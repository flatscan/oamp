import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A send that failed after send() returned (the system refused it, for
/// instance while the network is changing) reaches the socket's stream as
/// an error. Nothing depends on one packet, so it is only logged.
void _sendFailed(Object e) => debugPrint('Discovery: a send failed ($e)');

/// A reply to a [UdpQuery]: the bytes and who sent them.
typedef UdpReply = ({Uint8List data, InternetAddress from});

/// Sends one discovery query to a multicast group on every local network
/// and gathers the replies for a while.
///
/// Each query goes out from its own short-lived socket on a random port,
/// one per network interface, so replies come straight back to it:
///
/// - mDNS responders answer a query from a port other than 5353 with a
///   unicast reply to that port ("legacy unicast", RFC 6762 section 6.7).
/// - SSDP devices always answer an M-SEARCH by unicast to its source.
///
/// This needs neither the shared mDNS port 5353 nor, on Android, a
/// multicast lock, so it works even where [MulticastListener] can't.
/// Sending on every interface finds devices on the home network even when
/// a VPN such as Tailscale holds the default route.
class UdpQuery {
  UdpQuery({
    required this.group,
    required this.port,
    this.interfaces = _localInterfaces,
  });

  final InternetAddress group;
  final int port;

  /// The local IPv4 addresses to send from. Tests pass loopback.
  final Future<List<InternetAddress>> Function() interfaces;

  /// Sends [message] (again after [repeatAfter], since UDP drops packets)
  /// and returns every reply that arrives within [listenFor].
  Stream<UdpReply> send(
    Uint8List message, {
    Duration listenFor = const Duration(seconds: 3),
    Duration repeatAfter = const Duration(milliseconds: 700),
  }) {
    late StreamController<UdpReply> out;
    final sockets = <RawDatagramSocket>[];
    final timers = <Timer>[];

    Future<void> close() async {
      for (final t in timers) {
        t.cancel();
      }
      for (final s in sockets) {
        s.close();
      }
      sockets.clear();
      if (!out.isClosed) await out.close();
    }

    Future<void> start() async {
      final locals = await interfaces();
      for (final local in locals) {
        final RawDatagramSocket socket;
        try {
          socket = await RawDatagramSocket.bind(local, 0);
        } on SocketException catch (e) {
          debugPrint('Discovery: could not open a socket (${e.osError})');
          continue;
        }
        sockets.add(socket);
        if (group.isMulticast) {
          try {
            socket
              ..multicastHops = 4
              ..setRawOption(
                RawSocketOption(
                  RawSocketOption.levelIPv4,
                  RawSocketOption.IPv4MulticastInterface,
                  local.rawAddress,
                ),
              );
          } on Object {
            // Not every platform lets us pick; the default interface will do.
          }
        }
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final dg = socket.receive();
          if (dg != null && !out.isClosed) {
            out.add((data: dg.data, from: dg.address));
          }
        }, onError: _sendFailed);
        void fire() {
          try {
            socket.send(message, group, port);
          } on SocketException {
            // An interface that went away mid-scan.
          }
        }

        fire();
        timers.add(Timer(repeatAfter, fire));
      }
      timers.add(Timer(listenFor, close));
      if (sockets.isEmpty) await close();
    }

    out = StreamController<UdpReply>(onListen: start, onCancel: close);
    return out.stream;
  }

  /// IPv4 addresses of the interfaces that could reach speakers and TVs:
  /// not loopback, not link-local.
  static Future<List<InternetAddress>> _localInterfaces() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in list)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.isLinkLocal) a,
      ];
    } on Object catch (e) {
      debugPrint('Discovery: could not list network interfaces ($e)');
      return const [];
    }
  }
}

/// Listens on a shared multicast address and asks there too, so devices
/// that only answer by multicast are heard.
///
/// [UdpQuery] alone misses some: an mDNS reflector between networks (for
/// example a router passing replies across from an IoT VLAN) forwards a
/// legacy unicast reply only when its ID matches the question, and some
/// devices, such as the Nest Hub, always reply with ID 0. Their multicast
/// answers still get through, so OAmp listens for those as well.
///
/// The socket stays open between scans, until [idleTimeout] passes without
/// one. Joining the multicast group afresh for every 3-second scan loses
/// answers: a router or switch that forwards multicast by membership may
/// not have the new member in place when the answer comes, so some scans
/// hear nothing. Staying joined means a scan hears what it asks for.
///
/// The port is shared: on Windows the system's own DNS service holds 5353,
/// and on Android other apps may. On Android, Wi-Fi drops multicast unless
/// a multicast lock is held, which [lock] takes while the socket is open.
class MulticastListener {
  MulticastListener({
    required this.group,
    required this.port,
    this.lock = _noLock,
    this.interfaces = _multicastInterfaces,
    this.idleTimeout = const Duration(seconds: 20),
  });

  final InternetAddress group;
  final int port;

  /// Takes whatever the platform needs to receive multicast, and returns
  /// what lets it go again.
  final Future<void Function()> Function() lock;

  /// The interfaces to join the group on and ask from.
  final Future<List<NetworkInterface>> Function() interfaces;

  /// How long the socket stays open after a scan ends.
  final Duration idleTimeout;

  RawDatagramSocket? _socket;
  Future<void>? _opening;
  List<NetworkInterface> _joined = const [];
  void Function()? _release;
  Timer? _idle;
  bool _disposed = false;
  final _replies = StreamController<UdpReply>.broadcast();

  @visibleForTesting
  bool get isOpen => _socket != null;

  static Future<void Function()> _noLock() async => () {};

  /// Sends [query] now and again after [repeatAfter], and returns every
  /// reply that arrives within [listenFor].
  Stream<UdpReply> listen(
    Uint8List query, {
    Duration listenFor = const Duration(seconds: 3),
    Duration repeatAfter = const Duration(milliseconds: 700),
  }) {
    late StreamController<UdpReply> out;
    StreamSubscription<UdpReply>? heard;
    final timers = <Timer>[];

    Future<void> finish() async {
      for (final t in timers) {
        t.cancel();
      }
      await heard?.cancel();
      heard = null;
      if (!out.isClosed) await out.close();
      _idle?.cancel();
      _idle = Timer(idleTimeout, _closeSocket);
    }

    Future<void> start() async {
      _idle?.cancel();
      if (_disposed) {
        await finish();
        return;
      }
      await (_opening ??= _open());
      if (_socket == null || out.isClosed) {
        await finish();
        return;
      }
      heard = _replies.stream.listen(out.add);
      _ask(query);
      timers
        ..add(Timer(repeatAfter, () => _ask(query)))
        ..add(Timer(listenFor, finish));
    }

    out = StreamController<UdpReply>(onListen: start, onCancel: finish);
    return out.stream;
  }

  Future<void> _open() async {
    try {
      _release = await lock();
    } on Object catch (e) {
      debugPrint('Discovery: no multicast lock ($e)');
    }
    final RawDatagramSocket s;
    try {
      s = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        // Windows and Android share the port through reuseAddress alone,
        // and Dart logs an error if they are asked for reusePort.
        reusePort: !Platform.isWindows && !Platform.isAndroid,
      );
    } on Object catch (e) {
      debugPrint('Discovery: could not share the mDNS port ($e)');
      _opening = null;
      _releaseLock();
      return;
    }
    s.multicastHops = 255;
    final joined = <NetworkInterface>[];
    final refused = <String>[];
    for (final i in await interfaces()) {
      try {
        s.joinMulticast(group, i);
        joined.add(i);
      } on Object catch (e) {
        // Already joined through another address, or no multicast here.
        refused.add('${i.name} ($e)');
      }
    }
    debugPrint(
      'Discovery: shared port open, joined '
      '${joined.isEmpty ? 'nothing' : joined.map((i) => i.name).join(', ')}'
      '${refused.isEmpty ? '' : '; not ${refused.join(', ')}'}',
    );
    s.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = s.receive();
      if (dg != null) _replies.add((data: dg.data, from: dg.address));
    }, onError: _sendFailed);
    _socket = s;
    _joined = joined;
  }

  /// The name of the local interface [address] belongs to, if it is one
  /// this listener joined: a packet from it is one of our own questions
  /// coming back, which shows the question left by that interface.
  String? localInterfaceOf(InternetAddress address) {
    for (final i in _joined) {
      if (i.addresses.any((a) => a.address == address.address)) return i.name;
    }
    return null;
  }

  void _ask(Uint8List query) {
    final s = _socket;
    if (s == null) return;
    for (final i in _joined) {
      for (final a in i.addresses) {
        try {
          s
            ..setRawOption(
              RawSocketOption(
                RawSocketOption.levelIPv4,
                RawSocketOption.IPv4MulticastInterface,
                a.rawAddress,
              ),
            )
            ..send(query, group, port);
        } on Object catch (e) {
          // An interface that went away mid-scan, usually.
          debugPrint('Discovery: could not ask on ${i.name} ($e)');
        }
      }
    }
  }

  void _closeSocket() {
    _idle?.cancel();
    _idle = null;
    _socket?.close();
    _socket = null;
    _opening = null;
    _joined = const [];
    _releaseLock();
  }

  void _releaseLock() {
    _release?.call();
    _release = null;
  }

  /// Closes the socket for good.
  Future<void> dispose() async {
    _disposed = true;
    _closeSocket();
    await _replies.close();
  }

  /// IPv4 interfaces that could reach speakers and TVs.
  static Future<List<NetworkInterface>> _multicastInterfaces() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in list)
          if (i.addresses.any((a) => !a.isLoopback && !a.isLinkLocal)) i,
      ];
    } on Object catch (e) {
      debugPrint('Discovery: could not list network interfaces ($e)');
      return const [];
    }
  }
}

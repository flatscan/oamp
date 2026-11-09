import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

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
        });
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

/// Listens on a shared multicast address for the length of a scan, and asks
/// there too, so devices that only answer by multicast are heard.
///
/// [UdpQuery] alone misses some: an mDNS reflector between networks (for
/// example a router passing replies across from an IoT VLAN) forwards a
/// legacy unicast reply only when its ID matches the question, and some
/// devices, such as the Nest Hub, always reply with ID 0. Their multicast
/// announcements still get through, so OAmp listens for those as well.
///
/// The port is shared: on Windows the system's own DNS service holds 5353,
/// and on Android other apps may. On Android, Wi-Fi drops multicast unless
/// a multicast lock is held, which [lock] takes for the scan.
class MulticastListener {
  MulticastListener({
    required this.group,
    required this.port,
    this.lock = _noLock,
    this.interfaces = _multicastInterfaces,
  });

  final InternetAddress group;
  final int port;

  /// Takes whatever the platform needs to receive multicast, and returns
  /// what lets it go again.
  final Future<void Function()> Function() lock;

  /// The interfaces to join the group on and ask from.
  final Future<List<NetworkInterface>> Function() interfaces;

  static Future<void Function()> _noLock() async => () {};

  Stream<UdpReply> listen(
    Uint8List query, {
    Duration listenFor = const Duration(seconds: 3),
    Duration repeatAfter = const Duration(milliseconds: 700),
  }) {
    late StreamController<UdpReply> out;
    RawDatagramSocket? socket;
    void Function()? release;
    final timers = <Timer>[];

    Future<void> close() async {
      for (final t in timers) {
        t.cancel();
      }
      socket?.close();
      socket = null;
      release?.call();
      release = null;
      if (!out.isClosed) await out.close();
    }

    Future<void> start() async {
      try {
        release = await lock();
      } on Object catch (e) {
        debugPrint('Discovery: no multicast lock ($e)');
      }
      final RawDatagramSocket s;
      try {
        s = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          port,
          reuseAddress: true,
          // Windows shares the port through reuseAddress alone.
          reusePort: !Platform.isWindows,
        );
      } on Object catch (e) {
        debugPrint('Discovery: could not share the mDNS port ($e)');
        await close();
        return;
      }
      if (out.isClosed) {
        s.close();
        return;
      }
      socket = s;
      s.multicastHops = 255;
      final joined = <NetworkInterface>[];
      for (final i in await interfaces()) {
        try {
          s.joinMulticast(group, i);
          joined.add(i);
        } on Object {
          // Already joined through another address, or no multicast here.
        }
      }
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = s.receive();
        if (dg != null && !out.isClosed) {
          out.add((data: dg.data, from: dg.address));
        }
      });
      void ask() {
        for (final i in joined) {
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
            } on Object {
              // An interface that went away mid-scan.
            }
          }
        }
      }

      ask();
      timers
        ..add(Timer(repeatAfter, ask))
        ..add(Timer(listenFor, close));
    }

    out = StreamController<UdpReply>(onListen: start, onCancel: close);
    return out.stream;
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

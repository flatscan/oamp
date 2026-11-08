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
/// So OAmp never has to bind the shared mDNS port 5353, which on Windows
/// belongs to the system's own DNS service, and on Android needs no
/// multicast lock. Sending on every interface finds devices on the home
/// network even when a VPN such as Tailscale holds the default route.
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

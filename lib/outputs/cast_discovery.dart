import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/output_device.dart';
import 'dns_packet.dart';
import 'udp_query.dart';

/// Finds Google Cast devices with an mDNS query for `_googlecast._tcp`:
/// asked from a random port for direct replies, and by default also on the
/// shared mDNS port, for devices whose direct replies don't arrive.
class CastFinder {
  CastFinder({UdpQuery? query, MulticastListener? listener})
    : _query = query ?? UdpQuery(group: _mdnsGroup, port: mdnsPort),
      _listener = query == null && listener == null
          ? MulticastListener(
              group: _mdnsGroup,
              port: mdnsPort,
              lock: _multicastLock,
            )
          : listener;

  static const mdnsPort = 5353;
  static const service = '_googlecast._tcp.local';
  static final _mdnsGroup = InternetAddress('224.0.0.251');

  final UdpQuery _query;
  final MulticastListener? _listener;

  /// Closes the shared-port socket, which otherwise stays open a while
  /// after the last scan.
  Future<void> dispose() async => _listener?.dispose();

  /// Each device as it answers. A device may answer more than once.
  Stream<OutputDevice> find({Duration listenFor = const Duration(seconds: 3)}) {
    final question = buildPtrQuery(service);
    final direct = _query
        .send(question, listenFor: listenFor)
        .expand(
          (reply) => castDevicesIn(parseDnsResponse(reply.data), reply.from),
        );
    final listener = _listener;
    if (listener == null) return direct;
    // Heard on the shared port, a packet may come from any host and carry
    // only part of a device (answers to other apps' questions), so only a
    // device that arrives complete counts.
    var packets = 0;
    var aboutCast = 0;
    var devices = 0;
    final shared = listener.listen(question, listenFor: listenFor).expand((
      reply,
    ) {
      packets++;
      final records = parseDnsResponse(reply.data);
      if (records.any((r) => r.name.toLowerCase().endsWith(service))) {
        aboutCast++;
      }
      final found = castDevicesIn(records, reply.from, senderIsDevice: false);
      devices += found.length;
      return found;
    });
    return _merge(
      [direct, shared],
      // Counts only, so a quiet shared port can be told from a rejected
      // announcement.
      onDone: () => debugPrint(
        'Discovery: shared port heard $packets packet(s), $aboutCast about '
        'Cast, $devices Cast device(s)',
      ),
    );
  }

  static Stream<T> _merge<T>(
    List<Stream<T>> streams, {
    void Function()? onDone,
  }) {
    if (streams.length == 1) return streams.single;
    late StreamController<T> out;
    final subs = <StreamSubscription<T>>[];
    var open = streams.length;
    out = StreamController<T>(
      onListen: () {
        for (final s in streams) {
          subs.add(
            s.listen(
              out.add,
              onError: out.addError,
              onDone: () {
                if (--open == 0) {
                  onDone?.call();
                  out.close();
                }
              },
            ),
          );
        }
      },
      onCancel: () => Future.wait([for (final s in subs) s.cancel()]),
    );
    return out.stream;
  }

  static const _network = MethodChannel('oamp/network');

  /// Android's Wi-Fi drops multicast unless an app holds a multicast lock.
  /// MainActivity answers on `oamp/network`.
  static Future<void Function()> _multicastLock() async {
    if (!Platform.isAndroid) return () {};
    await _network.invokeMethod<void>('acquireMulticastLock');
    return () => unawaited(
      _network
          .invokeMethod<void>('releaseMulticastLock')
          .catchError((Object _) {}),
    );
  }
}

/// The Cast devices described by one mDNS reply from [from].
///
/// A reply usually carries the PTR record with the TXT, SRV and A records
/// alongside it. When the address record is missing, the reply's sender is
/// the device, if [senderIsDevice] (a direct reply to our question). A
/// device with no TXT record has no name or model and is left out.
List<OutputDevice> castDevicesIn(
  List<DnsRecord> records,
  InternetAddress from, {
  bool senderIsDevice = true,
}) {
  final instances = {
    for (final r in records)
      if (r.type == DnsType.ptr &&
          r.target != null &&
          r.name.toLowerCase() == CastFinder.service)
        r.target!,
  };
  // Some devices answer with only the SRV and TXT records.
  for (final r in records) {
    if ((r.type == DnsType.srv || r.type == DnsType.txt) &&
        r.name.toLowerCase().endsWith('.${CastFinder.service}')) {
      instances.add(r.name);
    }
  }
  DnsRecord? find(int type, String name) {
    final lower = name.toLowerCase();
    for (final r in records) {
      if (r.type == type && r.name.toLowerCase() == lower) return r;
    }
    return null;
  }

  return [
    for (final instance in instances)
      ?_device(instance, find, senderIsDevice ? from : null),
  ];
}

OutputDevice? _device(
  String instance,
  DnsRecord? Function(int, String) find,
  InternetAddress? from,
) {
  final txt = find(DnsType.txt, instance)?.txt ?? const {};
  // Without its TXT record there is no name, model or id to show.
  if (txt.isEmpty) return null;
  final srv = find(DnsType.srv, instance);
  // A TTL of zero says the device is leaving.
  if (srv?.ttl == 0) return null;
  final address = srv?.srvHost == null
      ? null
      : find(DnsType.a, srv!.srvHost!)?.address;
  final host = address ?? from?.address;
  if (host == null) return null;
  final caps = int.tryParse(txt['ca'] ?? '') ?? 0;
  final model = txt['md'];
  final isGroup = model == 'Google Cast Group' || caps & _castGroupBit != 0;
  final id = txt['id'] ?? instance.split('.').first;
  return OutputDevice(
    id: id,
    protocol: OutputProtocol.cast,
    name: txt['fn'] ?? model ?? 'Cast device',
    model: model,
    host: host,
    port: srv?.srvPort ?? 8009,
    isGroup: isGroup,
    hasScreen: !isGroup && caps & _videoOutBit != 0,
  );
}

/// Bits of the `ca` (capabilities) TXT entry.
const _videoOutBit = 0x01;
const _castGroupBit = 0x20;

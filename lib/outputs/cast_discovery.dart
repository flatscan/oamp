import 'dart:async';
import 'dart:io';

import '../core/output_device.dart';
import 'dns_packet.dart';
import 'udp_query.dart';

/// Finds Google Cast devices with an mDNS query for `_googlecast._tcp`.
class CastFinder {
  CastFinder({UdpQuery? query})
    : _query =
          query ??
          UdpQuery(group: InternetAddress('224.0.0.251'), port: mdnsPort);

  static const mdnsPort = 5353;
  static const service = '_googlecast._tcp.local';

  final UdpQuery _query;

  /// Each device as it answers. A device may answer more than once.
  Stream<OutputDevice> find({Duration listenFor = const Duration(seconds: 3)}) {
    return _query
        .send(buildPtrQuery(service), listenFor: listenFor)
        .expand(
          (reply) => castDevicesIn(parseDnsResponse(reply.data), reply.from),
        );
  }
}

/// The Cast devices described by one mDNS reply from [from].
///
/// A reply usually carries the PTR record with the TXT, SRV and A records
/// alongside it. When the address record is missing, the reply's sender is
/// the device.
List<OutputDevice> castDevicesIn(
  List<DnsRecord> records,
  InternetAddress from,
) {
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

  return [for (final instance in instances) ?_device(instance, find, from)];
}

OutputDevice? _device(
  String instance,
  DnsRecord? Function(int, String) find,
  InternetAddress from,
) {
  final txt = find(DnsType.txt, instance)?.txt ?? const {};
  final srv = find(DnsType.srv, instance);
  // A TTL of zero says the device is leaving.
  if (srv?.ttl == 0) return null;
  final address = srv?.srvHost == null
      ? null
      : find(DnsType.a, srv!.srvHost!)?.address;
  final caps = int.tryParse(txt['ca'] ?? '') ?? 0;
  final model = txt['md'];
  final isGroup = model == 'Google Cast Group' || caps & _castGroupBit != 0;
  final id = txt['id'] ?? instance.split('.').first;
  return OutputDevice(
    id: id,
    protocol: OutputProtocol.cast,
    name: txt['fn'] ?? model ?? 'Cast device',
    model: model,
    host: address ?? from.address,
    port: srv?.srvPort ?? 8009,
    isGroup: isGroup,
    hasScreen: !isGroup && caps & _videoOutBit != 0,
  );
}

/// Bits of the `ca` (capabilities) TXT entry.
const _videoOutBit = 0x01;
const _castGroupBit = 0x20;

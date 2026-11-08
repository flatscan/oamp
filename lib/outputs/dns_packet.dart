import 'dart:convert';
import 'dart:typed_data';

/// Just enough of the DNS wire format (RFC 1035) for multicast DNS service
/// browsing (RFC 6762, RFC 6763): building a PTR question and reading the
/// PTR, SRV, TXT and A records that come back.
class DnsType {
  static const a = 1;
  static const ptr = 12;
  static const txt = 16;
  static const aaaa = 28;
  static const srv = 33;
}

/// One resource record from an answer.
class DnsRecord {
  final String name;
  final int type;
  final int ttl;

  /// PTR: the instance name it points to.
  final String? target;

  /// SRV: where the instance lives.
  final String? srvHost;
  final int? srvPort;

  /// TXT: key=value pairs. Keys are lower-cased.
  final Map<String, String>? txt;

  /// A: the IPv4 address as a dotted string.
  final String? address;

  const DnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    this.target,
    this.srvHost,
    this.srvPort,
    this.txt,
    this.address,
  });
}

/// Builds a standard query for the PTR records of [service], such as
/// `_googlecast._tcp.local`.
///
/// [unicastResponse] sets the QU bit, asking responders to answer straight
/// to the sender instead of the whole network.
Uint8List buildPtrQuery(
  String service, {
  int id = 0,
  bool unicastResponse = false,
}) {
  final out = BytesBuilder();
  void u16(int v) => out.add([(v >> 8) & 0xff, v & 0xff]);
  u16(id);
  u16(0); // flags: standard query
  u16(1); // one question
  u16(0);
  u16(0);
  u16(0);
  for (final label in service.split('.')) {
    if (label.isEmpty) continue;
    final bytes = utf8.encode(label);
    out.addByte(bytes.length);
    out.add(bytes);
  }
  out.addByte(0);
  u16(DnsType.ptr);
  u16(unicastResponse ? 0x8001 : 0x0001); // class IN, QU bit
  return out.toBytes();
}

/// Reads every answer, authority and additional record in [packet].
/// Questions are skipped. Returns an empty list for anything that is not a
/// well-formed response, rather than throwing: the network is full of
/// other people's packets.
List<DnsRecord> parseDnsResponse(Uint8List packet) {
  try {
    return _Reader(packet).records();
  } on RangeError {
    return const [];
  } on FormatException {
    return const [];
  }
}

class _Reader {
  _Reader(this.data) : view = ByteData.sublistView(data);

  final Uint8List data;
  final ByteData view;
  int offset = 0;

  int u8() => data[offset++];
  int u16() {
    final v = view.getUint16(offset);
    offset += 2;
    return v;
  }

  int u32() {
    final v = view.getUint32(offset);
    offset += 4;
    return v;
  }

  List<DnsRecord> records() {
    u16(); // id
    final flags = u16();
    if (flags & 0x8000 == 0) return const []; // a query, not a response
    final questions = u16();
    final total = u16() + u16() + u16();
    for (var i = 0; i < questions; i++) {
      name();
      offset += 4;
    }
    return [for (var i = 0; i < total; i++) ?record()];
  }

  DnsRecord? record() {
    final owner = name();
    final type = u16();
    u16(); // class (and the cache-flush bit)
    final ttl = u32();
    final length = u16();
    final end = offset + length;
    if (end > data.length) throw RangeError('record runs past the packet');
    DnsRecord? result;
    switch (type) {
      case DnsType.ptr:
        result = DnsRecord(name: owner, type: type, ttl: ttl, target: name());
      case DnsType.srv:
        u16(); // priority
        u16(); // weight
        final port = u16();
        result = DnsRecord(
          name: owner,
          type: type,
          ttl: ttl,
          srvPort: port,
          srvHost: name(),
        );
      case DnsType.txt:
        final txt = <String, String>{};
        while (offset < end) {
          final len = u8();
          final entry = utf8.decode(
            data.sublist(offset, offset + len),
            allowMalformed: true,
          );
          offset += len;
          final eq = entry.indexOf('=');
          if (eq > 0) {
            txt[entry.substring(0, eq).toLowerCase()] = entry.substring(eq + 1);
          } else if (entry.isNotEmpty) {
            txt[entry.toLowerCase()] = '';
          }
        }
        result = DnsRecord(name: owner, type: type, ttl: ttl, txt: txt);
      case DnsType.a when length == 4:
        result = DnsRecord(
          name: owner,
          type: type,
          ttl: ttl,
          address: data.sublist(offset, offset + 4).join('.'),
        );
    }
    offset = end;
    return result;
  }

  /// A domain name, following compression pointers.
  String name() {
    final labels = <String>[];
    var pos = offset;
    var jumped = false;
    var hops = 0;
    while (true) {
      final len = data[pos];
      if (len == 0) {
        pos++;
        break;
      }
      if (len & 0xc0 == 0xc0) {
        final pointer = ((len & 0x3f) << 8) | data[pos + 1];
        if (!jumped) offset = pos + 2;
        jumped = true;
        if (++hops > 32) throw const FormatException('pointer loop');
        pos = pointer;
        continue;
      }
      labels.add(
        utf8.decode(data.sublist(pos + 1, pos + 1 + len), allowMalformed: true),
      );
      pos += 1 + len;
    }
    if (!jumped) offset = pos;
    return labels.join('.');
  }
}

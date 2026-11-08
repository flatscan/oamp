import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/output_device.dart';
import 'package:oamp/outputs/cast_discovery.dart';
import 'package:oamp/outputs/dlna_discovery.dart';
import 'package:oamp/outputs/dns_packet.dart';
import 'package:oamp/outputs/network_discovery.dart';
import 'package:oamp/outputs/udp_query.dart';

/// Builds mDNS responses the way Cast devices send them: PTR answer, then
/// TXT, SRV and A records, with names compressed.
class _Response {
  final _b = BytesBuilder();
  final _names = <String, int>{};
  int _count = 0;

  void _u16(int v) => _b.add([(v >> 8) & 0xff, v & 0xff]);
  void _u32(int v) =>
      _b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

  List<int> _name(String name, int at) {
    final out = <int>[];
    final labels = name.split('.');
    for (var i = 0; i < labels.length; i++) {
      final rest = labels.sublist(i).join('.');
      final seen = _names[rest];
      if (seen != null) {
        out.addAll([0xc0 | (seen >> 8), seen & 0xff]);
        return out;
      }
      _names[rest] = at + out.length;
      final bytes = utf8.encode(labels[i]);
      out
        ..add(bytes.length)
        ..addAll(bytes);
    }
    return out..add(0);
  }

  void _record(String name, int type, List<int> Function(int at) data) {
    _count++;
    _b.add(_name(name, 12 + _b.length));
    _u16(type);
    _u16(0x8001);
    _u32(120);
    final at = 12 + _b.length + 2;
    final body = data(at);
    _u16(body.length);
    _b.add(body);
  }

  void ptr(String name, String target) =>
      _record(name, DnsType.ptr, (at) => _name(target, at));

  void txt(String name, Map<String, String> entries) =>
      _record(name, DnsType.txt, (_) {
        final out = <int>[];
        entries.forEach((k, v) {
          final e = utf8.encode('$k=$v');
          out
            ..add(e.length)
            ..addAll(e);
        });
        return out;
      });

  void srv(String name, String host, int port) =>
      _record(name, DnsType.srv, (at) {
        return [0, 0, 0, 0, port >> 8, port & 0xff, ..._name(host, at + 6)];
      });

  void a(String name, String address) => _record(
    name,
    DnsType.a,
    (_) => address.split('.').map(int.parse).toList(),
  );

  Uint8List build() {
    final header = BytesBuilder()
      ..add([0, 0, 0x84, 0x00, 0, 0, 0, 1, 0, 0, 0, _count - 1]);
    return (header..add(_b.toBytes())).toBytes();
  }
}

Uint8List _castReply({
  String fn = 'Living room TV',
  String md = 'Chromecast',
  String id = 'abc123',
  int ca = 4101,
  int port = 8009,
  String address = '192.168.1.20',
}) {
  final instance = '$md-$id.${CastFinder.service}';
  return (_Response()
        ..ptr(CastFinder.service, instance)
        ..txt(instance, {'id': id, 'md': md, 'fn': fn, 'ca': '$ca'})
        ..srv(instance, '$id.local', port)
        ..a('$id.local', address))
      .build();
}

const _kodiDescription = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>Kodi (lounge)</friendlyName>
    <deviceList>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>Kodi lounge</friendlyName>
        <manufacturer>XBMC Foundation</manufacturer>
        <modelName>Kodi</modelName>
        <UDN>uuid:1234-5678</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
          </service>
        </serviceList>
      </device>
    </deviceList>
  </device>
</root>''';

final _loopback = InternetAddress.loopbackIPv4;
Future<List<InternetAddress>> _loopbackOnly() async => [_loopback];

/// A UDP responder on loopback that answers every packet with [answer].
Future<RawDatagramSocket> _responder(
  Uint8List? Function(Uint8List query) answer,
) async {
  final socket = await RawDatagramSocket.bind(_loopback, 0);
  socket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    final reply = answer(dg.data);
    if (reply != null) socket.send(reply, dg.address, dg.port);
  });
  return socket;
}

void main() {
  group('DNS packets', () {
    test('the PTR query asks one question for the service', () {
      final q = buildPtrQuery(CastFinder.service, unicastResponse: true);
      expect(q.sublist(0, 6), [0, 0, 0, 0, 0, 1]);
      expect(latin1.decode(q), contains('_googlecast'));
      expect(q.sublist(q.length - 4), [0, DnsType.ptr, 0x80, 0x01]);
    });

    test('queries and junk give no records', () {
      expect(parseDnsResponse(buildPtrQuery(CastFinder.service)), isEmpty);
      expect(parseDnsResponse(Uint8List.fromList([1, 2, 3])), isEmpty);
      final truncated = _castReply();
      expect(parseDnsResponse(truncated.sublist(0, 40)), isEmpty);
    });
  });

  group('Cast replies', () {
    test('a Chromecast with a screen', () {
      final devices = castDevicesIn(
        parseDnsResponse(_castReply()),
        InternetAddress('192.168.1.99'),
      );
      expect(devices, hasLength(1));
      final d = devices.single;
      expect(d.protocol, OutputProtocol.cast);
      expect(d.id, 'abc123');
      expect(d.name, 'Living room TV');
      expect(d.model, 'Chromecast');
      expect(d.host, '192.168.1.20');
      expect(d.port, 8009);
      expect(d.hasScreen, isTrue);
      expect(d.isGroup, isFalse);
    });

    test('a speaker and a speaker group', () {
      final speaker = castDevicesIn(
        parseDnsResponse(_castReply(md: 'Google Nest Mini', ca: 199172)),
        _loopback,
      ).single;
      expect(speaker.hasScreen, isFalse);
      final group = castDevicesIn(
        parseDnsResponse(
          _castReply(
            md: 'Google Cast Group',
            fn: 'Downstairs',
            id: 'grp1',
            ca: 199204,
            port: 32187,
          ),
        ),
        _loopback,
      ).single;
      expect(group.isGroup, isTrue);
      expect(group.port, 32187);
    });

    test('falls back to the sender when there is no address record', () {
      final instance = 'Chromecast-x.${CastFinder.service}';
      final reply =
          (_Response()
                ..ptr(CastFinder.service, instance)
                ..txt(instance, {'id': 'x', 'fn': 'Bedroom'}))
              .build();
      final d = castDevicesIn(
        parseDnsResponse(reply),
        InternetAddress('10.0.0.5'),
      ).single;
      expect(d.host, '10.0.0.5');
      expect(d.port, 8009);
      expect(d.name, 'Bedroom');
    });
  });

  group('DLNA', () {
    test('reads the LOCATION of a renderer reply only', () {
      const reply =
          'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'Location: http://192.168.1.30:1528/description.xml\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:1234::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
      expect(
        ssdpLocation(reply),
        Uri.parse('http://192.168.1.30:1528/description.xml'),
      );
      expect(
        ssdpLocation(reply.replaceAll('MediaRenderer', 'MediaServer')),
        isNull,
      );
      expect(ssdpLocation('M-SEARCH * HTTP/1.1\r\n\r\n'), isNull);
    });

    test('finds the renderer inside a combined device', () {
      final d = dlnaDeviceFrom(
        _kodiDescription,
        Uri.parse('http://192.168.1.30:1528/description.xml'),
      )!;
      expect(d.protocol, OutputProtocol.dlna);
      expect(d.id, '1234-5678');
      expect(d.name, 'Kodi lounge');
      expect(d.model, 'XBMC Foundation Kodi');
      expect(d.host, '192.168.1.30');
      expect(d.port, 1528);
      expect(d.hasScreen, isTrue, reason: 'Kodi drives a screen');
    });

    test('tells TVs from speakers by how they describe themselves', () {
      String describe(String name, String model) =>
          '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
          '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
          '<friendlyName>$name</friendlyName><modelName>$model</modelName>'
          '<serviceList><service><serviceType>'
          'urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
          '</service></serviceList></device></root>';
      final at = Uri.parse('http://h/d.xml');
      expect(
        dlnaDeviceFrom(describe('[TV] Living room', 'QE55Q70'), at)!.hasScreen,
        isTrue,
      );
      expect(
        dlnaDeviceFrom(describe('Kitchen', 'Speaker One'), at)!.hasScreen,
        isFalse,
      );
    });

    test('skips renderers without AVTransport, and bad XML', () {
      final noTransport = _kodiDescription.replaceAll('AVTransport', 'Other');
      final at = Uri.parse('http://h/d.xml');
      expect(dlnaDeviceFrom(noTransport, at), isNull);
      expect(dlnaDeviceFrom('<root><device>', at), isNull);
    });
  });

  test('a device that speaks Cast and DLNA is listed once, as Cast', () {
    const tvCast = OutputDevice(
      id: 'c',
      protocol: OutputProtocol.cast,
      name: 'TV',
      host: '192.168.1.40',
      port: 8009,
    );
    const tvDlna = OutputDevice(
      id: 'd',
      protocol: OutputProtocol.dlna,
      name: '[TV] Samsung',
      host: '192.168.1.40',
      port: 9197,
    );
    const group = OutputDevice(
      id: 'g',
      protocol: OutputProtocol.cast,
      name: 'Downstairs',
      host: '192.168.1.40',
      port: 32000,
      isGroup: true,
    );
    const kodi = OutputDevice(
      id: 'k',
      protocol: OutputProtocol.dlna,
      name: 'kodi',
      host: '192.168.1.50',
      port: 1528,
    );
    expect(mergeDevices([tvDlna, kodi, group, tvCast]), [group, kodi, tvCast]);
  });

  group('over the network (loopback)', () {
    test('finds a Cast device and a DLNA renderer, and drops them when '
        'they go quiet', () async {
      var castAnswers = true;
      final castResponder = await _responder(
        (q) => castAnswers && parseDnsResponse(q).isEmpty
            ? _castReply(address: '127.0.0.1')
            : null,
      );
      final http = await HttpServer.bind(_loopback, 0);
      http.listen((req) {
        req.response
          ..headers.contentType = ContentType('text', 'xml')
          ..write(_kodiDescription)
          ..close();
      });
      var dlnaAnswers = true;
      final ssdpResponder = await _responder((q) {
        if (!dlnaAnswers || !latin1.decode(q).startsWith('M-SEARCH')) {
          return null;
        }
        return Uint8List.fromList(
          latin1.encode(
            'HTTP/1.1 200 OK\r\n'
            'LOCATION: http://127.0.0.1:${http.port}/description.xml\r\n'
            'ST: ${DlnaFinder.renderer}\r\n\r\n',
          ),
        );
      });
      addTearDown(() async {
        castResponder.close();
        ssdpResponder.close();
        await http.close(force: true);
      });

      final discovery = NetworkDeviceDiscovery(
        listenFor: const Duration(milliseconds: 400),
        cast: CastFinder(
          query: UdpQuery(
            group: _loopback,
            port: castResponder.port,
            interfaces: _loopbackOnly,
          ),
        ),
        dlna: DlnaFinder(
          query: UdpQuery(
            group: _loopback,
            port: ssdpResponder.port,
            interfaces: _loopbackOnly,
          ),
        ),
      );
      addTearDown(discovery.dispose);

      await discovery.scan();
      // Both answer from 127.0.0.1, so they merge to the Cast entry.
      expect(discovery.current.map((d) => d.protocol), [OutputProtocol.cast]);

      castAnswers = false;
      await discovery.scan();
      expect(discovery.current.single.name, 'Kodi lounge');

      dlnaAnswers = false;
      await discovery.scan();
      expect(discovery.current, isEmpty);
    });
  });
}

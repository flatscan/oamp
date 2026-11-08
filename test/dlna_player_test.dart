import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oamp/core/output_device.dart';
import 'package:oamp/core/remote_player.dart';
import 'package:oamp/outputs/dlna/dlna_player.dart';
import 'package:xml/xml.dart';

RemoteMedia _m(int i, {Duration duration = const Duration(seconds: 10)}) =>
    RemoteMedia(
      url: Uri.parse('http://server/stream/$i?a=1&b=2'),
      contentType: 'audio/flac',
      title: 'Track <$i> & more',
      artist: 'Artist',
      duration: duration,
    );

const _description = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:3</serviceType>
        <controlURL>/av/control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>rc/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

/// A renderer answering SOAP calls from memory.
class FakeRenderer {
  FakeRenderer({this.supportsNext = true, this.slowStart = false});

  final bool supportsNext;

  /// Takes a moment to start playing, and refuses to seek until it has,
  /// as Samsung TVs do.
  final bool slowStart;
  int _starting = 0;
  final calls = <String>[];
  final args = <String, Map<String, String>>{};
  String? uri;
  String? nextUri;
  String state = 'NO_MEDIA_PRESENT';
  String relTime = '0:00:00';
  int volume = 30;

  late final client = MockClient(handle);

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'GET') return http.Response(_description, 200);
    final doc = XmlDocument.parse(request.body);
    final action = doc.descendantElements
        .firstWhere((e) => e.localName == 'Body')
        .childElements
        .first;
    final name = action.localName;
    calls.add(name);
    args[name] = {
      for (final e in action.childElements) e.localName: e.innerText,
    };
    final a = args[name]!;
    var out = '';
    switch (name) {
      case 'SetAVTransportURI':
        uri = a['CurrentURI'];
        state = 'STOPPED';
      case 'SetNextAVTransportURI':
        if (!supportsNext) return http.Response('<fault/>', 500);
        nextUri = a['NextURI'];
      case 'Play':
        if (slowStart && state != 'PAUSED_PLAYBACK') {
          state = 'TRANSITIONING';
          _starting = 2;
        } else {
          state = 'PLAYING';
        }
      case 'Pause':
        state = 'PAUSED_PLAYBACK';
      case 'Stop':
        state = 'STOPPED';
      case 'Seek':
        if (slowStart && state != 'PLAYING') {
          return http.Response('<fault/>', 500);
        }
        relTime = a['Target']!;
      case 'GetTransportInfo':
        if (state == 'TRANSITIONING' && --_starting <= 0) state = 'PLAYING';
        out = '<CurrentTransportState>$state</CurrentTransportState>';
      case 'GetPositionInfo':
        out =
            '<TrackURI>${uri ?? ''}</TrackURI><RelTime>$relTime</RelTime>'
            '<TrackDuration>0:00:10</TrackDuration>';
      case 'GetVolume':
        out = '<CurrentVolume>$volume</CurrentVolume>';
      case 'SetVolume':
        volume = int.parse(a['DesiredVolume']!);
    }
    return http.Response(
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body><u:${name}Response>$out</u:${name}Response></s:Body>'
      '</s:Envelope>',
      200,
    );
  }

  /// The renderer finishes the current track and moves to the next.
  void moveOn() {
    if (nextUri != null) {
      uri = nextUri;
      nextUri = null;
      relTime = '0:00:01';
    } else {
      relTime = '0:00:10';
      state = 'STOPPED';
    }
  }
}

final _device = OutputDevice(
  id: 'dlna',
  protocol: OutputProtocol.dlna,
  name: 'TV',
  host: '192.0.2.1',
  port: 9197,
  descriptionUrl: Uri.parse('http://192.0.2.1:9197/dmr/desc.xml'),
);

void main() {
  test('control URLs resolve against the description address', () {
    final urls = dlnaControlUrls(_description, _device.descriptionUrl!);
    expect(
      urls[DlnaPlayer.avTransport].toString(),
      'http://192.0.2.1:9197/av/control',
    );
    expect(
      urls[DlnaPlayer.renderingControl].toString(),
      'http://192.0.2.1:9197/dmr/rc/control',
    );
  });

  test('DIDL-Lite escapes titles and carries the stream type', () {
    final xml = didl(_m(1));
    final doc = XmlDocument.parse(xml);
    expect(
      doc.findAllElements('dc:title').single.innerText,
      'Track <1> & more',
    );
    final res = doc.findAllElements('res').single;
    expect(res.innerText, 'http://server/stream/1?a=1&b=2');
    expect(res.getAttribute('protocolInfo'), 'http-get:*:audio/flac:*');
    expect(res.getAttribute('duration'), '0:00:10.000');
  });

  test('loads, lines up the next track and follows the renderer', () async {
    final r = FakeRenderer();
    final player = await DlnaPlayer.connect(_device, client: r.client);
    addTearDown(player.close);

    await player.load(_m(0), next: _m(1), position: const Duration(seconds: 3));
    expect(r.uri, _m(0).url.toString());
    expect(r.nextUri, _m(1).url.toString());
    expect(r.state, 'PLAYING');
    expect(r.args['Seek']!['Target'], '0:00:03');

    final advanced = player.advanced.first;
    r.moveOn();
    await advanced.timeout(const Duration(seconds: 3));

    await player.pause();
    expect(r.state, 'PAUSED_PLAYBACK');
    await player.setVolume(0.6);
    expect(r.volume, 60);

    await player.close();
    expect(r.calls.last, 'Stop');
  });

  test('loading paused at a spot leaves the renderer paused there', () async {
    final r = FakeRenderer();
    final player = await DlnaPlayer.connect(_device, client: r.client);
    addTearDown(player.close);
    await player.load(_m(0), position: const Duration(seconds: 5), play: false);
    expect(r.state, 'PAUSED_PLAYBACK');
    expect(r.relTime, '0:00:05');
  });

  test('waits for a slow renderer to start before seeking', () async {
    final r = FakeRenderer(slowStart: true);
    final player = await DlnaPlayer.connect(_device, client: r.client);
    addTearDown(player.close);
    await player.load(_m(0), position: const Duration(seconds: 4));
    expect(r.relTime, '0:00:04');
    expect(r.state, 'PLAYING');

    await player.load(_m(1), position: const Duration(seconds: 6), play: false);
    expect(r.relTime, '0:00:06');
    expect(r.state, 'PAUSED_PLAYBACK');
  });

  test('a renderer that never seeks still plays', () async {
    final r = FakeRenderer(slowStart: true);
    final client = MockClient((req) async {
      if (req.body.contains('u:GetTransportInfo')) {
        // Never reports playing, so every seek is refused.
        r.state = 'TRANSITIONING';
      }
      return r.handle(req);
    });
    final player = await DlnaPlayer.connect(_device, client: client);
    addTearDown(player.close);
    await player.load(_m(0), position: const Duration(seconds: 4));
    expect(r.uri, _m(0).url.toString());
    await player.seek(const Duration(seconds: 8));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test(
    'starts the next track itself when the renderer cannot line it up',
    () async {
      final r = FakeRenderer(supportsNext: false);
      final player = await DlnaPlayer.connect(_device, client: r.client);
      addTearDown(player.close);
      await player.load(_m(0), next: _m(1));
      expect(r.nextUri, isNull);

      // Play nearly to the end, then stop as a finished track does.
      r.relTime = '0:00:09';
      await Future<void>.delayed(const Duration(milliseconds: 3200));
      final advanced = player.advanced.first;
      r.state = 'STOPPED';
      await advanced.timeout(const Duration(seconds: 3));
      expect(r.uri, _m(1).url.toString());
      expect(r.state, 'PLAYING');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('reports the end when the last track finishes', () async {
    final r = FakeRenderer();
    final player = await DlnaPlayer.connect(_device, client: r.client);
    addTearDown(player.close);
    await player.load(_m(0));
    r.relTime = '0:00:09';
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    final ended = player.status.firstWhere((s) => s.ended);
    r.moveOn();
    await ended.timeout(const Duration(seconds: 3));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('closes when the renderer stops answering', () async {
    var up = true;
    final r = FakeRenderer();
    final client = MockClient((req) async {
      if (!up) throw http.ClientException('gone');
      return r.handle(req);
    });
    final player = await DlnaPlayer.connect(_device, client: client);
    await player.load(_m(0));
    up = false;
    await player.closed.timeout(const Duration(seconds: 6));
  }, timeout: const Timeout(Duration(seconds: 15)));
}

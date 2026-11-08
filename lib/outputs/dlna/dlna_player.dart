import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../core/output_device.dart';
import '../../core/remote_player.dart';

/// [RemotePlayer] for DLNA / UPnP media renderers, through their
/// AVTransport and RenderingControl services.
///
/// Renderers don't report changes unless subscribed to, so the player asks
/// for the state every second. The next track is lined up with
/// SetNextAVTransportURI where the renderer has it; where it doesn't, the
/// player starts the next track itself when the current one stops at its
/// end.
class DlnaPlayer implements RemotePlayer {
  DlnaPlayer._(this.device, this._client, this._transport, this._rendering);

  static const avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const renderingControl =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  /// Reads [device]'s description for its control addresses.
  static Future<DlnaPlayer> connect(
    OutputDevice device, {
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    final location = device.descriptionUrl;
    if (location == null) throw StateError('No device description');
    final reply = await c.get(location).timeout(const Duration(seconds: 5));
    if (reply.statusCode != 200) {
      throw StateError('Description returned ${reply.statusCode}');
    }
    final controls = dlnaControlUrls(
      utf8.decode(reply.bodyBytes, allowMalformed: true),
      location,
    );
    final transport = controls[avTransport];
    if (transport == null) throw StateError('No AVTransport service');
    final player = DlnaPlayer._(
      device,
      c,
      transport,
      controls[renderingControl],
    );
    player._poller = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(player._poll()),
    );
    return player;
  }

  @override
  final OutputDevice device;
  final http.Client _client;
  final Uri _transport;
  final Uri? _rendering;
  Timer? _poller;

  final _status = StreamController<RemoteStatus>.broadcast();
  final _advanced = StreamController<void>.broadcast();
  final _closed = Completer<void>();

  RemoteMedia? _current;
  RemoteMedia? _next;

  /// The renderer refused SetNextAVTransportURI, so the player moves on
  /// to the next track itself.
  bool _noNextSupport = false;

  RemoteState _state = RemoteState.idle;
  Duration _position = Duration.zero;
  Duration? _duration;
  double? _volume;
  bool _ended = false;
  bool _wasPlaying = false;
  final _sinceLoad = Stopwatch();
  bool _polling = false;
  int _failures = 0;
  int _ticks = 0;

  /// Commands in flight; polling waits so it doesn't read a half-done
  /// change.
  int _busy = 0;

  @override
  Stream<RemoteStatus> get status => _status.stream;
  @override
  Stream<void> get advanced => _advanced.stream;
  @override
  Future<void> get closed => _closed.future;

  Future<XmlDocument> _call(
    Uri url,
    String service,
    String action,
    Map<String, String> args,
  ) async {
    final body = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$service">',
      );
    args.forEach((k, v) => body.write('<$k>${_escape(v)}</$k>'));
    body.write('</u:$action></s:Body></s:Envelope>');
    final reply = await _client
        .post(
          url,
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPACTION': '"$service#$action"',
          },
          body: utf8.encode(body.toString()),
        )
        .timeout(const Duration(seconds: 5));
    final text = utf8.decode(reply.bodyBytes, allowMalformed: true);
    if (reply.statusCode != 200) {
      throw DlnaFault(action, reply.statusCode, text);
    }
    return XmlDocument.parse(text);
  }

  Future<XmlDocument> _transportCall(
    String action, [
    Map<String, String> args = const {},
  ]) => _call(_transport, avTransport, action, {'InstanceID': '0', ...args});

  Future<T> _command<T>(Future<T> Function() f) async {
    _busy++;
    try {
      return await f();
    } finally {
      _busy--;
    }
  }

  @override
  Future<void> load(
    RemoteMedia current, {
    RemoteMedia? next,
    Duration position = Duration.zero,
    bool play = true,
  }) => _command(() async {
    _current = current;
    _next = null;
    _ended = false;
    _wasPlaying = false;
    _sinceLoad
      ..reset()
      ..start();
    _position = position;
    _duration = current.duration;
    _state = RemoteState.buffering;
    _publish();
    // Some renderers refuse a new track while one is playing.
    try {
      await _transportCall('Stop');
    } on Object {
      // Nothing was playing.
    }
    await _transportCall('SetAVTransportURI', {
      'CurrentURI': current.url.toString(),
      'CurrentURIMetaData': didl(current),
    });
    if (play || position > Duration.zero) {
      await _transportCall('Play', {'Speed': '1'});
      if (position > const Duration(seconds: 1)) {
        // Many renderers (Samsung TVs among them) refuse a seek until the
        // track is actually playing.
        await _untilPlaying();
        await _trySeek(position);
      }
      if (!play) await _transportCall('Pause');
    }
    _state = play ? RemoteState.playing : RemoteState.paused;
    _wasPlaying = play;
    await _lineUp(next);
  });

  @override
  Future<void> setNext(RemoteMedia? next) => _command(() => _lineUp(next));

  Future<void> _lineUp(RemoteMedia? next) async {
    _next = next;
    if (_noNextSupport || next == null) return;
    try {
      await _transportCall('SetNextAVTransportURI', {
        'NextURI': next.url.toString(),
        'NextURIMetaData': didl(next),
      });
    } on DlnaFault {
      // The player will start it itself when the current track ends.
      _noNextSupport = true;
    }
  }

  @override
  Future<void> play() => _command(() async {
    await _transportCall('Play', {'Speed': '1'});
    _state = RemoteState.playing;
    _wasPlaying = true;
    _publish();
  });

  @override
  Future<void> pause() => _command(() async {
    await _transportCall('Pause');
    _state = RemoteState.paused;
    _wasPlaying = false;
    _publish();
  });

  @override
  Future<void> seek(Duration position) => _command(() => _trySeek(position));

  /// Waits, up to a few seconds, for the renderer to report playing.
  Future<void> _untilPlaying() async {
    for (var i = 0; i < 20; i++) {
      try {
        final info = await _transportCall('GetTransportInfo');
        if (_text(info, 'CurrentTransportState') == 'PLAYING') return;
      } on DlnaFault {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Seeks, trying once more after a moment if the renderer refuses. A
  /// renderer that still won't seek carries on from where it is.
  Future<void> _trySeek(Duration position) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _seek(position);
        return;
      } on DlnaFault catch (e) {
        if (attempt > 0) {
          debugPrint('DLNA: the renderer would not seek ($e)');
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _seek(Duration position) async {
    _position = position;
    _publish();
    await _transportCall('Seek', {
      'Unit': 'REL_TIME',
      'Target': _clock(position),
    });
  }

  @override
  Future<void> stop() => _command(() async {
    _current = null;
    _next = null;
    _wasPlaying = false;
    _state = RemoteState.idle;
    _publish();
    await _transportCall('Stop');
  });

  @override
  Future<void> setVolume(double volume) async {
    final rendering = _rendering;
    if (rendering == null) return;
    _volume = volume.clamp(0.0, 1.0);
    await _call(rendering, renderingControl, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '${(_volume! * 100).round()}',
    });
  }

  Future<void> _poll() async {
    if (_polling || _busy > 0 || _closed.isCompleted) return;
    _polling = true;
    try {
      final info = await _transportCall('GetTransportInfo');
      final transport = _text(info, 'CurrentTransportState') ?? '';
      final pos = await _transportCall('GetPositionInfo');
      if (_busy > 0) return;
      _failures = 0;
      final uri = _text(pos, 'TrackURI');
      final rel = _parseClock(_text(pos, 'RelTime'));
      final dur = _parseClock(_text(pos, 'TrackDuration'));
      if (_ticks++ % 5 == 0) await _readVolume();

      final next = _next;
      if (next != null && uri != null && uri == next.url.toString()) {
        // The renderer moved on to the lined-up track by itself.
        _current = next;
        _next = null;
        _advanced.add(null);
      }
      final last = _position;
      if (rel != null) _position = rel;
      if (dur != null && dur > Duration.zero) _duration = dur;
      final stopped = transport == 'STOPPED' || transport == 'NO_MEDIA_PRESENT';
      // Renderers pass through STOPPED while starting a track, so only a
      // stop near the end, a while after loading, counts as finishing.
      final nearEnd =
          _duration == null || last >= _duration! - const Duration(seconds: 5);
      if (stopped &&
          _wasPlaying &&
          _current != null &&
          nearEnd &&
          _sinceLoad.elapsed > const Duration(seconds: 3)) {
        final pending = _next;
        if (pending != null) {
          await _startNext(pending);
          return;
        }
        _ended = true;
        _wasPlaying = false;
      }
      _state = switch (transport) {
        'PLAYING' => RemoteState.playing,
        'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => RemoteState.paused,
        'TRANSITIONING' => RemoteState.buffering,
        _ => RemoteState.idle,
      };
      if (_state == RemoteState.playing) {
        _wasPlaying = true;
        _ended = false;
      }
      _publish();
    } on Object catch (e) {
      // Three misses in a row: the renderer has gone.
      if (++_failures >= 3) {
        debugPrint('DLNA: the renderer stopped answering ($e)');
        await close(stopPlayback: false);
      }
    } finally {
      _polling = false;
    }
  }

  /// Starts [next] after the current track ended, for renderers that
  /// can't line it up themselves.
  Future<void> _startNext(RemoteMedia next) async {
    await load(next);
    _advanced.add(null);
  }

  Future<void> _readVolume() async {
    final rendering = _rendering;
    if (rendering == null) return;
    try {
      final doc = await _call(rendering, renderingControl, 'GetVolume', {
        'InstanceID': '0',
        'Channel': 'Master',
      });
      final v = int.tryParse(_text(doc, 'CurrentVolume') ?? '');
      if (v != null) _volume = v / 100;
    } on Object {
      // Some renderers don't report volume.
    }
  }

  void _publish() {
    if (_status.isClosed) return;
    _status.add(
      RemoteStatus(
        state: _state,
        position: _position,
        duration: _duration,
        ended: _ended,
        volume: _volume,
      ),
    );
  }

  @override
  Future<void> close({bool stopPlayback = true}) async {
    if (_closed.isCompleted) return;
    _poller?.cancel();
    if (stopPlayback) {
      try {
        await _transportCall('Stop');
      } on Object {
        // Gone already.
      }
    }
    _closed.complete();
    _client.close();
    await _status.close();
    await _advanced.close();
  }

  static String? _text(XmlDocument doc, String name) {
    final e = doc.findAllElements(name).firstOrNull;
    return e?.innerText.trim();
  }
}

/// A SOAP fault or HTTP error from a renderer.
class DlnaFault implements Exception {
  final String action;
  final int status;
  final String body;
  const DlnaFault(this.action, this.status, this.body);

  @override
  String toString() => 'DlnaFault($action, HTTP $status)';
}

/// The control URL of each service in a device description, resolved
/// against its base address.
Map<String, Uri> dlnaControlUrls(String xml, Uri location) {
  final doc = XmlDocument.parse(xml);
  final baseText = doc.findAllElements('URLBase').firstOrNull?.innerText.trim();
  final base = (baseText == null || baseText.isEmpty)
      ? location
      : Uri.parse(baseText);
  final out = <String, Uri>{};
  for (final s in doc.findAllElements('service')) {
    final type = s.getElement('serviceType')?.innerText.trim();
    final control = s.getElement('controlURL')?.innerText.trim();
    if (type == null || control == null) continue;
    // Match on the service name; renderers may offer version 2 or 3.
    final name = type.replaceFirst(RegExp(r':\d+$'), ':1');
    out.putIfAbsent(name, () => base.resolve(control));
  }
  return out;
}

/// DIDL-Lite metadata for [m], which renderers use for their display and
/// many need before they'll play at all.
String didl(RemoteMedia m) {
  final e = _escape;
  final art = m.artwork == null
      ? ''
      : '<upnp:albumArtURI>${e(m.artwork.toString())}</upnp:albumArtURI>';
  final duration = m.duration == null
      ? ''
      : ' duration="${_clock(m.duration!)}.000"';
  return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="oamp" parentID="0" restricted="1">'
      '<dc:title>${e(m.title)}</dc:title>'
      '${m.artist == null ? '' : '<upnp:artist>${e(m.artist!)}</upnp:artist>'}'
      '${m.album == null ? '' : '<upnp:album>${e(m.album!)}</upnp:album>'}'
      '$art'
      '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
      '<res protocolInfo="${protocolInfo(m)}"$duration>'
      '${e(m.url.toString())}</res>'
      '</item></DIDL-Lite>';
}

/// How a renderer may fetch [m]. Without the DLNA.ORG_OP flags many
/// renderers (Samsung TVs among them) assume the server can't seek and
/// refuse every seek. Original files are served with byte ranges;
/// transcoded streams are not.
String protocolInfo(RemoteMedia m) {
  final op = m.transcoded ? '00' : '01';
  final ci = m.transcoded ? '1' : '0';
  // Streaming transfer mode, background transfer, DLNA 1.5.
  const flags = '01700000000000000000000000000000';
  return 'http-get:*:${m.contentType}:'
      'DLNA.ORG_OP=$op;DLNA.ORG_CI=$ci;DLNA.ORG_FLAGS=$flags';
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// H:MM:SS, as UPnP writes times.
String _clock(Duration d) {
  final s = d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}';
}

/// Reads H:MM:SS(.fff). Null for NOT_IMPLEMENTED and the like.
Duration? _parseClock(String? s) {
  if (s == null) return null;
  final m = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+))?').firstMatch(s);
  if (m == null) return null;
  final ms = m.group(4) == null
      ? 0
      : int.parse(m.group(4)!.padRight(3, '0').substring(0, 3));
  return Duration(
    hours: int.parse(m.group(1)!),
    minutes: int.parse(m.group(2)!),
    seconds: int.parse(m.group(3)!),
    milliseconds: ms,
  );
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/output_device.dart';
import '../../core/remote_player.dart';
import 'cast_channel.dart';

/// [RemotePlayer] for Google Cast devices, through Google's Default Media
/// Receiver.
///
/// The receiver keeps a small queue: the current item and the one OAmp
/// lined up after it, so the device moves on by itself without a gap.
class CastPlayer implements RemotePlayer {
  CastPlayer._(this.device, this._channel);

  /// Google's Default Media Receiver, which needs no registration.
  static const defaultReceiver = 'CC1AD845';

  /// Connects to [device] and starts (or joins) the receiver app.
  static Future<CastPlayer> connect(
    OutputDevice device, {
    Future<CastChannel> Function(String host, int port)? open,
  }) async {
    final channel = await (open ?? CastChannel.connect)(
      device.host,
      device.port,
    );
    final player = CastPlayer._(device, channel);
    try {
      await player._start();
    } on Object {
      await channel.close();
      rethrow;
    }
    return player;
  }

  @override
  final OutputDevice device;
  final CastChannel _channel;

  final _status = StreamController<RemoteStatus>.broadcast();
  final _advanced = StreamController<void>.broadcast();
  late final StreamSubscription<CastMessage> _sub;
  Timer? _ticker;

  String? _sessionId;
  String? _transportId;
  int? _mediaSessionId;
  int? _currentItem;
  int? _nextItem;
  List<int> _itemIds = const [];

  RemoteState _state = RemoteState.idle;
  Duration _position = Duration.zero;
  final _since = Stopwatch();
  Duration? _duration;
  double? _volume;
  bool _ended = false;

  /// The last load, so a status for an older one is not taken as news.
  Completer<void>? _loading;

  @override
  Stream<RemoteStatus> get status => _status.stream;
  @override
  Stream<void> get advanced => _advanced.stream;
  @override
  Future<void> get closed => _channel.closed;

  Future<void> _start() async {
    _sub = _channel.messages.listen(_onMessage);
    unawaited(_channel.closed.then((_) => _shutDown()));
    var receiver = await _channel.request(
      CastChannel.receiverId,
      CastChannel.receiverNs,
      {'type': 'GET_STATUS'},
    );
    if (!_takeApp(receiver)) {
      receiver = await _channel.request(
        CastChannel.receiverId,
        CastChannel.receiverNs,
        {'type': 'LAUNCH', 'appId': defaultReceiver},
        timeout: const Duration(seconds: 20),
      );
      if (!_takeApp(receiver)) {
        throw StateError('The device did not start the receiver');
      }
    }
    _channel.send(_transportId!, CastChannel.connectionNs, {'type': 'CONNECT'});
    await _mediaRequest({'type': 'GET_STATUS'});
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      _publish();
      // The receiver only reports changes, so check in now and then.
      if (t.tick % 10 == 0) unawaited(_checkIn());
    });
  }

  Future<void> _checkIn() async {
    try {
      await _mediaRequest({'type': 'GET_STATUS'});
    } on Object {
      // The heartbeat notices if the device has gone.
    }
  }

  /// Picks the Default Media Receiver out of a RECEIVER_STATUS reply.
  bool _takeApp(CastMessage m) {
    final status = m.payload['status'];
    if (status is! Map) return false;
    _readVolume(status);
    final apps = status['applications'];
    if (apps is! List) return false;
    for (final app in apps) {
      if (app is Map && app['appId'] == defaultReceiver) {
        _sessionId = app['sessionId'] as String?;
        _transportId = app['transportId'] as String?;
        return _transportId != null;
      }
    }
    return false;
  }

  void _readVolume(Map status) {
    final volume = status['volume'];
    if (volume is Map) {
      final muted = volume['muted'] == true;
      final level = (volume['level'] as num?)?.toDouble();
      if (level != null) _volume = muted ? 0 : level;
    }
  }

  Future<CastMessage> _mediaRequest(Map<String, dynamic> body) =>
      _channel.request(_transportId!, CastChannel.mediaNs, {
        ...body,
        if (_mediaSessionId != null &&
            !const {'LOAD', 'QUEUE_LOAD', 'GET_STATUS'}.contains(body['type']))
          'mediaSessionId': _mediaSessionId,
      });

  void _onMessage(CastMessage m) {
    if (m.namespace == CastChannel.receiverNs && m.type == 'RECEIVER_STATUS') {
      final status = m.payload['status'];
      if (status is Map) {
        _readVolume(status);
        final apps = status['applications'];
        final ours =
            apps is List &&
            apps.any((a) => a is Map && a['sessionId'] == _sessionId);
        // Someone cast something else to it: our session is over.
        if (!ours && _sessionId != null) {
          debugPrint('Cast: the receiver app was closed or replaced');
          unawaited(_channel.close());
          return;
        }
      }
      _publish();
      return;
    }
    if (m.namespace != CastChannel.mediaNs) return;
    switch (m.type) {
      case 'MEDIA_STATUS':
        final list = m.payload['status'];
        if (list is List && list.isNotEmpty && list.first is Map) {
          _onMediaStatus(list.first as Map);
        } else if (list is List && list.isEmpty) {
          _mediaSessionId = null;
          _state = RemoteState.idle;
          _publish();
        }
      case 'QUEUE_ITEM_IDS':
        final ids = m.payload['itemIds'];
        if (ids is List) _setItems([for (final i in ids) (i as num).toInt()]);
      case 'LOAD_FAILED' || 'LOAD_CANCELLED' || 'INVALID_REQUEST':
        debugPrint('Cast: ${m.type} (${m.payload['reason'] ?? ''})');
    }
  }

  void _setItems(List<int> ids) {
    _itemIds = ids;
    final at = _currentItem == null ? -1 : ids.indexOf(_currentItem!);
    _nextItem = at >= 0 && at + 1 < ids.length ? ids[at + 1] : null;
  }

  void _onMediaStatus(Map s) {
    _mediaSessionId = (s['mediaSessionId'] as num?)?.toInt() ?? _mediaSessionId;
    final items = s['items'];
    if (items is List) {
      _itemIds = [
        for (final i in items)
          if (i is Map && i['itemId'] is num) (i['itemId'] as num).toInt(),
      ];
    }
    final current = (s['currentItemId'] as num?)?.toInt();
    if (current != null && current != _currentItem) {
      final movedOn = _currentItem != null && current == _nextItem;
      _currentItem = current;
      _setItems(_itemIds);
      if (movedOn) {
        _ended = false;
        _advanced.add(null);
      }
    } else if (items is List) {
      _setItems(_itemIds);
    }
    final media = s['media'];
    if (media is Map) {
      final d = (media['duration'] as num?)?.toDouble();
      if (d != null && d > 0) _duration = _seconds(d);
    }
    final time = (s['currentTime'] as num?)?.toDouble();
    if (time != null) {
      _position = _seconds(time);
      _since
        ..reset()
        ..start();
    }
    _state = switch (s['playerState']) {
      'PLAYING' => RemoteState.playing,
      'PAUSED' => RemoteState.paused,
      'BUFFERING' => RemoteState.buffering,
      _ => RemoteState.idle,
    };
    if (_state == RemoteState.idle) {
      final reason = s['idleReason'];
      if (reason == 'FINISHED' && _nextItem == null && _loading == null) {
        _ended = true;
      } else if (reason == 'ERROR') {
        debugPrint('Cast: the device could not play the track');
      }
    } else {
      _ended = false;
    }
    final volume = s['volume'];
    if (volume is Map) _readVolume({'volume': volume});
    _publish();
  }

  static Duration _seconds(double s) =>
      Duration(milliseconds: (s * 1000).round());

  Duration get _now =>
      _state == RemoteState.playing ? _position + _since.elapsed : _position;

  void _publish() {
    if (_status.isClosed) return;
    var position = _now;
    if (_duration != null && position > _duration!) position = _duration!;
    _status.add(
      RemoteStatus(
        state: _state,
        position: position,
        duration: _duration,
        ended: _ended,
        volume: _volume,
      ),
    );
  }

  static Map<String, dynamic> _item(RemoteMedia m, {bool autoplay = true}) => {
    'media': {
      'contentId': m.url.toString(),
      'contentUrl': m.url.toString(),
      'contentType': m.contentType,
      'streamType': 'BUFFERED',
      if (m.duration != null) 'duration': m.duration!.inMilliseconds / 1000,
      'metadata': {
        'metadataType': 3, // MUSIC_TRACK
        'title': m.title,
        if (m.artist != null) 'artist': m.artist,
        if (m.album != null) 'albumName': m.album,
        if (m.artwork != null)
          'images': [
            {'url': m.artwork.toString()},
          ],
      },
    },
    'autoplay': autoplay,
    // Fetch the next track this many seconds before the current one ends.
    'preloadTime': 20,
  };

  @override
  Future<void> load(
    RemoteMedia current, {
    RemoteMedia? next,
    Duration position = Duration.zero,
    bool play = true,
  }) async {
    final loading = _loading = Completer<void>();
    _ended = false;
    _state = RemoteState.buffering;
    _position = position;
    _duration = current.duration;
    _currentItem = null;
    _nextItem = null;
    _publish();
    try {
      final reply = await _mediaRequest({
        'type': 'QUEUE_LOAD',
        'items': [
          _item(current, autoplay: play),
          if (next != null) _item(next),
        ],
        'startIndex': 0,
        'currentTime': position.inMilliseconds / 1000,
        'repeatMode': 'REPEAT_OFF',
      });
      if (reply.type != 'MEDIA_STATUS') {
        throw StateError('The device refused the track (${reply.type})');
      }
      // The reply carries the new media session. Take it now: the same
      // message reaches the status listener only after this resumes, and
      // the next request would still carry the old session's id.
      final list = reply.payload['status'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final id = ((list.first as Map)['mediaSessionId'] as num?)?.toInt();
        if (id != null) _mediaSessionId = id;
      }
      await _refreshItems();
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
  }

  Future<void> _refreshItems() async {
    try {
      final reply = await _mediaRequest({'type': 'QUEUE_GET_ITEM_IDS'});
      final ids = reply.payload['itemIds'];
      if (ids is List) _setItems([for (final i in ids) (i as num).toInt()]);
    } on TimeoutException {
      // Older receivers: the item list comes with the next status instead.
    }
  }

  @override
  Future<void> setNext(RemoteMedia? next) async {
    if (_mediaSessionId == null) return;
    final old = _nextItem;
    if (old != null) {
      _nextItem = null;
      await _mediaRequest({
        'type': 'QUEUE_REMOVE',
        'itemIds': [old],
      });
    }
    // Drop tracks already played so the receiver's queue stays short.
    final played = _currentItem == null
        ? const <int>[]
        : _itemIds.takeWhile((i) => i != _currentItem).toList();
    if (played.isNotEmpty) {
      await _mediaRequest({'type': 'QUEUE_REMOVE', 'itemIds': played});
    }
    if (next != null) {
      await _mediaRequest({
        'type': 'QUEUE_INSERT',
        'items': [_item(next)],
      });
    }
    await _refreshItems();
  }

  Future<void> _command(String type, [Map<String, dynamic>? extra]) async {
    if (_mediaSessionId == null) return;
    await _mediaRequest({'type': type, ...?extra});
  }

  @override
  Future<void> play() => _command('PLAY');

  @override
  Future<void> pause() => _command('PAUSE');

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    _since
      ..reset()
      ..start();
    _publish();
    await _command('SEEK', {'currentTime': position.inMilliseconds / 1000});
  }

  @override
  Future<void> stop() async {
    await _command('STOP');
    _mediaSessionId = null;
    _currentItem = null;
    _nextItem = null;
    _state = RemoteState.idle;
    _publish();
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    _channel.send(CastChannel.receiverId, CastChannel.receiverNs, {
      'type': 'SET_VOLUME',
      'volume': {'level': _volume},
      'requestId': 0,
    });
  }

  @override
  Future<void> close({bool stopPlayback = true}) async {
    if (stopPlayback && _sessionId != null && !_channel.isClosed) {
      try {
        await _channel.request(CastChannel.receiverId, CastChannel.receiverNs, {
          'type': 'STOP',
          'sessionId': _sessionId,
        }, timeout: const Duration(seconds: 3));
      } on Object {
        // Closing anyway.
      }
    }
    await _channel.close();
    await _shutDown();
  }

  Future<void> _shutDown() async {
    _ticker?.cancel();
    if (_status.isClosed) return;
    await _sub.cancel();
    await _status.close();
    await _advanced.close();
  }
}

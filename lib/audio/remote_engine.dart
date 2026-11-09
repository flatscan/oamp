import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/remote_player.dart';
import 'audio_engine.dart';

/// [AudioEngine] that plays on a speaker or TV through a [RemotePlayer].
///
/// The queue stays here, as it does for local playback. The device only
/// ever holds the current track and the one after it; when it moves on by
/// itself the engine lines up the next one, so albums carry on without a
/// gap even while the app is busy. The URIs the player hands over are the
/// app's own (often its local cache), so the engine asks [QueueInfo] for
/// what the device should fetch instead.
///
/// Crossfade, gapless switching, ReplayGain and ducking are local playback
/// features; here they do nothing.
class RemoteEngine implements AudioEngine {
  RemoteEngine(this.player) {
    _subs = [
      player.status.listen(_onStatus),
      player.advanced.listen((_) => _onAdvanced()),
    ];
  }

  final RemotePlayer player;
  late final List<StreamSubscription<void>> _subs;

  final _state = StreamController<EngineState>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();

  int _length = 0;
  int? _index;
  PlaybackRepeat _repeat = PlaybackRepeat.off;
  QueueInfo? _info;

  /// What the device has lined up after the current track, as indexes, so
  /// a queue edit only reaches the device when that changes.
  int? _lined;

  RemoteStatus _status = const RemoteStatus();
  bool _completed = false;

  /// Whether the listener asked to play (and has not paused since). The
  /// device is told again when a track has to be loaded.
  bool _wantPlay = false;

  /// The device turned an original file down, so for the rest of the
  /// session it gets the server's MP3 instead.
  bool _transcode = false;

  /// The first load (starting playback on the device) reports failure to
  /// whoever connected; later ones only log it.
  bool _started = false;
  bool _recovering = false;

  /// Runs a device command for the listener: a device that doesn't answer
  /// is logged, never an uncaught error. (A device that has gone away is
  /// noticed by its connection closing.)
  Future<void> _quietly(Future<void> Function() command, String what) async {
    try {
      await command();
    } on Object catch (e) {
      debugPrint('Casting: $what failed ($e)');
    }
  }

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  Duration get position => _status.position;

  /// The device's own volume, when it has said.
  double? get deviceVolume => _status.volume;

  @override
  set queueInfo(QueueInfo? info) => _info = info;

  RemoteMedia? _media(int? i) {
    final m = i == null
        ? null
        : _info?.remoteMediaAt(i, player.device.protocol);
    return _transcode ? (m?.fallback ?? m) : m;
  }

  int? _nextIndex(int? from) {
    if (from == null || _length == 0) return null;
    if (_repeat == PlaybackRepeat.one) return from;
    if (from + 1 < _length) return from + 1;
    return _repeat == PlaybackRepeat.all ? 0 : null;
  }

  void _emit() {
    if (_state.isClosed) return;
    final s = _status.state;
    _state.add(
      EngineState(
        // While the listener wants it playing, a device between tracks
        // (idle or buffering for a moment) still counts as playing, so the
        // app and the OS media controls don't flicker to paused. On
        // Android that flicker drops the media service out of the
        // foreground, and it can't come back while the app is in the
        // background.
        playing: !_completed && (_wantPlay || s == RemoteState.playing),
        buffering: s == RemoteState.buffering,
        completed: _completed,
        currentIndex: _index,
      ),
    );
  }

  void _onStatus(RemoteStatus s) {
    final before = _status.state;
    _status = s;
    if (s.failed) {
      // A track the device moved on to by itself was turned down.
      unawaited(_recover(s.position));
      return;
    }
    if (s.ended) {
      _completed = true;
      _wantPlay = false;
    } else if (s.state != before) {
      // Paused or resumed with the device's own buttons or remote.
      if (s.state == RemoteState.paused && before == RemoteState.playing) {
        _wantPlay = false;
      } else if (s.state == RemoteState.playing) {
        _wantPlay = true;
      }
    }
    _position.add(s.position);
    _duration.add(s.duration ?? _info?.durationAt(_index ?? -1));
    _emit();
  }

  void _onAdvanced() {
    _index = _lined;
    _lined = null;
    _completed = false;
    _emit();
    unawaited(_lineUp());
  }

  /// Tells the device what comes after the current track, if that changed.
  Future<void> _lineUp() async {
    final next = _nextIndex(_index);
    if (next == _lined) return;
    _lined = next;
    await _quietly(() => player.setNext(_media(next)), 'lining up a track');
  }

  /// After the device couldn't play the current track: try the MP3, or
  /// stop there if that was the MP3 already.
  Future<void> _recover(Duration position) async {
    final i = _index;
    if (i == null || _recovering) return;
    if (_transcode ||
        _info?.remoteMediaAt(i, player.device.protocol)?.fallback == null) {
      debugPrint('Casting: the device could not play the track');
      _wantPlay = false;
      _emit();
      return;
    }
    _transcode = true;
    debugPrint('Casting: the device turned the file down; sending MP3');
    _recovering = true;
    try {
      await _tryLoad(i, position: position);
    } finally {
      _recovering = false;
    }
  }

  /// [_load] for the listener's own actions: a failure is logged and
  /// leaves playback paused, rather than surfacing as an uncaught error.
  Future<void> _tryLoad(int index, {Duration position = Duration.zero}) async {
    try {
      await _load(index, position: position);
    } on Object catch (e) {
      debugPrint('Casting: loading a track failed ($e)');
      _wantPlay = false;
      _emit();
    }
  }

  /// Loads the entry at [index] on the device. When the device turns the
  /// original file down, tries the server's MP3 once.
  Future<void> _load(int index, {Duration position = Duration.zero}) async {
    try {
      await _loadOnce(index, position: position);
    } on RemoteMediaError {
      if (_transcode ||
          _info?.remoteMediaAt(index, player.device.protocol)?.fallback ==
              null) {
        rethrow;
      }
      _transcode = true;
      debugPrint('Casting: the device turned the file down; sending MP3');
      await _loadOnce(index, position: position);
    }
  }

  Future<void> _loadOnce(int index, {Duration position = Duration.zero}) async {
    final media = _media(index);
    if (media == null) return;
    _index = index;
    _completed = false;
    // Until the device reports, it is fetching the track at [position].
    _status = RemoteStatus(state: RemoteState.buffering, position: position);
    final next = _nextIndex(index);
    _lined = next;
    _emit();
    await player.load(
      media,
      next: _media(next),
      position: position,
      play: _wantPlay,
    );
  }

  @override
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    _length = uris.length;
    _wantPlay = false;
    if (_length == 0) return clear();
    final index = initialIndex.clamp(0, _length - 1);
    if (_started) return _tryLoad(index, position: initialPosition);
    _started = true;
    await _load(index, position: initialPosition);
  }

  @override
  Future<void> addAll(List<Uri> uris) async {
    _length += uris.length;
    await _lineUp();
  }

  @override
  Future<void> insertAll(int index, List<Uri> uris) async {
    _length += uris.length;
    final cur = _index;
    if (cur != null && index <= cur) _index = cur + uris.length;
    if (_lined != null && index <= _lined!) _lined = _lined! + uris.length;
    await _lineUp();
  }

  @override
  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _length) return;
    _length--;
    final cur = _index;
    if (_lined == index) {
      _lined = -1; // gone: forces the device to be told again
    } else if (_lined != null && index < _lined!) {
      _lined = _lined! - 1;
    }
    if (cur == null) return;
    if (index < cur) {
      _index = cur - 1;
    } else if (index == cur) {
      if (_length == 0) return clear();
      // The next entry slides into this place and plays as it was.
      await _tryLoad(cur < _length ? cur : 0);
      return;
    }
    await _lineUp();
  }

  @override
  Future<void> move(int from, int to) async {
    int shift(int i) {
      if (i == from) return to;
      if (from < i && i <= to) return i - 1;
      if (to <= i && i < from) return i + 1;
      return i;
    }

    if (_index != null) _index = shift(_index!);
    if (_lined != null && _lined! >= 0) _lined = shift(_lined!);
    await _lineUp();
  }

  @override
  Future<void> clear() async {
    _length = 0;
    _index = null;
    _lined = null;
    _wantPlay = false;
    _completed = false;
    _emit();
    await _quietly(player.stop, 'stopping');
  }

  @override
  Future<void> play() async {
    _wantPlay = true;
    final i = _index;
    if (i == null) return;
    if (_completed || _status.state == RemoteState.idle) {
      // Finished, or the device dropped the track: start it again.
      await _tryLoad(
        _completed ? 0 : i,
        position: _completed ? Duration.zero : _status.position,
      );
    } else {
      _emit();
      await _quietly(player.play, 'play');
    }
  }

  @override
  Future<void> pause() async {
    _wantPlay = false;
    _emit();
    await _quietly(player.pause, 'pause');
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    if (index != null && index != _index) {
      if (index < 0 || index >= _length) return;
      return _tryLoad(index, position: position);
    }
    if (_completed && _index != null) {
      return _tryLoad(_index!, position: position);
    }
    await _quietly(() => player.seek(position), 'seeking');
  }

  @override
  Future<void> next() async {
    final cur = _index;
    if (cur == null) return;
    final n = cur + 1 < _length
        ? cur + 1
        : (_repeat == PlaybackRepeat.all ? 0 : null);
    if (n != null) await _tryLoad(n);
  }

  @override
  Future<void> previous() async {
    final cur = _index;
    if (cur == null) return;
    await _tryLoad(
      cur > 0 ? cur - 1 : (_repeat == PlaybackRepeat.all ? _length - 1 : 0),
    );
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeat mode) async {
    _repeat = mode;
    await _lineUp();
  }

  @override
  Future<void> setVolume(double volume) =>
      _quietly(() => player.setVolume(volume), 'setting the volume');

  @override
  Future<void> refreshGain() async {}
  @override
  Future<void> setGapless(bool enabled) async {}
  @override
  Future<void> setDucked(bool ducked) async {}
  @override
  Future<void> setCrossfade(Duration duration) async {}

  /// Doesn't wait for listeners to finish: a paused one would hold it up.
  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_state.close());
    unawaited(_position.close());
    unawaited(_duration.close());
  }
}

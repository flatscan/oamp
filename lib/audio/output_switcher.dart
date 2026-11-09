import 'dart:async';

import '../core/models.dart';
import 'audio_engine.dart';

/// The [AudioEngine] the player talks to: local playback, or a speaker or
/// TV while casting.
///
/// It keeps its own copy of the queue's URIs and settings, so when the
/// output changes it can load the new one at the same track and position
/// and the player never notices. Streams follow whichever output is
/// active.
class OutputSwitcher implements AudioEngine {
  OutputSwitcher(this.local) : _active = local {
    _follow(local);
  }

  /// This device's own playback.
  final AudioEngine local;
  AudioEngine _active;

  final List<Uri> _uris = [];
  PlaybackRepeat _repeat = PlaybackRepeat.off;
  QueueInfo? _info;
  double _localVolume = 1;
  bool _gapless = true;
  Duration _crossfade = Duration.zero;
  EngineState _last = const EngineState();

  final _state = StreamController<EngineState>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final List<StreamSubscription<void>> _subs = [];

  /// The output in use: [local], or a cast engine.
  AudioEngine get active => _active;
  bool get isRemote => !identical(_active, local);

  /// The last state the active output reported.
  EngineState get lastState => _last;

  void _follow(AudioEngine e) {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs
      ..clear()
      ..add(
        e.stateStream.listen((s) {
          _last = s;
          _state.add(s);
        }),
      )
      ..add(e.positionStream.listen(_position.add))
      ..add(e.durationStream.listen(_duration.add));
  }

  /// Moves playback to [to] (null for this device) at the current track
  /// and position. Playback carries on when it was playing and [play] is
  /// true; otherwise the new output holds it paused there.
  ///
  /// [at] overrides the position, for when the old output can no longer
  /// say (a device that just dropped off the network).
  Future<void> switchTo(
    AudioEngine? to, {
    bool play = true,
    Duration? at,
  }) async {
    final target = to ?? local;
    if (identical(target, _active)) return;
    final from = _active;
    final index = _last.currentIndex;
    final wasPlaying = _last.playing;
    final position = at ?? from.position;

    _active = target;
    _follow(target);
    // Leaving local playback releases its streams; leaving a device
    // stops it. Errors from a device that is already gone don't matter.
    try {
      if (identical(from, local)) {
        await from.clear();
      } else {
        await from.pause().timeout(const Duration(seconds: 3));
      }
    } on Object {
      // Carry on with the switch.
    }

    target.queueInfo = _info;
    await target.setRepeatMode(_repeat);
    if (identical(target, local)) {
      await local.setVolume(_localVolume);
      await local.setGapless(_gapless);
      await local.setCrossfade(_crossfade);
    }
    if (_uris.isEmpty || index == null) {
      _last = const EngineState();
      _state.add(_last);
      return;
    }
    await target.setQueue(
      List.of(_uris),
      initialIndex: index.clamp(0, _uris.length - 1),
      initialPosition: position,
    );
    if (wasPlaying && play) await target.play();
  }

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  Duration get position => _active.position;

  @override
  set queueInfo(QueueInfo? info) {
    _info = info;
    _active.queueInfo = info;
  }

  @override
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) {
    _uris
      ..clear()
      ..addAll(uris);
    return _active.setQueue(
      uris,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
  }

  @override
  Future<void> addAll(List<Uri> uris) {
    _uris.addAll(uris);
    return _active.addAll(uris);
  }

  @override
  Future<void> insertAll(int index, List<Uri> uris) {
    _uris.insertAll(index, uris);
    return _active.insertAll(index, uris);
  }

  @override
  Future<void> removeAt(int index) {
    if (index >= 0 && index < _uris.length) _uris.removeAt(index);
    return _active.removeAt(index);
  }

  @override
  Future<void> move(int from, int to) {
    if (from >= 0 && from < _uris.length && to >= 0 && to < _uris.length) {
      _uris.insert(to, _uris.removeAt(from));
    }
    return _active.move(from, to);
  }

  @override
  Future<void> clear() {
    _uris.clear();
    return _active.clear();
  }

  @override
  Future<void> play() => _active.play();
  @override
  Future<void> pause() => _active.pause();
  @override
  Future<void> seek(Duration position, {int? index}) =>
      _active.seek(position, index: index);
  @override
  Future<void> next() => _active.next();
  @override
  Future<void> previous() => _active.previous();

  @override
  Future<void> setRepeatMode(PlaybackRepeat mode) {
    _repeat = mode;
    return _active.setRepeatMode(mode);
  }

  /// This device's own volume. While casting it is kept for when playback
  /// comes back; the speaker or TV's volume is set through its engine.
  @override
  Future<void> setVolume(double volume) async {
    _localVolume = volume;
    if (!isRemote) await local.setVolume(volume);
  }

  @override
  Future<void> refreshGain() => _active.refreshGain();

  @override
  Future<void> setGapless(bool enabled) {
    _gapless = enabled;
    return _active.setGapless(enabled);
  }

  @override
  Future<void> setDucked(bool ducked) => _active.setDucked(ducked);

  @override
  Future<void> setCrossfade(Duration duration) {
    _crossfade = duration;
    return _active.setCrossfade(duration);
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _state.close();
    await _position.close();
    await _duration.close();
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/models.dart';

/// Snapshot of what the engine is doing, independent of the backend.
class EngineState {
  final bool playing;
  final bool buffering;
  final bool completed;
  final int? currentIndex;

  const EngineState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.currentIndex,
  });
}

/// What the engine needs to know about queue entries beyond their URIs.
/// The player answers from its queue, so the engine never sees [Track]s.
abstract class QueueInfo {
  /// Linear volume factor for the entry at [index], from ReplayGain.
  double gainAt(int index);

  /// Whether playback crossfades from entry [from] into entry [to].
  bool crossfadeBetween(int from, int to);

  /// The length the library gives for the entry at [index], used when the
  /// stream itself does not say (some transcoded streams).
  Duration? durationAt(int index);

  /// The most [gainAt] may raise a track, as a linear factor (1 when gain
  /// never raises). A deck that cannot play louder than normal turns every
  /// track down by this much instead, so quiet tracks still match loud ones.
  double get boostHeadroom;
}

/// The only interface the rest of the app uses to make sound.
///
/// Keeping playback behind this interface means switching backends is a
/// change to one implementation file, and a v2 cast engine can take over
/// the output without the queue moving.
abstract class AudioEngine {
  Stream<EngineState> get stateStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Duration get position;

  /// Loads [uris] paused at [initialIndex], [initialPosition] into it.
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  });
  Future<void> addAll(List<Uri> uris);
  Future<void> insertAll(int index, List<Uri> uris);
  Future<void> removeAt(int index);
  Future<void> move(int from, int to);
  Future<void> clear();

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position, {int? index});
  Future<void> next();
  Future<void> previous();
  Future<void> setRepeatMode(PlaybackRepeat mode);

  /// The listener's volume from 0 to 1, before ReplayGain.
  Future<void> setVolume(double volume);

  /// Where per-track gain and crossfade decisions come from.
  set queueInfo(QueueInfo? info);

  /// Re-reads the current entry's gain, after the ReplayGain settings change.
  Future<void> refreshGain();

  Future<void> setGapless(bool enabled);

  /// Turns playback down while another app briefly speaks over it (a
  /// navigation prompt, a notification), or back up again.
  Future<void> setDucked(bool ducked);

  /// How long tracks overlap at a natural track change. Zero turns
  /// crossfading off. Skipping by hand always cuts straight over.
  Future<void> setCrossfade(Duration duration);

  Future<void> dispose();
}

/// One player: a playlist and a single output. [MixingEngine] uses two of
/// them to crossfade. Implementations: [JustAudioDeck] (just_audio's
/// platform players) and `MpvDeck` (libmpv, used on Windows).
abstract class AudioDeck {
  Stream<EngineState> get stateStream;

  /// Playback failures, such as a stream cut off when the network dropped.
  /// The deck stops when one arrives; [MixingEngine] reopens the stream.
  Stream<Object> get errors;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Duration get position;
  Duration? get duration;
  int? get currentIndex;
  bool get playing;

  /// The highest value [setVolume] honours. Above 1 the deck can boost
  /// quiet tracks.
  double get maxVolume;

  /// Loads [uris] paused at [initialIndex], [initialPosition] into it.
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  });
  Future<void> addAll(List<Uri> uris);
  Future<void> insertAll(int index, List<Uri> uris);
  Future<void> removeAt(int index);
  Future<void> move(int from, int to);

  /// Stops and empties the playlist, releasing open streams.
  Future<void> clear();

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position, {int? index});
  Future<void> next();
  Future<void> previous();
  Future<void> setRepeatMode(PlaybackRepeat mode);
  Future<void> setVolume(double volume);
  Future<void> setGapless(bool enabled);
  Future<void> dispose();
}

/// [AudioEngine] that plays through one [AudioDeck] and borrows a second
/// for crossfades.
///
/// Normally only the active deck plays, with the whole queue loaded so
/// track changes are gapless. When a track nears its end and the next one
/// should crossfade, the spare deck loads the queue at the next track,
/// starts silent and fades up while the active one fades down; the spare
/// then becomes the active deck. Anything the listener does mid-fade
/// (pause, skip, seek, editing the queue around the current track) cuts
/// straight to the incoming track.
///
/// When the active deck reports a failure, such as a stream cut off by a
/// Wi-Fi or mobile data drop, the engine keeps the queue and reports
/// buffering while it reopens the track where it stopped, waiting longer
/// between each attempt ([retryDelays]). If the network is still gone after
/// that it pauses there, and play tries again.
class MixingEngine implements AudioEngine {
  MixingEngine(this._createDeck) : _active = _createDeck() {
    _follow(_active);
  }

  final AudioDeck Function() _createDeck;
  AudioDeck _active;
  AudioDeck? _spare;

  final List<Uri> _uris = [];
  PlaybackRepeat _repeat = PlaybackRepeat.off;
  double _volume = 1;
  bool _gapless = true;
  Duration _crossfade = Duration.zero;
  QueueInfo? _info;

  /// Bumped on every queue change, so a deck prepared for a crossfade
  /// against an older queue is never swapped in.
  int _version = 0;
  int? _preparedIndex;
  int _preparedVersion = -1;
  Future<void>? _preparing;
  _Fade? _fade;
  int? _lastIndex;

  /// How far [setDucked] turns playback down.
  static const duckLevel = 0.2;
  double _duck = 1;

  /// Waits before each attempt to reopen a failed stream, about a minute in
  /// all before the engine gives up and pauses.
  static const retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// A failure this soon after a stream was reopened is the same outage,
  /// so the waits carry on growing instead of starting again.
  static const sameOutage = Duration(seconds: 20);

  /// Whether the listener asked to play (and has not paused since).
  bool _wantPlay = false;

  /// Set from a failure until the stream is open again.
  _Failure? _failure;
  final _sinceRecovered = Stopwatch();
  int _lastAttempts = 0;

  /// While above zero the engine is loading the active deck itself, and a
  /// failure shows up as that load throwing.
  int _loading = 0;

  /// A crossfade into this entry could not be prepared, so the track change
  /// happens without one.
  (int, int)? _noFade;

  final _state = StreamController<EngineState>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final List<StreamSubscription> _subs = [];

  /// How often fade volumes are updated.
  static const fadeTick = Duration(milliseconds: 40);

  /// How far ahead of a crossfade the next track is loaded.
  static const prepareAhead = Duration(seconds: 8);

  /// Whether a crossfade is running, for tests.
  bool get isFading => _fade?.started ?? false;

  /// Whether a failed stream is being reopened (or waiting for play to
  /// try again), for tests.
  bool get isRecovering => _failure != null;

  void _follow(AudioDeck deck) {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs
      ..clear()
      ..add(
        deck.stateStream.listen((s) {
          // The deck is being reopened; [_failure] speaks for it meanwhile.
          if (_failure != null) return;
          _state.add(s);
          if (s.currentIndex != _lastIndex) {
            _lastIndex = s.currentIndex;
            if (_fade == null) unawaited(_applyGain());
          }
        }),
      )
      ..add(
        deck.positionStream.listen((p) {
          if (_failure != null) return;
          _position.add(p);
          _maybeCrossfade(p);
        }),
      )
      ..add(deck.durationStream.listen(_duration.add))
      ..add(deck.errors.listen(_onError));
  }

  void _onError(Object error) {
    debugPrint('Playback failed: $error');
    if (_loading > 0) return;
    unawaited(_fail());
  }

  /// Holds the queue at the failed entry and starts reopening it.
  Future<void> _fail({int? index, Duration? position}) async {
    if (_failure != null) return;
    await _finishFade();
    final at = index ?? _active.currentIndex ?? _lastIndex;
    if (at == null || at < 0 || at >= _uris.length) return;
    final f = _failure = _Failure(at, position ?? _active.position);
    if (_sinceRecovered.isRunning && _sinceRecovered.elapsed < sameOutage) {
      f.attempts = _lastAttempts;
    }
    _emitFailure();
    if (_wantPlay) _retryLater(f);
  }

  void _emitFailure() {
    final f = _failure;
    if (f == null) return;
    _state.add(
      EngineState(
        playing: _wantPlay,
        buffering: _wantPlay,
        currentIndex: f.index,
      ),
    );
  }

  void _retryLater(_Failure f, {bool now = false}) {
    f.timer?.cancel();
    f.timer = null;
    if (f.busy) {
      // The attempt under way checks for a new target when it finishes.
      if (now) f.again = true;
      return;
    }
    if (!now && f.attempts >= retryDelays.length) {
      // Still no stream: stop at the failed spot. Play tries again.
      _wantPlay = false;
      f.attempts = 0;
      _emitFailure();
      return;
    }
    f.timer = Timer(
      now ? Duration.zero : retryDelays[f.attempts],
      () => unawaited(_retry(f)),
    );
  }

  Future<void> _retry(_Failure f) async {
    if (!identical(_failure, f)) return;
    f
      ..timer = null
      ..busy = true
      ..again = false
      ..attempts += 1;
    final index = f.index;
    final position = f.position;
    final version = _version;
    var opened = false;
    _loading++;
    try {
      await _active.setVolume(_level(_active, index, 1));
      await _active.setQueue(
        List.of(_uris),
        initialIndex: index,
        initialPosition: position,
      );
      opened = true;
    } catch (e) {
      debugPrint('Reopening the stream failed: $e');
    } finally {
      _loading--;
      f.busy = false;
    }
    if (!identical(_failure, f)) return;
    final moved =
        f.again ||
        version != _version ||
        f.index != index ||
        f.position != position;
    if (moved) {
      _retryLater(f, now: true);
      return;
    }
    if (!opened) {
      if (_wantPlay) _retryLater(f);
      return;
    }
    _failure = null;
    _lastIndex = index;
    _lastAttempts = f.attempts;
    _sinceRecovered
      ..reset()
      ..start();
    if (_wantPlay) {
      await _active.play();
    } else {
      _state.add(EngineState(currentIndex: index));
    }
  }

  /// Moves a failure's target, and reopens there now if playing.
  void _retarget(int index, Duration position) {
    final f = _failure!;
    f
      ..index = index
      ..position = position
      ..attempts = 0;
    _emitFailure();
    if (_wantPlay) _retryLater(f, now: true);
  }

  void _dropFailure() {
    _failure?.timer?.cancel();
    _failure = null;
  }

  double _gain(int? index) {
    if (index == null || index < 0 || index >= _uris.length) return 1;
    return _info?.gainAt(index) ?? 1;
  }

  double _level(AudioDeck deck, int? index, double fade) {
    var level = _volume * _duck * _gain(index) * fade;
    // A deck that can't boost (Android's player) would cut every positive
    // gain off at normal volume; lower everything instead so tracks keep
    // their levels relative to each other.
    if (deck.maxVolume <= 1) level /= math.max(1, _info?.boostHeadroom ?? 1);
    return math.min(level, deck.maxVolume);
  }

  Future<void> _applyGain() =>
      _active.setVolume(_level(_active, _active.currentIndex, 1));

  int? _nextIndex(int cur) => switch (_repeat) {
    PlaybackRepeat.one => cur,
    _ when cur + 1 < _uris.length => cur + 1,
    PlaybackRepeat.all when _uris.isNotEmpty => 0,
    _ => null,
  };

  void _maybeCrossfade(Duration p) {
    if (_fade != null ||
        _failure != null ||
        _crossfade <= Duration.zero ||
        !_active.playing) {
      return;
    }
    final cur = _active.currentIndex;
    final dur =
        _active.duration ?? (cur == null ? null : _info?.durationAt(cur));
    if (cur == null || dur == null || dur < _crossfade * 2) return;
    final next = _nextIndex(cur);
    if (next == null || !(_info?.crossfadeBetween(cur, next) ?? true)) return;
    if (_noFade == (_version, next)) return;
    final remaining = dur - p;
    if (remaining <= _crossfade + prepareAhead &&
        (_preparedIndex != next || _preparedVersion != _version) &&
        _preparing == null) {
      _preparing = _prepare(next).whenComplete(() => _preparing = null);
    }
    if (remaining <= _crossfade && remaining > fadeTick * 3) {
      unawaited(_startFade(cur, next, remaining));
    }
  }

  /// Loads the queue into the spare deck, paused and silent at [index].
  /// If the next track cannot be opened (the network is down), the track
  /// change happens on the active deck as usual, without a crossfade.
  Future<void> _prepare(int index) async {
    final deck = _spare ??= _createDeck();
    final version = _version;
    try {
      await deck.setVolume(0);
      await deck.setGapless(_gapless);
      await deck.setRepeatMode(_repeat);
      await deck.setQueue(List.of(_uris), initialIndex: index);
    } catch (e) {
      debugPrint('Could not prepare the crossfade: $e');
      _noFade = (version, index);
      return;
    }
    if (version == _version) {
      _preparedIndex = index;
      _preparedVersion = version;
    }
  }

  Future<void> _startFade(int outIndex, int inIndex, Duration length) async {
    final fade = _fade = _Fade(_active, outIndex, inIndex, length);
    await _preparing;
    if (_preparedIndex != inIndex || _preparedVersion != _version) {
      await _prepare(inIndex);
    }
    final incoming = _spare!;
    if (fade.cancelled ||
        _failure != null ||
        _preparedIndex != inIndex ||
        _preparedVersion != _version) {
      if (identical(_fade, fade)) _fade = null;
      return;
    }
    await incoming.play();
    if (fade.cancelled) {
      await incoming.pause();
      return;
    }
    fade
      ..incoming = incoming
      ..started = true
      ..clock.start();
    _spare = fade.outgoing;
    _active = incoming;
    _preparedIndex = null;
    _lastIndex = inIndex;
    _follow(incoming);
    _state.add(
      EngineState(playing: true, currentIndex: inIndex, buffering: false),
    );
    _duration.add(incoming.duration);
    fade.timer = Timer.periodic(fadeTick, (_) => _fadeStep(fade));
    _fadeStep(fade);
  }

  void _fadeStep(_Fade fade) {
    final t = (fade.clock.elapsed.inMicroseconds / fade.length.inMicroseconds)
        .clamp(0.0, 1.0);
    // Equal power: the overall loudness stays level through the overlap.
    final up = math.sin(t * math.pi / 2);
    final down = math.cos(t * math.pi / 2);
    final out = fade.outgoing;
    final outMoved = out.currentIndex != fade.outIndex;
    unawaited(fade.incoming!.setVolume(_level(_active, fade.inIndex, up)));
    unawaited(out.setVolume(outMoved ? 0 : _level(out, fade.outIndex, down)));
    if (t >= 1) unawaited(_finishFade());
  }

  /// Ends a running crossfade now: the outgoing deck stops and the
  /// incoming one plays at full level. Cancels one that has not started.
  Future<void> _finishFade() async {
    final fade = _fade;
    if (fade == null) return;
    _fade = null;
    fade.cancelled = true;
    fade.timer?.cancel();
    if (!fade.started) return;
    await fade.outgoing.setVolume(0);
    await fade.outgoing.clear();
    await _applyGain();
  }

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  Duration get position => _failure?.position ?? _active.position;

  @override
  set queueInfo(QueueInfo? info) => _info = info;

  void _changed() {
    _version++;
    _preparedIndex = null;
  }

  @override
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    await _finishFade();
    _dropFailure();
    _changed();
    _uris
      ..clear()
      ..addAll(uris);
    _lastIndex = initialIndex;
    await _active.setVolume(_level(_active, initialIndex, 1));
    _loading++;
    try {
      await _active.setQueue(
        uris,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
      );
    } catch (e) {
      // Offline as the queue starts: keep it, and open it on play.
      debugPrint('Opening the queue failed: $e');
      if (uris.isNotEmpty) {
        await _fail(index: initialIndex, position: initialPosition);
      }
    } finally {
      _loading--;
    }
    await _spare?.clear();
  }

  @override
  Future<void> addAll(List<Uri> uris) async {
    _changed();
    _uris.addAll(uris);
    await _active.addAll(uris);
  }

  @override
  Future<void> insertAll(int index, List<Uri> uris) async {
    _changed();
    _uris.insertAll(index, uris);
    final f = _failure;
    if (f != null && index <= f.index) f.index += uris.length;
    await _active.insertAll(index, uris);
  }

  @override
  Future<void> removeAt(int index) async {
    await _finishFade();
    _changed();
    _uris.removeAt(index);
    final f = _failure;
    if (f != null) {
      if (_uris.isEmpty) {
        _dropFailure();
      } else if (index < f.index) {
        f.index--;
      } else if (index == f.index) {
        // The next entry takes its place, from the top.
        _retarget(math.min(index, _uris.length - 1), Duration.zero);
      }
    }
    await _active.removeAt(index);
  }

  @override
  Future<void> move(int from, int to) async {
    await _finishFade();
    _changed();
    _uris.insert(to, _uris.removeAt(from));
    final f = _failure;
    if (f != null) {
      final at = f.index;
      if (from == at) {
        f.index = to;
      } else if (from < at && to >= at) {
        f.index = at - 1;
      } else if (from > at && to <= at) {
        f.index = at + 1;
      }
    }
    await _active.move(from, to);
  }

  @override
  Future<void> clear() async {
    await _finishFade();
    _dropFailure();
    _wantPlay = false;
    _changed();
    _uris.clear();
    await _active.clear();
    await _spare?.clear();
  }

  @override
  Future<void> play() async {
    _wantPlay = true;
    final f = _failure;
    if (f == null) return _active.play();
    f.attempts = 0;
    _emitFailure();
    // An attempt under way plays once it opens.
    if (!f.busy) _retryLater(f, now: true);
  }

  @override
  Future<void> pause() async {
    _wantPlay = false;
    final f = _failure;
    if (f != null) {
      f.timer?.cancel();
      f.timer = null;
      _emitFailure();
      // The failed player may still mean to play once it is reopened.
      try {
        await _active.pause();
      } catch (_) {}
      return;
    }
    await _finishFade();
    await _active.pause();
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    final f = _failure;
    if (f != null) {
      final at = index ?? f.index;
      if (at >= 0 && at < _uris.length) _retarget(at, position);
      return;
    }
    await _finishFade();
    await _active.seek(position, index: index);
  }

  @override
  Future<void> next() async {
    final f = _failure;
    if (f != null) {
      final to = _nextIndex(f.index);
      if (to != null) _retarget(to, Duration.zero);
      return;
    }
    await _finishFade();
    await _active.next();
  }

  @override
  Future<void> previous() async {
    final f = _failure;
    if (f != null) {
      _retarget(math.max(f.index - 1, 0), Duration.zero);
      return;
    }
    await _finishFade();
    await _active.previous();
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeat mode) async {
    _repeat = mode;
    _preparedIndex = null;
    await _active.setRepeatMode(mode);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    if (_fade?.started != true) await _applyGain();
  }

  @override
  Future<void> refreshGain() async {
    if (_fade?.started != true) await _applyGain();
  }

  @override
  Future<void> setGapless(bool enabled) async {
    _gapless = enabled;
    await _active.setGapless(enabled);
    await _spare?.setGapless(enabled);
  }

  @override
  Future<void> setDucked(bool ducked) async {
    _duck = ducked ? duckLevel : 1;
    if (_fade?.started != true) await _applyGain();
  }

  @override
  Future<void> setCrossfade(Duration duration) async {
    _crossfade = duration;
    if (duration <= Duration.zero) await _finishFade();
  }

  @override
  Future<void> dispose() async {
    _fade?.timer?.cancel();
    _dropFailure();
    for (final s in _subs) {
      await s.cancel();
    }
    await _state.close();
    await _position.close();
    await _duration.close();
    await _active.dispose();
    await _spare?.dispose();
  }
}

/// Where a failed stream stopped, while the engine reopens it.
class _Failure {
  int index;
  Duration position;
  int attempts = 0;
  Timer? timer;

  /// An attempt to reopen is under way.
  bool busy = false;

  /// The target moved while [busy], so try again at once when it ends.
  bool again = false;

  _Failure(this.index, this.position);
}

class _Fade {
  final AudioDeck outgoing;
  final int outIndex;
  final int inIndex;
  final Duration length;
  AudioDeck? incoming;
  Timer? timer;
  final Stopwatch clock = Stopwatch();
  bool started = false;
  bool cancelled = false;

  _Fade(this.outgoing, this.outIndex, this.inIndex, this.length);
}

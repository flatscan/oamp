import 'dart:async';
import 'dart:math' as math;

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

  Future<void> setQueue(List<Uri> uris, {int initialIndex = 0});
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
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Duration get position;
  Duration? get duration;
  int? get currentIndex;
  bool get playing;

  /// The highest value [setVolume] honours. Above 1 the deck can boost
  /// quiet tracks.
  double get maxVolume;

  Future<void> setQueue(List<Uri> uris, {int initialIndex = 0});
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

  void _follow(AudioDeck deck) {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs
      ..clear()
      ..add(
        deck.stateStream.listen((s) {
          _state.add(s);
          if (s.currentIndex != _lastIndex) {
            _lastIndex = s.currentIndex;
            if (_fade == null) unawaited(_applyGain());
          }
        }),
      )
      ..add(
        deck.positionStream.listen((p) {
          _position.add(p);
          _maybeCrossfade(p);
        }),
      )
      ..add(deck.durationStream.listen(_duration.add));
  }

  double _gain(int? index) {
    if (index == null || index < 0 || index >= _uris.length) return 1;
    return _info?.gainAt(index) ?? 1;
  }

  double _level(AudioDeck deck, int? index, double fade) =>
      math.min(_volume * _gain(index) * fade, deck.maxVolume);

  Future<void> _applyGain() =>
      _active.setVolume(_level(_active, _active.currentIndex, 1));

  int? _nextIndex(int cur) => switch (_repeat) {
    PlaybackRepeat.one => cur,
    _ when cur + 1 < _uris.length => cur + 1,
    PlaybackRepeat.all when _uris.isNotEmpty => 0,
    _ => null,
  };

  void _maybeCrossfade(Duration p) {
    if (_fade != null || _crossfade <= Duration.zero || !_active.playing) {
      return;
    }
    final cur = _active.currentIndex;
    final dur =
        _active.duration ?? (cur == null ? null : _info?.durationAt(cur));
    if (cur == null || dur == null || dur < _crossfade * 2) return;
    final next = _nextIndex(cur);
    if (next == null || !(_info?.crossfadeBetween(cur, next) ?? true)) return;
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
  Future<void> _prepare(int index) async {
    final deck = _spare ??= _createDeck();
    final version = _version;
    await deck.setVolume(0);
    await deck.setGapless(_gapless);
    await deck.setRepeatMode(_repeat);
    await deck.setQueue(List.of(_uris), initialIndex: index);
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
    if (fade.cancelled || _preparedVersion != _version) {
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
  Duration get position => _active.position;

  @override
  set queueInfo(QueueInfo? info) => _info = info;

  void _changed() {
    _version++;
    _preparedIndex = null;
  }

  @override
  Future<void> setQueue(List<Uri> uris, {int initialIndex = 0}) async {
    await _finishFade();
    _changed();
    _uris
      ..clear()
      ..addAll(uris);
    _lastIndex = initialIndex;
    await _active.setVolume(_level(_active, initialIndex, 1));
    await _active.setQueue(uris, initialIndex: initialIndex);
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
    await _active.insertAll(index, uris);
  }

  @override
  Future<void> removeAt(int index) async {
    await _finishFade();
    _changed();
    _uris.removeAt(index);
    await _active.removeAt(index);
  }

  @override
  Future<void> move(int from, int to) async {
    await _finishFade();
    _changed();
    _uris.insert(to, _uris.removeAt(from));
    await _active.move(from, to);
  }

  @override
  Future<void> clear() async {
    await _finishFade();
    _changed();
    _uris.clear();
    await _active.clear();
    await _spare?.clear();
  }

  @override
  Future<void> play() => _active.play();

  @override
  Future<void> pause() async {
    await _finishFade();
    await _active.pause();
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    await _finishFade();
    await _active.seek(position, index: index);
  }

  @override
  Future<void> next() async {
    await _finishFade();
    await _active.next();
  }

  @override
  Future<void> previous() async {
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
  Future<void> setCrossfade(Duration duration) async {
    _crossfade = duration;
    if (duration <= Duration.zero) await _finishFade();
  }

  @override
  Future<void> dispose() async {
    _fade?.timer?.cancel();
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

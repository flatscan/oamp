import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_engine.dart';
import '../audio/just_audio_deck.dart';
import '../core/models.dart';
import '../core/playback_options.dart';
import '../core/track_resolver.dart';
import 'session.dart';
import 'settings.dart';

/// Immutable view of the queue and transport state for the UI.
class PlayerState {
  final List<Track> queue;
  final int? currentIndex;
  final bool playing;
  final bool buffering;
  final PlaybackRepeat repeat;
  final double volume;

  /// Where the queue came from, such as an album name, shown above the
  /// now playing artwork.
  final String? from;

  const PlayerState({
    this.from,
    this.queue = const [],
    this.currentIndex,
    this.playing = false,
    this.buffering = false,
    this.repeat = PlaybackRepeat.off,
    this.volume = 1,
  });

  Track? get current => (currentIndex != null && currentIndex! < queue.length)
      ? queue[currentIndex!]
      : null;
  bool get hasNext =>
      currentIndex != null &&
      (currentIndex! < queue.length - 1 || repeat == PlaybackRepeat.all);

  /// Tracks after the current one.
  List<Track> get upcoming =>
      currentIndex == null ? queue : queue.sublist(currentIndex! + 1);

  PlayerState copyWith({
    List<Track>? queue,
    int? Function()? currentIndex,
    bool? playing,
    bool? buffering,
    PlaybackRepeat? repeat,
    double? volume,
    String? Function()? from,
  }) => PlayerState(
    from: from != null ? from() : this.from,
    queue: queue ?? this.queue,
    currentIndex: currentIndex != null ? currentIndex() : this.currentIndex,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    repeat: repeat ?? this.repeat,
    volume: volume ?? this.volume,
  );
}

/// Makes the players the engine plays through. main.dart swaps in libmpv
/// on Windows.
final audioDeckFactoryProvider = Provider<AudioDeck Function()>(
  (_) => JustAudioDeck.new,
);

final audioEngineProvider = Provider<AudioEngine>((ref) {
  final engine = MixingEngine(ref.watch(audioDeckFactoryProvider));
  ref.onDispose(engine.dispose);
  return engine;
});

final positionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(audioEngineProvider).positionStream,
);
final durationProvider = StreamProvider<Duration?>(
  (ref) => ref.watch(audioEngineProvider).durationStream,
);

final playerProvider = NotifierProvider<PlayerController, PlayerState>(
  PlayerController.new,
);

/// Owns the play queue and treats the [AudioEngine] as an output.
///
/// The list of [Track]s lives here and is mirrored into the engine, so in-app
/// buttons and the OS media controls (see system_controls_bridge.dart) go
/// through the same code path, and a v2 cast engine can take over the output
/// without the queue moving. Tracks become playable URIs through the
/// [TrackResolver], which is where v2 offline downloads plug in.
class PlayerController extends Notifier<PlayerState> implements QueueInfo {
  late AudioEngine _engine;
  PlaybackOptions _options = const PlaybackOptions();

  bool get _signedIn => ref.read(sessionProvider).value != null;
  TrackResolver get _resolver => ref.read(trackResolverProvider);

  @override
  PlayerState build() {
    _engine = ref.watch(audioEngineProvider);
    final sub = _engine.stateStream.listen((s) {
      state = state.copyWith(
        currentIndex: () => s.currentIndex,
        playing: s.playing && !s.completed,
        buffering: s.buffering,
      );
    });
    ref.onDispose(sub.cancel);
    // Signing out (or, in v2, switching server) clears the queue, since its
    // URIs belong to the old server.
    ref.listen(sessionProvider, (prev, next) {
      final before = prev?.value?.serverId;
      if (before != null && before != next.value?.serverId) unawaited(clear());
    });
    _engine.queueInfo = this;
    ref.listen(
      playbackOptionsProvider,
      (_, o) => unawaited(_applyOptions(o)),
      fireImmediately: true,
    );
    // A new streaming quality applies to the tracks still to come; the one
    // playing carries on as it is.
    ref.listen(streamQualityProvider, (prev, next) {
      if (prev != next) unawaited(_reresolveUpcoming());
    });
    return const PlayerState();
  }

  Future<void> _applyOptions(PlaybackOptions o) async {
    final before = _options;
    _options = o;
    if (o.gapless != before.gapless) await _engine.setGapless(o.gapless);
    if (o.crossfade != before.crossfade) {
      await _engine.setCrossfade(o.crossfade);
    }
    await _engine.refreshGain();
  }

  @override
  double gainAt(int index) {
    final q = state.queue;
    return index >= 0 && index < q.length ? _options.gainFor(q[index]) : 1;
  }

  @override
  bool crossfadeBetween(int from, int to) {
    final q = state.queue;
    if (from < 0 || to < 0 || from >= q.length || to >= q.length) return false;
    return _options.shouldCrossfade(q[from], q[to]);
  }

  @override
  Duration? durationAt(int index) {
    final q = state.queue;
    return index >= 0 && index < q.length ? q[index].duration : null;
  }

  Future<void> _reresolveUpcoming() async {
    final cur = state.currentIndex;
    if (cur == null || !_signedIn) return;
    final rest = state.queue.sublist(cur + 1);
    if (rest.isEmpty) return;
    for (var i = cur + rest.length; i > cur; i--) {
      await _engine.removeAt(i);
    }
    await _engine.addAll(await _uris(rest));
  }

  Future<List<Uri>> _uris(List<Track> tracks) =>
      Future.wait([for (final t in tracks) _resolver.resolve(t)]);

  /// Replaces the queue with [tracks] and starts at [startIndex], or at a
  /// random order when [shuffle] is set.
  Future<void> playTracks(
    List<Track> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    String? from,
  }) async {
    if (!_signedIn || tracks.isEmpty) return;
    if (shuffle) {
      tracks = [...tracks]..shuffle();
      startIndex = 0;
    }
    state = state.copyWith(
      queue: List.unmodifiable(tracks),
      currentIndex: () => startIndex,
      from: () => from,
    );
    await _engine.setQueue(await _uris(tracks), initialIndex: startIndex);
    await _engine.play();
  }

  /// Adds [tracks] to the end of the queue.
  Future<void> enqueue(List<Track> tracks) async {
    if (!_signedIn || tracks.isEmpty) return;
    if (state.queue.isEmpty) return playTracks(tracks);
    state = state.copyWith(
      queue: List.unmodifiable([...state.queue, ...tracks]),
    );
    await _engine.addAll(await _uris(tracks));
  }

  /// Inserts [tracks] right after the current track.
  Future<void> playNext(List<Track> tracks) async {
    if (!_signedIn || tracks.isEmpty) return;
    if (state.queue.isEmpty) return playTracks(tracks);
    final at = (state.currentIndex ?? -1) + 1;
    final q = [...state.queue]..insertAll(at, tracks);
    state = state.copyWith(queue: List.unmodifiable(q));
    await _engine.insertAll(at, await _uris(tracks));
  }

  Future<void> jumpTo(int index) async {
    await _engine.seek(Duration.zero, index: index);
    await _engine.play();
  }

  Future<void> removeAt(int index) async {
    final q = [...state.queue]..removeAt(index);
    state = state.copyWith(queue: List.unmodifiable(q));
    await _engine.removeAt(index);
  }

  /// Moves the track at [oldIndex] so it ends up at [newIndex].
  Future<void> move(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final q = [...state.queue];
    q.insert(newIndex, q.removeAt(oldIndex));
    state = state.copyWith(queue: List.unmodifiable(q));
    await _engine.move(oldIndex, newIndex);
  }

  /// Puts the tracks after the current one in a random order.
  Future<void> shuffleUpcoming() async {
    final cur = state.currentIndex ?? -1;
    final rest = state.queue.sublist(cur + 1);
    if (rest.length < 2) return;
    final shuffled = [...rest]..shuffle();
    state = state.copyWith(
      queue: List.unmodifiable([
        ...state.queue.sublist(0, cur + 1),
        ...shuffled,
      ]),
    );
    for (var i = cur + rest.length; i > cur; i--) {
      await _engine.removeAt(i);
    }
    await _engine.addAll(await _uris(shuffled));
  }

  /// Removes everything after the current track.
  Future<void> clearUpcoming() async {
    final cur = state.currentIndex;
    if (cur == null) return clear();
    final end = state.queue.length - 1;
    if (end <= cur) return;
    state = state.copyWith(
      queue: List.unmodifiable(state.queue.sublist(0, cur + 1)),
    );
    for (var i = end; i > cur; i--) {
      await _engine.removeAt(i);
    }
  }

  /// Steps through repeat off, repeat queue and repeat track.
  Future<void> cycleRepeat() async {
    final next = PlaybackRepeat.values[(state.repeat.index + 1) % 3];
    state = state.copyWith(repeat: next);
    await _engine.setRepeatMode(next);
  }

  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    state = state.copyWith(volume: v);
    await _engine.setVolume(v);
  }

  /// Empties the queue, keeping the listener's repeat and volume settings.
  Future<void> clear() async {
    state = PlayerState(repeat: state.repeat, volume: state.volume);
    await _engine.clear();
  }

  Future<void> play() async {
    if (state.queue.isNotEmpty) await _engine.play();
  }

  Future<void> pause() => _engine.pause();
  Future<void> togglePlay() => state.playing ? pause() : play();
  Future<void> next() => _engine.next();

  /// Restarts the track when more than three seconds in, like most players.
  Future<void> previous() async {
    final i = state.currentIndex ?? 0;
    if (_engine.position > const Duration(seconds: 3) || i == 0) {
      await _engine.seek(Duration.zero);
    } else {
      await _engine.previous();
    }
  }

  Future<void> seek(Duration d) => _engine.seek(d);
}

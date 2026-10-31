import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../api/subsonic_client.dart';
import '../audio/audio_engine.dart';
import 'session.dart';

/// Immutable view of the queue and transport state for the UI.
class PlayerState {
  final List<Track> queue;
  final int? currentIndex;
  final bool playing;
  final bool buffering;

  const PlayerState({
    this.queue = const [],
    this.currentIndex,
    this.playing = false,
    this.buffering = false,
  });

  Track? get current => (currentIndex != null && currentIndex! < queue.length)
      ? queue[currentIndex!]
      : null;
  bool get hasNext => currentIndex != null && currentIndex! < queue.length - 1;

  PlayerState copyWith({
    List<Track>? queue,
    int? Function()? currentIndex,
    bool? playing,
    bool? buffering,
  }) => PlayerState(
    queue: queue ?? this.queue,
    currentIndex: currentIndex != null ? currentIndex() : this.currentIndex,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
  );
}

final audioEngineProvider = Provider<AudioEngine>((ref) {
  final engine = JustAudioEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

final positionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(audioEngineProvider).positionStream,
);
final durationProvider = StreamProvider<Duration?>(
  (ref) => ref.watch(audioEngineProvider).durationStream,
);

final playerProvider = NotifierProvider<PlayerNotifier, PlayerState>(
  PlayerNotifier.new,
);

/// Owns the play queue. The list of [Track]s lives here and is mirrored into
/// the [AudioEngine], so in-app buttons and (later) system media controls go
/// through the same code path.
class PlayerNotifier extends Notifier<PlayerState> {
  late AudioEngine _engine;

  SubsonicClient? get _client => ref.read(sessionProvider).value;

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
    // Signing out clears the queue, since its stream URLs carry the old auth.
    ref.listen(sessionProvider, (prev, next) {
      if (prev?.value != null && next.value == null) unawaited(clear());
    });
    return const PlayerState();
  }

  List<Uri> _uris(List<Track> tracks) => [
    for (final t in tracks) _client!.streamUrl(t.id),
  ];

  /// Replaces the queue with [tracks] and starts at [startIndex].
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    if (_client == null || tracks.isEmpty) return;
    state = state.copyWith(
      queue: List.unmodifiable(tracks),
      currentIndex: () => startIndex,
    );
    await _engine.setQueue(_uris(tracks), initialIndex: startIndex);
    await _engine.play();
  }

  /// Adds [tracks] to the end of the queue.
  Future<void> enqueue(List<Track> tracks) async {
    if (_client == null || tracks.isEmpty) return;
    if (state.queue.isEmpty) return playTracks(tracks);
    state = state.copyWith(
      queue: List.unmodifiable([...state.queue, ...tracks]),
    );
    await _engine.addAll(_uris(tracks));
  }

  /// Inserts [tracks] right after the current track.
  Future<void> playNext(List<Track> tracks) async {
    if (_client == null || tracks.isEmpty) return;
    if (state.queue.isEmpty) return playTracks(tracks);
    final at = (state.currentIndex ?? -1) + 1;
    final q = [...state.queue]..insertAll(at, tracks);
    state = state.copyWith(queue: List.unmodifiable(q));
    await _engine.insertAll(at, _uris(tracks));
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

  Future<void> clear() async {
    state = const PlayerState();
    await _engine.clear();
  }

  Future<void> togglePlay() => state.playing ? _engine.pause() : _engine.play();
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

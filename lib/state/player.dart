import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_engine.dart';
import '../audio/audio_focus.dart';
import '../audio/just_audio_deck.dart';
import '../core/models.dart';
import '../core/play_queue.dart';
import '../core/playback_options.dart';
import '../core/track_resolver.dart';
import '../platform/preferences.dart';
import 'session.dart';
import 'settings.dart';

/// Immutable view of the queue and transport state for the UI.
class PlayerState {
  final List<Track> queue;

  /// The streaming quality each track in [queue] was resolved with.
  final List<StreamQuality> qualities;
  final int? currentIndex;
  final bool playing;
  final bool buffering;
  final PlaybackRepeat repeat;
  final double volume;

  /// Where the queue came from, such as an album name, shown above the
  /// now playing artwork.
  final String? from;

  /// Whether up next is in a shuffled order that [PlayerController.unshuffle]
  /// can undo.
  final bool shuffled;

  /// How far into the current track its stream starts. Non-zero after a
  /// seek in a transcoded stream that had to be reopened part way in; the
  /// engine then counts from zero and [positionProvider] adds this back.
  final Duration offset;

  const PlayerState({
    this.from,
    this.offset = Duration.zero,
    this.shuffled = false,
    this.queue = const [],
    this.qualities = const [],
    this.currentIndex,
    this.playing = false,
    this.buffering = false,
    this.repeat = PlaybackRepeat.off,
    this.volume = 1,
  });

  Track? get current => (currentIndex != null && currentIndex! < queue.length)
      ? queue[currentIndex!]
      : null;

  /// The streaming quality of the currently playing track.
  StreamQuality get currentQuality =>
      (currentIndex != null && currentIndex! < qualities.length)
      ? qualities[currentIndex!]
      : StreamQuality.original;

  bool get hasNext =>
      currentIndex != null &&
      (currentIndex! < queue.length - 1 || repeat == PlaybackRepeat.all);

  /// Tracks after the current one.
  List<Track> get upcoming =>
      currentIndex == null ? queue : queue.sublist(currentIndex! + 1);

  PlayerState copyWith({
    List<Track>? queue,
    List<StreamQuality>? qualities,
    int? Function()? currentIndex,
    bool? playing,
    bool? buffering,
    PlaybackRepeat? repeat,
    double? volume,
    String? Function()? from,
    Duration? offset,
    bool? shuffled,
  }) => PlayerState(
    shuffled: shuffled ?? this.shuffled,
    from: from != null ? from() : this.from,
    offset: offset ?? this.offset,
    queue: queue ?? this.queue,
    qualities: qualities ?? this.qualities,
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

/// The OS audio session. main.dart swaps in the real one on phones; on
/// Windows and in tests nothing interrupts playback.
final audioFocusProvider = Provider<AudioFocus>((_) => const NoAudioFocus());

final audioEngineProvider = Provider<AudioEngine>((ref) {
  final engine = MixingEngine(ref.watch(audioDeckFactoryProvider));
  ref.onDispose(engine.dispose);
  return engine;
});

/// Where the current track is, counted from its start even when its
/// stream was reopened part way in (see [PlayerState.offset]).
final positionProvider = StreamProvider<Duration>((ref) {
  final offset = ref.watch(playerProvider.select((s) => s.offset));
  final positions = ref.watch(audioEngineProvider).positionStream;
  return offset == Duration.zero ? positions : positions.map((p) => p + offset);
});

/// The current track's length. A stream reopened part way in only knows
/// the length of what is left, so the library's length is used instead.
final durationProvider = StreamProvider<Duration?>((ref) {
  final offset = ref.watch(playerProvider.select((s) => s.offset));
  if (offset != Duration.zero) {
    return Stream.value(ref.read(playerProvider).current?.duration);
  }
  return ref.watch(audioEngineProvider).durationStream;
});

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

  /// Where [restore] left the current track, until playback moves on. The
  /// engine may not report it until the track has loaded.
  Duration? _restoredAt;
  PlaybackOptions _options = const PlaybackOptions();

  /// Set while the current entry is being swapped for one that starts part
  /// way in. The engine's index moves for a moment while that happens, and
  /// that is not a track change.
  bool _swapping = false;

  /// The queue entry whose stream was reopened part way in, while
  /// [PlayerState.offset] is set.
  Track? _reopened;

  /// The queue's order before it was shuffled, while [PlayerState.shuffled].
  List<Track> _unshuffled = const [];

  /// Playback was paused for a call or another app, and plays again when
  /// that is over. Anything the listener does meanwhile clears it.
  bool _resumeAfterInterruption = false;

  /// Where the volume level is kept between runs.
  static const volumeKey = 'oamp.player.volume';

  /// Dragging the slider sets the volume many times a second, so saving
  /// waits until it settles.
  Timer? _saveVolume;
  late Preferences _prefs;
  double _savedVolume = 1;

  bool get _signedIn => ref.read(sessionProvider).value != null;
  TrackResolver get _resolver => ref.read(trackResolverProvider);

  @override
  PlayerState build() {
    _engine = ref.watch(audioEngineProvider);
    final sub = _engine.stateStream.listen((s) {
      if (_swapping) {
        state = state.copyWith(buffering: s.buffering);
        return;
      }
      final before = state.currentIndex;
      if (s.currentIndex != before || s.playing) _restoredAt = null;
      // Moving or removing other entries also changes the index, so compare
      // the track itself.
      final reopened = _reopened;
      final at = s.currentIndex;
      final left =
          reopened != null &&
          !identical(
            at != null && at < state.queue.length ? state.queue[at] : null,
            reopened,
          );
      state = state.copyWith(
        currentIndex: () => s.currentIndex,
        playing: s.playing && !s.completed,
        buffering: s.buffering,
        offset: left ? Duration.zero : null,
      );
      // The track that was reopened part way in is behind us; put its
      // ordinary stream back so it plays from the top next time.
      if (left) {
        _reopened = null;
        unawaited(_restoreEntry(reopened));
      }
    });
    ref.onDispose(sub.cancel);
    final focus = ref.watch(audioFocusProvider).changes.listen(_onFocus);
    ref.onDispose(focus.cancel);
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
    _prefs = ref.read(preferencesProvider);
    ref.onDispose(_flushVolume);
    final saved = _prefs.getDouble(volumeKey);
    if (saved == null) return const PlayerState();
    final volume = saved.clamp(0.0, 1.0);
    unawaited(_engine.setVolume(volume));
    return PlayerState(volume: volume);
  }

  /// Calls, other apps and unplugged headphones. Pauses for an
  /// interruption and plays again after it only if it was what paused us;
  /// losing the audio to another player or the headphones going away
  /// pauses for good.
  void _onFocus(FocusChange change) {
    switch (change) {
      case FocusChange.interrupted:
        if (state.playing) {
          _resumeAfterInterruption = true;
          unawaited(_engine.pause());
        }
      case FocusChange.lost || FocusChange.becomingNoisy:
        _resumeAfterInterruption = false;
        if (state.playing) unawaited(_engine.pause());
      case FocusChange.duck:
        unawaited(_engine.setDucked(true));
      case FocusChange.resumed || FocusChange.ended:
        unawaited(_engine.setDucked(false));
        final resume =
            _resumeAfterInterruption && change == FocusChange.resumed;
        _resumeAfterInterruption = false;
        if (resume && state.queue.isNotEmpty) unawaited(_engine.play());
    }
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
  double get boostHeadroom => _options.boostHeadroom;

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
    final q = ref.read(streamQualityProvider);
    state = state.copyWith(
      qualities: List.unmodifiable([
        ...state.qualities.take(cur + 1),
        ...List.filled(rest.length, q),
      ]),
    );
    for (var i = cur + rest.length; i > cur; i--) {
      await _engine.removeAt(i);
    }
    await _engine.addAll(await _uris(rest));
  }

  List<StreamQuality> _qualitiesFor(int count) =>
      List.filled(count, ref.read(streamQualityProvider));

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
    _unshuffled = shuffle ? List.of(tracks) : const [];
    if (shuffle) {
      tracks = [...tracks]..shuffle();
      startIndex = 0;
    }
    _restoredAt = null;
    _reopened = null;
    _resumeAfterInterruption = false;
    state = state.copyWith(
      queue: List.unmodifiable(tracks),
      qualities: List.unmodifiable(_qualitiesFor(tracks.length)),
      currentIndex: () => startIndex,
      from: () => from,
      offset: Duration.zero,
      shuffled: shuffle,
    );
    await _engine.setQueue(await _uris(tracks), initialIndex: startIndex);
    await _engine.play();
  }

  /// Loads a saved queue paused at its current track and position, as it
  /// was left on this or another device. Replaces whatever is queued.
  Future<void> restore(SavedQueue saved) async {
    if (!_signedIn || saved.isEmpty) return;
    final tracks = saved.tracks;
    final index = (saved.currentIndex ?? 0).clamp(0, tracks.length - 1);
    var position = saved.position;
    final length = tracks[index].duration;
    // A position at (or past) the end would finish the track at once.
    if (position < Duration.zero ||
        (length != null && position >= length - const Duration(seconds: 1))) {
      position = Duration.zero;
    }
    _resumeAfterInterruption = false;
    if (state.playing) await _engine.pause();
    _restoredAt = position;
    final uris = await _uris(tracks);
    // A transcoded stream that is not cached cannot be seeked to where the
    // queue was left, so open it there instead.
    final reopen = position > Duration.zero
        ? _resolver.resolveFrom(tracks[index], _whole(position))
        : null;
    if (reopen != null) uris[index] = reopen;
    _reopened = reopen == null ? null : tracks[index];
    state = state.copyWith(
      queue: List.unmodifiable(tracks),
      qualities: List.unmodifiable(_qualitiesFor(tracks.length)),
      currentIndex: () => index,
      from: () => saved.from,
      playing: false,
      offset: reopen == null ? Duration.zero : _whole(position),
      shuffled: false,
    );
    await _engine.setQueue(
      uris,
      initialIndex: index,
      initialPosition: reopen == null ? position : Duration.zero,
    );
  }

  /// The queue as it stands now, for saving.
  SavedQueue snapshot() => SavedQueue(
    tracks: state.queue,
    currentIndex: state.currentIndex,
    position: state.queue.isEmpty
        ? Duration.zero
        : (_restoredAt ?? _engine.position + state.offset),
    from: state.from,
  );

  /// Adds [tracks] to the end of the queue.
  Future<void> enqueue(List<Track> tracks) async {
    if (!_signedIn || tracks.isEmpty) return;
    if (state.queue.isEmpty) return playTracks(tracks);
    state = state.copyWith(
      queue: List.unmodifiable([...state.queue, ...tracks]),
      qualities: List.unmodifiable([
        ...state.qualities,
        ..._qualitiesFor(tracks.length),
      ]),
    );
    await _engine.addAll(await _uris(tracks));
  }

  /// Inserts [tracks] right after the current track.
  Future<void> playNext(List<Track> tracks) async {
    if (!_signedIn || tracks.isEmpty) return;
    if (state.queue.isEmpty) return playTracks(tracks);
    final at = (state.currentIndex ?? -1) + 1;
    final q = [...state.queue]..insertAll(at, tracks);
    final quals = [...state.qualities]
      ..insertAll(at, _qualitiesFor(tracks.length));
    state = state.copyWith(
      queue: List.unmodifiable(q),
      qualities: List.unmodifiable(quals),
    );
    await _engine.insertAll(at, await _uris(tracks));
  }

  Future<void> jumpTo(int index) async {
    _resumeAfterInterruption = false;
    await _engine.seek(Duration.zero, index: index);
    await _engine.play();
  }

  Future<void> removeAt(int index) async {
    // The reopened entry is going, so there is nothing to put back.
    final offset = index == state.currentIndex ? Duration.zero : null;
    if (offset != null) _reopened = null;
    final q = [...state.queue]..removeAt(index);
    final quals = [...state.qualities];
    if (index < quals.length) quals.removeAt(index);
    state = state.copyWith(
      queue: List.unmodifiable(q),
      qualities: List.unmodifiable(quals),
      offset: offset,
    );
    await _engine.removeAt(index);
  }

  /// Moves the track at [oldIndex] so it ends up at [newIndex].
  Future<void> move(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final q = [...state.queue];
    q.insert(newIndex, q.removeAt(oldIndex));
    final quals = [...state.qualities];
    if (oldIndex < quals.length && newIndex <= quals.length) {
      quals.insert(newIndex, quals.removeAt(oldIndex));
    }
    state = state.copyWith(
      queue: List.unmodifiable(q),
      qualities: List.unmodifiable(quals),
    );
    await _engine.move(oldIndex, newIndex);
  }

  /// Puts the tracks after the current one in a random order.
  Future<void> shuffleUpcoming() async {
    final cur = state.currentIndex ?? -1;
    final rest = state.queue.sublist(cur + 1);
    if (rest.length < 2) return;
    if (!state.shuffled) _unshuffled = List.of(state.queue);
    await _setUpcoming([...rest]..shuffle());
    state = state.copyWith(shuffled: true);
  }

  /// Puts up next back in the order it had before [shuffleUpcoming] (or a
  /// shuffled [playTracks]). Tracks added since keep their place at the
  /// end, in the order they were added.
  Future<void> unshuffle() async {
    if (!state.shuffled) return;
    final cur = state.currentIndex ?? -1;
    final rest = state.queue.sublist(cur + 1);
    final left = [...rest];
    final ordered = <Track>[];
    for (final t in _unshuffled) {
      final i = left.indexWhere((x) => identical(x, t));
      if (i >= 0) ordered.add(left.removeAt(i));
    }
    _unshuffled = const [];
    await _setUpcoming([...ordered, ...left]);
    state = state.copyWith(shuffled: false);
  }

  Future<void> toggleShuffle() =>
      state.shuffled ? unshuffle() : shuffleUpcoming();

  /// Replaces everything after the current track with [upcoming].
  Future<void> _setUpcoming(List<Track> upcoming) async {
    final cur = state.currentIndex ?? -1;
    final count = state.queue.length - cur - 1;
    final q = ref.read(streamQualityProvider);
    state = state.copyWith(
      queue: List.unmodifiable([
        ...state.queue.sublist(0, cur + 1),
        ...upcoming,
      ]),
      qualities: List.unmodifiable([
        ...state.qualities.take(cur + 1),
        ...List.filled(upcoming.length, q),
      ]),
    );
    for (var i = cur + count; i > cur; i--) {
      await _engine.removeAt(i);
    }
    await _engine.addAll(await _uris(upcoming));
  }

  /// Removes everything after the current track.
  Future<void> clearUpcoming() async {
    final cur = state.currentIndex;
    if (cur == null) return clear();
    final end = state.queue.length - 1;
    if (end <= cur) return;
    state = state.copyWith(
      queue: List.unmodifiable(state.queue.sublist(0, cur + 1)),
      qualities: List.unmodifiable(state.qualities.take(cur + 1).toList()),
      shuffled: false,
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
    _saveVolume?.cancel();
    _savedVolume = v;
    _saveVolume = Timer(const Duration(milliseconds: 500), _flushVolume);
    await _engine.setVolume(v);
  }

  void _flushVolume() {
    final pending = _saveVolume;
    if (pending == null) return;
    pending.cancel();
    _saveVolume = null;
    unawaited(_prefs.setDouble(volumeKey, _savedVolume));
  }

  /// Empties the queue, keeping the listener's repeat and volume settings.
  Future<void> clear() async {
    _resumeAfterInterruption = false;
    _restoredAt = null;
    _reopened = null;
    state = PlayerState(repeat: state.repeat, volume: state.volume);
    await _engine.clear();
  }

  Future<void> play() async {
    _resumeAfterInterruption = false;
    if (state.queue.isNotEmpty) await _engine.play();
  }

  Future<void> pause() {
    _resumeAfterInterruption = false;
    return _engine.pause();
  }

  Future<void> togglePlay() => state.playing ? pause() : play();
  Future<void> next() => _engine.next();

  /// Restarts the track when more than three seconds in, like most players.
  Future<void> previous() async {
    final i = state.currentIndex ?? 0;
    if (_engine.position + state.offset > const Duration(seconds: 3) ||
        i == 0) {
      await seek(Duration.zero);
    } else {
      await _engine.previous();
    }
  }

  /// Seeks in the current track. A transcoded stream that is not cached
  /// cannot jump ahead by bytes, so where the server can start one part way
  /// in, the current entry is reopened at [d] instead.
  Future<void> seek(Duration d) async {
    _restoredAt = null;
    final i = state.currentIndex;
    final track = state.current;
    if (i == null || track == null) return _engine.seek(d);
    final reopen =
        state.currentQuality.isOriginal || d < const Duration(seconds: 1)
        ? null
        : _resolver.resolveFrom(track, _whole(d));
    if (reopen == null && state.offset == Duration.zero) {
      return _engine.seek(d);
    }
    // Back to the top, or now cached: the ordinary stream can do it.
    final uri = reopen ?? await _resolver.resolve(track);
    final offset = reopen == null ? Duration.zero : _whole(d);
    await _replaceCurrent(i, uri);
    _reopened = reopen == null ? null : track;
    state = state.copyWith(offset: offset);
    if (reopen == null && d > Duration.zero) await _engine.seek(d);
  }

  static Duration _whole(Duration d) => Duration(seconds: d.inSeconds);

  /// Swaps the entry at [i], which is playing, for [uri], keeping playing
  /// or paused as it was.
  Future<void> _replaceCurrent(int i, Uri uri) async {
    _swapping = true;
    try {
      await _engine.insertAll(i + 1, [uri]);
      await _engine.seek(Duration.zero, index: i + 1);
      await _engine.removeAt(i);
    } finally {
      _swapping = false;
    }
  }

  /// Puts the ordinary stream back for [track] after leaving it, when it
  /// was reopened part way in.
  Future<void> _restoreEntry(Track track) async {
    final uri = await _resolver.resolve(track);
    final i = state.queue.indexWhere((t) => identical(t, track));
    if (i < 0 || i == state.currentIndex) return;
    _swapping = true;
    try {
      await _engine.removeAt(i);
      await _engine.insertAll(i, [uri]);
    } finally {
      _swapping = false;
    }
  }
}

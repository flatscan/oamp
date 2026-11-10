import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_engine.dart';
import '../audio/audio_focus.dart';
import '../audio/just_audio_deck.dart';
import '../audio/output_switcher.dart';
import '../core/models.dart';
import '../core/output_device.dart';
import '../core/remote_player.dart';
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

  /// Whether the queue was started by playing a whole album in order. Such
  /// queues can carry on with the artist's next album (see
  /// endless_play.dart), and have their own endless play default.
  final bool albumQueue;

  /// Queue entries that endless play added, marked in the queue. Compared
  /// by identity, so the same track queued by hand is not marked.
  final Set<Track> endless;

  const PlayerState({
    this.from,
    this.albumQueue = false,
    this.endless = const {},
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

  /// Whether endless play added this queue entry.
  bool isEndless(Track entry) => endless.contains(entry);

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
    bool? albumQueue,
    Set<Track>? endless,
  }) => PlayerState(
    albumQueue: albumQueue ?? this.albumQueue,
    endless: endless ?? this.endless,
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

/// This device's own playback.
final audioEngineProvider = Provider<AudioEngine>((ref) {
  final engine = MixingEngine(ref.watch(audioDeckFactoryProvider));
  ref.onDispose(engine.dispose);
  return engine;
});

/// What the player plays through: this device, or a speaker or TV while
/// casting (see state/outputs.dart).
final outputSwitcherProvider = Provider<OutputSwitcher>((ref) {
  final switcher = OutputSwitcher(ref.watch(audioEngineProvider));
  ref.onDispose(switcher.dispose);
  return switcher;
});

/// Where the current track is, counted from its start even when its
/// stream was reopened part way in (see [PlayerState.offset]).
final positionProvider = StreamProvider<Duration>((ref) {
  final offset = ref.watch(playerProvider.select((s) => s.offset));
  final positions = ref.watch(outputSwitcherProvider).positionStream;
  return offset == Duration.zero ? positions : positions.map((p) => p + offset);
});

/// The current track's length. A stream reopened part way in only knows
/// the length of what is left, so the library's length is used instead.
final durationProvider = StreamProvider<Duration?>((ref) {
  final offset = ref.watch(playerProvider.select((s) => s.offset));
  if (offset != Duration.zero) {
    return Stream.value(ref.read(playerProvider).current?.duration);
  }
  final switcher = ref.watch(outputSwitcherProvider);
  // Moving on from a reopened stream, the engine has usually reported the
  // next track's length already. When repeat one puts the same track back,
  // that report is forgotten, and the library's length stands in for it.
  final known = switcher.duration ?? ref.read(playerProvider).current?.duration;
  return (() async* {
    if (known != null) yield known;
    yield* switcher.durationStream;
  })();
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
  late OutputSwitcher _engine;

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

  /// Runs from a skip by hand until the engine reports leaving the track,
  /// so a natural advance at the end of a reopened stream can be told apart
  /// in [PlaybackRepeat.one]. The engine can report the new track well
  /// after the skip's command returns (libmpv reports it from its own
  /// thread), so this waits for that report, or [_stepWindow] at most for
  /// a skip that doesn't move (at either end of the queue).
  Timer? _stepping;
  static const _stepWindow = Duration(seconds: 2);

  /// The queue's order before it was shuffled, while [PlayerState.shuffled].
  List<Track> _unshuffled = const [];

  /// Ids of queued tracks whose details came from a saved queue and may be
  /// out of date, such as ReplayGain added since by retagging the files.
  /// The current and next ones are fetched again as playback reaches them.
  Set<String> _stale = {};

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
    _engine = ref.watch(outputSwitcherProvider);
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
      final manual = _stepping != null;
      if (left) {
        _stepping?.cancel();
        _stepping = null;
      }
      // Repeat one on a stream reopened part way in keeps the engine in
      // repeat off until the stream ends (which completes on the last
      // entry or moves on to the next one), then puts the full stream back
      // so it repeats from the top.
      if (state.repeat == PlaybackRepeat.one &&
          state.offset > Duration.zero &&
          reopened != null &&
          (s.completed || (left && !manual))) {
        final idx = state.queue.indexWhere((t) => identical(t, reopened));
        if (idx >= 0) {
          _reopened = null;
          // The engine's last length was what was left of the reopened
          // stream, not the track's.
          _engine.forgetDuration();
          state = state.copyWith(
            currentIndex: () => idx,
            playing: true,
            buffering: s.buffering,
            offset: Duration.zero,
          );
          unawaited(_repeatReopenedFromTop(reopened));
          return;
        }
      }
      state = state.copyWith(
        currentIndex: () => s.currentIndex,
        playing: s.playing && !s.completed,
        buffering: s.buffering,
        offset: left ? Duration.zero : null,
      );
      if (s.currentIndex != before && s.currentIndex != null) {
        unawaited(_refreshAround(s.currentIndex!));
      }
      // The track that was reopened part way in is behind us; put its
      // ordinary stream back so it plays from the top next time.
      if (left) {
        _reopened = null;
        if (state.repeat == PlaybackRepeat.one) {
          unawaited(_engine.setRepeatMode(PlaybackRepeat.one));
        }
        unawaited(_restoreEntry(reopened));
      }
    });
    ref.onDispose(sub.cancel);
    ref.onDispose(() => _stepping?.cancel());
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
    // Calls and other apps on the phone don't stop the speaker or TV.
    if (_engine.isRemote) return;
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
    if (state.repeat == PlaybackRepeat.one &&
        state.offset > Duration.zero &&
        from == state.currentIndex) {
      return false;
    }
    final q = state.queue;
    if (from < 0 || to < 0 || from >= q.length || to >= q.length) return false;
    return _options.shouldCrossfade(q[from], q[to]);
  }

  @override
  double get boostHeadroom => _options.boostHeadroom;

  @override
  RemoteMedia? remoteMediaAt(int index, OutputProtocol protocol) {
    final q = state.queue;
    if (index < 0 || index >= q.length || !_signedIn) return null;
    return remoteMediaFor(q[index], ref.read(musicSourceProvider), protocol);
  }

  @override
  Duration? durationAt(int index) {
    final q = state.queue;
    if (index < 0 || index >= q.length) return null;
    final dur = q[index].duration;
    if (dur == null) return null;
    if (index == state.currentIndex && state.offset > Duration.zero) {
      final rem = dur - state.offset;
      return rem > Duration.zero ? rem : Duration.zero;
    }
    return dur;
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
  /// random order when [shuffle] is set. [album] says [tracks] are a whole
  /// album; played in order, that makes it an album queue
  /// ([PlayerState.albumQueue]).
  Future<void> playTracks(
    List<Track> tracks, {
    int startIndex = 0,
    bool shuffle = false,
    String? from,
    bool album = false,
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
    _stale = {};
    state = state.copyWith(
      queue: List.unmodifiable(tracks),
      qualities: List.unmodifiable(_qualitiesFor(tracks.length)),
      currentIndex: () => startIndex,
      from: () => from,
      offset: Duration.zero,
      shuffled: shuffle,
      albumQueue: album && !shuffle,
      endless: _marks(const []),
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
    final reopen = position > Duration.zero && !_engine.isRemote
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
      albumQueue: saved.albumQueue,
      endless: _marks([
        for (final i in saved.endless)
          if (i >= 0 && i < tracks.length) tracks[i],
      ]),
    );
    _stale = {for (final t in tracks) t.id};
    if (reopen != null && state.repeat == PlaybackRepeat.one) {
      await _engine.setRepeatMode(PlaybackRepeat.off);
    }
    await _engine.setQueue(
      uris,
      initialIndex: index,
      initialPosition: reopen == null ? position : Duration.zero,
    );
    await _refreshAround(index);
  }

  /// Fetches fresh details for the tracks at [index] and the one after it
  /// when they came from a saved queue, so their ReplayGain, rating and so
  /// on match the server now rather than when they were queued.
  Future<void> _refreshAround(int index) async {
    if (_stale.isEmpty || !_signedIn) return;
    final q = state.queue;
    final ids = <String>{
      for (final i in [index, index + 1])
        if (i >= 0 && i < q.length && _stale.contains(q[i].id)) q[i].id,
    };
    if (ids.isEmpty) return;
    _stale.removeAll(ids);
    final source = ref.read(musicSourceProvider);
    final fresh = <String, Track>{};
    await Future.wait([
      for (final id in ids)
        source.getTrack(id).then((t) {
          if (t.id == id) fresh[id] = t;
        }, onError: (Object e) {}),
    ]);
    if (fresh.isEmpty || !ref.mounted) return;
    Track swap(Track t) => fresh[t.id] ?? t;
    final before = state.queue;
    final after = [for (final t in before) swap(t)];
    final reopened = _reopened;
    if (reopened != null) {
      final i = before.indexWhere((t) => identical(t, reopened));
      if (i >= 0) _reopened = after[i];
    }
    _unshuffled = [for (final t in _unshuffled) swap(t)];
    final marks = [
      for (var i = 0; i < before.length; i++)
        if (state.isEndless(before[i])) after[i],
    ];
    state = state.copyWith(
      queue: List.unmodifiable(after),
      endless: _marks(marks),
    );
    await _engine.refreshGain();
  }

  /// The queue as it stands now, for saving.
  SavedQueue snapshot() => SavedQueue(
    tracks: state.queue,
    currentIndex: state.currentIndex,
    position: state.queue.isEmpty
        ? Duration.zero
        : (_restoredAt ?? _engine.position + state.offset),
    from: state.from,
    albumQueue: state.albumQueue,
    endless: {
      for (var i = 0; i < state.queue.length; i++)
        if (state.isEndless(state.queue[i])) i,
    },
  );

  static Set<Track> _marks(Iterable<Track> entries) =>
      Set<Track>.unmodifiable(Set<Track>.identity()..addAll(entries));

  /// Adds [tracks] to the end of the queue.
  Future<void> enqueue(List<Track> tracks) => _append(tracks);

  /// Adds tracks endless play picked to the end of the queue, marked as
  /// such. Does nothing when the queue is empty: endless play only carries
  /// on from something.
  Future<void> addEndless(List<Track> tracks) async {
    if (state.queue.isEmpty) return;
    // Separate entries, so a track that is also queued by hand is not
    // marked there.
    await _append([for (final t in tracks) t.copy()], marked: true);
  }

  Future<void> _append(List<Track> tracks, {bool marked = false}) async {
    if (!_signedIn || tracks.isEmpty) return;
    if (state.queue.isEmpty) return playTracks(tracks);
    state = state.copyWith(
      queue: List.unmodifiable([...state.queue, ...tracks]),
      qualities: List.unmodifiable([
        ...state.qualities,
        ..._qualitiesFor(tracks.length),
      ]),
      endless: marked ? _marks([...state.endless, ...tracks]) : null,
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

  Future<void> _step(Future<void> Function() action) async {
    _stepping?.cancel();
    _stepping = Timer(_stepWindow, () => _stepping = null);
    await action();
  }

  Future<void> jumpTo(int index) async {
    _resumeAfterInterruption = false;
    await _step(() async {
      await _engine.seek(Duration.zero, index: index);
      await _engine.play();
    });
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    if (state.queue.length == 1) {
      await clear();
      return;
    }
    // The reopened entry is going, so there is nothing to put back.
    final offset = index == state.currentIndex ? Duration.zero : null;
    if (offset != null) {
      _reopened = null;
      if (state.repeat == PlaybackRepeat.one) {
        await _engine.setRepeatMode(PlaybackRepeat.one);
      }
    }
    final removed = state.queue[index];
    final q = [...state.queue]..removeAt(index);
    final quals = [...state.qualities];
    if (index < quals.length) quals.removeAt(index);
    final endless = Set<Track>.identity()
      ..addAll(state.endless)
      ..remove(removed);
    state = state.copyWith(
      queue: List.unmodifiable(q),
      qualities: List.unmodifiable(quals),
      endless: Set<Track>.unmodifiable(endless),
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
    final kept = state.queue.sublist(0, cur + 1);
    final endless = Set<Track>.identity()
      ..addAll(state.endless.where((t) => kept.any((k) => identical(k, t))));
    _unshuffled = const [];
    state = state.copyWith(
      queue: List.unmodifiable(kept),
      qualities: List.unmodifiable(state.qualities.take(cur + 1).toList()),
      endless: Set<Track>.unmodifiable(endless),
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
    await _engine.setRepeatMode(
      next == PlaybackRepeat.one && state.offset > Duration.zero
          ? PlaybackRepeat.off
          : next,
    );
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
    _stale = {};
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

  Future<void> next() => _step(_engine.next);

  /// Restarts the track when more than three seconds in, like most players.
  Future<void> previous() async {
    final i = state.currentIndex ?? 0;
    if (_engine.position + state.offset > const Duration(seconds: 3) ||
        i == 0) {
      await seek(Duration.zero);
    } else {
      await _step(_engine.previous);
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
    // A speaker or TV is sent its own stream (see remoteMediaFor), so this
    // device's transcoding doesn't apply while casting.
    final reopen =
        state.currentQuality.isOriginal ||
            d < const Duration(seconds: 1) ||
            _engine.isRemote
        ? null
        : _resolver.resolveFrom(track, _whole(d));
    if (reopen == null && state.offset == Duration.zero) {
      return _engine.seek(d);
    }
    // Back to the top, or now cached: the ordinary stream can do it.
    final uri = reopen ?? await _resolver.resolve(track);
    final offset = reopen == null ? Duration.zero : _whole(d);
    if (state.repeat == PlaybackRepeat.one) {
      await _engine.setRepeatMode(
        offset > Duration.zero ? PlaybackRepeat.off : PlaybackRepeat.one,
      );
    }
    _reopened = reopen == null ? null : track;
    _stepping?.cancel();
    _stepping = null;
    state = state.copyWith(offset: offset);
    await _replaceCurrent(i, uri);
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

  /// Puts the ordinary stream back for [track] and plays it from the top
  /// when repeat one reaches the end of a reopened stream.
  Future<void> _repeatReopenedFromTop(Track track) async {
    _swapping = true;
    try {
      final uri = await _resolver.resolve(track);
      if (!ref.mounted) return;
      final idx = state.queue.indexWhere((t) => identical(t, track));
      if (idx < 0 || state.currentIndex != idx) return;
      await _engine.insertAll(idx + 1, [uri]);
      await _engine.seek(Duration.zero, index: idx + 1);
      await _engine.removeAt(idx);
      if (state.repeat == PlaybackRepeat.one) {
        await _engine.setRepeatMode(PlaybackRepeat.one);
      }
      await _engine.play();
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

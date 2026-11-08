import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../platform/system_controls.dart';
import 'library.dart';
import 'outputs.dart';
import 'car_library.dart';
import 'player.dart';
import 'session.dart';

/// The OS media session. main.dart overrides this with the platform's
/// implementation; everywhere else (and in tests) it does nothing.
final systemControlsProvider = Provider<SystemControls>(
  (_) => const NoSystemControls(),
);

/// Why the OS media controls are not working, or `null`.
final systemControlsProblemProvider =
    NotifierProvider<_ProblemNotifier, String?>(_ProblemNotifier.new);

class _ProblemNotifier extends Notifier<String?> {
  @override
  String? build() {
    final problem = ref.watch(systemControlsProvider).problem;
    void update() => state = problem.value;
    problem.addListener(update);
    ref.onDispose(() => problem.removeListener(update));
    return problem.value;
  }
}

/// Keeps the OS media session in step with [PlayerController], and sends
/// its button presses back through the same controller methods the in-app
/// buttons use. Nothing here is platform specific: Windows SMTC today and
/// `audio_service` or MPRIS later all plug in through [SystemControls].
///
/// Watched once from the app root so it lives as long as the app.
final systemControlsBridgeProvider = Provider<void>((ref) {
  final controls = ref.watch(systemControlsProvider);
  final bridge = _Bridge(ref, controls);

  ref.listen(playerProvider, (_, _) => bridge.push(), fireImmediately: true);
  ref.listen(durationProvider, (_, _) => bridge.push());
  ref.listen(positionProvider, (_, _) => bridge.pushPosition());
  ref.listen(outputProvider, (_, _) => bridge.push());

  final sub = controls.commands.listen(bridge.handle);
  ref.onDispose(sub.cancel);

  // Android Auto browses and plays the library through the same session.
  if (controls is BrowsableSystemControls) {
    final browsable = controls as BrowsableSystemControls;
    browsable.attachLibrary(ref.watch(carLibraryProvider));
    ref.onDispose(() => browsable.attachLibrary(null));
  }
});

class _Bridge {
  final Ref ref;
  final SystemControls controls;
  _Bridge(this.ref, this.controls);

  /// The OS only needs the position now and then to draw its progress bar;
  /// a full update every second is plenty.
  static const _positionInterval = Duration(seconds: 1);
  final _sincePush = Stopwatch();

  // Updates go out one at a time, each built from the state at send time, so
  // a burst of changes collapses into one update and none arrive out of order.
  bool _sending = false;
  bool _dirty = false;

  PlayerController get _player => ref.read(playerProvider.notifier);

  void handle(MediaCommand cmd) {
    unawaited(switch (cmd) {
      PlayCommand() => _player.play(),
      PauseCommand() || StopCommand() => _player.pause(),
      TogglePlayCommand() => _player.togglePlay(),
      NextCommand() => _player.next(),
      PreviousCommand() => _player.previous(),
      SeekCommand(:final position) => _player.seek(position),
      ToggleShuffleCommand() => _player.toggleShuffle(),
      CycleRepeatCommand() => _player.cycleRepeat(),
      ToggleLikeCommand() => _toggleLike(),
      JumpToCommand(:final index) => _player.jumpTo(index),
      SetCastVolumeCommand(:final volume) =>
        ref.read(outputProvider.notifier).setVolume(volume),
      StepCastVolumeCommand(:final steps) =>
        ref.read(outputProvider.notifier).stepVolume(steps),
    });
  }

  Future<void> _toggleLike() async {
    final track = ref.read(playerProvider).current;
    if (track == null) return;
    try {
      await ref
          .read(likesProvider(LikeTarget.track).notifier)
          .toggle(track.id, fetched: track.liked);
    } catch (e) {
      debugPrint('Could not update like from the media controls: $e');
    }
    push();
  }

  /// The queue as last sent, so an unchanged queue keeps the same list.
  List<Track>? _queueOf;
  List<QueueEntry> _queue = const [];

  List<QueueEntry> _entries(List<Track> queue) {
    if (!identical(queue, _queueOf)) {
      _queueOf = queue;
      _queue = List.unmodifiable([
        for (final t in queue)
          QueueEntry(title: t.title, artist: t.artist, coverArt: t.coverArt),
      ]);
    }
    return _queue;
  }

  bool _liked(Track track) {
    try {
      return ref.read(likesProvider(LikeTarget.track))[track.id] ?? track.liked;
    } catch (_) {
      return track.liked;
    }
  }

  void pushPosition() {
    if (_sincePush.isRunning && _sincePush.elapsed < _positionInterval) return;
    push();
  }

  void push() {
    _sincePush
      ..reset()
      ..start();
    _dirty = true;
    if (!_sending) unawaited(_drain());
  }

  Future<void> _drain() async {
    _sending = true;
    try {
      while (_dirty) {
        _dirty = false;
        var info = _snapshot();
        if (info != null && controls.needsLocalArt) info = _localArt(info);
        await (info == null ? controls.clear() : controls.update(info));
      }
    } finally {
      _sending = false;
    }
  }

  /// The current track's cover as a local file, by artwork cache key:
  /// null while it is being fetched, or when it can't be had.
  String? _artKey;
  Uri? _artFile;

  /// Swaps the signed cover URL in [info] for a local file. The first
  /// update for a track goes out without art while the file is fetched,
  /// then is sent again with it.
  NowPlayingInfo _localArt(NowPlayingInfo info) {
    final url = info.artUri;
    final track = ref.read(playerProvider).current;
    final serverId = ref.read(sessionProvider).value?.serverId;
    final cache = ref.read(artworkCacheProvider);
    if (url == null || track?.coverArt == null || cache == null) {
      return info.withArt(null);
    }
    final key = '$serverId/${track!.coverArt}/$_artSize';
    if (key != _artKey) {
      _artKey = key;
      _artFile = null;
      unawaited(
        cache
            .localUri(key, url)
            .then(
              (file) {
                if (key != _artKey || file == null) return;
                _artFile = file;
                push();
              },
              onError: (Object _) {
                // No cover in the media controls, rather than the server URL.
              },
            ),
      );
    }
    return info.withArt(_artFile);
  }

  static const _artSize = 512;

  NowPlayingInfo? _snapshot() {
    final s = ref.read(playerProvider);
    final track = s.current;
    if (track == null) return null;
    final source = ref.read(sessionProvider).value?.source;
    return NowPlayingInfo(
      title: track.title,
      artist: track.artist,
      album: track.album,
      artUri: source?.coverArtUrl(track.coverArt, size: _artSize),
      playing: s.playing,
      position: ref.read(positionProvider).value ?? Duration.zero,
      duration: ref.read(durationProvider).value ?? track.duration,
      canGoNext: s.hasNext,
      // Previous restarts the current track, so it always does something.
      canGoPrevious: true,
      liked: _liked(track),
      shuffled: s.shuffled,
      repeat: s.repeat,
      queue: _entries(s.queue),
      queueIndex: s.currentIndex,
      castVolume: _castVolume(),
    );
  }

  double? _castVolume() {
    final output = ref.read(outputProvider);
    if (!output.isConnected) return null;
    return output.volume ?? 0.5;
  }
}

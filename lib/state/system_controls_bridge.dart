import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/system_controls.dart';
import 'player.dart';
import 'session.dart';

/// The OS media session. main.dart overrides this with the platform's
/// implementation; everywhere else (and in tests) it does nothing.
final systemControlsProvider = Provider<SystemControls>(
  (_) => const NoSystemControls(),
);

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

  final sub = controls.commands.listen(bridge.handle);
  ref.onDispose(sub.cancel);
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
    });
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
        final info = _snapshot();
        await (info == null ? controls.clear() : controls.update(info));
      }
    } finally {
      _sending = false;
    }
  }

  NowPlayingInfo? _snapshot() {
    final s = ref.read(playerProvider);
    final track = s.current;
    if (track == null) return null;
    final source = ref.read(sessionProvider).value?.source;
    return NowPlayingInfo(
      title: track.title,
      artist: track.artist,
      album: track.album,
      artUri: source?.coverArtUrl(track.coverArt, size: 512),
      playing: s.playing,
      position: ref.read(positionProvider).value ?? Duration.zero,
      duration: ref.read(durationProvider).value ?? track.duration,
      canGoNext: s.hasNext,
      // Previous restarts the current track, so it always does something.
      canGoPrevious: true,
    );
  }
}

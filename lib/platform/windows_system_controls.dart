import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';

import 'system_controls.dart';

/// [SystemControls] on Windows: the System Media Transport Controls (SMTC).
///
/// Registering with SMTC puts OAmp in the media overlay (volume flyout and
/// lock screen) and routes the keyboard's play/pause, next and previous keys
/// to it, even while the window is minimised or unfocused.
class WindowsSystemControls implements SystemControls {
  final SMTCWindows _smtc;
  final _commands = StreamController<MediaCommand>.broadcast();
  StreamSubscription<PressedButton>? _sub;
  NowPlayingInfo? _last;
  final _problem = ValueNotifier<String?>(null);

  void _fail(String what, Object e) {
    debugPrint('$what: $e');
    // Keep the first failure; later ones are usually the same cause.
    _problem.value ??= '$what: $e';
  }

  WindowsSystemControls._(this._smtc) {
    _sub = _smtc.buttonPressStream.listen((b) {
      final cmd = switch (b) {
        PressedButton.play => const PlayCommand(),
        PressedButton.pause => const PauseCommand(),
        PressedButton.next => const NextCommand(),
        PressedButton.previous => const PreviousCommand(),
        PressedButton.stop => const StopCommand(),
        _ => null,
      };
      if (cmd != null) _commands.add(cmd);
    }, onError: (Object e) => _fail('Media key events failed', e));
  }

  /// Loads the native library and registers with SMTC. If that fails the app
  /// still runs, with [NoSystemControls] reporting why.
  static Future<SystemControls> create() async {
    try {
      await SMTCWindows.initialize();
      final smtc = SMTCWindows(
        // Hidden until something is loaded.
        enabled: false,
        config: const SMTCConfig(
          playEnabled: true,
          pauseEnabled: true,
          nextEnabled: true,
          prevEnabled: true,
          stopEnabled: false,
          fastForwardEnabled: false,
          rewindEnabled: false,
        ),
      );
      return WindowsSystemControls._(smtc);
    } catch (e) {
      debugPrint('Windows media controls unavailable: $e');
      return NoSystemControls(
        unavailableReason: 'Windows media controls could not start: $e',
      );
    }
  }

  @override
  ValueListenable<String?> get problem => _problem;
  @override
  Stream<MediaCommand> get commands => _commands.stream;

  @override
  Future<void> update(NowPlayingInfo info) async {
    // Each step is tried on its own, so one failing (say, the cover art URL)
    // cannot stop the rest from showing. Windows only lists a session once
    // its status is Playing or Paused, so that goes first.
    final last = _last;
    await _try('Enabling the Windows media overlay failed', () async {
      if (!_smtc.enabled) await _smtc.enableSmtc();
    });
    await _try('Setting the play state failed', () async {
      final status = info.playing
          ? PlaybackStatus.playing
          : PlaybackStatus.paused;
      if (_smtc.status != status) await _smtc.setPlaybackStatus(status);
    });
    if (last == null || !last.sameMetadata(info)) {
      final metadata = MusicMetadata(
        title: info.title,
        artist: info.artist,
        album: info.album,
        albumArtist: info.artist,
        thumbnail: info.artUri?.toString(),
      );
      final ok = await _try('Showing the track failed', () async {
        try {
          await _smtc.updateMetadata(metadata);
        } catch (e) {
          if (metadata.thumbnail == null) rethrow;
          // Retry without the cover so title and artist still show.
          _fail('Showing the cover art failed', e);
          await _smtc.updateMetadata(
            MusicMetadata(
              title: metadata.title,
              artist: metadata.artist,
              album: metadata.album,
              albumArtist: metadata.albumArtist,
            ),
          );
        }
      });
      // Only remember metadata that reached Windows, so a failure is retried.
      _last = ok ? info : null;
    } else {
      _last = info;
    }
    if (last == null ||
        last.canGoNext != info.canGoNext ||
        last.canGoPrevious != info.canGoPrevious) {
      await _try('Setting the overlay buttons failed', () async {
        await _smtc.updateConfig(
          _smtc.config.copyWith(
            nextEnabled: info.canGoNext,
            prevEnabled: info.canGoPrevious,
          ),
        );
      });
    }
    await _try('Updating the progress bar failed', () async {
      final end = (info.duration ?? Duration.zero).inMilliseconds;
      await _smtc.updateTimeline(
        PlaybackTimeline(
          startTimeMs: 0,
          endTimeMs: end,
          positionMs: info.position.inMilliseconds.clamp(0, end),
          minSeekTimeMs: 0,
          maxSeekTimeMs: end,
        ),
      );
    });
  }

  Future<bool> _try(String what, Future<void> Function() step) async {
    try {
      await step();
      return true;
    } catch (e) {
      _fail(what, e);
      return false;
    }
  }

  @override
  Future<void> clear() async {
    _last = null;
    try {
      if (!_smtc.enabled) return;
      await _smtc.setPlaybackStatus(PlaybackStatus.stopped);
      await _smtc.clearMetadata();
      await _smtc.disableSmtc();
    } catch (e) {
      _fail('Clearing the Windows media overlay failed', e);
    }
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _commands.close();
    await _smtc.dispose();
  }
}

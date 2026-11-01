import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:smtc_windows/smtc_windows.dart';

import 'system_controls.dart';

/// [SystemControls] on Windows: the System Media Transport Controls (SMTC).
///
/// Registering with SMTC puts OAmp in the media overlay (quick settings and
/// lock screen).
///
/// Keyboard media keys are caught separately: Windows' forwarding of them to
/// the overlay session dropped most presses in testing, so while something
/// is loaded the runner registers them as system-wide hotkeys
/// (windows/runner/flutter_window.cpp) and reports each press on the
/// `oamp/media_keys` channel. When nothing is loaded the hotkeys are
/// released, so other apps get the keys back.
class WindowsSystemControls implements SystemControls {
  static const _mediaKeys = MethodChannel('oamp/media_keys');
  bool _keysHeld = false;
  MediaCommand? _lastKey;
  final _sinceKey = Stopwatch();

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
      final cmd = commandFor(b);
      // If Windows also forwards a key we caught as a hotkey, the press would
      // toggle twice and cancel itself out, so drop the echo.
      final echo =
          cmd != null &&
          cmd.runtimeType == _lastKey?.runtimeType &&
          _sinceKey.elapsed < const Duration(milliseconds: 500);
      if (cmd != null && !echo) _commands.add(cmd);
    }, onError: (Object e) => _fail('Media key events failed', e));
    _mediaKeys.setMethodCallHandler((call) async {
      if (call.method != 'pressed') return;
      final cmd = commandForKey(call.arguments as String?);
      if (cmd == null) return;
      _lastKey = cmd;
      _sinceKey
        ..reset()
        ..start();
      _commands.add(cmd);
    });
  }

  /// Maps a hotkey name from the runner to a player command.
  @visibleForTesting
  static MediaCommand? commandForKey(String? key) => switch (key) {
    'playPause' => const TogglePlayCommand(),
    'next' => const NextCommand(),
    'previous' => const PreviousCommand(),
    'stop' => const StopCommand(),
    _ => null,
  };

  Future<void> _holdKeys(bool hold) async {
    if (_keysHeld == hold) return;
    _keysHeld = hold;
    await _try('Registering the media keys failed', () async {
      if (hold) {
        // false means another app holds every key; the overlay still
        // forwards them, so this is not reported as an error.
        await _mediaKeys.invokeMethod<bool>('register');
      } else {
        await _mediaKeys.invokeMethod<void>('unregister');
      }
    });
  }

  /// Maps an SMTC button to a player command.
  ///
  /// A keyboard's single play/pause key reaches SMTC as Play or Pause,
  /// chosen from the status OAmp last reported. If that status lags the
  /// player by a moment (a track change, buffering, a press right after
  /// another), Windows sends the wrong one and an explicit Play/Pause would
  /// do nothing. Both are treated as a toggle of the player's real state,
  /// which is the same thing whenever the status is current.
  @visibleForTesting
  static MediaCommand? commandFor(PressedButton b) => switch (b) {
    PressedButton.play || PressedButton.pause => const TogglePlayCommand(),
    PressedButton.next => const NextCommand(),
    PressedButton.previous => const PreviousCommand(),
    PressedButton.stop => const StopCommand(),
    _ => null,
  };

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
    await _holdKeys(true);
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
    await _holdKeys(false);
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
    await _holdKeys(false);
    _mediaKeys.setMethodCallHandler(null);
    await _sub?.cancel();
    await _commands.close();
    await _smtc.dispose();
  }
}

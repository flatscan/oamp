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
    }, onError: (Object e) => debugPrint('SMTC button error: $e'));
  }

  /// Loads the native library and registers with SMTC. Returns `null` if that
  /// fails, so the app still runs without the overlay.
  static Future<WindowsSystemControls?> create() async {
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
      return null;
    }
  }

  @override
  Stream<MediaCommand> get commands => _commands.stream;

  @override
  Future<void> update(NowPlayingInfo info) async {
    try {
      final last = _last;
      _last = info;
      if (!_smtc.enabled) await _smtc.enableSmtc();
      if (last == null || !last.sameMetadata(info)) {
        await _smtc.updateMetadata(
          MusicMetadata(
            title: info.title,
            artist: info.artist,
            album: info.album,
            albumArtist: info.artist,
            thumbnail: info.artUri?.toString(),
          ),
        );
      }
      if (last == null ||
          last.canGoNext != info.canGoNext ||
          last.canGoPrevious != info.canGoPrevious) {
        await _smtc.updateConfig(
          _smtc.config.copyWith(
            nextEnabled: info.canGoNext,
            prevEnabled: info.canGoPrevious,
          ),
        );
      }
      final status = info.playing
          ? PlaybackStatus.playing
          : PlaybackStatus.paused;
      if (_smtc.status != status) await _smtc.setPlaybackStatus(status);
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
    } catch (e) {
      debugPrint('SMTC update failed: $e');
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
      debugPrint('SMTC clear failed: $e');
    }
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _commands.close();
    await _smtc.dispose();
  }
}

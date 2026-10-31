import 'dart:async';

/// What the OS media UI should show: the Windows media overlay today, and
/// later the Android notification, iOS/macOS Now Playing and Linux MPRIS.
class NowPlayingInfo {
  final String title;
  final String? artist;
  final String? album;

  /// Cover art the OS fetches itself. Stream and cover URLs are absolute and
  /// self-authenticating, so they work outside the app's HTTP client.
  final Uri? artUri;
  final bool playing;
  final Duration position;
  final Duration? duration;
  final bool canGoNext;
  final bool canGoPrevious;

  const NowPlayingInfo({
    required this.title,
    this.artist,
    this.album,
    this.artUri,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
    this.canGoNext = false,
    this.canGoPrevious = false,
  });

  /// Same track and metadata, ignoring transport state.
  bool sameMetadata(NowPlayingInfo o) =>
      title == o.title &&
      artist == o.artist &&
      album == o.album &&
      artUri == o.artUri &&
      duration == o.duration;
}

/// A button pressed outside the app: a keyboard media key, the Windows media
/// overlay, a headset, a lock screen or (v2) a car or watch.
sealed class MediaCommand {
  const MediaCommand();
}

class PlayCommand extends MediaCommand {
  const PlayCommand();
}

class PauseCommand extends MediaCommand {
  const PauseCommand();
}

class TogglePlayCommand extends MediaCommand {
  const TogglePlayCommand();
}

class NextCommand extends MediaCommand {
  const NextCommand();
}

class PreviousCommand extends MediaCommand {
  const PreviousCommand();
}

class StopCommand extends MediaCommand {
  const StopCommand();
}

class SeekCommand extends MediaCommand {
  final Duration position;
  const SeekCommand(this.position);
}

/// The OS media session. One implementation per platform family; the player
/// only ever talks to this interface (see state/system_controls_bridge.dart).
///
/// Windows uses SMTC (`WindowsSystemControls`). Android, iOS and macOS will
/// get an `audio_service` implementation and Linux an MPRIS one, without the
/// player or the UI changing.
abstract class SystemControls {
  /// Buttons pressed in the OS media UI or on the keyboard.
  Stream<MediaCommand> get commands;

  /// Shows [info] in the OS media UI.
  Future<void> update(NowPlayingInfo info);

  /// Nothing is loaded: hide the app from the OS media UI.
  Future<void> clear();

  Future<void> dispose();
}

/// Used on platforms without an implementation yet, and in tests.
class NoSystemControls implements SystemControls {
  const NoSystemControls();

  @override
  Stream<MediaCommand> get commands => const Stream.empty();
  @override
  Future<void> update(NowPlayingInfo info) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<void> dispose() async {}
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart' show PlaybackRepeat;

/// What the OS media UI should show: the Windows media overlay, the Android
/// notification and lock screen, and later iOS/macOS Now Playing and MPRIS.
class NowPlayingInfo {
  final String title;
  final String? artist;
  final String? album;

  /// Cover art the OS fetches itself. Stream and cover URLs are absolute and
  /// self-authenticating, so they work outside the app's HTTP client. For
  /// controls with [SystemControls.needsLocalArt] it is a local file.
  final Uri? artUri;
  final bool playing;
  final Duration position;
  final Duration? duration;
  final bool canGoNext;
  final bool canGoPrevious;

  /// Whether the track is liked, or null where liking isn't offered.
  final bool? liked;
  final bool shuffled;
  final PlaybackRepeat repeat;

  /// The play queue, for media UIs that list it (Android Auto). The list
  /// is replaced, never changed in place, so a new queue is a new list.
  final List<QueueEntry> queue;
  final int? queueIndex;

  /// While playing on a speaker or TV: its volume from 0 to 1, so the
  /// phone's volume keys and the OS volume panel control the device.
  /// Null for this device's own playback.
  final double? castVolume;

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
    this.liked,
    this.shuffled = false,
    this.repeat = PlaybackRepeat.off,
    this.queue = const [],
    this.queueIndex,
    this.castVolume,
  });

  NowPlayingInfo withArt(Uri? artUri) => NowPlayingInfo(
    title: title,
    artist: artist,
    album: album,
    artUri: artUri,
    playing: playing,
    position: position,
    duration: duration,
    canGoNext: canGoNext,
    canGoPrevious: canGoPrevious,
    liked: liked,
    shuffled: shuffled,
    repeat: repeat,
    queue: queue,
    queueIndex: queueIndex,
    castVolume: castVolume,
  );

  /// Same track and metadata, ignoring transport state.
  bool sameMetadata(NowPlayingInfo o) =>
      title == o.title &&
      artist == o.artist &&
      album == o.album &&
      artUri == o.artUri &&
      duration == o.duration;
}

/// One track in [NowPlayingInfo.queue].
class QueueEntry {
  final String title;
  final String? artist;

  /// The source's cover art id.
  final String? coverArt;

  const QueueEntry({required this.title, this.artist, this.coverArt});
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

class ToggleShuffleCommand extends MediaCommand {
  const ToggleShuffleCommand();
}

class CycleRepeatCommand extends MediaCommand {
  const CycleRepeatCommand();
}

class ToggleLikeCommand extends MediaCommand {
  const ToggleLikeCommand();
}

/// Play the queue entry at [index] (in [NowPlayingInfo.queue]).
class JumpToCommand extends MediaCommand {
  final int index;
  const JumpToCommand(this.index);
}

/// Set the speaker or TV's volume while casting (the OS volume panel).
class SetCastVolumeCommand extends MediaCommand {
  final double volume;
  const SetCastVolumeCommand(this.volume);
}

/// Turn the speaker or TV up or down while casting (volume keys): +1 for
/// a step up, -1 for a step down.
class StepCastVolumeCommand extends MediaCommand {
  final int steps;
  const StepCastVolumeCommand(this.steps);
}

class SeekCommand extends MediaCommand {
  final Duration position;
  const SeekCommand(this.position);
}

/// The OS media session. One implementation per platform family; the player
/// only ever talks to this interface (see state/system_controls_bridge.dart).
///
/// Windows uses SMTC (`WindowsSystemControls`) and Android `audio_service`
/// (`AndroidSystemControls`). iOS, macOS and Linux (MPRIS) can be added the
/// same way, without the player or the UI changing.
abstract class SystemControls {
  /// Why the OS media controls are not working, or `null` when they are (or
  /// when the platform has none yet). Shown in the app so a failure is not
  /// silent.
  ValueListenable<String?> get problem;

  /// Buttons pressed in the OS media UI or on the keyboard.
  Stream<MediaCommand> get commands;

  /// Whether cover art must be a local file rather than the server URL.
  /// The URL carries the sign-in token, and some media sessions (Android's)
  /// share it with every app and device that reads them.
  bool get needsLocalArt;

  /// Shows [info] in the OS media UI.
  Future<void> update(NowPlayingInfo info);

  /// Nothing is loaded: hide the app from the OS media UI.
  Future<void> clear();

  Future<void> dispose();
}

/// Used on platforms without an implementation yet, and in tests.
class NoSystemControls implements SystemControls {
  /// Set when a platform implementation exists but could not start.
  final String? unavailableReason;
  const NoSystemControls({this.unavailableReason});

  @override
  ValueListenable<String?> get problem => ValueNotifier(unavailableReason);
  @override
  Stream<MediaCommand> get commands => const Stream.empty();
  @override
  bool get needsLocalArt => false;
  @override
  Future<void> update(NowPlayingInfo info) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<void> dispose() async {}
}

/// One entry in the library a car (Android Auto) can browse: a folder to
/// open, or something to play.
class MediaNode {
  /// Opaque to the OS; [MediaLibrary] hands it back to open or play.
  final String id;
  final String title;
  final String? subtitle;

  /// The source's cover art id, which [MediaLibrary.artwork] turns into an
  /// image. Null for no picture.
  final String? coverArt;

  /// Played when picked, rather than opened as a folder.
  final bool playable;

  /// How the car lays out this folder's folders and playable items.
  final NodeStyle folderStyle;
  final NodeStyle itemStyle;

  /// A heading the car shows above a run of entries with the same group.
  final String? group;

  const MediaNode({
    required this.id,
    required this.title,
    this.subtitle,
    this.coverArt,
    this.playable = false,
    this.folderStyle = NodeStyle.list,
    this.itemStyle = NodeStyle.list,
    this.group,
  });
}

enum NodeStyle { list, grid }

/// What a voice request ("play Air on OAmp") asked for. [focus] says what
/// kind of thing the assistant understood, when it could tell.
class VoiceRequest {
  final String query;
  final VoiceFocus focus;
  final String? artist;
  final String? album;
  final String? title;
  final String? playlist;
  final String? genre;

  const VoiceRequest(
    this.query, {
    this.focus = VoiceFocus.any,
    this.artist,
    this.album,
    this.title,
    this.playlist,
    this.genre,
  });
}

enum VoiceFocus { any, artist, album, track, playlist, genre }

/// The library as a car head unit sees it: folders to browse, search, and
/// ways to start playback, all without the app's screens.
abstract class MediaLibrary {
  /// The top folder. Its children are the car's tabs.
  static const rootId = 'root';

  /// What the car offers to resume when it starts up.
  static const recentId = 'recent';

  Future<List<MediaNode>> children(String parentId);
  Future<List<MediaNode>> search(String query);

  /// Plays the playable node [id].
  Future<void> play(String id);
  Future<void> playFromVoice(VoiceRequest request);

  /// The cover image for a [MediaNode.coverArt] id, or null when there is
  /// none or it can't be fetched.
  Future<Uint8List?> artwork(String coverArt);

  /// Fires when what the folders hold has changed, such as after signing
  /// in or out.
  Stream<void> get changes;
}

/// [SystemControls] whose OS session can also be browsed, such as from
/// Android Auto.
abstract class BrowsableSystemControls {
  /// Serves [library] to the car, or stops when it is null.
  void attachLibrary(MediaLibrary? library);
}

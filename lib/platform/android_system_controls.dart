import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'system_controls.dart';

/// [SystemControls] on Android, through `audio_service`.
///
/// `audio_service` runs a foreground media service while something plays,
/// which keeps the app (and the audio) alive with the screen off or the app
/// in the background. Its media session drives the notification, the lock
/// screen controls, and Bluetooth and headset buttons.
///
/// The player itself stays in the app's own audio engine; this class only
/// mirrors its state into the session and sends button presses back.
class AndroidSystemControls implements SystemControls {
  static const _notifications = MethodChannel('oamp/notifications');

  final OampAudioHandler _handler;
  final _problem = ValueNotifier<String?>(null);
  final Future<bool> Function() _requestNotifications;
  bool _askedForNotifications = false;

  @visibleForTesting
  AndroidSystemControls(
    this._handler, {
    Future<bool> Function()? requestNotifications,
  }) : _requestNotifications =
           requestNotifications ?? _requestNotificationPermission;

  /// Starts the media session. If that fails the app still runs, with
  /// [NoSystemControls] reporting why.
  static Future<SystemControls> create() async {
    try {
      final handler = await AudioService.init(
        builder: OampAudioHandler.new,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.oamp.oamp.playback',
          androidNotificationChannelName: 'Playback',
          androidNotificationChannelDescription:
              'Shows what is playing, with playback controls',
          androidNotificationIcon: 'drawable/ic_stat_oamp',
          // While paused the notification can be swiped away and Android
          // may stop the service, as with other music players.
          androidStopForegroundOnPause: true,
          // Opening the app from the notification brings the player back
          // rather than starting a second copy.
          androidResumeOnClick: true,
          // Cover art is a file from the artwork cache (see needsLocalArt),
          // loaded by audio_service itself.
          artDownscaleWidth: 512,
          artDownscaleHeight: 512,
        ),
      );
      return AndroidSystemControls(handler);
    } catch (e) {
      debugPrint('Android media controls unavailable: $e');
      return NoSystemControls(
        unavailableReason: 'Android media controls could not start: $e',
      );
    }
  }

  /// Android 13 and later ask before an app may post notifications. The
  /// media notification is exempt on stock Android, but some phones still
  /// hide it without the permission, so it is asked for once, the first
  /// time something plays. MainActivity answers on `oamp/notifications`.
  static Future<bool> _requestNotificationPermission() async =>
      await _notifications.invokeMethod<bool>('requestPermission') ?? false;

  @override
  ValueListenable<String?> get problem => _problem;

  @override
  Stream<MediaCommand> get commands => _handler.commands;

  /// The session's art URI is visible to car units, watches and any app
  /// that reads media sessions, so it must not be the signed server URL.
  @override
  bool get needsLocalArt => true;

  @override
  Future<void> update(NowPlayingInfo info) async {
    if (!_askedForNotifications && info.playing) {
      _askedForNotifications = true;
      unawaited(
        _requestNotifications().then(
          (_) {},
          onError: (Object e) =>
              debugPrint('Asking for the notification permission failed: $e'),
        ),
      );
    }
    try {
      _handler.show(info);
    } catch (e) {
      debugPrint('Updating the Android media session failed: $e');
      _problem.value ??= 'Updating the Android media session failed: $e';
    }
  }

  @override
  Future<void> clear() async => _handler.hide();

  @override
  Future<void> dispose() async {
    _handler.hide();
    await _handler.close();
  }
}

/// The `audio_service` handler: holds the session state the notification
/// shows, and turns its callbacks into [MediaCommand]s.
class OampAudioHandler extends BaseAudioHandler {
  final _commands = StreamController<MediaCommand>.broadcast();

  Stream<MediaCommand> get commands => _commands.stream;

  /// What is showing now, so unchanged metadata is not sent again (each
  /// change makes Android redraw the notification and refetch the art).
  @visibleForTesting
  NowPlayingInfo? last;

  /// Shows [info] in the notification, the lock screen and on connected
  /// Bluetooth devices.
  void show(NowPlayingInfo info) {
    final previous = last;
    last = info;
    if (previous == null || !previous.sameMetadata(info)) {
      mediaItem.add(mediaItemFor(info));
    }
    playbackState.add(stateFor(info));
  }

  /// Nothing is loaded: an idle session stops the service and removes the
  /// notification.
  void hide() {
    last = null;
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
    mediaItem.add(null);
  }

  Future<void> close() => _commands.close();

  @visibleForTesting
  static MediaItem mediaItemFor(NowPlayingInfo info) => MediaItem(
    // The id only has to change with the track; the art URL does, and the
    // title covers tracks without art.
    id: '${info.artUri ?? ''}|${info.title}|${info.album ?? ''}',
    title: info.title,
    artist: info.artist,
    album: info.album,
    artUri: info.artUri,
    duration: info.duration,
  );

  @visibleForTesting
  static PlaybackState stateFor(NowPlayingInfo info) {
    final controls = [
      if (info.canGoPrevious) MediaControl.skipToPrevious,
      info.playing ? MediaControl.pause : MediaControl.play,
      if (info.canGoNext) MediaControl.skipToNext,
    ];
    return PlaybackState(
      controls: controls,
      // The seek bar on the notification and lock screen.
      systemActions: const {MediaAction.seek},
      // The collapsed notification shows every button; there are at most 3.
      androidCompactActionIndices: [
        for (var i = 0; i < controls.length; i++) i,
      ],
      // Ready even while paused, so the paused notification stays until the
      // user swipes it away; idle is kept for "nothing loaded" (see hide).
      processingState: AudioProcessingState.ready,
      playing: info.playing,
      updatePosition: info.position,
      speed: 1,
    );
  }

  void _send(MediaCommand cmd) {
    if (!_commands.isClosed) _commands.add(cmd);
  }

  @override
  Future<void> play() async => _send(const PlayCommand());

  @override
  Future<void> pause() async => _send(const PauseCommand());

  @override
  Future<void> stop() async => _send(const StopCommand());

  @override
  Future<void> skipToNext() async => _send(const NextCommand());

  @override
  Future<void> skipToPrevious() async => _send(const PreviousCommand());

  @override
  Future<void> seek(Duration position) async => _send(SeekCommand(position));

  /// A headset or Bluetooth button. A single press toggles the player's real
  /// state rather than the state the session last showed, which can lag by a
  /// moment; double and triple presses skip, as on other players.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async =>
      _send(switch (button) {
        MediaButton.media => const TogglePlayCommand(),
        MediaButton.next => const NextCommand(),
        MediaButton.previous => const PreviousCommand(),
      });

  /// Swiping the app away from recents while paused ends the session;
  /// while playing, the music keeps going.
  @override
  Future<void> onTaskRemoved() async {
    if (!playbackState.value.playing) _send(const StopCommand());
  }
}

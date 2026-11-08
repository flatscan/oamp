import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/models.dart' show PlaybackRepeat;
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
class AndroidSystemControls implements SystemControls, BrowsableSystemControls {
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
          // Android Auto: search, and the layout hints used on the
          // folders (see OampAudioHandler.mediaItemForNode).
          androidBrowsableRootExtras: {
            'android.media.browse.SEARCH_SUPPORTED': true,
            AndroidContentStyle.supportedKey: true,
            AndroidContentStyle.browsableHintKey:
                AndroidContentStyle.listItemHintValue,
            AndroidContentStyle.playableHintKey:
                AndroidContentStyle.listItemHintValue,
          },
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
  void attachLibrary(MediaLibrary? library) => _handler.attachLibrary(library);

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
    if (!identical(previous?.queue, info.queue)) _showQueue(info);
    playbackState.add(stateFor(info, queueStart: _queueStart));
  }

  /// Nothing is loaded: an idle session stops the service and removes the
  /// notification.
  void hide() {
    last = null;
    _queueStart = 0;
    queue.add(const []);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
    mediaItem.add(null);
  }

  Future<void> close() async {
    attachLibrary(null);
    await _commands.close();
  }

  // Android Auto.

  static const _artChannel = MethodChannel('oamp/artwork');

  /// What Android Auto browses, plays from and searches.
  MediaLibrary? _library;
  StreamSubscription<void>? _libraryChanges;

  /// Tells connected cars the folders changed, so they load them again.
  /// Replaceable in tests, where there is no media service.
  @visibleForTesting
  void Function() notifyRootChanged = _notifyRootChanged;

  @visibleForTesting
  MediaLibrary? get library => _library;

  void attachLibrary(MediaLibrary? library) {
    _libraryChanges?.cancel();
    _libraryChanges = null;
    _library = library;
    if (library == null) {
      _artChannel.setMethodCallHandler(null);
      return;
    }
    _libraryChanges = library.changes.listen((_) => notifyRootChanged());
    _artChannel.setMethodCallHandler(_answerArtwork);
    // A car that connected while the app was still starting got an empty
    // root; have it ask again now that there is a library to show.
    notifyRootChanged();
  }

  static void _notifyRootChanged() {
    // The handler-level replacement (subscribeToChildren) only reaches
    // folders a car has already loaded once through the handler, and the
    // old AudioServiceBackground call sends no options, which the Android
    // side refuses. Ask the platform directly, with empty options.
    unawaited(
      AudioServicePlatform.instance
          .notifyChildrenChanged(
            const NotifyChildrenChangedRequest(
              parentMediaId: AudioService.browsableRootId,
              options: {},
            ),
          )
          .catchError((Object e) {
            debugPrint('Could not refresh Android Auto: $e');
          }),
    );
  }

  /// Cover art for Android Auto, asked for by ArtworkProvider (Kotlin) on
  /// behalf of the car, which never sees the signed server URL.
  Future<Uint8List?> _answerArtwork(MethodCall call) async {
    final library = _library;
    if (call.method != 'artwork' || library == null) return null;
    return library.artwork(call.arguments as String);
  }

  /// Where the car fetches a cover from: OAmp's own content provider,
  /// which serves it from the artwork cache.
  @visibleForTesting
  static Uri artworkUri(String coverArt) => Uri(
    scheme: 'content',
    host: 'dev.oamp.oamp.artwork',
    pathSegments: [coverArt],
  );

  @visibleForTesting
  static MediaItem mediaItemForNode(MediaNode n) => MediaItem(
    id: n.id,
    title: n.title,
    artist: n.subtitle,
    displaySubtitle: n.subtitle,
    artUri: n.coverArt == null ? null : artworkUri(n.coverArt!),
    playable: n.playable,
    extras: {
      if (!n.playable) ...{
        AndroidContentStyle.browsableHintKey: _hint(n.folderStyle),
        AndroidContentStyle.playableHintKey: _hint(n.itemStyle),
      },
      if (n.group != null)
        'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT': n.group,
    },
  );

  static int _hint(NodeStyle s) => switch (s) {
    NodeStyle.list => AndroidContentStyle.listItemHintValue,
    NodeStyle.grid => AndroidContentStyle.gridItemHintValue,
  };

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    final library = _library;
    if (library == null) return const [];
    final nodes = await library.children(parentMediaId);
    return [for (final n in nodes) mediaItemForNode(n)];
  }

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final library = _library;
    if (library == null) return const [];
    final nodes = await library.search(query);
    return [for (final n in nodes) mediaItemForNode(n)];
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async => _library?.play(mediaId);

  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async => _library?.playFromVoice(voiceRequest(query, extras));

  /// Reads the extras Google Assistant sends with "play ... on OAmp"
  /// (MediaStore.EXTRA_MEDIA_FOCUS and friends).
  @visibleForTesting
  static VoiceRequest voiceRequest(String query, Map<String, dynamic>? e) {
    String? text(String key) {
      final v = e?[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    return VoiceRequest(
      query,
      focus: switch (text('android.intent.extra.focus')) {
        'vnd.android.cursor.item/artist' => VoiceFocus.artist,
        'vnd.android.cursor.item/album' => VoiceFocus.album,
        'vnd.android.cursor.item/audio' => VoiceFocus.track,
        'vnd.android.cursor.item/playlist' => VoiceFocus.playlist,
        'vnd.android.cursor.item/genre' || 'audio/genre' => VoiceFocus.genre,
        _ => VoiceFocus.any,
      },
      artist: text('android.intent.extra.artist'),
      album: text('android.intent.extra.album'),
      title: text('android.intent.extra.title'),
      playlist: text('android.intent.extra.playlist'),
      genre: text('android.intent.extra.genre'),
    );
  }

  @visibleForTesting
  static MediaItem mediaItemFor(NowPlayingInfo info) => MediaItem(
    // The id only has to change with the track; the art URL does, and the
    // title covers tracks without art.
    id: '${info.artUri ?? ''}|${info.title}|${info.album ?? ''}',
    title: info.title,
    artist: info.artist,
    album: info.album,
    artUri: sharedArtUri(info.artUri),
    duration: info.duration,
  );

  /// The cover as Android Auto's home screen can read it. That screen runs
  /// in another app and can't open the app's own files, so a cover from the
  /// artwork cache goes out as a content URI that ArtworkProvider serves
  /// straight from the file (the notification and lock screen read it the
  /// same way). Anything else is left as it is.
  @visibleForTesting
  static Uri? sharedArtUri(Uri? art) {
    if (art == null || art.scheme != 'file') return art;
    final segments = art.pathSegments;
    if (segments.length < 2 ||
        segments[segments.length - 2] != 'artwork' ||
        !_cachedArtName.hasMatch(segments.last)) {
      return art;
    }
    return Uri(
      scheme: 'content',
      host: 'dev.oamp.oamp.artwork',
      pathSegments: ['file', segments.last],
    );
  }

  /// DiskArtworkCache's file names: a SHA-1 of the key, then `.art`.
  static final _cachedArtName = RegExp(r'^[0-9a-f]{40}\.art$');

  /// The queue Android Auto lists from Now Playing. A long queue is sent
  /// as a window around the current track; [_queueStart] is where the
  /// window begins, so queue item ids map back to queue positions.
  int _queueStart = 0;

  /// The most queue entries sent at once.
  static const queueWindow = 300;

  void _showQueue(NowPlayingInfo info) {
    final all = info.queue;
    final current = info.queueIndex ?? 0;
    _queueStart = all.length <= queueWindow
        ? 0
        : (current - queueWindow ~/ 3).clamp(0, all.length - queueWindow);
    final end = (_queueStart + queueWindow).clamp(0, all.length);
    queue.add([
      for (var i = _queueStart; i < end; i++)
        MediaItem(
          id: 'queue/$i',
          title: all[i].title,
          artist: all[i].artist,
          artUri: all[i].coverArt == null ? null : artworkUri(all[i].coverArt!),
        ),
    ]);
  }

  // Android Auto shows custom actions as extra buttons beside the transport
  // controls (and Android 13+ in the notification's spare slots).
  static const likeAction = 'oamp.like';
  static const shuffleAction = 'oamp.shuffle';
  static const repeatAction = 'oamp.repeat';

  static List<MediaControl> _extraControls(NowPlayingInfo info) => [
    if (info.liked != null)
      MediaControl.custom(
        androidIcon: info.liked!
            ? 'drawable/ic_media_liked'
            : 'drawable/ic_media_like',
        label: info.liked! ? 'Unlike' : 'Like',
        name: likeAction,
      ),
    MediaControl.custom(
      androidIcon: info.shuffled
          ? 'drawable/ic_media_shuffle_on'
          : 'drawable/ic_media_shuffle_off',
      label: info.shuffled ? 'Shuffle on' : 'Shuffle off',
      name: shuffleAction,
    ),
    MediaControl.custom(
      androidIcon: switch (info.repeat) {
        PlaybackRepeat.off => 'drawable/ic_media_repeat_off',
        PlaybackRepeat.all => 'drawable/ic_media_repeat_all',
        PlaybackRepeat.one => 'drawable/ic_media_repeat_one',
      },
      label: switch (info.repeat) {
        PlaybackRepeat.off => 'Repeat off',
        PlaybackRepeat.all => 'Repeat queue',
        PlaybackRepeat.one => 'Repeat track',
      },
      name: repeatAction,
    ),
  ];

  @visibleForTesting
  static PlaybackState stateFor(NowPlayingInfo info, {int queueStart = 0}) {
    final transport = [
      if (info.canGoPrevious) MediaControl.skipToPrevious,
      info.playing ? MediaControl.pause : MediaControl.play,
      if (info.canGoNext) MediaControl.skipToNext,
    ];
    final index = info.queueIndex;
    return PlaybackState(
      controls: [...transport, ..._extraControls(info)],
      queueIndex: index == null ? null : index - queueStart,
      // The seek bar on the notification and lock screen.
      systemActions: const {MediaAction.seek},
      // The collapsed notification shows every button; there are at most 3.
      androidCompactActionIndices: [
        for (var i = 0; i < transport.length; i++) i,
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

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async => switch (name) {
    likeAction => _send(const ToggleLikeCommand()),
    shuffleAction => _send(const ToggleShuffleCommand()),
    repeatAction => _send(const CycleRepeatCommand()),
    _ => null,
  };

  /// A track picked from the queue list on Android Auto's Now Playing.
  @override
  Future<void> skipToQueueItem(int index) async =>
      _send(JumpToCommand(_queueStart + index));

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

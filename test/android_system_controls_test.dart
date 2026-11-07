import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/platform/android_system_controls.dart';
import 'package:oamp/platform/system_controls.dart';

void main() {
  final art = Uri.parse('http://music.local/rest/getCoverArt?id=al-1');
  NowPlayingInfo info({
    String title = 'Track',
    bool playing = true,
    bool canGoNext = true,
    bool canGoPrevious = true,
    Duration position = Duration.zero,
  }) => NowPlayingInfo(
    title: title,
    artist: 'Artist',
    album: 'Album',
    artUri: art,
    playing: playing,
    position: position,
    duration: const Duration(minutes: 3),
    canGoNext: canGoNext,
    canGoPrevious: canGoPrevious,
  );

  late OampAudioHandler handler;
  late AndroidSystemControls controls;
  late int permissionRequests;

  setUp(() {
    handler = OampAudioHandler();
    permissionRequests = 0;
    controls = AndroidSystemControls(
      handler,
      requestNotifications: () async {
        permissionRequests++;
        return true;
      },
    );
  });

  test('shows the track with art, duration and a seek bar', () async {
    await controls.update(info(position: const Duration(seconds: 42)));

    final item = handler.mediaItem.value!;
    expect(item.title, 'Track');
    expect(item.artist, 'Artist');
    expect(item.album, 'Album');
    expect(item.artUri, art);
    expect(item.duration, const Duration(minutes: 3));

    final state = handler.playbackState.value;
    expect(state.playing, isTrue);
    expect(state.processingState, AudioProcessingState.ready);
    expect(state.updatePosition, const Duration(seconds: 42));
    expect(state.systemActions, contains(MediaAction.seek));
    expect(state.controls, [
      MediaControl.skipToPrevious,
      MediaControl.pause,
      MediaControl.skipToNext,
    ]);
    expect(state.androidCompactActionIndices, [0, 1, 2]);
  });

  test('paused shows play, and next is hidden at the end of the queue', () {
    final state = OampAudioHandler.stateFor(
      info(playing: false, canGoNext: false),
    );
    expect(state.controls, [MediaControl.skipToPrevious, MediaControl.play]);
    expect(state.androidCompactActionIndices, [0, 1]);
    // Still ready, so the paused notification stays until swiped away.
    expect(state.processingState, AudioProcessingState.ready);
  });

  test('only sends metadata again when the track changes', () async {
    final items = <MediaItem?>[];
    final sub = handler.mediaItem.listen(items.add);
    addTearDown(sub.cancel);

    await controls.update(info());
    await controls.update(info(position: const Duration(seconds: 1)));
    await controls.update(info(playing: false));
    await controls.update(info(title: 'Next track'));
    await pumpEventQueue();

    expect(items.whereType<MediaItem>().map((i) => i.title), [
      'Track',
      'Next track',
    ]);
  });

  test('clear makes the session idle so the notification goes', () async {
    await controls.update(info());
    await controls.clear();

    expect(handler.mediaItem.value, isNull);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    expect(handler.playbackState.value.playing, isFalse);

    // The next track shows again in full.
    await controls.update(info());
    expect(handler.mediaItem.value!.title, 'Track');
  });

  test('asks for the notification permission once, at first play', () async {
    await controls.update(info(playing: false));
    expect(permissionRequests, 0);
    await controls.update(info());
    await controls.update(info(title: 'Next track'));
    expect(permissionRequests, 1);
  });

  test('a failed permission request does not stop the session', () async {
    final failing = AndroidSystemControls(
      handler,
      requestNotifications: () => Future.error(Exception('no activity')),
    );
    await failing.update(info());
    await pumpEventQueue();
    expect(handler.mediaItem.value!.title, 'Track');
    expect(failing.problem.value, isNull);
  });

  test(
    'notification, lock screen and Bluetooth buttons become commands',
    () async {
      final got = <MediaCommand>[];
      final sub = controls.commands.listen(got.add);
      addTearDown(sub.cancel);

      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.seek(const Duration(seconds: 30));
      await handler.stop();
      // Swiping the notification away while paused.
      await handler.onNotificationDeleted();
      await pumpEventQueue();

      expect(got.map((c) => c.runtimeType), [
        PlayCommand,
        PauseCommand,
        NextCommand,
        PreviousCommand,
        SeekCommand,
        StopCommand,
        StopCommand,
      ]);
      expect((got[4] as SeekCommand).position, const Duration(seconds: 30));
    },
  );

  test('headset button presses toggle and skip', () async {
    final got = <MediaCommand>[];
    final sub = controls.commands.listen(got.add);
    addTearDown(sub.cancel);

    // Even if the session still shows "paused", one press toggles the
    // player's real state.
    await controls.update(info(playing: false));
    await handler.click();
    await handler.click(MediaButton.next);
    await handler.click(MediaButton.previous);
    await pumpEventQueue();

    expect(got.map((c) => c.runtimeType), [
      TogglePlayCommand,
      NextCommand,
      PreviousCommand,
    ]);
  });

  test('removing the app from recents stops only when paused', () async {
    final got = <MediaCommand>[];
    final sub = controls.commands.listen(got.add);
    addTearDown(sub.cancel);

    await controls.update(info());
    await handler.onTaskRemoved();
    await controls.update(info(playing: false));
    await handler.onTaskRemoved();
    await pumpEventQueue();

    expect(got.map((c) => c.runtimeType), [StopCommand]);
  });

  group('Android Auto', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late _FakeLibrary library;
    late int refreshes;

    setUp(() {
      library = _FakeLibrary();
      refreshes = 0;
      handler.notifyRootChanged = () => refreshes++;
      controls.attachLibrary(library);
    });

    test('attaching asks connected cars to reload, as do changes', () async {
      expect(refreshes, 1);
      library.changed.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(refreshes, 2);
      controls.attachLibrary(null);
      expect(handler.library, isNull);
      expect(await handler.getChildren('root'), isEmpty);
    });

    test('folders become browsable items with layout hints', () async {
      final items = await handler.getChildren('root');
      expect(library.opened, ['root']);
      final folder = items.first;
      expect(folder.id, 'album/al1');
      expect(folder.title, 'Moon Safari');
      expect(folder.artist, 'Air');
      expect(folder.playable, isFalse);
      // The car fetches art from the app, never from the signed URL.
      expect(folder.artUri.toString(), 'content://dev.oamp.oamp.artwork/al-1');
      expect(
        folder.extras![AndroidContentStyle.browsableHintKey],
        AndroidContentStyle.gridItemHintValue,
      );
      expect(
        folder.extras!['android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT'],
        'Recently added',
      );

      final song = items.last;
      expect(song.playable, isTrue);
      expect(song.artUri, isNull);
      expect(
        song.extras!.containsKey(AndroidContentStyle.browsableHintKey),
        isFalse,
      );
    });

    test('playing, searching and voice go to the library', () async {
      await handler.playFromMediaId('play/album/al1/0');
      expect(library.played, ['play/album/al1/0']);

      final found = await handler.search('moon');
      expect(found, hasLength(2));
      expect(library.searched, ['moon']);

      await handler.playFromSearch('air', {
        'android.intent.extra.focus': 'vnd.android.cursor.item/artist',
        'android.intent.extra.artist': 'Air',
      });
      final r = library.voice.single;
      expect(r.query, 'air');
      expect(r.focus, VoiceFocus.artist);
      expect(r.artist, 'Air');
    });

    test('voice extras: unknown or missing focus means anything', () {
      expect(OampAudioHandler.voiceRequest('x', null).focus, VoiceFocus.any);
      expect(
        OampAudioHandler.voiceRequest('x', {
          'android.intent.extra.focus': 'vnd.android.cursor.item/album',
          'android.intent.extra.album': '  ',
        }),
        isA<VoiceRequest>()
            .having((r) => r.focus, 'focus', VoiceFocus.album)
            .having((r) => r.album, 'blank album', isNull),
      );
    });
  });
}

class _FakeLibrary implements MediaLibrary {
  final changed = StreamController<void>.broadcast();
  final opened = <String>[];
  final played = <String>[];
  final searched = <String>[];
  final voice = <VoiceRequest>[];

  static const _nodes = [
    MediaNode(
      id: 'album/al1',
      title: 'Moon Safari',
      subtitle: 'Air',
      coverArt: 'al-1',
      folderStyle: NodeStyle.grid,
      group: 'Recently added',
    ),
    MediaNode(id: 'play/album/al1/0', title: 'Sexy Boy', playable: true),
  ];

  @override
  Stream<void> get changes => changed.stream;
  @override
  Future<List<MediaNode>> children(String parentId) async {
    opened.add(parentId);
    return _nodes;
  }

  @override
  Future<List<MediaNode>> search(String query) async {
    searched.add(query);
    return _nodes;
  }

  @override
  Future<void> play(String id) async => played.add(id);
  @override
  Future<void> playFromVoice(VoiceRequest request) async => voice.add(request);
  @override
  Future<Uint8List?> artwork(String coverArt) async => null;
}

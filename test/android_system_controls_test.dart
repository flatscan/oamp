import 'package:audio_service/audio_service.dart';
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
}

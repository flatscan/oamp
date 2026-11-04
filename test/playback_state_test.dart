import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/state/playback_reporter.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

void main() {
  const tracks = [
    Track(id: 'a', title: 'A', duration: Duration(minutes: 4)),
    Track(id: 'b', title: 'B', duration: Duration(minutes: 4)),
  ];
  late FakeAudioEngine engine;
  late FakeMusicSource source;
  late ProviderContainer container;

  setUp(() async {
    engine = FakeAudioEngine();
    source = FakeMusicSource()
      ..capabilities = const SourceCapabilities(hasPlaybackState: true);
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        audioEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    container.read(playbackReporterProvider);
    container.listen(positionProvider, (_, _) {});
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  PlayerController player() => container.read(playerProvider.notifier);
  List<String> calls() => List.of(source.calls);

  test('start, pause and resume are reported with the position', () async {
    await player().playTracks(tracks);
    await settle();
    expect(calls(), ['state:starting:a:0', 'state:playing:a:0']);

    engine.emitPosition(const Duration(seconds: 75));
    await settle();
    await player().pause();
    await settle();
    expect(calls().last, 'state:paused:a:75');

    await player().play();
    await settle();
    expect(calls().last, 'state:playing:a:75');
    // Plays are still counted by scrobble alone.
    expect(calls().where((c) => c.startsWith('playing:')), isEmpty);
  });

  test('a seek is reported at once', () async {
    await player().playTracks(tracks);
    await settle();
    engine.emitPosition(const Duration(seconds: 10));
    await settle();
    final before = calls().length;
    engine.emitPosition(const Duration(seconds: 100));
    await settle();
    expect(calls().skip(before), ['state:playing:a:100']);
  });

  test(
    'moving to the next track stops the old one and starts the new',
    () async {
      await player().playTracks(tracks);
      await settle();
      engine.emitPosition(const Duration(seconds: 200));
      await settle();
      final before = calls().length;
      await player().next();
      await settle();
      expect(calls().skip(before), [
        'state:stopped:a:200',
        'state:starting:b:0',
        'state:playing:b:0',
      ]);
    },
  );

  test('stopping, as when the app closes, is reported', () async {
    await player().playTracks(tracks);
    await settle();
    engine.emitPosition(const Duration(seconds: 30));
    await settle();
    container.read(playbackReporterProvider).stop();
    expect(calls().last, 'state:stopped:a:30');
  });

  test('a restored paused queue is not reported', () async {
    await player().playTracks(tracks);
    await settle();
    await player().pause();
    await settle();
    final before = calls().length;
    await settle();
    expect(calls().length, before);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/state/library.dart';
import 'package:oamp/state/playback_reporter.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

void main() {
  late FakeAudioEngine engine;
  late FakeMusicSource source;
  late ProviderContainer container;

  final many = [
    for (var i = 0; i < 6; i++)
      Track(id: 'm$i', title: 'Track $i', duration: const Duration(minutes: 3)),
  ];

  setUp(() async {
    engine = FakeAudioEngine();
    source = FakeMusicSource();
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        audioEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  PlayerController player() => container.read(playerProvider.notifier);
  PlayerState state() => container.read(playerProvider);

  test('repeat cycles off, queue, track and reaches the engine', () async {
    expect(state().repeat, PlaybackRepeat.off);
    await player().cycleRepeat();
    expect(engine.repeat, PlaybackRepeat.all);
    await player().cycleRepeat();
    expect(engine.repeat, PlaybackRepeat.one);
    await player().cycleRepeat();
    expect(state().repeat, PlaybackRepeat.off);
  });

  test('repeat queue makes next available on the last track', () async {
    await player().playTracks(many, startIndex: 5);
    await settle();
    expect(state().hasNext, isFalse);
    await player().cycleRepeat();
    expect(state().hasNext, isTrue);
  });

  test('shuffle up next keeps played and current tracks in place', () async {
    await player().playTracks(many, startIndex: 2);
    await settle();
    await player().shuffleUpcoming();
    final ids = state().queue.map((t) => t.id).toList();
    expect(ids.take(3), ['m0', 'm1', 'm2']);
    expect(ids.skip(3).toSet(), {'m3', 'm4', 'm5'});
    // The engine's queue matches the controller's order.
    expect(engine.queue.map((u) => u.pathSegments.last), ids);
  });

  test('clear up next leaves the current track playing', () async {
    await player().playTracks(many, startIndex: 1);
    await settle();
    await player().clearUpcoming();
    expect(state().queue.map((t) => t.id), ['m0', 'm1']);
    expect(engine.queue, hasLength(2));
    expect(state().current?.id, 'm1');
  });

  test('volume is clamped and survives clearing the queue', () async {
    await player().setVolume(1.4);
    expect(engine.volume, 1);
    await player().setVolume(0.3);
    await player().playTracks(many);
    await player().clear();
    expect(state().volume, 0.3);
  });

  test('shuffled play starts from a random order of the same tracks', () async {
    await player().playTracks(many, startIndex: 4, shuffle: true, from: 'X');
    expect(state().currentIndex, 0);
    expect(state().from, 'X');
    expect(
      state().queue.map((t) => t.id).toSet(),
      many.map((t) => t.id).toSet(),
    );
  });

  test('reports now playing, then a play after half the track', () async {
    container.read(playbackReporterProvider);
    // The reporter reads positions through this provider; keep it alive.
    container.listen(positionProvider, (_, _) {});
    await player().playTracks(many);
    await settle();
    expect(source.calls, ['playing:m0']);

    engine.emitPosition(const Duration(seconds: 60));
    await settle();
    expect(source.calls, ['playing:m0']);

    engine.emitPosition(const Duration(seconds: 91));
    await settle();
    engine.emitPosition(const Duration(seconds: 120));
    await settle();
    expect(source.calls, ['playing:m0', 'played:m0']);

    await player().next();
    await settle();
    expect(source.calls.last, 'playing:m1');
  });

  test('album pages load once even when asked repeatedly', () async {
    final sub = container.listen(
      albumPagesProvider(AlbumSort.alphabetical),
      (_, _) {},
    );
    addTearDown(sub.close);
    final n = container.read(
      albumPagesProvider(AlbumSort.alphabetical).notifier,
    );
    await Future.wait([n.loadMore(), n.loadMore(), n.loadMore()]);
    await settle();
    final pages = container.read(albumPagesProvider(AlbumSort.alphabetical));
    expect(pages.albums.map((a) => a.name), ['Moon Safari']);
    expect(pages.done, isTrue);
  });
}

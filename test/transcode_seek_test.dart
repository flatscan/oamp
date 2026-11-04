import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/core/play_queue.dart';
import 'package:oamp/core/playback_options.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';

import 'fakes/fakes.dart';

/// Seeking in transcoded streams, which servers usually cannot seek by
/// byte range: the player reopens the stream part way in instead.
void main() {
  late FakeAudioEngine engine;
  late FakeMusicSource source;
  late ProviderContainer container;
  const opus = StreamQuality(format: StreamFormat.opus, bitRate: 128);

  final tracks = [
    for (var i = 0; i < 3; i++)
      Track(id: 't$i', title: 'Track $i', duration: const Duration(minutes: 3)),
  ];

  Future<void> start({
    StreamQuality quality = opus,
    bool offsets = true,
  }) async {
    engine = FakeAudioEngine();
    source = FakeMusicSource()
      ..capabilities = SourceCapabilities(
        extensions: {
          if (offsets) 'transcodeOffset': [1],
        },
      );
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        audioEngineProvider.overrideWithValue(engine),
        streamQualityProvider.overrideWithValue(quality),
      ],
    );
    addTearDown(container.dispose);
    container.listen(positionProvider, (_, _) {});
    container.listen(durationProvider, (_, _) {});
    await container.read(sessionProvider.future);
    // Let the extensions arrive.
    container.read(capabilitiesProvider);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  PlayerController player() => container.read(playerProvider.notifier);
  PlayerState state() => container.read(playerProvider);
  List<String> engineQueue() => [for (final u in engine.queue) '$u'];

  test('a seek in a transcoded stream reopens it at that point', () async {
    await start();
    await player().playTracks(tracks, startIndex: 1);
    await settle();
    await player().seek(const Duration(seconds: 95, milliseconds: 600));
    await settle();

    expect(engineQueue(), [
      'fake://stream/t0?q=opus128',
      'fake://stream/t1?q=opus128&t=95',
      'fake://stream/t2?q=opus128',
    ]);
    expect(engine.index, 1);
    expect(engine.playing, isTrue);
    expect(state().current?.id, 't1');
    expect(state().offset, const Duration(seconds: 95));

    // Positions count from the start of the track, and the length is the
    // track's, not what is left of the stream.
    engine.emitPosition(const Duration(seconds: 5));
    await settle();
    expect(
      container.read(positionProvider).value,
      const Duration(seconds: 100),
    );
    expect(container.read(durationProvider).value, const Duration(minutes: 3));
    engine.currentPosition = const Duration(seconds: 5);
    expect(player().snapshot().position, const Duration(seconds: 100));
  });

  test('moving on puts the ordinary stream back', () async {
    await start();
    await player().playTracks(tracks, startIndex: 1);
    await settle();
    await player().seek(const Duration(seconds: 60));
    await settle();
    await player().next();
    await settle();
    await settle();

    expect(state().current?.id, 't2');
    expect(state().offset, Duration.zero);
    expect(engineQueue(), [
      'fake://stream/t0?q=opus128',
      'fake://stream/t1?q=opus128',
      'fake://stream/t2?q=opus128',
    ]);
    expect(engine.index, 2);
  });

  test('seeking back to the start uses the ordinary stream', () async {
    await start();
    await player().playTracks(tracks);
    await settle();
    await player().seek(const Duration(seconds: 60));
    await player().seek(Duration.zero);
    await settle();
    expect(engineQueue().first, 'fake://stream/t0?q=opus128');
    expect(state().offset, Duration.zero);
    expect(engine.index, 0);
  });

  test(
    'original quality and servers without the extension seek as before',
    () async {
      await start(quality: StreamQuality.original);
      await player().playTracks(tracks);
      await settle();
      await player().seek(const Duration(seconds: 60));
      expect(engineQueue().first, 'fake://stream/t0');
      expect(state().offset, Duration.zero);

      await start(offsets: false);
      await player().playTracks(tracks);
      await settle();
      await player().seek(const Duration(seconds: 60));
      expect(engineQueue().first, 'fake://stream/t0?q=opus128');
      expect(state().offset, Duration.zero);
    },
  );

  test('a saved queue resumes a transcoded track where it was left', () async {
    await start();
    await player().restore(
      SavedQueue(
        tracks: tracks,
        currentIndex: 2,
        position: const Duration(seconds: 42),
      ),
    );
    await settle();
    expect(engineQueue()[2], 'fake://stream/t2?q=opus128&t=42');
    expect(engine.startPosition, Duration.zero);
    expect(state().offset, const Duration(seconds: 42));
  });

  test('removing the reopened track does not touch the next one', () async {
    await start();
    await player().playTracks(tracks, startIndex: 1);
    await settle();
    await player().seek(const Duration(seconds: 60));
    await settle();
    await player().removeAt(1);
    await settle();
    expect(state().offset, Duration.zero);
    expect(engineQueue(), [
      'fake://stream/t0?q=opus128',
      'fake://stream/t2?q=opus128',
    ]);
  });
}

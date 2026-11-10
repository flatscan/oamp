import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/audio/audio_engine.dart';
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

  test('durationAt subtracts offset for the reopened current track', () async {
    await start();
    await player().playTracks(tracks, startIndex: 1);
    await settle();
    expect(player().durationAt(1), const Duration(minutes: 3));

    await player().seek(const Duration(seconds: 120));
    await settle();
    expect(player().durationAt(1), const Duration(seconds: 60));
    expect(player().durationAt(0), const Duration(minutes: 3));
    expect(player().durationAt(2), const Duration(minutes: 3));
  });

  test(
    'crossfade after a transcoded seek uses the remaining stream length',
    () async {
      final decks = <FakeDeck>[];
      final mixing = MixingEngine(() {
        final d = FakeDeck()..duration = null;
        decks.add(d);
        return d;
      });
      source = FakeMusicSource()
        ..capabilities = const SourceCapabilities(
          extensions: {
            'transcodeOffset': [1],
          },
        );
      container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
          audioEngineProvider.overrideWithValue(mixing),
          streamQualityProvider.overrideWithValue(opus),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);
      container.read(capabilitiesProvider);
      await settle();
      container.read(playerProvider);
      await container
          .read(settingsProvider.notifier)
          .setPlayback(const PlaybackOptions(crossfade: Duration(seconds: 6)));
      await settle();

      await player().playTracks(tracks);
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      // Seek to 2:00 of a 3:00 track; remaining stream length is 60s.
      await player().seek(const Duration(seconds: 120));
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(state().offset, const Duration(seconds: 120));
      expect(decks[0].index, 0);
      expect(decks[0].playing, isTrue);
      expect(player().durationAt(0), const Duration(seconds: 60));
      expect(player().crossfadeBetween(0, 1), isTrue);

      // 40s into the reopened stream (20s left): not fading yet.
      decks[0].at(const Duration(seconds: 40));
      await settle();
      expect(mixing.isFading, isFalse);

      // 50s into the reopened stream (10s left <= 6s + 8s prepareAhead):
      // spare deck prepares.
      decks[0].at(const Duration(seconds: 50));
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(decks, hasLength(2));

      // 55s into the reopened stream (5s left <= 6s crossfade): fades now,
      // and moving on restores the reopened entry in the background.
      decks[0].at(const Duration(seconds: 55));
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(decks[1].playing, isTrue);
      expect(decks[1].index, 1);
      expect(state().currentIndex, 1);
      expect(state().offset, Duration.zero);
      await mixing.pause();
    },
  );

  test(
    'repeat one after a transcoded seek repeats from the top of the track',
    () async {
      await start();
      // Start at index 0 of a 3-track queue so a natural end with repeat off
      // advances to index 1 rather than emitting completed.
      await player().playTracks(tracks, startIndex: 0);
      await settle();
      // Cycle to Repeat One (off -> all -> one).
      await player().cycleRepeat();
      await player().cycleRepeat();
      expect(state().repeat, PlaybackRepeat.one);
      expect(engine.repeat, PlaybackRepeat.one);

      await player().seek(const Duration(seconds: 90));
      await settle();
      expect(state().offset, const Duration(seconds: 90));
      // Engine repeat is off while playing the reopened stream so it doesn't
      // loop from 1:30, and crossfade out of the reopened stream is suppressed
      // so MixingEngine does not crossfade into track 1.
      expect(engine.repeat, PlaybackRepeat.off);
      expect(player().crossfadeBetween(0, 1), isFalse);

      // Natural end of track 0: engine advances to index 1 with repeat off,
      // and PlayerController intercepts it, restores track 0's full stream,
      // and repeats track 0 from 0:00.
      engine.finishTrack();
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(state().currentIndex, 0);
      expect(state().offset, Duration.zero);
      expect(engine.index, 0);
      expect(engineQueue()[0], 'fake://stream/t0?q=opus128');
      expect(engine.repeat, PlaybackRepeat.one);
      expect(engine.playing, isTrue);

      // Also works on the last track in the queue (where finishTrack emits
      // completed: true).
      await player().jumpTo(2);
      await settle();
      await player().seek(const Duration(seconds: 45));
      await settle();
      expect(state().offset, const Duration(seconds: 45));
      expect(engine.repeat, PlaybackRepeat.off);

      engine.finishTrack();
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(state().currentIndex, 2);
      expect(state().offset, Duration.zero);
      expect(engine.index, 2);
      expect(engineQueue()[2], 'fake://stream/t2?q=opus128');
      expect(engine.repeat, PlaybackRepeat.one);
      expect(engine.playing, isTrue);

      // Skipping by hand while reopened under Repeat One still advances.
      await player().jumpTo(0);
      await settle();
      await player().seek(const Duration(seconds: 30));
      await settle();
      await player().next();
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(state().currentIndex, 1);
      expect(state().offset, Duration.zero);
      expect(engine.repeat, PlaybackRepeat.one);
    },
  );

  test(
    'durationProvider keeps the active duration when offset returns to zero',
    () async {
      await start();
      await player().playTracks(tracks, startIndex: 0);
      await settle();
      await player().seek(const Duration(seconds: 60));
      await settle();
      expect(
        container.read(durationProvider).value,
        const Duration(minutes: 3),
      );

      // Advance to the next track; the engine reports its duration before the
      // rebuilt durationProvider subscribes to durationStream.
      const nextDur = Duration(minutes: 4, seconds: 15);
      engine.emitDuration(nextDur);
      await player().next();
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(state().offset, Duration.zero);
      expect(container.read(durationProvider).value, nextDur);
    },
  );
}

class FakeDeck implements AudioDeck {
  final _state = StreamController<EngineState>.broadcast(sync: true);
  final _pos = StreamController<Duration>.broadcast(sync: true);
  final _dur = StreamController<Duration?>.broadcast(sync: true);
  List<Uri> queue = [];
  int? index;
  @override
  bool playing = false;
  double volume = 1;
  bool gapless = true;
  PlaybackRepeat repeat = PlaybackRepeat.off;
  Duration _p = Duration.zero;
  @override
  Duration? duration;

  void at(Duration p) {
    _p = p;
    _pos.add(p);
  }

  void _emit() =>
      _state.add(EngineState(playing: playing, currentIndex: index));

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Object> get errors => const Stream.empty();
  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration?> get durationStream => _dur.stream;
  @override
  Duration get position => _p;
  @override
  int? get currentIndex => index;
  @override
  double get maxVolume => 2;

  @override
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    queue = List.of(uris);
    index = initialIndex;
    _p = initialPosition;
    _emit();
  }

  @override
  Future<void> addAll(List<Uri> uris) async => queue.addAll(uris);
  @override
  Future<void> insertAll(int i, List<Uri> uris) async {
    queue.insertAll(i, uris);
    final at = index;
    if (at != null && i <= at && at < queue.length - uris.length) {
      index = at + uris.length;
      _emit();
    }
  }

  @override
  Future<void> removeAt(int i) async {
    queue.removeAt(i);
    final at = index;
    if (at != null && i < at) {
      index = at - 1;
      _emit();
    }
  }

  @override
  Future<void> move(int from, int to) async =>
      queue.insert(to, queue.removeAt(from));
  @override
  Future<void> clear() async {
    queue.clear();
    index = null;
    playing = false;
    _emit();
  }

  @override
  Future<void> play() async {
    playing = true;
    _emit();
  }

  @override
  Future<void> pause() async {
    playing = false;
    _emit();
  }

  @override
  Future<void> seek(Duration p, {int? index}) async {
    if (index != null) this.index = index;
    _p = p;
    _emit();
  }

  @override
  Future<void> next() async {
    index = (index ?? 0) + 1;
    _emit();
  }

  @override
  Future<void> previous() async {
    index = (index ?? 1) - 1;
    _emit();
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeat mode) async => repeat = mode;
  @override
  Future<void> setVolume(double v) async => volume = v;
  @override
  Future<void> setGapless(bool enabled) async => gapless = enabled;
  @override
  Future<void> dispose() async {
    await _state.close();
    await _pos.close();
    await _dur.close();
  }
}

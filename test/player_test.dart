import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/play_queue.dart';
import 'package:oamp/core/playback_options.dart';
import 'package:oamp/state/library.dart';
import 'package:oamp/state/playback_reporter.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/ui/player/controls.dart';

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

  /// The track ids the engine has queued, in order.
  List<String> engineIds() => [
    for (final u in engine.queue) u.pathSegments.last,
  ];

  test('shuffling up next is one bulk removal, not one per track', () async {
    await player().playTracks(many);
    await settle();
    await player().shuffleUpcoming();
    expect(engine.rangeRemovals, 1);
    expect(engineIds(), [for (final t in state().queue) t.id]);
  });

  test('edits made while a shuffle is still reaching the engine keep it in '
      'step with the queue', () async {
    await player().playTracks(many);
    await settle();
    final shuffling = player().shuffleUpcoming();
    final moving = player().move(5, 1);
    final removing = player().removeAt(3);
    await Future.wait([shuffling, moving, removing]);
    await settle();
    expect(engineIds(), [for (final t in state().queue) t.id]);
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

  test('shuffle can be undone, keeping tracks added since', () async {
    await player().playTracks(many, startIndex: 1);
    await settle();
    await player().toggleShuffle();
    expect(state().shuffled, isTrue);
    const extra = Track(id: 'x', title: 'Extra');
    await player().enqueue([extra]);
    await player().toggleShuffle();
    expect(state().shuffled, isFalse);
    final ids = state().queue.map((t) => t.id).toList();
    expect(ids, ['m0', 'm1', 'm2', 'm3', 'm4', 'm5', 'x']);
    expect(engine.queue.map((u) => u.pathSegments.last), ids);
  });

  test('a shuffled play can be put back in album order', () async {
    await player().playTracks(many, shuffle: true);
    await settle();
    expect(state().shuffled, isTrue);
    final first = state().current!;
    await player().unshuffle();
    // The playing track stays; the rest follow in their original order.
    final rest = [
      for (final t in many)
        if (!identical(t, first)) t.id,
    ];
    expect(state().queue.skip(1).map((t) => t.id), rest);
    expect(state().current, same(first));
  });

  test('playing something new clears the shuffled state', () async {
    await player().playTracks(many, shuffle: true);
    await settle();
    await player().playTracks(many);
    expect(state().shuffled, isFalse);
  });

  test('clear up next leaves the current track playing', () async {
    await player().playTracks(many, startIndex: 1);
    await settle();
    await player().clearUpcoming();
    expect(state().queue.map((t) => t.id), ['m0', 'm1']);
    expect(engine.queue, hasLength(2));
    expect(state().current?.id, 'm1');
  });

  test('removing the last remaining track clears the queue cleanly', () async {
    await player().playTracks([many.first]);
    await settle();
    expect(state().queue, hasLength(1));
    expect(state().currentIndex, 0);

    await player().removeAt(0);
    await settle();
    expect(state().queue, isEmpty);
    expect(state().currentIndex, isNull);
    expect(state().playing, isFalse);
    expect(engine.queue, isEmpty);
    expect(engine.index, isNull);
  });

  test('removeAt and clearUpcoming prune endless track marks', () async {
    await player().playTracks(many.sublist(0, 2));
    await settle();
    await player().addEndless(many.sublist(2, 5));
    await settle();
    expect(state().endless, hasLength(3));
    final firstEndless = state().queue[2];

    await player().removeAt(2);
    await settle();
    expect(state().endless.contains(firstEndless), isFalse);
    expect(state().endless, hasLength(2));

    await player().clearUpcoming();
    await settle();
    expect(state().endless, isEmpty);
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

  test(
    'currentQuality keeps playing track quality and updates upcoming',
    () async {
      await player().playTracks(many);
      await settle();
      expect(state().currentQuality, StreamQuality.original);

      const opus128 = StreamQuality(format: StreamFormat.opus, bitRate: 128);
      await container.read(settingsProvider.notifier).setQuality(opus128);
      await settle();
      expect(state().currentQuality, StreamQuality.original);

      await player().next();
      await settle();
      expect(state().currentQuality, opus128);
    },
  );

  test('a restored queue fetches fresh details as playback reaches each '
      'track', () async {
    // Saved before the files were tagged, so no ReplayGain.
    source.trackDetails = {
      for (final t in many)
        t.id: Track(
          id: t.id,
          title: t.title,
          duration: t.duration,
          replayGain: const ReplayGain(trackGain: -10.14, albumGain: -9.76),
        ),
    };
    await player().restore(SavedQueue(tracks: many, currentIndex: 1));
    await settle();
    // The current track and the next one, not the whole queue.
    expect(source.trackRequests, ['m1', 'm2']);
    expect(state().queue[1].replayGain?.trackGain, -10.14);
    expect(state().queue[2].replayGain?.trackGain, -10.14);
    expect(state().queue[3].replayGain, isNull);
    expect(engine.gainRefreshes, greaterThan(0));

    await player().next();
    await settle();
    expect(source.trackRequests, ['m1', 'm2', 'm3']);
    expect(state().queue[3].replayGain?.trackGain, -10.14);

    // Tracks queued fresh are already up to date.
    await player().playTracks(many);
    await settle();
    await player().next();
    await settle();
    expect(source.trackRequests, ['m1', 'm2', 'm3']);
  });

  test('qualityLabel and replayGainDebugLabel format display strings', () {
    const flac = Track(
      id: 't1',
      title: 'T',
      format: 'flac',
      sampleRate: 44100,
      bitDepth: 16,
      replayGain: ReplayGain(trackGain: -6.4, albumGain: -5.0, trackPeak: 0.98),
    );
    const untagged = Track(id: 't2', title: 'U', format: 'mp3', bitRate: 320);

    expect(qualityLabel(flac), 'FLAC  ·  44.1 / 16');
    expect(
      qualityLabel(
        flac,
        const StreamQuality(format: StreamFormat.opus, bitRate: 128),
      ),
      'FLAC → OPUS  ·  128 kbps',
    );
    expect(
      replayGainDebugLabel(
        flac,
        const PlaybackOptions(replayGain: ReplayGainMode.track),
      ),
      'RG: track -6.4 dB · album -5.0 dB · peak 0.98'
      '  ·  applied -6.4 dB (track)',
    );
    expect(
      replayGainDebugLabel(
        untagged,
        const PlaybackOptions(
          replayGain: ReplayGainMode.track,
          fallbackGainDb: -4.0,
        ),
      ),
      'RG: untagged  ·  applied -4.0 dB (fallback)',
    );
  });
}

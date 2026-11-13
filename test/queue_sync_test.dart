import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/core/play_queue.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/playback_reporter.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/queue_sync.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';

import 'fakes/fakes.dart';

void main() {
  final many = [
    for (var i = 0; i < 4; i++)
      Track(
        id: 'm$i',
        title: 'Track $i',
        album: 'Album',
        duration: const Duration(minutes: 3),
        replayGain: const ReplayGain(trackGain: -6.5),
      ),
  ];

  late MemoryPreferences prefs;
  late FakeMusicSource source;
  late FakeAudioEngine engine;
  late ProviderContainer container;

  /// Starts the app: a fresh player and engine over the same settings and
  /// server, as after a restart.
  Future<void> launch() async {
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        audioEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(queueSyncProvider).restored;
    await container.read(queueSyncProvider).saved;
  }

  setUp(() {
    prefs = MemoryPreferences();
    source = FakeMusicSource()..extraTracks = many;
  });

  QueueSync sync() => container.read(queueSyncProvider);
  PlayerController player() => container.read(playerProvider.notifier);
  PlayerState state() => container.read(playerProvider);
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Plays [many] from the third track and pauses 75 seconds in.
  Future<void> playAndPause() async {
    await player().playTracks(many, startIndex: 2, from: 'Album');
    await settle();
    engine.currentPosition = const Duration(seconds: 75);
    await player().pause();
    await settle();
    await sync().saved;
  }

  test('the queue comes back paused where it was after a restart', () async {
    source.capabilities = const SourceCapabilities(hasSimilar: true);
    await launch();
    await playAndPause();
    container.dispose();

    await launch();
    expect(state().queue.map((t) => t.id), ['m0', 'm1', 'm2', 'm3']);
    expect(state().currentIndex, 2);
    expect(state().playing, isFalse);
    expect(state().from, 'Album');
    expect(engine.index, 2);
    expect(engine.startPosition, const Duration(seconds: 75));
    // Track details survive, so ReplayGain still applies before any reload.
    expect(state().current?.replayGain?.trackGain, -6.5);
  });

  test('pausing saves the queue to the server', () async {
    await launch();
    await playAndPause();
    final saved = source.playQueue!;
    expect(saved.tracks.map((t) => t.id), ['m0', 'm1', 'm2', 'm3']);
    expect(saved.currentIndex, 2);
    expect(saved.position, const Duration(seconds: 75));
  });

  test('a queue saved on another device since wins at start-up', () async {
    await launch();
    await playAndPause();
    container.dispose();

    // Another device played on and paused elsewhere.
    source.playQueue = SavedQueue(
      tracks: [many[3], many[0]],
      currentIndex: 1,
      position: const Duration(seconds: 30),
      changed: DateTime.now().toUtc(),
    );
    await launch();
    expect(state().queue.map((t) => t.id), ['m3', 'm0']);
    expect(state().currentIndex, 1);
    expect(engine.startPosition, const Duration(seconds: 30));
  });

  test('changes saved while offline are pushed at the next start', () async {
    await launch();
    source.queueOffline = true;
    await playAndPause();
    container.dispose();

    source.queueOffline = false;
    source.playQueue = SavedQueue(
      tracks: [many[1]],
      currentIndex: 0,
      changed: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );
    await launch();
    expect(state().currentIndex, 2);
    expect(source.playQueue!.tracks, hasLength(4));
    expect(source.playQueue!.position, const Duration(seconds: 75));
  });

  test('coming back while paused picks up another device\'s queue', () async {
    await launch();
    await playAndPause();
    source.playQueue = SavedQueue(
      tracks: [many[0], many[1]],
      currentIndex: 1,
      position: const Duration(seconds: 10),
    );
    await sync().checkServer();
    expect(state().queue.map((t) => t.id), ['m0', 'm1']);
    expect(state().currentIndex, 1);
    expect(state().playing, isFalse);
  });

  test('coming back while playing leaves the queue alone', () async {
    await launch();
    await player().playTracks(many);
    await settle();
    source.playQueue = SavedQueue(tracks: [many[0]], currentIndex: 0);
    await sync().checkServer();
    expect(state().queue, hasLength(4));
  });

  test('our own save is not mistaken for another device', () async {
    await launch();
    await playAndPause();
    final reads = source.queueReads;
    await sync().checkServer();
    expect(source.queueReads, reads + 1);
    expect(state().currentIndex, 2);
    expect(engine.startPosition, Duration.zero, reason: 'not reloaded');
  });

  test('with syncing off the server is never touched', () async {
    await launch();
    await container.read(settingsProvider.notifier).setSyncQueue(false);
    final reads = source.queueReads;
    await playAndPause();
    await sync().checkServer();
    expect(source.queueSaves, isEmpty);
    expect(source.queueReads, reads);
  });

  test('a queue restored but not yet played keeps its position', () async {
    source.playQueue = SavedQueue(
      tracks: many,
      currentIndex: 1,
      position: const Duration(seconds: 50),
    );
    await launch();
    expect(player().snapshot().position, const Duration(seconds: 50));
    // Restoring does not echo the same queue back to the server.
    expect(source.queueSaves, isEmpty);
  });

  test('a restored queue is not reported as playing until played', () async {
    source.playQueue = SavedQueue(tracks: many, currentIndex: 1);
    await launch();
    container.read(playbackReporterProvider);
    await settle();
    expect(source.calls.where((c) => c.startsWith('playing:')), isEmpty);
    await player().play();
    await settle();
    expect(source.calls, contains('playing:m1'));
  });

  test('edits are saved once they settle', () {
    fakeAsync((async) {
      engine = FakeAudioEngine();
      container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
          audioEngineProvider.overrideWithValue(engine),
        ],
      );
      container.read(queueSyncProvider);
      async.elapse(Duration.zero); // Restored: nothing saved yet.
      player().enqueue(many);
      async.flushMicrotasks();
      player().removeAt(0);
      async.elapse(QueueSync.debounce - const Duration(milliseconds: 100));
      expect(source.queueSaves, isEmpty);
      async.elapse(const Duration(milliseconds: 100));
      expect(source.queueSaves, hasLength(1));
      expect(source.queueSaves.last.tracks.map((t) => t.id), [
        'm1',
        'm2',
        'm3',
      ]);
      container.dispose();
    });
  });

  test('while playing, the server hears the position about once a minute', () {
    fakeAsync((async) {
      engine = FakeAudioEngine();
      container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
          audioEngineProvider.overrideWithValue(engine),
        ],
      );
      container.read(queueSyncProvider);
      async.elapse(Duration.zero);
      player().playTracks(many);
      async.elapse(QueueSync.debounce);
      expect(source.queueSaves, hasLength(1));
      // Three position saves on this device; the third reaches the server.
      for (var i = 1; i <= 3; i++) {
        engine.currentPosition = Duration(seconds: 20 * i);
        async.elapse(QueueSync.interval);
      }
      expect(source.queueSaves, hasLength(2));
      expect(prefs.getInt('oamp.queue.${source.serverId}.positionMs'), 60000);
      // Pausing sends where it stopped at once.
      engine.currentPosition = const Duration(seconds: 65);
      player().pause();
      async.elapse(Duration.zero);
      expect(source.queueSaves, hasLength(3));
      expect(source.queueSaves.last.position, const Duration(seconds: 65));
      container.dispose();
    });
  });

  group('choose', () {
    SavedQueue q(List<int> ids, {int at = 0, int pos = 0, DateTime? when}) =>
        SavedQueue(
          tracks: [for (final i in ids) many[i]],
          currentIndex: at,
          position: Duration(seconds: pos),
          changed: when,
        );
    final early = DateTime.utc(2026, 11, 1);
    final late = DateTime.utc(2026, 11, 2);

    test('keeps the local copy when both match', () {
      final local = q([0, 1], at: 1);
      expect(QueueSync.choose(local, true, q([0, 1], at: 1)), same(local));
    });

    test('keeps which of two identical entries was current', () {
      final local = q([0, 1, 0], at: 2, pos: 5);
      // The server names the current entry by id, so it says the first.
      final pick = QueueSync.choose(local, true, q([0, 1, 0], at: 0, pos: 9));
      expect(pick!.currentIndex, 2);
      expect(pick.position, const Duration(seconds: 9));
    });

    test('takes the server copy when ours reached it', () {
      final remote = q([2]);
      expect(QueueSync.choose(q([0, 1]), true, remote), same(remote));
    });

    test('takes the newer copy when ours never reached the server', () {
      final local = q([0], when: late), remote = q([1], when: early);
      expect(QueueSync.choose(local, false, remote), same(local));
      expect(
        QueueSync.choose(
          q([0], when: early),
          false,
          q([1], when: late),
        )!.tracks.single.id,
        'm1',
      );
    });

    test('a queue cleared elsewhere stays cleared', () {
      expect(QueueSync.choose(q([0]), true, null), isNull);
      expect(QueueSync.choose(q([0]), false, null)!.tracks, hasLength(1));
    });
  });
}

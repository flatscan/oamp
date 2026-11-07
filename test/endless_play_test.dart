import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/play_queue.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/endless_play.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';

import 'fakes/fakes.dart';

Track _t(String id, {String? albumId, List<String> genres = const []}) => Track(
  id: id,
  title: 'Track $id',
  artist: 'Air',
  artistId: 'ar1',
  albumId: albumId,
  genres: genres,
  duration: const Duration(minutes: 3),
);

const _early = Album(
  id: 'al0',
  name: 'Premiers Symptômes',
  artistId: 'ar1',
  year: 1997,
);
const _later = Album(
  id: 'al2',
  name: '10 000 Hz Legend',
  artistId: 'ar1',
  year: 2001,
);

void main() {
  late FakeAudioEngine engine;
  late FakeMusicSource source;
  late MemoryPreferences prefs;
  late ProviderContainer container;

  final safari = [for (var i = 1; i <= 3; i++) _t('s$i', albumId: 'al1')];
  final legend = [for (var i = 1; i <= 10; i++) _t('l$i', albumId: 'al2')];
  final symptoms = [for (var i = 1; i <= 10; i++) _t('p$i', albumId: 'al0')];

  ProviderContainer make() {
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        audioEngineProvider.overrideWithValue(engine),
        preferencesProvider.overrideWithValue(prefs),
      ],
    );
    c.listen(endlessPlayProvider, (_, _) {});
    return c;
  }

  setUp(() async {
    engine = FakeAudioEngine();
    source = FakeMusicSource()
      ..artistExtras = const [_later, _early]
      ..albumDetails = {
        'al1': AlbumDetail(FakeMusicSource.moonSafari, safari),
        'al2': AlbumDetail(_later, legend),
        'al0': AlbumDetail(_early, symptoms),
      };
    prefs = MemoryPreferences();
    container = make();
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
  });

  PlayerController player() => container.read(playerProvider.notifier);
  PlayerState state() => container.read(playerProvider);
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      await container.read(endlessPlayProvider).idle;
    }
  }

  group('modes', () {
    test('album queues default to next album, others to stop', () async {
      await player().playTracks(safari, album: true);
      expect(state().albumQueue, isTrue);
      expect(container.read(endlessModeProvider), EndlessMode.nextAlbum);
      expect(
        container.read(endlessChoicesProvider),
        contains(EndlessMode.nextAlbum),
      );

      await player().playTracks(safari, from: 'Mixtape');
      expect(state().albumQueue, isFalse);
      expect(container.read(endlessModeProvider), EndlessMode.stop);
      expect(
        container.read(endlessChoicesProvider),
        isNot(contains(EndlessMode.nextAlbum)),
      );
    });

    test('a shuffled album is not an album queue', () async {
      await player().playTracks(safari, album: true, shuffle: true);
      expect(state().albumQueue, isFalse);
    });

    test('adding tracks keeps an album queue', () async {
      await player().playTracks(safari, album: true);
      await player().enqueue([_t('x')]);
      await player().playNext([_t('y')]);
      expect(state().albumQueue, isTrue);
    });

    test('each kind of queue remembers its own mode per server', () async {
      final settings = container.read(endlessSettingsProvider.notifier);
      await settings.set(EndlessMode.similar, album: true);
      await settings.set(EndlessMode.liked, album: false);
      // Next album is never the default for other queues.
      await settings.set(EndlessMode.nextAlbum, album: false);

      final again = make();
      addTearDown(again.dispose);
      await again.read(sessionProvider.future);
      final s = again.read(endlessSettingsProvider);
      expect(s.album, EndlessMode.similar);
      expect(s.other, EndlessMode.liked);
      expect(prefs.getString('oamp.endless.fake:1.album'), 'similar');
    });
  });

  group('topping up', () {
    test('an album queue carries on with the next album, marked', () async {
      await player().playTracks(safari, album: true);
      await settle();
      expect(state().queue.map((t) => t.id), [
        ...safari.map((t) => t.id),
        ...legend.map((t) => t.id),
      ]);
      expect(state().isEndless(state().queue[2]), isFalse);
      expect(state().isEndless(state().queue[3]), isTrue);
      expect(state().albumQueue, isTrue);
    });

    test('nothing is added in stop mode or with repeat on', () async {
      await player().playTracks(safari);
      await settle();
      expect(state().queue, hasLength(3));

      await player().cycleRepeat();
      await player().playTracks(safari, album: true);
      await settle();
      expect(state().queue, hasLength(3));
    });

    test('waits until six tracks are left', () async {
      final long = [for (var i = 0; i < 10; i++) _t('n$i', albumId: 'al1')];
      await player().playTracks(long, album: true);
      await settle();
      expect(state().queue, hasLength(10));
      await player().jumpTo(3);
      await settle();
      expect(state().queue, hasLength(20));
    });

    test('liked mode skips what is already queued', () async {
      await container
          .read(endlessSettingsProvider.notifier)
          .set(EndlessMode.liked, album: false);
      source.likedTracks = [safari[0], _t('liked1'), _t('liked2')];
      await player().playTracks(safari);
      await settle();
      expect(state().queue.skip(3).map((t) => t.id).toSet(), {
        'liked1',
        'liked2',
      });
    });

    test('gives up quietly when nothing comes back', () async {
      await container
          .read(endlessSettingsProvider.notifier)
          .set(EndlessMode.liked, album: false);
      await player().playTracks(safari);
      await settle();
      expect(state().queue, hasLength(3));
    });
  });

  group('mixer', () {
    EndlessMixer mixer() => EndlessMixer(
      source,
      capabilities: source.capabilities,
      random: Random(1),
    );

    test('next album goes by year and loops round after the last', () async {
      expect((await mixer().nextAlbum(safari.last)).first.id, 'l1');
      expect((await mixer().nextAlbum(legend.last)).first.id, 'p1');
    });

    test('similar leaves out excluded tracks and tops up by genre', () async {
      source
        ..similarTracks = [safari[0], _t('sim1')]
        ..tracksByGenre = {
          'Electronic': [_t('g1'), _t('g2')],
        };
      final seeds = [
        _t('a', genres: const ['Electronic']),
      ];
      final picked = await mixer().similar(seeds, {'s1'});
      expect(picked.map((t) => t.id).toSet(), {'sim1', 'g1', 'g2'});
    });

    test('genre shuffle falls back to album genres', () async {
      source
        ..albumDetails['al9'] = const AlbumDetail(
          Album(id: 'al9', name: 'X', genre: 'Jazz'),
          [],
        )
        ..tracksByGenre = {
          'Jazz': [_t('j1')],
        };
      final picked = await mixer().genreShuffle([_t('a', albumId: 'al9')], {});
      expect(picked.map((t) => t.id), ['j1']);
    });
  });

  test('marks and album queues survive a save and restore', () async {
    await player().playTracks(safari, album: true);
    await settle();
    final snap = player().snapshot();
    expect(snap.albumQueue, isTrue);
    expect(snap.endless, {for (var i = 3; i < 13; i++) i});

    final json = jsonDecode(jsonEncode(snap.toJson())) as Map;
    final back = SavedQueue.fromJson(json.cast<String, Object?>())!;
    await player().clear();
    await player().restore(back);
    expect(state().albumQueue, isTrue);
    expect(state().isEndless(state().queue[3]), isTrue);
    expect(state().isEndless(state().queue[0]), isFalse);
  });
}

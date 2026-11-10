import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/downloads.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/offline_library.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/downloads.dart';
import 'package:oamp/state/library.dart';
import 'package:oamp/state/offline.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/ui/server_banner.dart';

import 'fakes/fakes.dart';
import 'fakes/memory_download_store.dart';

const _a1 = Track(
  id: 'a1',
  title: 'Sexy Boy',
  artist: 'Air',
  artistId: 'ar1',
  album: 'Moon Safari',
  albumId: 'al1',
  track: 2,
  year: 1998,
  coverArt: 'c1',
);
const _a2 = Track(
  id: 'a2',
  title: 'La femme d’argent',
  artist: 'Air',
  artistId: 'ar1',
  album: 'Moon Safari',
  albumId: 'al1',
  track: 1,
  year: 1998,
);
const _b1 = Track(
  id: 'b1',
  title: 'Kids',
  artist: 'MGMT',
  album: 'Oracular Spectacular',
  year: 2007,
  liked: true,
  genres: ['Indie'],
);
const _notHere = Track(id: 'x', title: 'Not downloaded', artist: 'Air');

Pin _pin(PinKind kind, String id, String name, List<Track> tracks) => Pin(
  kind: kind,
  itemId: id,
  name: name,
  tracks: tracks,
  pinnedAt: DateTime.utc(2026, 11, 1),
);

Future<void> settle([int turns = 20]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Unreachable extends ServerStatusNotifier {
  @override
  ServerStatus build() =>
      const ServerStatus(ServerHealth.unreachable, 'Can’t reach the server.');
}

void main() {
  group('OfflineLibrary', () {
    final lib = OfflineLibrary([
      _pin(PinKind.album, 'al1', 'Moon Safari', [_a1, _a2, _notHere]),
      _pin(PinKind.playlist, 'p1', 'Mix', [_b1, _a1]),
    ], (id) => id != 'x');

    test('only downloaded tracks count, each once', () {
      expect([for (final t in lib.tracks) t.id], ['a1', 'a2', 'b1']);
    });

    test('albums and artists are grouped from the tracks', () {
      expect([for (final a in lib.artists()) a.name], ['Air', 'MGMT']);
      final al = lib.album('al1');
      expect(
        [for (final t in al.tracks) t.id],
        ['a2', 'a1'],
        reason: 'by track',
      );
      expect(al.album.name, 'Moon Safari');
      expect(al.album.songCount, 2);
      expect(lib.artist('ar1').albums.single.name, 'Moon Safari');
      // An untagged track still gets an artist and an album of its own.
      expect(lib.albums().map((a) => a.name), [
        'Moon Safari',
        'Oracular Spectacular',
      ]);
      expect(
        lib.albums(sort: AlbumSort.newest).first.name,
        'Oracular Spectacular',
      );
      expect(
        lib.albums(size: 1, offset: 1).single.name,
        'Oracular Spectacular',
      );
    });

    test('playlists list their downloaded tracks and are read only', () {
      final p = lib.playlists().single;
      expect(p.name, 'Mix');
      expect(p.readonly, isTrue);
      expect([for (final t in lib.playlist('p1').tracks) t.id], ['b1', 'a1']);
    });

    test('search, liked tracks and shuffle use the downloads', () {
      expect([for (final t in lib.search('boy').tracks) t.id], ['a1']);
      expect(lib.search('mgmt').artists.single.name, 'MGMT');
      expect(lib.search('moon').albums.single.name, 'Moon Safari');
      expect([for (final t in lib.liked()) t.id], ['b1']);
      expect(lib.random(genre: 'indie').single.id, 'b1');
      expect(lib.random().length, 3);
    });

    test('something that was not downloaded is not found', () {
      expect(() => lib.album('nope'), throwsStateError);
      expect(lib.track('x'), isNull);
    });
  });

  group('offline state', () {
    late MemoryDownloadStore store;
    late MemoryPreferences prefs;
    late FakeAudioEngine engine;
    late ProviderContainer container;

    Future<void> launch({bool unreachable = false}) async {
      engine = FakeAudioEngine();
      container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          sessionProvider.overrideWith(() => FakeSessionNotifier()),
          downloadStoreProvider.overrideWithValue(store),
          audioEngineProvider.overrideWithValue(engine),
          if (unreachable) serverStatusProvider.overrideWith(_Unreachable.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);
      container.listen(downloadsProvider, (_, _) {});
      container.listen(offlineSkipProvider, (_, _) {});
      await settle();
    }

    setUp(() {
      store = MemoryDownloadStore();
      prefs = MemoryPreferences();
      store.savedPins['album:al1'] = _pin(PinKind.album, 'al1', 'Moon Safari', [
        _a1,
        _a2,
      ]);
      store.files.addAll(['a1', 'a2']);
    });

    test('online, browsing goes to the server', () async {
      await launch();
      expect(container.read(offlineProvider), isFalse);
      final albums = await container.read(musicSourceProvider).getAlbums();
      expect(albums.single.id, FakeMusicSource.moonSafari.id);
    });

    test(
      'Offline mode answers from the downloads and refetches screens',
      () async {
        await launch();
        expect(
          (await container.read(artistsProvider.future)).single.id,
          FakeMusicSource.air.id,
        );
        await container.read(settingsProvider.notifier).setOfflineMode(true);
        expect(container.read(offlineProvider), isTrue);
        final artists = await container.read(artistsProvider.future);
        expect(artists.single.name, 'Air');
        expect(artists.single.id, 'ar1', reason: 'now from the pins');
        final detail = await container.read(albumDetailProvider('al1').future);
        expect(detail.tracks.length, 2);
        await container.read(settingsProvider.notifier).setOfflineMode(false);
        expect(
          (await container.read(artistsProvider.future)).single.id,
          FakeMusicSource.air.id,
        );
      },
    );

    test('an unreachable server falls back to downloads', () async {
      await launch(unreachable: true);
      expect(container.read(offlineProvider), isTrue);
      expect(
        (await container.read(musicSourceProvider).search('boy'))
            .tracks
            .single
            .id,
        'a1',
      );
    });

    test(
      'an unreachable server with nothing downloaded keeps its Retry',
      () async {
        store.files.clear();
        store.savedPins.clear();
        await launch(unreachable: true);
        expect(container.read(offlineProvider), isFalse);
      },
    );

    test('queue entries that are not downloaded are skipped offline', () async {
      await launch();
      await container.read(settingsProvider.notifier).setOfflineMode(true);
      await container.read(playerProvider.notifier).playTracks([
        _notHere,
        _a1,
        _notHere,
        _a2,
      ], from: 'test');
      await settle();
      expect(engine.index, 1);
      await container.read(playerProvider.notifier).next();
      await settle();
      expect(engine.index, 3, reason: 'past the entry that is not downloaded');
    });

    test('downloads wait while Offline mode is on', () async {
      store.files.remove('a2');
      await prefs.setBool('oamp.offline.mode', true);
      await launch();
      store.savedPins['album:al1'] = _pin(PinKind.album, 'al1', 'Moon Safari', [
        _a1,
        _a2,
      ]);
      container.read(downloadsProvider.notifier).kick();
      await settle();
      expect(store.fetched, isEmpty);
      expect(container.read(downloadsProvider).problem, 'Offline mode is on');
      await container.read(settingsProvider.notifier).setOfflineMode(false);
      await settle();
      expect(store.fetched, ['a2']);
    });
  });

  testWidgets('the banner says Offline mode is on and offers the way back', (
    tester,
  ) async {
    final prefs = MemoryPreferences();
    await prefs.setBool('oamp.offline.mode', true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          sessionProvider.overrideWith(() => FakeSessionNotifier()),
          downloadStoreProvider.overrideWithValue(MemoryDownloadStore()),
        ],
        child: const MaterialApp(
          home: Scaffold(body: Column(children: [ServerStatusBanner()])),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline mode is on'), findsOneWidget);
    await tester.tap(find.text('Go online'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline mode is on'), findsNothing);
  });
}

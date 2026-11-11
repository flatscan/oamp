import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/downloads.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/platform/network_monitor.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/downloads.dart';
import 'package:oamp/state/library.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';

import 'fakes/fakes.dart';
import 'fakes/memory_download_store.dart';

void main() {
  const t1 = Track(id: 't1', title: 'One', format: 'flac');
  const t2 = Track(id: 't2', title: 'Two', format: 'flac');
  const t3 = Track(id: 't3', title: 'Three', format: 'flac');
  const album = Album(id: 'al1', name: 'Album');

  late MemoryDownloadStore store;
  late FakeMusicSource source;
  late ProviderContainer container;

  Future<void> settle([int turns = 20]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> launch() async {
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(MemoryPreferences()),
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        downloadStoreProvider.overrideWithValue(store),
        networkMonitorProvider.overrideWithValue(const FixedNetworkMonitor()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    container.listen(downloadsProvider, (_, _) {});
    await settle();
  }

  setUp(() {
    store = MemoryDownloadStore();
    source = FakeMusicSource();
  });

  DownloadManager manager() => container.read(downloadsProvider.notifier);
  DownloadsState state() => container.read(downloadsProvider);

  Future<void> pinAlbum(List<Track> tracks) async {
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: tracks);
    await settle();
  }

  test('tracks added on the server download, removed ones go', () async {
    source.albumDetails['al1'] = const AlbumDetail(album, [t1, t3]);
    await launch();
    await pinAlbum([t1, t2]);
    expect(store.files, {'t1', 't2'});

    await manager().syncPin(PinKind.album, 'al1', force: true);
    await settle();
    expect(store.files, {'t1', 't3'});
    expect(state().pinFor(PinKind.album, 'al1')!.tracks.map((t) => t.id), [
      't1',
      't3',
    ]);
    expect(store.savedPins['album:al1']!.tracks.length, 2);
    expect(state().statusOf(PinKind.album, 'al1')!.complete, isTrue);
  });

  test('a track another pin holds is kept', () async {
    source.albumDetails['al1'] = const AlbumDetail(album, [t1]);
    await launch();
    await pinAlbum([t1, t2]);
    await manager().pin(PinKind.playlist, 'p1', name: 'Mix', tracks: [t2]);
    await settle();

    await manager().syncPin(PinKind.album, 'al1', force: true);
    await settle();
    expect(store.files, {'t1', 't2'});
  });

  test('an unreachable server changes nothing', () async {
    await launch();
    await pinAlbum([t1, t2]);
    source.unreachable = true;
    source.albumDetails['al1'] = const AlbumDetail(album, [t3]);

    await manager().syncPin(PinKind.album, 'al1', force: true);
    await settle();
    expect(store.files, {'t1', 't2'});
    expect(state().pinFor(PinKind.album, 'al1'), isNotNull);
  });

  test('an album the server says is gone is removed quietly', () async {
    await launch();
    await pinAlbum([t1, t2]);
    source.goneAlbums.add('al1');

    await manager().syncPin(PinKind.album, 'al1', force: true);
    await settle();
    expect(state().pinFor(PinKind.album, 'al1'), isNull);
    expect(store.files, isEmpty);
    expect(store.savedPins, isEmpty);
  });

  test('an album listed with no tracks is left alone', () async {
    source.albumDetails['al1'] = const AlbumDetail(album, []);
    await launch();
    await pinAlbum([t1, t2]);

    await manager().syncPin(PinKind.album, 'al1', force: true);
    await settle();
    expect(store.files, {'t1', 't2'});
  });

  test('a playlist deleted on the server is removed', () async {
    await launch();
    final id = source.playlists.keys.first;
    await manager().pin(PinKind.playlist, id, name: 'Mix', tracks: [t1]);
    await settle();
    expect(store.files, {'t1'});

    source.playlists.remove(id);
    await manager().syncAll(force: true);
    await settle();
    expect(state().pins, isEmpty);
    expect(store.files, isEmpty);
  });

  test('a playlist emptied on the server empties the download', () async {
    await launch();
    final id = source.playlists.keys.first;
    final (p, _) = source.playlists[id]!;
    source.playlists[id] = (p, []);
    await manager().pin(PinKind.playlist, id, name: 'Mix', tracks: [t1, t2]);
    await settle();

    await manager().syncPin(PinKind.playlist, id, force: true);
    await settle();
    expect(store.files, isEmpty);
    expect(state().pinFor(PinKind.playlist, id), isNotNull);
  });

  test('a rename on the server is picked up', () async {
    source.albumDetails['al1'] = const AlbumDetail(
      Album(id: 'al1', name: 'Renamed'),
      [t1],
    );
    await launch();
    await pinAlbum([t1]);

    await manager().syncPin(PinKind.album, 'al1', force: true);
    await settle();
    expect(state().pinFor(PinKind.album, 'al1')!.name, 'Renamed');
  });

  test('opening a pin again soon does not ask the server again', () async {
    source.albumDetails['al1'] = const AlbumDetail(album, [t1]);
    await launch();
    await pinAlbum([t1]);
    await manager().syncPin(PinKind.album, 'al1');
    await settle();

    source.albumDetails['al1'] = const AlbumDetail(album, [t1, t2]);
    await manager().syncPin(PinKind.album, 'al1');
    await settle();
    expect(store.files, {'t1'});

    await manager().syncPin(PinKind.album, 'al1', force: true);
    await settle();
    expect(store.files, {'t1', 't2'});
  });

  test('editing a downloaded playlist in OAmp syncs it at once', () async {
    await launch();
    final id = source.playlists.keys.first;
    final (playlist, serverTracks) = source.playlists[id]!;
    await manager().pin(PinKind.playlist, id, name: 'Mix', tracks: [t1]);
    await settle();

    await container.read(playlistActionsProvider).rename(playlist, 'Renamed');
    await settle();
    expect(state().pinFor(PinKind.playlist, id)!.name, 'Renamed');
    expect(
      state().pinFor(PinKind.playlist, id)!.tracks.length,
      serverTracks.length,
    );
  });

  test('the sync provider reads every pin once downloads are loaded', () async {
    source.albumDetails['al1'] = const AlbumDetail(album, [t1, t3]);
    store.savedPins['album:al1'] = Pin(
      kind: PinKind.album,
      itemId: 'al1',
      name: 'Album',
      tracks: const [t1, t2],
      pinnedAt: DateTime.utc(2026, 11, 1),
    );
    store.files.addAll(['t1', 't2']);
    await launch();
    container.listen(pinSyncProvider, (_, _) {});
    await settle();
    expect(store.files, {'t1', 't3'});
  });
}

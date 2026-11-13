import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/downloads.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/playback_options.dart';
import 'package:oamp/platform/network_monitor.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/downloads.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';

import 'fakes/fakes.dart';
import 'fakes/memory_download_store.dart';

class _Network implements NetworkMonitor {
  _Network(this.current);
  @override
  NetworkKind current;
  final _c = StreamController<NetworkKind>.broadcast();
  @override
  Stream<NetworkKind> get changes => _c.stream;
  @override
  Stream<void> get anyChange => const Stream.empty();
  @override
  Future<void> dispose() async {}
  void go(NetworkKind k) {
    current = k;
    _c.add(k);
  }
}

void main() {
  const a = Track(id: 'a', title: 'A', format: 'flac');
  const b = Track(id: 'b', title: 'B', format: 'flac');
  const c = Track(id: 'c', title: 'C', format: 'flac');

  late MemoryDownloadStore store;
  late _Network network;
  late MemoryPreferences prefs;
  late FakeMusicSource source;
  late ProviderContainer container;

  Future<void> settle([int turns = 20]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> launch({NetworkKind kind = NetworkKind.wifi}) async {
    network = _Network(kind);
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        downloadStoreProvider.overrideWithValue(store),
        networkMonitorProvider.overrideWithValue(network),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    container.listen(downloadsProvider, (_, _) {});
    await settle();
  }

  setUp(() {
    store = MemoryDownloadStore();
    prefs = MemoryPreferences();
    source = FakeMusicSource();
  });

  DownloadManager manager() => container.read(downloadsProvider.notifier);
  DownloadsState state() => container.read(downloadsProvider);

  test('pinning an album fetches its tracks and marks it complete', () async {
    await launch();
    await manager().pin(
      PinKind.album,
      'al1',
      name: 'Moon Safari',
      tracks: [a, b],
    );
    await settle();
    expect(store.fetched, ['a', 'b']);
    final status = state().statusOf(PinKind.album, 'al1')!;
    expect(status.complete, isTrue);
    expect(status.progress, 1);
    expect(state().problem, isNull);
    expect(state().remaining, 0);
    expect(store.lastUrl, startsWith('fake://stream/b'));
  });

  test('tracks in two pins are fetched once and kept until both go', () async {
    await launch();
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a, b]);
    await manager().pin(PinKind.playlist, 'p1', name: 'Mix', tracks: [b, c]);
    await settle();
    expect(store.fetched, ['a', 'b', 'c']);

    await manager().unpin(PinKind.album, 'al1');
    expect(store.files, {'b', 'c'});
    expect(state().statusOf(PinKind.album, 'al1'), isNull);
    expect(state().statusOf(PinKind.playlist, 'p1')!.complete, isTrue);

    await manager().unpin(PinKind.playlist, 'p1');
    expect(store.files, isEmpty);
    expect(store.savedPins, isEmpty);
  });

  test('progress shows while a track is arriving', () async {
    store.gate = Completer<void>();
    await launch();
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a, b]);
    await settle();
    expect(state().active.keys, ['a']);
    expect(state().statusOf(PinKind.album, 'al1')!.complete, isFalse);
    expect(state().remaining, 2);
    store.gate!.complete();
    await settle();
    expect(state().statusOf(PinKind.album, 'al1')!.complete, isTrue);
    expect(state().active, isEmpty);
  });

  test(
    'pins and files are picked up again at launch, and strays removed',
    () async {
      store.savedPins['album:al1'] = Pin(
        kind: PinKind.album,
        itemId: 'al1',
        name: 'Album',
        tracks: const [a, b],
        pinnedAt: DateTime.utc(2026, 11, 1),
      );
      store.files.addAll(['a', 'stray']);
      await launch();
      await settle();
      expect(store.files, {'a', 'b'});
      expect(store.fetched, ['b']);
      expect(state().loaded, isTrue);
      expect(state().statusOf(PinKind.album, 'al1')!.complete, isTrue);
    },
  );

  test('waits for Wi-Fi on mobile data, then carries on', () async {
    await launch(kind: NetworkKind.mobile);
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a]);
    await settle();
    expect(store.fetched, isEmpty);
    expect(state().problem, 'Waiting for Wi-Fi');

    network.go(NetworkKind.wifi);
    await settle();
    expect(store.fetched, ['a']);
    expect(state().problem, isNull);
  });

  test('uses mobile data when the switch is off', () async {
    await launch(kind: NetworkKind.mobile);
    await container
        .read(settingsProvider.notifier)
        .setDownloads(const DownloadOptions(wifiOnly: false));
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a]);
    await settle();
    expect(store.fetched, ['a']);
  });

  test('downloads at the chosen quality', () async {
    await launch();
    await container
        .read(settingsProvider.notifier)
        .setDownloads(
          const DownloadOptions(
            quality: StreamQuality(format: StreamFormat.opus, bitRate: 128),
          ),
        );
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a]);
    await settle();
    expect(store.lastUrl, contains('q=opus128'));
  });

  test('an unreachable server pauses downloads with a reason', () async {
    store.failures.add(
      const DownloadException(DownloadFailure.unreachable, 'down'),
    );
    await launch();
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a, b]);
    await settle();
    expect(state().problem, contains('can’t be reached'));
    expect(store.fetched, isEmpty);

    manager().kick();
    await settle();
    expect(store.fetched, ['a', 'b']);
    expect(state().problem, isNull);
  });

  test('a full device pauses downloads with a reason', () async {
    store.failures.add(
      const DownloadException(DownloadFailure.storageFull, 'full'),
    );
    await launch();
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a]);
    await settle();
    expect(state().problem, contains('out of space'));
  });

  test('a track the server refuses is skipped, not retried forever', () async {
    store.failures.add(const DownloadException(DownloadFailure.server, 'gone'));
    await launch();
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a, b]);
    await settle();
    expect(store.fetched, ['b']);
    expect(state().statusOf(PinKind.album, 'al1')!.complete, isFalse);
    expect(state().problem, isNull);
  });

  test(
    'a refused login stops downloading instead of trying each track',
    () async {
      store.failures.add(
        const DownloadException(DownloadFailure.login, 'refused'),
      );
      await launch();
      await manager().pin(
        PinKind.album,
        'al1',
        name: 'Album',
        tracks: [a, b, c],
      );
      await settle();
      expect(store.fetched, isEmpty);
      expect(state().problem, DownloadManager.loginProblem);
    },
  );

  test('removing all downloads clears the pins and files', () async {
    await launch();
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a]);
    await settle();
    await manager().removeAll();
    expect(state().pins, isEmpty);
    expect(store.files, isEmpty);
  });

  test('a downloaded track plays from its file, others stream', () async {
    await launch();
    await manager().pin(PinKind.album, 'al1', name: 'Album', tracks: [a]);
    await settle();
    final resolver = container.read(trackResolverProvider);
    expect((await resolver.resolve(a)).path, '/downloads/a.flac');
    expect((await resolver.resolve(b)).scheme, 'fake');
    expect(resolver.cacheRequest(a), isNull);
  });
}

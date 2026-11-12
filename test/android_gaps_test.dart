import 'dart:async';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/artwork_cache.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/playback_options.dart';
import 'package:oamp/core/track_cache.dart';
import 'package:oamp/platform/network_monitor.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/state/system_controls_bridge.dart';
import 'package:oamp/ui/browse/settings_page.dart';
import 'package:oamp/ui/player/controls.dart';
import 'package:oamp/ui/theme.dart';

import 'fakes/fakes.dart';
import 'playback_settings_test.dart' show FakeTrackCache;

/// A network the test switches by hand.
class FakeNetwork implements NetworkMonitor {
  FakeNetwork([this.current = NetworkKind.wifi]);
  final _changes = StreamController<NetworkKind>.broadcast(sync: true);
  final _any = StreamController<void>.broadcast(sync: true);

  @override
  NetworkKind current;

  void set(NetworkKind kind) {
    current = kind;
    _changes.add(kind);
    _any.add(null);
  }

  /// A change that keeps the kind, such as another Wi-Fi network.
  void hop() => _any.add(null);

  @override
  Stream<NetworkKind> get changes => _changes.stream;

  @override
  Stream<void> get anyChange => _any.stream;

  @override
  Future<void> dispose() async {
    await _changes.close();
    await _any.close();
  }
}

/// A source whose covers have (signed) server URLs.
class CoverSource extends FakeMusicSource {
  @override
  Uri? coverArtUrl(String? coverArtId, {int size = 300}) => coverArtId == null
      ? null
      : Uri.parse(
          'https://music.example/rest/getCoverArt?id=$coverArtId'
          '&size=$size&u=ed&t=token&s=salt',
        );
}

/// An artwork cache that hands out files once [release] is called.
class FakeArtworkCache implements ArtworkCache {
  final requests = <String>[];
  final _pending = <Completer<Uri?>>[];

  void release() {
    for (final c in _pending) {
      c.complete(Uri.file('/cache/artwork/${requests.last.hashCode}.art'));
    }
    _pending.clear();
  }

  @override
  Future<Uri?> localUri(String key, Uri url) {
    requests.add(key);
    final c = Completer<Uri?>();
    _pending.add(c);
    return c.future;
  }

  @override
  Future<Uint8List> load(String key, Uri url) async => Uint8List(0);
  @override
  Future<CacheUsage> usage() async => CacheUsage.empty;
  @override
  Future<void> clear() async {}
}

void main() {
  group('network kind', () {
    test('the log names the links up, and nothing else', () {
      expect(
        ConnectivityNetworkMonitor.describe([
          ConnectivityResult.wifi,
          ConnectivityResult.vpn,
        ]),
        'wifi + vpn',
      );
      expect(ConnectivityNetworkMonitor.describe([]), 'none');
    });

    test('mobile data only when no Wi-Fi or Ethernet is up', () {
      NetworkKind kind(List<ConnectivityResult> r) =>
          ConnectivityNetworkMonitor.kindOf(r);
      expect(kind([ConnectivityResult.mobile]), NetworkKind.mobile);
      expect(
        kind([ConnectivityResult.vpn, ConnectivityResult.mobile]),
        NetworkKind.mobile,
        reason: 'Tailscale over mobile data is still mobile data',
      );
      expect(
        kind([ConnectivityResult.vpn, ConnectivityResult.wifi]),
        NetworkKind.wifi,
      );
      expect(kind([ConnectivityResult.wifi]), NetworkKind.wifi);
      expect(kind([ConnectivityResult.none]), NetworkKind.wifi);
    });

    test('a change is passed on only once it has settled', () {
      fakeAsync((async) {
        final source = StreamController<NetworkKind>();
        final m = ConnectivityNetworkMonitor.forTest(
          NetworkKind.wifi,
          source.stream,
        );
        final seen = <NetworkKind>[];
        m.changes.listen(seen.add);

        // Wi-Fi drops for a moment and comes back: nothing changes.
        source.add(NetworkKind.mobile);
        async.elapse(const Duration(seconds: 1));
        source.add(NetworkKind.wifi);
        async.elapse(const Duration(seconds: 5));
        expect(seen, isEmpty);
        expect(m.current, NetworkKind.wifi);

        source.add(NetworkKind.mobile);
        async.elapse(const Duration(seconds: 3));
        expect(seen, [NetworkKind.mobile]);
        expect(m.current, NetworkKind.mobile);
      });
    });
  });

  group('mobile data settings', () {
    late FakeNetwork network;
    late MemoryPreferences prefs;
    late ProviderContainer c;

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          networkMonitorProvider.overrideWithValue(network),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      network = FakeNetwork();
      prefs = MemoryPreferences();
      c = container();
    });

    const opus128 = StreamQuality(format: StreamFormat.opus, bitRate: 128);

    test('mobile data follows Wi-Fi until a quality is picked', () async {
      await c
          .read(settingsProvider.notifier)
          .setQuality(const StreamQuality(format: StreamFormat.mp3));
      network.set(NetworkKind.mobile);
      expect(
        c.read(streamQualityProvider),
        const StreamQuality(format: StreamFormat.mp3),
      );
    });

    test('the mobile data quality applies only on mobile data', () async {
      final seen = <StreamQuality>[];
      c.listen(streamQualityProvider, (_, q) => seen.add(q));
      await c.read(settingsProvider.notifier).setMobileQuality(opus128);
      expect(c.read(streamQualityProvider), StreamQuality.original);

      network.set(NetworkKind.mobile);
      expect(c.read(streamQualityProvider), opus128);
      network.set(NetworkKind.wifi);
      expect(c.read(streamQualityProvider), StreamQuality.original);
      expect(seen, [opus128, StreamQuality.original]);
    });

    test('pre-caching can be turned off on mobile data', () async {
      final n = c.read(settingsProvider.notifier);
      await n.setCache(
        c.read(settingsProvider).cache.copyWith(precacheOnMobile: false),
      );
      expect(c.read(cacheOptionsProvider).precacheTracks, 3);
      network.set(NetworkKind.mobile);
      expect(c.read(cacheOptionsProvider).precacheTracks, 0);
      expect(c.read(cacheOptionsProvider).limitMb, 1024);
    });

    test('the choices are saved and read back', () async {
      final n = c.read(settingsProvider.notifier);
      await n.setMobileQuality(opus128);
      await n.setCache(const CacheOptions(precacheOnMobile: false));
      var s = container().read(settingsProvider);
      expect(s.mobileQuality, opus128);
      expect(s.cache.precacheOnMobile, isFalse);

      await n.setMobileQuality(null);
      s = container().read(settingsProvider);
      expect(s.mobileQuality, isNull);
    });

    test('a new network re-resolves the tracks still to come', () async {
      final engine = FakeAudioEngine();
      final c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          networkMonitorProvider.overrideWithValue(network),
          sessionProvider.overrideWith(FakeSessionNotifier.new),
          audioEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(c.dispose);
      // Kept listened, as the app's media controls bridge does, so the
      // player stays active.
      c.listen(playerProvider, (_, _) {});
      await c.read(sessionProvider.future);
      await c.read(settingsProvider.notifier).setMobileQuality(opus128);
      await c.read(playerProvider.notifier).playTracks(FakeMusicSource.tracks);
      expect(engine.queue.last.query, isEmpty);

      network.set(NetworkKind.mobile);
      await pumpEventQueue();
      expect(c.read(playerProvider).qualities.last, opus128);
      expect(engine.queue.map((u) => u.toString()), [
        'fake://stream/t1',
        'fake://stream/t2?q=opus128',
      ]);
    });
  });

  group('settings page on a phone', () {
    testWidgets('offers mobile data choices and no gapless switch', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(440, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final prefs = MemoryPreferences();
      final c = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier()),
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
          preferencesProvider.overrideWithValue(prefs),
          trackCacheProvider.overrideWithValue(FakeTrackCache()),
        ],
      );
      addTearDown(c.dispose);
      await tester.runAsync(() => c.read(sessionProvider.future));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: buildTheme(), home: const SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Gapless playback'), findsNothing);
      expect(find.text('Format on Wi-Fi'), findsOneWidget);
      expect(find.text('Same as Wi-Fi'), findsOneWidget);
      expect(find.text('Maximum bit rate on mobile data'), findsNothing);

      await tester.tap(find.text('Format on mobile data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Opus').last);
      await tester.pumpAndSettle();
      expect(prefs.getString('oamp.stream.mobile.format'), 'opus');
      expect(find.text('Maximum bit rate on mobile data'), findsOneWidget);
      expect(
        prefs.getString('oamp.stream.format'),
        isNull,
        reason: 'the Wi-Fi quality is untouched',
      );

      await tester.tap(find.text('Pre-cache on mobile data'));
      await tester.pumpAndSettle();
      expect(prefs.getBool('oamp.cache.precacheOnMobile'), isFalse);
      await tester.tap(find.text('Equaliser'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('More bass').last);
      await tester.pumpAndSettle();
      expect(prefs.getString('oamp.playback.equalizer'), 'moreBass');
      expect(find.text('Fuller low end.'), findsOneWidget);
    });
  });

  group('media controls art', () {
    late FakeSystemControls controls;
    late FakeArtworkCache art;
    late ProviderContainer c;

    final withCovers = [
      for (final t in FakeMusicSource.tracks)
        Track(
          id: t.id,
          title: t.title,
          artist: t.artist,
          album: t.album,
          duration: t.duration,
          coverArt: 'al-${t.id}',
        ),
    ];

    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUp(() async {
      controls = FakeSystemControls()..needsLocalArt = true;
      art = FakeArtworkCache();
      c = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(
            () => FakeSessionNotifier(CoverSource()),
          ),
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
          systemControlsProvider.overrideWithValue(controls),
          artworkCacheProvider.overrideWithValue(art),
        ],
      );
      addTearDown(c.dispose);
      await c.read(sessionProvider.future);
      c.read(systemControlsBridgeProvider);
    });

    test('never carries the signed server URL', () async {
      await c.read(playerProvider.notifier).playTracks(withCovers);
      await settle();
      expect(controls.last!.title, withCovers.first.title);
      expect(controls.last!.artUri, isNull, reason: 'still being fetched');

      art.release();
      await settle();
      expect(controls.last!.artUri!.scheme, 'file');
      expect(art.requests, ['fake:1/al-t1/512']);

      await c.read(playerProvider.notifier).next();
      await settle();
      expect(controls.last!.artUri, isNull);
      expect(art.requests.last, 'fake:1/al-t2/512');

      for (final info in controls.shown) {
        expect(info?.artUri?.scheme, isNot('https'));
      }
    });

    test('desktop controls keep the server URL', () async {
      controls.needsLocalArt = false;
      await c.read(playerProvider.notifier).playTracks(withCovers);
      await settle();
      expect(controls.last!.artUri!.host, 'music.example');
      expect(art.requests, isEmpty);
    });
  });

  test('the ReplayGain debug line shows the headroom on phones', () {
    const t = Track(id: 't', title: 't', replayGain: ReplayGain(trackGain: 3));
    const o = PlaybackOptions(replayGain: ReplayGainMode.track);
    expect(replayGainDebugLabel(t, o), contains('applied +3.0 dB (track)'));
    expect(
      replayGainDebugLabel(t, o, canBoost: false),
      contains('applied -3.0 dB (track, incl. -6.0 dB headroom)'),
    );
    expect(const PlaybackOptions().boostHeadroom, 1);
    expect(o.boostHeadroom, closeTo(1.9953, 1e-4));
  });
}

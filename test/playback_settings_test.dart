import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/playback_options.dart';
import 'package:oamp/core/track_cache.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/precache.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/ui/browse/settings_page.dart';
import 'package:oamp/ui/theme.dart';

import 'fakes/fakes.dart';

/// Records what the app asks the playback cache for.
class FakeTrackCache implements TrackCache {
  final List<List<String>> prefetched = [];
  int? limit;
  bool cleared = false;
  final _changes = StreamController<void>.broadcast();

  @override
  Uri urlFor(CacheRequest r) =>
      Uri.parse('http://127.0.0.1/${Uri.encodeComponent(r.key)}');
  @override
  void prefetch(List<CacheRequest> wanted) =>
      prefetched.add([for (final r in wanted) r.key]);
  @override
  bool isCached(String key) => false;
  @override
  set limitBytes(int bytes) => limit = bytes;
  @override
  Future<CacheUsage> usage() async =>
      cleared ? CacheUsage.empty : const CacheUsage(50 * 1024 * 1024, 7);
  @override
  Future<void> clear() async {
    cleared = true;
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;
  @override
  Future<void> dispose() => _changes.close();
}

Track t(
  String id, {
  String? album,
  double? gain,
  double? albumGain,
  double? peak,
}) => Track(
  id: id,
  title: id,
  albumId: album,
  replayGain: gain == null && albumGain == null
      ? null
      : ReplayGain(trackGain: gain, albumGain: albumGain, trackPeak: peak),
);

void main() {
  group('ReplayGain', () {
    test('off leaves every track alone', () {
      expect(const PlaybackOptions().gainFor(t('a', gain: -10)), 1);
    });

    test('track mode turns loud tracks down by their gain', () {
      const o = PlaybackOptions(replayGain: ReplayGainMode.track);
      expect(o.gainFor(t('a', gain: -6.0206)), closeTo(0.5, 1e-4));
    });

    test('album mode prefers the album value, then the track value', () {
      const o = PlaybackOptions(replayGain: ReplayGainMode.album);
      expect(
        o.gainFor(t('a', gain: -12, albumGain: -6.0206)),
        closeTo(0.5, 1e-4),
      );
      expect(o.gainFor(t('b', gain: -6.0206)), closeTo(0.5, 1e-4));
    });

    test('pre-amp adds on top, and the peak stops a boost clipping', () {
      const o = PlaybackOptions(
        replayGain: ReplayGainMode.track,
        preampDb: 6.0206,
      );
      expect(o.gainFor(t('a', gain: 0)), closeTo(2, 1e-3));
      expect(o.gainFor(t('b', gain: 0, peak: 0.8)), closeTo(1.25, 1e-9));
      expect(
        o.copyWith(preventClipping: false).gainFor(t('c', gain: 0, peak: 0.8)),
        closeTo(2, 1e-3),
      );
    });

    test('untagged tracks get the fallback gain', () {
      const o = PlaybackOptions(
        replayGain: ReplayGainMode.track,
        fallbackGainDb: -6.0206,
      );
      expect(o.gainFor(t('a')), closeTo(0.5, 1e-4));
    });
  });

  test('crossfade skips tracks on the same album unless asked', () {
    const o = PlaybackOptions(crossfade: Duration(seconds: 6));
    expect(o.shouldCrossfade(t('a', album: 'x'), t('b', album: 'x')), isFalse);
    expect(o.shouldCrossfade(t('a', album: 'x'), t('b', album: 'y')), isTrue);
    expect(
      o
          .copyWith(crossfadeSameAlbum: true)
          .shouldCrossfade(t('a', album: 'x'), t('b', album: 'x')),
      isTrue,
    );
    expect(
      const PlaybackOptions().shouldCrossfade(t('a'), t('b')),
      isFalse,
      reason: 'crossfade off',
    );
  });

  test('settings are saved and read back', () async {
    final prefs = MemoryPreferences();
    var c = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    final n = c.read(settingsProvider.notifier);
    await n.setPlayback(
      const PlaybackOptions(
        gapless: false,
        crossfade: Duration(seconds: 8),
        replayGain: ReplayGainMode.album,
        preampDb: 3,
      ),
    );
    await n.setQuality(
      const StreamQuality(format: StreamFormat.opus, bitRate: 160),
    );
    await n.setCache(const CacheOptions(precacheTracks: 10, limitMb: 2048));
    c.dispose();

    c = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    final s = c.read(settingsProvider);
    expect(s.playback.gapless, isFalse);
    expect(s.playback.crossfade, const Duration(seconds: 8));
    expect(s.playback.replayGain, ReplayGainMode.album);
    expect(s.playback.preampDb, 3);
    expect(
      s.quality,
      const StreamQuality(format: StreamFormat.opus, bitRate: 160),
    );
    expect(s.cache.precacheTracks, 10);
    expect(s.cache.limitBytes, 2048 * 1024 * 1024);
    c.dispose();
  });

  group('with a player', () {
    late FakeAudioEngine engine;
    late FakeTrackCache cache;
    late ProviderContainer c;
    final queue = [
      for (var i = 0; i < 6; i++)
        t('m$i', album: i < 3 ? 'a' : 'b', gain: -6.0206),
    ];

    setUp(() async {
      engine = FakeAudioEngine();
      cache = FakeTrackCache();
      c = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier()),
          audioEngineProvider.overrideWithValue(engine),
          trackCacheProvider.overrideWithValue(cache),
        ],
      );
      addTearDown(c.dispose);
      await c.read(sessionProvider.future);
      // The app always has the player on screen; keep it listened to.
      c.listen(playerProvider, (_, _) {});
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('playback settings reach the engine', () async {
      final n = c.read(settingsProvider.notifier);
      await n.setPlayback(
        const PlaybackOptions(
          gapless: false,
          crossfade: Duration(seconds: 4),
          replayGain: ReplayGainMode.track,
        ),
      );
      await settle();
      expect(engine.gapless, isFalse);
      expect(engine.crossfade, const Duration(seconds: 4));
      expect(engine.gainRefreshes, greaterThan(0));

      await c.read(playerProvider.notifier).playTracks(queue);
      final info = engine.queueInfo!;
      expect(info.gainAt(0), closeTo(0.5, 1e-4));
      expect(info.crossfadeBetween(1, 2), isFalse, reason: 'same album');
      expect(info.crossfadeBetween(2, 3), isTrue);
      expect(info.gainAt(99), 1);
    });

    test('tracks play through the cache at the chosen quality', () async {
      await c.read(playerProvider.notifier).playTracks(queue);
      expect(engine.queue.first.host, '127.0.0.1');
      expect(Uri.decodeComponent(engine.queue.first.path), '/fake:1|m0|raw');
    });

    test('a new quality re-resolves only the tracks still to come', () async {
      final p = c.read(playerProvider.notifier);
      await p.playTracks(queue, startIndex: 2);
      await settle();
      await c
          .read(settingsProvider.notifier)
          .setQuality(
            const StreamQuality(format: StreamFormat.mp3, bitRate: 192),
          );
      await settle();
      await settle();
      final keys = [for (final u in engine.queue) Uri.decodeComponent(u.path)];
      expect(keys.take(3), everyElement(endsWith('|raw')));
      expect(keys.skip(3), everyElement(endsWith('|mp3192')));
      expect(keys.map((k) => k.split('|')[1]), [for (final q in queue) q.id]);
    });

    test('the current and next tracks are pre-cached', () async {
      c.listen(precacheProvider, (_, _) {});
      await c
          .read(settingsProvider.notifier)
          .setCache(const CacheOptions(precacheTracks: 2, limitMb: 512));
      await c.read(playerProvider.notifier).playTracks(queue, startIndex: 1);
      await settle();
      expect(cache.limit, 512 * 1024 * 1024);
      expect(cache.prefetched.last, [
        'fake:1|m1|raw',
        'fake:1|m2|raw',
        'fake:1|m3|raw',
      ]);

      await c
          .read(settingsProvider.notifier)
          .setCache(const CacheOptions(precacheTracks: 0));
      await settle();
      expect(cache.prefetched.last, isEmpty);
    });
  });

  test('pre-cache wraps round when the queue repeats', () {
    final q = [for (var i = 0; i < 4; i++) t('m$i')];
    List<String> ids(PlayerState s, int n) =>
        tracksToPrecache(s, n).map((t) => t.id).toList();
    final s = PlayerState(queue: q, currentIndex: 2);
    expect(ids(s, 5), ['m2', 'm3']);
    expect(ids(s.copyWith(repeat: PlaybackRepeat.all), 5), [
      'm2',
      'm3',
      'm0',
      'm1',
    ]);
    expect(ids(s, 0), isEmpty);
  });

  testWidgets('the settings page changes playback options', (tester) async {
    tester.view.physicalSize = const Size(440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = MemoryPreferences();
    final cache = FakeTrackCache();
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier()),
        audioEngineProvider.overrideWithValue(FakeAudioEngine()),
        preferencesProvider.overrideWithValue(prefs),
        trackCacheProvider.overrideWithValue(cache),
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

    expect(find.text('Gapless playback'), findsOneWidget);
    expect(find.text('Pre-amp'), findsNothing, reason: 'ReplayGain is off');
    expect(find.text('50 MB in 7 tracks'), findsOneWidget);

    await tester.tap(find.text('ReplayGain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Album').last);
    await tester.pumpAndSettle();
    expect(prefs.getString('oamp.playback.replayGain'), 'album');
    expect(find.text('Pre-amp'), findsOneWidget);

    await tester.tap(find.text('Format'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opus').last);
    await tester.pumpAndSettle();
    expect(prefs.getString('oamp.stream.format'), 'opus');
    expect(find.text('Maximum bit rate'), findsOneWidget);

    await tester.tap(find.text('Gapless playback'));
    await tester.pumpAndSettle();
    expect(prefs.getBool('oamp.playback.gapless'), isFalse);

    await tester.tap(find.text('Clear cache'));
    await tester.pumpAndSettle();
    expect(cache.cleared, isTrue);
    expect(find.text('0.0 MB in 0 tracks'), findsOneWidget);
  });
}

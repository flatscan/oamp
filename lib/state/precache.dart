import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/track_cache.dart';
import 'player.dart';
import 'session.dart';
import 'settings.dart';

/// Keeps the playback cache fetching the current track and the next few in
/// the queue, as the queue changes. Watched for the app's lifetime by
/// main.dart.
final precacheProvider = Provider<void>((ref) {
  final cache = ref.watch(trackCacheProvider);
  if (cache == null) return;
  final options = ref.watch(cacheOptionsProvider);
  cache.limitBytes = options.limitBytes;
  if (ref.watch(sessionProvider).value == null) {
    cache.prefetch(const []);
    return;
  }
  final resolver = ref.watch(trackResolverProvider);

  void update(PlayerState s) {
    cache.prefetch([
      for (final t in tracksToPrecache(s, options.precacheTracks))
        ?resolver.cacheRequest(t),
    ]);
  }

  ref.listen<PlayerState>(playerProvider, (prev, next) {
    if (prev == null ||
        !identical(prev.queue, next.queue) ||
        prev.currentIndex != next.currentIndex ||
        prev.repeat != next.repeat) {
      update(next);
    }
  }, fireImmediately: true);
});

/// The current track, then up to [count] after it, wrapping round to the
/// start when the whole queue repeats. Empty when [count] is zero, so
/// turning pre-caching off stops background fetches.
List<Track> tracksToPrecache(PlayerState s, int count) {
  final cur = s.currentIndex;
  if (count <= 0 || cur == null || cur >= s.queue.length) return const [];
  final q = s.queue;
  final out = <Track>[q[cur]];
  for (var i = 1; i <= count && i < q.length; i++) {
    final j = cur + i;
    if (j < q.length) {
      out.add(q[j]);
    } else if (s.repeat == PlaybackRepeat.all) {
      out.add(q[j % q.length]);
    } else {
      break;
    }
  }
  return out;
}

/// Disk used by the playback cache, refreshed as files come and go.
final cacheUsageProvider = StreamProvider<CacheUsage>((ref) async* {
  final cache = ref.watch(trackCacheProvider);
  if (cache == null) {
    yield CacheUsage.empty;
    return;
  }
  yield await cache.usage();
  await for (final _ in cache.changes) {
    yield await cache.usage();
  }
});

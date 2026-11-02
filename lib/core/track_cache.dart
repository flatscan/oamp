/// One track the cache can fetch: [key] names the bytes (server, track and
/// stream quality), [upstream] is where they come from.
class CacheRequest {
  final String key;
  final Uri upstream;
  const CacheRequest(this.key, this.upstream);
}

/// Disk usage of the playback cache.
class CacheUsage {
  final int bytes;
  final int files;
  const CacheUsage(this.bytes, this.files);

  static const empty = CacheUsage(0, 0);
}

/// A temporary on-disk cache of streamed tracks.
///
/// The player plays [urlFor]'s address, which serves the cached file when it
/// is complete and streams from the server (saving as it goes) when not.
/// [prefetch] fetches upcoming tracks ahead of time. Files are evicted
/// oldest first once [limitBytes] is reached.
///
/// This is not offline storage: v2 downloads live elsewhere, are never
/// evicted, and are checked by the [TrackResolver] before this cache.
abstract class TrackCache {
  /// An address the audio engine can play for [request].
  Uri urlFor(CacheRequest request);

  /// Makes [wanted] the tracks to fetch ahead, in order. Replaces the
  /// previous list; fetches no longer wanted are cancelled.
  void prefetch(List<CacheRequest> wanted);

  /// Whether [key] is fully cached.
  bool isCached(String key);

  set limitBytes(int bytes);

  Future<CacheUsage> usage();

  /// Deletes every cached file not in use right now.
  Future<void> clear();

  /// Fires when a file finishes caching or is removed.
  Stream<void> get changes;

  Future<void> dispose();
}

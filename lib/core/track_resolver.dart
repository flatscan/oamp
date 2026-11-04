import 'models.dart';
import 'music_source.dart';
import 'playback_options.dart';
import 'track_cache.dart';

/// Turns a track into something the audio engine can play.
///
/// v1 streams from the server, through the playback cache when there is
/// one. Offline downloads (v2) add a resolver that returns a local file URI
/// when the track is downloaded and falls back to this one otherwise;
/// nothing else in the player changes.
abstract class TrackResolver {
  Future<Uri> resolve(Track track);

  /// The cache request for [track], or null when tracks are not cached.
  CacheRequest? cacheRequest(Track track) => null;

  /// A URI that starts [offset] into [track], when the URI from [resolve]
  /// cannot be seeked that far: a transcoded stream that is not cached yet.
  /// Null when an ordinary seek works.
  Uri? resolveFrom(Track track, Duration offset) => null;
}

class StreamingTrackResolver implements TrackResolver {
  final MusicSource source;
  final StreamQuality quality;

  /// Optional playback cache. Without one the engine streams directly.
  final TrackCache? cache;

  /// Whether the server can start a transcoded stream part way in.
  final bool canStartAt;

  const StreamingTrackResolver(
    this.source, {
    this.quality = StreamQuality.original,
    this.cache,
    this.canStartAt = false,
  });

  @override
  Uri? resolveFrom(Track track, Duration offset) {
    if (quality.isOriginal || !canStartAt) return null;
    final req = cacheRequest(track);
    if (req != null && cache!.isCached(req.key)) return null;
    return source.streamUrl(track.id, quality: quality, offset: offset);
  }

  @override
  CacheRequest? cacheRequest(Track track) => cache == null
      ? null
      : CacheRequest(
          '${source.serverId}|${track.id}|${quality.tag}',
          source.streamUrl(track.id, quality: quality),
        );

  @override
  Future<Uri> resolve(Track track) async {
    final req = cacheRequest(track);
    return req == null
        ? source.streamUrl(track.id, quality: quality)
        : cache!.urlFor(req);
  }
}

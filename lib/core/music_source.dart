import 'models.dart';

/// Features a backend may or may not support. The UI switches features on
/// from these instead of checking which backend it is talking to.
class SourceCapabilities {
  final bool hasLyrics;
  final bool hasSimilar;
  final bool hasQueueSync;

  const SourceCapabilities({
    this.hasLyrics = false,
    this.hasSimilar = false,
    this.hasQueueSync = false,
  });
}

/// A library on one server. Subsonic/Navidrome is the only v1
/// implementation; other backends (Jellyfin, Plex) become new
/// implementations of this interface rather than changes to the app.
///
/// Errors are thrown as [MusicSourceException] with a readable message.
abstract class MusicSource {
  /// Stable id of the server this source talks to. Credentials, caches and
  /// the saved queue are all keyed by it, so several servers can coexist.
  String get serverId;

  /// Short human label, such as `ed @ music.example.com`.
  String get displayName;

  SourceCapabilities get capabilities;

  /// Checks the server is reachable and the credentials work.
  Future<void> ping();

  Future<List<Artist>> getArtists();
  Future<ArtistDetail> getArtist(String id);
  Future<List<Album>> getAlbums({
    AlbumSort sort = AlbumSort.alphabetical,
    int size = 100,
    int offset = 0,
  });
  Future<AlbumDetail> getAlbum(String id);

  /// A URL that plays the track with no extra headers, so the local player
  /// or (later) a cast device can fetch it directly.
  Uri streamUrl(String trackId);

  /// URL for cover art at roughly [size] pixels, or null if there is none.
  Uri? coverArtUrl(String? coverArtId, {int size = 300});

  void close();
}

class MusicSourceException implements Exception {
  final String message;
  final int? code;
  MusicSourceException(this.message, {this.code});

  @override
  String toString() => code == null ? message : '$message (code $code)';
}

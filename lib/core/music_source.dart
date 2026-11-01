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

  /// The signed-in user's name on the server, which decides whose
  /// playlists can be edited.
  String get userName;

  SourceCapabilities get capabilities;

  /// Checks the server is reachable and the credentials work.
  Future<void> ping();

  Future<List<Artist>> getArtists();
  Future<ArtistDetail> getArtist(String id);

  /// Biography and similar artists. Empty when the server has none.
  Future<ArtistInfo> getArtistInfo(String id);

  /// The artist's most popular tracks that are in this library, most
  /// popular first. Empty when the server does not know.
  Future<List<Track>> getTopTracks(Artist artist, {int count = 10});

  /// Tracks like the given track or artist, for an instant mix. Only
  /// meaningful when [SourceCapabilities.hasSimilar] is set.
  Future<List<Track>> getSimilarTracks(String id, {int count = 50});
  Future<List<Album>> getAlbums({
    AlbumSort sort = AlbumSort.alphabetical,
    int size = 100,
    int offset = 0,
  });
  Future<AlbumDetail> getAlbum(String id);

  /// Artists, albums and tracks matching [query].
  Future<SearchResults> search(String query, {int limit = 20});

  Future<List<Playlist>> getPlaylists();
  Future<PlaylistDetail> getPlaylist(String id);

  /// Creates a playlist owned by the signed-in user.
  Future<Playlist> createPlaylist(
    String name, {
    List<String> trackIds = const [],
  });
  Future<void> renamePlaylist(String id, String name);

  /// Appends tracks to the end of a playlist.
  Future<void> addToPlaylist(String id, List<String> trackIds);

  /// Removes the entries at [indexes] (positions in the playlist, so the
  /// same track listed twice can be removed once).
  Future<void> removeFromPlaylist(String id, List<int> indexes);

  /// Replaces a playlist's tracks, which is how a new order is saved.
  Future<void> replacePlaylistTracks(String id, List<String> trackIds);
  Future<void> deletePlaylist(String id);

  /// A random selection from the whole library, for "shuffle everything".
  Future<List<Track>> getRandomTracks({int size = 100});

  /// Tracks the user has liked.
  Future<List<Track>> getLikedTracks();

  /// Likes or unlikes a track, album or artist.
  Future<void> setLiked(
    String id,
    bool liked, {
    LikeTarget target = LikeTarget.track,
  });

  /// Tells the server a track is playing ([submission] false) or has been
  /// listened to ([submission] true), which drives play counts and the
  /// "recently played" lists.
  Future<void> reportPlayback(String trackId, {required bool submission});

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

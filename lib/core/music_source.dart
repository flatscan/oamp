import 'models.dart';
import 'play_queue.dart';
import 'playback_options.dart';

/// Features a backend may or may not support. The UI switches features on
/// from these instead of checking which backend it is talking to.
///
/// The flags are what features check. [extensions] carries the raw protocol
/// extensions a server advertised (OpenSubsonic's, for Subsonic servers), for
/// the source itself and for features with no flag of their own; other
/// backends leave it empty and set the flags directly.
class SourceCapabilities {
  final bool hasLyrics;
  final bool hasSimilar;

  /// Whether the server keeps a play queue per user that [MusicSource.
  /// getPlayQueue] and [MusicSource.savePlayQueue] read and write, so
  /// listening can carry on from another device.
  final bool hasQueueSync;

  /// Whether tracks can be picked by genre, which radio falls back to when
  /// the server finds nothing similar.
  final bool hasGenres;

  /// Extension name to the versions the server supports, such as
  /// `{'songLyrics': [1], 'formPost': [1]}`. Empty when the server
  /// advertises none or has not been asked yet.
  final Map<String, List<int>> extensions;

  /// The server software and its version, such as `navidrome` and
  /// `0.64.2`, when the server says.
  final String? serverType;
  final String? serverVersion;

  const SourceCapabilities({
    this.hasLyrics = false,
    this.hasSimilar = false,
    this.hasQueueSync = false,
    this.hasGenres = false,
    this.extensions = const {},
    this.serverType,
    this.serverVersion,
  });

  /// Whether the server advertised extension [name], at [version] if given.
  bool supports(String name, {int? version}) {
    final versions = extensions[name];
    if (versions == null) return false;
    return version == null || versions.contains(version);
  }

  /// Whether radio can start at all: from similar tracks or from genres.
  bool get hasRadio => hasSimilar || hasGenres;
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

  /// What this source can do. Before [detectCapabilities] has run this is a
  /// safe baseline for the backend; afterwards it is what the server said.
  SourceCapabilities get capabilities;

  /// Asks the server what it supports and returns (and keeps, as
  /// [capabilities]) the result. Falls back to the baseline rather than
  /// throwing when the server cannot say.
  Future<SourceCapabilities> detectCapabilities();

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

  /// A random selection from the whole library, for "shuffle everything",
  /// or from one [genre] (which radio uses when nothing similar is found).
  Future<List<Track>> getRandomTracks({int size = 100, String? genre});

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

  /// The play queue the server holds for the signed-in user, as this or
  /// another client last saved it, or null when there is none. Only
  /// meaningful when [SourceCapabilities.hasQueueSync] is set.
  Future<SavedQueue?> getPlayQueue();

  /// Saves the play queue on the server, replacing what it held. An empty
  /// [trackIds] clears it. [currentIndex] points into [trackIds].
  Future<void> savePlayQueue(
    List<String> trackIds, {
    int? currentIndex,
    Duration position = Duration.zero,
  });

  /// A URL that plays the track with no extra headers, so the local player
  /// or (later) a cast device can fetch it directly. [quality] asks the
  /// server to transcode; the default streams the original file.
  Uri streamUrl(
    String trackId, {
    StreamQuality quality = StreamQuality.original,
  });

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

/// OAmp's own domain models. Every [MusicSource] maps its backend's types
/// into these, so the UI and providers never see Subsonic (or, later,
/// Jellyfin or Plex) types.
library;

class Artist {
  final String id;
  final String name;
  final int albumCount;
  final String? coverArt;

  /// Whether the user has liked (starred) the artist on the server.
  final bool liked;

  const Artist({
    required this.id,
    required this.name,
    this.albumCount = 0,
    this.coverArt,
    this.liked = false,
  });
}

/// Extra, optional facts about an artist. Servers usually fetch these from
/// an outside service, so either part can be missing.
class ArtistInfo {
  /// Plain text, without markup.
  final String? biography;

  /// Similar artists that are in this library.
  final List<Artist> similar;

  const ArtistInfo({this.biography, this.similar = const []});
}

class Album {
  final String id;
  final String name;
  final String? artist;
  final String? artistId;
  final int? year;
  final int songCount;
  final String? coverArt;
  final String? genre;
  final Duration? duration;

  /// Whether the user has liked (starred) the album on the server.
  final bool liked;

  /// Release types in lower case, such as `album`, `ep`, `single`, `live`
  /// or `compilation`. Empty when the server does not say.
  final List<String> releaseTypes;
  final bool isCompilation;

  const Album({
    required this.id,
    required this.name,
    this.artist,
    this.artistId,
    this.year,
    this.songCount = 0,
    this.coverArt,
    this.genre,
    this.duration,
    this.liked = false,
    this.releaseTypes = const [],
    this.isCompilation = false,
  });

  /// Which shelf of an artist's page the album belongs on.
  ReleaseKind get kind {
    if (isCompilation || releaseTypes.contains('compilation')) {
      return ReleaseKind.compilation;
    }
    if (releaseTypes.contains('live')) return ReleaseKind.live;
    if (releaseTypes.contains('ep') || releaseTypes.contains('single')) {
      return ReleaseKind.single;
    }
    return ReleaseKind.album;
  }
}

/// How an artist page groups releases.
enum ReleaseKind { album, single, live, compilation }

class Track {
  final String id;
  final String title;
  final String? artist;
  final String? artistId;
  final String? album;
  final String? albumId;
  final int? track;
  final int? discNumber;
  final Duration? duration;
  final String? coverArt;

  /// Whether the user has liked (starred) the track on the server.
  final bool liked;

  final int? year;

  /// File format as the server stores it, such as `flac` or `mp3`.
  final String? format;

  /// Kilobits per second.
  final int? bitRate;

  /// Hertz, such as 44100.
  final int? sampleRate;
  final int? bitDepth;

  const Track({
    required this.id,
    required this.title,
    this.artist,
    this.artistId,
    this.album,
    this.albumId,
    this.track,
    this.discNumber,
    this.duration,
    this.coverArt,
    this.liked = false,
    this.year,
    this.format,
    this.bitRate,
    this.sampleRate,
    this.bitDepth,
  });
}

class Playlist {
  final String id;
  final String name;
  final int songCount;
  final Duration? duration;
  final String? owner;
  final String? coverArt;
  final String? comment;
  final bool public;

  /// Set by servers for playlists nobody can edit, such as smart playlists.
  final bool readonly;

  const Playlist({
    required this.id,
    required this.name,
    this.songCount = 0,
    this.duration,
    this.owner,
    this.coverArt,
    this.comment,
    this.public = false,
    this.readonly = false,
  });
}

class PlaylistDetail {
  final Playlist playlist;
  final List<Track> tracks;
  const PlaylistDetail(this.playlist, this.tracks);
}

class SearchResults {
  final List<Artist> artists;
  final List<Album> albums;
  final List<Track> tracks;

  const SearchResults({
    this.artists = const [],
    this.albums = const [],
    this.tracks = const [],
  });

  bool get isEmpty => artists.isEmpty && albums.isEmpty && tracks.isEmpty;
}

class ArtistDetail {
  final Artist artist;
  final List<Album> albums;
  const ArtistDetail(this.artist, this.albums);
}

class AlbumDetail {
  final Album album;
  final List<Track> tracks;
  const AlbumDetail(this.album, this.tracks);
}

/// Album list orderings. Sources map these to their own sort options.
enum AlbumSort { alphabetical, newest, recent, frequent, random, starred }

/// What a like (star) applies to.
enum LikeTarget { track, album, artist }

/// What happens when the queue reaches its end, or a track ends.
enum PlaybackRepeat { off, all, one }

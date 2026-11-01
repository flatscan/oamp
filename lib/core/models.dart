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

  /// The name the server sorts by, such as `Beatles` for `The Beatles`.
  final String? sortName;

  const Artist({
    required this.id,
    required this.name,
    this.albumCount = 0,
    this.coverArt,
    this.liked = false,
    this.sortName,
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

  /// The name the server sorts by, such as `Wall` for `The Wall`.
  final String? sortName;

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
    this.sortName,
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

/// The letters of an A to Z jump bar: `#` for anything that does not start
/// with a letter, then A to Z.
const indexLetters = [
  '#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', //
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

const _plainLetters = {
  'À': 'A', 'Á': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A', 'Æ': 'A', //
  'Ç': 'C', 'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E', 'Ì': 'I', 'Í': 'I',
  'Î': 'I', 'Ï': 'I', 'Ñ': 'N', 'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O',
  'Ö': 'O', 'Ø': 'O', 'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U', 'Ý': 'Y',
};

/// Which of [indexLetters] a name files under.
String indexLetter(String sortName) {
  final s = sortName.trim();
  if (s.isEmpty) return '#';
  final c = s[0].toUpperCase();
  final plain = _plainLetters[c] ?? c;
  return indexLetters.contains(plain) ? plain : '#';
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

  /// Loudness data for volume levelling, or null when the server has none.
  final ReplayGain? replayGain;

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
    this.replayGain,
  });
}

/// ReplayGain values for a track, as the server read them from the file's
/// tags. Gains are in decibels, peaks are linear sample peaks where 1.0 is
/// full scale.
class ReplayGain {
  final double? trackGain;
  final double? albumGain;
  final double? trackPeak;
  final double? albumPeak;

  const ReplayGain({
    this.trackGain,
    this.albumGain,
    this.trackPeak,
    this.albumPeak,
  });

  bool get isEmpty => trackGain == null && albumGain == null;
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

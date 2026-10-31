/// Plain data classes for the parts of the Subsonic/OpenSubsonic API that
/// OAmp uses. Parsing is lenient because servers differ in which optional
/// fields they send.
library;

int? _int(Object? v) => v is int ? v : (v is String ? int.tryParse(v) : null);

class Artist {
  final String id;
  final String name;
  final int albumCount;
  final String? coverArt;

  const Artist({
    required this.id,
    required this.name,
    this.albumCount = 0,
    this.coverArt,
  });

  factory Artist.fromJson(Map<String, dynamic> j) => Artist(
    id: '${j['id']}',
    name: (j['name'] ?? 'Unknown artist') as String,
    albumCount: _int(j['albumCount']) ?? 0,
    coverArt: j['coverArt'] as String?,
  );
}

class Album {
  final String id;
  final String name;
  final String? artist;
  final String? artistId;
  final int? year;
  final int songCount;
  final String? coverArt;

  const Album({
    required this.id,
    required this.name,
    this.artist,
    this.artistId,
    this.year,
    this.songCount = 0,
    this.coverArt,
  });

  factory Album.fromJson(Map<String, dynamic> j) => Album(
    id: '${j['id']}',
    name: (j['name'] ?? j['title'] ?? 'Unknown album') as String,
    artist: j['artist'] as String?,
    artistId: j['artistId']?.toString(),
    year: _int(j['year']),
    songCount: _int(j['songCount']) ?? 0,
    coverArt: j['coverArt'] as String?,
  );
}

class Track {
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final String? albumId;
  final int? track;
  final int? discNumber;
  final Duration? duration;
  final String? coverArt;

  const Track({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.albumId,
    this.track,
    this.discNumber,
    this.duration,
    this.coverArt,
  });

  factory Track.fromJson(Map<String, dynamic> j) {
    final secs = _int(j['duration']);
    return Track(
      id: '${j['id']}',
      title: (j['title'] ?? 'Unknown track') as String,
      artist: j['artist'] as String?,
      album: j['album'] as String?,
      albumId: j['albumId']?.toString(),
      track: _int(j['track']),
      discNumber: _int(j['discNumber']),
      duration: secs == null ? null : Duration(seconds: secs),
      coverArt: j['coverArt'] as String?,
    );
  }
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

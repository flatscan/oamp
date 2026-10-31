/// OAmp's own domain models. Every [MusicSource] maps its backend's types
/// into these, so the UI and providers never see Subsonic (or, later,
/// Jellyfin or Plex) types.
library;

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

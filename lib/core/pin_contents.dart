import 'downloads.dart';
import 'models.dart';
import 'music_source.dart';

/// What the server holds for a pinned item right now.
class PinContents {
  final String name;
  final String? coverArt;
  final List<Track> tracks;
  const PinContents({required this.name, this.coverArt, required this.tracks});
}

/// Reads the item behind [pin] from [source].
///
/// Throws [MusicSourceException] as the source does; with
/// [MusicSourceErrorKind.notFound] when the server says the item is gone.
Future<PinContents> readPinContents(MusicSource source, Pin pin) async {
  switch (pin.kind) {
    case PinKind.album:
      final d = await source.getAlbum(pin.itemId);
      return PinContents(
        name: d.album.name,
        coverArt: d.album.coverArt,
        tracks: d.tracks,
      );
    case PinKind.playlist:
      final d = await source.getPlaylist(pin.itemId);
      return PinContents(
        name: d.playlist.name,
        coverArt: d.playlist.coverArt,
        tracks: d.tracks,
      );
    case PinKind.artist:
      final d = await source.getArtist(pin.itemId);
      const batch = 4;
      final tracks = <Track>[];
      for (var i = 0; i < d.albums.length; i += batch) {
        final end = i + batch < d.albums.length ? i + batch : d.albums.length;
        final got = await Future.wait([
          for (var j = i; j < end; j++) _albumTracks(source, d.albums[j].id),
        ]);
        got.forEach(tracks.addAll);
      }
      return PinContents(
        name: d.artist.name,
        coverArt: d.artist.coverArt,
        tracks: tracks,
      );
    case PinKind.liked:
      return PinContents(
        name: pin.name,
        coverArt: pin.coverArt,
        tracks: await source.getLikedTracks(),
      );
  }
}

/// An album's tracks; none when the album was removed since the artist was
/// read, which says nothing about the artist.
Future<List<Track>> _albumTracks(MusicSource source, String id) async {
  try {
    return (await source.getAlbum(id)).tracks;
  } on MusicSourceException catch (e) {
    if (e.kind == MusicSourceErrorKind.notFound) return const [];
    rethrow;
  }
}

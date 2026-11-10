import 'dart:math';

import 'downloads.dart';
import 'models.dart';

/// The music that is on the device, shaped like a small library: artists,
/// albums, playlists and search over just the downloaded tracks. This is
/// what the app shows when it is offline.
///
/// Built from the pins' saved track details, so it needs no server and
/// grows and shrinks as downloads do. Artists and albums that have no id
/// of their own (an untagged track) get one made from their name.
class OfflineLibrary {
  OfflineLibrary(this.pins, this._isDownloaded) {
    final seen = <String>{};
    for (final p in pins) {
      for (final t in p.tracks) {
        if (_isDownloaded(t.id) && seen.add(t.id)) tracks.add(t);
      }
    }
  }

  final List<Pin> pins;
  final bool Function(String trackId) _isDownloaded;

  /// Every downloaded track once, in the order the pins were made.
  final List<Track> tracks = [];

  bool get isEmpty => tracks.isEmpty;

  static String artistIdOf(Track t) =>
      t.artistId ?? 'offline-artist:${t.artist ?? 'Unknown artist'}';

  static String albumIdOf(Track t) =>
      t.albumId ??
      'offline-album:${t.album ?? 'Unknown album'}|${t.artist ?? ''}';

  /// The track's album as a list entry.
  static Album _albumFrom(String id, List<Track> of) {
    final first = of.first;
    final total = of.fold<Duration>(
      Duration.zero,
      (sum, t) => sum + (t.duration ?? Duration.zero),
    );
    return Album(
      id: id,
      name: first.album ?? 'Unknown album',
      artist: first.artist,
      artistId: first.artistId,
      year: of.map((t) => t.year).whereType<int>().firstOrNull,
      songCount: of.length,
      coverArt: of.map((t) => t.coverArt).whereType<String>().firstOrNull,
      genre: first.genre,
      duration: total > Duration.zero ? total : null,
    );
  }

  Map<String, List<Track>> _byAlbum([Iterable<Track>? from]) {
    final out = <String, List<Track>>{};
    for (final t in from ?? tracks) {
      (out[albumIdOf(t)] ??= []).add(t);
    }
    return out;
  }

  static int _trackOrder(Track a, Track b) {
    final d = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
    return d != 0 ? d : (a.track ?? 0).compareTo(b.track ?? 0);
  }

  static String _key(String s) => s.toLowerCase();

  List<Artist> artists() {
    final byArtist = <String, List<Track>>{};
    for (final t in tracks) {
      (byArtist[artistIdOf(t)] ??= []).add(t);
    }
    return [for (final e in byArtist.entries) _artistFrom(e.key, e.value)]
      ..sort((a, b) => _key(a.name).compareTo(_key(b.name)));
  }

  Artist _artistFrom(String id, List<Track> of) => Artist(
    id: id,
    name: of.first.artist ?? 'Unknown artist',
    albumCount: _byAlbum(of).length,
    coverArt: of.map((t) => t.coverArt).whereType<String>().firstOrNull,
  );

  ArtistDetail artist(String id) {
    final mine = [
      for (final t in tracks)
        if (artistIdOf(t) == id) t,
    ];
    if (mine.isEmpty) throw StateError('Not downloaded');
    return ArtistDetail(_artistFrom(id, mine), [
      for (final e in _byAlbum(mine).entries) _albumFrom(e.key, e.value),
    ]);
  }

  List<Album> albums({
    AlbumSort sort = AlbumSort.alphabetical,
    int size = 100,
    int offset = 0,
  }) {
    final all = [
      for (final e in _byAlbum().entries) _albumFrom(e.key, e.value),
    ];
    switch (sort) {
      case AlbumSort.newest:
        all.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
      case AlbumSort.random:
        all.shuffle(Random());
      case AlbumSort.alphabetical:
      case AlbumSort.recent:
      case AlbumSort.frequent:
      case AlbumSort.starred:
        all.sort((a, b) => _key(a.name).compareTo(_key(b.name)));
    }
    if (offset >= all.length) return const [];
    return all.sublist(offset, min(all.length, offset + size));
  }

  AlbumDetail album(String id) {
    final mine = [
      for (final t in tracks)
        if (albumIdOf(t) == id) t,
    ]..sort(_trackOrder);
    if (mine.isEmpty) throw StateError('Not downloaded');
    return AlbumDetail(_albumFrom(id, mine), mine);
  }

  Track? track(String id) {
    for (final t in tracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  SearchResults search(String query, {int limit = 20}) {
    final q = _key(query.trim());
    if (q.isEmpty) return const SearchResults();
    bool hit(String? s) => s != null && _key(s).contains(q);
    final matching = [
      for (final t in tracks)
        if (hit(t.title) || hit(t.artist) || hit(t.album)) t,
    ];
    return SearchResults(
      artists: [
        for (final a in artists())
          if (hit(a.name)) a,
      ].take(limit).toList(),
      albums: [
        for (final a in albums(size: 1 << 30))
          if (hit(a.name) || hit(a.artist)) a,
      ].take(limit).toList(),
      tracks: matching.take(limit).toList(),
    );
  }

  List<Playlist> playlists() => [
    for (final p in pins)
      if (p.kind == PinKind.playlist)
        Playlist(
          id: p.itemId,
          name: p.name,
          coverArt: p.coverArt,
          songCount: p.tracks.where((t) => _isDownloaded(t.id)).length,
          // Nobody can edit a playlist while offline.
          readonly: true,
        ),
  ];

  PlaylistDetail playlist(String id) {
    final pin = pins
        .where((p) => p.kind == PinKind.playlist && p.itemId == id)
        .firstOrNull;
    if (pin == null) throw StateError('Not downloaded');
    final mine = [
      for (final t in pin.tracks)
        if (_isDownloaded(t.id)) t,
    ];
    return PlaylistDetail(
      Playlist(
        id: id,
        name: pin.name,
        coverArt: pin.coverArt,
        songCount: mine.length,
        readonly: true,
      ),
      mine,
    );
  }

  /// Liked tracks that are downloaded: those in a liked-tracks pin, and any
  /// other downloaded track that was liked when it was saved.
  List<Track> liked() {
    final out = <Track>[];
    final seen = <String>{};
    for (final p in pins.where((p) => p.kind == PinKind.liked)) {
      for (final t in p.tracks) {
        if (_isDownloaded(t.id) && seen.add(t.id)) out.add(t);
      }
    }
    for (final t in tracks) {
      if (t.liked && seen.add(t.id)) out.add(t);
    }
    return out;
  }

  List<Track> random({int size = 100, String? genre}) {
    final pool = [
      for (final t in tracks)
        if (genre == null ||
            t.genres.any((g) => g.toLowerCase() == genre.toLowerCase()))
          t,
    ]..shuffle(Random());
    return pool.take(size).toList();
  }
}

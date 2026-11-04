import '../core/models.dart';
import '../core/music_source.dart';

/// Where a radio's tracks came from, so the UI can say so.
enum RadioBasis {
  /// The server's similar tracks.
  similar,

  /// Similar tracks topped up with tracks from the seed's genres.
  similarAndGenre,

  /// Only the seed's genres, because the server found nothing similar.
  genre,

  /// Nothing to play.
  none,
}

class RadioMix {
  final List<Track> tracks;
  final RadioBasis basis;

  /// The genres used, main one first. Empty unless genres were used.
  final List<String> genres;

  const RadioMix(this.tracks, this.basis, {this.genres = const []});

  bool get isEmpty => tracks.isEmpty;
}

/// Builds the queue for a track or artist radio.
///
/// Asks the server for similar tracks first. When it has none (Navidrome
/// without an outside agent such as Last.fm returns an empty list) or too few,
/// fills up with random tracks from the seed's genres. The seed track, when
/// given, leads the queue and is never repeated.
class RadioMixer {
  final MusicSource source;
  final SourceCapabilities capabilities;

  /// How many tracks a radio aims for.
  final int size;

  /// Fewer similar tracks than this and genre tracks top the mix up.
  final int minSimilar;

  /// At most this many of the seed's genres are mixed in.
  final int maxGenres;

  const RadioMixer(
    this.source, {
    required this.capabilities,
    this.size = 50,
    this.minSimilar = 10,
    this.maxGenres = 3,
  });

  /// Radio from a track: similar to it, else its genres (or its album's).
  Future<RadioMix> forTrack(Track seed) => _build(
    similarTo: seed.id,
    seed: seed,
    genres: () async {
      if (seed.genres.isNotEmpty) return seed.genres;
      final albumId = seed.albumId;
      if (albumId == null) return const [];
      final g = (await source.getAlbum(albumId)).album.genre;
      return [?g];
    },
  );

  /// Radio from an artist: similar to them, else the genres they release
  /// in most.
  Future<RadioMix> forArtist(String artistId) => _build(
    similarTo: artistId,
    genres: () async {
      final detail = await source.getArtist(artistId);
      return topGenres([for (final a in detail.albums) ?a.genre]);
    },
  );

  Future<RadioMix> _build({
    required String similarTo,
    required Future<List<String>> Function() genres,
    Track? seed,
  }) async {
    var similar = const <Track>[];
    if (capabilities.hasSimilar) {
      try {
        similar = await source.getSimilarTracks(similarTo, count: size);
      } on MusicSourceException {
        // Some servers refuse rather than return nothing; use genres.
      }
    }
    final seen = <String>{?seed?.id};
    final picked = <Track>[?seed];
    void add(Iterable<Track> ts) {
      for (final t in ts) {
        if (picked.length >= size) return;
        if (seen.add(t.id)) picked.add(t);
      }
    }

    add(similar);
    final similarCount = picked.length - (seed == null ? 0 : 1);
    if (similarCount >= minSimilar || !capabilities.hasGenres) {
      return _mix(picked, similarCount, const [], seed);
    }

    final used = (await genres()).take(maxGenres).toList();
    if (used.isNotEmpty) {
      final want = size - similarCount;
      final perGenre = (want / used.length).ceil();
      final pools = await Future.wait([
        for (final g in used) source.getRandomTracks(size: perGenre, genre: g),
      ]);
      add(_interleave(pools));
    }
    final genreCount = picked.length - similarCount - (seed == null ? 0 : 1);
    return _mix(picked, similarCount, genreCount > 0 ? used : const [], seed);
  }

  RadioMix _mix(
    List<Track> picked,
    int similarCount,
    List<String> genres,
    Track? seed,
  ) {
    final onlySeed = picked.length == (seed == null ? 0 : 1);
    if (onlySeed) return const RadioMix([], RadioBasis.none);
    final basis = genres.isEmpty
        ? RadioBasis.similar
        : similarCount == 0
        ? RadioBasis.genre
        : RadioBasis.similarAndGenre;
    return RadioMix(picked, basis, genres: genres);
  }

  /// Genres by how often they appear, most first; ties keep first-seen order.
  static List<String> topGenres(Iterable<String> genres) {
    final counts = <String, int>{};
    for (final g in genres) {
      final k = g.trim();
      if (k.isNotEmpty) counts[k] = (counts[k] ?? 0) + 1;
    }
    final order = counts.keys.toList();
    return order..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }

  /// One from each list in turn, so a radio does not play one genre in a
  /// block.
  static List<Track> _interleave(List<List<Track>> pools) {
    final out = <Track>[];
    for (var i = 0; pools.any((p) => i < p.length); i++) {
      for (final p in pools) {
        if (i < p.length) out.add(p[i]);
      }
    }
    return out;
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import 'session.dart';

/// Library data, cached per session by Riverpod. Pull-to-refresh or the
/// refresh button invalidates these.
final artistsProvider = FutureProvider<List<Artist>>(
  (ref) => ref.watch(clientProvider).getArtists(),
);

final albumsProvider = FutureProvider<List<Album>>(
  (ref) => ref.watch(clientProvider).getAlbumList(size: 500),
);

final artistDetailProvider = FutureProvider.family<ArtistDetail, String>(
  (ref, id) => ref.watch(clientProvider).getArtist(id),
);

final albumDetailProvider = FutureProvider.family<AlbumDetail, String>(
  (ref, id) => ref.watch(clientProvider).getAlbum(id),
);

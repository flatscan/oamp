import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import 'session.dart';

/// Library queries against the active [MusicSource], cached by Riverpod and
/// dropped when the session changes. Pull-to-refresh invalidates them.
final artistsProvider = FutureProvider<List<Artist>>(
  (ref) => ref.watch(musicSourceProvider).getArtists(),
);

final albumsProvider = FutureProvider<List<Album>>(
  (ref) => ref.watch(musicSourceProvider).getAlbums(size: 500),
);

final artistDetailProvider = FutureProvider.family<ArtistDetail, String>(
  (ref, id) => ref.watch(musicSourceProvider).getArtist(id),
);

final albumDetailProvider = FutureProvider.family<AlbumDetail, String>(
  (ref, id) => ref.watch(musicSourceProvider).getAlbum(id),
);

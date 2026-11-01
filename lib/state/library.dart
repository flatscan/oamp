import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import 'session.dart';

/// Library queries against the active [MusicSource], cached by Riverpod and
/// dropped when the session changes. Pull-to-refresh invalidates them.
final artistsProvider = FutureProvider<List<Artist>>(
  (ref) => ref.watch(musicSourceProvider).getArtists(),
);

final artistDetailProvider = FutureProvider.family<ArtistDetail, String>(
  (ref, id) => ref.watch(musicSourceProvider).getArtist(id),
);

final albumDetailProvider = FutureProvider.family<AlbumDetail, String>(
  (ref, id) => ref.watch(musicSourceProvider).getAlbum(id),
);

/// Every track by an artist, album by album, for the artist page's play and
/// shuffle buttons.
final artistTracksProvider = FutureProvider.family<List<Track>, String>((
  ref,
  id,
) async {
  final detail = await ref.watch(artistDetailProvider(id).future);
  final albums = await Future.wait([
    for (final a in detail.albums) ref.watch(albumDetailProvider(a.id).future),
  ]);
  return [for (final a in albums) ...a.tracks];
});

/// A short album row for the home screen, such as recently added.
final homeAlbumsProvider = FutureProvider.family<List<Album>, AlbumSort>(
  (ref, sort) => ref.watch(musicSourceProvider).getAlbums(sort: sort, size: 24),
);

final playlistsProvider = FutureProvider<List<Playlist>>(
  (ref) => ref.watch(musicSourceProvider).getPlaylists(),
);

final playlistDetailProvider = FutureProvider.family<PlaylistDetail, String>(
  (ref, id) => ref.watch(musicSourceProvider).getPlaylist(id),
);

final likedTracksProvider = FutureProvider<List<Track>>(
  (ref) => ref.watch(musicSourceProvider).getLikedTracks(),
);

final searchProvider = FutureProvider.family<SearchResults, String>((
  ref,
  query,
) {
  if (query.trim().isEmpty) return const SearchResults();
  return ref.watch(musicSourceProvider).search(query.trim());
});

/// The whole album list in one ordering, fetched a page at a time as the
/// user scrolls.
class AlbumPages {
  final List<Album> albums;
  final bool loading;
  final bool done;
  final Object? error;

  const AlbumPages({
    this.albums = const [],
    this.loading = false,
    this.done = false,
    this.error,
  });
}

final albumPagesProvider =
    NotifierProvider.family<AlbumPagesNotifier, AlbumPages, AlbumSort>(
      AlbumPagesNotifier.new,
    );

class AlbumPagesNotifier extends Notifier<AlbumPages> {
  AlbumPagesNotifier(this.sort);
  final AlbumSort sort;

  static const pageSize = 120;
  bool _fetching = false;

  @override
  AlbumPages build() {
    ref.watch(musicSourceProvider);
    Future.microtask(loadMore);
    return const AlbumPages(loading: true);
  }

  /// Fetches the next page unless one is already loading or the end is
  /// reached. Safe to call on every scroll.
  Future<void> loadMore() async {
    final s = state;
    if (s.done || _fetching) return;
    _fetching = true;
    state = AlbumPages(albums: s.albums, loading: true);
    try {
      final page = await ref
          .read(musicSourceProvider)
          .getAlbums(sort: sort, size: pageSize, offset: s.albums.length);
      if (!ref.mounted) return;
      state = AlbumPages(
        albums: List.unmodifiable([...s.albums, ...page]),
        // Random order has no end, so stop after one page there.
        done: page.length < pageSize || sort == AlbumSort.random,
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = AlbumPages(albums: s.albums, error: e);
    } finally {
      _fetching = false;
    }
  }
}

/// Like/unlike state for tracks. A track's own [Track.liked] is what the
/// server said when it was fetched; toggles made since are kept here so every
/// screen agrees without refetching.
final likesProvider = NotifierProvider<LikesNotifier, Map<String, bool>>(
  LikesNotifier.new,
);

class LikesNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() {
    ref.watch(musicSourceProvider);
    return const {};
  }

  bool isLiked(Track t) => state[t.id] ?? t.liked;

  Future<void> toggle(Track t) async {
    final liked = !isLiked(t);
    state = {...state, t.id: liked};
    try {
      await ref.read(musicSourceProvider).setLiked(t.id, liked);
      ref.invalidate(likedTracksProvider);
    } catch (_) {
      if (ref.mounted) state = {...state, t.id: !liked};
      rethrow;
    }
  }
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import 'session.dart';
import 'settings.dart';

/// Library queries against the active [MusicSource], cached by Riverpod and
/// dropped when the session changes. Pull-to-refresh invalidates them.
final artistsProvider = FutureProvider<List<Artist>>(
  (ref) => ref.watch(musicSourceProvider).getArtists(),
);

final artistDetailProvider = FutureProvider.family<ArtistDetail, String>(
  (ref, id) => ref.watch(musicSourceProvider).getArtist(id),
);

final artistInfoProvider = FutureProvider.family<ArtistInfo, String>(
  (ref, id) => ref.watch(musicSourceProvider).getArtistInfo(id),
);

/// An artist's popular tracks, keyed by `(id, name)` because Subsonic looks
/// them up by name.
final topTracksProvider =
    FutureProvider.family<List<Track>, ({String id, String name})>(
      (ref, a) async => a.name.isEmpty
          ? const <Track>[]
          : ref
                .watch(musicSourceProvider)
                .getTopTracks(Artist(id: a.id, name: a.name), count: 20),
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

/// Search results for a query, with up to [limit] of each kind. The
/// search page asks for a few of everything, and more of one kind when a
/// filter is chosen.
final searchProvider =
    FutureProvider.family<SearchResults, ({String query, int limit})>((ref, q) {
      if (q.query.trim().isEmpty) return const SearchResults();
      return ref
          .watch(musicSourceProvider)
          .search(q.query.trim(), limit: q.limit);
    });

/// Searches the user ran recently on this server, newest first.
final recentSearchesProvider =
    NotifierProvider<RecentSearchesNotifier, List<String>>(
      RecentSearchesNotifier.new,
    );

class RecentSearchesNotifier extends Notifier<List<String>> {
  static const max = 12;

  String? get _key {
    final id = ref.read(sessionProvider).value?.serverId;
    return id == null ? null : 'oamp.search.recent.$id';
  }

  @override
  List<String> build() {
    ref.watch(sessionProvider);
    final key = _key;
    if (key == null) return const [];
    return ref.read(preferencesProvider).getStringList(key) ?? const [];
  }

  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final lower = q.toLowerCase();
    await _save(
      [q, ...state.where((s) => s.toLowerCase() != lower)].take(max).toList(),
    );
  }

  Future<void> remove(String query) =>
      _save([...state.where((s) => s != query)]);

  Future<void> clear() => _save(const []);

  Future<void> _save(List<String> list) async {
    state = List.unmodifiable(list);
    final key = _key;
    if (key != null) {
      await ref.read(preferencesProvider).setStringList(key, list);
    }
  }
}

/// Changes to playlists. Each call goes to the server, then drops the
/// cached playlist lists so every screen shows the result.
final playlistActionsProvider = Provider<PlaylistActions>(PlaylistActions.new);

class PlaylistActions {
  PlaylistActions(this._ref);
  final Ref _ref;

  void _changed([String? id]) {
    _ref.invalidate(playlistsProvider);
    if (id != null) _ref.invalidate(playlistDetailProvider(id));
  }

  /// Whether the signed-in user may change [p].
  bool canEdit(Playlist p) {
    if (p.readonly) return false;
    final owner = p.owner;
    return owner == null || owner == _ref.read(musicSourceProvider).userName;
  }

  Future<Playlist> create(String name, [List<Track> tracks = const []]) async {
    final p = await _ref
        .read(musicSourceProvider)
        .createPlaylist(name, trackIds: [for (final t in tracks) t.id]);
    _changed(p.id);
    return p;
  }

  Future<void> rename(Playlist p, String name) async {
    await _ref.read(musicSourceProvider).renamePlaylist(p.id, name);
    _changed(p.id);
  }

  Future<void> add(Playlist p, List<Track> tracks) async {
    await _ref.read(musicSourceProvider).addToPlaylist(p.id, [
      for (final t in tracks) t.id,
    ]);
    _changed(p.id);
  }

  Future<void> removeAt(Playlist p, List<int> indexes) async {
    await _ref.read(musicSourceProvider).removeFromPlaylist(p.id, indexes);
    _changed(p.id);
  }

  Future<void> replaceTracks(Playlist p, List<Track> tracks) async {
    await _ref.read(musicSourceProvider).replacePlaylistTracks(p.id, [
      for (final t in tracks) t.id,
    ]);
    _changed(p.id);
  }

  Future<void> delete(Playlist p) async {
    await _ref.read(musicSourceProvider).deletePlaylist(p.id);
    _changed();
  }
}

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

/// Like/unlike state for tracks, albums or artists, by id. An item's own
/// `liked` field is what the server said when it was fetched; toggles made
/// since are kept here so every screen agrees without refetching.
final likesProvider =
    NotifierProvider.family<LikesNotifier, Map<String, bool>, LikeTarget>(
      LikesNotifier.new,
    );

class LikesNotifier extends Notifier<Map<String, bool>> {
  LikesNotifier(this.target);
  final LikeTarget target;

  @override
  Map<String, bool> build() {
    ref.watch(musicSourceProvider);
    return const {};
  }

  bool isLiked(String id, {required bool fetched}) => state[id] ?? fetched;

  Future<void> toggle(String id, {required bool fetched}) async {
    final liked = !isLiked(id, fetched: fetched);
    state = {...state, id: liked};
    try {
      await ref.read(musicSourceProvider).setLiked(id, liked, target: target);
      switch (target) {
        case LikeTarget.track:
          ref.invalidate(likedTracksProvider);
        case LikeTarget.album:
          ref.invalidate(homeAlbumsProvider(AlbumSort.starred));
          ref.invalidate(albumPagesProvider(AlbumSort.starred));
        case LikeTarget.artist:
          break;
      }
    } catch (_) {
      if (ref.mounted) state = {...state, id: !liked};
      rethrow;
    }
  }
}

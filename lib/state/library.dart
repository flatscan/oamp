import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import 'downloads.dart';
import 'offline.dart';
import 'session.dart';
import 'settings.dart';

/// Library queries against the active [MusicSource], cached by Riverpod and
/// dropped when the session changes. Pull-to-refresh invalidates them.
final artistsProvider = FutureProvider<List<Artist>>(
  (ref) => ref.watchLibrary().getArtists(),
);

/// The artist list split by index letter, worked out once per fetch rather
/// than on every rebuild, so a list of tens of thousands stays cheap.
final artistIndexProvider = FutureProvider<LetterGroups<Artist>>((ref) async {
  final artists = await ref.watch(artistsProvider.future);
  return LetterGroups.of(artists, (a) => a.sortName ?? a.name);
});

/// Items in display order, cut into runs that share an index letter. Each
/// run is drawn as a heading and then fixed-height rows, so the distance to
/// any letter is a sum over at most 27 runs and never needs the rows above
/// it to be built or measured.
class LetterGroups<T> {
  final List<({String letter, List<T> items})> groups;
  final int length;

  const LetterGroups._(this.groups, this.length);

  factory LetterGroups.of(List<T> items, String Function(T) sortName) {
    final groups = <({String letter, List<T> items})>[];
    List<T>? run;
    String? last;
    for (final item in items) {
      final l = indexLetter(sortName(item));
      if (l != last || run == null) {
        run = <T>[];
        groups.add((letter: l, items: run));
        last = l;
      }
      run.add(item);
    }
    return LetterGroups._(List.unmodifiable(groups), items.length);
  }

  bool get isEmpty => length == 0;

  /// Letters that have at least one item.
  Set<String> get letters => {for (final g in groups) g.letter};

  /// Scroll offset of [letter]'s heading, given the height of a heading
  /// and of a row. A letter with no items gives the offset of the next
  /// group, or the end of the list.
  double offsetOf(
    String letter, {
    required double headerHeight,
    required double rowHeight,
  }) {
    final target = indexLetters.indexOf(letter);
    var offset = 0.0;
    for (final g in groups) {
      if (g.letter == letter) return offset;
      // A server that sorts '#' names after Z puts that run last, so only
      // stop at a later letter when the run is a real letter.
      if (g.letter != '#' && indexLetters.indexOf(g.letter) > target) {
        return offset;
      }
      offset += headerHeight + rowHeight * g.items.length;
    }
    return offset;
  }
}

final artistDetailProvider = FutureProvider.family<ArtistDetail, String>(
  (ref, id) => ref.watchLibrary().getArtist(id),
);

final artistInfoProvider = FutureProvider.family<ArtistInfo, String>(
  (ref, id) => ref.watchLibrary().getArtistInfo(id),
);

/// An artist's popular tracks, keyed by `(id, name)` because Subsonic looks
/// them up by name.
final topTracksProvider =
    FutureProvider.family<List<Track>, ({String id, String name})>(
      (ref, a) async => a.name.isEmpty
          ? const <Track>[]
          : ref.watchLibrary().getTopTracks(
              Artist(id: a.id, name: a.name),
              count: 20,
            ),
    );

final albumDetailProvider = FutureProvider.family<AlbumDetail, String>(
  (ref, id) => ref.watchLibrary().getAlbum(id),
);

/// Every track by an artist, album by album, for the artist page's play and
/// shuffle buttons.
final artistTracksProvider = FutureProvider.family<List<Track>, String>((
  ref,
  id,
) async {
  final detail = await ref.watch(artistDetailProvider(id).future);
  const batchSize = 4;
  final out = <Track>[];
  for (var i = 0; i < detail.albums.length; i += batchSize) {
    final end = (i + batchSize < detail.albums.length)
        ? i + batchSize
        : detail.albums.length;
    final batch = await Future.wait([
      for (var j = i; j < end; j++)
        ref.watch(albumDetailProvider(detail.albums[j].id).future),
    ]);
    for (final a in batch) {
      out.addAll(a.tracks);
    }
  }
  return out;
});

/// A short album row for the home screen, such as recently added.
final homeAlbumsProvider = FutureProvider.family<List<Album>, AlbumSort>(
  (ref, sort) => ref.watchLibrary().getAlbums(sort: sort, size: 24),
);

final playlistsProvider = FutureProvider<List<Playlist>>(
  (ref) => ref.watchLibrary().getPlaylists(),
);

final playlistDetailProvider = FutureProvider.family<PlaylistDetail, String>(
  (ref, id) => ref.watchLibrary().getPlaylist(id),
);

final likedTracksProvider = FutureProvider<List<Track>>(
  (ref) => ref.watchLibrary().getLikedTracks(),
);

final likedArtistsProvider = FutureProvider<List<Artist>>(
  (ref) => ref.watchLibrary().getLikedArtists(),
);

/// Search results for a query, with up to [limit] of each kind. The
/// search page asks for a few of everything, and more of one kind when a
/// filter is chosen.
final searchProvider =
    FutureProvider.family<SearchResults, ({String query, int limit})>((ref, q) {
      if (q.query.trim().isEmpty) return const SearchResults();
      return ref.watchLibrary().search(q.query.trim(), limit: q.limit);
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
    if (id != null) {
      _ref.invalidate(playlistDetailProvider(id));
      // A downloaded playlist follows the change at once.
      unawaited(
        _ref
            .read(downloadsProvider.notifier)
            .syncPin(PinKind.playlist, id, force: true),
      );
    }
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
  Future<void>? _inflight;

  @override
  AlbumPages build() {
    ref.watchLibrary();
    _inflight = null;
    Future.microtask(loadMore);
    return const AlbumPages(loading: true);
  }

  /// Fetches the next page unless the end is reached. Safe to call on every
  /// scroll: while a page is loading, it returns that page's future.
  Future<void> loadMore() {
    if (state.done) return Future.value();
    return _inflight ??= _fetch().whenComplete(() => _inflight = null);
  }

  Future<void> _fetch() async {
    final s = state;
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
    }
  }

  /// Loads pages until one reaches albums filed under [letter] (or later),
  /// and returns the index of the first such album, or the end of the list.
  /// Only meaningful in A to Z order.
  ///
  /// A jump can be thousands of albums past what is loaded, so rather than
  /// the scrolling page size this fetches [jumpPageSize] albums a page,
  /// [jumpBatch] pages at a time: a library of 10,000 albums reaches Z in a
  /// handful of round trips instead of eighty.
  Future<int> loadThrough(String letter) async {
    final target = indexLetters.indexOf(letter);
    var scanned = 0;
    int firstAt() {
      final albums = state.albums;
      for (; scanned < albums.length; scanned++) {
        final a = albums[scanned];
        final l = indexLetter(a.sortName ?? a.name);
        // A '#' album sorted after Z (a non-Latin title, say) is not a
        // sign the letter has been passed.
        if (l == '#' && target > 0) continue;
        if (indexLetters.indexOf(l) >= target) return scanned;
      }
      return -1;
    }

    var i = firstAt();
    while (i < 0 && !state.done && state.error == null) {
      await _fastForward();
      if (!ref.mounted) return 0;
      i = firstAt();
    }
    if (i < 0) return state.albums.length;
    // Load a screenful past it too, so it can be scrolled to the top.
    while (state.albums.length < i + 60 && !state.done && state.error == null) {
      await loadMore();
      if (!ref.mounted) break;
    }
    return i;
  }

  static const jumpPageSize = 500;
  static const jumpBatch = 4;

  /// Fetches the next [jumpBatch] pages of [jumpPageSize] together.
  Future<void> _fastForward() {
    if (state.done) return Future.value();
    return _inflight ??= _fetchBatch().whenComplete(() => _inflight = null);
  }

  Future<void> _fetchBatch() async {
    final s = state;
    state = AlbumPages(albums: s.albums, loading: true);
    final source = ref.read(musicSourceProvider);
    try {
      final pages = await Future.wait([
        for (var k = 0; k < jumpBatch; k++)
          source.getAlbums(
            sort: sort,
            size: jumpPageSize,
            offset: s.albums.length + k * jumpPageSize,
          ),
      ]);
      if (!ref.mounted) return;
      final albums = [...s.albums];
      var done = false;
      for (final page in pages) {
        albums.addAll(page);
        if (page.length < jumpPageSize) {
          done = true;
          break;
        }
      }
      state = AlbumPages(albums: List.unmodifiable(albums), done: done);
    } catch (e) {
      if (!ref.mounted) return;
      state = AlbumPages(albums: s.albums, error: e);
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
          // Downloaded liked tracks follow the change.
          unawaited(
            ref
                .read(downloadsProvider.notifier)
                .syncPin(PinKind.liked, Pin.likedItemId, force: true),
          );
        case LikeTarget.album:
          ref.invalidate(homeAlbumsProvider(AlbumSort.starred));
          ref.invalidate(albumPagesProvider(AlbumSort.starred));
        case LikeTarget.artist:
          ref.invalidate(likedArtistsProvider);
      }
    } catch (_) {
      if (ref.mounted) state = {...state, id: !liked};
      rethrow;
    }
  }
}

/// Ratings changed in this session, by id. An item's own `rating` is what
/// the server said when it was fetched; changes made since are kept here
/// so every screen agrees without refetching.
final ratingsProvider = NotifierProvider<RatingsNotifier, Map<String, int>>(
  RatingsNotifier.new,
);

class RatingsNotifier extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    ref.watch(musicSourceProvider);
    return const {};
  }

  int ratingOf(String id, {required int fetched}) => state[id] ?? fetched;

  /// Sets [id]'s rating (0 clears it), putting it back if the server
  /// refuses.
  Future<void> rate(String id, int rating, {required int fetched}) async {
    final before = ratingOf(id, fetched: fetched);
    state = {...state, id: rating};
    try {
      await ref.read(musicSourceProvider).setRating(id, rating);
    } catch (_) {
      if (ref.mounted) state = {...state, id: before};
      rethrow;
    }
  }
}

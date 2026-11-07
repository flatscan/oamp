import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/music_source.dart';
import '../platform/system_controls.dart';
import 'player.dart';
import 'radio.dart';
import 'session.dart';

/// What Android Auto browses; see [CarLibrary].
final carLibraryProvider = Provider<CarLibrary>((ref) {
  final library = CarLibrary(ref);
  ref.onDispose(library.dispose);
  return library;
});

/// The library as Android Auto (and later other car or watch screens)
/// browses it: Home, Playlists, Artists and Albums tabs, search, and voice
/// requests, played through the same [PlayerController] as the app.
///
/// Node ids are paths such as `album/<id>` or `play/album/<id>/<index>`,
/// with each id percent-encoded.
class CarLibrary implements MediaLibrary {
  CarLibrary(this.ref) {
    ref.listen(sessionProvider, (prev, next) {
      if (prev?.value?.serverId != next.value?.serverId) {
        _allAlbums = null;
        _changes.add(null);
      }
    });
  }

  final Ref ref;
  final _changes = StreamController<void>.broadcast();

  /// The most a folder lists. Head units page through long lists slowly,
  /// and every entry crosses to the car in one message.
  static const maxItems = 400;

  /// Artist and album tabs longer than this are split by first letter.
  static const letterThreshold = 100;

  /// Albums in each row of the Home tab.
  static const homeRow = 10;

  static const _albumsPage = 500;
  static const _albumsFresh = Duration(minutes: 15);

  @override
  Stream<void> get changes => _changes.stream;

  void dispose() => _changes.close();

  /// The signed-in source, waiting for a saved sign-in to be read when the
  /// car connects before the app has finished starting.
  Future<MusicSource?> _source() async {
    try {
      return (await ref.read(sessionProvider.future))?.source;
    } catch (_) {
      return null;
    }
  }

  PlayerController get _player => ref.read(playerProvider.notifier);

  static String _id(List<String> parts) =>
      parts.map(Uri.encodeComponent).join('/');

  static List<String> _parts(String id) =>
      id.split('/').map(Uri.decodeComponent).toList();

  // Browsing.

  @override
  Future<List<MediaNode>> children(String parentId) async {
    final source = await _source();
    if (source == null) {
      return parentId == MediaLibrary.rootId
          ? const [
              MediaNode(
                id: 'signin',
                title: 'Sign in on your phone',
                subtitle: 'Open OAmp on your phone to sign in to your server',
                playable: true,
              ),
            ]
          : const [];
    }
    final p = _parts(parentId);
    try {
      return switch (p) {
        [MediaLibrary.rootId] => _tabs,
        [MediaLibrary.recentId] => _recent(),
        ['home'] => await _home(source),
        ['playlists'] => await _playlists(source),
        ['playlist', final id] => await _playlist(source, id),
        ['artists'] => await _artists(source),
        ['artists', final letter] => await _artists(source, letter: letter),
        ['artist', final id] => await _artist(source, id),
        ['albums'] => await _albums(source),
        ['albums', final letter] => await _albums(source, letter: letter),
        ['album', final id] => await _album(source, id),
        _ => const [],
      };
    } catch (e) {
      debugPrint('Car library could not load $parentId: $e');
      rethrow;
    }
  }

  static const _tabs = [
    MediaNode(id: 'home', title: 'Home', folderStyle: NodeStyle.grid),
    MediaNode(id: 'playlists', title: 'Playlists'),
    MediaNode(id: 'artists', title: 'Artists', folderStyle: NodeStyle.list),
    MediaNode(id: 'albums', title: 'Albums', folderStyle: NodeStyle.list),
  ];

  /// What the car offers to carry on with when it starts: the loaded track.
  List<MediaNode> _recent() {
    final track = ref.read(playerProvider).current;
    if (track == null) return const [];
    return [
      MediaNode(
        id: 'resume',
        title: track.title,
        subtitle: track.artist,
        coverArt: track.coverArt,
        playable: true,
      ),
    ];
  }

  Future<List<MediaNode>> _home(MusicSource source) async {
    const rows = [
      (AlbumSort.recent, 'Recently played'),
      (AlbumSort.newest, 'Recently added'),
      (AlbumSort.frequent, 'Most played'),
      (AlbumSort.starred, 'Liked albums'),
    ];
    final albums = await Future.wait([
      for (final (sort, _) in rows)
        source
            .getAlbums(sort: sort, size: homeRow)
            .catchError((Object _) => const <Album>[]),
    ]);
    return [
      const MediaNode(
        id: 'shuffle/all',
        title: 'Shuffle all',
        subtitle: 'Your whole library',
        playable: true,
        group: 'Mixes',
      ),
      const MediaNode(
        id: 'shuffle/liked',
        title: 'Liked songs',
        subtitle: 'Shuffled',
        playable: true,
        group: 'Mixes',
      ),
      for (var i = 0; i < rows.length; i++)
        for (final a in albums[i]) _albumNode(a, group: rows[i].$2),
    ];
  }

  Future<List<MediaNode>> _playlists(MusicSource source) async => [
    for (final p in (await source.getPlaylists()).take(maxItems))
      MediaNode(
        id: _id(['playlist', p.id]),
        title: p.name,
        subtitle: p.songCount == 1 ? '1 song' : '${p.songCount} songs',
        coverArt: p.coverArt,
      ),
  ];

  Future<List<MediaNode>> _playlist(MusicSource source, String id) async {
    final detail = await source.getPlaylist(id);
    return [
      MediaNode(
        id: _id(['shuffle', 'playlist', id]),
        title: 'Shuffle',
        subtitle: detail.playlist.name,
        playable: true,
      ),
      for (final (i, t) in detail.tracks.take(maxItems).indexed)
        _trackNode(t, _id(['play', 'playlist', id, '$i'])),
    ];
  }

  Future<List<MediaNode>> _artists(MusicSource source, {String? letter}) async {
    final artists = await source.getArtists();
    String sortName(Artist a) => a.sortName ?? a.name;
    if (letter == null && artists.length > letterThreshold) {
      return _letters('artists', artists.map(sortName), NodeStyle.list);
    }
    return [
      for (final a
          in artists
              .where(
                (a) => letter == null || indexLetter(sortName(a)) == letter,
              )
              .take(maxItems))
        MediaNode(
          id: _id(['artist', a.id]),
          title: a.name,
          subtitle: a.albumCount == 0
              ? null
              : a.albumCount == 1
              ? '1 album'
              : '${a.albumCount} albums',
          coverArt: a.coverArt,
          folderStyle: NodeStyle.grid,
        ),
    ];
  }

  Future<List<MediaNode>> _artist(MusicSource source, String id) async {
    final detail = await source.getArtist(id);
    return [
      MediaNode(
        id: _id(['shuffle', 'artist', id]),
        title: 'Shuffle',
        subtitle: detail.artist.name,
        playable: true,
      ),
      for (final a in detail.albums.take(maxItems))
        _albumNode(a, subtitle: a.year?.toString()),
    ];
  }

  Future<List<MediaNode>> _albums(MusicSource source, {String? letter}) async {
    final albums = await _everyAlbum(source);
    String sortName(Album a) => a.sortName ?? a.name;
    if (letter == null && albums.length > letterThreshold) {
      return _letters('albums', albums.map(sortName), NodeStyle.grid);
    }
    return [
      for (final a
          in albums
              .where(
                (a) => letter == null || indexLetter(sortName(a)) == letter,
              )
              .take(maxItems))
        _albumNode(a),
    ];
  }

  /// Folders for each first letter that has at least one name.
  static List<MediaNode> _letters(
    String tab,
    Iterable<String> names,
    NodeStyle style,
  ) {
    final used = {for (final n in names) indexLetter(n)};
    return [
      for (final l in indexLetters)
        if (used.contains(l))
          MediaNode(id: _id([tab, l]), title: l, folderStyle: style),
    ];
  }

  ({DateTime at, Future<List<Album>> albums})? _allAlbums;

  /// Every album, A to Z, kept for a while so opening letter after letter
  /// asks the server once.
  Future<List<Album>> _everyAlbum(MusicSource source) {
    final cached = _allAlbums;
    if (cached != null && DateTime.now().difference(cached.at) < _albumsFresh) {
      return cached.albums;
    }
    final albums = _fetchAlbums(source);
    _allAlbums = (at: DateTime.now(), albums: albums);
    albums.catchError((Object _) {
      _allAlbums = null;
      return const <Album>[];
    });
    return albums;
  }

  static Future<List<Album>> _fetchAlbums(MusicSource source) async {
    final all = <Album>[];
    for (var page = 0; page < 40; page++) {
      final albums = await source.getAlbums(
        size: _albumsPage,
        offset: page * _albumsPage,
      );
      all.addAll(albums);
      if (albums.length < _albumsPage) break;
    }
    return all;
  }

  Future<List<MediaNode>> _album(MusicSource source, String id) async {
    final detail = await source.getAlbum(id);
    final artist = detail.album.artist;
    return [
      for (final (i, t) in detail.tracks.take(maxItems).indexed)
        _trackNode(
          t,
          _id(['play', 'album', id, '$i']),
          // Each track's artist only when it is not the album's.
          subtitle: t.artist != null && t.artist != artist ? t.artist : null,
          art: false,
        ),
    ];
  }

  static MediaNode _albumNode(Album a, {String? group, String? subtitle}) =>
      MediaNode(
        id: _id(['album', a.id]),
        title: a.name,
        subtitle: subtitle ?? a.artist,
        coverArt: a.coverArt,
        group: group,
      );

  static MediaNode _trackNode(
    Track t,
    String id, {
    String? subtitle,
    bool art = true,
    String? group,
  }) => MediaNode(
    id: id,
    title: t.title,
    subtitle: subtitle ?? t.artist,
    coverArt: art ? t.coverArt : null,
    playable: true,
    group: group,
  );

  // Search.

  @override
  Future<List<MediaNode>> search(String query) async {
    final source = await _source();
    if (source == null || query.trim().isEmpty) return const [];
    final r = await source.search(query.trim(), limit: 10);
    return [
      for (final t in r.tracks)
        _trackNode(t, _id(['play', 'track', t.id]), group: 'Songs'),
      for (final a in r.albums) _albumNode(a, group: 'Albums'),
      for (final a in r.artists)
        MediaNode(
          id: _id(['artist', a.id]),
          title: a.name,
          coverArt: a.coverArt,
          folderStyle: NodeStyle.grid,
          group: 'Artists',
        ),
    ];
  }

  // Playing.

  @override
  Future<void> play(String id) async {
    final source = await _source();
    if (source == null) return;
    try {
      switch (_parts(id)) {
        case ['resume']:
          await _player.play();
        case ['shuffle', 'all']:
          await _shuffleAll(source);
        case ['shuffle', 'liked']:
          final tracks = await source.getLikedTracks();
          await _player.playTracks(tracks, shuffle: true, from: 'Liked songs');
        case ['shuffle', 'artist', final artistId]:
          await _playArtist(source, artistId);
        case ['shuffle', 'playlist', final playlistId]:
          final d = await source.getPlaylist(playlistId);
          await _player.playTracks(
            d.tracks,
            shuffle: true,
            from: d.playlist.name,
          );
        case ['play', 'album', final albumId, final index]:
          final d = await source.getAlbum(albumId);
          await _player.playTracks(
            d.tracks,
            startIndex: _index(index, d.tracks.length),
            from: d.album.name,
          );
        case ['play', 'playlist', final playlistId, final index]:
          final d = await source.getPlaylist(playlistId);
          await _player.playTracks(
            d.tracks,
            startIndex: _index(index, d.tracks.length),
            from: d.playlist.name,
          );
        case ['play', 'track', final trackId]:
          await _playRadio(source, await source.getTrack(trackId));
      }
    } catch (e) {
      debugPrint('Car library could not play $id: $e');
    }
  }

  static int _index(String s, int length) =>
      (int.tryParse(s) ?? 0).clamp(0, length == 0 ? 0 : length - 1);

  Future<void> _shuffleAll(MusicSource source) async {
    final tracks = await source.getRandomTracks();
    await _player.playTracks(tracks, from: 'Library shuffle');
  }

  /// Every track by the artist, shuffled.
  Future<void> _playArtist(MusicSource source, String artistId) async {
    final detail = await source.getArtist(artistId);
    final albums = await Future.wait([
      for (final a in detail.albums) source.getAlbum(a.id),
    ]);
    await _player.playTracks(
      [for (final a in albums) ...a.tracks],
      shuffle: true,
      from: detail.artist.name,
    );
  }

  Future<void> _playAlbum(MusicSource source, String albumId) async {
    final d = await source.getAlbum(albumId);
    await _player.playTracks(d.tracks, from: d.album.name);
  }

  /// The track, then more like it, so a single song asked for in the car
  /// keeps going. Just the track when the server can't find anything.
  Future<void> _playRadio(MusicSource source, Track seed) async {
    var tracks = [seed];
    try {
      final mix = await RadioMixer(
        source,
        capabilities: ref.read(capabilitiesProvider),
      ).forTrack(seed);
      if (!mix.isEmpty) tracks = mix.tracks;
    } catch (e) {
      debugPrint('Radio for track ${seed.id} failed: $e');
    }
    await _player.playTracks(tracks, from: '${seed.title} radio');
  }

  @override
  Future<void> playFromVoice(VoiceRequest r) async {
    final source = await _source();
    if (source == null) return;
    try {
      await _playFromVoice(source, r);
    } catch (e) {
      debugPrint('Voice request failed: $e');
    }
  }

  Future<void> _playFromVoice(MusicSource source, VoiceRequest r) async {
    final query = r.query.trim();
    // "Play music on OAmp": carry on, or shuffle when nothing is loaded.
    if (query.isEmpty) {
      if (ref.read(playerProvider).queue.isNotEmpty) {
        await _player.play();
      } else {
        await _shuffleAll(source);
      }
      return;
    }

    if (r.focus == VoiceFocus.genre) {
      final genre = r.genre ?? query;
      final tracks = await source.getRandomTracks(genre: genre);
      if (tracks.isNotEmpty) {
        return _player.playTracks(tracks, from: genre);
      }
    }

    if (r.focus == VoiceFocus.playlist) {
      final p = _bestPlaylist(await source.getPlaylists(), r.playlist ?? query);
      if (p != null) return _playPlaylist(source, p.id);
    }

    final results = await source.search(switch (r.focus) {
      VoiceFocus.artist => r.artist ?? query,
      VoiceFocus.album => r.album ?? query,
      VoiceFocus.track => r.title ?? query,
      _ => query,
    }, limit: 10);
    final artist = results.artists.firstOrNull;
    final album = results.albums.firstOrNull;
    final track = results.tracks.firstOrNull;

    switch (r.focus) {
      case VoiceFocus.artist when artist != null:
        return _playArtist(source, artist.id);
      case VoiceFocus.album when album != null:
        return _playAlbum(source, album.id);
      case VoiceFocus.track when track != null:
        return _playRadio(source, track);
      default:
    }

    // No focus, or nothing of that kind: an exact name wins, then songs.
    bool same(String a) => a.toLowerCase() == query.toLowerCase();
    final exactArtist = results.artists.where((a) => same(a.name)).firstOrNull;
    if (exactArtist != null) return _playArtist(source, exactArtist.id);
    final exactAlbum = results.albums.where((a) => same(a.name)).firstOrNull;
    if (exactAlbum != null) return _playAlbum(source, exactAlbum.id);
    final playlist = _bestPlaylist(
      await source.getPlaylists(),
      query,
      exact: true,
    );
    if (playlist != null) return _playPlaylist(source, playlist.id);
    if (track != null) return _playRadio(source, track);
    if (album != null) return _playAlbum(source, album.id);
    if (artist != null) return _playArtist(source, artist.id);
  }

  static Playlist? _bestPlaylist(
    List<Playlist> playlists,
    String name, {
    bool exact = false,
  }) {
    final n = name.toLowerCase().replaceAll(RegExp(r'\s*playlist$'), '');
    return playlists.where((p) => p.name.toLowerCase() == n).firstOrNull ??
        (exact
            ? null
            : playlists
                  .where((p) => p.name.toLowerCase().contains(n))
                  .firstOrNull);
  }

  Future<void> _playPlaylist(MusicSource source, String id) async {
    final d = await source.getPlaylist(id);
    await _player.playTracks(d.tracks, from: d.playlist.name);
  }

  // Artwork.

  /// Cover art for the car at this size, from the artwork cache when it
  /// has it.
  static const artSize = 300;

  @override
  Future<Uint8List?> artwork(String coverArt) async {
    final session = ref.read(sessionProvider).value;
    final url = session?.source.coverArtUrl(coverArt, size: artSize);
    if (session == null || url == null) return null;
    try {
      final cache = ref.read(artworkCacheProvider);
      if (cache != null) {
        return await cache.load('${session.serverId}/$coverArt/$artSize', url);
      }
      return null;
    } catch (e) {
      debugPrint('Car artwork $coverArt failed: $e');
      return null;
    }
  }
}

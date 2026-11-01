import 'package:http/http.dart' as http;

import '../../core/models.dart';
import '../../core/music_source.dart';
import 'subsonic_client.dart';

/// [MusicSource] for Navidrome and other Subsonic/OpenSubsonic servers.
/// Uses the ID3 (tag based) endpoints.
class SubsonicSource implements MusicSource {
  final SubsonicClient client;

  SubsonicSource(SubsonicCredentials credentials, {http.Client? httpClient})
    : client = SubsonicClient(credentials, httpClient: httpClient);

  SubsonicCredentials get credentials => client.credentials;

  @override
  String get serverId => credentials.serverId;

  @override
  String get displayName =>
      '${credentials.username} @ ${credentials.baseUrl.host}';

  @override
  String get userName => credentials.username;

  // TODO(M1): read getOpenSubsonicExtensions at login and set the rest.
  // Every supported Navidrome has getSimilarSongs; it just returns nothing
  // when no outside agent (such as Last.fm) is configured.
  @override
  SourceCapabilities get capabilities =>
      const SourceCapabilities(hasSimilar: true);

  @override
  Future<void> ping() => client.get('ping');

  @override
  Future<List<Artist>> getArtists() async {
    final r = await client.get('getArtists');
    final index = (r['artists']?['index'] as List?) ?? const [];
    final articles =
        (r['artists']?['ignoredArticles'] as String?)?.split(' ') ??
        defaultIgnoredArticles;
    return [
      for (final group in index)
        for (final a in ((group as Map)['artist'] as List? ?? const []))
          _artist(a as Map<String, dynamic>, articles),
    ];
  }

  @override
  Future<ArtistDetail> getArtist(String id) async {
    final r = await client.get('getArtist', {'id': id});
    final a = r['artist'] as Map<String, dynamic>;
    return ArtistDetail(_artist(a), [
      for (final al in (a['album'] as List? ?? const []))
        _album(al as Map<String, dynamic>),
    ]);
  }

  @override
  Future<ArtistInfo> getArtistInfo(String id) async {
    final r = await client.get('getArtistInfo2', {'id': id});
    final info = (r['artistInfo2'] as Map<String, dynamic>?) ?? const {};
    return ArtistInfo(
      biography: plainBiography(info['biography'] as String?),
      similar: [
        for (final a in (info['similarArtist'] as List? ?? const []))
          // Without an id the artist is not in this library.
          if ((a as Map)['id'] != null) _artist(a as Map<String, dynamic>),
      ],
    );
  }

  /// Strips markup from a biography, and the "Read more on Last.fm" link
  /// servers copy from Last.fm. Returns null when nothing is left.
  static String? plainBiography(String? html) {
    if (html == null) return null;
    var s = html
        .replaceAll(RegExp(r'<a [^>]*>[^<]*</a>\.?', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();
    return s.isEmpty ? null : s;
  }

  @override
  Future<List<Track>> getTopTracks(Artist artist, {int count = 10}) async {
    final r = await client.get('getTopSongs', {
      'artist': artist.name,
      'count': '$count',
    });
    return [
      for (final t in (r['topSongs']?['song'] as List? ?? const []))
        _track(t as Map<String, dynamic>),
    ];
  }

  @override
  Future<List<Track>> getSimilarTracks(String id, {int count = 50}) async {
    final r = await client.get('getSimilarSongs', {
      'id': id,
      'count': '$count',
    });
    return [
      for (final t in (r['similarSongs']?['song'] as List? ?? const []))
        _track(t as Map<String, dynamic>),
    ];
  }

  static const _sortTypes = {
    AlbumSort.alphabetical: 'alphabeticalByName',
    AlbumSort.newest: 'newest',
    AlbumSort.recent: 'recent',
    AlbumSort.frequent: 'frequent',
    AlbumSort.random: 'random',
    AlbumSort.starred: 'starred',
  };

  @override
  Future<List<Album>> getAlbums({
    AlbumSort sort = AlbumSort.alphabetical,
    int size = 100,
    int offset = 0,
  }) async {
    final r = await client.get('getAlbumList2', {
      'type': _sortTypes[sort]!,
      'size': '$size',
      'offset': '$offset',
    });
    return [
      for (final al in (r['albumList2']?['album'] as List? ?? const []))
        _album(al as Map<String, dynamic>),
    ];
  }

  @override
  Future<AlbumDetail> getAlbum(String id) async {
    final r = await client.get('getAlbum', {'id': id});
    final a = r['album'] as Map<String, dynamic>;
    return AlbumDetail(_album(a), [
      for (final t in (a['song'] as List? ?? const []))
        _track(t as Map<String, dynamic>),
    ]);
  }

  @override
  Future<SearchResults> search(String query, {int limit = 20}) async {
    final r = await client.get('search3', {
      'query': query,
      'artistCount': '$limit',
      'albumCount': '$limit',
      'songCount': '$limit',
    });
    final res = (r['searchResult3'] as Map<String, dynamic>?) ?? const {};
    return SearchResults(
      artists: [
        for (final a in (res['artist'] as List? ?? const []))
          _artist(a as Map<String, dynamic>),
      ],
      albums: [
        for (final a in (res['album'] as List? ?? const []))
          _album(a as Map<String, dynamic>),
      ],
      tracks: [
        for (final t in (res['song'] as List? ?? const []))
          _track(t as Map<String, dynamic>),
      ],
    );
  }

  @override
  Future<List<Playlist>> getPlaylists() async {
    final r = await client.get('getPlaylists');
    return [
      for (final p in (r['playlists']?['playlist'] as List? ?? const []))
        _playlist(p as Map<String, dynamic>),
    ];
  }

  @override
  Future<PlaylistDetail> getPlaylist(String id) async {
    final r = await client.get('getPlaylist', {'id': id});
    final p = r['playlist'] as Map<String, dynamic>;
    return PlaylistDetail(_playlist(p), [
      for (final t in (p['entry'] as List? ?? const []))
        _track(t as Map<String, dynamic>),
    ]);
  }

  /// Id lists longer than this go in a form body rather than the URL.
  static const _maxIdsInUrl = 40;

  Future<Map<String, dynamic>> _write(
    String endpoint,
    Map<String, Object> params,
    int idCount,
  ) => idCount > _maxIdsInUrl
      ? client.post(endpoint, params)
      : client.get(endpoint, params);

  @override
  Future<Playlist> createPlaylist(
    String name, {
    List<String> trackIds = const [],
  }) async {
    final r = await _write('createPlaylist', {
      'name': name,
      'songId': trackIds,
    }, trackIds.length);
    final p = r['playlist'] as Map<String, dynamic>?;
    if (p != null) return _playlist(p);
    // Servers before API 1.14 do not return the new playlist.
    final all = await getPlaylists();
    return all.lastWhere(
      (p) => p.name == name,
      orElse: () => throw MusicSourceException('Playlist was not created'),
    );
  }

  @override
  Future<void> renamePlaylist(String id, String name) =>
      client.get('updatePlaylist', {'playlistId': id, 'name': name});

  @override
  Future<void> addToPlaylist(String id, List<String> trackIds) async {
    if (trackIds.isEmpty) return;
    await _write('updatePlaylist', {
      'playlistId': id,
      'songIdToAdd': trackIds,
    }, trackIds.length);
  }

  @override
  Future<void> removeFromPlaylist(String id, List<int> indexes) async {
    if (indexes.isEmpty) return;
    await _write('updatePlaylist', {
      'playlistId': id,
      'songIndexToRemove': [for (final i in indexes) '$i'],
    }, indexes.length);
  }

  @override
  Future<void> replacePlaylistTracks(String id, List<String> trackIds) =>
      // createPlaylist with an existing id replaces its tracks.
      _write('createPlaylist', {
        'playlistId': id,
        'songId': trackIds,
      }, trackIds.length);

  @override
  Future<void> deletePlaylist(String id) =>
      client.get('deletePlaylist', {'id': id});

  @override
  Future<List<Track>> getRandomTracks({int size = 100}) async {
    final r = await client.get('getRandomSongs', {'size': '$size'});
    return [
      for (final t in (r['randomSongs']?['song'] as List? ?? const []))
        _track(t as Map<String, dynamic>),
    ];
  }

  @override
  Future<List<Track>> getLikedTracks() async {
    final r = await client.get('getStarred2');
    return [
      for (final t in (r['starred2']?['song'] as List? ?? const []))
        _track(t as Map<String, dynamic>),
    ];
  }

  @override
  Future<void> setLiked(
    String id,
    bool liked, {
    LikeTarget target = LikeTarget.track,
  }) => client.get(liked ? 'star' : 'unstar', {
    switch (target) {
      LikeTarget.track => 'id',
      LikeTarget.album => 'albumId',
      LikeTarget.artist => 'artistId',
    }: id,
  });

  @override
  Future<void> reportPlayback(String trackId, {required bool submission}) =>
      client.get('scrobble', {'id': trackId, 'submission': '$submission'});

  /// Auth rides in the query string, which is how Subsonic clients stream.
  @override
  Uri streamUrl(String trackId) =>
      client.endpointUri('stream', {'id': trackId});

  @override
  Uri? coverArtUrl(String? coverArtId, {int size = 300}) => coverArtId == null
      ? null
      : client.endpointUri('getCoverArt', {'id': coverArtId, 'size': '$size'});

  @override
  void close() => client.close();

  // Parsing is lenient because servers differ in which optional fields they
  // send, and some send numbers as strings.
  static int? _int(Object? v) =>
      v is int ? v : (v is String ? int.tryParse(v) : null);

  /// Navidrome's default list of words to sort names without.
  static const defaultIgnoredArticles = [
    'The', 'El', 'La', 'Los', 'Las', 'Le', 'Les', 'Os', 'As', 'O', 'A', //
  ];

  /// The name without a leading article, as the server sorts it.
  static String sortNameOf(
    String name, [
    List<String> articles = defaultIgnoredArticles,
  ]) {
    final lower = name.toLowerCase();
    for (final a in articles) {
      if (a.isEmpty) continue;
      if (lower.startsWith('${a.toLowerCase()} ')) {
        return name.substring(a.length + 1).trimLeft();
      }
    }
    return name;
  }

  static String? _sortName(
    Map<String, dynamic> j,
    String name, [
    List<String> articles = defaultIgnoredArticles,
  ]) {
    final given = j['sortName'] as String?;
    return given != null && given.trim().isNotEmpty
        ? given
        : sortNameOf(name, articles);
  }

  static Artist _artist(
    Map<String, dynamic> j, [
    List<String> articles = defaultIgnoredArticles,
  ]) => Artist(
    id: '${j['id']}',
    name: (j['name'] ?? 'Unknown artist') as String,
    sortName: _sortName(j, (j['name'] ?? '') as String, articles),
    albumCount: _int(j['albumCount']) ?? 0,
    coverArt: j['coverArt'] as String?,
    liked: j['starred'] != null,
  );

  static Album _album(Map<String, dynamic> j) {
    final secs = _int(j['duration']);
    final genre = j['genre'] as String?;
    final name = (j['name'] ?? j['title'] ?? 'Unknown album') as String;
    return Album(
      id: '${j['id']}',
      name: name,
      artist: j['artist'] as String?,
      artistId: j['artistId']?.toString(),
      year: _int(j['year']),
      songCount: _int(j['songCount']) ?? 0,
      coverArt: j['coverArt'] as String?,
      genre: genre == null || genre.isEmpty ? null : genre,
      duration: secs == null ? null : Duration(seconds: secs),
      liked: j['starred'] != null,
      // OpenSubsonic fields.
      releaseTypes: [
        for (final t in (j['releaseTypes'] as List? ?? const []))
          '$t'.toLowerCase(),
      ],
      isCompilation: j['isCompilation'] == true,
      sortName: _sortName(j, name),
    );
  }

  static Track _track(Map<String, dynamic> j) {
    final secs = _int(j['duration']);
    return Track(
      id: '${j['id']}',
      title: (j['title'] ?? 'Unknown track') as String,
      artist: j['artist'] as String?,
      artistId: j['artistId']?.toString(),
      album: j['album'] as String?,
      albumId: j['albumId']?.toString(),
      track: _int(j['track']),
      discNumber: _int(j['discNumber']),
      duration: secs == null ? null : Duration(seconds: secs),
      coverArt: j['coverArt'] as String?,
      liked: j['starred'] != null,
      year: _int(j['year']),
      format: j['suffix'] as String?,
      bitRate: _int(j['bitRate']),
      // OpenSubsonic fields; plain Subsonic servers leave them out.
      sampleRate: _int(j['samplingRate']),
      bitDepth: _int(j['bitDepth']),
    );
  }

  static Playlist _playlist(Map<String, dynamic> j) {
    final secs = _int(j['duration']);
    return Playlist(
      id: '${j['id']}',
      name: (j['name'] ?? 'Untitled playlist') as String,
      songCount: _int(j['songCount']) ?? 0,
      duration: secs == null ? null : Duration(seconds: secs),
      owner: j['owner'] as String?,
      coverArt: j['coverArt'] as String?,
      comment: (j['comment'] as String?)?.trim().isEmpty ?? true
          ? null
          : (j['comment'] as String).trim(),
      public: j['public'] == true,
      readonly: j['readonly'] == true,
    );
  }
}

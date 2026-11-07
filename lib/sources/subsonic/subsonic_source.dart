import 'dart:async';

import 'package:http/http.dart' as http;

import '../../core/lyrics.dart';
import '../../core/models.dart';
import '../../core/music_source.dart';
import '../../core/play_queue.dart';
import '../../core/playback_options.dart';
import '../../core/server_route.dart';
import 'subsonic_client.dart';

/// [MusicSource] for Navidrome and other Subsonic/OpenSubsonic servers.
/// Uses the ID3 (tag based) endpoints.
class SubsonicSource implements MusicSource {
  final SubsonicClient client;

  SubsonicSource(SubsonicCredentials credentials, {http.Client? httpClient})
    : client = SubsonicClient(credentials, httpClient: httpClient);

  SubsonicCredentials get credentials => client.credentials;

  /// Sets or clears the away address, keeping this source (and so the
  /// library, queue and caches) as it is.
  void setAwayUrl(Uri? url, {bool connected = false}) =>
      client.setAwayUrl(url, connected: connected);

  @override
  ServerRoute get route => client.picker.route;

  @override
  Stream<ServerRoute> get routeChanges => client.picker.changes;

  @override
  Future<void> connect() => client.connect();

  @override
  void reportUnreachable() {
    if (client.picker.away == null) return;
    unawaited(client.picker.recover(client.probe, client.baseUrl));
  }

  @override
  String get serverId => credentials.serverId;

  @override
  String get displayName =>
      '${credentials.username} @ ${credentials.baseUrl.host}';

  @override
  String get userName => credentials.username;

  /// What every supported Navidrome can do before extensions are read.
  /// getSimilarSongs always exists; it just returns nothing when no outside
  /// agent (such as Last.fm) is configured, which radio handles with genres.
  /// Navidrome also keeps a play queue per user.
  static const baseline = SourceCapabilities(
    hasSimilar: true,
    hasGenres: true,
    hasQueueSync: true,
  );

  SourceCapabilities _capabilities = baseline;
  bool _detected = false;

  @override
  SourceCapabilities get capabilities => _capabilities;

  /// Reads the server type and version from `ping` and the OpenSubsonic
  /// extensions from `getOpenSubsonicExtensions`. A plain Subsonic server
  /// has no such endpoint and keeps the baseline.
  @override
  Future<SourceCapabilities> detectCapabilities() async {
    Map<String, dynamic> pong = const {};
    var openSubsonic = false;
    try {
      pong = await client.get('ping');
      openSubsonic = pong['openSubsonic'] == true;
    } on MusicSourceException {
      // Offline or signed out: keep what we had rather than forget it.
      return _capabilities;
    }
    var extensions = const <String, List<int>>{};
    if (openSubsonic) {
      try {
        final r = await client.get('getOpenSubsonicExtensions');
        extensions = parseExtensions(r['openSubsonicExtensions']);
      } on MusicSourceException {
        // Advertised but not answered; carry on without extensions.
      }
    }
    _detected = true;
    return _capabilities = capabilitiesFor(
      extensions,
      serverType: pong['type'] as String?,
      serverVersion: pong['serverVersion'] as String?,
    );
  }

  /// `[{name: songLyrics, versions: [1]}, ...]` as a map. Lenient about
  /// missing or odd fields, since servers differ.
  static Map<String, List<int>> parseExtensions(Object? raw) => {
    if (raw is List)
      for (final e in raw)
        if (e is Map && e['name'] is String)
          e['name'] as String: [
            for (final v in (e['versions'] as List? ?? const [])) ?_int(v),
          ],
  };

  /// The flags features check, from the server's extensions.
  static SourceCapabilities capabilitiesFor(
    Map<String, List<int>> extensions, {
    String? serverType,
    String? serverVersion,
  }) => SourceCapabilities(
    hasSimilar: baseline.hasSimilar,
    hasGenres: baseline.hasGenres,
    hasQueueSync: baseline.hasQueueSync,
    hasLyrics: extensions.containsKey('songLyrics'),
    hasPlaybackState: extensions.containsKey('playbackReport'),
    extensions: extensions,
    serverType: serverType,
    serverVersion: serverVersion,
  );

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
  Future<Track> getTrack(String id) async {
    final r = await client.get('getSong', {'id': id});
    return _track(r['song'] as Map<String, dynamic>);
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

  /// Every supported Navidrome has `formPost`, so it is assumed until the
  /// server has been asked and said otherwise.
  bool get _formPost => !_detected || _capabilities.supports('formPost');

  /// Id lists longer than this go in a form body rather than the URL, when
  /// the server has the `formPost` extension.
  static const _maxIdsInUrl = 40;

  Future<Map<String, dynamic>> _write(
    String endpoint,
    Map<String, Object> params,
    int idCount,
  ) => idCount > _maxIdsInUrl && _formPost
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
  Future<List<Track>> getRandomTracks({int size = 100, String? genre}) async {
    final r = await client.get('getRandomSongs', {
      'size': '$size',
      'genre': ?genre,
    });
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
  Future<List<Artist>> getLikedArtists() async {
    final r = await client.get('getStarred2');
    final list = [
      for (final a in (r['starred2']?['artist'] as List? ?? const []))
        _artist(a as Map<String, dynamic>),
    ];
    return list..sort(
      (a, b) => (a.sortName ?? a.name).toLowerCase().compareTo(
        (b.sortName ?? b.name).toLowerCase(),
      ),
    );
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
  Future<void> setRating(String id, int rating) =>
      client.get('setRating', {'id': id, 'rating': '${rating.clamp(0, 5)}'});

  /// Tries OpenSubsonic's `getLyricsBySongId` (which can return synced
  /// lyrics) first, and falls back to the classic artist and title lookup
  /// when the server does not have that endpoint or has nothing there.
  ///
  /// Once the server's extensions are known, the OpenSubsonic call is only
  /// made when it lists `songLyrics`.
  @override
  Future<Lyrics> getLyrics(Track track) async {
    if (!_detected || _capabilities.hasLyrics) {
      try {
        final r = await client.get('getLyricsBySongId', {'id': track.id});
        final found = structuredLyrics(r['lyricsList']);
        if (!found.isEmpty) return found;
      } on MusicSourceException {
        // Not an OpenSubsonic server, or no lyrics for this id.
      }
    }
    final artist = track.artist;
    if (artist == null || artist.isEmpty) return Lyrics.none;
    final r = await client.get('getLyrics', {
      'artist': artist,
      'title': track.title,
    });
    final value = (r['lyrics'] as Map?)?['value'];
    return value is String ? Lyrics.parse(value) : Lyrics.none;
  }

  /// Picks from OpenSubsonic's `lyricsList`: synced lyrics over plain, and
  /// within those the first the server lists.
  static Lyrics structuredLyrics(Object? lyricsList) {
    final all = lyricsList is Map ? lyricsList['structuredLyrics'] : null;
    if (all is! List) return Lyrics.none;
    Lyrics? plain;
    for (final entry in all.whereType<Map>()) {
      final lines = (entry['line'] as List? ?? const []).whereType<Map>();
      if (lines.isEmpty) continue;
      if (entry['synced'] == true) {
        // A positive offset means the lyrics should show earlier.
        final offset = _int(entry['offset']) ?? 0;
        final synced = [
          for (final l in lines)
            LyricLine(
              '${l['value'] ?? ''}',
              start: Duration(
                milliseconds: ((_int(l['start']) ?? 0) - offset).clamp(
                  0,
                  1 << 31,
                ),
              ),
            ),
        ]..sort((a, b) => a.start!.compareTo(b.start!));
        final lyrics = Lyrics(synced, synced: true);
        if (!lyrics.isEmpty) return lyrics;
      } else {
        plain ??= Lyrics([
          for (final l in lines) LyricLine('${l['value'] ?? ''}'),
        ]);
      }
    }
    return plain != null && !plain.isEmpty ? plain : Lyrics.none;
  }

  @override
  Future<void> reportPlayback(String trackId, {required bool submission}) =>
      client.get('scrobble', {'id': trackId, 'submission': '$submission'});

  @override
  Future<void> reportPlaybackState(
    String trackId,
    PlaybackPhase phase,
    Duration position,
  ) => client.get('reportPlayback', {
    'mediaId': trackId,
    'mediaType': 'song',
    'positionMs': '${position.inMilliseconds}',
    'state': phase.name,
    // Plays are counted by scrobble, so the server must not count them again.
    'ignoreScrobble': 'true',
  });

  @override
  Future<SavedQueue?> getPlayQueue() async {
    final Map<String, dynamic> r;
    try {
      r = await client.get('getPlayQueue');
    } on MusicSourceException catch (e) {
      // Some servers answer "not found" (70) when nothing has been saved.
      if (e.code == 70) return null;
      rethrow;
    }
    return parsePlayQueue(r['playQueue']);
  }

  /// The `playQueue` element of a getPlayQueue reply, or null when it holds
  /// nothing. The server names the current entry by track id, so a track
  /// listed twice resumes at its first entry.
  static SavedQueue? parsePlayQueue(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final tracks = [
      for (final t in (j['entry'] as List? ?? const []))
        _track(t as Map<String, dynamic>),
    ];
    if (tracks.isEmpty) return null;
    final current = j['current']?.toString();
    final index = current == null
        ? null
        : tracks.indexWhere((t) => t.id == current);
    return SavedQueue(
      tracks: tracks,
      currentIndex: index == null || index < 0 ? 0 : index,
      position: Duration(milliseconds: _int(j['position']) ?? 0),
      changed: DateTime.tryParse('${j['changed']}'),
      changedBy: j['changedBy'] as String?,
    );
  }

  @override
  Future<void> savePlayQueue(
    List<String> trackIds, {
    int? currentIndex,
    Duration position = Duration.zero,
  }) => _write('savePlayQueue', {
    'id': trackIds,
    if (currentIndex != null &&
        currentIndex >= 0 &&
        currentIndex < trackIds.length) ...{
      'current': trackIds[currentIndex],
      'position': '${position.inMilliseconds}',
    },
  }, trackIds.length);

  /// Auth rides in the query string, which is how Subsonic clients stream.
  @override
  Uri streamUrl(
    String trackId, {
    StreamQuality quality = StreamQuality.original,
    Duration offset = Duration.zero,
  }) => client.endpointUri('stream', {
    'id': trackId,
    if (!quality.isOriginal && offset.inSeconds > 0)
      'timeOffset': '${offset.inSeconds}',
    // `raw` asks for the stored file even when the server has a default
    // transcoding set up for this client.
    if (quality.isOriginal)
      'format': 'raw'
    else ...{
      'format': quality.format.name,
      'maxBitRate': '${quality.bitRate}',
    },
  });

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
    rating: _int(j['userRating']) ?? 0,
  );

  /// OpenSubsonic's `genres` list, else the single `genre` field.
  static List<String> _genres(Map<String, dynamic> j) {
    final names = [
      for (final g in (j['genres'] as List? ?? const []))
        if (g is Map && '${g['name'] ?? ''}'.trim().isNotEmpty)
          '${g['name']}'.trim(),
    ];
    if (names.isNotEmpty) return names;
    final one = (j['genre'] as String?)?.trim();
    return one == null || one.isEmpty ? const [] : [one];
  }

  static Album _album(Map<String, dynamic> j) {
    final secs = _int(j['duration']);
    final genres = _genres(j);
    final genre = genres.isEmpty ? null : genres.first;
    final name = (j['name'] ?? j['title'] ?? 'Unknown album') as String;
    return Album(
      id: '${j['id']}',
      name: name,
      artist: j['artist'] as String?,
      artistId: j['artistId']?.toString(),
      year: _int(j['year']),
      songCount: _int(j['songCount']) ?? 0,
      coverArt: j['coverArt'] as String?,
      genre: genre,
      duration: secs == null ? null : Duration(seconds: secs),
      liked: j['starred'] != null,
      rating: _int(j['userRating']) ?? 0,
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
      rating: _int(j['userRating']) ?? 0,
      year: _int(j['year']),
      format: j['suffix'] as String?,
      bitRate: _int(j['bitRate']),
      // OpenSubsonic fields; plain Subsonic servers leave them out.
      sampleRate: _int(j['samplingRate']),
      bitDepth: _int(j['bitDepth']),
      replayGain: _replayGain(j['replayGain']),
      genres: _genres(j),
    );
  }

  /// OpenSubsonic's `replayGain` object. Navidrome fills it from the
  /// file's tags.
  static ReplayGain? _replayGain(Object? raw) {
    if (raw is! Map) return null;
    double? d(Object? v) => v is num ? v.toDouble() : double.tryParse('$v');
    final rg = ReplayGain(
      trackGain: d(raw['trackGain']),
      albumGain: d(raw['albumGain']),
      trackPeak: d(raw['trackPeak']),
      albumPeak: d(raw['albumPeak']),
    );
    return rg.isEmpty ? null : rg;
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

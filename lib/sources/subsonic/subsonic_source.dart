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

  // TODO(M1): read getOpenSubsonicExtensions at login and set these.
  @override
  SourceCapabilities get capabilities => const SourceCapabilities();

  @override
  Future<void> ping() => client.get('ping');

  @override
  Future<List<Artist>> getArtists() async {
    final r = await client.get('getArtists');
    final index = (r['artists']?['index'] as List?) ?? const [];
    return [
      for (final group in index)
        for (final a in ((group as Map)['artist'] as List? ?? const []))
          _artist(a as Map<String, dynamic>),
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

  static Artist _artist(Map<String, dynamic> j) => Artist(
    id: '${j['id']}',
    name: (j['name'] ?? 'Unknown artist') as String,
    albumCount: _int(j['albumCount']) ?? 0,
    coverArt: j['coverArt'] as String?,
  );

  static Album _album(Map<String, dynamic> j) => Album(
    id: '${j['id']}',
    name: (j['name'] ?? j['title'] ?? 'Unknown album') as String,
    artist: j['artist'] as String?,
    artistId: j['artistId']?.toString(),
    year: _int(j['year']),
    songCount: _int(j['songCount']) ?? 0,
    coverArt: j['coverArt'] as String?,
  );

  static Track _track(Map<String, dynamic> j) {
    final secs = _int(j['duration']);
    return Track(
      id: '${j['id']}',
      title: (j['title'] ?? 'Unknown track') as String,
      artist: j['artist'] as String?,
      album: j['album'] as String?,
      albumId: j['albumId']?.toString(),
      track: _int(j['track']),
      discNumber: _int(j['discNumber']),
      duration: secs == null ? null : Duration(seconds: secs),
      coverArt: j['coverArt'] as String?,
    );
  }
}

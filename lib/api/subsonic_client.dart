import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// Error returned by the server (`status: failed`) or by the transport.
class SubsonicException implements Exception {
  final String message;
  final int? code;
  SubsonicException(this.message, {this.code});

  @override
  String toString() => code == null ? message : '$message (code $code)';
}

/// Credentials in the form the Subsonic API wants them.
///
/// Token auth (API 1.13.0+) sends `t = md5(password + salt)` and `s = salt`
/// instead of the password. We keep only the token and salt, so the plain
/// password never needs to be stored on disk.
class SubsonicCredentials {
  final Uri baseUrl;
  final String username;
  final String token;
  final String salt;

  const SubsonicCredentials({
    required this.baseUrl,
    required this.username,
    required this.token,
    required this.salt,
  });

  factory SubsonicCredentials.fromPassword({
    required Uri baseUrl,
    required String username,
    required String password,
  }) {
    final salt = _randomSalt();
    final token = md5.convert(utf8.encode(password + salt)).toString();
    return SubsonicCredentials(
      baseUrl: baseUrl,
      username: username,
      token: token,
      salt: salt,
    );
  }

  static String _randomSalt([int length = 12]) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl.toString(),
    'username': username,
    'token': token,
    'salt': salt,
  };

  factory SubsonicCredentials.fromJson(Map<String, dynamic> j) =>
      SubsonicCredentials(
        baseUrl: Uri.parse(j['baseUrl'] as String),
        username: j['username'] as String,
        token: j['token'] as String,
        salt: j['salt'] as String,
      );
}

/// Minimal client for the Subsonic / OpenSubsonic REST API as served by
/// Navidrome. Uses the ID3 (tag based) endpoints: getArtists, getArtist,
/// getAlbum, getAlbumList2.
class SubsonicClient {
  static const apiVersion = '1.16.1';
  static const clientName = 'OAmp';

  final SubsonicCredentials credentials;
  final http.Client _http;

  SubsonicClient(this.credentials, {http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  /// Normalises what the user typed into a base URL: adds `https://` when no
  /// scheme is given and strips a trailing slash.
  static Uri normaliseServerUrl(String input) {
    var s = input.trim();
    if (!s.contains('://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return Uri.parse(s);
  }

  Map<String, String> get _authParams => {
    'u': credentials.username,
    't': credentials.token,
    's': credentials.salt,
    'v': apiVersion,
    'c': clientName,
    'f': 'json',
  };

  /// Builds `<base>/rest/<endpoint>` with auth and extra query parameters.
  Uri endpointUri(String endpoint, [Map<String, String> params = const {}]) {
    final base = credentials.baseUrl;
    final path = '${base.path}/rest/$endpoint';
    return base.replace(
      path: path,
      queryParameters: {..._authParams, ...params},
    );
  }

  Future<Map<String, dynamic>> _get(
    String endpoint, [
    Map<String, String> params = const {},
  ]) async {
    final http.Response res;
    try {
      res = await _http
          .get(endpointUri(endpoint, params))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw SubsonicException('Could not reach the server: $e');
    }
    if (res.statusCode != 200) {
      throw SubsonicException('Server returned HTTP ${res.statusCode}');
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw SubsonicException(
        'The server did not return Subsonic JSON. Check the URL.',
      );
    }
    final resp = body['subsonic-response'] as Map<String, dynamic>?;
    if (resp == null) {
      throw SubsonicException('Missing subsonic-response in reply.');
    }
    if (resp['status'] != 'ok') {
      final err = resp['error'] as Map<String, dynamic>?;
      throw SubsonicException(
        (err?['message'] as String?) ?? 'Request failed',
        code: err?['code'] as int?,
      );
    }
    return resp;
  }

  /// Checks the server is reachable and the credentials are valid.
  Future<void> ping() => _get('ping');

  Future<List<Artist>> getArtists() async {
    final r = await _get('getArtists');
    final index = (r['artists']?['index'] as List?) ?? const [];
    return [
      for (final group in index)
        for (final a in ((group as Map)['artist'] as List? ?? const []))
          Artist.fromJson(a as Map<String, dynamic>),
    ];
  }

  Future<ArtistDetail> getArtist(String id) async {
    final r = await _get('getArtist', {'id': id});
    final a = r['artist'] as Map<String, dynamic>;
    final albums = [
      for (final al in (a['album'] as List? ?? const []))
        Album.fromJson(al as Map<String, dynamic>),
    ];
    return ArtistDetail(Artist.fromJson(a), albums);
  }

  /// [type] is one of the getAlbumList2 types such as `alphabeticalByName`,
  /// `newest`, `recent`, `frequent`, `random`.
  Future<List<Album>> getAlbumList({
    String type = 'alphabeticalByName',
    int size = 100,
    int offset = 0,
  }) async {
    final r = await _get('getAlbumList2', {
      'type': type,
      'size': '$size',
      'offset': '$offset',
    });
    return [
      for (final al in (r['albumList2']?['album'] as List? ?? const []))
        Album.fromJson(al as Map<String, dynamic>),
    ];
  }

  Future<AlbumDetail> getAlbum(String id) async {
    final r = await _get('getAlbum', {'id': id});
    final a = r['album'] as Map<String, dynamic>;
    final tracks = [
      for (final t in (a['song'] as List? ?? const []))
        Track.fromJson(t as Map<String, dynamic>),
    ];
    return AlbumDetail(Album.fromJson(a), tracks);
  }

  /// URL the audio player streams from. Auth is in the query string, which is
  /// how Subsonic clients normally stream.
  Uri streamUrl(String trackId) => endpointUri('stream', {'id': trackId});

  Uri? coverArtUrl(String? coverArtId, {int size = 300}) => coverArtId == null
      ? null
      : endpointUri('getCoverArt', {'id': coverArtId, 'size': '$size'});

  void close() => _http.close();
}

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../core/music_source.dart';

/// Credentials in the form the Subsonic API wants them.
///
/// Token auth (API 1.13.0+) sends `t = md5(password + salt)` and `s = salt`
/// instead of the password. Only the token and salt are kept, so the plain
/// password never needs to be stored.
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

  /// Stable id for this server account: the same URL and username always
  /// give the same id, whatever salt was used.
  String get serverId =>
      'subsonic:${sha1.convert(utf8.encode('$username@$baseUrl')).toString().substring(0, 16)}';

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

/// Transport for the Subsonic / OpenSubsonic REST API: builds signed URLs,
/// makes requests and unwraps `subsonic-response`. Mapping to OAmp's models
/// lives in [SubsonicSource].
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
    return base.replace(
      path: '${base.path}/rest/$endpoint',
      queryParameters: {..._authParams, ...params},
    );
  }

  Future<Map<String, dynamic>> get(
    String endpoint, [
    Map<String, String> params = const {},
  ]) async {
    final http.Response res;
    try {
      res = await _http
          .get(endpointUri(endpoint, params))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw MusicSourceException('Could not reach the server: $e');
    }
    if (res.statusCode != 200) {
      throw MusicSourceException('Server returned HTTP ${res.statusCode}');
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw MusicSourceException(
        'The server did not return Subsonic JSON. Check the URL.',
      );
    }
    final resp = body['subsonic-response'] as Map<String, dynamic>?;
    if (resp == null) {
      throw MusicSourceException('Missing subsonic-response in reply.');
    }
    if (resp['status'] != 'ok') {
      final err = resp['error'] as Map<String, dynamic>?;
      throw MusicSourceException(
        (err?['message'] as String?) ?? 'Request failed',
        code: err?['code'] as int?,
      );
    }
    return resp;
  }

  void close() => _http.close();
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;

import '../../core/music_source.dart';

/// Credentials in the form the Subsonic API wants them.
///
/// Token auth (API 1.13.0+) sends `t = md5(password + salt)` and `s = salt`
/// instead of the password. Only the token and salt are kept, so the plain
/// password never needs to be stored.
///
/// Servers with the OpenSubsonic `apiKeyAuthentication` extension also take
/// an API key ([apiKey]) in place of all three, which is the only way in for
/// accounts that cannot use token auth, such as LDAP ones.
class SubsonicCredentials {
  final Uri baseUrl;
  final String username;
  final String token;
  final String salt;
  final String? apiKey;

  const SubsonicCredentials({
    required this.baseUrl,
    required this.username,
    required this.token,
    required this.salt,
    this.apiKey,
  });

  /// Signs in with an API key. [username] is optional and only for display;
  /// the server knows the account from the key.
  factory SubsonicCredentials.fromApiKey({
    required Uri baseUrl,
    required String apiKey,
    String username = '',
  }) => SubsonicCredentials(
    baseUrl: baseUrl,
    username: username,
    token: '',
    salt: '',
    apiKey: apiKey,
  );

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
  ///
  /// With an API key and no username, the id comes from a hash of the key,
  /// so it is stable without revealing the key.
  String get serverId {
    final who = apiKey != null && username.isEmpty
        ? 'key:${sha1.convert(utf8.encode(apiKey!))}'
        : username;
    return 'subsonic:${sha1.convert(utf8.encode('$who@$baseUrl')).toString().substring(0, 16)}';
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
    'apiKey': ?apiKey,
  };

  factory SubsonicCredentials.fromJson(Map<String, dynamic> j) =>
      SubsonicCredentials(
        baseUrl: Uri.parse(j['baseUrl'] as String),
        username: j['username'] as String,
        token: (j['token'] as String?) ?? '',
        salt: (j['salt'] as String?) ?? '',
        apiKey: j['apiKey'] as String?,
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
    if (credentials.apiKey case final key?)
      'apiKey': key
    else ...{
      'u': credentials.username,
      't': credentials.token,
      's': credentials.salt,
    },
    'v': apiVersion,
    'c': clientName,
    'f': 'json',
  };

  /// Builds `<base>/rest/<endpoint>` with auth and extra query parameters.
  /// A parameter's value is a `String`, or a `List<String>` to repeat it
  /// (such as several `songId`s).
  Uri endpointUri(String endpoint, [Map<String, Object> params = const {}]) {
    final base = credentials.baseUrl;
    return base.replace(
      path: '${base.path}/rest/$endpoint',
      queryParameters: {..._authParams, ...params},
    );
  }

  Future<Map<String, dynamic>> get(
    String endpoint, [
    Map<String, Object> params = const {},
  ]) => _send(endpoint, params, post: false);

  /// Sends the parameters as a form body instead of in the URL (the
  /// OpenSubsonic `formPost` extension), for long id lists that would make
  /// the URL too long.
  Future<Map<String, dynamic>> post(
    String endpoint, [
    Map<String, Object> params = const {},
  ]) => _send(endpoint, params, post: true);

  Future<Map<String, dynamic>> _send(
    String endpoint,
    Map<String, Object> params, {
    required bool post,
  }) async {
    final http.Response res;
    try {
      final Future<http.Response> request;
      if (post) {
        final base = credentials.baseUrl;
        final body = Uri(queryParameters: {..._authParams, ...params}).query;
        request = _http.post(
          Uri(
            scheme: base.scheme,
            userInfo: base.userInfo,
            host: base.host,
            port: base.hasPort ? base.port : null,
            path: '${base.path}/rest/$endpoint',
          ),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: body,
        );
      } else {
        request = _http.get(endpointUri(endpoint, params));
      }
      res = await request.timeout(const Duration(seconds: 20));
    } catch (e) {
      throw transportError(e, credentials.baseUrl);
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw MusicSourceException(
        'The server turned the login down. Check your username and password.',
        kind: MusicSourceErrorKind.auth,
      );
    }
    if (res.statusCode >= 500) {
      throw MusicSourceException(
        '${credentials.baseUrl.host} had a problem (HTTP ${res.statusCode}). '
        'Try again in a moment.',
        kind: MusicSourceErrorKind.server,
      );
    }
    if (res.statusCode != 200) {
      throw MusicSourceException(
        'No music server answered at ${credentials.baseUrl} '
        '(HTTP ${res.statusCode}). Check the address.',
        kind: MusicSourceErrorKind.notAServer,
      );
    }
    final Map<String, dynamic>? resp;
    try {
      final bytes = res.bodyBytes;
      // A big library's artist list can run to megabytes. Decoding that on
      // the UI thread stalls scrolling and animations, so large replies are
      // decoded on a background isolate (inline on the web, which has none).
      final body = bytes.length > backgroundDecodeBytes
          ? await compute(_decodeJson, bytes)
          : _decodeJson(bytes);
      resp =
          (body as Map<String, dynamic>)['subsonic-response']
              as Map<String, dynamic>?;
    } catch (_) {
      throw _notSubsonic();
    }
    if (resp == null) throw _notSubsonic();
    if (resp['status'] != 'ok') {
      final err = resp['error'] as Map<String, dynamic>?;
      throw serverError(err?['code'] as int?, err?['message'] as String?);
    }
    return resp;
  }

  void close() => _http.close();

  /// Replies bigger than this are decoded off the UI thread.
  static const backgroundDecodeBytes = 256 * 1024;

  static Object? _decodeJson(Uint8List bytes) => jsonDecode(utf8.decode(bytes));

  MusicSourceException _notSubsonic() => MusicSourceException(
    'The server at ${credentials.baseUrl} is not a Subsonic or Navidrome '
    'server. Check the address: it is the one you open Navidrome with in a '
    'browser.',
    kind: MusicSourceErrorKind.notAServer,
  );

  /// A failure to get any reply, in words. Matches on the error's text
  /// because the types (`SocketException`, `HandshakeException`) live in
  /// dart:io, which this layer keeps out of so a web build stays possible.
  static MusicSourceException transportError(Object e, Uri baseUrl) {
    final host = baseUrl.host;
    final text = e.toString();
    final String message;
    if (e is TimeoutException) {
      message =
          '$host did not answer within 20 seconds. Check that the '
          'server is running and reachable from this computer.';
    } else if (text.contains('Handshake') ||
        text.contains('CERTIFICATE') ||
        text.contains('WRONG_VERSION_NUMBER')) {
      message = baseUrl.scheme == 'https'
          ? 'Could not make a secure connection to $host. If the server '
                'has no HTTPS, start the address with http://.'
          : 'Could not make a secure connection to $host.';
    } else if (text.contains('Failed host lookup') ||
        text.contains('No address associated') ||
        text.contains('nodename nor servname')) {
      message = 'Could not find $host. Check the address.';
    } else {
      message =
          'Could not reach $host. Check the address and that the '
          'server is running.';
    }
    return MusicSourceException(
      message,
      kind: MusicSourceErrorKind.unreachable,
    );
  }

  /// A Subsonic error code in words. See the error codes in the Subsonic
  /// API's `subsonic-response` docs.
  static MusicSourceException serverError(int? code, String? serverMessage) {
    final (kind, message) = switch (code) {
      40 => (MusicSourceErrorKind.auth, 'Wrong username or password.'),
      41 => (
        MusicSourceErrorKind.auth,
        'This server does not accept token logins for this account, which '
            'OAmp needs. If it uses LDAP, sign in with an API key instead.',
      ),
      42 || 43 => (
        MusicSourceErrorKind.auth,
        'This server does not accept that way of signing in. Try the other '
            'one (password or API key).',
      ),
      44 => (MusicSourceErrorKind.auth, 'That API key is not valid.'),
      50 => (
        MusicSourceErrorKind.auth,
        'This account is not allowed to do that on the server.',
      ),
      20 || 30 => (
        MusicSourceErrorKind.server,
        'The server\'s API version does not work with OAmp. Update the server.',
      ),
      _ => (
        MusicSourceErrorKind.server,
        (serverMessage == null || serverMessage.isEmpty)
            ? 'The server could not do that.'
            : serverMessage,
      ),
    };
    return MusicSourceException(message, code: code, kind: kind);
  }
}

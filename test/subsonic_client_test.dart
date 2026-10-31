import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oamp/api/subsonic_client.dart';

void main() {
  group('normaliseServerUrl', () {
    test('adds https and strips trailing slashes', () {
      expect(
        SubsonicClient.normaliseServerUrl(' music.example.com// ').toString(),
        'https://music.example.com',
      );
    });
    test('keeps an explicit scheme, port and sub-path', () {
      expect(
        SubsonicClient.normaliseServerUrl('http://nas:4533/navidrome/')
            .toString(),
        'http://nas:4533/navidrome',
      );
    });
  });

  test('token is md5(password + salt) and the password is not sent', () {
    final c = SubsonicCredentials.fromPassword(
      baseUrl: Uri.parse('https://m.example.com/nd'),
      username: 'ed',
      password: 'sesame',
    );
    expect(c.token, md5.convert(utf8.encode('sesame${c.salt}')).toString());
    final uri = SubsonicClient(c).endpointUri('ping');
    expect(uri.path, '/nd/rest/ping');
    expect(uri.queryParameters['u'], 'ed');
    expect(uri.queryParameters['t'], c.token);
    expect(uri.queryParameters['s'], c.salt);
    expect(uri.queryParameters['f'], 'json');
    expect(uri.toString(), isNot(contains('sesame')));
  });

  SubsonicClient clientReturning(Map<String, dynamic> body) => SubsonicClient(
    SubsonicCredentials.fromPassword(
      baseUrl: Uri.parse('https://m.example.com'),
      username: 'ed',
      password: 'x',
    ),
    httpClient: MockClient(
      (_) async => http.Response.bytes(
        utf8.encode(jsonEncode({"subsonic-response": body})),
        200,
      ),
    ),
  );

  test('server error is surfaced with its message', () async {
    final c = clientReturning({
      'status': 'failed',
      'error': {'code': 40, 'message': 'Wrong username or password'},
    });
    await expectLater(
      c.ping(),
      throwsA(
        isA<SubsonicException>()
            .having((e) => e.code, 'code', 40)
            .having((e) => e.message, 'message', 'Wrong username or password'),
      ),
    );
  });

  test('getArtists flattens the index', () async {
    final c = clientReturning({
      'status': 'ok',
      'artists': {
        'index': [
          {
            'name': 'A',
            'artist': [
              {'id': '1', 'name': 'Air', 'albumCount': 3},
            ],
          },
          {
            'name': 'B',
            'artist': [
              {'id': '2', 'name': 'Björk', 'albumCount': 9},
            ],
          },
        ],
      },
    });
    final artists = await c.getArtists();
    expect(artists.map((a) => a.name), ['Air', 'Björk']);
    expect(artists.last.albumCount, 9);
  });

  test('getAlbum parses tracks with durations', () async {
    final c = clientReturning({
      'status': 'ok',
      'album': {
        'id': 'al1',
        'name': 'Moon Safari',
        'artist': 'Air',
        'song': [
          {
            'id': 't1',
            'title': 'La femme d\'argent',
            'track': 1,
            'duration': 427,
          },
        ],
      },
    });
    final detail = await c.getAlbum('al1');
    expect(detail.album.name, 'Moon Safari');
    expect(detail.tracks.single.duration, const Duration(seconds: 427));
  });
}

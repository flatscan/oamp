import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/sources/subsonic/subsonic_client.dart';
import 'package:oamp/sources/subsonic/subsonic_source.dart';

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

  test('serverId is stable across salts and differs per account', () {
    SubsonicCredentials creds(String user) => SubsonicCredentials.fromPassword(
      baseUrl: Uri.parse('https://m.example.com'),
      username: user,
      password: 'x',
    );
    expect(creds('ed').serverId, creds('ed').serverId);
    expect(creds('ed').serverId, isNot(creds('kim').serverId));
  });

  SubsonicSource sourceReturning(Map<String, dynamic> body) => SubsonicSource(
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
    final c = sourceReturning({
      'status': 'failed',
      'error': {'code': 40, 'message': 'Wrong username or password'},
    });
    await expectLater(
      c.ping(),
      throwsA(
        isA<MusicSourceException>()
            .having((e) => e.code, 'code', 40)
            .having((e) => e.message, 'message', 'Wrong username or password'),
      ),
    );
  });

  test('getArtists flattens the index', () async {
    final c = sourceReturning({
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
    final c = sourceReturning({
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

  test('search3 results and liked flags are parsed', () async {
    final c = sourceReturning({
      'status': 'ok',
      'searchResult3': {
        'artist': [
          {'id': 'ar1', 'name': 'Air'},
        ],
        'album': [
          {'id': 'al1', 'name': 'Moon Safari', 'artist': 'Air'},
        ],
        'song': [
          {
            'id': 't2',
            'title': 'Sexy Boy',
            'artistId': 'ar1',
            'albumId': 'al1',
            'starred': '2026-01-01T00:00:00Z',
          },
          {'id': 't3', 'title': 'Kelly Watch the Stars'},
        ],
      },
    });
    final r = await c.search('air');
    expect(r.artists.single.name, 'Air');
    expect(r.albums.single.name, 'Moon Safari');
    expect(r.tracks.first.liked, isTrue);
    expect(r.tracks.first.artistId, 'ar1');
    expect(r.tracks.last.liked, isFalse);
  });

  test('an empty search result is empty, not an error', () async {
    final c = sourceReturning({'status': 'ok', 'searchResult3': {}});
    expect((await c.search('zzz')).isEmpty, isTrue);
  });

  test('getPlaylist parses entries and duration', () async {
    final c = sourceReturning({
      'status': 'ok',
      'playlist': {
        'id': 'p1',
        'name': 'Mixtape',
        'songCount': 1,
        'duration': 300,
        'owner': 'ed',
        'entry': [
          {'id': 't1', 'title': 'One'},
        ],
      },
    });
    final d = await c.getPlaylist('p1');
    expect(d.playlist.duration, const Duration(minutes: 5));
    expect(d.playlist.owner, 'ed');
    expect(d.tracks.single.title, 'One');
  });

  test('scrobble and star send the right endpoints', () async {
    final seen = <Uri>[];
    final c = SubsonicSource(
      SubsonicCredentials.fromPassword(
        baseUrl: Uri.parse('https://m.example.com'),
        username: 'ed',
        password: 'x',
      ),
      httpClient: MockClient((req) async {
        seen.add(req.url);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'subsonic-response': {'status': 'ok'},
            }),
          ),
          200,
        );
      }),
    );
    await c.reportPlayback('t1', submission: true);
    await c.setLiked('t1', false);
    expect(seen[0].path, '/rest/scrobble');
    expect(seen[0].queryParameters['submission'], 'true');
    expect(seen[1].path, '/rest/unstar');
    expect(seen[1].queryParameters['id'], 't1');
  });
}

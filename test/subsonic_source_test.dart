import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/core/playback_options.dart';
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

  test('stream URLs ask for the original file or a transcode', () {
    final c = sourceReturning({'status': 'ok'});
    final raw = c.streamUrl('t1').queryParameters;
    expect(raw['id'], 't1');
    expect(raw['format'], 'raw');
    expect(raw.containsKey('maxBitRate'), isFalse);
    final opus = c
        .streamUrl(
          't1',
          quality: const StreamQuality(format: StreamFormat.opus, bitRate: 128),
        )
        .queryParameters;
    expect(opus['format'], 'opus');
    expect(opus['maxBitRate'], '128');
  });

  test('OpenSubsonic ReplayGain is read from songs', () async {
    final c = sourceReturning({
      'status': 'ok',
      'album': {
        'id': 'al1',
        'name': 'Moon Safari',
        'song': [
          {
            'id': 't1',
            'title': 'Sexy Boy',
            'replayGain': {
              'trackGain': -7.5,
              'albumGain': -6.25,
              'trackPeak': 0.98,
              'albumPeak': 1,
            },
          },
          {'id': 't2', 'title': 'Untagged', 'replayGain': {}},
        ],
      },
    });
    final tracks = (await c.getAlbum('al1')).tracks;
    final rg = tracks.first.replayGain!;
    expect(rg.trackGain, -7.5);
    expect(rg.albumGain, -6.25);
    expect(rg.trackPeak, 0.98);
    expect(rg.albumPeak, 1.0);
    expect(tracks.last.replayGain, isNull);
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

  /// A source that records each request and answers with [reply].
  (SubsonicSource, List<http.Request>) recording([
    Map<String, dynamic> reply = const {},
  ]) {
    final seen = <http.Request>[];
    final c = SubsonicSource(
      SubsonicCredentials.fromPassword(
        baseUrl: Uri.parse('https://m.example.com'),
        username: 'ed',
        password: 'x',
      ),
      httpClient: MockClient((req) async {
        seen.add(req);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'subsonic-response': {'status': 'ok', ...reply},
            }),
          ),
          200,
        );
      }),
    );
    return (c, seen);
  }

  test('likes for albums and artists use their own star parameters', () async {
    final (c, seen) = recording();
    await c.setLiked('al1', true, target: LikeTarget.album);
    await c.setLiked('ar1', false, target: LikeTarget.artist);
    expect(seen[0].url.path, '/rest/star');
    expect(seen[0].url.queryParameters['albumId'], 'al1');
    expect(seen[1].url.path, '/rest/unstar');
    expect(seen[1].url.queryParameters['artistId'], 'ar1');
  });

  test('album extras: genre, liked, release types', () async {
    final c = sourceReturning({
      'status': 'ok',
      'album': {
        'id': 'al2',
        'name': 'Kelly Watch the Stars',
        'genre': 'Electronic',
        'starred': '2026-01-01T00:00:00Z',
        'releaseTypes': ['Single'],
        'song': [],
      },
    });
    final a = (await c.getAlbum('al2')).album;
    expect(a.genre, 'Electronic');
    expect(a.liked, isTrue);
    expect(a.kind, ReleaseKind.single);
  });

  test('playlist writes send ids as repeated parameters', () async {
    final (c, seen) = recording({
      'playlist': {'id': 'p9', 'name': 'New', 'owner': 'ed'},
    });
    final p = await c.createPlaylist('New', trackIds: ['t1', 't2']);
    await c.addToPlaylist('p9', ['t3']);
    await c.removeFromPlaylist('p9', [0, 2]);
    await c.replacePlaylistTracks('p9', ['t2', 't1']);
    await c.renamePlaylist('p9', 'Renamed');
    await c.deletePlaylist('p9');

    expect(p.id, 'p9');
    expect(seen[0].url.path, '/rest/createPlaylist');
    expect(seen[0].url.queryParametersAll['songId'], ['t1', 't2']);
    expect(seen[1].url.queryParametersAll['songIdToAdd'], ['t3']);
    expect(seen[2].url.queryParametersAll['songIndexToRemove'], ['0', '2']);
    expect(seen[3].url.path, '/rest/createPlaylist');
    expect(seen[3].url.queryParameters['playlistId'], 'p9');
    expect(seen[3].url.queryParametersAll['songId'], ['t2', 't1']);
    expect(seen[4].url.queryParameters['name'], 'Renamed');
    expect(seen[5].url.path, '/rest/deletePlaylist');
  });

  test('long id lists are posted as a form, not put in the URL', () async {
    final (c, seen) = recording();
    final ids = [for (var i = 0; i < 500; i++) 'track-$i'];
    await c.replacePlaylistTracks('p9', ids);
    final req = seen.single;
    expect(req.method, 'POST');
    expect(req.url.query, isEmpty);
    expect(req.url.path, '/rest/createPlaylist');
    final form = Uri.splitQueryString(req.body);
    expect(form['u'], 'ed');
    expect(form['playlistId'], 'p9');
    expect(Uri(query: req.body).queryParametersAll['songId'], ids);
  });

  test('artist info strips markup and skips artists not in the library', () {
    expect(
      SubsonicSource.plainBiography(
        'Air are a <b>French</b> duo. <a href="https://last.fm">Read more on '
        'Last.fm</a>.',
      ),
      'Air are a French duo.',
    );
    expect(SubsonicSource.plainBiography('  '), isNull);
  });

  test('artist info, top songs and similar songs are parsed', () async {
    final (c, seen) = recording({
      'artistInfo2': {
        'biography': 'Duo.',
        'similarArtist': [
          {'id': 'ar2', 'name': 'Daft Punk'},
          {'name': 'Not in library'},
        ],
      },
      'topSongs': {
        'song': [
          {'id': 't2', 'title': 'Sexy Boy'},
        ],
      },
      'similarSongs': {
        'song': [
          {'id': 't9', 'title': 'Around the World'},
        ],
      },
    });
    final info = await c.getArtistInfo('ar1');
    expect(info.biography, 'Duo.');
    expect(info.similar.map((a) => a.name), ['Daft Punk']);
    final top = await c.getTopTracks(const Artist(id: 'ar1', name: 'Air'));
    expect(top.single.title, 'Sexy Boy');
    expect(seen[1].url.queryParameters['artist'], 'Air');
    final similar = await c.getSimilarTracks('t2');
    expect(similar.single.id, 't9');
    expect(seen[2].url.path, '/rest/getSimilarSongs');
  });
}

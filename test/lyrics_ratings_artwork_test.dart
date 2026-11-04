import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oamp/core/lyrics.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/main.dart';
import 'package:oamp/platform/disk_artwork_cache.dart';
import 'package:oamp/sources/subsonic/subsonic_client.dart';
import 'package:oamp/ui/glyphs.dart';
import 'package:oamp/sources/subsonic/subsonic_source.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

void main() {
  group('Lyrics.parse', () {
    test('reads LRC as synced lines in time order', () {
      final l = Lyrics.parse(
        '[ar:Air]\n'
        '[00:12.50]First line\n'
        '[00:05.1]Opening\n'
        '[01:02.345][01:30.00]Chorus\n',
      );
      expect(l.synced, isTrue);
      expect(l.lines.map((x) => x.text), [
        'Opening',
        'First line',
        'Chorus',
        'Chorus',
      ]);
      expect(l.lines[0].start, const Duration(seconds: 5, milliseconds: 100));
      expect(l.lines[1].start, const Duration(seconds: 12, milliseconds: 500));
      expect(
        l.lines[2].start,
        const Duration(minutes: 1, seconds: 2, milliseconds: 345),
      );
    });

    test('lineAt finds the line being sung', () {
      final l = Lyrics.parse('[00:01.00]a\n[00:03.00]b\n[00:06.00]c');
      expect(l.lineAt(Duration.zero), -1);
      expect(l.lineAt(const Duration(seconds: 1)), 0);
      expect(l.lineAt(const Duration(seconds: 5)), 1);
      expect(l.lineAt(const Duration(minutes: 9)), 2);
    });

    test('plain text stays plain, blank lines and all', () {
      final l = Lyrics.parse('Verse one\nstill verse\n\nVerse two');
      expect(l.synced, isFalse);
      expect(l.lines.map((x) => x.text), [
        'Verse one',
        'still verse',
        '',
        'Verse two',
      ]);
      expect(l.lineAt(const Duration(seconds: 3)), -1);
      expect(Lyrics.parse('  ').isEmpty, isTrue);
    });
  });

  group('Subsonic lyrics and ratings', () {
    final requests = <Uri>[];

    SubsonicSource source(Map<String, dynamic> Function(Uri) reply) {
      requests.clear();
      return SubsonicSource(
        SubsonicCredentials.fromPassword(
          baseUrl: Uri.parse('https://m.example.com'),
          username: 'ed',
          password: 'x',
        ),
        httpClient: MockClient((req) async {
          requests.add(req.url);
          return http.Response.bytes(
            utf8.encode(jsonEncode({'subsonic-response': reply(req.url)})),
            200,
          );
        }),
      );
    }

    const track = Track(id: 's1', title: 'Sexy Boy', artist: 'Air');

    test('prefers synced structured lyrics and applies the offset', () async {
      final s = source(
        (_) => {
          'status': 'ok',
          'lyricsList': {
            'structuredLyrics': [
              {
                'synced': false,
                'line': [
                  {'value': 'plain'},
                ],
              },
              {
                'synced': true,
                'offset': 500,
                'line': [
                  {'start': 2000, 'value': 'second'},
                  {'start': 1000, 'value': 'first'},
                ],
              },
            ],
          },
        },
      );
      final l = await s.getLyrics(track);
      expect(l.synced, isTrue);
      expect(l.lines.map((x) => x.text), ['first', 'second']);
      expect(l.lines.first.start, const Duration(milliseconds: 500));
      expect(requests.single.path, endsWith('/getLyricsBySongId'));
    });

    test('falls back to getLyrics by artist and title', () async {
      final s = source(
        (u) => u.path.endsWith('getLyricsBySongId')
            ? {
                'status': 'failed',
                'error': {'code': 0, 'message': 'not implemented'},
              }
            : {
                'status': 'ok',
                'lyrics': {
                  'artist': 'Air',
                  'title': 'Sexy Boy',
                  'value': 'Line one\nLine two',
                },
              },
      );
      final l = await s.getLyrics(track);
      expect(l.synced, isFalse);
      expect(l.lines.map((x) => x.text), ['Line one', 'Line two']);
      expect(requests.last.path, endsWith('/getLyrics'));
      expect(requests.last.queryParameters['artist'], 'Air');
      expect(requests.last.queryParameters['title'], 'Sexy Boy');
    });

    test('no lyrics anywhere is Lyrics.none', () async {
      final s = source(
        (u) => u.path.endsWith('getLyricsBySongId')
            ? {
                'status': 'ok',
                'lyricsList': {'structuredLyrics': <Object>[]},
              }
            : {'status': 'ok', 'lyrics': <String, Object>{}},
      );
      expect((await s.getLyrics(track)).isEmpty, isTrue);
    });

    test('setRating sends the id and stars; userRating is read', () async {
      final s = source(
        (u) => u.path.endsWith('getAlbum')
            ? {
                'status': 'ok',
                'album': {
                  'id': 'al1',
                  'name': 'Moon Safari',
                  'userRating': 4,
                  'song': [
                    {'id': 's1', 'title': 'x', 'userRating': 2},
                  ],
                },
              }
            : {'status': 'ok'},
      );
      await s.setRating('s1', 5);
      expect(requests.last.path, endsWith('/setRating'));
      expect(requests.last.queryParameters['id'], 's1');
      expect(requests.last.queryParameters['rating'], '5');
      final album = await s.getAlbum('al1');
      expect(album.album.rating, 4);
      expect(album.tracks.single.rating, 2);
    });
  });

  group('DiskArtworkCache', () {
    late Directory dir;
    late List<Uri> fetched;
    final png = Uint8List.fromList(List.generate(1000, (i) => i % 256));

    setUp(() {
      dir = Directory.systemTemp.createTempSync('oamp_art');
      fetched = [];
    });
    tearDown(() => dir.deleteSync(recursive: true));

    DiskArtworkCache cache({
      String type = 'image/jpeg',
      int limit = DiskArtworkCache.defaultLimit,
    }) => DiskArtworkCache(
      dir,
      limitBytes: limit,
      httpClient: MockClient((req) async {
        fetched.add(req.url);
        return http.Response.bytes(png, 200, headers: {'content-type': type});
      }),
    );

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    test('fetches once, then serves from disk across restarts', () async {
      final a = cache();
      final u1 = Uri.parse('https://m/rest/getCoverArt?id=c1&s=salt1');
      expect(await a.load('srv/c1/300', u1), png);
      expect(await a.load('srv/c1/300', u1), png);
      await settle();
      // A new instance (next launch) with a different auth salt in the URL.
      final b = cache();
      final u2 = Uri.parse('https://m/rest/getCoverArt?id=c1&s=salt2');
      expect(await b.load('srv/c1/300', u2), png);
      expect(fetched, hasLength(1));
      expect((await b.usage()).files, 1);
      await b.clear();
      expect((await b.usage()).files, 0);
    });

    test('does not cache a Subsonic error reply', () async {
      final c = cache(type: 'application/json');
      await expectLater(
        c.load('srv/x/300', Uri.parse('https://m/x')),
        throwsA(isA<HttpException>()),
      );
      await settle();
      expect((await c.usage()).files, 0);
    });

    test('evicts the least recently used images over the limit', () async {
      final c = cache(limit: 2500);
      for (final id in ['a', 'b', 'c']) {
        await c.load('srv/$id', Uri.parse('https://m/$id'));
        await settle();
        // Distinct modification times on coarse file systems.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await settle();
      final usage = await c.usage();
      expect(usage.bytes, lessThanOrEqualTo(2000));
      fetched.clear();
      await c.load('srv/c', Uri.parse('https://m/c'));
      expect(fetched, isEmpty, reason: 'the newest image is kept');
    });
  });

  group('now playing', () {
    late FakeAudioEngine engine;
    late FakeMusicSource source;

    Future<void> pumpPlaying(WidgetTester tester) async {
      tester.view.physicalSize = const Size(440, 880);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      engine = FakeAudioEngine();
      source = FakeMusicSource();
      source.lyrics['t1'] = Lyrics.parse(
        '[00:00.50]Ouverture\n[00:04.00]Deuxième ligne\n[00:09.00]Fin',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
            audioEngineProvider.overrideWithValue(engine),
          ],
          child: const OAmpApp(),
        ),
      );
      // The scope is disposed with the widget tree, which also stops the
      // timers the queue saver and play reporter start.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(OAmpApp)),
      );
      await tester.pumpAndSettle();
      await container
          .read(playerProvider.notifier)
          .playTracks(FakeMusicSource.tracks, from: 'Moon Safari');
      await tester.pumpAndSettle();
      await tester.tap(find.text('La femme d’argent').last);
      await tester.pumpAndSettle();
    }

    testWidgets('shows synced lyrics over the art and follows the music', (
      tester,
    ) async {
      await pumpPlaying(tester);
      expect(source.calls, contains('lyrics:t1'));
      expect(find.text('Ouverture'), findsNothing);

      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('Ouverture'), findsOneWidget);

      Color colorOf(String text) => tester
          .widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text(text),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          )
          .style
          .color!;

      engine.emitPosition(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(colorOf('Deuxième ligne').a, 1.0);
      expect(colorOf('Fin').a, lessThan(1.0));

      await tester.tap(find.byTooltip('Hide lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('Ouverture'), findsNothing);
    });

    testWidgets('lyrics button is off for a track without lyrics', (
      tester,
    ) async {
      await pumpPlaying(tester);
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(source.calls, contains('lyrics:t2'));
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byType(LyricsGlyph),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(find.byTooltip('No lyrics for this track'), findsOneWidget);
    });

    testWidgets('rating the playing track saves to the server', (tester) async {
      await pumpPlaying(tester);
      await tester.tap(find.byKey(const ValueKey('star4')).first);
      await tester.pumpAndSettle();
      expect(source.calls, contains('rate:t1:4'));
      expect(find.bySemanticsLabel('Rated 4 stars'), findsOneWidget);
      expect(find.byType(StarGlyph), findsNWidgets(5));

      // Clicking the same star again clears it.
      await tester.tap(find.byKey(const ValueKey('star4')).first);
      await tester.pumpAndSettle();
      expect(source.calls, contains('rate:t1:0'));
    });
  });
}

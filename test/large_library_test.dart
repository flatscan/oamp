import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/main.dart';
import 'package:oamp/sources/subsonic/subsonic_client.dart';
import 'package:oamp/sources/subsonic/subsonic_source.dart';
import 'package:oamp/state/library.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/ui/browse/artists_view.dart';
import 'package:oamp/ui/jump_bar.dart';

import 'fakes/fakes.dart';

/// A library the size of 50,000+ tracks: 20,000 artists and 10,000 albums,
/// spread over the letters, with some names under '#'.
const artistCount = 20000;
const albumCount = 10000;

String _name(int i, int n, String kind) {
  // The first 1% file under '#', the rest are spread A to Z.
  if (i < n ~/ 100) return '${i.toString().padLeft(5, '0')} $kind';
  final letter = indexLetters[1 + (i - n ~/ 100) * 26 ~/ (n - n ~/ 100)];
  return '$letter $kind ${i.toString().padLeft(5, '0')}';
}

final bigArtists = List<Artist>.unmodifiable([
  for (var i = 0; i < artistCount; i++)
    Artist(id: 'ar$i', name: _name(i, artistCount, 'artist'), albumCount: 2),
]);

final bigAlbums = List<Album>.unmodifiable([
  for (var i = 0; i < albumCount; i++)
    () {
      final name = _name(i, albumCount, 'album');
      return Album(id: 'al$i', name: name, sortName: name);
    }(),
]);

/// Counts the album pages asked for, to show a jump does not walk the
/// whole list a page at a time.
class CountingSource extends FakeMusicSource {
  CountingSource() : super(artists: bigArtists, albums: bigAlbums);

  final albumRequests = <({int size, int offset})>[];

  @override
  Future<List<Album>> getAlbums({
    AlbumSort sort = AlbumSort.alphabetical,
    int size = 100,
    int offset = 0,
  }) {
    albumRequests.add((size: size, offset: offset));
    return super.getAlbums(sort: sort, size: size, offset: offset);
  }
}

void main() {
  late CountingSource source;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    source = CountingSource();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
        ],
        child: const OAmpApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
  }

  Future<void> jumpTo(WidgetTester tester, String letter) async {
    final rect = tester.getRect(find.byType(JumpBar));
    final i = indexLetters.indexOf(letter);
    await tester.tapAt(
      Offset(
        rect.center.dx,
        rect.top + (i + 0.5) * rect.height / indexLetters.length,
      ),
    );
    await tester.pumpAndSettle();
  }

  bool nearTop(WidgetTester tester, Finder f, {double below = 0}) {
    final y = tester.getTopLeft(f).dy - below;
    return y > 40 && y < 140;
  }

  /// The first artist filed under [letter].
  Artist firstArtist(String letter) =>
      bigArtists.firstWhere((a) => indexLetter(a.sortName ?? a.name) == letter);

  group('LetterGroups', () {
    test('splits runs by letter and sums offsets without the rows', () {
      final g = LetterGroups.of(bigArtists, (a) => a.name);
      expect(g.length, artistCount);
      expect(g.groups.first.letter, '#');
      expect(g.letters, containsAll(indexLetters));

      const h = 40.0, r = 72.0;
      expect(g.offsetOf('#', headerHeight: h, rowHeight: r), 0);
      final hashRun = g.groups.first.items.length;
      expect(g.offsetOf('A', headerHeight: h, rowHeight: r), h + hashRun * r);
      final beforeZ = g.groups
          .takeWhile((x) => x.letter != 'Z')
          .fold<double>(0, (sum, x) => sum + h + x.items.length * r);
      expect(g.offsetOf('Z', headerHeight: h, rowHeight: r), beforeZ);
    });

    test('a missing letter goes to the next one, ignoring a # run at the '
        'end', () {
      final g = LetterGroups.of(['Alpha', 'Bravo', 'Delta', '東京'], (s) => s);
      expect(g.groups.map((x) => x.letter), ['A', 'B', 'D', '#']);
      expect(g.offsetOf('C', headerHeight: 10, rowHeight: 1), 22);
      // Past D, the only run left is '#', so the jump goes to the end.
      expect(g.offsetOf('X', headerHeight: 10, rowHeight: 1), 44);
    });
  });

  testWidgets('20,000 artists: only visible rows are built, and the jump '
      'bar reaches every letter', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.byType(JumpBar), findsOneWidget);
    // A screenful, not the library.
    expect(
      find.byType(ArtistTile, skipOffstage: false).evaluate().length,
      lessThan(60),
    );

    for (final letter in ['M', 'Z', 'A', '#', 'S']) {
      await jumpTo(tester, letter);
      final first = firstArtist(letter).name;
      expect(find.text(first), findsOneWidget, reason: letter);
      // Under the letter's heading, which sits just below the top bar.
      expect(
        nearTop(tester, find.text(first), below: 40),
        isTrue,
        reason: letter,
      );
      expect(
        find.byType(ArtistTile, skipOffstage: false).evaluate().length,
        lessThan(60),
      );
    }

    // Scrolling on from a jump shows the following artists in order.
    await jumpTo(tester, 'K');
    final list = find.byType(CustomScrollView).last;
    final k = bigArtists.indexOf(firstArtist('K'));
    await tester.drag(list, const Offset(0, -72.0 * 50));
    await tester.pumpAndSettle();
    expect(find.text(bigArtists[k + 50].name), findsOneWidget);
  });

  testWidgets('10,000 albums: jumping to Z takes a few large requests, not '
      'a page at a time', (tester) async {
    await pumpApp(tester);
    source.albumRequests.clear(); // the home screen's rows
    await tester.tap(find.text('Albums').first);
    await tester.pumpAndSettle();
    expect(source.albumRequests, hasLength(1));

    await jumpTo(tester, 'Z');
    final firstZ = bigAlbums.firstWhere((a) => indexLetter(a.name) == 'Z');
    expect(find.text(firstZ.name), findsOneWidget);
    expect(nearTop(tester, find.text(firstZ.name), below: 190), isTrue);
    // 10,000 albums at 120 a page would be 84 requests one after another.
    // Fast-forwarding is five rounds of four requests sent together.
    expect(source.albumRequests.length, lessThanOrEqualTo(21));
    expect(source.albumRequests.skip(1).every((r) => r.size == 500), isTrue);

    // Back up the list needs nothing more from the server.
    final before = source.albumRequests.length;
    await jumpTo(tester, 'C');
    final firstC = bigAlbums.firstWhere((a) => indexLetter(a.name) == 'C');
    expect(nearTop(tester, find.text(firstC.name), below: 190), isTrue);
    expect(source.albumRequests.length, before);
  });

  test('a multi-megabyte artist list is decoded off the UI thread and '
      'comes back whole', () async {
    final body = utf8.encode(
      jsonEncode({
        'subsonic-response': {
          'status': 'ok',
          'artists': {
            'ignoredArticles': 'The',
            'index': [
              for (final l in indexLetters.skip(1))
                {
                  'name': l,
                  'artist': [
                    for (var i = 0; i < 400; i++)
                      {
                        'id': '$l$i',
                        'name': '$l artist $i',
                        'albumCount': 1,
                        'coverArt': 'ar-$l$i',
                      },
                  ],
                },
            ],
          },
        },
      }),
    );
    expect(body.length, greaterThan(SubsonicClient.backgroundDecodeBytes));
    final s = SubsonicSource(
      SubsonicCredentials.fromPassword(
        baseUrl: Uri.parse('https://m.example.com'),
        username: 'ed',
        password: 'x',
      ),
      httpClient: MockClient((_) async => http.Response.bytes(body, 200)),
    );
    final artists = await s.getArtists();
    expect(artists, hasLength(26 * 400));
    expect(artists.last.name, 'Z artist 399');
  });
}

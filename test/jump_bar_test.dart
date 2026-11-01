import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/main.dart';
import 'package:oamp/sources/subsonic/subsonic_source.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/ui/jump_bar.dart';

import 'fakes/fakes.dart';

void main() {
  late FakeMusicSource source;

  Future<void> pumpApp(WidgetTester tester, FakeMusicSource s) async {
    tester.view.physicalSize = const Size(440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    source = s;
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
  }

  /// Clicks [letter] on the jump bar.
  Future<void> jumpTo(WidgetTester tester, String letter) async {
    final bar = find.byType(JumpBar);
    final rect = tester.getRect(bar);
    final i = indexLetters.indexOf(letter);
    await tester.tapAt(
      Offset(
        rect.center.dx,
        rect.top + (i + 0.5) * rect.height / indexLetters.length,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Whether [text] is drawn just under the top bar. An album's title is
  /// under its cover, so allow for that with [below].
  bool nearTop(WidgetTester tester, String text, {double below = 0}) {
    final y = tester.getTopLeft(find.text(text)).dy - below;
    return y > 40 && y < 140;
  }

  test('index letters ignore case, accents and leading articles', () {
    expect(indexLetter('émilie'), 'E');
    expect(indexLetter('2Pac'), '#');
    expect(indexLetter(''), '#');
    expect(SubsonicSource.sortNameOf('The Beatles'), 'Beatles');
    expect(
      SubsonicSource.sortNameOf('Theory of a Deadman'),
      'Theory of a Deadman',
    );
  });

  testWidgets('artists list jumps to a letter, and past empty ones', (
    tester,
  ) async {
    final names = [
      for (final l in ['A', 'B', 'C', 'D', 'M', 'S', 'Z'])
        for (var i = 0; i < 10; i++) '$l artist $i',
    ];
    await pumpApp(
      tester,
      FakeMusicSource(
        artists: [
          for (final (i, n) in names.indexed) Artist(id: 'a$i', name: n),
        ],
      ),
    );
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.byType(JumpBar), findsOneWidget);

    await jumpTo(tester, 'M');
    expect(nearTop(tester, 'M artist 0'), isTrue);

    // Nothing under P, so it goes on to S.
    await jumpTo(tester, 'P');
    expect(nearTop(tester, 'S artist 0'), isTrue);

    await jumpTo(tester, 'A');
    expect(nearTop(tester, 'A artist 0'), isTrue);
  });

  testWidgets('albums A to Z loads pages until it reaches the letter', (
    tester,
  ) async {
    // 26 letters x 12 albums is more than two pages of 120.
    final albums = [
      for (final l in indexLetters.skip(1))
        for (var i = 0; i < 12; i++)
          Album(id: '$l$i', name: '$l album $i', sortName: '$l album $i'),
    ];
    await pumpApp(tester, FakeMusicSource(albums: albums));
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Albums').first);
    await tester.pumpAndSettle();

    await jumpTo(tester, 'T');
    expect(find.text('T album 0'), findsOneWidget);
    expect(nearTop(tester, 'T album 0', below: 190), isTrue);

    await jumpTo(tester, 'B');
    expect(nearTop(tester, 'B album 0', below: 190), isTrue);
  });
}

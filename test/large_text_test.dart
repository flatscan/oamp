import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/main.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/ui/browse/artist_page.dart';

import 'fakes/fakes.dart';

/// Album grids and shelves leave room for their captions when the system
/// text is enlarged. A card that doesn't fit shows up as a RenderFlex
/// overflow, which fails the test.
void main() {
  Future<void> pumpApp(WidgetTester tester, double textScale) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(
            () => FakeSessionNotifier(FakeMusicSource()),
          ),
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
        ],
        child: const OAmpApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find.byType(Scrollable).hitTestable().first,
    );
    await tester.pumpAndSettle();
  }

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('home shelves fit at ${scale}x text', (tester) async {
      await pumpApp(tester, scale);
      expect(find.text('Moon Safari'), findsWidgets);
    });

    testWidgets('albums grid fits at ${scale}x text', (tester) async {
      await pumpApp(tester, scale);
      await tapText(tester, 'Library');
      await tapText(tester, 'Albums');
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.text('Moon Safari'), findsWidgets);
    });

    testWidgets('artist shelves fit at ${scale}x text', (tester) async {
      await pumpApp(tester, scale);
      await tapText(tester, 'Library');
      await tapText(tester, 'Artists');
      await tapText(tester, 'Air');
      await scrollTo(tester, find.text('Similar artists'));
      expect(find.text('Daft Punk'), findsOneWidget);
    });

    testWidgets('search album results fit at ${scale}x text', (tester) async {
      await pumpApp(tester, scale);
      await tapText(tester, 'Search');
      await tester.enterText(find.byType(TextField), 'moon');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final chip = find.widgetWithText(ChoiceChip, 'Albums');
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.byType(SliverGrid), findsOneWidget);
    });
  }

  test('grid rows keep their usual shape at normal text size', () {
    const grid = AlbumGridDelegate(caption: 46);
    // Two columns in a 380 px wide grid: 183 px covers.
    expect(AlbumGridDelegate.columns(380), 2);
    expect(grid.cardHeight(380), closeTo(183 / 0.74, 0.01));
  });

  test('grid rows grow when the caption needs more room', () {
    const grid = AlbumGridDelegate(caption: 90);
    expect(grid.cardHeight(380), 183 + 90);
    expect(grid.rowStride(380), 183 + 90 + 16);
  });
}

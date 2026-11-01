import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/main.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

void main() {
  late FakeAudioEngine engine;
  late FakeMusicSource source;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(440, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    engine = FakeAudioEngine();
    source = FakeMusicSource();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
          audioEngineProvider.overrideWithValue(engine),
        ],
        child: const OAmpApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('browse Library > Artists > album, play, open now playing', (
    tester,
  ) async {
    await pumpApp(tester);

    // Home shows the server's album rows; nothing is playing yet, so there
    // is no mini-player.
    expect(find.text('Recently added'), findsOneWidget);
    expect(find.byTooltip('Next'), findsNothing);

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Air'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moon Safari').first);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Play'));
    await tester.pumpAndSettle();

    // The player resolved both tracks through the source and started at 0.
    expect(engine.queue.map((u) => u.toString()), [
      'fake://stream/t1',
      'fake://stream/t2',
    ]);
    expect(engine.playing, isTrue);

    // The mini-player appeared; clicking it slides up now playing.
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tester.tap(find.text('La femme d’argent').last);
    await tester.pumpAndSettle();
    expect(find.text('Moon Safari (1998)'), findsNothing); // no year on track
    expect(find.text('Moon Safari'), findsWidgets);

    // The queue sits directly under the controls on the same screen.
    expect(find.text('UP NEXT'), findsOneWidget);
    expect(find.textContaining('Playing from Moon Safari'), findsOneWidget);
    expect(find.text('Sexy Boy'), findsWidgets);

    // Earlier lists nothing yet, since this is the first track.
    await tester.tap(find.text('EARLIER'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing has played yet.'), findsOneWidget);

    // Escape closes it again, back to the album page.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('UP NEXT'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
  });

  testWidgets('search finds a track and typing a space does not pause', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'sexy boy');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Tracks'), findsOneWidget);

    await tester.tap(find.text('Sexy Boy'));
    await tester.pumpAndSettle();
    expect(engine.queue.single.toString(), 'fake://stream/t2');
    expect(engine.playing, isTrue);

    // Space in the search field types a space rather than pausing.
    await tester.showKeyboard(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(engine.playing, isTrue);

    // Outside a text field, Space toggles playback.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(engine.playing, isFalse);
  });

  testWidgets('shuffle library from home and like the track', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Shuffle library'));
    await tester.pumpAndSettle();
    expect(engine.queue, hasLength(2));
    expect(engine.playing, isTrue);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(engine.playing, isFalse);

    // Open now playing and like the current track.
    await tester.fling(find.byTooltip('Play'), const Offset(0, -200), 1000);
    await tester.pumpAndSettle();
    expect(find.textContaining('Playing from Library shuffle'), findsOneWidget);
    await tester.tap(find.byTooltip('Like'));
    await tester.pumpAndSettle();
    expect(source.calls, contains('like:t1'));
    expect(find.byTooltip('Unlike'), findsOneWidget);
  });

  testWidgets('hovering an album on home shows a play button that plays it', (
    tester,
  ) async {
    await pumpApp(tester);
    final play = find.byTooltip('Play Moon Safari').first;
    // Hidden until the mouse is over the cover.
    expect(
      tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(of: play, matching: find.byType(AnimatedOpacity))
                .first,
          )
          .opacity,
      0,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.text('Moon Safari').first) - const Offset(0, 80),
    );
    await tester.pumpAndSettle();
    await tester.tap(play);
    await tester.pumpAndSettle();

    expect(engine.queue, hasLength(2));
    expect(engine.playing, isTrue);
    // Played in place: still on Home, not the album page.
    expect(find.text('Recently added'), findsOneWidget);
  });
}

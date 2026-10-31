import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/main.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

void main() {
  testWidgets('browse to an album and play it, driven by a fake source', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(460, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = FakeAudioEngine();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(FakeSessionNotifier.new),
          audioEngineProvider.overrideWithValue(engine),
        ],
        child: const OAmpApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Signed in: the home shell shows the artist list and an empty queue.
    expect(find.text('Air'), findsOneWidget);
    expect(find.textContaining('Queue is empty'), findsOneWidget);

    await tester.tap(find.text('Air'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moon Safari'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Play'));
    await tester.pumpAndSettle();

    // The player resolved both tracks through the source and started at 0.
    expect(engine.queue.map((u) => u.toString()), [
      'fake://stream/t1',
      'fake://stream/t2',
    ]);
    expect(engine.playing, isTrue);
    expect(find.textContaining('1 of 2'), findsOneWidget);
    // Now-playing title, the album row and the queue row.
    expect(find.text('Sexy Boy'), findsNWidgets(2));
  });
}

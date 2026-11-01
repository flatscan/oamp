import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/main.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

/// The album, artist, playlist and search screens, driven by the fake
/// source.
void main() {
  late FakeAudioEngine engine;
  late FakeMusicSource source;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    engine = FakeAudioEngine();
    source = FakeMusicSource()
      ..artistExtras = const [
        Album(
          id: 'al2',
          name: 'Kelly Watch the Stars',
          artist: 'Air',
          artistId: 'ar1',
          year: 1998,
          releaseTypes: ['single'],
        ),
      ];
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

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> openPlaylists(WidgetTester tester) async {
    await tapText(tester, 'Library');
    await tapText(tester, 'Playlists');
  }

  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find.byType(Scrollable).hitTestable().first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('album page: like, add to a new playlist, more by the artist', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Moon Safari').first);
    await tester.pumpAndSettle();

    expect(find.text('1998'), findsWidgets);
    await tester.tap(find.byTooltip('Like album'));
    await tester.pumpAndSettle();
    expect(source.calls, contains('like-album:al1'));
    expect(find.byTooltip('Unlike album'), findsOneWidget);

    // The ⋯ menu adds the whole album to a playlist made on the spot.
    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tapText(tester, 'Add to playlist…');
    expect(find.text('Add 2 tracks to'), findsOneWidget);
    await tapText(tester, 'New playlist…');
    await tester.enterText(find.byType(TextField), 'Road trip');
    await tapText(tester, 'Create');
    expect(source.calls, contains('create:Road trip:t1,t2'));

    await scrollTo(tester, find.text('More by Air'));
    expect(find.text('Kelly Watch the Stars'), findsOneWidget);
  });

  testWidgets('artist page: popular tracks, releases by kind, similar, bio', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapText(tester, 'Library');
    await tapText(tester, 'Artists');
    await tapText(tester, 'Air');

    expect(find.text('Popular'), findsOneWidget);
    expect(find.text('2 releases'), findsOneWidget);
    await scrollTo(tester, find.text('Singles & EPs'));
    expect(find.text('Albums'), findsOneWidget);
    await scrollTo(tester, find.text('About Air'));
    expect(find.text('Similar artists'), findsOneWidget);
    expect(find.text('Daft Punk'), findsOneWidget);
    expect(find.text('Air are a French duo from Versailles.'), findsOneWidget);

    // Radio plays tracks the server says are similar.
    await tester.scrollUntilVisible(
      find.byTooltip('Artist radio'),
      -200,
      scrollable: find.byType(Scrollable).hitTestable().first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Artist radio'));
    await tester.pumpAndSettle();
    expect(source.calls, contains('similar:ar1'));
    expect(engine.queue, hasLength(2));

    await tester.tap(find.byTooltip('Like artist'));
    await tester.pumpAndSettle();
    expect(source.calls, contains('like-artist:ar1'));
  });

  testWidgets('playlists: create from the list, rename and delete', (
    tester,
  ) async {
    await pumpApp(tester);
    await openPlaylists(tester);
    expect(find.text('Mixtape'), findsOneWidget);

    await tapText(tester, 'New playlist');
    await tester.enterText(find.byType(TextField), 'Chill');
    await tapText(tester, 'Create');
    expect(source.calls, contains('create:Chill:'));
    // The new, empty playlist opens.
    expect(find.textContaining('This playlist is empty'), findsOneWidget);

    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tapText(tester, 'Rename');
    await tester.enterText(find.byType(TextField), 'Chill out');
    await tapText(tester, 'Rename');
    expect(source.calls, contains('rename:pl2:Chill out'));
    expect(find.text('Chill out'), findsWidgets);

    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tapText(tester, 'Delete');
    await tapText(tester, 'Delete'); // confirm
    expect(source.calls, contains('delete:pl2'));
    // Back on the list, which no longer has it.
    expect(find.text('Chill out'), findsNothing);
    expect(find.text('Mixtape'), findsOneWidget);
  });

  testWidgets('playlist: remove a track from its menu, then undo', (
    tester,
  ) async {
    await pumpApp(tester);
    await openPlaylists(tester);
    await tapText(tester, 'Mixtape');
    expect(find.text('Sexy Boy'), findsOneWidget);

    await tester.tap(find.byTooltip('More').at(1)); // first track's menu
    await tester.pumpAndSettle();
    await tapText(tester, 'Remove from this playlist');
    expect(source.calls, contains('remove:pl1:0'));
    expect(find.text('Sexy Boy'), findsNothing);

    await tapText(tester, 'Undo');
    expect(source.calls, contains('replace:pl1:t2,t1'));
    expect(find.text('Sexy Boy'), findsOneWidget);
  });

  testWidgets('playlist: edit mode reorders and removes, saved on Done', (
    tester,
  ) async {
    await pumpApp(tester);
    await openPlaylists(tester);
    await tapText(tester, 'Mixtape');

    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tapText(tester, 'Edit tracks');
    expect(find.text('Done'), findsOneWidget);

    // Drag Sexy Boy below La femme d'argent.
    final handle = find.byIcon(Icons.drag_handle_rounded).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await tapText(tester, 'Done');
    expect(source.calls, contains('replace:pl1:t1,t2'));
    expect(find.text('Done'), findsNothing);

    // Cancel leaves the server alone.
    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tapText(tester, 'Edit tracks');
    await tester.tap(find.byTooltip('Remove Sexy Boy'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Cancel');
    expect(source.calls.where((c) => c.startsWith('replace')), hasLength(1));
    expect(find.text('Sexy Boy'), findsOneWidget);
  });

  testWidgets('track menu adds a track to an existing playlist', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Moon Safari').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More').at(1)); // first track
    await tester.pumpAndSettle();
    await tapText(tester, 'Add to playlist…');
    await tapText(tester, 'Mixtape');
    expect(source.calls, contains('add:pl1:t1'));
    expect(find.text('Added 1 track to "Mixtape"'), findsOneWidget);
  });

  testWidgets('search: filters, recent searches', (tester) async {
    await pumpApp(tester);
    await tapText(tester, 'Search');

    await tester.enterText(find.byType(TextField), 'air');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // The artist is the exact match.
    expect(find.text('Top result'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Artists'));
    await tester.pumpAndSettle();
    expect(find.text('Top result'), findsNothing);
    expect(find.text('Air'), findsOneWidget);

    // Opening a result remembers the search.
    await tapText(tester, 'Air');
    expect(find.text('Popular'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Recent searches'), findsOneWidget);
    expect(find.text('air'), findsOneWidget);

    await tapText(tester, 'air');
    expect(find.text('Top result'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Forget "air"'));
    await tester.pumpAndSettle();
    expect(find.text('Recent searches'), findsNothing);
  });

  testWidgets('queue can be saved as a playlist', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Moon Safari').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Play'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('La femme d’argent').last);
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('Save as playlist'));
    await tapText(tester, 'Save as playlist');
    await tester.enterText(find.byType(TextField), 'Tonight');
    await tapText(tester, 'Create');
    expect(source.calls, contains('create:Tonight:t1,t2'));
  });
}

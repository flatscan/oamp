import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/downloads.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/downloads.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/ui/download_button.dart';

import 'fakes/fakes.dart';
import 'fakes/memory_download_store.dart';

void main() {
  late MemoryDownloadStore store;

  Widget app({bool withStore = true}) => ProviderScope(
    overrides: [
      preferencesProvider.overrideWithValue(MemoryPreferences()),
      sessionProvider.overrideWith(() => FakeSessionNotifier()),
      if (withStore) downloadStoreProvider.overrideWithValue(store),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            ref.watch(downloadsProvider);
            return const DownloadButton(
              kind: PinKind.album,
              itemId: 'al1',
              name: 'Moon Safari',
              tracks: FakeMusicSource.tracks,
            );
          },
        ),
      ),
    ),
  );

  setUp(() => store = MemoryDownloadStore());

  testWidgets('tap downloads the album, shows a tick, and asks before '
      'removing it', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_circle_down_rounded), findsOneWidget);

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(store.files, {'t1', 't2'});
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.text('Remove download?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.files, {'t1', 't2'});

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(store.files, isEmpty);
    expect(find.byIcon(Icons.arrow_circle_down_rounded), findsOneWidget);
  });

  testWidgets('is hidden where downloads are not available', (tester) async {
    await tester.pumpWidget(app(withStore: false));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
  });
}

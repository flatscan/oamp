import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/ui/browse/settings_page.dart';
import 'package:oamp/ui/theme.dart';

import 'fakes/fakes.dart';

class _SignsOut extends FakeSessionNotifier {
  void signOut() => state = const AsyncData(null);
}

void main() {
  testWidgets('signing out with the settings page open throws nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = _SignsOut();
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => session),
        audioEngineProvider.overrideWithValue(FakeAudioEngine()),
        preferencesProvider.overrideWithValue(MemoryPreferences()),
      ],
    );
    addTearDown(c.dispose);
    await tester.runAsync(() => c.read(sessionProvider.future));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: buildTheme(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsWidgets);

    session.signOut();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

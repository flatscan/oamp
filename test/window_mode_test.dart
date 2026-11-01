import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/main.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/ui/app_frame.dart';
import 'package:oamp/ui/mode_switch.dart';
import 'package:oamp/ui/player/now_playing.dart';

import 'fakes/fakes.dart';

/// Desktop-only behaviour, run as Windows with window_manager's native side
/// faked out.
void main() {
  late List<MethodCall> windowCalls;
  late MemoryPreferences prefs;

  setUp(() {
    windowCalls = [];
    prefs = MemoryPreferences();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          windowCalls.add(call);
          return switch (call.method) {
            'isMaximized' || 'isFullScreen' || 'isMinimized' => false,
            'getBounds' => {
              'x': 0.0,
              'y': 0.0,
              'width': 440.0,
              'height': 880.0,
            },
            _ => null,
          };
        });
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(440, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier()),
          audioEngineProvider.overrideWithValue(FakeAudioEngine()),
          preferencesProvider.overrideWithValue(prefs),
        ],
        child: const OAmpApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the mode switch stays under the mouse across modes', (
    tester,
  ) async {
    await pumpApp(tester);
    final home = tester.getRect(find.byType(ModeSwitchButton));
    expect(home.right, 440 - ModeSwitchButton.inset);

    // Single-column Home -> expanded.
    await tester.tap(find.byType(ModeSwitchButton));
    tester.view.physicalSize = const Size(1160, 880);
    await tester.pumpAndSettle();
    expect(windowCalls.where((c) => c.method == 'setMaximumSize'), isNotEmpty);
    // One in the now playing column, one at the fly-out's top right.
    final buttons = find.byType(ModeSwitchButton);
    expect(buttons, findsNWidgets(2));
    expect(tester.getRect(buttons.first), home);
    final expandedNowPlaying = tester.getRect(find.byType(NowPlayingView));
    expect(expandedNowPlaying.width, 440);
    // The window is resized once, straight to its final width; the slide
    // happens inside the app.
    final widths = [
      for (final c in windowCalls.where((c) => c.method == 'setBounds'))
        (c.arguments as Map)['width'] as double,
    ];
    expect(widths.last, 1160);
    expect(widths.where((w) => w > 440 && w < 1160), isEmpty);
    expect(tester.getRect(buttons.last).right, 1160 - ModeSwitchButton.inset);

    // Expanded -> single column lands on now playing, same spot again, and
    // it is the very same widget (not a fresh copy that could flicker).
    final nowPlayingState = tester.state(find.byType(NowPlayingView));
    final nowPlayingRender = tester.renderObject(find.byType(NowPlayingView));
    await tester.tap(buttons.first);
    // Every frame of the switch back (panel sliding in, layout swap) keeps
    // the same now playing render object in the same place.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(find.byType(NowPlayingView)), expandedNowPlaying);
      expect(
        tester.renderObject(find.byType(NowPlayingView)),
        same(nowPlayingRender),
      );
    }
    tester.view.physicalSize = const Size(440, 880);
    await tester.pumpAndSettle();
    expect(find.text('UP NEXT'), findsOneWidget);
    expect(tester.getRect(find.byType(ModeSwitchButton)), home);
    // Now playing is exactly the same size and place in both modes.
    expect(tester.getRect(find.byType(NowPlayingView)), expandedNowPlaying);
    expect(tester.state(find.byType(NowPlayingView)), same(nowPlayingState));

    // And from single-column now playing back to expanded.
    await tester.tap(find.byType(ModeSwitchButton));
    tester.view.physicalSize = const Size(1160, 880);
    await tester.pumpAndSettle();
    expect(find.byType(ModeSwitchButton), findsNWidgets(2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the title bar can be hidden from settings', (tester) async {
    await pumpApp(tester);
    expect(find.byType(WindowBar), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show title bar'));
    await tester.pumpAndSettle();

    expect(find.byType(WindowBar), findsNothing);
    expect(prefs.getBool('oamp.window.showTitleBar'), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

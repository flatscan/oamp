import 'package:flutter/material.dart';
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
import 'package:oamp/ui/window_mode.dart';
import 'package:window_manager/window_manager.dart';

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

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('oamp/window'), (
          call,
        ) async {
          windowCalls.add(call);
          return null;
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
    final panelButton = tester.getRect(buttons.last);
    expect(panelButton.right, 1160 - ModeSwitchButton.inset);
    // Every page in the panel has it in exactly the same spot.
    Future<void> expectPanelButtonAfterTapping(Finder target) async {
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(tester.getRect(buttons.last), panelButton);
    }

    await expectPanelButtonAfterTapping(find.text('Library'));
    await expectPanelButtonAfterTapping(find.text('Artists'));
    await expectPanelButtonAfterTapping(find.text('Air').first);
    await expectPanelButtonAfterTapping(find.text('Search'));
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

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

    // Every page's top bar now moves the window: Settings itself, and the
    // Library tab.
    Finder dragInAppBar() => find.descendant(
      of: find.byType(SliverAppBar),
      matching: find.byType(DragToMoveArea),
    );
    expect(dragInAppBar(), findsOneWidget);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(dragInAppBar(), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('size limits always contain the window at fractional scaling', (
    tester,
  ) async {
    // 125% scaling: the content is 550 physical px (440 logical) and the
    // runner reports a 568 px window (454.4 logical), a fractional frame.
    final widths = <double>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('oamp/window'), (
        call,
      ) async {
        windowCalls.add(call);
        if (call.method == 'setWidth') widths.add(call.arguments as double);
        return call.method == 'setWidth' ? true : null;
      })
      ..setMockMethodCallHandler(const MethodChannel('window_manager'), (
        call,
      ) async {
        windowCalls.add(call);
        return switch (call.method) {
          'getBounds' => {'x': 0.0, 'y': 0.0, 'width': 454.4, 'height': 880.0},
          _ => null,
        };
      });
    tester.view.physicalSize = const Size(550, 1100);
    tester.view.devicePixelRatio = 1.25;
    addTearDown(tester.view.reset);

    await FlyoutController.lockToColumn();

    Map<Object?, Object?> args(String method) =>
        windowCalls.lastWhere((c) => c.method == method).arguments as Map;
    final width = widths.single;
    expect(width, closeTo(454.4, 1e-9));
    // window_manager truncates limits to whole logical pixels before
    // scaling, so check them the way it applies them.
    int applied(String method) =>
        ((args(method)['width'] as double).truncate() * 1.25).truncate();
    final physical = (width * 1.25).round();
    expect(applied('setMaximumSize'), greaterThanOrEqualTo(physical));
    expect(applied('setMinimumSize'), lessThanOrEqualTo(physical));
    // The width was set natively, so the height was never touched.
    expect(windowCalls.where((c) => c.method == 'setBounds'), isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

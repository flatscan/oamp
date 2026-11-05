import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/main.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/ui/browse/home_view.dart';
import 'package:oamp/ui/browser.dart';
import 'package:oamp/ui/glyphs.dart';
import 'package:oamp/ui/jump_bar.dart';
import 'package:oamp/ui/login_screen.dart';
import 'package:oamp/ui/player/controls.dart';
import 'package:oamp/ui/player/mini_player.dart';
import 'package:oamp/ui/player/now_playing.dart';

import 'fakes/fakes.dart';

/// The app on a phone (tests run as Android): edge to edge under the system
/// bars, the back button, the keyboard and landscape.
void main() {
  late FakeAudioEngine engine;

  // A typical phone in logical pixels, with a status bar, a gesture
  // navigation bar and the side strips the back gesture claims.
  const statusBar = 24.0;
  const navBar = 16.0;
  const gestureEdge = 30.0;

  Future<void> pumpPhone(
    WidgetTester tester, {
    Size size = const Size(393, 851),
    double statusBarHeight = statusBar,
    FakeMusicSource? source,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final bars = FakeViewPadding(top: statusBarHeight, bottom: navBar);
    tester.view.padding = bars;
    tester.view.viewPadding = bars;
    tester.view.systemGestureInsets = const FakeViewPadding(
      left: gestureEdge,
      right: gestureEdge,
    );
    addTearDown(tester.view.reset);
    engine = FakeAudioEngine();
    source ??= FakeMusicSource();
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

  Future<void> playAlbumFromLibrary(WidgetTester tester) async {
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
  }

  bool nowPlayingUp(WidgetTester tester) =>
      find.text('UP NEXT').hitTestable().evaluate().isNotEmpty;

  /// Presses the system back button. True if the app handled it rather
  /// than closing.
  Future<bool> pressBack(WidgetTester tester) async {
    var exited = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') exited = true;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    return !exited;
  }

  testWidgets('pages clear the status bar and the tab bar the nav bar', (
    tester,
  ) async {
    // Enough artists for the A-Z bar.
    await pumpPhone(
      tester,
      source: FakeMusicSource(
        artists: [
          FakeMusicSource.air,
          for (var i = 0; i < 40; i++) Artist(id: 'x$i', name: 'Band $i'),
        ],
      ),
    );

    // Home's title sits below the status bar.
    expect(
      tester.getTopLeft(find.text('Home').first).dy,
      greaterThan(statusBar),
    );
    // The tab bar ends at the bottom of the screen, its labels above the
    // gesture bar.
    expect(tester.getBottomLeft(find.byType(NavigationBar)).dy, 851);
    expect(
      tester.getBottomLeft(find.text('Search').last).dy,
      lessThan(851 - navBar),
    );

    // A library page's top bar also starts below the status bar.
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    final bar = find.byType(AppBar).last;
    expect(tester.getTopLeft(bar).dy, 0);
    expect(
      tester.getTopLeft(find.text('Artists').last).dy,
      greaterThan(statusBar),
    );

    // The A-Z bar starts below the top bar and keeps clear of the strip
    // along the right edge where a swipe means back.
    final jump = tester.getRect(find.byType(JumpBar));
    expect(jump.top, greaterThan(statusBar + kToolbarHeight));
    expect(jump.right, lessThanOrEqualTo(393 - gestureEdge));
  });

  testWidgets('now playing runs under the status bar with Close below it', (
    tester,
  ) async {
    await pumpPhone(tester);
    await playAlbumFromLibrary(tester);
    await tester.tap(find.text('La femme d’argent').last);
    await tester.pumpAndSettle();
    expect(nowPlayingUp(tester), isTrue);

    // The cover starts at the very top, under the status bar ...
    final cover = find.descendant(
      of: find.byType(NowPlayingView),
      matching: find.byType(ClipRRect),
    );
    expect(tester.getTopLeft(cover.first).dy, 0);
    // ... and the Close button is below the bar.
    expect(
      tester.getTopLeft(find.byTooltip('Close')).dy,
      greaterThan(statusBar),
    );

    // Phones set the volume with their own buttons.
    expect(find.byType(VolumeControl), findsNothing);

    // Each rating star is big enough to tap.
    final star = find.ancestor(
      of: find.byKey(const ValueKey('star1')),
      matching: find.byType(GestureDetector),
    );
    final box = tester.getSize(star.first);
    expect(box.width, greaterThanOrEqualTo(40));
    expect(box.height, greaterThanOrEqualTo(40));
    expect(find.byType(StarGlyph), findsNWidgets(5));
  });

  testWidgets('back closes now playing, then pages, then tabs, then exits', (
    tester,
  ) async {
    await pumpPhone(tester);
    await playAlbumFromLibrary(tester);
    await tester.tap(find.text('La femme d’argent').last);
    await tester.pumpAndSettle();
    expect(nowPlayingUp(tester), isTrue);

    // Now playing closes, back to the album page.
    expect(await pressBack(tester), isTrue);
    expect(nowPlayingUp(tester), isFalse);
    expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);

    // Then back through the library pages: the artist list, then Library.
    expect(await pressBack(tester), isTrue);
    expect(find.widgetWithText(FilledButton, 'Play'), findsNothing);
    expect(find.text('1 album').hitTestable(), findsOneWidget);
    expect(await pressBack(tester), isTrue);
    expect(find.text('Liked artists').hitTestable(), findsOneWidget);

    // From another tab's first page, back goes Home ...
    expect(await pressBack(tester), isTrue);
    expect(find.byType(HomeView).hitTestable(), findsOneWidget);
    expect(tester.state<BrowserState>(find.byType(Browser)).mounted, isTrue);

    // ... and from Home it leaves the app.
    expect(await pressBack(tester), isFalse);
  });

  testWidgets('back from search returns Home', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField).hitTestable(), findsOneWidget);

    expect(await pressBack(tester), isTrue);
    expect(find.byType(HomeView).hitTestable(), findsOneWidget);
  });

  testWidgets('the tab bar and mini-player step aside for the keyboard', (
    tester,
  ) async {
    await pumpPhone(tester);
    await tester.tap(find.text('Shuffle library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget); // mini-player

    // The keyboard comes up over the bottom of the screen.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.view.padding = const FakeViewPadding(top: statusBar);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byTooltip('Pause'), findsNothing);
    // The search page fills the room above it, without shrinking twice.
    final results = tester.getRect(
      find
          .ancestor(
            of: find.byType(TextField),
            matching: find.byType(CustomScrollView),
          )
          .first,
    );
    expect(results.bottom, 851 - 300);

    // Keyboard away: both come back.
    tester.view.resetViewInsets();
    tester.view.padding = const FakeViewPadding(top: statusBar, bottom: navBar);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  testWidgets('long-pressing the top search result opens its menu', (
    tester,
  ) async {
    await pumpPhone(tester);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sexy boy');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Track · Air'));
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);
    expect(engine.playing, isFalse);
  });

  testWidgets('landscape fills the screen, clear of the cutout', (
    tester,
  ) async {
    await pumpPhone(tester, size: const Size(851, 393), statusBarHeight: 0);
    tester.view.padding = const FakeViewPadding(left: 32, bottom: navBar);
    tester.view.viewPadding = const FakeViewPadding(left: 32, bottom: navBar);
    await tester.pumpAndSettle();

    // No empty desktop side panel: the tabs span the screen past the cutout.
    final tabs = tester.getRect(find.byType(NavigationBar));
    expect(tabs.left, 32);
    expect(tabs.right, 851);

    // Now playing's cover is short enough for the controls to show.
    await tester.tap(find.text('Shuffle library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();
    expect(find.byType(SeekBar).hitTestable(), findsOneWidget);
  });

  testWidgets('settings leave out the desktop window options', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    expect(find.text('Show title bar'), findsNothing);
    expect(find.byTooltip('Expanded view'), findsNothing);
  });

  testWidgets('sign-in clears the system bars and suits the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: statusBar, bottom: navBar);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginScreen())),
    );

    final url = tester.widget<TextField>(
      find.descendant(
        of: find.widgetWithText(TextFormField, 'Server URL'),
        matching: find.byType(TextField),
      ),
    );
    expect(url.keyboardType, TextInputType.url);
    expect(url.autocorrect, isFalse);

    // With the keyboard up the form scrolls in the room left above it.
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(SingleChildScrollView)).bottom,
      lessThanOrEqualTo(851 - 320),
    );
  });

  testWidgets('desktop keeps its volume slider', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPhone(tester, size: const Size(440, 900), statusBarHeight: 0);
    await tester.tap(find.text('Shuffle library'));
    await tester.pumpAndSettle();
    await tester.fling(find.byTooltip('Pause'), const Offset(0, -200), 1000);
    await tester.pumpAndSettle();
    expect(find.byType(VolumeControl), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}

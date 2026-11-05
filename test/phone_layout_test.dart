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

  /// Swipes back from the left edge, as Android's predictive back gesture
  /// reports it.
  Future<void> swipeBack(WidgetTester tester) async {
    Future<void> send(String method, [Object? args]) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.backGesture.name,
          SystemChannels.backGesture.codec.encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) {},
        );
    Map<String, Object?> at(double progress) => {
      'touchOffset': [4.0, 400.0],
      'progress': progress,
      'swipeEdge': 0,
    };
    await send('startBackGesture', at(0));
    await tester.pump();
    await send('updateBackGestureProgress', at(0.5));
    await tester.pump();
    await send('commitBackGesture');
    await tester.pumpAndSettle();
  }

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
    // The status bar's inset doesn't push the tab icons down: the tab bar
    // is only the icons, labels and the gesture bar.
    expect(
      tester.getTopLeft(find.byIcon(Icons.search_rounded).last).dy -
          tester.getTopLeft(find.byType(NavigationBar)).dy,
      lessThan(16),
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

  testWidgets('now playing runs under the status bar', (tester) async {
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
    // ... with no Close button: a pull down or back closes it.
    expect(find.byTooltip('Close'), findsNothing);

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

  testWidgets('the back gesture closes now playing before the page', (
    tester,
  ) async {
    await pumpPhone(tester);
    await playAlbumFromLibrary(tester);
    await tester.tap(find.text('La femme d’argent').last);
    await tester.pumpAndSettle();
    expect(nowPlayingUp(tester), isTrue);

    // Now playing closes; the album page under it stays.
    await swipeBack(tester);
    expect(nowPlayingUp(tester), isFalse);
    expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);

    // With now playing closed, the gesture goes back a page.
    await swipeBack(tester);
    expect(find.widgetWithText(FilledButton, 'Play'), findsNothing);
    expect(find.text('1 album').hitTestable(), findsOneWidget);
  });

  testWidgets('pulling now playing down closes it', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.text('Shuffle library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();
    expect(nowPlayingUp(tester), isTrue);

    // A short, slow pull settles back up.
    final art =
        tester.getCenter(find.byType(NowPlayingView)) - const Offset(0, 250);
    var g = await tester.startGesture(art);
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The sheet follows the finger.
    expect(tester.getTopLeft(find.byType(NowPlayingView)).dy, greaterThan(60));
    await tester.pump(const Duration(milliseconds: 300));
    await g.up();
    await tester.pumpAndSettle();
    expect(nowPlayingUp(tester), isTrue);
    expect(tester.getTopLeft(find.byType(NowPlayingView)).dy, 0);

    // A longer pull closes it, back to Home with the mini-player.
    g = await tester.startGesture(art);
    for (var i = 0; i < 15; i++) {
      await g.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(nowPlayingUp(tester), isFalse);
    expect(find.byType(MiniPlayer).hitTestable(), findsOneWidget);
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

    // Now playing puts the cover on the left and the controls beside it,
    // all on screen at once.
    await tester.tap(find.text('Shuffle library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();
    final cover = tester.getRect(
      find
          .descendant(
            of: find.byType(NowPlayingView),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(cover.height, closeTo(393, 1));
    expect(cover.left, 32);
    final seek = tester.getRect(find.byType(SeekBar));
    expect(seek.left, greaterThanOrEqualTo(cover.right));
    expect(find.byType(TransportControls).hitTestable(), findsOneWidget);
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

  testWidgets('desktop keeps its volume slider and close arrow', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPhone(tester, size: const Size(440, 900), statusBarHeight: 0);
    await tester.tap(find.text('Shuffle library'));
    await tester.pumpAndSettle();
    await tester.fling(find.byTooltip('Pause'), const Offset(0, -200), 1000);
    await tester.pumpAndSettle();
    expect(find.byType(VolumeControl), findsOneWidget);

    // Desktop keeps the close arrow over the artwork.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('UP NEXT').hitTestable(), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}

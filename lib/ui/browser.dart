import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browse/home_view.dart';
import 'browse/library_view.dart';
import 'browse/search_view.dart';
import 'player/now_playing.dart';
import 'window_mode.dart';

enum BrowserTab { home, library, search }

/// The browsing side of the app: Home, Library and Search tabs, each with
/// its own page history, and the tab bar along the bottom.
///
/// There is one browser for the app's lifetime ([globalKey]), so moving it between
/// the single column and the desktop fly-out keeps every tab's history.
/// [footer] sits between the pages and the tab bar; the single column puts
/// the mini-player there.
///
/// The system back button (and back gesture) steps back through the app
/// before leaving it: it closes now playing, then goes back a page in the
/// current tab, then returns to Home from another tab.
///
/// On a phone the mini-player and tab bar step aside while the keyboard is
/// up, so the page being typed into keeps the room above the keyboard.
class Browser extends ConsumerStatefulWidget {
  final Widget? footer;

  /// Whether the on-screen keyboard is up, which hides [footer] and the tab
  /// bar. The shell passes it in, since its Scaffold takes the keyboard out
  /// of the MediaQuery the browser sees.
  final bool keyboardUp;

  const Browser({
    required GlobalKey<BrowserState> super.key,
    this.footer,
    this.keyboardUp = false,
  });

  static final globalKey = GlobalKey<BrowserState>();

  @override
  ConsumerState<Browser> createState() => BrowserState();
}

/// Opens [page] in the current browser tab, closing the now playing screen
/// first if it is covering the browser.
void openPage(Widget page) => Browser.globalKey.currentState?.push(page);

class BrowserState extends ConsumerState<Browser> {
  BrowserTab _tab = BrowserTab.home;
  final _navKeys = {
    for (final t in BrowserTab.values) t: GlobalKey<NavigatorState>(),
  };
  final searchFocus = FocusNode(debugLabel: 'search');

  NavigatorState? get _nav => _navKeys[_tab]!.currentState;

  @override
  void dispose() {
    searchFocus.dispose();
    super.dispose();
  }

  void push(Widget page) {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    hideNowPlaying(context);
    _nav?.push(MaterialPageRoute<void>(builder: (_) => _SheetGuard(page)));
  }

  /// Switches tab. Choosing the tab that is already showing goes back to
  /// its first page.
  void select(BrowserTab tab) {
    if (tab == _tab) {
      _nav?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = tab);
    }
    if (tab == BrowserTab.search) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => searchFocus.requestFocus(),
      );
    }
  }

  Widget _tabNavigator(BrowserTab tab, Widget root) => Offstage(
    offstage: tab != _tab,
    child: TickerMode(
      enabled: tab == _tab,
      child: HeroControllerScope.none(
        child: Navigator(
          key: _navKeys[tab],
          onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => root),
        ),
      ),
    ),
  );

  /// Whether now playing is covering the browser in the single column.
  bool get _sheetOpen =>
      ref.read(nowPlayingSheetProvider).open && !ref.read(flyoutOpenProvider);

  /// Whether a back press has something to do inside the app.
  bool get _canGoBack =>
      _sheetOpen || (_nav?.canPop() ?? false) || _tab != BrowserTab.home;

  /// One step back: see [Browser].
  void _goBack() {
    if (_sheetOpen) {
      hideNowPlaying(context);
    } else if (_nav?.canPop() ?? false) {
      _nav!.maybePop();
    } else if (_tab != BrowserTab.home) {
      select(BrowserTab.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild so the back handling below sees the sheet open or close.
    ref.watch(nowPlayingSheetProvider.select((s) => s.open));
    ref.watch(flyoutOpenProvider);
    final typing = widget.keyboardUp;
    final pages = Stack(
      fit: StackFit.expand,
      children: [
        _tabNavigator(BrowserTab.home, const HomeView()),
        _tabNavigator(BrowserTab.library, const LibraryView()),
        _tabNavigator(BrowserTab.search, SearchView(focusNode: searchFocus)),
      ],
    );
    return Column(
      children: [
        Expanded(
          child: PopScope(
            canPop: !_canGoBack,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _goBack();
            },
            // A page pushed or popped in a tab changes what back does.
            child: NotificationListener<NavigationNotification>(
              onNotification: (_) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
                return false;
              },
              // The mouse's back button goes back, as in a browser.
              child: Listener(
                onPointerDown: (e) {
                  if (e.buttons & kBackMouseButton != 0) _nav?.maybePop();
                },
                // The shell's Scaffold has already shrunk the column for
                // the keyboard, so pages must not shrink again; and the tab
                // bar below pads for the navigation bar.
                child: MediaQuery.removeViewInsets(
                  context: context,
                  removeBottom: true,
                  child: typing
                      ? pages
                      : MediaQuery.removePadding(
                          context: context,
                          removeBottom: true,
                          child: pages,
                        ),
                ),
              ),
            ),
          ),
        ),
        if (!typing) ...[
          ?widget.footer,
          // NavigationBar keeps clear of every system inset, the status bar
          // included, which put a status bar's height of empty space above
          // the tabs on phones. It only needs the bottom one.
          MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: NavigationBar(
              selectedIndex: _tab.index,
              onDestinationSelected: (i) => select(BrowserTab.values[i]),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music_rounded),
                  label: 'Library',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search_rounded),
                  selectedIcon: Icon(Icons.manage_search_rounded),
                  label: 'Search',
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Keeps a library page from taking Android's back gesture while now
/// playing covers it. Each page claims the gesture for its own slide-back
/// animation, which would pop the page out of sight under now playing;
/// while the sheet is up, the browser's back handling closes it instead.
class _SheetGuard extends ConsumerWidget {
  final Widget child;
  const _SheetGuard(this.child);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final covered =
        ref.watch(nowPlayingSheetProvider.select((s) => s.open)) &&
        !ref.watch(flyoutOpenProvider);
    return PopScope(canPop: !covered, child: child);
  }
}

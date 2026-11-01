import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'browse/home_view.dart';
import 'browse/library_view.dart';
import 'browse/search_view.dart';
import 'player/now_playing.dart';

enum BrowserTab { home, library, search }

/// The browsing side of the app: Home, Library and Search tabs, each with
/// its own page history, and the tab bar along the bottom.
///
/// There is one browser for the app's lifetime ([globalKey]), so moving it between
/// the single column and the desktop fly-out keeps every tab's history.
/// [footer] sits between the pages and the tab bar; the single column puts
/// the mini-player there.
class Browser extends StatefulWidget {
  final Widget? footer;
  const Browser({required GlobalKey<BrowserState> super.key, this.footer});

  static final globalKey = GlobalKey<BrowserState>();

  @override
  State<Browser> createState() => BrowserState();
}

/// Opens [page] in the current browser tab, closing the now playing screen
/// first if it is covering the browser.
void openPage(Widget page) => Browser.globalKey.currentState?.push(page);

class BrowserState extends State<Browser> {
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
    _nav?.push(MaterialPageRoute<void>(builder: (_) => page));
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: NavigatorPopHandler(
            onPopWithResult: (_) => _nav?.maybePop(),
            // The mouse's back button goes back, as in a browser.
            child: Listener(
              onPointerDown: (e) {
                if (e.buttons & kBackMouseButton != 0) _nav?.maybePop();
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _tabNavigator(BrowserTab.home, const HomeView()),
                  _tabNavigator(BrowserTab.library, const LibraryView()),
                  _tabNavigator(
                    BrowserTab.search,
                    SearchView(focusNode: searchFocus),
                  ),
                ],
              ),
            ),
          ),
        ),
        ?widget.footer,
        NavigationBar(
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
      ],
    );
  }
}

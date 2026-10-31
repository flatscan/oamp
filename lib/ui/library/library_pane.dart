import 'package:flutter/material.dart';

import 'albums_view.dart';
import 'artists_view.dart';

/// Library browser with its own nested navigator, so drilling into an artist
/// or album never covers the player or the queue.
class LibraryPane extends StatefulWidget {
  const LibraryPane({super.key});

  @override
  State<LibraryPane> createState() => _LibraryPaneState();
}

class _LibraryPaneState extends State<LibraryPane> {
  final _navKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return NavigatorPopHandler(
      onPopWithResult: (_) => _navKey.currentState?.maybePop(),
      child: Navigator(
        key: _navKey,
        onGenerateRoute: (_) =>
            MaterialPageRoute(builder: (_) => const _LibraryHome()),
      ),
    );
  }
}

class _LibraryHome extends StatelessWidget {
  const _LibraryHome();

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: 'Artists'),
              Tab(text: 'Albums'),
            ],
          ),
          Expanded(child: TabBarView(children: [ArtistsView(), AlbumsView()])),
        ],
      ),
    );
  }
}

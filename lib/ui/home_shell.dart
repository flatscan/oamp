import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser.dart';
import 'player/mini_player.dart';
import 'player/now_playing.dart';
import 'window_mode.dart';

/// Main screen: one column, the same on desktop as on a phone. Browsing
/// (Home, Library, Search) fills the column, a mini-player sits above the
/// tabs, and clicking it slides up the full now playing view.
///
/// On desktop the mode button on now playing switches to expanded mode: a
/// library panel opens to the right and the window widens. While it is
/// open, the column shows now playing permanently and browsing moves into
/// the panel.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(flyoutOpenProvider);
    final slideWidth = ref.watch(flyoutSlideWidthProvider);
    if (!expanded) {
      return Scaffold(
        body: Browser(key: Browser.globalKey, footer: const MiniPlayer()),
      );
    }
    // The column stays exactly one column wide and pinned left in every
    // state, including while the window is growing or shrinking, so now
    // playing never moves or resizes.
    return Scaffold(
      body: Row(
        children: [
          const SizedBox(
            width: FlyoutController.columnWidth,
            child: NowPlayingView(),
          ),
          Expanded(
            child: FlyoutSlide(
              width: slideWidth,
              child: Row(
                children: [
                  const VerticalDivider(width: 1),
                  Expanded(child: Browser(key: Browser.globalKey)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

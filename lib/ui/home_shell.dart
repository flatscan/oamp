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
    final flyout = ref.watch(flyoutOpenProvider);
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, c) {
          // Fall back to the single column if the window is too narrow to
          // fit the fly-out (e.g. while it is still resizing).
          if (flyout && c.maxWidth >= FlyoutController.columnWidth + 360) {
            return Row(
              children: [
                const SizedBox(
                  width: FlyoutController.columnWidth,
                  child: NowPlayingView(),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: Browser(key: Browser.globalKey)),
              ],
            );
          }
          return Browser(key: Browser.globalKey, footer: const MiniPlayer());
        },
      ),
    );
  }
}

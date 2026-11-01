import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/platform_info.dart';
import 'browser.dart';
import 'player/mini_player.dart';
import 'player/now_playing.dart';

/// Whether the desktop library fly-out is open.
final flyoutOpenProvider = NotifierProvider<FlyoutController, bool>(
  FlyoutController.new,
);

class FlyoutController extends Notifier<bool> {
  static const columnWidth = 420.0;
  static const flyoutWidth = 720.0;

  @override
  bool build() => false;

  /// Opens or closes the fly-out, growing or shrinking the window by its
  /// width unless the window is maximised, in which case the existing space
  /// is reused.
  Future<void> toggle() async {
    final open = !state;
    state = open;
    if (!isDesktop) return;
    if (await windowManager.isMaximized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    final size = await windowManager.getSize();
    final width = open
        ? size.width + flyoutWidth
        : (size.width - flyoutWidth).clamp(360.0, double.infinity);
    await windowManager.setSize(Size(width, size.height), animate: true);
  }
}

/// Main screen: one column, the same on desktop as on a phone. Browsing
/// (Home, Library, Search) fills the column, a mini-player sits above the
/// tabs, and clicking it slides up the full now playing view.
///
/// On desktop the fly-out toggle in the window bar opens a library panel to
/// the right and widens the window. While it is open, the column shows now
/// playing permanently and browsing moves into the panel.
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

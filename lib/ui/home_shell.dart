import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser.dart';
import 'player/mini_player.dart';
import 'player/now_playing.dart';
import 'window_mode.dart';

/// Main screen: one column, the same on desktop as on a phone. Browsing
/// (Home, Library, Search) fills the column, a mini-player sits above the
/// tabs, and clicking it slides up the full now playing view over them.
///
/// On desktop the mode button on now playing switches to expanded mode: a
/// library panel opens to the right and the window widens. While it is
/// open, the column shows now playing permanently and browsing moves into
/// the panel.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with SingleTickerProviderStateMixin {
  /// Now playing is one widget for the shell's lifetime. It moves between
  /// the single column's sheet and the expanded column, so switching modes
  /// never rebuilds it: no reload, no flicker, same scroll position.
  final _nowPlayingKey = GlobalKey(debugLabel: 'now playing');

  late final _sheet = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 260),
  );

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  void _close() => ref.read(nowPlayingSheetProvider.notifier).close();

  @override
  Widget build(BuildContext context) {
    ref.listen(nowPlayingSheetProvider, (_, next) {
      if (!next.animate) {
        _sheet.value = next.open ? 1 : 0;
      } else if (next.open) {
        _sheet.forward();
      } else {
        _sheet.reverse();
      }
    });
    final expanded = ref.watch(flyoutOpenProvider);
    final reveal = ref.watch(flyoutRevealProvider);

    if (expanded) {
      // The column stays exactly one column wide and pinned left in every
      // state, so now playing never moves or resizes.
      return Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: FlyoutController.columnWidth,
              child: NowPlayingView(key: _nowPlayingKey),
            ),
            Expanded(
              child: FlyoutSlide(
                reveal: reveal,
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

    final browser = Browser(key: Browser.globalKey, footer: const MiniPlayer());
    return Scaffold(
      body: AnimatedBuilder(
        animation: _sheet,
        builder: (context, _) {
          if (_sheet.isDismissed) return browser;
          return Stack(
            fit: StackFit.expand,
            children: [
              // The browser is fully covered once the sheet is up.
              Offstage(offstage: _sheet.isCompleted, child: browser),
              SlideTransition(
                position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                    .animate(
                      CurvedAnimation(
                        parent: _sheet,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInCubic,
                      ),
                    ),
                child: NowPlayingView(key: _nowPlayingKey, onClose: _close),
              ),
            ],
          );
        },
      ),
    );
  }
}

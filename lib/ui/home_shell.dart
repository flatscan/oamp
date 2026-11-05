import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform_info.dart';
import '../state/session.dart';
import 'browser.dart';
import 'player/mini_player.dart';
import 'player/now_playing.dart';
import 'server_banner.dart';
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

  /// The column is one column wide, pinned left, so now playing keeps its
  /// size and place while the window grows or shrinks around it. Once the
  /// window is back to about one column in single-column mode, the column
  /// fills it, so a window a pixel or two off one column wide still has
  /// everything centred with no strip at the edge.
  ///
  /// Phones and tablets have no window to fit, so the column is the whole
  /// screen in either orientation.
  static double _columnWidth(bool expanded, double available) {
    if (!isDesktop) return available;
    const column = FlyoutController.columnWidth;
    if (!expanded && available < column + 64) return available;
    return available < column ? available : column;
  }

  void _close() => ref.read(nowPlayingSheetProvider.notifier).close();

  /// Height of the column, for turning a finger's pull into sheet travel.
  double _height = 1;

  /// Whether the sheet is following a finger (or settling after one), when
  /// it moves in step with the finger instead of on its usual curve.
  bool _dragged = false;

  @override
  void initState() {
    super.initState();
    _sheet.addStatusListener((status) {
      if (status.isCompleted || status.isDismissed) _dragged = false;
    });
  }

  void _pull(double dy) {
    _dragged = true;
    _sheet.value = (_sheet.value - dy / _height).clamp(0.0, 1.0);
  }

  /// Let go: close if pulled a quarter of the way or flicked down, else
  /// settle back up.
  void _pullEnd(double velocity) {
    if (_sheet.value < 0.75 || velocity > 700) {
      _close();
    } else {
      _sheet.animateTo(
        1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(nowPlayingSheetProvider, (_, next) {
      if (!next.animate) {
        _sheet.value = next.open ? 1 : 0;
      } else if (!next.open && _dragged) {
        // Carry on from where the finger let go.
        _sheet.animateBack(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else if (next.open) {
        _sheet.forward();
      } else {
        _sheet.reverse();
      }
    });
    final expanded = ref.watch(flyoutOpenProvider);
    final reveal = ref.watch(flyoutRevealProvider);

    // One layout for both modes, so switching never rebuilds or moves now
    // playing: a column exactly one column wide pinned left, and a panel
    // that takes whatever width the window adds. In single-column mode the
    // panel is empty and the window is one column wide; in expanded mode
    // the browser slides out into it and now playing stays up in the
    // column.
    final browser = Browser(
      key: Browser.globalKey,
      footer: expanded ? null : const MiniPlayer(),
      keyboardUp: !isDesktop && MediaQuery.viewInsetsOf(context).bottom > 0,
    );
    final sheet = expanded ? kAlwaysCompleteAnimation : _sheet;
    final banner = ServerStatusBanner.visibleFor(
      ref.watch(serverStatusProvider),
    );
    // Edge to edge on a phone: the banner (when shown) or each page pads
    // for the status bar, the tab bar for the navigation bar, and the sides
    // keep clear of a landscape cutout or navigation bar.
    return Scaffold(
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            const ServerStatusBanner(),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: banner,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _height = constraints.maxHeight;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: _columnWidth(expanded, constraints.maxWidth),
                          child: AnimatedBuilder(
                            animation: sheet,
                            builder: (context, _) => Stack(
                              fit: StackFit.expand,
                              children: [
                                // Covered (and paused) while now playing is fully up.
                                Offstage(
                                  offstage: expanded || sheet.isCompleted,
                                  child: expanded
                                      ? const SizedBox.shrink()
                                      : browser,
                                ),
                                if (!sheet.isDismissed)
                                  SlideTransition(
                                    position:
                                        Tween(
                                          begin: const Offset(0, 1),
                                          end: Offset.zero,
                                        ).animate(
                                          _dragged
                                              ? sheet
                                              : CurvedAnimation(
                                                  parent: sheet,
                                                  curve: Curves.easeOutCubic,
                                                  reverseCurve:
                                                      Curves.easeInCubic,
                                                ),
                                        ),
                                    child: NowPlayingView(
                                      key: _nowPlayingKey,
                                      onClose: expanded ? null : _close,
                                      onPull: expanded || isDesktop
                                          ? null
                                          : _pull,
                                      onPullEnd: expanded || isDesktop
                                          ? null
                                          : _pullEnd,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: expanded
                              ? FlyoutSlide(
                                  reveal: reveal,
                                  child: Row(
                                    children: [
                                      const VerticalDivider(width: 1),
                                      Expanded(child: browser),
                                    ],
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

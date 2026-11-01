import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform_info.dart';
import 'theme.dart';
import 'window_mode.dart';

/// The switch between single-column and expanded mode.
///
/// It is always [size] square and placed [inset] from the top-right corner
/// of the column (on single-column Home, single-column now playing and the
/// expanded column), so switching back and forth never needs the mouse to
/// move. Expanded Home also has one at the fly-out's top-right.
///
/// [overArt] gives it the same dark circle as now playing's Close button,
/// so it stays visible on light album covers.
class ModeSwitchButton extends ConsumerWidget {
  final bool overArt;
  const ModeSwitchButton({super.key, this.overArt = false});

  static const size = 48.0;
  static const inset = 8.0;

  /// Height for a page's top bar so the mode switch in it lands exactly
  /// where it is on Home and over the now playing artwork.
  static double get toolbarHeight =>
      isDesktop ? size + 2 * inset : kToolbarHeight;

  /// A page's top bar actions followed by the mode switch, so every page
  /// has it in the same top-right spot.
  static List<Widget> withActions(List<Widget>? actions) => [
    ...?actions,
    if (isDesktop) ...const [ModeSwitchButton(), SizedBox(width: inset)],
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktop) return const SizedBox.shrink();
    final expanded = ref.watch(flyoutOpenProvider);
    final foreground = expanded
        ? oampAccent
        : (overArt ? Colors.white : OAmpColors.textMuted);
    final button = IconButton(
      tooltip: expanded ? 'Single column' : 'Expanded view',
      padding: EdgeInsets.zero,
      iconSize: 18,
      color: foreground,
      style: overArt
          ? IconButton.styleFrom(
              backgroundColor: Colors.black45,
              hoverColor: Colors.white24,
              // A circle the size of Close's, centred where the plain
              // button sits, so the click spot doesn't move.
              fixedSize: const Size.square(40),
              minimumSize: const Size.square(40),
            )
          : null,
      icon: Icon(
        expanded ? Icons.view_sidebar_rounded : Icons.view_sidebar_outlined,
      ),
      onPressed: () {
        final c = ref.read(flyoutOpenProvider.notifier);
        expanded ? c.collapse() : c.expand();
      },
    );
    return SizedBox.square(
      dimension: size,
      child: overArt ? Center(child: button) : button,
    );
  }
}

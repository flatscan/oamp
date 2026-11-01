import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform_info.dart';
import 'app_frame.dart';
import 'player/now_playing.dart';
import 'theme.dart';
import 'window_mode.dart';

/// The switch between single-column and expanded mode.
///
/// It is always [size] square and placed [inset] from the top-right corner
/// of the column (on single-column Home, single-column now playing and the
/// expanded column), so switching back and forth never needs the mouse to
/// move. Expanded Home also has one at the fly-out's top-right.
class ModeSwitchButton extends ConsumerWidget {
  const ModeSwitchButton({super.key});

  static const size = 48.0;
  static const inset = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktop) return const SizedBox.shrink();
    final expanded = ref.watch(flyoutOpenProvider);
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        tooltip: expanded ? 'Single column' : 'Expanded view',
        padding: EdgeInsets.zero,
        iconSize: 18,
        color: expanded ? oampAccent : OAmpColors.textMuted,
        icon: Icon(
          expanded ? Icons.view_sidebar_rounded : Icons.view_sidebar_outlined,
        ),
        onPressed: () async {
          final nav = rootNavigatorKey.currentState;
          if (expanded) {
            final resized = ref.read(flyoutOpenProvider.notifier).toggle();
            // Back in one column, carry on in now playing, which is what
            // the column was showing, rather than flashing Home first.
            final rootContext = rootNavigatorKey.currentContext;
            if (rootContext != null) {
              showNowPlaying(rootContext, animate: false);
            }
            await resized;
          } else {
            // Expanded mode shows now playing in the column, so a
            // full-screen copy goes away at once, without sliding down.
            final route = ModalRoute.of(context);
            if (nav != null && route != null && !route.isFirst) {
              nav.removeRoute(route);
            }
            await ref.read(flyoutOpenProvider.notifier).toggle();
          }
        },
      ),
    );
  }
}

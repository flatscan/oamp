import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/platform_info.dart';
import '../state/session.dart';
import 'library/library_pane.dart';
import 'player/now_playing.dart';
import 'player/queue_panel.dart';

/// Main screen: a Plexamp-style single column, the same on desktop as on a
/// phone: now playing / library / queue, with a draggable divider between
/// library and queue so the queue is always on screen.
///
/// On desktop a toggle opens a library fly-out to the right of the column and
/// widens the window to make room. While it is open, the column shows large
/// artwork and the queue, and library browsing moves into the fly-out.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  static const _columnWidth = 420.0;
  static const _flyoutWidth = 720.0;

  /// Fraction of the split area given to the queue in the column.
  double _queueFraction = 0.4;
  bool _flyoutOpen = false;

  Future<void> _toggleFlyout() async {
    final open = !_flyoutOpen;
    setState(() => _flyoutOpen = open);
    // Grow or shrink the window by the fly-out's width, unless the user has
    // maximised it, in which case the existing space is reused.
    if (await windowManager.isMaximized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    final size = await windowManager.getSize();
    final width = open
        ? size.width + _flyoutWidth
        : (size.width - _flyoutWidth).clamp(360.0, double.infinity);
    await windowManager.setSize(Size(width, size.height), animate: true);
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(musicSourceProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('OAmp'),
        actions: [
          if (isDesktop)
            IconButton(
              tooltip: _flyoutOpen
                  ? 'Close library panel'
                  : 'Open library panel',
              isSelected: _flyoutOpen,
              icon: const Icon(Icons.view_sidebar_outlined),
              selectedIcon: const Icon(Icons.view_sidebar),
              onPressed: _toggleFlyout,
            ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (v) {
              if (v == 'logout') ref.read(sessionProvider.notifier).logout();
            },
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text(source.displayName)),
              const PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          // Fall back to the single column if the window is too narrow to
          // fit the fly-out (e.g. while it is still resizing).
          if (_flyoutOpen && c.maxWidth >= _columnWidth + 360) {
            return _withFlyout();
          }
          return _column(c.maxHeight);
        },
      ),
    );
  }

  Widget _withFlyout() {
    return const Row(
      children: [
        SizedBox(
          width: _columnWidth,
          child: Column(
            children: [
              NowPlaying(),
              Divider(height: 1),
              Expanded(child: QueuePanel()),
            ],
          ),
        ),
        VerticalDivider(width: 1),
        Expanded(child: LibraryPane()),
      ],
    );
  }

  Widget _column(double height) {
    return Column(
      children: [
        const NowPlaying(compact: true),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final total = c.maxHeight;
              final queueH = (total * _queueFraction).clamp(
                120.0,
                total - 120.0,
              );
              return Column(
                children: [
                  const Expanded(child: LibraryPane()),
                  _SplitHandle(
                    onDrag: (dy) => setState(() {
                      _queueFraction = ((queueH - dy) / total).clamp(
                        0.15,
                        0.85,
                      );
                    }),
                  ),
                  SizedBox(height: queueH, child: const QueuePanel()),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SplitHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;
  const _SplitHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
        child: SizedBox(
          height: 14,
          child: Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

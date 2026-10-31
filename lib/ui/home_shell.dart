import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';
import 'library/library_pane.dart';
import 'player/now_playing.dart';
import 'player/queue_panel.dart';

/// Main screen: a Plexamp-style vertical column with the queue always on
/// screen.
///
/// Narrow (the default phone-shaped window, and phones):
///   now playing (compact) / library / queue, with a draggable divider
///   between library and queue.
/// Wide (900px+, e.g. a maximised desktop window):
///   library on the left, a player column (large artwork + queue) on the right.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// Fraction of the split area given to the queue in the narrow layout.
  double _queueFraction = 0.4;

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(clientProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('OAmp'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Account',
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (v) {
              if (v == 'logout') ref.read(sessionProvider.notifier).logout();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text(
                  '${client.credentials.username} @ ${client.credentials.baseUrl.host}',
                ),
              ),
              const PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= 900) return _wide();
          return _narrow(c.maxHeight);
        },
      ),
    );
  }

  Widget _wide() {
    return Row(
      children: [
        const Expanded(child: LibraryPane()),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 400,
          child: Column(
            children: const [
              NowPlaying(),
              Divider(height: 1),
              Expanded(child: QueuePanel()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _narrow(double height) {
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

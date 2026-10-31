import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/player.dart';
import '../cover_art.dart';

/// The play queue: tap to jump, drag to reorder, swipe or click to remove.
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playerProvider);
    final p = ref.read(playerProvider.notifier);
    final t = Theme.of(context).textTheme;
    final remaining = s.currentIndex == null
        ? s.queue.length
        : s.queue.length - s.currentIndex! - 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Text('Up next', style: t.titleSmall),
              const SizedBox(width: 8),
              if (s.queue.isNotEmpty)
                Text('$remaining of ${s.queue.length}', style: t.bodySmall),
              const Spacer(),
              IconButton(
                tooltip: 'Clear queue',
                onPressed: s.queue.isEmpty ? null : p.clear,
                icon: const Icon(Icons.clear_all),
              ),
            ],
          ),
        ),
        Expanded(
          child: s.queue.isEmpty
              ? Center(
                  child: Text(
                    'Queue is empty. Pick an album to start.',
                    style: t.bodySmall,
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: s.queue.length,
                  onReorderItem: p.move,
                  itemBuilder: (context, i) {
                    final track = s.queue[i];
                    final isCurrent = i == s.currentIndex;
                    final isPast =
                        s.currentIndex != null && i < s.currentIndex!;
                    // Key by position too: the same track can be queued twice.
                    return Dismissible(
                      key: ValueKey('q-$i-${track.id}'),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => p.removeAt(i),
                      background: Container(
                        color: Theme.of(context).colorScheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: const Icon(Icons.delete_outline),
                      ),
                      child: Opacity(
                        opacity: isPast ? 0.5 : 1,
                        child: ListTile(
                          selected: isCurrent,
                          leading: CoverArt(track.coverArt, size: 40),
                          title: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            track.artist ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isCurrent)
                                Icon(
                                  s.playing ? Icons.volume_up : Icons.pause,
                                  size: 18,
                                ),
                              IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => p.removeAt(i),
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(Icons.drag_handle),
                                ),
                              ),
                            ],
                          ),
                          onTap: () => p.jumpTo(i),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

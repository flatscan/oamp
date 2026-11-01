import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/player.dart';
import '../cover_art.dart';
import '../theme.dart';

/// What plays after the current track: tap to jump, drag to reorder, swipe
/// or click to remove.
class QueueView extends ConsumerWidget {
  const QueueView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playerProvider);
    final p = ref.read(playerProvider.notifier);
    final t = Theme.of(context).textTheme;
    final first = (s.currentIndex ?? -1) + 1;
    final upcoming = s.upcoming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 0, 4),
          child: Row(
            children: [
              Text('Up next', style: t.titleLarge),
              const SizedBox(width: 10),
              if (upcoming.isNotEmpty)
                Text(
                  '${upcoming.length} track${upcoming.length == 1 ? '' : 's'}',
                  style: t.bodySmall,
                ),
              const Spacer(),
              if (upcoming.isNotEmpty)
                TextButton(
                  onPressed: p.clearUpcoming,
                  style: TextButton.styleFrom(
                    foregroundColor: OAmpColors.textMuted,
                  ),
                  child: const Text('Clear'),
                ),
            ],
          ),
        ),
        Expanded(
          child: upcoming.isEmpty
              ? Center(
                  child: Text(
                    s.queue.isEmpty
                        ? 'Queue is empty. Pick an album to start.'
                        : 'Nothing queued after this track.',
                    style: t.bodySmall,
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: upcoming.length,
                  onReorderItem: (from, to) => p.move(first + from, first + to),
                  itemBuilder: (context, i) {
                    final track = upcoming[i];
                    final index = first + i;
                    // Key by position too: the same track can be queued twice.
                    return Dismissible(
                      key: ValueKey('q-$index-${track.id}'),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => p.removeAt(index),
                      background: Container(
                        color: Theme.of(context).colorScheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: const Icon(Icons.delete_outline),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.only(left: 8),
                        leading: CoverArt(track.coverArt, size: 42, radius: 4),
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          track.artist ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Remove',
                              color: OAmpColors.textFaint,
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => p.removeAt(index),
                            ),
                            ReorderableDragStartListener(
                              index: i,
                              child: const MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.drag_handle_rounded,
                                    color: OAmpColors.textFaint,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        onTap: () => p.jumpTo(index),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

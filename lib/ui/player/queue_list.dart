import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/player.dart';
import '../cover_art.dart';
import '../playlist_dialogs.dart';
import '../theme.dart';
import '../widgets.dart';

enum _QueueTab { earlier, upNext }

/// The queue under the now playing controls, as slivers so it scrolls with
/// them: tabs for what already played and what plays next.
///
/// Up next: click to jump, drag the handle to reorder, swipe or click × to
/// remove. Earlier: click to play a track again.
class QueueSlivers extends ConsumerStatefulWidget {
  const QueueSlivers({super.key});

  @override
  ConsumerState<QueueSlivers> createState() => _QueueSliversState();
}

class _QueueSliversState extends ConsumerState<QueueSlivers> {
  _QueueTab _tab = _QueueTab.upNext;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(playerProvider);
    final p = ref.read(playerProvider.notifier);
    final t = Theme.of(context).textTheme;
    final first = (s.currentIndex ?? -1) + 1;
    final earlier = s.currentIndex == null
        ? const <Track>[]
        : s.queue.sublist(0, s.currentIndex);
    final upcoming = s.upcoming;
    final list = _tab == _QueueTab.upNext ? upcoming : earlier;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          Row(
            children: [
              for (final (tab, label) in [
                (_QueueTab.earlier, 'EARLIER'),
                (_QueueTab.upNext, 'UP NEXT'),
              ])
                Expanded(
                  child: _TabLabel(
                    label: label,
                    selected: _tab == tab,
                    onTap: () => setState(() => _tab = tab),
                  ),
                ),
            ],
          ),
          const Divider(height: 1),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      if (s.from != null) 'Playing from ${s.from}',
                      if (list.isNotEmpty)
                        '${list.length} track${list.length == 1 ? '' : 's'}',
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall,
                  ),
                ),
                if (s.queue.isNotEmpty)
                  TextButton(
                    onPressed: () => createPlaylist(context, ref, s.queue),
                    style: TextButton.styleFrom(
                      foregroundColor: OAmpColors.textMuted,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Save as playlist'),
                  ),
                if (_tab == _QueueTab.upNext && upcoming.isNotEmpty)
                  TextButton(
                    onPressed: p.clearUpcoming,
                    style: TextButton.styleFrom(
                      foregroundColor: OAmpColors.textMuted,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Clear'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    final Widget body;
    if (list.isEmpty) {
      body = SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            s.queue.isEmpty
                ? 'Queue is empty. Pick an album to start.'
                : _tab == _QueueTab.upNext
                ? 'Nothing queued after this track.'
                : 'Nothing has played yet.',
            textAlign: TextAlign.center,
            style: t.bodySmall,
          ),
        ),
      );
    } else if (_tab == _QueueTab.earlier) {
      body = SliverList.builder(
        itemCount: earlier.length,
        itemBuilder: (_, i) =>
            _QueueRow(track: earlier[i], faded: true, onTap: () => p.jumpTo(i)),
      );
    } else {
      body = SliverReorderableList(
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
            child: _QueueRow(
              track: track,
              onTap: () => p.jumpTo(index),
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
            ),
          );
        },
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: header),
        body,
      ],
    );
  }
}

class _TabLabel extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabLabel({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: selected ? Colors.white : OAmpColors.textFaint,
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends ConsumerWidget {
  final Track track;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool faded;
  const _QueueRow({
    required this.track,
    required this.onTap,
    this.trailing,
    this.faded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return Opacity(
      opacity: faded ? 0.6 : 1,
      child: GestureDetector(
        onSecondaryTapUp: (d) =>
            showTrackMenu(context, ref, track, at: d.globalPosition),
        child: ListTile(
          onTap: onTap,
          onLongPress: () => showTrackMenu(context, ref, track),
          leading: CoverArt(track.coverArt, size: 44, radius: 4),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            track.artist ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.bodySmall,
          ),
          trailing: trailing,
        ),
      ),
    );
  }
}

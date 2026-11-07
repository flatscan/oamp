import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/endless_play.dart';
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
/// remove. Below it, a row of endless play modes picks what happens when the
/// queue runs out. Earlier: click to play a track again.
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
        itemBuilder: (_, i) => _QueueRow(
          track: earlier[i],
          faded: true,
          endless: s.isEndless(earlier[i]),
          onTap: () => p.jumpTo(i),
        ),
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
              endless: s.isEndless(track),
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
        if (_tab == _QueueTab.upNext && s.queue.isNotEmpty)
          const SliverToBoxAdapter(child: EndlessPicker()),
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

/// The endless play modes as a sideways row of tiles, under up next. The
/// current one is lit; picking another sets it for this kind of queue
/// (album queues and the rest each remember their own).
class EndlessPicker extends ConsumerWidget {
  const EndlessPicker({super.key});

  static const _tileSize = 104.0;

  static IconData iconFor(EndlessMode m) => switch (m) {
    EndlessMode.stop => Icons.stop_rounded,
    EndlessMode.nextAlbum => Icons.album_rounded,
    EndlessMode.similar => Icons.auto_awesome_rounded,
    EndlessMode.liked => Icons.favorite_rounded,
    EndlessMode.genre => Icons.shuffle_rounded,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final mode = ref.watch(endlessModeProvider);
    final choices = ref.watch(endlessChoicesProvider);
    final album = ref.watch(playerProvider.select((s) => s.albumQueue));
    final repeating = ref.watch(
      playerProvider.select((s) => s.repeat != PlaybackRepeat.off),
    );
    final height =
        _tileSize +
        albumCaptionHeight(context) +
        lineHeight(context, t.bodySmall);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HorizontalShelf(
            title: 'When the queue ends',
            height: height,
            itemCount: choices.length,
            itemBuilder: (_, i) {
              final m = choices[i];
              return _EndlessTile(
                mode: m,
                size: _tileSize,
                selected: m == mode,
                onTap: () => ref
                    .read(endlessSettingsProvider.notifier)
                    .set(m, album: album),
              );
            },
          ),
          if (repeating)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Repeat is on, so the queue keeps going round.',
                style: t.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _EndlessTile extends StatelessWidget {
  final EndlessMode mode;
  final double size;
  final bool selected;
  final VoidCallback onTap;
  const _EndlessTile({
    required this.mode,
    required this.size,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: size,
      child: Semantics(
        button: true,
        selected: selected,
        label: '${mode.label}: ${mode.description}',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: selected
                      ? oampAccent.withValues(alpha: 0.18)
                      : OAmpColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? oampAccent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Icon(
                  EndlessPicker.iconFor(mode),
                  size: 40,
                  color: selected ? oampAccent : OAmpColors.textMuted,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                mode.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: selected ? oampAccent : null,
                ),
              ),
              Text(
                mode.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall,
              ),
            ],
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

  /// Endless play added this entry; a faint mark says so.
  final bool endless;
  const _QueueRow({
    required this.track,
    required this.onTap,
    this.trailing,
    this.faded = false,
    this.endless = false,
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
          trailing: endless
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Tooltip(
                      message: 'Added by endless play',
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          Icons.all_inclusive_rounded,
                          size: 16,
                          color: Color(0x59FFFFFF),
                          semanticLabel: 'Added by endless play',
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                )
              : trailing,
        ),
      ),
    );
  }
}

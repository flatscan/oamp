import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../async_view.dart';
import '../browser.dart';
import '../cover_art.dart';
import '../playlist_dialogs.dart';
import '../theme.dart';
import '../widgets.dart';

class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListScaffold(
      title: 'Playlists',
      onRefresh: () => ref.refresh(playlistsProvider.future),
      actions: [
        IconButton(
          tooltip: 'New playlist',
          icon: const Icon(Icons.add_rounded),
          onPressed: () => _createAndOpen(context, ref),
        ),
      ],
      slivers: [
        AsyncSliver(
          value: ref.watch(playlistsProvider),
          onRetry: () => ref.invalidate(playlistsProvider),
          builder: (lists) {
            return SliverList.builder(
              itemCount: lists.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Column(
                    children: [
                      ListTile(
                        leading: const _NewPlaylistIcon(),
                        title: const Text(
                          'New playlist',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        onTap: () => _createAndOpen(context, ref),
                      ),
                      if (lists.isEmpty)
                        const EmptyMessage(
                          icon: Icons.queue_music_rounded,
                          text:
                              'No playlists yet. Make one here, or choose '
                              '"Add to playlist" on any track or album.',
                        ),
                    ],
                  );
                }
                return _PlaylistTile(playlist: lists[i - 1]);
              },
            );
          },
        ),
      ],
    );
  }

  static Future<void> _createAndOpen(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final p = await createPlaylist(context, ref);
    if (p != null) openPage(PlaylistPage(playlist: p));
  }
}

class _NewPlaylistIcon extends StatelessWidget {
  const _NewPlaylistIcon();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(
      dimension: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: OAmpColors.surfaceHigh,
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        child: Icon(Icons.add_rounded, color: oampAccent, size: 28),
      ),
    );
  }
}

class _PlaylistTile extends ConsumerWidget {
  final Playlist playlist;
  const _PlaylistTile({required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = playlist;
    final mine = ref.read(playlistActionsProvider).canEdit(p);
    return GestureDetector(
      onSecondaryTapUp: (d) =>
          showPlaylistMenu(context, ref, p, at: d.globalPosition),
      child: ListTile(
        leading: CoverArt(
          p.coverArt,
          size: 56,
          placeholderIcon: Icons.queue_music_rounded,
        ),
        title: Text(
          p.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            playlistSummary(p),
            if (!mine && p.owner != null) 'by ${p.owner}',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Builder(
          builder: (btn) => IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded, size: 20),
            onPressed: () =>
                showPlaylistMenu(context, ref, p, at: centreOf(btn)),
          ),
        ),
        onTap: () => openPage(PlaylistPage(playlist: p)),
        onLongPress: () => showPlaylistMenu(context, ref, p),
      ),
    );
  }
}

String playlistSummary(Playlist p) => [
  '${p.songCount} track${p.songCount == 1 ? '' : 's'}',
  if (p.duration != null && p.duration! > Duration.zero)
    formatLongDuration(p.duration!),
].join(' · ');

enum _PlaylistAction { play, shuffle, playNext, enqueue, edit, rename, delete }

/// The actions menu for a playlist. [onEdit] adds "Edit tracks", and
/// [onDeleted] runs after the playlist is deleted.
Future<void> showPlaylistMenu(
  BuildContext context,
  WidgetRef ref,
  Playlist p, {
  Offset? at,
  VoidCallback? onEdit,
  VoidCallback? onDeleted,
}) async {
  final mine = ref.read(playlistActionsProvider).canEdit(p);
  final action = await showMenuAt<_PlaylistAction>(context, at: at, [
    menuItem(_PlaylistAction.play, Icons.play_arrow_rounded, 'Play'),
    menuItem(_PlaylistAction.shuffle, Icons.shuffle_rounded, 'Shuffle'),
    menuItem(
      _PlaylistAction.playNext,
      Icons.playlist_play_rounded,
      'Play next',
    ),
    menuItem(
      _PlaylistAction.enqueue,
      Icons.queue_music_rounded,
      'Add to queue',
    ),
    if (mine) ...[
      const PopupMenuDivider(),
      if (onEdit != null)
        menuItem(_PlaylistAction.edit, Icons.edit_rounded, 'Edit tracks'),
      menuItem(
        _PlaylistAction.rename,
        Icons.drive_file_rename_outline_rounded,
        'Rename',
      ),
      menuItem(_PlaylistAction.delete, Icons.delete_outline_rounded, 'Delete'),
    ],
  ]);
  if (action == null || !context.mounted) return;
  switch (action) {
    case _PlaylistAction.edit:
      onEdit!();
      return;
    case _PlaylistAction.rename:
      await renamePlaylist(context, ref, p);
      return;
    case _PlaylistAction.delete:
      if (await deletePlaylist(context, ref, p)) onDeleted?.call();
      return;
    default:
  }
  final List<Track> tracks;
  try {
    tracks = (await ref.read(playlistDetailProvider(p.id).future)).tracks;
  } catch (e) {
    if (context.mounted) toast(context, 'Could not load playlist: $e');
    return;
  }
  if (!context.mounted) return;
  final player = ref.read(playerProvider.notifier);
  switch (action) {
    case _PlaylistAction.play:
    case _PlaylistAction.shuffle:
      await player.playTracks(
        tracks,
        shuffle: action == _PlaylistAction.shuffle,
        from: p.name,
      );
    case _PlaylistAction.playNext:
      await player.playNext(tracks);
      if (context.mounted) toast(context, 'Playing "${p.name}" next');
    case _PlaylistAction.enqueue:
      await player.enqueue(tracks);
      if (context.mounted) toast(context, 'Added "${p.name}" to queue');
    default:
  }
}

/// One playlist: cover, name and details, play and shuffle, then its
/// tracks. The owner can remove tracks from each track's menu, or choose
/// Edit to drag tracks into a new order and remove several at once.
class PlaylistPage extends ConsumerStatefulWidget {
  final Playlist playlist;
  const PlaylistPage({super.key, required this.playlist});

  @override
  ConsumerState<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends ConsumerState<PlaylistPage> {
  /// The tracks being edited, each with a key that survives reordering
  /// (the same track can be in a playlist twice). Null when not editing.
  List<(int, Track)>? _draft;
  bool _saving = false;

  String get _id => widget.playlist.id;

  void _startEditing(List<Track> tracks) => setState(() {
    _draft = [for (var i = 0; i < tracks.length; i++) (i, tracks[i])];
  });

  Future<void> _finishEditing(Playlist p, List<Track> original) async {
    final draft = _draft!;
    final changed =
        draft.length != original.length ||
        [for (var i = 0; i < draft.length; i++) draft[i].$1 != i].any((c) => c);
    if (!changed) {
      setState(() => _draft = null);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(playlistActionsProvider).replaceTracks(p, [
        for (final (_, t) in draft) t,
      ]);
      await ref.read(playlistDetailProvider(_id).future);
      if (mounted) setState(() => _draft = null);
    } catch (e) {
      if (mounted) toast(context, 'Could not save playlist: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeOne(Playlist p, List<Track> tracks, int index) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final actions = ref.read(playlistActionsProvider);
    final title = tracks[index].title;
    try {
      await actions.removeAt(p, [index]);
    } catch (e) {
      if (mounted) toast(context, 'Could not remove track: $e');
      return;
    }
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed "$title"'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => actions.replaceTracks(p, tracks),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(playlistDetailProvider(_id));
    final p = detail.value?.playlist ?? widget.playlist;
    final tracks = detail.value?.tracks ?? const <Track>[];
    final mine = ref.read(playlistActionsProvider).canEdit(p);
    final player = ref.read(playerProvider.notifier);
    final draft = _draft;
    final t = Theme.of(context).textTheme;

    void play({int start = 0, bool shuffle = false}) => player.playTracks(
      tracks,
      startIndex: start,
      shuffle: shuffle,
      from: p.name,
    );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Column(
        children: [
          CoverArt(
            p.coverArt,
            size: 220,
            radius: 10,
            placeholderIcon: Icons.queue_music_rounded,
          ),
          const SizedBox(height: 18),
          Text(p.name, textAlign: TextAlign.center, style: t.headlineSmall),
          const SizedBox(height: 4),
          Text(
            [
              if (p.owner != null) 'by ${p.owner}',
              playlistSummary(p),
            ].join(' · '),
            textAlign: TextAlign.center,
            style: t.bodySmall,
          ),
          if (p.comment != null) ...[
            const SizedBox(height: 8),
            Text(
              p.comment!,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium?.copyWith(color: OAmpColors.textMuted),
            ),
          ],
          const SizedBox(height: 20),
          if (draft == null)
            PlayShuffleButtons(
              onPlay: tracks.isEmpty ? null : () => play(),
              onShuffle: tracks.isEmpty ? null : () => play(shuffle: true),
              trailing: Builder(
                builder: (btn) => IconButton(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_horiz_rounded),
                  onPressed: () => showPlaylistMenu(
                    context,
                    ref,
                    p,
                    at: centreOf(btn),
                    onEdit: tracks.isEmpty ? null : () => _startEditing(tracks),
                    onDeleted: () => Navigator.maybePop(context),
                  ),
                ),
              ),
            )
          else
            Text(
              'Drag tracks into a new order, or remove them. '
              'Nothing changes on the server until you choose Done.',
              textAlign: TextAlign.center,
              style: t.bodySmall,
            ),
        ],
      ),
    );

    final Widget list;
    if (draft != null) {
      list = SliverReorderableList(
        itemCount: draft.length,
        onReorderItem: (from, to) => setState(() {
          draft.insert(to, draft.removeAt(from));
        }),
        itemBuilder: (context, i) {
          final (key, track) = draft[i];
          return _EditRow(
            key: ValueKey(key),
            index: i,
            track: track,
            onRemove: () => setState(() => draft.removeAt(i)),
          );
        },
      );
    } else {
      list = AsyncSliver(
        value: detail,
        onRetry: () => ref.invalidate(playlistDetailProvider(_id)),
        builder: (_) => tracks.isEmpty
            ? const SliverToBoxAdapter(
                child: EmptyMessage(
                  icon: Icons.queue_music_rounded,
                  text:
                      'This playlist is empty. Choose "Add to playlist" on '
                      'any track or album to fill it.',
                ),
              )
            : SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (_, i) => TrackTile(
                  track: tracks[i],
                  onTap: () => play(start: i),
                  onRemove: mine ? () => _removeOne(p, tracks, i) : null,
                ),
              ),
      );
    }

    return DetailScaffold(
      title: p.name,
      titleAfter: 280,
      onRefresh: draft != null
          ? null
          : () => ref.refresh(playlistDetailProvider(_id).future),
      actions: draft == null
          ? null
          : [
              TextButton(
                onPressed: _saving ? null : () => setState(() => _draft = null),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: _saving ? null : () => _finishEditing(p, tracks),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                child: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Done'),
              ),
              const SizedBox(width: 8),
            ],
      slivers: [
        SliverToBoxAdapter(child: header),
        list,
      ],
    );
  }
}

class _EditRow extends StatelessWidget {
  final int index;
  final Track track;
  final VoidCallback onRemove;
  const _EditRow({
    super.key,
    required this.index,
    required this.track,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        leading: IconButton(
          tooltip: 'Remove ${track.title}',
          color: Theme.of(context).colorScheme.error,
          icon: const Icon(Icons.remove_circle_outline_rounded),
          onPressed: onRemove,
        ),
        minLeadingWidth: 28,
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        ),
        subtitle: track.artist == null
            ? null
            : Text(
                track.artist!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall,
              ),
        trailing: ReorderableDragStartListener(
          index: index,
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
      ),
    );
  }
}

/// A playlist-like page: cover, title, play and shuffle, then tracks with
/// their own covers.
class TrackListPage extends ConsumerWidget {
  final String title;
  final String subtitle;
  final String? coverArt;
  final IconData icon;
  final AsyncValue<List<Track>> tracks;
  final Future<void> Function() onRefresh;
  final VoidCallback onRetry;

  const TrackListPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.coverArt,
    required this.icon,
    required this.tracks,
    required this.onRefresh,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = tracks.value ?? const <Track>[];
    final player = ref.read(playerProvider.notifier);
    void play({int start = 0, bool shuffle = false}) => player.playTracks(
      list,
      startIndex: start,
      shuffle: shuffle,
      from: title,
    );
    final t = Theme.of(context).textTheme;
    return DetailScaffold(
      title: title,
      titleAfter: 260,
      onRefresh: onRefresh,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Column(
              children: [
                CoverArt(
                  coverArt,
                  size: 200,
                  radius: 10,
                  placeholderIcon: icon,
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: t.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(subtitle, textAlign: TextAlign.center, style: t.bodySmall),
                const SizedBox(height: 20),
                PlayShuffleButtons(
                  onPlay: list.isEmpty ? null : () => play(),
                  onShuffle: list.isEmpty ? null : () => play(shuffle: true),
                ),
              ],
            ),
          ),
        ),
        AsyncSliver(
          value: tracks,
          onRetry: onRetry,
          builder: (list) => list.isEmpty
              ? SliverToBoxAdapter(
                  child: EmptyMessage(icon: icon, text: 'Nothing here yet'),
                )
              : SliverList.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => TrackTile(
                    track: list[i],
                    onTap: () => play(start: i),
                  ),
                ),
        ),
      ],
    );
  }
}

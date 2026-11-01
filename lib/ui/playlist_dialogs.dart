import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/library.dart';
import 'async_view.dart';
import 'cover_art.dart';
import 'theme.dart';
import 'widgets.dart';

/// Asks for a name, such as a new playlist's. Returns null when cancelled
/// or left blank.
Future<String?> promptForName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, action: action, initial: initial),
  );
  return name == null || name.isEmpty ? null : name;
}

/// Owns its text controller, so it outlives the dialog's closing animation.
class _NameDialog extends StatefulWidget {
  final String title;
  final String action;
  final String initial;
  const _NameDialog({
    required this.title,
    required this.action,
    required this.initial,
  });

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}

/// Asks for a name and creates a playlist holding [tracks].
Future<Playlist?> createPlaylist(
  BuildContext context,
  WidgetRef ref, [
  List<Track> tracks = const [],
]) async {
  final name = await promptForName(
    context,
    title: 'New playlist',
    action: 'Create',
  );
  if (name == null || !context.mounted) return null;
  try {
    final p = await ref.read(playlistActionsProvider).create(name, tracks);
    if (context.mounted) {
      toast(
        context,
        tracks.isEmpty
            ? 'Created "$name"'
            : 'Created "$name" with ${_count(tracks.length)}',
      );
    }
    return p;
  } catch (e) {
    if (context.mounted) toast(context, 'Could not create playlist: $e');
    return null;
  }
}

String _count(int n) => '$n track${n == 1 ? '' : 's'}';

/// Lets the user pick one of their playlists, or start a new one, and adds
/// [tracks] to it.
Future<void> addToPlaylist(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks,
) async {
  if (tracks.isEmpty) return;
  final picked = await showDialog<_Pick>(
    context: context,
    builder: (_) => _PlaylistPicker(trackCount: tracks.length),
  );
  if (picked == null || !context.mounted) return;
  final playlist = picked.playlist;
  if (playlist == null) {
    await createPlaylist(context, ref, tracks);
    return;
  }
  try {
    await ref.read(playlistActionsProvider).add(playlist, tracks);
    if (context.mounted) {
      toast(context, 'Added ${_count(tracks.length)} to "${playlist.name}"');
    }
  } catch (e) {
    if (context.mounted) toast(context, 'Could not add to playlist: $e');
  }
}

/// A choice from the picker: a playlist, or null for "New playlist".
class _Pick {
  final Playlist? playlist;
  const _Pick(this.playlist);
}

class _PlaylistPicker extends ConsumerWidget {
  final int trackCount;
  const _PlaylistPicker({required this.trackCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(playlistActionsProvider);
    return AlertDialog(
      title: Text('Add ${_count(trackCount)} to'),
      contentPadding: const EdgeInsets.only(top: 12, bottom: 8),
      // A fixed width, because the dialog measures its content's width and
      // a list cannot be measured.
      content: SizedBox(
        width: 360,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 380),
          child: AsyncView(
            value: ref.watch(playlistsProvider),
            onRetry: () => ref.invalidate(playlistsProvider),
            builder: (all) {
              final mine = [
                for (final p in all)
                  if (actions.canEdit(p)) p,
              ];
              return ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const SizedBox.square(
                      dimension: 44,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: OAmpColors.surfaceHigh,
                          borderRadius: BorderRadius.all(Radius.circular(6)),
                        ),
                        child: Icon(Icons.add_rounded, color: oampAccent),
                      ),
                    ),
                    title: const Text(
                      'New playlist…',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    onTap: () => Navigator.pop(context, const _Pick(null)),
                  ),
                  for (final p in mine)
                    ListTile(
                      leading: CoverArt(
                        p.coverArt,
                        size: 44,
                        placeholderIcon: Icons.queue_music_rounded,
                      ),
                      title: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _count(p.songCount),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      onTap: () => Navigator.pop(context, _Pick(p)),
                    ),
                ],
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Renames [p] after asking for the new name.
Future<void> renamePlaylist(
  BuildContext context,
  WidgetRef ref,
  Playlist p,
) async {
  final name = await promptForName(
    context,
    title: 'Rename playlist',
    action: 'Rename',
    initial: p.name,
  );
  if (name == null || name == p.name || !context.mounted) return;
  try {
    await ref.read(playlistActionsProvider).rename(p, name);
  } catch (e) {
    if (context.mounted) toast(context, 'Could not rename playlist: $e');
  }
}

/// Deletes [p] once the user confirms. Returns whether it was deleted.
Future<bool> deletePlaylist(
  BuildContext context,
  WidgetRef ref,
  Playlist p,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete playlist?'),
      content: Text('"${p.name}" will be deleted from the server.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  try {
    await ref.read(playlistActionsProvider).delete(p);
    if (context.mounted) toast(context, 'Deleted "${p.name}"');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, 'Could not delete playlist: $e');
    return false;
  }
}

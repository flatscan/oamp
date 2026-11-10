import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/downloads.dart';
import '../../core/models.dart';
import '../../state/downloads.dart';
import '../browser.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';
import 'album_page.dart';
import 'artist_page.dart';
import 'liked_view.dart';
import 'playlists_view.dart';

/// Everything kept on the device, with how far each download has got.
class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadsProvider);
    final bytes = ref.watch(downloadUsageProvider).value ?? 0;
    final tracks = downloads.totalTracks;
    return ListScaffold(
      title: 'Downloads',
      slivers: [
        if (downloads.pins.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyMessage(
              icon: Icons.download_for_offline_outlined,
              text:
                  'Nothing downloaded yet. Use the download button on an '
                  'album, playlist or artist to keep it on this device.',
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                downloads.problem ??
                    [
                      '$tracks ${tracks == 1 ? 'track' : 'tracks'}',
                      formatBytes(bytes),
                      if (downloads.remaining > 0)
                        '${downloads.remaining} to go',
                    ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: downloads.problem == null
                      ? OAmpColors.textMuted
                      : oampAccent,
                ),
              ),
            ),
          ),
          SliverList.builder(
            itemCount: downloads.pins.length,
            itemBuilder: (context, i) =>
                _PinTile(pin: downloads.pins[downloads.pins.length - 1 - i]),
          ),
        ],
      ],
    );
  }

  /// A size in bytes as a short phrase, such as `1.4 GB`.
  static String formatBytes(int b) {
    final mb = b / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }
}

class _PinTile extends ConsumerWidget {
  final Pin pin;
  const _PinTile({required this.pin});

  static String _kind(PinKind k) => switch (k) {
    PinKind.album => 'Album',
    PinKind.playlist => 'Playlist',
    PinKind.artist => 'Artist',
    PinKind.liked => 'Liked tracks',
  };

  void _open() => openPage(switch (pin.kind) {
    PinKind.album => AlbumPage(
      album: Album(id: pin.itemId, name: pin.name, coverArt: pin.coverArt),
    ),
    PinKind.playlist => PlaylistPage(
      playlist: Playlist(
        id: pin.itemId,
        name: pin.name,
        coverArt: pin.coverArt,
      ),
    ),
    PinKind.artist => ArtistPage(
      artist: Artist(id: pin.itemId, name: pin.name, coverArt: pin.coverArt),
    ),
    PinKind.liked => const LikedTracksPage(),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(
      downloadsProvider.select((s) => s.statusOf(pin.kind, pin.itemId)),
    );
    final done = status?.complete ?? false;
    return ListTile(
      leading: CoverArt(
        pin.coverArt,
        size: 48,
        radius: 4,
        placeholderIcon: pin.kind == PinKind.artist
            ? Icons.person_rounded
            : pin.kind == PinKind.liked
            ? Icons.favorite_rounded
            : Icons.queue_music_rounded,
      ),
      title: Text(pin.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_kind(pin.kind)} · ${done ? '${status!.total} tracks' : '${status?.done ?? 0} of ${pin.tracks.length} tracks'}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: done
          ? const Icon(Icons.download_done_rounded, color: oampAccent)
          : SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: (status?.progress ?? 0) > 0 ? status!.progress : null,
                color: oampAccent,
              ),
            ),
      onTap: _open,
      onLongPress: () => _confirmRemove(context, ref),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove download?'),
        content: Text(
          '"${pin.name}" will be removed from this device. It stays on the '
          'server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) {
      await ref.read(downloadsProvider.notifier).unpin(pin.kind, pin.itemId);
    }
  }
}

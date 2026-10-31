import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../async_view.dart';
import '../cover_art.dart';

/// Responsive grid of album covers.
class AlbumGrid extends StatelessWidget {
  final List<Album> albums;
  const AlbumGrid({super.key, required this.albums});

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) return const Center(child: Text('No albums'));
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.75,
      ),
      itemCount: albums.length,
      itemBuilder: (context, i) => _AlbumTile(album: albums[i]),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  final Album album;
  const _AlbumTile({required this.album});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () =>
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => AlbumPage(album: album))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (_, c) => CoverArt(album.coverArt, size: c.maxWidth),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            album.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.bodyMedium,
          ),
          Text(
            [album.artist, album.year].whereType<Object>().join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}

class AlbumPage extends ConsumerWidget {
  final Album album;
  const AlbumPage({super.key, required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(playerProvider.notifier);
    final current = ref.watch(playerProvider.select((s) => s.current?.id));
    return Scaffold(
      appBar: AppBar(title: Text(album.name)),
      body: AsyncView(
        value: ref.watch(albumDetailProvider(album.id)),
        onRetry: () => ref.invalidate(albumDetailProvider(album.id)),
        builder: (detail) {
          final tracks = detail.tracks;
          return ListView.builder(
            itemCount: tracks.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return _AlbumHeader(
                  album: detail.album,
                  onPlay: () => player.playTracks(tracks),
                  onShuffle: () => player.playTracks([...tracks]..shuffle()),
                  onEnqueue: () {
                    player.enqueue(tracks);
                    _toast(context, 'Added ${tracks.length} tracks to queue');
                  },
                );
              }
              final t = tracks[i - 1];
              return ListTile(
                selected: t.id == current,
                leading: SizedBox(
                  width: 28,
                  child: Text(
                    '${t.track ?? i}',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: (t.artist != null && t.artist != detail.album.artist)
                    ? Text(t.artist!, maxLines: 1)
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(formatDuration(t.duration)),
                    PopupMenuButton<String>(
                      tooltip: 'More',
                      onSelected: (v) {
                        if (v == 'next') player.playNext([t]);
                        if (v == 'end') player.enqueue([t]);
                        _toast(context, 'Queued "${t.title}"');
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'next', child: Text('Play next')),
                        PopupMenuItem(
                          value: 'end',
                          child: Text('Add to queue'),
                        ),
                      ],
                    ),
                  ],
                ),
                onTap: () => player.playTracks(tracks, startIndex: i - 1),
              );
            },
          );
        },
      ),
    );
  }

  static void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(msg)));
}

class _AlbumHeader extends StatelessWidget {
  final Album album;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final VoidCallback onEnqueue;

  const _AlbumHeader({
    required this.album,
    required this.onPlay,
    required this.onShuffle,
    required this.onEnqueue,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverArt(album.coverArt, size: 120, radius: 6),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(album.name, style: t.titleLarge),
                if (album.artist != null)
                  Text(album.artist!, style: t.bodyLarge),
                Text(
                  [
                    if (album.year != null) '${album.year}',
                    '${album.songCount} tracks',
                  ].join(' · '),
                  style: t.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: onPlay,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play'),
                    ),
                    IconButton.outlined(
                      tooltip: 'Shuffle',
                      onPressed: onShuffle,
                      icon: const Icon(Icons.shuffle),
                    ),
                    IconButton.outlined(
                      tooltip: 'Add to queue',
                      onPressed: onEnqueue,
                      icon: const Icon(Icons.queue_music),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

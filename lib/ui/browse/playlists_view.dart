import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../async_view.dart';
import '../browser.dart';
import '../cover_art.dart';
import '../widgets.dart';

class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListScaffold(
      title: 'Playlists',
      onRefresh: () => ref.refresh(playlistsProvider.future),
      slivers: [
        AsyncSliver(
          value: ref.watch(playlistsProvider),
          onRetry: () => ref.invalidate(playlistsProvider),
          builder: (lists) {
            if (lists.isEmpty) {
              return const SliverToBoxAdapter(
                child: EmptyMessage(
                  icon: Icons.queue_music_rounded,
                  text: 'No playlists yet',
                ),
              );
            }
            return SliverList.builder(
              itemCount: lists.length,
              itemBuilder: (context, i) {
                final p = lists[i];
                return ListTile(
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
                    _summary(p),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  onTap: () => openPage(PlaylistPage(playlist: p)),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

String _summary(Playlist p) => [
  '${p.songCount} track${p.songCount == 1 ? '' : 's'}',
  if (p.duration != null && p.duration! > Duration.zero)
    formatLongDuration(p.duration!),
].join(' · ');

class PlaylistPage extends ConsumerWidget {
  final Playlist playlist;
  const PlaylistPage({super.key, required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(playlistDetailProvider(playlist.id));
    final p = detail.value?.playlist ?? playlist;
    return TrackListPage(
      title: p.name,
      subtitle: [_summary(p), if (p.owner != null) 'by ${p.owner}'].join(' · '),
      coverArt: p.coverArt,
      icon: Icons.queue_music_rounded,
      tracks: detail.whenData((d) => d.tracks),
      onRefresh: () => ref.refresh(playlistDetailProvider(playlist.id).future),
      onRetry: () => ref.invalidate(playlistDetailProvider(playlist.id)),
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

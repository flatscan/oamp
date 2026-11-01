import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../async_view.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';

/// An album: large centred cover, title, artist, play and shuffle, then the
/// tracks grouped by disc.
class AlbumPage extends ConsumerWidget {
  final Album album;
  const AlbumPage({super.key, required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(albumDetailProvider(album.id));
    final a = detail.value?.album ?? album;
    final tracks = detail.value?.tracks ?? const <Track>[];
    final player = ref.read(playerProvider.notifier);

    void play({int start = 0, bool shuffle = false}) => player.playTracks(
      tracks,
      startIndex: start,
      shuffle: shuffle,
      from: a.name,
    );

    final discs = {for (final t in tracks) t.discNumber ?? 1};
    final multiDisc = discs.length > 1;

    return DetailScaffold(
      title: a.name,
      titleAfter: 300,
      onRefresh: () => ref.refresh(albumDetailProvider(album.id).future),
      actions: [
        IconButton(
          tooltip: 'Add album to queue',
          icon: const Icon(Icons.playlist_add_rounded),
          onPressed: tracks.isEmpty
              ? null
              : () {
                  player.enqueue(tracks);
                  toast(context, 'Added ${tracks.length} tracks to queue');
                },
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: _Header(
            album: a,
            tracks: tracks,
            onPlay: tracks.isEmpty ? null : () => play(),
            onShuffle: tracks.isEmpty ? null : () => play(shuffle: true),
          ),
        ),
        AsyncSliver(
          value: detail,
          onRetry: () => ref.invalidate(albumDetailProvider(album.id)),
          builder: (d) => SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) {
              final t = tracks[i];
              final disc = t.discNumber ?? 1;
              final firstOfDisc =
                  i == 0 || (tracks[i - 1].discNumber ?? 1) != disc;
              final tile = TrackTile(
                track: t,
                number: '${t.track ?? i + 1}',
                showArtist: t.artist != null && t.artist != a.artist,
                onTap: () => play(start: i),
              );
              if (!multiDisc || !firstOfDisc) return tile;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 16, 4),
                    child: Text(
                      'DISC $disc',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: OAmpColors.textFaint,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  tile,
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final Album album;
  final List<Track> tracks;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  const _Header({
    required this.album,
    required this.tracks,
    required this.onPlay,
    required this.onShuffle,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final total = tracks.fold(
      Duration.zero,
      (sum, tr) => sum + (tr.duration ?? Duration.zero),
    );
    final meta = [
      if (album.year != null) '${album.year}',
      if (tracks.isNotEmpty)
        '${tracks.length} track${tracks.length == 1 ? '' : 's'}',
      if (total > Duration.zero) formatLongDuration(total),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: LayoutBuilder(
        builder: (context, c) {
          final art = (c.maxWidth * 0.78).clamp(140.0, 320.0);
          return Column(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 30,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: CoverArt(album.coverArt, size: art, radius: 10),
              ),
              const SizedBox(height: 20),
              Text(
                album.name,
                textAlign: TextAlign.center,
                style: t.headlineSmall,
              ),
              if (album.artist != null) ...[
                const SizedBox(height: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: album.artistId == null
                      ? null
                      : () => openArtistById(album.artistId!, album.artist!),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      album.artist!,
                      textAlign: TextAlign.center,
                      style: t.titleMedium?.copyWith(color: oampAccent),
                    ),
                  ),
                ),
              ],
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(meta, style: t.bodySmall),
              ],
              const SizedBox(height: 20),
              PlayShuffleButtons(onPlay: onPlay, onShuffle: onShuffle),
            ],
          );
        },
      ),
    );
  }
}

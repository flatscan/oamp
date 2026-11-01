import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../async_view.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';

/// An artist: picture fading into the page, play and shuffle across all
/// their albums, then the albums newest first.
class ArtistPage extends ConsumerWidget {
  final Artist artist;
  const ArtistPage({super.key, required this.artist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(artistDetailProvider(artist.id));
    final a = detail.value?.artist ?? artist;
    final albums = [...?detail.value?.albums]
      ..sort((x, y) => (y.year ?? 0).compareTo(x.year ?? 0));

    Future<void> play({bool shuffle = false}) async {
      try {
        final tracks = await ref.read(artistTracksProvider(artist.id).future);
        await ref
            .read(playerProvider.notifier)
            .playTracks(tracks, shuffle: shuffle, from: a.name);
      } catch (e) {
        if (context.mounted) toast(context, 'Could not load tracks: $e');
      }
    }

    return DetailScaffold(
      title: a.name,
      titleAfter: 240,
      onRefresh: () => ref.refresh(artistDetailProvider(artist.id).future),
      slivers: [
        SliverToBoxAdapter(
          child: _Hero(artist: a, albumCount: albums.length),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: PlayShuffleButtons(
              onPlay: albums.isEmpty ? null : () => play(),
              onShuffle: albums.isEmpty ? null : () => play(shuffle: true),
            ),
          ),
        ),
        if (albums.isNotEmpty)
          const SliverToBoxAdapter(child: SectionHeader('Albums')),
        AsyncSliver(
          value: detail,
          onRetry: () => ref.invalidate(artistDetailProvider(artist.id)),
          builder: (_) => SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: AlbumSliverGrid(albums: albums, showArtist: false),
          ),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  final Artist artist;
  final int albumCount;
  const _Hero({required this.artist, required this.albumCount});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, c) {
        final size = (c.maxWidth * 0.55).clamp(140.0, 260.0);
        return Column(
          children: [
            CoverArt(
              artist.coverArt,
              size: size,
              circle: true,
              placeholderIcon: Icons.person_rounded,
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                artist.name,
                textAlign: TextAlign.center,
                style: t.headlineMedium,
              ),
            ),
            if (albumCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: Text(
                  '$albumCount album${albumCount == 1 ? '' : 's'}',
                  style: t.bodyMedium?.copyWith(color: OAmpColors.textMuted),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Albums as a grid sliver whose columns adapt to the width.
class AlbumSliverGrid extends StatelessWidget {
  final List<Album> albums;
  final bool showArtist;
  const AlbumSliverGrid({
    super.key,
    required this.albums,
    this.showArtist = true,
  });

  @override
  Widget build(BuildContext context) {
    return SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 16,
        crossAxisSpacing: 14,
        childAspectRatio: 0.74,
      ),
      itemCount: albums.length,
      itemBuilder: (_, i) =>
          AlbumCard(album: albums[i], showArtist: showArtist),
    );
  }
}

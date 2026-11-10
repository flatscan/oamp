import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/downloads.dart';
import '../../state/library.dart';
import '../async_view.dart';
import '../download_button.dart';
import '../widgets.dart';
import 'artists_view.dart';
import 'playlists_view.dart';

class LikedTracksPage extends ConsumerWidget {
  const LikedTracksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(likedTracksProvider);
    final n = tracks.value?.length;
    return TrackListPage(
      title: 'Liked tracks',
      subtitle: n == null ? '' : '$n track${n == 1 ? '' : 's'}',
      coverArt: null,
      icon: Icons.favorite_rounded,
      tracks: tracks,
      onRefresh: () => ref.refresh(likedTracksProvider.future),
      onRetry: () => ref.invalidate(likedTracksProvider),
      trailing: DownloadButton(
        kind: PinKind.liked,
        itemId: Pin.likedItemId,
        name: 'Liked tracks',
        loadTracks: () => ref.read(likedTracksProvider.future),
      ),
    );
  }
}

/// The artists the user has liked, A to Z.
class LikedArtistsPage extends ConsumerWidget {
  const LikedArtistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(likedArtistsProvider);
    return ListScaffold(
      title: 'Liked artists',
      onRefresh: () => ref.refresh(likedArtistsProvider.future),
      slivers: [
        AsyncSliver(
          value: artists,
          onRetry: () => ref.invalidate(likedArtistsProvider),
          builder: (list) => list.isEmpty
              ? const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyMessage(
                    icon: Icons.person_rounded,
                    text:
                        'No liked artists yet. Tap the heart on an artist to '
                        'add them here.',
                  ),
                )
              : SliverList.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => ArtistTile(artist: list[i]),
                ),
        ),
      ],
    );
  }
}

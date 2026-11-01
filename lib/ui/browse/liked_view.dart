import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/library.dart';
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
    );
  }
}

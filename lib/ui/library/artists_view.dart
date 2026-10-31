import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../async_view.dart';
import '../cover_art.dart';
import 'album_page.dart';

class ArtistsView extends ConsumerWidget {
  const ArtistsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(artistsProvider),
      onRetry: () => ref.invalidate(artistsProvider),
      builder: (artists) => RefreshIndicator(
        onRefresh: () => ref.refresh(artistsProvider.future),
        child: ListView.builder(
          itemCount: artists.length,
          itemBuilder: (context, i) {
            final a = artists[i];
            return ListTile(
              leading: CoverArt(a.coverArt, size: 40, radius: 20),
              title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${a.albumCount} album${a.albumCount == 1 ? '' : 's'}',
              ),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => ArtistPage(artist: a))),
            );
          },
        ),
      ),
    );
  }
}

class ArtistPage extends ConsumerWidget {
  final Artist artist;
  const ArtistPage({super.key, required this.artist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(artist.name)),
      body: AsyncView(
        value: ref.watch(artistDetailProvider(artist.id)),
        onRetry: () => ref.invalidate(artistDetailProvider(artist.id)),
        builder: (detail) => AlbumGrid(albums: detail.albums),
      ),
    );
  }
}

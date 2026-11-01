import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../browser.dart';
import '../theme.dart';
import '../widgets.dart';
import 'albums_view.dart';
import 'artists_view.dart';
import 'liked_view.dart';
import 'playlists_view.dart';

/// The Library tab: the ways into the collection, then recent additions.
class LibraryView extends ConsumerWidget {
  const LibraryView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListScaffold(
      title: 'Library',
      slivers: [
        SliverList.list(
          children: [
            _Entry(
              icon: Icons.person_rounded,
              label: 'Artists',
              onTap: () => openPage(const ArtistsPage()),
            ),
            _Entry(
              icon: Icons.album_rounded,
              label: 'Albums',
              onTap: () => openPage(const AllAlbumsPage()),
            ),
            _Entry(
              icon: Icons.queue_music_rounded,
              label: 'Playlists',
              onTap: () => openPage(const PlaylistsPage()),
            ),
            _Entry(
              icon: Icons.favorite_rounded,
              label: 'Liked tracks',
              onTap: () => openPage(const LikedTracksPage()),
            ),
            AlbumCarousel(
              title: 'Recently added',
              albums: ref.watch(homeAlbumsProvider(AlbumSort.newest)),
              onSeeAll: () =>
                  openPage(const AllAlbumsPage(initialSort: AlbumSort.newest)),
            ),
          ],
        ),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Entry({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: oampAccent),
      title: Text(label, style: Theme.of(context).textTheme.titleMedium),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: OAmpColors.textFaint,
      ),
      onTap: onTap,
    );
  }
}

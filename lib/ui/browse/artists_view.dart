import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../async_view.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';

/// All artists A to Z, with a letter heading where the initial changes.
class ArtistsPage extends ConsumerWidget {
  const ArtistsPage({super.key});

  static String _initial(String name) {
    final c = name.trim().isEmpty ? '#' : name.trim()[0].toUpperCase();
    return RegExp(r'[A-Z]').hasMatch(c) ? c : '#';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListScaffold(
      title: 'Artists',
      onRefresh: () => ref.refresh(artistsProvider.future),
      slivers: [
        AsyncSliver(
          value: ref.watch(artistsProvider),
          onRetry: () => ref.invalidate(artistsProvider),
          builder: (artists) {
            if (artists.isEmpty) {
              return const SliverToBoxAdapter(
                child: EmptyMessage(
                  icon: Icons.person_outline,
                  text: 'No artists',
                ),
              );
            }
            return SliverList.builder(
              itemCount: artists.length,
              itemBuilder: (context, i) {
                final a = artists[i];
                final letter = _initial(a.name);
                final showLetter =
                    i == 0 || _initial(artists[i - 1].name) != letter;
                final tile = _ArtistTile(artist: a);
                if (!showLetter) return tile;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        letter,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: oampAccent),
                      ),
                    ),
                    tile,
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _ArtistTile extends StatelessWidget {
  final Artist artist;
  const _ArtistTile({required this.artist});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CoverArt(
        artist.coverArt,
        size: 48,
        circle: true,
        placeholderIcon: Icons.person_rounded,
      ),
      title: Text(
        artist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${artist.albumCount} album${artist.albumCount == 1 ? '' : 's'}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => openArtist(artist),
    );
  }
}

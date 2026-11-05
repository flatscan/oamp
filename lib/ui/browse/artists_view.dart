import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../async_view.dart';
import '../cover_art.dart';
import '../jump_bar.dart';
import '../theme.dart';
import '../widgets.dart';

/// All artists A to Z, with a letter heading where the initial changes and
/// a jump bar down the right.
///
/// Each letter is a heading and a fixed-height run of rows, so scrolling
/// and jumping cost the same with fifty artists or fifty thousand: nothing
/// ever has to measure every row above the one on screen.
class ArtistsPage extends ConsumerStatefulWidget {
  const ArtistsPage({super.key});

  @override
  ConsumerState<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends ConsumerState<ArtistsPage> {
  final _scroll = ScrollController();

  static const _headerHeight = 40.0;
  static const _rowHeight = 72.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jump(LetterGroups<Artist> index, String letter) {
    if (!_scroll.hasClients) return;
    final offset = index.offsetOf(
      letter,
      headerHeight: _headerHeight,
      rowHeight: _rowHeight,
    );
    final p = _scroll.position;
    _scroll.jumpTo(offset.clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(artistIndexProvider);
    final loaded = index.value;
    return ListScaffold(
      title: 'Artists',
      controller: _scroll,
      onRefresh: () => ref.refresh(artistsProvider.future),
      jumpBar: loaded != null && loaded.length > 30
          ? JumpBar(available: loaded.letters, onJump: (l) => _jump(loaded, l))
          : null,
      slivers: [
        AsyncSliver(
          value: index,
          onRetry: () => ref.invalidate(artistsProvider),
          builder: (index) {
            if (index.isEmpty) {
              return const SliverToBoxAdapter(
                child: EmptyMessage(
                  icon: Icons.person_outline,
                  text: 'No artists',
                ),
              );
            }
            final heading = Theme.of(context).textTheme.titleMedium
                ?.copyWith(color: oampAccent);
            return SliverPadding(
              padding: const EdgeInsets.only(right: JumpBar.width),
              sliver: SliverMainAxisGroup(
                slivers: [
                  for (final g in index.groups) ...[
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: _headerHeight,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                          child: Text(g.letter, style: heading),
                        ),
                      ),
                    ),
                    SliverFixedExtentList.builder(
                      itemExtent: _rowHeight,
                      itemCount: g.items.length,
                      itemBuilder: (context, i) =>
                          ArtistTile(artist: g.items[i]),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// One artist in a list, with their photo and album count.
class ArtistTile extends StatelessWidget {
  final Artist artist;
  const ArtistTile({super.key, required this.artist});

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

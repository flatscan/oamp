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
class ArtistsPage extends ConsumerStatefulWidget {
  const ArtistsPage({super.key});

  @override
  ConsumerState<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends ConsumerState<ArtistsPage> {
  final _scroll = ScrollController();

  // Fixed heights, so the offset of any letter can be worked out without
  // building the rows above it.
  static const _headerHeight = 40.0;
  static const _rowHeight = 72.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static String _letter(Artist a) => indexLetter(a.sortName ?? a.name);

  /// Headings (letters) and artists, in display order.
  static List<Object> _rows(List<Artist> artists) {
    final rows = <Object>[];
    String? last;
    for (final a in artists) {
      final l = _letter(a);
      if (l != last) rows.add(l);
      rows.add(a);
      last = l;
    }
    return rows;
  }

  void _jump(List<Object> rows, String letter) {
    var offset = 0.0;
    for (final r in rows) {
      if (r == letter) break;
      offset += r is String ? _headerHeight : _rowHeight;
    }
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _scroll.jumpTo(offset.clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final artists = ref.watch(artistsProvider);
    final rows = _rows(artists.value ?? const []);
    final available = {
      for (final r in rows)
        if (r is String) r,
    };
    return ListScaffold(
      title: 'Artists',
      controller: _scroll,
      onRefresh: () => ref.refresh(artistsProvider.future),
      jumpBar: rows.length > 30
          ? JumpBar(available: available, onJump: (l) => _jump(rows, l))
          : null,
      slivers: [
        AsyncSliver(
          value: artists,
          onRetry: () => ref.invalidate(artistsProvider),
          builder: (list) {
            if (list.isEmpty) {
              return const SliverToBoxAdapter(
                child: EmptyMessage(
                  icon: Icons.person_outline,
                  text: 'No artists',
                ),
              );
            }
            return SliverPadding(
              padding: const EdgeInsets.only(right: JumpBar.width),
              sliver: SliverVariedExtentList.builder(
                itemCount: rows.length,
                itemExtentBuilder: (i, _) => i >= rows.length
                    ? null
                    : rows[i] is String
                    ? _headerHeight
                    : _rowHeight,
                itemBuilder: (context, i) {
                  final r = rows[i];
                  if (r is Artist) return _ArtistTile(artist: r);
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: Text(
                      r as String,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(color: oampAccent),
                    ),
                  );
                },
              ),
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

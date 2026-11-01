import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../../state/session.dart';
import '../async_view.dart';
import '../browser.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';
import 'playlists_view.dart';

/// Shelf titles for each kind of release, in page order.
const _releaseShelves = [
  (ReleaseKind.album, 'Albums'),
  (ReleaseKind.single, 'Singles & EPs'),
  (ReleaseKind.live, 'Live'),
  (ReleaseKind.compilation, 'Compilations'),
];

List<Album> _newestFirst(Iterable<Album> albums) =>
    [...albums]..sort((x, y) => (y.year ?? 0).compareTo(x.year ?? 0));

/// An artist: their photo across the top with the name over it, play,
/// shuffle and radio, popular tracks, releases by kind, similar artists and
/// a short biography.
class ArtistPage extends ConsumerWidget {
  final Artist artist;
  const ArtistPage({super.key, required this.artist});

  static const _topShown = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(artistDetailProvider(artist.id));
    final a = detail.value?.artist ?? artist;
    final albums = _newestFirst(detail.value?.albums ?? const []);
    final top =
        ref.watch(topTracksProvider((id: artist.id, name: a.name))).value ??
        const <Track>[];
    final info = ref.watch(artistInfoProvider(artist.id)).value;
    final similar = ref.read(musicSourceProvider).capabilities.hasSimilar;
    final player = ref.read(playerProvider.notifier);

    Future<void> play({bool shuffle = false}) async {
      try {
        final tracks = await ref.read(artistTracksProvider(artist.id).future);
        await player.playTracks(tracks, shuffle: shuffle, from: a.name);
      } catch (e) {
        if (context.mounted) toast(context, 'Could not load tracks: $e');
      }
    }

    Future<void> refresh() async {
      ref.invalidate(artistInfoProvider(artist.id));
      ref.invalidate(topTracksProvider((id: artist.id, name: a.name)));
      ref.invalidate(artistDetailProvider(artist.id));
      await ref.read(artistDetailProvider(artist.id).future);
    }

    return DetailScaffold(
      title: a.name,
      titleAfter: 260,
      hero: _Hero(artist: a, albumCount: albums.length),
      onRefresh: refresh,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: PlayShuffleButtons(
              onPlay: albums.isEmpty ? null : () => play(),
              onShuffle: albums.isEmpty ? null : () => play(shuffle: true),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (similar)
                    IconButton(
                      tooltip: 'Artist radio',
                      icon: const Icon(Icons.radio_rounded),
                      onPressed: () =>
                          startRadio(context, ref, id: a.id, name: a.name),
                    ),
                  LikeButton(
                    target: LikeTarget.artist,
                    id: a.id,
                    fetched: a.liked,
                    what: 'artist',
                  ),
                ],
              ),
            ),
          ),
        ),
        if (top.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionHeader(
              'Popular',
              onSeeAll: top.length > _topShown
                  ? () => openPage(_TopTracksPage(artist: a))
                  : null,
            ),
          ),
          SliverList.builder(
            itemCount: top.length.clamp(0, _topShown),
            itemBuilder: (_, i) => TrackTile(
              track: top[i],
              showArtist: false,
              onTap: () => player.playTracks(
                top,
                startIndex: i,
                from: '${a.name}: popular',
              ),
            ),
          ),
        ],
        AsyncSliver(
          value: detail,
          onRetry: () => ref.invalidate(artistDetailProvider(artist.id)),
          builder: (_) => SliverList.list(
            children: [
              if (albums.isEmpty)
                const EmptyMessage(
                  icon: Icons.album_outlined,
                  text: 'No albums by this artist',
                ),
              for (final (kind, title) in _releaseShelves)
                if (albums.where((x) => x.kind == kind).toList()
                    case final shelf when shelf.isNotEmpty)
                  _ReleaseShelf(
                    title: title,
                    albums: shelf,
                    onSeeAll: () =>
                        openPage(_ReleasesPage(title: title, albums: shelf)),
                  ),
              if (info != null && info.similar.isNotEmpty)
                HorizontalShelf(
                  title: 'Similar artists',
                  height: 140,
                  spacing: 16,
                  itemCount: info.similar.length,
                  itemBuilder: (_, i) =>
                      ArtistBubble(artist: info.similar[i], size: 100),
                ),
              if (info?.biography != null)
                _About(name: a.name, biography: info!.biography!),
            ],
          ),
        ),
      ],
    );
  }
}

/// The artist's photo filling the top of the page, fading into the
/// background, with their name over the bottom of it.
class _Hero extends StatelessWidget {
  final Artist artist;
  final int albumCount;
  const _Hero({required this.artist, required this.albumCount});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth > c.maxHeight ? c.maxWidth : c.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            OverflowBox(
              maxWidth: side,
              maxHeight: side,
              alignment: Alignment.topCenter,
              child: CoverArt(
                artist.coverArt,
                size: side,
                radius: 0,
                placeholderIcon: Icons.person_rounded,
              ),
            ),
            // Darkens the top so the back button and mode switch show on
            // light photos, and fades the bottom into the page.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.25, 0.55, 1],
                  colors: [
                    Color(0x99000000),
                    Color(0x00000000),
                    Color(0x00000000),
                    oampBackground,
                  ],
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    artist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                      height: 1.05,
                    ),
                  ),
                  if (albumCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '$albumCount release${albumCount == 1 ? '' : 's'}',
                        style: t.bodyMedium?.copyWith(
                          color: OAmpColors.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReleaseShelf extends StatelessWidget {
  final String title;
  final List<Album> albums;
  final VoidCallback onSeeAll;
  const _ReleaseShelf({
    required this.title,
    required this.albums,
    required this.onSeeAll,
  });

  static const _card = 148.0;

  @override
  Widget build(BuildContext context) {
    return HorizontalShelf(
      title: title,
      onSeeAll: albums.length > 2 ? onSeeAll : null,
      height: _card + 52,
      itemCount: albums.length,
      itemBuilder: (_, i) => SizedBox(
        width: _card,
        child: AlbumCard(album: albums[i], size: _card, showArtist: false),
      ),
    );
  }
}

/// The biography, a few lines at a time.
class _About extends StatefulWidget {
  final String name;
  final String biography;
  const _About({required this.name, required this.biography});

  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('About ${widget.name}'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _open = !_open),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: OAmpColors.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.biography,
                    maxLines: _open ? null : 4,
                    overflow: _open ? null : TextOverflow.ellipsis,
                    style: t.bodyMedium?.copyWith(
                      color: OAmpColors.textMuted,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _open ? 'Show less' : 'Read more',
                    style: t.labelLarge?.copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TopTracksPage extends ConsumerWidget {
  final Artist artist;
  const _TopTracksPage({required this.artist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (id: artist.id, name: artist.name);
    final tracks = ref.watch(topTracksProvider(key));
    final n = tracks.value?.length;
    return TrackListPage(
      title: 'Popular tracks',
      subtitle: [
        artist.name,
        if (n != null) '$n track${n == 1 ? '' : 's'}',
      ].join(' · '),
      coverArt: artist.coverArt,
      icon: Icons.person_rounded,
      tracks: tracks,
      onRefresh: () => ref.refresh(topTracksProvider(key).future),
      onRetry: () => ref.invalidate(topTracksProvider(key)),
    );
  }
}

class _ReleasesPage extends StatelessWidget {
  final String title;
  final List<Album> albums;
  const _ReleasesPage({required this.title, required this.albums});

  @override
  Widget build(BuildContext context) {
    return ListScaffold(
      title: title,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: AlbumSliverGrid(albums: albums, showArtist: false),
        ),
      ],
    );
  }
}

/// Columns that adapt to the width, for grids of album cards.
const albumGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 200,
  mainAxisSpacing: 16,
  crossAxisSpacing: 14,
  childAspectRatio: 0.74,
);

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
      gridDelegate: albumGridDelegate,
      itemCount: albums.length,
      itemBuilder: (_, i) =>
          AlbumCard(album: albums[i], showArtist: showArtist),
    );
  }
}

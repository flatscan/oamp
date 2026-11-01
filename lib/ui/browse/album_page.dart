import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../async_view.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';

/// An album: large centred cover, title, artist, play and shuffle, the
/// tracks grouped by disc, then more releases by the same artist.
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

    final artistId = a.artistId;
    final moreBy = artistId == null
        ? null
        : ref
              .watch(artistDetailProvider(artistId))
              .whenData(
                (d) => [
                  for (final x in d.albums)
                    if (x.id != a.id) x,
                ]..sort((x, y) => (y.year ?? 0).compareTo(x.year ?? 0)),
              );
    final total = tracks.fold(
      Duration.zero,
      (sum, tr) => sum + (tr.duration ?? Duration.zero),
    );

    return DetailScaffold(
      title: a.name,
      titleAfter: 300,
      onRefresh: () => ref.refresh(albumDetailProvider(album.id).future),
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
        if (tracks.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text(
                [
                  '${tracks.length} track${tracks.length == 1 ? '' : 's'}',
                  if (total > Duration.zero) formatLongDuration(total),
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: OAmpColors.textFaint),
              ),
            ),
          ),
        if (moreBy != null && a.artist != null)
          SliverToBoxAdapter(
            child: AlbumCarousel(
              title: 'More by ${a.artist}',
              albums: moreBy,
              showArtist: false,
              onSeeAll: () => openArtistById(artistId!, a.artist!),
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
    final kind = switch (album.kind) {
      ReleaseKind.album => null,
      ReleaseKind.single => album.releaseTypes.contains('ep') ? 'EP' : 'Single',
      ReleaseKind.live => 'Live',
      ReleaseKind.compilation => 'Compilation',
    };
    final meta = [
      ?kind,
      if (album.year != null) '${album.year}',
      ?album.genre,
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
              PlayShuffleButtons(
                onPlay: onPlay,
                onShuffle: onShuffle,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LikeButton(
                      target: LikeTarget.album,
                      id: album.id,
                      fetched: album.liked,
                      what: 'album',
                    ),
                    Consumer(
                      builder: (context, ref, _) => IconButton(
                        tooltip: 'More',
                        icon: const Icon(Icons.more_horiz_rounded),
                        onPressed: () => showAlbumMenu(
                          context,
                          ref,
                          album,
                          at: centreOf(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

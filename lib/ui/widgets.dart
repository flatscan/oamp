import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/library.dart';
import '../state/player.dart';
import 'browse/album_page.dart';
import 'browse/artist_page.dart';
import 'browser.dart';
import 'cover_art.dart';
import 'theme.dart';

void toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
}

void openAlbum(Album album) => openPage(AlbumPage(album: album));

void openAlbumById(String id, String name) =>
    openAlbum(Album(id: id, name: name));

void openArtist(Artist artist) => openPage(ArtistPage(artist: artist));

void openArtistById(String id, String name) =>
    openArtist(Artist(id: id, name: name));

/// A section title with an optional "See all" link.
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  const SectionHeader(this.title, {super.key, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          if (onSeeAll != null)
            TextButton(
              onPressed: onSeeAll,
              style: TextButton.styleFrom(
                foregroundColor: OAmpColors.textMuted,
              ),
              child: const Text('See all'),
            ),
        ],
      ),
    );
  }
}

/// Cover, title and subtitle, used in rows and grids of albums. Hovering
/// the cover shows a play button that plays the album without opening it.
class AlbumCard extends ConsumerWidget {
  final Album album;
  final double? size;
  final bool showArtist;
  const AlbumCard({
    super.key,
    required this.album,
    this.size,
    this.showArtist = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final sub = [
      if (showArtist) album.artist,
      if (!showArtist) album.year,
    ].whereType<Object>().join(' · ');
    Future<void> play() async {
      try {
        final detail = await ref.read(albumDetailProvider(album.id).future);
        await ref
            .read(playerProvider.notifier)
            .playTracks(detail.tracks, from: detail.album.name);
      } catch (e) {
        if (context.mounted) toast(context, 'Could not play album: $e');
      }
    }

    return Semantics(
      button: true,
      label: album.name,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        // The cover's own hover overlay is the hover cue.
        hoverColor: Colors.transparent,
        onTap: () => openAlbum(album),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (_, c) => HoverPlay(
                tooltip: 'Play ${album.name}',
                onPlay: play,
                radius: 8,
                child: CoverArt(
                  album.coverArt,
                  size: size ?? c.maxWidth,
                  radius: 8,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (sub.isNotEmpty)
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

/// Shows a round play button over [child] while the mouse is over it, and
/// dims the cover a little so the button stands out.
class HoverPlay extends StatefulWidget {
  final Widget child;
  final Future<void> Function() onPlay;
  final String tooltip;
  final double radius;
  final bool circle;

  const HoverPlay({
    super.key,
    required this.child,
    required this.onPlay,
    required this.tooltip,
    this.radius = 0,
    this.circle = false,
  });

  @override
  State<HoverPlay> createState() => _HoverPlayState();
}

class _HoverPlayState extends State<HoverPlay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        alignment: Alignment.center,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius: widget.circle
                        ? null
                        : BorderRadius.circular(widget.radius),
                  ),
                ),
              ),
            ),
          ),
          AnimatedScale(
            scale: _hover ? 1 : 0.6,
            duration: const Duration(milliseconds: 150),
            child: AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: IgnorePointer(
                ignoring: !_hover,
                child: IconButton.filled(
                  tooltip: widget.tooltip,
                  iconSize: 40,
                  padding: const EdgeInsets.all(12),
                  style: IconButton.styleFrom(
                    backgroundColor: oampAccent,
                    foregroundColor: Colors.black,
                    elevation: 4,
                  ),
                  onPressed: widget.onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A horizontally scrolling row of albums under a heading. Hidden when the
/// list is empty, so sections the server has no data for do not show.
class AlbumCarousel extends StatelessWidget {
  final String title;
  final AsyncValue<List<Album>> albums;
  final VoidCallback? onSeeAll;
  const AlbumCarousel({
    super.key,
    required this.title,
    required this.albums,
    this.onSeeAll,
  });

  static const _cardSize = 148.0;

  @override
  Widget build(BuildContext context) {
    final list = albums.value;
    if (list != null && list.isEmpty) return const SizedBox.shrink();
    if (list == null && albums.hasError) return const SizedBox.shrink();
    if (list == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title),
          const SizedBox(
            height: _cardSize + 52,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ],
      );
    }
    return HorizontalShelf(
      title: title,
      onSeeAll: onSeeAll,
      height: _cardSize + 52,
      itemCount: list.length,
      itemBuilder: (_, i) => SizedBox(
        width: _cardSize,
        child: AlbumCard(album: list[i], size: _cardSize),
      ),
    );
  }
}

/// A titled row that scrolls sideways on its own. With a mouse it can be
/// dragged, scrolled with Shift + wheel, or stepped a page at a time with
/// the arrows in the heading; trackpads and touch scroll it directly.
class HorizontalShelf extends StatefulWidget {
  final String title;
  final VoidCallback? onSeeAll;
  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double spacing;

  const HorizontalShelf({
    super.key,
    required this.title,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.onSeeAll,
    this.spacing = 14,
  });

  @override
  State<HorizontalShelf> createState() => _HorizontalShelfState();
}

class _HorizontalShelfState extends State<HorizontalShelf> {
  final _controller = ScrollController();
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted || !_controller.hasClients) return;
    final p = _controller.position;
    final back = p.pixels > p.minScrollExtent + 1;
    final forward = p.pixels < p.maxScrollExtent - 1;
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  void _page(int direction) {
    final p = _controller.position;
    final target = (p.pixels + direction * p.viewportDimension * 0.8).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  /// Shift + wheel over the row scrolls it sideways. A plain wheel turn
  /// still scrolls the page, so the rows never trap vertical scrolling.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_controller.hasClients) return;
    if (!HardwareKeyboard.instance.isShiftPressed) return;
    final dy = e.scrollDelta.dy;
    if (dy == 0 || e.scrollDelta.dx != 0) return;
    final p = _controller.position;
    final target = (p.pixels + dy).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (target == p.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      _controller.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (widget.onSeeAll != null)
                TextButton(
                  onPressed: widget.onSeeAll,
                  style: TextButton.styleFrom(
                    foregroundColor: OAmpColors.textMuted,
                  ),
                  child: const Text('See all'),
                ),
              if (_canBack || _canForward) ...[
                IconButton(
                  tooltip: 'Scroll ${widget.title} back',
                  visualDensity: VisualDensity.compact,
                  onPressed: _canBack ? () => _page(-1) : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                IconButton(
                  tooltip: 'Scroll ${widget.title} forward',
                  visualDensity: VisualDensity.compact,
                  onPressed: _canForward ? () => _page(1) : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ],
          ),
        ),
        SizedBox(
          height: widget.height,
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                _update();
                return false;
              },
              child: ScrollConfiguration(
                // Let a mouse drag the row as well as touch and trackpad.
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: PointerDeviceKind.values.toSet(),
                  scrollbars: false,
                ),
                child: ListView.separated(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: widget.itemCount,
                  separatorBuilder: (_, _) => SizedBox(width: widget.spacing),
                  itemBuilder: widget.itemBuilder,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Round artist picture with the name beneath.
class ArtistBubble extends ConsumerWidget {
  final Artist artist;
  final double size;
  const ArtistBubble({super.key, required this.artist, this.size = 112});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> play() async {
      try {
        final tracks = await ref.read(artistTracksProvider(artist.id).future);
        await ref
            .read(playerProvider.notifier)
            .playTracks(tracks, from: artist.name);
      } catch (e) {
        if (context.mounted) toast(context, 'Could not play artist: $e');
      }
    }

    return InkWell(
      borderRadius: BorderRadius.circular(size),
      onTap: () => openArtist(artist),
      child: SizedBox(
        width: size,
        child: Column(
          children: [
            HoverPlay(
              tooltip: 'Play ${artist.name}',
              onPlay: play,
              circle: true,
              child: CoverArt(
                artist.coverArt,
                size: size,
                circle: true,
                placeholderIcon: Icons.person_rounded,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              artist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// White "Play" and outlined "Shuffle" pills used at the top of album,
/// artist and playlist pages.
class PlayShuffleButtons extends StatelessWidget {
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final Widget? trailing;
  const PlayShuffleButtons({
    super.key,
    required this.onPlay,
    required this.onShuffle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final pill = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(28),
    );
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(shape: pill),
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(shape: pill),
            onPressed: onShuffle,
            icon: const Icon(Icons.shuffle_rounded),
            label: const Text('Shuffle'),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 4), trailing!],
      ],
    );
  }
}

/// A page with a pinned top bar whose title fades in once the page's own
/// header has scrolled away, the way album and artist pages behave.
class DetailScaffold extends StatefulWidget {
  final String title;
  final List<Widget> slivers;
  final List<Widget>? actions;
  final double titleAfter;
  final Future<void> Function()? onRefresh;

  const DetailScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.actions,
    this.titleAfter = 220,
    this.onRefresh,
  });

  @override
  State<DetailScaffold> createState() => _DetailScaffoldState();
}

class _DetailScaffoldState extends State<DetailScaffold> {
  bool _showTitle = false;

  @override
  Widget build(BuildContext context) {
    Widget body = CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          title: AnimatedOpacity(
            opacity: _showTitle ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Text(widget.title, maxLines: 1),
          ),
          actions: widget.actions,
        ),
        ...widget.slivers,
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
    if (widget.onRefresh != null) {
      body = RefreshIndicator(onRefresh: widget.onRefresh!, child: body);
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) {
          if (n.depth == 0) {
            final show = n.metrics.pixels > widget.titleAfter;
            if (show != _showTitle) setState(() => _showTitle = show);
          }
          return false;
        },
        child: body,
      ),
    );
  }
}

/// Plain list page with a big title, such as Artists or Playlists.
class ListScaffold extends StatelessWidget {
  final String title;
  final List<Widget> slivers;
  final List<Widget>? actions;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;
  final double toolbarHeight;

  const ListScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.actions,
    this.onRefresh,
    this.controller,
    this.toolbarHeight = kToolbarHeight,
  });

  @override
  Widget build(BuildContext context) {
    Widget body = CustomScrollView(
      controller: controller,
      slivers: [
        SliverAppBar(
          pinned: true,
          title: Text(title, style: Theme.of(context).textTheme.headlineSmall),
          actions: actions,
        ),
        ...slivers,
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
    if (onRefresh != null) {
      body = RefreshIndicator(onRefresh: onRefresh!, child: body);
    }
    return Scaffold(backgroundColor: Colors.transparent, body: body);
  }
}

/// One track in a list. Tap plays; the menu button, a right-click or a long
/// press opens actions for it.
class TrackTile extends ConsumerWidget {
  final Track track;
  final VoidCallback onTap;

  /// Shown in place of the cover when set, such as the track number.
  final String? number;
  final bool showArtist;
  final bool showAlbumLinks;

  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.number,
    this.showArtist = true,
    this.showAlbumLinks = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final isCurrent = ref.watch(
      playerProvider.select((s) => s.current?.id == track.id),
    );
    final playing = ref.watch(playerProvider.select((s) => s.playing));
    final liked = ref.watch(
      likesProvider.select((m) => m[track.id] ?? track.liked),
    );

    final Widget leading = number != null
        ? SizedBox(
            width: 28,
            child: isCurrent
                ? Icon(
                    playing ? Icons.graphic_eq_rounded : Icons.pause_rounded,
                    color: oampAccent,
                    size: 20,
                  )
                : Text(
                    number!,
                    textAlign: TextAlign.center,
                    style: t.bodyMedium?.copyWith(color: OAmpColors.textFaint),
                  ),
          )
        : CoverArt(track.coverArt, size: 44, radius: 4);

    return GestureDetector(
      onSecondaryTapUp: (d) => showTrackMenu(
        context,
        ref,
        track,
        at: d.globalPosition,
        showAlbumLinks: showAlbumLinks,
      ),
      child: ListTile(
        onTap: onTap,
        onLongPress: () =>
            showTrackMenu(context, ref, track, showAlbumLinks: showAlbumLinks),
        leading: leading,
        minLeadingWidth: 28,
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.bodyLarge?.copyWith(
            color: isCurrent ? oampAccent : null,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: showArtist && track.artist != null
            ? Text(
                track.artist!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall,
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (liked)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.favorite_rounded,
                  size: 14,
                  color: oampAccent,
                ),
              ),
            Text(
              formatDuration(track.duration),
              style: t.bodySmall?.copyWith(color: OAmpColors.textFaint),
            ),
            Builder(
              builder: (btnContext) => IconButton(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert_rounded, size: 20),
                onPressed: () {
                  final box = btnContext.findRenderObject() as RenderBox;
                  showTrackMenu(
                    context,
                    ref,
                    track,
                    at: box.localToGlobal(box.size.center(Offset.zero)),
                    showAlbumLinks: showAlbumLinks,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TrackAction { playNext, enqueue, like, album, artist }

/// The actions menu for a track, at [at] (or the centre of the screen).
Future<void> showTrackMenu(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  Offset? at,
  bool showAlbumLinks = true,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final pos = at ?? overlay.size.center(Offset.zero);
  final liked = ref.read(likesProvider.notifier).isLiked(track);
  final action = await showMenu<_TrackAction>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(pos.dx, pos.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      const PopupMenuItem(
        value: _TrackAction.playNext,
        child: ListTile(
          leading: Icon(Icons.playlist_play_rounded),
          title: Text('Play next'),
        ),
      ),
      const PopupMenuItem(
        value: _TrackAction.enqueue,
        child: ListTile(
          leading: Icon(Icons.playlist_add_rounded),
          title: Text('Add to queue'),
        ),
      ),
      PopupMenuItem(
        value: _TrackAction.like,
        child: ListTile(
          leading: Icon(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          ),
          title: Text(liked ? 'Unlike' : 'Like'),
        ),
      ),
      if (showAlbumLinks && track.albumId != null)
        const PopupMenuItem(
          value: _TrackAction.album,
          child: ListTile(
            leading: Icon(Icons.album_rounded),
            title: Text('Go to album'),
          ),
        ),
      if (showAlbumLinks && track.artistId != null)
        const PopupMenuItem(
          value: _TrackAction.artist,
          child: ListTile(
            leading: Icon(Icons.person_rounded),
            title: Text('Go to artist'),
          ),
        ),
    ],
  );
  if (action == null || !context.mounted) return;
  final player = ref.read(playerProvider.notifier);
  switch (action) {
    case _TrackAction.playNext:
      await player.playNext([track]);
      if (context.mounted) toast(context, 'Playing "${track.title}" next');
    case _TrackAction.enqueue:
      await player.enqueue([track]);
      if (context.mounted) toast(context, 'Added "${track.title}" to queue');
    case _TrackAction.like:
      await toggleLike(context, ref, track);
    case _TrackAction.album:
      openAlbumById(track.albumId!, track.album ?? '');
    case _TrackAction.artist:
      openArtistById(track.artistId!, track.artist ?? '');
  }
}

Future<void> toggleLike(BuildContext context, WidgetRef ref, Track t) async {
  try {
    await ref.read(likesProvider.notifier).toggle(t);
  } catch (e) {
    if (context.mounted) toast(context, 'Could not update like: $e');
  }
}

/// Centered message for empty lists.
class EmptyMessage extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyMessage({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: OAmpColors.textFaint),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: OAmpColors.textMuted),
          ),
        ],
      ),
    );
  }
}

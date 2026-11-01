import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';
import 'art_colors.dart';
import 'controls.dart';
import 'queue_view.dart';

/// Opens the full-screen now playing view over the whole column.
void showNowPlaying(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, _, _) =>
          NowPlayingView(onClose: () => Navigator.of(context).maybePop()),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: child,
      ),
    ),
  );
}

/// Big artwork tinted by its own colours, track details, seek bar and
/// controls. "Up next" swaps the artwork for the queue.
///
/// [onClose] shows a close chevron; the desktop fly-out layout embeds this
/// view permanently and leaves it null.
class NowPlayingView extends ConsumerStatefulWidget {
  final VoidCallback? onClose;
  const NowPlayingView({super.key, this.onClose});

  @override
  ConsumerState<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends ConsumerState<NowPlayingView> {
  bool _showQueue = false;

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(playerProvider.select((s) => s.current));
    final from = ref.watch(playerProvider.select((s) => s.from));
    final tint = track == null
        ? null
        : ref.watch(artColorProvider(track.coverArt)).value;

    final body = SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            _TopBar(onClose: widget.onClose, from: from, track: track),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _showQueue
                    ? const Padding(
                        key: ValueKey('queue'),
                        padding: EdgeInsets.only(top: 8),
                        child: QueueView(),
                      )
                    : _Artwork(key: const ValueKey('art'), track: track),
              ),
            ),
            const SizedBox(height: 16),
            _TrackInfo(track: track),
            const SizedBox(height: 4),
            const Scrubber(),
            const SizedBox(height: 4),
            const TransportControls(),
            const SizedBox(height: 4),
            Row(
              children: [
                const Expanded(child: VolumeControl()),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: _showQueue ? 'Show artwork' : 'Up next',
                  isSelected: _showQueue,
                  color: OAmpColors.textMuted,
                  selectedIcon: const Icon(
                    Icons.queue_music_rounded,
                    color: oampAccent,
                  ),
                  icon: const Icon(Icons.queue_music_rounded),
                  onPressed: () => setState(() => _showQueue = !_showQueue),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        if (widget.onClose != null)
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose!,
      },
      child: Focus(
        autofocus: widget.onClose != null,
        child: Material(
          color: oampBackground,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: tint ?? const Color(0xFF3A3A40)),
            duration: const Duration(milliseconds: 600),
            builder: (context, c, child) => DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.55, 1],
                  colors: [
                    Color.lerp(c, Colors.black, 0.45)!,
                    Color.lerp(c, Colors.black, 0.82)!,
                    oampBackground,
                  ],
                ),
              ),
              child: child,
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  final VoidCallback? onClose;
  final String? from;
  final Track? track;
  const _TopBar({required this.onClose, required this.from, this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final tr = track;
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: onClose == null
                ? null
                : IconButton(
                    tooltip: 'Close',
                    iconSize: 32,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    onPressed: onClose,
                  ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (from != null) ...[
                  Text(
                    'PLAYING FROM',
                    style: t.labelSmall?.copyWith(
                      color: OAmpColors.textMuted,
                      letterSpacing: 1.4,
                    ),
                  ),
                  Text(
                    from!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: tr == null
                ? null
                : Builder(
                    builder: (btn) => IconButton(
                      tooltip: 'More',
                      icon: const Icon(Icons.more_horiz_rounded),
                      onPressed: () {
                        final box = btn.findRenderObject() as RenderBox;
                        showTrackMenu(
                          context,
                          ref,
                          tr,
                          at: box.localToGlobal(box.size.center(Offset.zero)),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The cover, as large as fits. Swipe sideways to change track.
class _Artwork extends ConsumerWidget {
  final Track? track;
  const _Artwork({super.key, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.read(playerProvider.notifier);
    return LayoutBuilder(
      builder: (context, c) {
        final size = (c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight)
            .clamp(80.0, 640.0);
        return GestureDetector(
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300) p.next();
            if (v > 300) p.previous();
          },
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: DecoratedBox(
                key: ValueKey(track?.id),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 40,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: CoverArt(
                  track?.coverArt,
                  size: size,
                  radius: 12,
                  placeholderIcon: track == null
                      ? Icons.music_note_rounded
                      : Icons.album_rounded,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackInfo extends ConsumerWidget {
  final Track? track;
  const _TrackInfo({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final tr = track;
    final liked =
        tr != null &&
        ref.watch(likesProvider.select((m) => m[tr.id] ?? tr.liked));
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr?.title ?? 'Nothing playing',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.headlineSmall?.copyWith(fontSize: 22),
              ),
              const SizedBox(height: 2),
              if (tr != null)
                DefaultTextStyle.merge(
                  style: t.bodyLarge?.copyWith(color: OAmpColors.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: Row(
                    children: [
                      if (tr.artist != null)
                        Flexible(
                          child: _Link(
                            tr.artist!,
                            onTap: tr.artistId == null
                                ? null
                                : () =>
                                      openArtistById(tr.artistId!, tr.artist!),
                          ),
                        ),
                      if (tr.artist != null && tr.album != null)
                        const Text('  ·  '),
                      if (tr.album != null)
                        Flexible(
                          child: _Link(
                            tr.album!,
                            onTap: tr.albumId == null
                                ? null
                                : () => openAlbumById(tr.albumId!, tr.album!),
                          ),
                        ),
                    ],
                  ),
                )
              else
                Text(
                  'Pick something from your library',
                  style: t.bodyLarge?.copyWith(color: OAmpColors.textMuted),
                ),
            ],
          ),
        ),
        if (tr != null)
          IconButton(
            tooltip: liked ? 'Unlike' : 'Like',
            iconSize: 26,
            color: liked ? oampAccent : OAmpColors.textMuted,
            icon: Icon(
              liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            ),
            onPressed: () => toggleLike(context, ref, tr),
          ),
      ],
    );
  }
}

/// Text that underlines on hover and opens a page when clicked.
class _Link extends StatefulWidget {
  final String text;
  final VoidCallback? onTap;
  const _Link(this.text, {this.onTap});

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      style: _hover
          ? const TextStyle(decoration: TextDecoration.underline)
          : null,
    );
    if (widget.onTap == null) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: widget.onTap, child: text),
    );
  }
}

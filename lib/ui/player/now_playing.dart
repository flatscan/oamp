import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';
import '../app_frame.dart';
import '../mode_switch.dart';
import 'art_colors.dart';
import 'controls.dart';
import 'queue_list.dart';

/// Opens the full-screen now playing view over the whole column.
/// [animate] false shows it at once, as when switching back from expanded
/// mode.
void showNowPlaying(BuildContext context, {bool animate = true}) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: animate
          ? const Duration(milliseconds: 320)
          : Duration.zero,
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

/// One scrolling screen: the cover edge to edge at the top, then the seek
/// bar, track details and controls, then the queue directly below. The
/// whole screen is tinted from the cover.
///
/// [onClose] adds a close button (and Esc); the desktop fly-out layout embeds
/// this view permanently and leaves it null.
class NowPlayingView extends ConsumerStatefulWidget {
  final VoidCallback? onClose;
  const NowPlayingView({super.key, this.onClose});

  @override
  ConsumerState<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends ConsumerState<NowPlayingView> {
  /// Where the screen was scrolled to, shared by every copy of it, so the
  /// full-screen view and the expanded column's view pick up in the same
  /// place when switching modes.
  static double _sharedOffset = 0;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _sharedOffset,
  )..addListener(() => _sharedOffset = _scroll.offset);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onClose = widget.onClose;
    final track = ref.watch(playerProvider.select((s) => s.current));
    final tint = track == null
        ? null
        : ref.watch(artColorProvider(track.coverArt)).value;
    final base = tint ?? const Color(0xFF4A4A52);

    final view = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: base),
      duration: const Duration(milliseconds: 600),
      builder: (context, c, _) {
        // A muted version of the cover's colour for the play button and
        // sliders, light enough to read on the dark background.
        final hsl = HSLColor.fromColor(c!);
        final accent = hsl
            .withSaturation((hsl.saturation * 0.7).clamp(0.0, 0.6))
            .withLightness(0.62)
            .toColor();
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(c, Colors.black, 0.55)!,
                Color.lerp(c, Colors.black, 0.72)!,
              ],
            ),
          ),
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Stack(
                  children: [
                    _Artwork(track: track),
                    Positioned(
                      top: 8,
                      left: 8,
                      right: 8,
                      child: _ArtOverlayBar(onClose: onClose),
                    ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _Controls(track: track, accent: accent),
                  ),
                ),
              ),
              const QueueSlivers(),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        );
      },
    );

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): ?onClose},
      child: Focus(
        autofocus: onClose != null,
        child: Material(color: oampBackground, child: view),
      ),
    );
  }
}

/// Buttons over the top of the artwork: close in the middle (when shown
/// full-screen) and the mode switch at the top right. On Windows the
/// strip also moves the window, for when the title bar is hidden.
class _ArtOverlayBar extends StatelessWidget {
  final VoidCallback? onClose;
  const _ArtOverlayBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final bar = SizedBox(
      height: ModeSwitchButton.size,
      child: Row(
        children: [
          const SizedBox(width: ModeSwitchButton.size),
          Expanded(
            child: Center(
              child: onClose == null
                  ? null
                  : IconButton(
                      tooltip: 'Close',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black45,
                        foregroundColor: Colors.white,
                        hoverColor: Colors.white24,
                      ),
                      iconSize: 30,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      onPressed: onClose,
                    ),
            ),
          ),
          const ModeSwitchButton(),
        ],
      ),
    );
    return WindowDragArea(child: bar);
  }
}

/// The cover across the full width, square, at most 560 wide. Swipe
/// sideways to change track.
class _Artwork extends ConsumerWidget {
  final Track? track;
  const _Artwork({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.read(playerProvider.notifier);
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.maxWidth.clamp(0.0, 560.0);
        final wide = c.maxWidth > size;
        return GestureDetector(
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300) p.next();
            if (v > 300) p.previous();
          },
          child: Padding(
            padding: EdgeInsets.only(top: wide ? 16 : 0),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: CoverArt(
                  track?.coverArt,
                  key: ValueKey(track?.id),
                  size: size,
                  radius: wide ? 10 : 0,
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

class _Controls extends ConsumerWidget {
  final Track? track;
  final Color accent;
  const _Controls({required this.track, required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final tr = track;
    final quality = tr == null ? null : qualityLabel(tr);
    final liked =
        tr != null &&
        ref.watch(likesProvider.select((m) => m[tr.id] ?? tr.liked));
    final albumLine = tr?.album == null
        ? null
        : tr!.year == null
        ? tr.album!
        : '${tr.album} (${tr.year})';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        children: [
          SeekBar(accent: accent),
          const SizedBox(height: 10),
          if (tr == null) ...[
            Text('Nothing playing', style: t.titleLarge),
            const SizedBox(height: 2),
            Text(
              'Pick something from your library',
              style: t.bodyLarge?.copyWith(color: OAmpColors.textMuted),
            ),
          ] else ...[
            if (tr.artist != null)
              _Link(
                tr.artist!,
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w500),
                onTap: tr.artistId == null
                    ? null
                    : () => openArtistById(tr.artistId!, tr.artist!),
              ),
            Text(
              tr.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (albumLine != null)
              _Link(
                albumLine,
                style: t.titleMedium?.copyWith(
                  color: OAmpColors.textMuted,
                  fontWeight: FontWeight.w400,
                ),
                onTap: tr.albumId == null
                    ? null
                    : () => openAlbumById(tr.albumId!, tr.album!),
              ),
            if (quality != null) ...[
              const SizedBox(height: 10),
              Text(
                quality,
                style: t.labelLarge?.copyWith(color: OAmpColors.textMuted),
              ),
            ],
          ],
          const SizedBox(height: 14),
          TransportControls(playColor: accent),
          const SizedBox(height: 8),
          VolumeControl(accent: accent),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Builder(
                builder: (btn) => IconButton(
                  tooltip: 'More',
                  color: OAmpColors.textMuted,
                  icon: const Icon(Icons.more_horiz_rounded),
                  onPressed: tr == null
                      ? null
                      : () {
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
              IconButton(
                tooltip: liked ? 'Unlike' : 'Like',
                color: liked ? oampAccent : OAmpColors.textMuted,
                icon: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                ),
                onPressed: tr == null
                    ? null
                    : () => toggleLike(context, ref, tr),
              ),
              const ShuffleButton(),
              const RepeatButton(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Text that underlines on hover and opens a page when clicked.
class _Link extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final VoidCallback? onTap;
  const _Link(this.text, {this.style, this.onTap});

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _hover
          ? widget.style?.copyWith(decoration: TextDecoration.underline)
          : widget.style,
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

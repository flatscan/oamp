import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../platform/platform_info.dart';
import '../../state/library.dart';
import '../../state/lyrics.dart';
import '../../state/player.dart';
import '../../state/settings.dart';
import '../cover_art.dart';
import '../theme.dart';
import '../widgets.dart';
import '../app_frame.dart';
import '../glyphs.dart';
import '../mode_switch.dart';
import '../rating_stars.dart';
import 'art_colors.dart';
import 'controls.dart';
import 'lyrics_view.dart';
import 'queue_list.dart';

/// Whether the single column is showing now playing over the browser.
/// [animate] says whether the last change should slide.
class NowPlayingSheet {
  final bool open;
  final bool animate;
  const NowPlayingSheet({this.open = false, this.animate = true});
}

final nowPlayingSheetProvider =
    NotifierProvider<NowPlayingSheetNotifier, NowPlayingSheet>(
      NowPlayingSheetNotifier.new,
    );

class NowPlayingSheetNotifier extends Notifier<NowPlayingSheet> {
  @override
  NowPlayingSheet build() => const NowPlayingSheet();

  void open({bool animate = true}) =>
      state = NowPlayingSheet(open: true, animate: animate);

  void close({bool animate = true}) =>
      state = NowPlayingSheet(open: false, animate: animate);
}

/// Slides now playing up over the single column. [animate] false shows it
/// at once, as when switching back from expanded mode.
void showNowPlaying(BuildContext context, {bool animate = true}) =>
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(nowPlayingSheetProvider.notifier).open(animate: animate);

/// Slides now playing back down, if it is open.
void hideNowPlaying(BuildContext context) => ProviderScope.containerOf(
  context,
  listen: false,
).read(nowPlayingSheetProvider.notifier).close();

/// One scrolling screen: the cover edge to edge at the top, then the seek
/// bar, track details and controls, then the queue directly below. The
/// whole screen is tinted from the cover.
///
/// [onClose] adds a close button on desktop (and Esc); the desktop fly-out
/// layout embeds this view permanently and leaves it null.
///
/// On a phone, pulling down from the top of the screen drags the view down:
/// [onPull] gets each move in pixels and [onPullEnd] the speed at release,
/// for the shell to slide the sheet with the finger and then close it or
/// settle it back. A phone on its side shows the cover beside the controls.
class NowPlayingView extends ConsumerStatefulWidget {
  final VoidCallback? onClose;
  final ValueChanged<double>? onPull;
  final ValueChanged<double>? onPullEnd;
  const NowPlayingView({super.key, this.onClose, this.onPull, this.onPullEnd});

  @override
  ConsumerState<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends ConsumerState<NowPlayingView> {
  /// Where the screen was scrolled to, kept when the sheet is closed so it
  /// reopens in the same place.
  static double _savedOffset = 0;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _savedOffset,
  )..addListener(() => _savedOffset = _scroll.offset);

  final _focus = FocusNode(debugLabel: 'now playing');

  // A finger pulling the sheet down: which pointer, where it went down,
  // whether it has started pulling, and how fast it moves.
  int? _pointer;
  Offset _downAt = Offset.zero;
  bool _pulling = false;
  VelocityTracker? _velocity;

  bool get _atTop => !_scroll.hasClients || _scroll.offset <= 0;

  void _pointerDown(PointerDownEvent e) {
    if (widget.onPull == null || _pointer != null) return;
    // Touch only: a mouse drag on desktop keeps doing nothing.
    if (e.kind != PointerDeviceKind.touch &&
        e.kind != PointerDeviceKind.stylus) {
      return;
    }
    _pointer = e.pointer;
    _downAt = e.position;
    _pulling = false;
    _velocity = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.position);
  }

  void _pointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _velocity?.addPosition(e.timeStamp, e.position);
    if (!_pulling) {
      final d = e.position - _downAt;
      // Downwards, mostly vertical, and only with the list at its top, so
      // scrolling the queue and swiping the cover sideways still work.
      if (d.dy < kTouchSlop || d.dy.abs() < d.dx.abs() * 1.5 || !_atTop) {
        return;
      }
      _pulling = true;
    }
    // The finger now moves the sheet, not the list.
    if (_scroll.hasClients && _scroll.offset != 0) _scroll.jumpTo(0);
    widget.onPull?.call(e.delta.dy);
  }

  void _pointerEnd(PointerEvent e, {required bool cancelled}) {
    if (e.pointer != _pointer) return;
    if (_pulling) {
      final v = cancelled
          ? 0.0
          : _velocity?.getVelocity().pixelsPerSecond.dy ?? 0.0;
      widget.onPullEnd?.call(v);
    }
    _pointer = null;
    _pulling = false;
    _velocity = null;
  }

  @override
  void initState() {
    super.initState();
    _focusIfClosable();
  }

  @override
  void didUpdateWidget(NowPlayingView old) {
    super.didUpdateWidget(old);
    if (old.onClose == null) _focusIfClosable();
  }

  /// As the full-screen sheet it takes keyboard focus, so Esc closes it.
  void _focusIfClosable() {
    if (widget.onClose == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
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
    // Room for the status and navigation bars when drawn edge to edge.
    final insets = MediaQuery.paddingOf(context);
    final topInset = insets.top;
    final bottomInset = insets.bottom;
    // A phone on its side: the cover on the left, the rest beside it.
    final screen = MediaQuery.sizeOf(context);
    final sideBySide = !isDesktop && screen.width > screen.height;

    // The cover with the bar over its top.
    Widget cover() => Stack(
      children: [
        _Artwork(track: track),
        // On a phone the cover runs up under the status bar; a shade there
        // keeps the bar's icons readable.
        if (topInset > 0)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topInset + 24,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x73000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),
        if (isDesktop)
          Positioned(
            top: 8 + topInset,
            left: 8,
            right: 8,
            child: _ArtOverlayBar(onClose: onClose),
          ),
      ],
    );

    Widget controls(Color accent) => SliverToBoxAdapter(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: _Controls(track: track, accent: accent),
        ),
      ),
    );

    // The scrolling part, ending with the queue. With pull-to-close, the
    // list does not stretch at its top, so the pull moves the whole sheet.
    Widget list(List<Widget> top) => ScrollConfiguration(
      behavior: ScrollConfiguration.of(context)
          .copyWith(overscroll: widget.onPull == null),
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          ...top,
          const QueueSlivers(),
          SliverToBoxAdapter(child: SizedBox(height: 24 + bottomInset)),
        ],
      ),
    );

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
          child: sideBySide
              ? LayoutBuilder(
                  builder: (context, c) => Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox.square(dimension: c.maxHeight, child: cover()),
                      Expanded(
                        child: list([
                          SliverToBoxAdapter(child: SizedBox(height: topInset)),
                          controls(accent),
                        ]),
                      ),
                    ],
                  ),
                )
              : list([SliverToBoxAdapter(child: cover()), controls(accent)]),
        );
      },
    );

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): ?onClose},
      child: Focus(
        focusNode: _focus,
        child: Listener(
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: (e) => _pointerEnd(e, cancelled: false),
          onPointerCancel: (e) => _pointerEnd(e, cancelled: true),
          child: Material(color: oampBackground, child: view),
        ),
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
          const ModeSwitchButton(overArt: true),
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
    final lyrics = ref.watch(showLyricsProvider);
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
            // A framed cover clears the status bar too.
            padding: EdgeInsets.only(
              top: wide ? 16 + MediaQuery.paddingOf(context).top : 0,
            ),
            child: Center(
              child: SizedBox.square(
                dimension: size,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(wide ? 10 : 0),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: ImageFiltered(
                          key: ValueKey((track?.id, lyrics)),
                          enabled: lyrics,
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: 24,
                            sigmaY: 24,
                            tileMode: TileMode.clamp,
                          ),
                          child: CoverArt(
                            track?.coverArt,
                            size: size,
                            radius: 0,
                            placeholderIcon: track == null
                                ? Icons.music_note_rounded
                                : Icons.album_rounded,
                          ),
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: lyrics && track != null
                            ? SizedBox.expand(
                                key: const ValueKey('lyrics'),
                                child: ColoredBox(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  child: LyricsView(track: track!),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
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
    final streamQuality = ref.watch(
      playerProvider.select((s) => s.currentQuality),
    );
    final quality = tr == null ? null : qualityLabel(tr, streamQuality);
    final showRgDebug = ref.watch(
      settingsProvider.select((s) => s.showReplayGainDebug),
    );
    final playback = ref.watch(playbackOptionsProvider);
    final rgDebug = (tr != null && showRgDebug)
        ? replayGainDebugLabel(
            tr,
            playback,
            // Only the Windows player can play louder than normal.
            canBoost: defaultTargetPlatform == TargetPlatform.windows,
          )
        : null;
    final liked =
        tr != null &&
        ref.watch(
          likesProvider(LikeTarget.track).select((m) => m[tr.id] ?? tr.liked),
        );
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
            const SizedBox(height: 4),
            RatingStars(
              key: ValueKey('rating-${tr.id}'),
              id: tr.id,
              fetched: tr.rating,
              size: 18,
              color: accent,
            ),
            if (quality != null) ...[
              const SizedBox(height: 6),
              Text(
                quality,
                style: t.labelLarge?.copyWith(color: OAmpColors.textMuted),
              ),
            ],
            if (rgDebug != null) ...[
              const SizedBox(height: 4),
              Text(
                rgDebug,
                textAlign: TextAlign.center,
                style: t.labelMedium?.copyWith(color: OAmpColors.textFaint),
              ),
            ],
          ],
          const SizedBox(height: 14),
          TransportControls(playColor: accent),
          const SizedBox(height: 8),
          // Phones set the volume with their own buttons.
          if (isDesktop) ...[
            VolumeControl(accent: accent),
            const SizedBox(height: 4),
          ],
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
              _LyricsButton(track: tr, accent: accent),
              const ShuffleButton(),
              const RepeatButton(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows or hides lyrics over the artwork. Disabled when the track has
/// none, unless lyrics are showing (so they can still be hidden).
class _LyricsButton extends ConsumerWidget {
  final Track? track;
  final Color accent;
  const _LyricsButton({required this.track, required this.accent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showing = ref.watch(showLyricsProvider);
    final tr = track;
    final lyrics = tr == null
        ? null
        : ref.watch(lyricsProvider(lyricsRequestFor(tr))).value;
    final has = lyrics != null && !lyrics.isEmpty;
    final failed =
        tr != null && ref.watch(lyricsProvider(lyricsRequestFor(tr))).hasError;
    final color = showing ? accent : OAmpColors.textMuted;
    return IconButton(
      tooltip: showing
          ? 'Hide lyrics'
          : (has
                ? 'Show lyrics'
                : failed
                ? 'Lyrics could not be loaded'
                : 'No lyrics for this track'),
      icon: LyricsGlyph(
        color: tr == null || !(showing || has || failed)
            ? OAmpColors.textFaint.withValues(alpha: 0.35)
            : color,
        filled: showing,
      ),
      onPressed: showing || has || failed
          ? ref.read(showLyricsProvider.notifier).toggle
          : null,
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

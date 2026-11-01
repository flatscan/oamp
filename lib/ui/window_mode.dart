import 'dart:async';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/platform_info.dart';
import 'app_frame.dart';
import 'player/now_playing.dart';

/// Whether the desktop window is in expanded mode (the column plus the
/// library fly-out) rather than the single column alone.
final flyoutOpenProvider = NotifierProvider<FlyoutController, bool>(
  FlyoutController.new,
);

/// While the fly-out slides in or out, the width it is laid out at, so its
/// contents are revealed or covered rather than squeezed. Null otherwise.
final flyoutSlideWidthProvider = NotifierProvider<_SlideWidth, double?>(
  _SlideWidth.new,
);

class _SlideWidth extends Notifier<double?> {
  @override
  double? build() => null;
  void set(double? w) => state = w;
}

/// Switches between the two modes. The column (now playing, in expanded
/// mode) keeps exactly the same size and place throughout; the window grows
/// or shrinks on its right-hand side over a short animation, so the fly-out
/// appears to slide out of the column and back into it.
class FlyoutController extends Notifier<bool> {
  /// Width of the column's content, in both modes.
  static const columnWidth = 440.0;
  static const flyoutWidth = 720.0;
  static const minHeight = 600.0;
  static const slideDuration = Duration(milliseconds: 260);

  /// window_manager has no way to lift a maximum once set, so "no limit"
  /// is a size no screen reaches.
  static const _unlimited = 100000.0;

  /// How much wider the window is than its content (resize borders). Window
  /// sizes are set as outer sizes, so this is added to make the content
  /// exactly [columnWidth] wide. Measured at startup.
  static double _frame = 0;

  static double get _singleWindowWidth => columnWidth + _frame;

  @override
  bool build() => false;

  /// Sets up single-column mode at startup: measures the window frame,
  /// sizes the window so its content is exactly one column wide, and fixes
  /// the width so only the height can be dragged.
  static Future<void> lockToColumn() async {
    final outer = await windowManager.getSize();
    final view = PlatformDispatcher.instance.implicitView;
    if (view != null && view.physicalSize.width > 0) {
      final inner = view.physicalSize.width / view.devicePixelRatio;
      _frame = (outer.width - inner).clamp(0.0, 64.0);
    }
    await windowManager.setMinimumSize(Size(_singleWindowWidth, minHeight));
    await windowManager.setMaximumSize(Size(_singleWindowWidth, _unlimited));
    await windowManager.setSize(Size(_singleWindowWidth, outer.height));
  }

  bool _busy = false;

  /// Single column to expanded. If the full-screen now playing is open it
  /// is swapped for the column's own copy in the same frame, so nothing
  /// visibly changes before the fly-out slides out.
  Future<void> expand({Route<dynamic>? nowPlayingRoute}) async {
    if (state || _busy) return;
    _busy = true;
    try {
      state = true;
      if (nowPlayingRoute != null && !nowPlayingRoute.isFirst) {
        rootNavigatorKey.currentState?.removeRoute(nowPlayingRoute);
      }
      if (!isDesktop) return;
      await windowManager.setMaximumSize(const Size(_unlimited, _unlimited));
      final height = (await windowManager.getSize()).height;
      ref.read(flyoutSlideWidthProvider.notifier).set(flyoutWidth);
      await _animateWidth(
        _singleWindowWidth,
        _singleWindowWidth + flyoutWidth,
        height,
      );
      await windowManager.setMinimumSize(
        Size(_singleWindowWidth + 360, minHeight),
      );
    } finally {
      if (ref.mounted) ref.read(flyoutSlideWidthProvider.notifier).set(null);
      _busy = false;
    }
  }

  /// Expanded to single column: the fly-out slides back into the column,
  /// then the column carries on as the full-screen now playing.
  Future<void> collapse() async {
    if (!state || _busy) return;
    _busy = true;
    try {
      if (isDesktop) {
        if (await windowManager.isFullScreen()) {
          await windowManager.setFullScreen(false);
        }
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        }
        final size = await windowManager.getSize();
        await windowManager.setMinimumSize(Size(_singleWindowWidth, minHeight));
        ref
            .read(flyoutSlideWidthProvider.notifier)
            .set(size.width - _singleWindowWidth);
        await _animateWidth(size.width, _singleWindowWidth, size.height);
        await windowManager.setMaximumSize(
          Size(_singleWindowWidth, _unlimited),
        );
      }
      // Same frame: the full-screen now playing covers the column as the
      // column's own copy goes away.
      final context = rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        showNowPlaying(context, animate: false);
      }
      state = false;
    } finally {
      if (ref.mounted) ref.read(flyoutSlideWidthProvider.notifier).set(null);
      _busy = false;
    }
  }

  /// Resizes the window's width from [from] to [to] once per frame, keeping
  /// its left edge where it is.
  Future<void> _animateWidth(double from, double to, double height) {
    final done = Completer<void>();
    final binding = SchedulerBinding.instance;
    Duration? start;
    void tick(Duration now) {
      start ??= now;
      final t = ((now - start!).inMicroseconds / slideDuration.inMicroseconds)
          .clamp(0.0, 1.0);
      final w = lerpDouble(from, to, Curves.easeInOutCubic.transform(t))!;
      unawaited(windowManager.setSize(Size(w.roundToDouble(), height)));
      if (t < 1) {
        binding.scheduleFrameCallback(tick);
        binding.scheduleFrame();
      } else {
        done.complete();
      }
    }

    binding.scheduleFrameCallback(tick);
    binding.scheduleFrame();
    return done.future;
  }
}

/// Lays out the fly-out at [width] even while less of it is visible, and
/// clips it, so during the slide its contents move rather than reflow.
class FlyoutSlide extends StatelessWidget {
  final double? width;
  final Widget child;
  const FlyoutSlide({super.key, required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    final w = width;
    if (w == null) return child;
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: w,
        maxWidth: w,
        child: child,
      ),
    );
  }
}

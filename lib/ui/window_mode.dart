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

/// How far the fly-out has slid out of the column: 0 hidden behind it,
/// 1 fully out.
final flyoutRevealProvider = NotifierProvider<_Reveal, double>(_Reveal.new);

class _Reveal extends Notifier<double> {
  @override
  double build() => 1;
  void set(double v) => state = v;
}

/// Switches between the two modes. The column (now playing, in expanded
/// mode) keeps exactly the same size and place throughout.
///
/// The window is resized in one step (resizing it every frame makes Windows
/// stretch stale frames), and the fly-out then slides out from behind the
/// column inside the app; collapsing slides it back in first and shrinks
/// the window after.
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
    final reveal = ref.read(flyoutRevealProvider.notifier);
    try {
      reveal.set(0);
      state = true;
      if (nowPlayingRoute != null && !nowPlayingRoute.isFirst) {
        rootNavigatorKey.currentState?.removeRoute(nowPlayingRoute);
      }
      if (isDesktop) {
        final height = (await windowManager.getSize()).height;
        await windowManager.setMaximumSize(const Size(_unlimited, _unlimited));
        await windowManager.setSize(
          Size(_singleWindowWidth + flyoutWidth, height),
        );
        await windowManager.setMinimumSize(
          Size(_singleWindowWidth + 360, minHeight),
        );
      }
      await _animate(0, 1, reveal.set);
    } finally {
      if (ref.mounted) reveal.set(1);
      _busy = false;
    }
  }

  /// Expanded to single column: the fly-out slides back into the column,
  /// the window shrinks, and the column carries on as the full-screen now
  /// playing.
  Future<void> collapse() async {
    if (!state || _busy) return;
    _busy = true;
    final reveal = ref.read(flyoutRevealProvider.notifier);
    try {
      await _animate(1, 0, reveal.set);
      if (isDesktop) {
        if (await windowManager.isFullScreen()) {
          await windowManager.setFullScreen(false);
        }
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        }
        final height = (await windowManager.getSize()).height;
        await windowManager.setMinimumSize(Size(_singleWindowWidth, minHeight));
        await windowManager.setSize(Size(_singleWindowWidth, height));
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
      if (ref.mounted) reveal.set(1);
      _busy = false;
    }
  }

  /// Runs [apply] from [from] to [to] once per frame over [slideDuration].
  Future<void> _animate(double from, double to, void Function(double) apply) {
    final done = Completer<void>();
    final binding = SchedulerBinding.instance;
    Duration? start;
    void tick(Duration now) {
      start ??= now;
      final t = ((now - start!).inMicroseconds / slideDuration.inMicroseconds)
          .clamp(0.0, 1.0);
      apply(lerpDouble(from, to, Curves.easeOutCubic.transform(t))!);
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

/// Slides the fly-out out from behind the column: at [reveal] 0 it sits
/// fully to the left (hidden under the column), at 1 in place. It is laid
/// out at its final width throughout, so it moves without reflowing.
class FlyoutSlide extends StatelessWidget {
  final double reveal;
  final Widget child;
  const FlyoutSlide({super.key, required this.reveal, required this.child});

  @override
  Widget build(BuildContext context) {
    if (reveal >= 1) return child;
    return ClipRect(
      child: FractionalTranslation(
        translation: Offset(reveal - 1, 0),
        child: child,
      ),
    );
  }
}

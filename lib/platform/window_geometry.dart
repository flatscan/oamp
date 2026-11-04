import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'preferences.dart';

/// Where the desktop window was and how tall it was, so it opens there
/// again. The width is not kept: it is always one column (or the column
/// plus the fly-out), set by the window mode.
class WindowGeometry {
  final Offset position;
  final double height;
  const WindowGeometry(this.position, this.height);

  static const _xKey = 'oamp.window.x';
  static const _yKey = 'oamp.window.y';
  static const _heightKey = 'oamp.window.height';

  /// The saved geometry, or null on first run.
  static WindowGeometry? read(Preferences prefs) {
    final x = prefs.getDouble(_xKey);
    final y = prefs.getDouble(_yKey);
    final h = prefs.getDouble(_heightKey);
    if (x == null || y == null || h == null) return null;
    return WindowGeometry(Offset(x.toDouble(), y.toDouble()), h.toDouble());
  }

  Future<void> write(Preferences prefs) async {
    await prefs.setDouble(_xKey, position.dx);
    await prefs.setDouble(_yKey, position.dy);
    await prefs.setDouble(_heightKey, height);
  }

  /// This geometry, made to fit one of [screens] (their work areas) for a
  /// window [width] wide: shorter if the screen is, and moved fully onto
  /// it. Null when the window would be mostly off every screen, such as
  /// after unplugging the monitor it was on, so it opens centred instead.
  WindowGeometry? fitTo(
    List<Rect> screens, {
    required double width,
    required double minHeight,
  }) {
    final rect = Rect.fromLTWH(position.dx, position.dy, width, height);
    Rect? best;
    var bestArea = 0.0;
    for (final s in screens) {
      final overlap = rect.intersect(s);
      if (overlap.isEmpty) continue;
      final area = overlap.width * overlap.height;
      if (area > bestArea) {
        best = s;
        bestArea = area;
      }
    }
    // Less than a quarter of the title bar's worth showing: start fresh.
    if (best == null || bestArea < width * 40) return null;
    final h = height.clamp(minHeight, math.max(minHeight, best.height));
    final x = position.dx.clamp(
      best.left,
      math.max(best.left, best.right - width),
    );
    final y = position.dy.clamp(best.top, math.max(best.top, best.bottom - h));
    return WindowGeometry(Offset(x.toDouble(), y.toDouble()), h.toDouble());
  }

  /// The work areas of the connected screens.
  static Future<List<Rect>> screens() async {
    try {
      return [
        for (final d in await screenRetriever.getAllDisplays())
          (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size),
      ];
    } catch (e) {
      debugPrint('Could not list screens: $e');
      return const [];
    }
  }
}

/// Saves the window's position and height whenever the user moves or
/// resizes it, a moment after they stop. Maximised, minimised and full
/// screen windows are not saved, so restoring opens the normal window.
class WindowGeometrySaver with WindowListener {
  final Preferences _prefs;
  Timer? _pending;

  WindowGeometrySaver(this._prefs);

  void start() => windowManager.addListener(this);

  @override
  void onWindowMoved() => _schedule();
  @override
  void onWindowResized() => _schedule();

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(const Duration(milliseconds: 500), save);
  }

  Future<void> save() async {
    _pending?.cancel();
    try {
      if (await windowManager.isMaximized() ||
          await windowManager.isMinimized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      final bounds = await windowManager.getBounds();
      await WindowGeometry(bounds.topLeft, bounds.height).write(_prefs);
    } catch (e) {
      debugPrint('Could not save the window position: $e');
    }
  }
}

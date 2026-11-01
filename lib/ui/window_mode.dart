import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/platform_info.dart';

/// Whether the desktop window is in expanded mode (the single column plus
/// the library fly-out) rather than the single column alone.
final flyoutOpenProvider = NotifierProvider<FlyoutController, bool>(
  FlyoutController.new,
);

class FlyoutController extends Notifier<bool> {
  /// Width of the single column, and of the window in single-column mode.
  static const columnWidth = 440.0;
  static const flyoutWidth = 720.0;
  static const minHeight = 600.0;

  /// window_manager has no way to lift a maximum once set, so "no limit"
  /// is a size no screen reaches.
  static const _unlimited = 100000.0;

  @override
  bool build() => false;

  /// Window limits for single-column mode: the width is fixed and only the
  /// height can be dragged. Called once at startup.
  static Future<void> lockToColumn() async {
    await windowManager.setMinimumSize(const Size(columnWidth, minHeight));
    await windowManager.setMaximumSize(const Size(columnWidth, _unlimited));
  }

  /// Switches between single-column and expanded mode, resizing the window
  /// to match. In expanded mode the window can be resized freely (down to
  /// room for the column and a narrow fly-out) and maximised; going back to
  /// single-column un-maximises it and fixes the width again.
  Future<void> toggle() async {
    final open = !state;
    state = open;
    if (!isDesktop) return;
    final height = (await windowManager.getSize()).height;
    if (open) {
      await windowManager.setMaximumSize(const Size(_unlimited, _unlimited));
      await windowManager.setMinimumSize(
        const Size(columnWidth + 360, minHeight),
      );
      if (await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      await windowManager.setSize(
        Size(columnWidth + flyoutWidth, height),
        animate: true,
      );
    } else {
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      }
      if (await windowManager.isMaximized()) await windowManager.unmaximize();
      await windowManager.setMinimumSize(const Size(columnWidth, minHeight));
      await windowManager.setSize(Size(columnWidth, height), animate: true);
      await windowManager.setMaximumSize(const Size(columnWidth, _unlimited));
    }
  }
}

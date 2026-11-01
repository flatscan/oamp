import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Turns the Windows window manager's own animations for this window off
/// and on (`oamp/window` channel, windows/runner/flutter_window.cpp).
///
/// The app animates its own mode switch. When the window is snapped,
/// Windows also animates the size change with a stretched snapshot of the
/// old frame, which flickers on top of the app's animation.
abstract final class WindowTransitions {
  static const _channel = MethodChannel('oamp/window');

  static Future<void> setEnabled(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await _channel.invokeMethod<void>('setTransitionsEnabled', enabled);
    } on MissingPluginException {
      // Tests and older runners: nothing to turn off.
    } on PlatformException {
      // Purely cosmetic; never block a mode switch on it.
    }
  }
}

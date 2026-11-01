import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Window calls the runner makes itself (`oamp/window` channel,
/// windows/runner/flutter_window.cpp), for the few things window_manager
/// doesn't do precisely enough.
abstract final class NativeWindow {
  static const _channel = MethodChannel('oamp/window');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Sets the outer window width (logical pixels), rounded once to whole
  /// physical pixels, leaving the height and position exactly as they are.
  /// Returns false when the runner can't, so the caller can fall back.
  static Future<bool> setWidth(double width) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('setWidth', width) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

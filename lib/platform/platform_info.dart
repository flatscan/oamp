import 'package:flutter/foundation.dart';

/// Platform checks without `dart:io`, so the same code compiles for web.
bool get isDesktop =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };

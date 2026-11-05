import 'package:flutter/foundation.dart';

import 'android_system_controls.dart';
import 'system_controls.dart';
import 'windows_system_controls.dart';

/// Picks the OS media session for the current platform.
///
/// iOS and macOS can reuse the `audio_service` implementation once they are
/// worked on, and Linux gets an MPRIS one in v2; each is one more case here.
Future<SystemControls> createSystemControls() async {
  if (kIsWeb) return const NoSystemControls();
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => await WindowsSystemControls.create(),
    TargetPlatform.android => await AndroidSystemControls.create(),
    _ => const NoSystemControls(),
  };
}

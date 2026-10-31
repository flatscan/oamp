import 'package:flutter/foundation.dart';

import 'system_controls.dart';
import 'windows_system_controls.dart';

/// Picks the OS media session for the current platform.
///
/// Android, iOS and macOS get an `audio_service` implementation in a later
/// milestone, and Linux an MPRIS one in v2; each is one more case here.
Future<SystemControls> createSystemControls() async {
  if (kIsWeb) return const NoSystemControls();
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows =>
      await WindowsSystemControls.create() ?? const NoSystemControls(),
    _ => const NoSystemControls(),
  };
}

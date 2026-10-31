import 'package:flutter/material.dart';

/// OAmp's accent, a warm amber reminiscent of a VU meter.
const oampSeed = Color(0xFFE5A00D);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: oampSeed,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    listTileTheme: const ListTileThemeData(dense: true),
  );
}

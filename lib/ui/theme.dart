import 'package:flutter/material.dart';

/// OAmp's accent: a warm coral, like the glow of a valve amp.
const oampAccent = Color(0xFFFF6B4A);

/// The near-black canvas everything sits on.
const oampBackground = Color(0xFF0B0B0C);

/// Colours outside the Material scheme that the player screens use.
abstract final class OAmpColors {
  static const surface = Color(0xFF161618);
  static const surfaceHigh = Color(0xFF222226);
  static const textMuted = Color(0xB3FFFFFF);
  static const textFaint = Color(0x80FFFFFF);
}

/// OAmp is dark only: a black canvas, white type and one accent.
ThemeData buildTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: oampAccent,
        brightness: Brightness.dark,
      ).copyWith(
        primary: oampAccent,
        onPrimary: Colors.black,
        surface: oampBackground,
        onSurface: Colors.white,
        onSurfaceVariant: OAmpColors.textMuted,
        surfaceContainerLowest: oampBackground,
        surfaceContainerLow: const Color(0xFF111113),
        surfaceContainer: OAmpColors.surface,
        surfaceContainerHigh: const Color(0xFF1C1C1F),
        surfaceContainerHighest: OAmpColors.surfaceHigh,
        outlineVariant: const Color(0x1FFFFFFF),
      );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: oampBackground,
    canvasColor: oampBackground,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
  );
  final text = base.textTheme.apply(
    bodyColor: Colors.white,
    displayColor: Colors.white,
  );
  return base.copyWith(
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
      headlineSmall: text.headlineSmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
      ),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodySmall: text.bodySmall?.copyWith(color: OAmpColors.textMuted),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: oampBackground,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: oampBackground,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 60,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected)
              ? Colors.white
              : OAmpColors.textFaint,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: s.contains(WidgetState.selected)
              ? Colors.white
              : OAmpColors.textFaint,
        ),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      selectedColor: oampAccent,
      iconColor: OAmpColors.textMuted,
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: OAmpColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: OAmpColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Color(0x40FFFFFF)),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: OAmpColors.surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      activeTrackColor: Colors.white,
      inactiveTrackColor: Color(0x33FFFFFF),
      thumbColor: Colors.white,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      trackShape: RoundedRectSliderTrackShape(),
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(6),
      radius: Radius.circular(3),
    ),
    dividerTheme: const DividerThemeData(color: Color(0x14FFFFFF), space: 1),
  );
}

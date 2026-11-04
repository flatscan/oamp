import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/platform/window_geometry.dart';

import 'package:oamp/platform/preferences.dart';

void main() {
  const screen = Rect.fromLTWH(0, 0, 1920, 1040);
  const second = Rect.fromLTWH(1920, 0, 2560, 1400);

  WindowGeometry? fit(Offset at, double height, [List<Rect>? screens]) =>
      WindowGeometry(
        at,
        height,
      ).fitTo(screens ?? const [screen, second], width: 440, minHeight: 600);

  test('a window that fits is left where it was', () {
    final g = fit(const Offset(2400, 100), 1200)!;
    expect(g.position, const Offset(2400, 100));
    expect(g.height, 1200);
  });

  test('a window hanging off a screen edge is moved onto it', () {
    final g = fit(const Offset(1600, 300), 900)!;
    // Mostly on the first screen, so it moves left to fit there.
    expect(g.position, const Offset(1480, 140));
    expect(g.height, 900);
  });

  test('a window taller than its screen is shortened', () {
    final g = fit(const Offset(100, 0), 1300, const [screen])!;
    expect(g.height, 1040);
    expect(g.position, const Offset(100, 0));
  });

  test('a window on a monitor that is gone opens centred', () {
    expect(fit(const Offset(5000, 100), 900), isNull);
    expect(fit(const Offset(-800, 100), 900, const [screen]), isNull);
  });

  test('geometry round-trips through preferences', () async {
    final prefs = MemoryPreferences();
    expect(WindowGeometry.read(prefs), isNull);
    await const WindowGeometry(Offset(12, 34), 901).write(prefs);
    final g = WindowGeometry.read(prefs)!;
    expect(g.position, const Offset(12, 34));
    expect(g.height, 901);
  });
}

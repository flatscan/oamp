import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the seams from the design doc's "Built for v2 from day one" rules.
void main() {
  Iterable<(String, String)> imports(String dir) sync* {
    for (final f in Directory(dir).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final line in f.readAsLinesSync()) {
        if (line.startsWith('import ')) yield (f.path, line);
      }
    }
  }

  test('widgets do not import backend or audio packages', () {
    final bad = [
      for (final (path, line) in imports('lib/ui'))
        if (line.contains('/sources/') ||
            line.contains('/audio/') ||
            line.contains('package:just_audio') ||
            line.contains('package:http/') ||
            line.contains('package:media_kit'))
          '$path: $line',
    ];
    expect(bad, isEmpty);
  });

  test('core, state and ui avoid dart:io so a web build stays possible', () {
    final bad = [
      for (final dir in ['lib/core', 'lib/state', 'lib/ui'])
        for (final (path, line) in imports(dir))
          if (line.contains("'dart:io'")) '$path: $line',
    ];
    expect(bad, isEmpty);
  });

  test('OS media session code stays behind SystemControls', () {
    // Only lib/platform may use a platform's media session package, so
    // Android/iOS/macOS (audio_service) and Linux (MPRIS) are new files there.
    final bad = [
      for (final dir in ['lib/core', 'lib/state', 'lib/ui', 'lib/sources'])
        for (final (path, line) in imports(dir))
          if (line.contains('package:smtc_windows') ||
              line.contains('package:audio_service') ||
              line.contains('windows_system_controls') ||
              line.contains('platform_system_controls'))
            '$path: $line',
    ];
    expect(bad, isEmpty);
  });
}

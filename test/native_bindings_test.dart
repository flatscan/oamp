import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// smtc_windows only starts when the flutter_rust_bridge runtime resolved by
/// pub is the exact version its bindings were generated with. A mismatch
/// builds fine and only fails on Windows at launch, so check it here.
void main() {
  test('flutter_rust_bridge matches the smtc_windows bindings', () {
    final config = jsonDecode(
      File('.dart_tool/package_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    Directory root(String name) {
      final pkg = (config['packages'] as List).cast<Map>().firstWhere(
        (p) => p['name'] == name,
      );
      final uri = Uri.parse(pkg['rootUri'] as String);
      return Directory.fromUri(
        uri.isAbsolute ? uri : Uri.file('.dart_tool/').resolveUri(uri),
      );
    }

    final generated = File(
      '${root('smtc_windows').path}/lib/src/rust/frb_generated.dart',
    ).readAsStringSync();
    final codegen = RegExp(r"codegenVersion => '([^']+)'")
        .firstMatch(generated)!
        .group(1);
    final runtime = root('flutter_rust_bridge').uri.pathSegments
        .lastWhere((s) => s.isNotEmpty)
        .split('-')
        .last;
    expect(runtime, codegen);
  });
}

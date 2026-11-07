import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/diagnostics.dart';

/// The diagnostics log on disk: `logs/oamp.log` in the app's support
/// folder, moved to `oamp.1.log` when it passes [maxBytes], so at most about
/// twice that is ever kept.
class FileLogStore implements LogStore {
  static const maxBytes = 512 * 1024;
  static const reportName = 'oamp-diagnostics.txt';

  final Directory dir;
  FileLogStore(this.dir);

  File get _current => File('${dir.path}${Platform.pathSeparator}oamp.log');
  File get _previous => File('${dir.path}${Platform.pathSeparator}oamp.1.log');

  /// The log in the app's support folder, or in memory when that can't be
  /// made.
  static Future<LogStore> open() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}logs');
      await dir.create(recursive: true);
      return FileLogStore(dir);
    } catch (_) {
      return MemoryLogStore();
    }
  }

  @override
  String? get folder => dir.path;

  @override
  Future<void> append(List<String> lines) async {
    final file = _current;
    if (await file.exists() && await file.length() > maxBytes) {
      await file.rename(_previous.path);
    }
    await file.writeAsString(
      '${lines.join('\n')}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  @override
  Future<String> readAll() async {
    final parts = <String>[];
    for (final f in [_previous, _current]) {
      if (await f.exists()) parts.add(await f.readAsString());
    }
    return parts.join();
  }

  @override
  Future<String?> writeReport(String text) async {
    final file = File('${dir.path}${Platform.pathSeparator}$reportName');
    await file.writeAsString(text, flush: true);
    return file.path;
  }
}

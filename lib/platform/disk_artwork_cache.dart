import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/artwork_cache.dart';
import '../core/track_cache.dart';

/// [ArtworkCache] in a folder of image files named by a hash of their key.
/// Reading a file marks it as recently used; once the folder passes
/// [limitBytes], the least recently used images are deleted.
class DiskArtworkCache implements ArtworkCache {
  DiskArtworkCache(
    this.dir, {
    http.Client? httpClient,
    this.limitBytes = defaultLimit,
  }) : _http = httpClient ?? http.Client();

  static const defaultLimit = 300 * 1024 * 1024;

  final Directory dir;
  final http.Client _http;
  int limitBytes;

  /// Fetches in progress, so an image shown in several places at once is
  /// downloaded once.
  final _inflight = <String, Future<Uint8List>>{};

  /// Bytes on disk, counted on first use and kept up to date after.
  int? _bytes;
  Future<int>? _counting;
  Future<void>? _trimming;

  File _file(String key) => File(
    '${dir.path}${Platform.pathSeparator}'
    '${sha1.convert(utf8.encode(key))}.img',
  );

  @override
  Future<Uint8List> load(String key, Uri url) {
    // The callback must not return the removed future, or whenComplete
    // would wait on itself.
    return _inflight[key] ??= _load(key, url).whenComplete(() {
      _inflight.remove(key);
    });
  }

  Future<Uint8List> _load(String key, Uri url) async {
    final file = _file(key);
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        // Best effort: an error here only makes eviction less accurate.
        unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
        return bytes;
      }
    } on FileSystemException {
      // Not cached yet.
    }

    final res = await _http.get(url).timeout(const Duration(seconds: 30));
    final type = res.headers['content-type'] ?? '';
    if (res.statusCode != 200 ||
        res.bodyBytes.isEmpty ||
        // Subsonic reports errors as JSON or XML with a 200 status.
        type.contains('json') ||
        type.contains('xml')) {
      throw HttpException('Artwork not available (HTTP ${res.statusCode})');
    }
    final bytes = res.bodyBytes;
    // Saved before returning, so a second request for the same image,
    // made as soon as this one finishes, finds it on disk.
    await _save(file, bytes);
    return bytes;
  }

  Future<void> _save(File file, Uint8List bytes) async {
    try {
      await dir.create(recursive: true);
      _bytes ??= await (_counting ??= _countBytes());
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      _bytes = _bytes! + bytes.length;
      if (_bytes! > limitBytes) {
        _trimming ??= _trim().whenComplete(() => _trimming = null);
      }
    } catch (e) {
      debugPrint('Could not save artwork: $e');
    }
  }

  Future<List<File>> _files() async {
    if (!await dir.exists()) return const [];
    return [
      await for (final f in dir.list())
        if (f is File && f.path.endsWith('.img')) f,
    ];
  }

  Future<int> _countBytes() async {
    var total = 0;
    for (final f in await _files()) {
      try {
        total += await f.length();
      } on FileSystemException {
        // Deleted meanwhile.
      }
    }
    return total;
  }

  /// Deletes least recently used images until the folder is at 80% of the
  /// limit, leaving room so this does not run on every save.
  Future<void> _trim() async {
    final entries = <(File, FileStat)>[];
    for (final f in await _files()) {
      try {
        entries.add((f, await f.stat()));
      } on FileSystemException {
        // Deleted meanwhile.
      }
    }
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var total = entries.fold<int>(0, (n, e) => n + e.$2.size);
    final target = limitBytes * 0.8;
    for (final (f, stat) in entries) {
      if (total <= target) break;
      try {
        await f.delete();
        total -= stat.size;
      } on FileSystemException {
        // In use or gone; skip it.
      }
    }
    _bytes = total;
  }

  @override
  Future<CacheUsage> usage() async {
    var bytes = 0, files = 0;
    for (final f in await _files()) {
      try {
        bytes += await f.length();
        files++;
      } on FileSystemException {
        // Deleted meanwhile.
      }
    }
    _bytes = bytes;
    return CacheUsage(bytes, files);
  }

  @override
  Future<void> clear() async {
    for (final f in await _files()) {
      try {
        await f.delete();
      } on FileSystemException {
        // Gone already.
      }
    }
    _bytes = 0;
  }

  /// Opens the cache in the app's cache folder, or returns null (artwork is
  /// then fetched every time) when there is no file system to use.
  static Future<ArtworkCache?> open() async {
    if (kIsWeb) return null;
    try {
      final base = await getApplicationCacheDirectory();
      return DiskArtworkCache(
        Directory('${base.path}${Platform.pathSeparator}artwork'),
      );
    } catch (e) {
      debugPrint('Artwork cache unavailable: $e');
      return null;
    }
  }
}

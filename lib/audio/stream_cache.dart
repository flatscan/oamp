import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/track_cache.dart';

/// [TrackCache] on disk, served to the audio engine by a small HTTP server
/// on the loopback interface.
///
/// The engine always plays `http://127.0.0.1:<port>/<secret>/<id>`, so a
/// track's address never changes when it finishes caching:
///
/// * a complete file is served from disk, with range requests for seeking;
/// * otherwise a request from the start streams from the server and saves
///   the bytes as they pass, so the track is cached once it has played;
/// * a range request for a file that is not cached yet is passed straight
///   through to the server.
///
/// Separately, [prefetch] downloads upcoming tracks one at a time.
class HttpTrackCache implements TrackCache {
  HttpTrackCache._(this._dir, this._server, this._secret, int limitBytes)
    : _limit = limitBytes {
    _server.listen(_handle, onError: (Object e) => _log('server: $e'));
  }

  /// Opens the cache in [dir], creating it if needed, and starts serving.
  static Future<HttpTrackCache> open(
    Directory dir, {
    int limitBytes = 1024 * 1024 * 1024,
  }) async {
    await dir.create(recursive: true);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rnd = Random.secure();
    final secret = [
      for (var i = 0; i < 16; i++) rnd.nextInt(256).toRadixString(16),
    ].join();
    final cache = HttpTrackCache._(dir, server, secret, limitBytes);
    await cache._scan();
    return cache;
  }

  final Directory _dir;
  final HttpServer _server;
  final String _secret;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  int _limit;

  /// Requests the engine may ask for, by file id.
  final Map<String, CacheRequest> _known = {};

  /// Complete files: id to size and last use.
  final Map<String, _Entry> _index = {};

  /// Ids being written (a download or a pass-through that saves).
  final Set<String> _writing = {};

  /// Ids with a file open for reading, and how many times.
  final Map<String, int> _reading = {};

  List<CacheRequest> _wanted = const [];
  _Download? _download;
  final _changes = StreamController<void>.broadcast();
  bool _disposed = false;

  static String idFor(String key) => sha1.convert(utf8.encode(key)).toString();

  File _file(String id) => File('${_dir.path}${Platform.pathSeparator}$id');
  File _part(String id) =>
      File('${_dir.path}${Platform.pathSeparator}$id.part');

  Future<void> _scan() async {
    await for (final f in _dir.list()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.part')) {
        await _tryDelete(f);
        continue;
      }
      try {
        final stat = await f.stat();
        _index[name] = _Entry(stat.size, stat.modified);
      } catch (_) {}
    }
    await _evict();
  }

  @override
  Uri urlFor(CacheRequest request) {
    final id = idFor(request.key);
    _known[id] = request;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server.port,
      pathSegments: [_secret, id],
    );
  }

  @override
  bool isCached(String key) => _index.containsKey(idFor(key));

  @override
  set limitBytes(int bytes) {
    _limit = bytes;
    unawaited(_evict());
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<CacheUsage> usage() async => CacheUsage(
    _index.values.fold(0, (sum, e) => sum + e.size),
    _index.length,
  );

  @override
  Future<void> clear() async {
    for (final id in _index.keys.toList()) {
      if (_reading.containsKey(id)) continue;
      if (await _tryDelete(_file(id))) _index.remove(id);
    }
    _notify();
  }

  @override
  void prefetch(List<CacheRequest> wanted) {
    _wanted = List.unmodifiable(wanted);
    for (final r in wanted) {
      _known[idFor(r.key)] = r;
    }
    final d = _download;
    if (d != null && !wanted.any((r) => idFor(r.key) == d.id)) d.cancel();
    _pump();
  }

  /// Starts the next wanted download if none is running.
  void _pump() {
    if (_disposed || _download != null) return;
    for (final r in _wanted) {
      final id = idFor(r.key);
      if (_index.containsKey(id) || _writing.contains(id)) continue;
      final d = _Download(id);
      _download = d;
      unawaited(
        _fetch(r, d).whenComplete(() {
          _download = null;
          _pump();
        }),
      );
      return;
    }
  }

  Future<void> _fetch(CacheRequest r, _Download d) async {
    _writing.add(d.id);
    final part = _part(d.id);
    IOSink? sink;
    try {
      final req = await _client.getUrl(r.upstream);
      d.request = req;
      if (d.cancelled) return;
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok || _isError(res)) {
        await res.drain<void>();
        _log('prefetch ${d.id}: HTTP ${res.statusCode}');
        // Skip this track for now rather than retrying in a loop.
        _wanted = [
          for (final w in _wanted)
            if (idFor(w.key) != d.id) w,
        ];
        return;
      }
      sink = part.openWrite();
      var n = 0;
      await for (final chunk in res) {
        if (d.cancelled) return;
        sink.add(chunk);
        n += chunk.length;
      }
      await sink.close();
      sink = null;
      if (res.contentLength >= 0 && n != res.contentLength) return;
      await _commit(d.id, part, n);
    } catch (e) {
      if (!d.cancelled) _log('prefetch ${d.id}: $e');
    } finally {
      _writing.remove(d.id);
      await sink?.close().catchError((_) {});
      if (!_index.containsKey(d.id)) await _tryDelete(part);
    }
  }

  /// A Subsonic server answers errors with HTTP 200 and an XML or JSON body.
  static bool _isError(HttpClientResponse res) {
    final type = res.headers.contentType?.mimeType ?? '';
    return type.contains('xml') || type.contains('json');
  }

  Future<void> _commit(String id, File part, int size) async {
    await part.rename(_file(id).path);
    _index[id] = _Entry(size, DateTime.now());
    _notify();
    await _evict();
  }

  /// Removes least recently used files until the cache fits its limit.
  /// Files being read and the tracks wanted next are kept.
  Future<void> _evict() async {
    var total = _index.values.fold(0, (sum, e) => sum + e.size);
    if (total <= _limit) return;
    final keep = {for (final r in _wanted) idFor(r.key), ..._reading.keys};
    final byAge = _index.entries.toList()
      ..sort((a, b) => a.value.used.compareTo(b.value.used));
    var removed = false;
    for (final e in byAge) {
      if (total <= _limit) break;
      if (keep.contains(e.key)) continue;
      if (await _tryDelete(_file(e.key))) {
        _index.remove(e.key);
        total -= e.value.size;
        removed = true;
      }
    }
    if (removed) _notify();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final segs = req.uri.pathSegments;
    final id = segs.length == 2 && segs[0] == _secret ? segs[1] : null;
    final known = id == null ? null : _known[id];
    if (id == null || known == null || req.method != 'GET') {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final range = req.headers.value(HttpHeaders.rangeHeader);
    try {
      if (_index.containsKey(id)) {
        await _serveFile(id, range, res);
      } else if (_fromStart(range) && !_writing.contains(id)) {
        await _passThrough(known, id, null, res, save: true);
      } else {
        await _passThrough(known, id, range, res, save: false);
      }
    } catch (e) {
      // The engine closing a stream early (skip, seek) lands here.
      try {
        await res.close();
      } catch (_) {}
    }
  }

  static bool _fromStart(String? range) =>
      range == null || RegExp(r'^bytes=0-$').hasMatch(range.trim());

  Future<void> _serveFile(String id, String? range, HttpResponse res) async {
    final entry = _index[id]!;
    entry.used = DateTime.now();
    _reading[id] = (_reading[id] ?? 0) + 1;
    try {
      final file = _file(id);
      final size = entry.size;
      var start = 0, end = size - 1;
      final m = range == null
          ? null
          : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      if (m != null) {
        final s = m[1]!, e = m[2]!;
        if (s.isEmpty && e.isNotEmpty) {
          start = max(0, size - int.parse(e));
        } else {
          start = int.tryParse(s) ?? 0;
          if (e.isNotEmpty) end = min(size - 1, int.parse(e));
        }
        if (start >= size || start > end) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          await res.close();
          return;
        }
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
      }
      res.headers
        ..contentType = ContentType.binary
        ..contentLength = end - start + 1
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      await res.addStream(file.openRead(start, end + 1));
      await res.close();
      unawaited(file.setLastModified(entry.used).catchError((_) {}));
    } finally {
      final n = (_reading[id] ?? 1) - 1;
      n <= 0 ? _reading.remove(id) : _reading[id] = n;
    }
  }

  Future<void> _passThrough(
    CacheRequest known,
    String id,
    String? range,
    HttpResponse res, {
    required bool save,
  }) async {
    final up = await _client.getUrl(known.upstream);
    if (range != null) up.headers.set(HttpHeaders.rangeHeader, range);
    final upRes = await up.close();
    res.statusCode = upRes.statusCode;
    for (final h in [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
    ]) {
      final v = upRes.headers.value(h);
      if (v != null) res.headers.set(h, v);
    }
    if (upRes.contentLength >= 0) res.contentLength = upRes.contentLength;
    save =
        save &&
        upRes.statusCode == HttpStatus.ok &&
        !_isError(upRes) &&
        !_writing.contains(id);
    if (!save) {
      await res.addStream(upRes);
      await res.close();
      return;
    }
    _writing.add(id);
    final part = _part(id);
    final sink = part.openWrite();
    var n = 0;
    var ok = false;
    try {
      await res.addStream(
        upRes.map((chunk) {
          sink.add(chunk);
          n += chunk.length;
          return chunk;
        }),
      );
      await sink.close();
      ok = upRes.contentLength < 0 || n == upRes.contentLength;
      if (ok) await _commit(id, part, n);
      await res.close();
    } finally {
      _writing.remove(id);
      if (!ok) {
        await sink.close().catchError((_) {});
        await _tryDelete(part);
      }
      _pump();
    }
  }

  Future<bool> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _log(String msg) => debugPrint('TrackCache: $msg');

  @override
  Future<void> dispose() async {
    _disposed = true;
    _download?.cancel();
    await _server.close(force: true);
    _client.close(force: true);
    await _changes.close();
  }
}

class _Entry {
  final int size;
  DateTime used;
  _Entry(this.size, this.used);
}

class _Download {
  final String id;
  HttpClientRequest? request;
  bool cancelled = false;
  _Download(this.id);

  void cancel() {
    cancelled = true;
    request?.abort();
  }
}

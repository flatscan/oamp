import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/downloads.dart';

/// [DownloadStore] on disk, in the app's own data folder (never in the
/// cache folder, which the OS may empty).
///
/// Layout, with names hashed so nothing in a file name says what the music
/// is:
///
///     downloads/<server>/tracks/<track>.<ext>          a complete file
///     downloads/<server>/tracks/<track>.<quality>.part  one still arriving
///     downloads/<server>/pins/<pin>.json                what a pin holds
class DiskDownloadStore implements DownloadStore {
  DiskDownloadStore._(this._root, this.retryDelays, this.stallAfter);

  /// The waits between attempts to reach the server again.
  final List<Duration> retryDelays;

  /// A download that receives nothing for this long counts as dropped.
  final Duration stallAfter;

  final Directory _root;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  final _changes = StreamController<void>.broadcast();

  /// Complete files: server hash, then track hash, to the file.
  final Map<String, Map<String, File>> _files = {};

  /// Servers whose last pin read skipped a file it could not parse, so
  /// [retain] must not delete files a damaged pin may still need.
  final Set<String> _damaged = {};

  /// Opens the store in the app's data folder, or returns null when there
  /// is nowhere to keep files.
  static Future<DiskDownloadStore?> openDefault() async {
    if (kIsWeb) return null;
    try {
      final base = await getApplicationSupportDirectory();
      return await open(
        Directory('${base.path}${Platform.pathSeparator}downloads'),
      );
    } catch (e) {
      debugPrint('Downloads unavailable: $e');
      return null;
    }
  }

  static Future<DiskDownloadStore> open(
    Directory root, {
    List<Duration> retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ],
    Duration stallAfter = const Duration(seconds: 20),
  }) async {
    await root.create(recursive: true);
    final store = DiskDownloadStore._(root, retryDelays, stallAfter);
    await store._scan();
    return store;
  }

  static String hash(String value) =>
      sha1.convert(utf8.encode(value)).toString();

  String get _sep => Platform.pathSeparator;

  Directory _serverDir(String serverId) =>
      Directory('${_root.path}$_sep${hash(serverId)}');
  Directory _tracksDir(String serverId) =>
      Directory('${_serverDir(serverId).path}${_sep}tracks');
  Directory _pinsDir(String serverId) =>
      Directory('${_serverDir(serverId).path}${_sep}pins');

  Future<void> _scan() async {
    await for (final server in _root.list()) {
      if (server is! Directory) continue;
      final serverHash = server.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last;
      final tracks = Directory('${server.path}${_sep}tracks');
      if (!await tracks.exists()) continue;
      await for (final f in tracks.list()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        if (name.endsWith('.part')) continue;
        final dot = name.indexOf('.');
        if (dot <= 0) continue;
        (_files[serverHash] ??= {})[name.substring(0, dot)] = f;
      }
    }
  }

  @override
  bool has(String serverId, String trackId) =>
      _files[hash(serverId)]?.containsKey(hash(trackId)) ?? false;

  @override
  Uri? fileUri(String serverId, String trackId) =>
      _files[hash(serverId)]?[hash(trackId)]?.uri;

  @override
  Stream<void> get changes => _changes.stream;

  // ---- Pins ------------------------------------------------------------

  File _pinFile(String serverId, String key) =>
      File('${_pinsDir(serverId).path}$_sep${hash(key)}.json');

  @override
  Future<List<Pin>> pins(String serverId) async {
    final dir = _pinsDir(serverId);
    _damaged.remove(serverId);
    if (!await dir.exists()) return const [];
    final out = <Pin>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final pin = Pin.fromJson(jsonDecode(await f.readAsString()));
        if (pin == null) throw const FormatException('not a pin');
        out.add(pin);
      } catch (e) {
        _damaged.add(serverId);
        debugPrint('Skipped an unreadable download record: $e');
      }
    }
    out.sort((a, b) => a.pinnedAt.compareTo(b.pinnedAt));
    return out;
  }

  @override
  Future<void> savePin(String serverId, Pin pin) async {
    final dir = _pinsDir(serverId);
    await dir.create(recursive: true);
    final file = _pinFile(serverId, pin.key);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(pin.toJson()), flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> removePin(String serverId, String pinKey) async {
    final file = _pinFile(serverId, pinKey);
    if (await file.exists()) await file.delete();
  }

  // ---- Files -----------------------------------------------------------

  @override
  Future<void> removeTrack(String serverId, String trackId) =>
      removeTracks(serverId, [trackId]);

  /// Deletes the files, then lists the folder once for half-finished ones,
  /// rather than once per track.
  @override
  Future<void> removeTracks(String serverId, Iterable<String> trackIds) async {
    final ids = {for (final t in trackIds) hash(t)};
    if (ids.isEmpty) return;
    final files = _files[hash(serverId)];
    for (final id in ids) {
      final file = files?.remove(id);
      if (file == null) continue;
      _sizes.remove(file.path);
      await _tryDelete(file);
    }
    final dir = _tracksDir(serverId);
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.part')) continue;
        final name = f.uri.pathSegments.last;
        final dot = name.indexOf('.');
        if (dot > 0 && ids.contains(name.substring(0, dot))) {
          await _tryDelete(f);
        }
      }
    }
    _changes.add(null);
  }

  @override
  Future<void> retain(String serverId, Set<String> keep) async {
    if (_damaged.contains(serverId)) return;
    final keepHashes = {for (final id in keep) hash(id)};
    final files = _files[hash(serverId)] ?? {};
    for (final id in files.keys.toList()) {
      if (keepHashes.contains(id)) continue;
      final file = files.remove(id)!;
      _sizes.remove(file.path);
      await _tryDelete(file);
    }
    final dir = _tracksDir(serverId);
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        if (f is File && f.path.endsWith('.part')) await _tryDelete(f);
      }
    }
    _changes.add(null);
  }

  @override
  Future<void> removeServer(String serverId) async {
    for (final f in (_files.remove(hash(serverId)) ?? {}).values) {
      _sizes.remove(f.path);
    }
    final dir = _serverDir(serverId);
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        debugPrint('Could not remove downloads: $e');
      }
    }
    _changes.add(null);
  }

  /// File sizes by path, so the usage total doesn't ask the disk about
  /// every file each time a download finishes.
  final Map<String, int> _sizes = {};

  @override
  Future<int> usageBytes(String serverId) async {
    var total = 0;
    for (final f in (_files[hash(serverId)] ?? {}).values) {
      try {
        total += _sizes[f.path] ??= await f.length();
      } catch (_) {}
    }
    return total;
  }

  Future<void> _tryDelete(File f) async {
    try {
      await f.delete();
    } catch (e) {
      debugPrint('Could not delete a download file: $e');
    }
  }

  // ---- Fetching --------------------------------------------------------

  @override
  Future<void> fetch(
    String serverId,
    String trackId, {
    required Uri Function() upstream,
    required String extension,
    required String variant,
    required FetchCancel cancel,
    void Function()? onUnreachable,
    void Function(int received, int? total)? onProgress,
  }) async {
    final dir = _tracksDir(serverId);
    await dir.create(recursive: true);
    final id = hash(trackId);
    final part = File('${dir.path}$_sep$id.$variant.part');
    final target = File('${dir.path}$_sep$id.$extension');

    var attempt = 0;
    while (true) {
      if (cancel.cancelled) {
        throw const DownloadException(
          DownloadFailure.cancelled,
          'Download cancelled',
        );
      }
      try {
        await _attempt(upstream(), part, cancel, onProgress);
        break;
      } on DownloadException {
        rethrow;
      } on FileSystemException catch (e) {
        if (_isDiskFull(e)) {
          throw const DownloadException(
            DownloadFailure.storageFull,
            'The device is out of space',
          );
        }
        rethrow;
      } on Object catch (e) {
        // The network dropped or the server went quiet: ask the source
        // whether its other address works, then go again from where the
        // file got to.
        debugPrint('Download interrupted: ${e.runtimeType}');
        onUnreachable?.call();
        if (attempt >= retryDelays.length) {
          throw const DownloadException(
            DownloadFailure.unreachable,
            'The server could not be reached',
          );
        }
        await Future<void>.delayed(retryDelays[attempt++]);
      }
    }

    if (cancel.cancelled) {
      // Cancelled as the last bytes arrived: the caller no longer wants it.
      await _tryDelete(part);
      throw const DownloadException(
        DownloadFailure.cancelled,
        'Download cancelled',
      );
    }

    // Replace any older copy, such as at another file type.
    final files = _files[hash(serverId)] ??= {};
    final old = files[id];
    if (old != null && old.path != target.path) {
      _sizes.remove(old.path);
      await _tryDelete(old);
    }
    if (await target.exists()) await target.delete();
    final done = await part.rename(target.path);
    files[id] = done;
    _sizes.remove(done.path);
    _changes.add(null);
  }

  /// One go at the whole file or, when [part] already holds the start of
  /// it, the rest. Throws on anything that should be tried again.
  Future<void> _attempt(
    Uri url,
    File part,
    FetchCancel cancel,
    void Function(int received, int? total)? onProgress,
  ) async {
    final have = await part.exists() ? await part.length() : 0;
    final request = await _client.getUrl(url);
    if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
    final response = await request.close().timeout(stallAfter);

    if (response.statusCode == 416) {
      // The partial file does not fit what the server has now.
      await response.drain<void>();
      await _tryDelete(part);
      throw const SocketException('Partial file discarded');
    }
    if (response.statusCode >= 500) {
      await response.drain<void>();
      throw HttpException('Server error ${response.statusCode}');
    }
    final type = response.headers.contentType;
    final isError =
        response.statusCode >= 400 ||
        // Subsonic servers report errors with a normal status and a body
        // of XML or JSON in place of audio, and a proxy or login page
        // answers with HTML.
        (type != null &&
            (type.subType == 'json' ||
                type.subType == 'html' ||
                type.subType.contains('xml')));
    if (isError) {
      final body = await _readSome(response);
      if (isLoginRefusal(
        status: response.statusCode,
        code: subsonicErrorCode(body),
      )) {
        throw const DownloadException(
          DownloadFailure.login,
          'The server turned the login down',
        );
      }
      throw DownloadException(
        DownloadFailure.server,
        response.statusCode >= 400
            ? 'The server refused the track (${response.statusCode})'
            : 'The server did not send audio',
      );
    }

    final resume = response.statusCode == 206 && have > 0;
    final length = response.contentLength;
    final total = length < 0 ? null : length + (resume ? have : 0);
    var received = resume ? have : 0;
    final sink = part.openWrite(
      mode: resume ? FileMode.append : FileMode.write,
    );
    try {
      await for (final chunk in response.timeout(stallAfter)) {
        if (cancel.cancelled) {
          throw const DownloadException(
            DownloadFailure.cancelled,
            'Download cancelled',
          );
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close().catchError((Object _) {});
    }
    if (total != null && received != total) {
      throw SocketException('Got $received of $total bytes');
    }
    if (received == 0) throw const SocketException('Empty reply');
  }

  /// The start of an error reply, enough to find its error code.
  static Future<String> _readSome(HttpClientResponse response) async {
    final bytes = <int>[];
    try {
      await for (final chunk in response) {
        if (bytes.length < 16 * 1024) bytes.addAll(chunk);
      }
    } catch (_) {}
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// ENOSPC on Android, ERROR_DISK_FULL and ERROR_HANDLE_DISK_FULL on
  /// Windows.
  static bool _isDiskFull(FileSystemException e) {
    final code = e.osError?.errorCode;
    return code == 28 || code == 112 || code == 39;
  }
}

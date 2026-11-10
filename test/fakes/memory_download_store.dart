import 'dart:async';

import 'package:oamp/core/downloads.dart';

/// A store that keeps everything in memory, and can be told to fail.
class MemoryDownloadStore implements DownloadStore {
  final Map<String, Pin> savedPins = {};
  final Set<String> files = {};
  final List<String> fetched = [];
  final _changes = StreamController<void>.broadcast();

  /// Failures to throw, one per fetch, before a fetch succeeds.
  final List<DownloadException> failures = [];

  /// Holds fetches until completed, to look at the state meanwhile.
  Completer<void>? gate;
  String? lastUrl;

  @override
  Future<List<Pin>> pins(String serverId) async => savedPins.values.toList();
  @override
  Future<void> savePin(String serverId, Pin pin) async =>
      savedPins[pin.key] = pin;
  @override
  Future<void> removePin(String serverId, String pinKey) async =>
      savedPins.remove(pinKey);
  @override
  bool has(String serverId, String trackId) => files.contains(trackId);
  @override
  Uri? fileUri(String serverId, String trackId) =>
      files.contains(trackId) ? Uri.file('/downloads/$trackId.flac') : null;
  @override
  Future<void> fetch(
    String serverId,
    String trackId, {
    required Uri Function() upstream,
    required String extension,
    required String variant,
    required FetchCancel cancel,
    void Function()? onUnreachable,
    void Function(int, int?)? onProgress,
  }) async {
    lastUrl = upstream().toString();
    if (gate != null) await gate!.future;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    onProgress?.call(50, 100);
    fetched.add(trackId);
    files.add(trackId);
    _changes.add(null);
  }

  @override
  Future<void> removeTrack(String serverId, String trackId) async =>
      files.remove(trackId);
  @override
  Future<void> retain(String serverId, Set<String> keep) async =>
      files.removeWhere((f) => !keep.contains(f));
  @override
  Future<void> removeServer(String serverId) async {
    files.clear();
    savedPins.clear();
  }

  @override
  Future<int> usageBytes(String serverId) async => files.length * 1000;
  @override
  Stream<void> get changes => _changes.stream;
}

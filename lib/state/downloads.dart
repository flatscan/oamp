import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import '../core/playback_options.dart';
import '../platform/network_monitor.dart';
import 'session.dart';
import 'settings.dart';

/// Where one pin stands.
class PinStatus {
  final int total;
  final int done;

  /// 0 to 1, counting the files being fetched right now as part-done.
  final double progress;

  const PinStatus({
    required this.total,
    required this.done,
    required this.progress,
  });

  bool get complete => total > 0 && done >= total;
}

class DownloadsState {
  /// Whether the saved pins have been read yet.
  final bool loaded;
  final List<Pin> pins;

  /// Ids of tracks whose files are complete on the device.
  final Set<String> downloaded;

  /// Tracks being fetched now, to how far (0 to 1; null when unknown).
  final Map<String, double?> active;

  /// Why downloading is waiting, in words, or null when it is not.
  final String? problem;

  const DownloadsState({
    this.loaded = false,
    this.pins = const [],
    this.downloaded = const {},
    this.active = const {},
    this.problem,
  });

  DownloadsState copyWith({
    bool? loaded,
    List<Pin>? pins,
    Set<String>? downloaded,
    Map<String, double?>? active,
    String? Function()? problem,
  }) => DownloadsState(
    loaded: loaded ?? this.loaded,
    pins: pins ?? this.pins,
    downloaded: downloaded ?? this.downloaded,
    active: active ?? this.active,
    problem: problem == null ? this.problem : problem(),
  );

  Pin? pinFor(PinKind kind, String itemId) {
    final key = Pin.keyFor(kind, itemId);
    for (final p in pins) {
      if (p.key == key) return p;
    }
    return null;
  }

  /// Null when the item is not pinned.
  PinStatus? statusOf(PinKind kind, String itemId) {
    final pin = pinFor(kind, itemId);
    if (pin == null) return null;
    var done = 0;
    var partial = 0.0;
    for (final t in pin.tracks) {
      if (downloaded.contains(t.id)) {
        done++;
      } else if (active.containsKey(t.id)) {
        partial += active[t.id] ?? 0;
      }
    }
    final total = pin.tracks.length;
    return PinStatus(
      total: total,
      done: done,
      progress: total == 0 ? 1 : (done + partial) / total,
    );
  }

  /// Tracks still to fetch, over every pin.
  int get remaining {
    final wanted = <String>{};
    for (final p in pins) {
      for (final t in p.tracks) {
        if (!downloaded.contains(t.id)) wanted.add(t.id);
      }
    }
    return wanted.length;
  }

  int get totalTracks => {
    for (final p in pins)
      for (final t in p.tracks) t.id,
  }.length;
}

final downloadsProvider = NotifierProvider<DownloadManager, DownloadsState>(
  DownloadManager.new,
);

/// The settings that decide how downloads are fetched.
final downloadOptionsProvider = Provider<DownloadOptions>(
  (ref) => ref.watch(settingsProvider.select((s) => s.downloads)),
);

/// Disk used by this server's downloads, refreshed as files come and go.
final downloadUsageProvider = FutureProvider.autoDispose<int>((ref) async {
  final store = ref.watch(downloadStoreProvider);
  final serverId = ref.watch(sessionProvider).value?.serverId;
  if (store == null || serverId == null) return 0;
  // Recount whenever a file finishes or the pins change.
  ref.watch(downloadsProvider.select((s) => s.downloaded.length));
  return store.usageBytes(serverId);
});

/// Keeps the pins, fetches what they are missing, and removes what no pin
/// needs. Watched once from the app root so it runs for the app's
/// lifetime.
class DownloadManager extends Notifier<DownloadsState> {
  /// How long to wait before trying again after the server could not be
  /// reached.
  static const retryAfterUnreachable = Duration(seconds: 30);

  /// How long to wait before trying again after the device ran out of space.
  static const retryAfterFull = Duration(minutes: 5);

  DownloadStore? get _store => ref.read(downloadStoreProvider);
  String? get _serverId => ref.read(sessionProvider).value?.serverId;

  bool _running = false;
  bool _disposed = false;
  Timer? _retry;
  int _generation = 0;
  ({String trackId, FetchCancel cancel})? _current;
  Timer? _progressTimer;
  final Map<String, double?> _pendingProgress = {};

  /// Tracks the server refused, left alone until the next fresh start so
  /// one bad file doesn't hold up the rest.
  final Set<String> _refused = {};

  @override
  DownloadsState build() {
    final store = ref.watch(downloadStoreProvider);
    final session = ref.watch(sessionProvider).value;
    final generation = ++_generation;
    _disposed = false;
    _running = false;
    _retry?.cancel();
    ref.onDispose(() {
      _disposed = true;
      _retry?.cancel();
      _progressTimer?.cancel();
      _current?.cancel.cancel();
    });
    _refused.clear();
    if (store == null || session == null) return const DownloadsState();

    // Pick up where things stopped when the network, or the server,
    // changes.
    ref.listen(networkKindProvider, (_, _) => kick());
    ref.listen(serverStatusProvider, (prev, next) {
      if (next.health == ServerHealth.ok && prev?.health != ServerHealth.ok) {
        kick();
      }
    });
    ref.listen(downloadOptionsProvider, (_, _) => kick());

    unawaited(_load(store, session.serverId, generation));
    return const DownloadsState();
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  Future<void> _load(DownloadStore store, String serverId, int gen) async {
    try {
      final pins = await store.pins(serverId);
      if (_stale(gen)) return;
      final wanted = {
        for (final p in pins)
          for (final t in p.tracks) t.id,
      };
      await store.retain(serverId, wanted);
      if (_stale(gen)) return;
      state = DownloadsState(
        loaded: true,
        pins: pins,
        downloaded: _downloadedAmong(store, serverId, pins),
      );
      kick();
    } catch (e) {
      debugPrint('Could not read downloads: $e');
      if (!_stale(gen)) state = state.copyWith(loaded: true);
    }
  }

  static Set<String> _downloadedAmong(
    DownloadStore store,
    String serverId,
    List<Pin> pins,
  ) => {
    for (final p in pins)
      for (final t in p.tracks)
        if (store.has(serverId, t.id)) t.id,
  };

  /// Keeps [tracks] on the device as pin [kind]/[itemId], replacing the
  /// pin if there already is one.
  Future<void> pin(
    PinKind kind,
    String itemId, {
    required String name,
    String? coverArt,
    required List<Track> tracks,
  }) async {
    final store = _store;
    final serverId = _serverId;
    if (store == null || serverId == null) return;
    final existing = state.pinFor(kind, itemId);
    final pin = Pin(
      kind: kind,
      itemId: itemId,
      name: name,
      coverArt: coverArt,
      tracks: tracks,
      pinnedAt: existing?.pinnedAt ?? DateTime.now(),
    );
    await store.savePin(serverId, pin);
    if (_disposed) return;
    state = state.copyWith(
      pins: [
        for (final p in state.pins)
          if (p.key != pin.key) p,
        pin,
      ],
      downloaded: _downloadedAmong(store, serverId, [...state.pins, pin]),
    );
    _refused.clear();
    kick();
  }

  /// Stops keeping an item and removes the files no other pin needs.
  Future<void> unpin(PinKind kind, String itemId) async {
    final store = _store;
    final serverId = _serverId;
    final pin = state.pinFor(kind, itemId);
    if (store == null || serverId == null || pin == null) return;
    final rest = [
      for (final p in state.pins)
        if (p.key != pin.key) p,
    ];
    final stillWanted = {
      for (final p in rest)
        for (final t in p.tracks) t.id,
    };
    // Show it gone at once; the files follow.
    state = state.copyWith(
      pins: rest,
      downloaded: {
        for (final id in state.downloaded)
          if (stillWanted.contains(id)) id,
      },
    );
    final current = _current;
    if (current != null && !stillWanted.contains(current.trackId)) {
      current.cancel.cancel();
    }
    await store.removePin(serverId, pin.key);
    for (final t in pin.tracks) {
      if (!stillWanted.contains(t.id)) await store.removeTrack(serverId, t.id);
    }
    kick();
  }

  /// Removes every download for the signed-in server.
  Future<void> removeAll() async {
    final store = _store;
    final serverId = _serverId;
    if (store == null || serverId == null) return;
    _current?.cancel.cancel();
    state = state.copyWith(pins: const [], downloaded: const {});
    await store.removeServer(serverId);
  }

  /// Starts fetching if it is not already, or has stopped to wait for
  /// something that may have changed.
  void kick() {
    if (_running || _disposed) return;
    final store = _store;
    final serverId = _serverId;
    if (store == null || serverId == null || !state.loaded) return;
    _retry?.cancel();
    _running = true;
    unawaited(_run(store, serverId, _generation));
  }

  Track? _next() {
    for (final p in state.pins) {
      for (final t in p.tracks) {
        if (!state.downloaded.contains(t.id) && !_refused.contains(t.id)) {
          return t;
        }
      }
    }
    return null;
  }

  void _setProblem(String? text) {
    if (_disposed || state.problem == text) return;
    state = state.copyWith(problem: () => text);
  }

  Future<void> _run(DownloadStore store, String serverId, int gen) async {
    try {
      while (!_stale(gen)) {
        final track = _next();
        if (track == null) {
          _setProblem(null);
          return;
        }
        final options = ref.read(downloadOptionsProvider);
        if (options.wifiOnly &&
            ref.read(networkKindProvider) == NetworkKind.mobile) {
          _setProblem('Waiting for Wi-Fi');
          return;
        }
        final source = ref.read(sessionProvider).value?.source;
        if (source == null) return;

        final quality = options.quality;
        final cancel = FetchCancel();
        _current = (trackId: track.id, cancel: cancel);
        state = state.copyWith(active: {...state.active, track.id: null});
        try {
          await store.fetch(
            serverId,
            track.id,
            upstream: () => source.streamUrl(track.id, quality: quality),
            extension: _extension(track, quality),
            variant: quality.tag,
            cancel: cancel,
            onUnreachable: source.reportUnreachable,
            onProgress: (got, total) =>
                _progress(track.id, total == null ? null : got / total),
          );
          if (_stale(gen)) return;
          _setProblem(null);
          final wanted = {
            for (final p in state.pins)
              for (final t in p.tracks) t.id,
          };
          if (wanted.contains(track.id)) {
            state = state.copyWith(downloaded: {...state.downloaded, track.id});
          } else {
            // Its pin was removed while it was arriving.
            await store.removeTrack(serverId, track.id);
          }
        } on DownloadException catch (e) {
          if (_stale(gen)) return;
          switch (e.kind) {
            case DownloadFailure.cancelled:
              break;
            case DownloadFailure.server:
              debugPrint('A download was refused: ${e.message}');
              _refused.add(track.id);
            case DownloadFailure.unreachable:
              _setProblem('The server can’t be reached. Will keep trying.');
              _retry = Timer(retryAfterUnreachable, kick);
              return;
            case DownloadFailure.storageFull:
              _setProblem(
                'The device is out of space. Free some up and downloading '
                'will carry on.',
              );
              _retry = Timer(retryAfterFull, kick);
              return;
          }
        } on Object catch (e) {
          if (_stale(gen)) return;
          // Something unexpected with this one file: leave it for now.
          debugPrint('A download failed: ${e.runtimeType}');
          _refused.add(track.id);
        } finally {
          _current = null;
          if (!_disposed) {
            state = state.copyWith(
              active: {
                for (final e in state.active.entries)
                  if (e.key != track.id) e.key: e.value,
              },
            );
          }
        }
      }
    } finally {
      if (gen == _generation) _running = false;
    }
  }

  /// Progress comes many times a second; the screen is told a few times.
  void _progress(String trackId, double? fraction) {
    _pendingProgress[trackId] = fraction;
    _progressTimer ??= Timer(const Duration(milliseconds: 250), () {
      _progressTimer = null;
      if (_disposed) return;
      final updates = {..._pendingProgress};
      _pendingProgress.clear();
      state = state.copyWith(
        active: {
          for (final e in state.active.entries)
            e.key: updates.containsKey(e.key) ? updates[e.key] : e.value,
        },
      );
    });
  }

  /// The file's type, so players and people can tell what it is.
  static String _extension(Track track, StreamQuality quality) {
    if (!quality.isOriginal) return quality.format.name;
    final f = (track.format ?? '').toLowerCase().replaceAll(
      RegExp('[^a-z0-9]'),
      '',
    );
    return f.isEmpty || f.length > 5 ? 'audio' : f;
  }
}

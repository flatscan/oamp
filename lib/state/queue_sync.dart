import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/music_source.dart';
import '../core/play_queue.dart';
import '../platform/preferences.dart';
import 'player.dart';
import 'session.dart';
import 'settings.dart';

/// Keeps the play queue across restarts and devices.
///
/// The queue, current track and position are saved on this device for each
/// server (so a v2 server switcher restores the right one), and, when the
/// server keeps a play queue and syncing is on, on the server too. At
/// start-up the newer of the two is loaded, paused where it was left. When
/// the app comes back to the front while paused, a queue saved since by
/// another device or app is picked up.
///
/// Watched once from the app root so it lives as long as the app.
final queueSyncProvider = Provider<QueueSync>((ref) {
  final sync = QueueSync(ref);
  ref.onDispose(sync.dispose);
  ref.listen(
    sessionProvider,
    (_, next) => sync._onSession(next.value),
    fireImmediately: true,
  );
  ref.listen(playerProvider, sync._onPlayer);
  ref.listen(syncQueueProvider, (prev, next) {
    if (next && prev == false) sync._enqueueSave();
  });
  return sync;
});

class QueueSync {
  QueueSync(this.ref);
  final Ref ref;

  /// How long queue edits settle before they are saved.
  static const debounce = Duration(seconds: 2);

  /// How often the position is saved while playing.
  static const interval = Duration(seconds: 20);

  /// The shortest gap between two looks at the server's queue.
  static const checkGap = Duration(seconds: 10);

  static String _queueKey(String id) => 'oamp.queue.$id';
  static String _positionKey(String id) => 'oamp.queue.$id.positionMs';
  static String _changedKey(String id) => 'oamp.queue.$id.changed';
  static String _syncedKey(String id) => 'oamp.queue.$id.synced';

  static const _emptyPrint = '|null|0';

  String? _serverId;

  /// Bumped on every change of server, so work started for the old one
  /// stops.
  int _generation = 0;

  /// Saving starts only once the saved queue has been restored, so the
  /// empty queue at start-up never overwrites it.
  bool _ready = false;

  /// [SavedQueue.fingerprint] of what the server holds, as last read or
  /// saved, or null when unknown.
  String? _serverPrint;

  /// What the queue entry on this device holds, to skip rewriting it when
  /// only the position moved.
  String? _localPrint;

  Future<void> _restoring = Future.value();
  Future<void> _saving = Future.value();
  Timer? _debounce;
  Timer? _ticker;
  DateTime? _lastCheck;

  Preferences get _prefs => ref.read(preferencesProvider);
  PlayerController get _player => ref.read(playerProvider.notifier);

  /// The active source, while it is still the server this was set up for.
  MusicSource? get _source {
    final s = ref.read(sessionProvider).value;
    return s != null && s.serverId == _serverId ? s.source : null;
  }

  bool get _canSync =>
      ref.read(syncQueueProvider) &&
      (_source?.capabilities.hasQueueSync ?? false);

  /// Completes once the saved queue has been loaded for the current server.
  Future<void> get restored => _restoring;

  /// Completes once every save asked for so far has finished.
  Future<void> get saved => _saving;

  void _onSession(ServerSession? s) {
    if (s?.serverId == _serverId) return;
    _stopTimers();
    _generation++;
    _ready = false;
    _serverPrint = null;
    _localPrint = null;
    _lastCheck = null;
    _serverId = s?.serverId;
    // Not straight away: this can run while the provider is being built,
    // when the player must not be changed.
    final gen = _generation;
    if (s != null) _restoring = Future(() => _restore(gen));
  }

  void _onPlayer(PlayerState? prev, PlayerState next) {
    if (!_ready) return;
    final edited =
        !identical(prev?.queue, next.queue) ||
        prev?.currentIndex != next.currentIndex ||
        prev?.from != next.from;
    if (prev?.playing == true && !next.playing) {
      // Paused or finished: save the position straight away.
      _debounce?.cancel();
      _enqueueSave();
    } else if (edited) {
      _debounce?.cancel();
      _debounce = Timer(debounce, _enqueueSave);
    }
    if (next.playing) {
      _ticker ??= Timer.periodic(interval, (_) => _enqueueSave());
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Whether work for server generation [gen] should carry on.
  bool _current(int gen) => !_disposed && gen == _generation;
  bool _disposed = false;

  Future<void> _restore(int gen) async {
    if (!_current(gen)) return;
    final id = _serverId!;
    final local = _readLocal(id);
    final localSynced = _prefs.getBool(_syncedKey(id)) ?? false;
    SavedQueue? remote;
    var remoteKnown = false;
    if (_canSync) {
      try {
        remote = await _source!.getPlayQueue();
        remoteKnown = true;
      } catch (e) {
        debugPrint('Could not read the server play queue: $e');
      }
    }
    if (!_current(gen)) return;
    if (remoteKnown) _serverPrint = remote?.fingerprint ?? _emptyPrint;
    final pick = remoteKnown ? choose(local, localSynced, remote) : local;
    // Something may have started playing while the server was asked.
    if (pick != null &&
        !pick.isEmpty &&
        ref.read(playerProvider).queue.isEmpty) {
      try {
        await _player.restore(pick);
      } catch (e) {
        debugPrint('Could not restore the play queue: $e');
      }
    }
    if (!_current(gen)) return;
    _ready = true;
    // Brings this device's copy and the server's in line with what is now
    // queued; does nothing when they already match.
    _enqueueSave();
  }

  /// Which saved queue to resume at start-up: the one on this device
  /// ([local]) or the server's ([remote]). [localSynced] says whether the
  /// local copy reached the server when it was saved; if so, any difference
  /// on the server was made since by another device or app.
  static SavedQueue? choose(
    SavedQueue? local,
    bool localSynced,
    SavedQueue? remote,
  ) {
    if (remote == null || remote.isEmpty) {
      // Cleared elsewhere after this device last saved.
      return localSynced ? null : local;
    }
    if (local == null || local.isEmpty) return remote;
    if (local.fingerprint == remote.fingerprint) return local;
    if (localSynced) {
      // Same queue played on elsewhere: keep this copy, which knows which of
      // two identical entries was current, at the new position.
      return local.contentFingerprint == remote.contentFingerprint
          ? local.copyWith(position: remote.position)
          : remote;
    }
    // This device saved something the server never got (it was offline, or
    // syncing was off). Keep whichever is newer.
    final lc = local.changed, rc = remote.changed;
    if (lc == null || rc == null) return local;
    return rc.isAfter(lc) ? remote : local;
  }

  SavedQueue? _readLocal(String id) {
    final raw = _prefs.getString(_queueKey(id));
    if (raw == null) return null;
    try {
      final q = SavedQueue.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
      if (q == null) return null;
      _localPrint = q.localFingerprint;
      return q.copyWith(
        position: Duration(milliseconds: _prefs.getInt(_positionKey(id)) ?? 0),
        changed: DateTime.tryParse(_prefs.getString(_changedKey(id)) ?? ''),
      );
    } catch (e) {
      debugPrint('Ignoring an unreadable saved queue: $e');
      return null;
    }
  }

  void _enqueueSave() {
    _saving = _saving.then((_) => _save()).catchError((Object e) {
      debugPrint('Could not save the play queue: $e');
    });
  }

  /// Saves the queue now, such as when the app is about to close.
  Future<void> flush() {
    _debounce?.cancel();
    _enqueueSave();
    return _saving;
  }

  Future<void> _save() async {
    final gen = _generation;
    if (_disposed) return;
    final id = _serverId;
    final source = _source;
    if (!_ready || id == null || source == null) return;
    final canSync = _canSync;
    final now = DateTime.now().toUtc();
    final snap = _player.snapshot().copyWith(changed: now);
    final content = snap.localFingerprint;
    final fp = snap.fingerprint;
    final push = canSync && fp != _serverPrint;
    final p = _prefs;
    if (content != _localPrint) {
      await p.setString(_queueKey(id), jsonEncode(snap.toJson()));
      _localPrint = content;
    }
    await p.setInt(_positionKey(id), snap.position.inMilliseconds);
    await p.setString(_changedKey(id), now.toIso8601String());
    if (!canSync) return p.setBool(_syncedKey(id), false);
    if (!push) return p.setBool(_syncedKey(id), true);
    await p.setBool(_syncedKey(id), false);
    try {
      await source.savePlayQueue(
        [for (final t in snap.tracks) t.id],
        currentIndex: snap.currentIndex,
        position: snap.position,
      );
    } catch (e) {
      debugPrint('Could not save the play queue to the server: $e');
      return;
    }
    if (!_current(gen)) return;
    _serverPrint = fp;
    await p.setBool(_syncedKey(id), true);
  }

  /// Picks up a queue another device or app saved to the server since this
  /// one last looked, unless something is playing here. Called when the
  /// app comes back to the front.
  Future<void> checkServer() async {
    if (!_ready || !_canSync || (_debounce?.isActive ?? false)) return;
    if (ref.read(playerProvider).playing) return;
    final now = DateTime.now();
    if (_lastCheck != null && now.difference(_lastCheck!) < checkGap) return;
    _lastCheck = now;
    final gen = _generation;
    await _saving;
    if (!_current(gen)) return;
    final SavedQueue? remote;
    try {
      remote = await _source!.getPlayQueue();
    } catch (e) {
      debugPrint('Could not read the server play queue: $e');
      return;
    }
    if (!_current(gen) || ref.read(playerProvider).playing) return;
    final fp = remote?.fingerprint ?? _emptyPrint;
    final known = _serverPrint;
    _serverPrint = fp;
    // Unknown before (the server could not be reached at start-up), or
    // unchanged: nothing new to pick up. A queue cleared elsewhere leaves
    // this one alone.
    if (known == null || fp == known || remote == null || remote.isEmpty) {
      return;
    }
    final here = _player.snapshot();
    await _player.restore(
      here.contentFingerprint == remote.contentFingerprint
          ? here.copyWith(position: remote.position)
          : remote,
    );
    _enqueueSave();
  }

  void _stopTimers() {
    _debounce?.cancel();
    _debounce = null;
    _ticker?.cancel();
    _ticker = null;
  }

  void dispose() {
    _disposed = true;
    _stopTimers();
  }
}

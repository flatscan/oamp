import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/music_source.dart';
import 'player.dart';
import 'session.dart';

/// Reports listening to the server: "now playing" when a track starts, and
/// a play once it has been heard for half its length or four minutes,
/// whichever comes first (the usual scrobbling rule). This is what keeps the
/// server's play counts and "recently played" lists current.
///
/// Servers that show live playback state (see
/// [SourceCapabilities.hasPlaybackState]) are also told when playback starts,
/// pauses, resumes, seeks or stops, and the position every half minute, so
/// their now-playing list shows what is really happening. They then get
/// plays from scrobble only, never "now playing" from it too.
///
/// Watched once from the app root so it lives as long as the app.
final playbackReporterProvider = Provider<PlaybackReporter>((ref) {
  final r = PlaybackReporter(ref);
  ref.onDispose(r.dispose);
  ref.listen(playerProvider, (_, _) => r.onPlayer(), fireImmediately: true);
  ref.listen(positionProvider, (_, next) {
    final p = next.value;
    if (p != null) r.onPosition(p);
  });
  return r;
});

class PlaybackReporter {
  final Ref ref;
  PlaybackReporter(this.ref);

  /// How often the position is repeated while playing.
  static const interval = Duration(seconds: 30);

  /// A position this far from where playback should be is a seek.
  static const _seekJump = Duration(seconds: 3);

  Timer? _ticker;
  bool _playing = false;
  DateTime _lastPositionAt = DateTime.now();

  bool get _reportsState => ref.read(capabilitiesProvider).hasPlaybackState;

  String? _trackId;
  int? _index;
  bool _submitted = false;
  Duration _last = Duration.zero;

  /// Whether "now playing" has been sent for the current entry. It waits
  /// for playback to start, so a queue restored paused at start-up is not
  /// announced.
  bool _announced = false;

  void onPlayer() {
    final s = ref.read(playerProvider);
    final t = s.current;
    final changed = t?.id != _trackId || s.currentIndex != _index;
    if (changed) {
      // The old entry is over, however it ended.
      if (_announced && _trackId != null) _state(PlaybackPhase.stopped);
      _trackId = t?.id;
      _index = s.currentIndex;
      _submitted = false;
      _announced = false;
      _playing = false;
      _last = Duration.zero;
    }
    final playing = t != null && s.playing;
    if (playing && !_announced) {
      _announced = true;
      _playing = true;
      if (_reportsState) {
        _state(PlaybackPhase.starting);
        _state(PlaybackPhase.playing);
      } else {
        _send(t.id, submission: false);
      }
    } else if (_announced && playing != _playing) {
      _playing = playing;
      _state(playing ? PlaybackPhase.playing : PlaybackPhase.paused);
    }
    if (_playing) {
      _ticker ??= Timer.periodic(
        interval,
        (_) => _state(PlaybackPhase.playing),
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Tells the server playback has stopped, such as when the app closes.
  void stop() {
    if (_announced && _trackId != null) _state(PlaybackPhase.stopped);
    _announced = false;
    _playing = false;
    _ticker?.cancel();
    _ticker = null;
  }

  void dispose() => _ticker?.cancel();

  void _state(PlaybackPhase phase) {
    final id = _trackId;
    final source = ref.read(sessionProvider).value?.source;
    if (id == null || source == null || !_reportsState) return;
    unawaited(
      _quietly(
        () => source.reportPlaybackState(id, phase, _last),
        'State report failed',
      ),
    );
  }

  void onPosition(Duration p) {
    final id = _trackId;
    if (id == null) return;
    // A big jump back to the start of the same entry is a repeat-one replay.
    if (_submitted &&
        p < const Duration(seconds: 2) &&
        _last > p * 2 + const Duration(seconds: 5)) {
      _submitted = false;
      if (_reportsState) {
        _state(PlaybackPhase.starting);
        _state(PlaybackPhase.playing);
      } else {
        _send(id, submission: false);
      }
    }
    // Playback should have moved on by about the time since the last
    // position; a bigger difference is a seek, which the server must hear
    // about since it estimates the position from the last report.
    final now = DateTime.now();
    if (_playing && _announced) {
      final expected = _last + now.difference(_lastPositionAt);
      if ((p - expected).abs() > _seekJump) {
        _last = p;
        _lastPositionAt = now;
        _state(PlaybackPhase.playing);
      }
    }
    _lastPositionAt = now;
    _last = p;
    if (_submitted) return;
    final s = ref.read(playerProvider);
    final total = ref.read(durationProvider).value ?? s.current?.duration;
    if (total == null || total == Duration.zero) return;
    var threshold = total ~/ 2;
    if (threshold > const Duration(minutes: 4)) {
      threshold = const Duration(minutes: 4);
    }
    if (p >= threshold) {
      _submitted = true;
      _send(id, submission: true);
    }
  }

  void _send(String trackId, {required bool submission}) {
    final source = ref.read(sessionProvider).value?.source;
    if (source == null) return;
    unawaited(
      _quietly(
        () => source.reportPlayback(trackId, submission: submission),
        'Play report failed',
      ),
    );
  }

  /// Runs a report and logs a failure. Not `catchError`: the source's
  /// future may really carry the server's reply, and a handler that
  /// returns nothing then throws an error of its own.
  static Future<void> _quietly(
    Future<void> Function() report,
    String what,
  ) async {
    try {
      await report();
    } on Object catch (e) {
      debugPrint('$what: $e');
    }
  }
}

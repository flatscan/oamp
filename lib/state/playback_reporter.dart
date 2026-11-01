import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player.dart';
import 'session.dart';

/// Reports listening to the server: "now playing" when a track starts, and
/// a play once it has been heard for half its length or four minutes,
/// whichever comes first (the usual scrobbling rule). This is what keeps the
/// server's play counts and "recently played" lists current.
///
/// Watched once from the app root so it lives as long as the app.
final playbackReporterProvider = Provider<void>((ref) {
  final r = _Reporter(ref);
  ref.listen(playerProvider, (_, _) => r.onPlayer(), fireImmediately: true);
  ref.listen(positionProvider, (_, next) {
    final p = next.value;
    if (p != null) r.onPosition(p);
  });
});

class _Reporter {
  final Ref ref;
  _Reporter(this.ref);

  String? _trackId;
  int? _index;
  bool _submitted = false;
  Duration _last = Duration.zero;

  void onPlayer() {
    final s = ref.read(playerProvider);
    final t = s.current;
    if (t?.id == _trackId && s.currentIndex == _index) return;
    _trackId = t?.id;
    _index = s.currentIndex;
    _submitted = false;
    _last = Duration.zero;
    if (t != null) _send(t.id, submission: false);
  }

  void onPosition(Duration p) {
    final id = _trackId;
    if (id == null) return;
    // A big jump back to the start of the same entry is a repeat-one replay.
    if (_submitted &&
        p < const Duration(seconds: 2) &&
        _last > p * 2 + const Duration(seconds: 5)) {
      _submitted = false;
      _send(id, submission: false);
    }
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
      source
          .reportPlayback(trackId, submission: submission)
          .catchError((Object e) => debugPrint('Play report failed: $e')),
    );
  }
}

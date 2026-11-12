import 'dart:async';

import 'package:flutter/foundation.dart';

/// Logs how app start-up goes, so a start that hangs says where.
///
/// Each awaited start-up step runs through [step]. A slow step is logged
/// with its time, and while any step is still running after [stallAfter]
/// a line naming it is logged every [stallAfter], so the diagnostics log
/// shows which step a stuck start is waiting on.
///
/// Off until [enabled] is set (main() does), so tests that build the same
/// providers leave no timers behind.
class StartupTrace {
  StartupTrace({
    this.enabled = false,
    this.stallAfter = const Duration(seconds: 5),
    this.slowAfter = const Duration(milliseconds: 500),
    void Function(String)? log,
    Duration Function()? clock,
  }) : _log = log ?? ((m) => debugPrint(m)),
       _clock = clock ?? _stopwatchClock();

  bool enabled;
  final Duration stallAfter;
  final Duration slowAfter;
  final void Function(String) _log;

  /// Time since the trace was made.
  final Duration Function() _clock;

  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final _running = <int, (String, Duration)>{};
  int _nextId = 0;
  Timer? _watchdog;

  String get _now => '${(_clock().inMilliseconds / 1000).toStringAsFixed(1)} s';

  /// Logs [message] with the time since start-up began.
  void mark(String message) {
    if (enabled) _log('Startup: $message at $_now');
  }

  /// Runs [run], logging it if it is slow or never finishes.
  Future<T> step<T>(String name, Future<T> Function() run) async {
    if (!enabled) return run();
    final id = _nextId++;
    final started = _clock();
    _running[id] = (name, started);
    _watchdog ??= Timer.periodic(stallAfter, (_) => _reportStalled());
    try {
      return await run();
    } catch (e) {
      _log('Startup: $name failed after ${_since(started)}: $e');
      rethrow;
    } finally {
      _running.remove(id);
      if (_clock() - started >= slowAfter) {
        _log('Startup: $name took ${_since(started)}');
      }
      if (_running.isEmpty) {
        _watchdog?.cancel();
        _watchdog = null;
      }
    }
  }

  void _reportStalled() {
    final now = _clock();
    final stuck = [
      for (final (name, started) in _running.values)
        if (now - started >= stallAfter) '$name (${_since(started)})',
    ];
    if (stuck.isNotEmpty) {
      _log('Startup: still waiting on ${stuck.join(', ')} at $_now');
    }
  }

  String _since(Duration started) =>
      '${(_clock() - started).inMilliseconds} ms';

  /// Steps still running, for tests.
  @visibleForTesting
  List<String> get running => [for (final (n, _) in _running.values) n];
}

/// The app's start-up trace, switched on by main().
final startupTrace = StartupTrace();

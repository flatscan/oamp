import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/startup_trace.dart';

void main() {
  test('a step that never finishes is named until it does', () {
    fakeAsync((async) {
      final lines = <String>[];
      final trace = StartupTrace(
        enabled: true,
        log: lines.add,
        clock: () => async.elapsed,
      );
      final stuck = Completer<void>();
      unawaited(trace.step('saved sign-in', () => stuck.future));
      unawaited(trace.step('quick', () async {}));
      async.elapse(const Duration(seconds: 11));
      expect(trace.running, ['saved sign-in']);
      expect(
        lines.where((l) => l.startsWith('Startup: still waiting on')),
        hasLength(2),
      );
      expect(lines.last, contains('saved sign-in'));

      stuck.complete();
      async.flushMicrotasks();
      expect(lines.last, startsWith('Startup: saved sign-in took'));
      // Nothing left running: the watchdog stops.
      final before = lines.length;
      async.elapse(const Duration(seconds: 20));
      expect(lines, hasLength(before));
    });
  });

  test('quick steps are not logged; failures are', () async {
    final lines = <String>[];
    final trace = StartupTrace(enabled: true, log: lines.add);
    expect(await trace.step('quick', () async => 42), 42);
    expect(lines, isEmpty);
    await expectLater(
      trace.step('broken', () async => throw StateError('nope')),
      throwsStateError,
    );
    expect(lines.single, contains('broken failed'));
  });

  test('off by default, so tests leave no timers', () async {
    final lines = <String>[];
    final trace = StartupTrace(log: lines.add);
    final stuck = Completer<int>();
    final step = trace.step('x', () => stuck.future);
    trace.mark('hello');
    expect(trace.running, isEmpty);
    stuck.complete(1);
    expect(await step, 1);
    expect(lines, isEmpty);
  });
}

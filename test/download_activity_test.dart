import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/download_activity.dart';
import 'package:oamp/state/downloads.dart';
import 'package:oamp/state/session.dart';

class _Recorder implements DownloadActivity {
  final calls = <String>[];

  @override
  Future<void> show({required int done, required int total}) async =>
      calls.add('show $done/$total');

  @override
  Future<void> hide() async => calls.add('hide');
}

class _Fake extends DownloadManager {
  _Fake(this.initial);
  final DownloadsState initial;
  @override
  DownloadsState build() => initial;
  void set(DownloadsState s) => state = s;
}

void main() {
  test('shows progress while fetching and hides after a pause', () {
    fakeAsync((async) {
      final rec = _Recorder();
      final fake = _Fake(const DownloadsState());
      final container = ProviderContainer(
        overrides: [
          downloadActivityProvider.overrideWithValue(rec),
          downloadsProvider.overrideWith(() => fake),
        ],
      );
      container.listen(downloadActivityBridgeProvider, (_, _) {});
      async.flushMicrotasks();
      expect(rec.calls, isEmpty);

      fake.set(const DownloadsState(loaded: true, active: {'a': 0.1}));
      async.flushMicrotasks();
      // No pins, so the counts are zero; the sign still appears.
      expect(rec.calls, ['show 0/0']);

      // The same numbers again do not repeat the call.
      fake.set(const DownloadsState(loaded: true, active: {'a': 0.5}));
      async.flushMicrotasks();
      expect(rec.calls, ['show 0/0']);

      // Between two tracks the sign stays.
      fake.set(const DownloadsState(loaded: true));
      async.elapse(const Duration(seconds: 2));
      expect(rec.calls, ['show 0/0']);

      fake.set(const DownloadsState(loaded: true, active: {'b': 0.0}));
      async.elapse(const Duration(seconds: 5));
      expect(rec.calls, ['show 0/0']);

      fake.set(const DownloadsState(loaded: true));
      async.elapse(const Duration(seconds: 4));
      expect(rec.calls, ['show 0/0', 'hide']);
      container.dispose();
    });
  });
}

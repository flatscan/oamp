import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/state/library.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

void main() {
  test('an album page is kept for a while after it closes, then let go', () {
    fakeAsync((async) {
      final source = FakeMusicSource();
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        ],
      );
      container.read(sessionProvider);
      async.flushMicrotasks();

      var sub = container.listen(albumDetailProvider('al1'), (_, _) {});
      async.flushMicrotasks();
      expect(source.albumFetches, ['al1']);
      sub.close();

      // Back to it a minute later: still there.
      async.elapse(const Duration(minutes: 1));
      sub = container.listen(albumDetailProvider('al1'), (_, _) {});
      async.flushMicrotasks();
      expect(source.albumFetches, ['al1']);
      sub.close();

      // Long after: fetched again.
      async.elapse(libraryCacheTime + const Duration(seconds: 1));
      container.listen(albumDetailProvider('al1'), (_, _) {});
      async.flushMicrotasks();
      expect(source.albumFetches, ['al1', 'al1']);
      container.dispose();
    });
  });
}

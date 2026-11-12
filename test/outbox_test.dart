import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/core/outbox.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/library.dart';
import 'package:oamp/state/outbox.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';

import 'fakes/fakes.dart';

void main() {
  late FakeMusicSource source;
  late MemoryPreferences prefs;
  late ProviderContainer container;

  Future<void> settle([int turns = 20]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> launch() async {
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    container.listen(outboxProvider, (_, _) {});
    await settle();
  }

  setUp(() {
    source = FakeMusicSource();
    prefs = MemoryPreferences();
  });

  OutboxNotifier outbox() => container.read(outboxProvider.notifier);
  List<OutboxEntry> pending() => container.read(outboxProvider);

  final t0 = DateTime.utc(2026, 11, 10, 20, 0);

  test('a play is sent at once, with the time it happened', () async {
    await launch();
    await outbox().play('t1', t0);
    expect(source.calls, contains('played:t1'));
    expect(source.playTimes['t1'], t0);
    expect(pending(), isEmpty);
  });

  test('plays made while the server is out of reach are sent later, in order, '
      'with their own times', () async {
    await launch();
    source.unreachable = true;
    await outbox().play('t1', t0);
    await outbox().play('t2', t0.add(const Duration(minutes: 4)));
    expect(pending().map((e) => e.id), ['t1', 't2']);
    expect(source.playTimes, isEmpty);

    source.unreachable = false;
    await outbox().flush();
    expect(pending(), isEmpty);
    expect(source.calls.where((c) => c.startsWith('played')), [
      'played:t1',
      'played:t2',
    ]);
    expect(source.playTimes['t1'], t0);
    expect(source.playTimes['t2'], t0.add(const Duration(minutes: 4)));
  });

  test('nothing is lost when the server only answers for some', () async {
    await launch();
    source.unreachable = true;
    await outbox().play('t1', t0);
    await outbox().play('t2', t0);
    await outbox().flush();
    expect(pending(), hasLength(2));
  });

  test('a new play waits behind older ones', () async {
    await launch();
    source.unreachable = true;
    await outbox().play('t1', t0);
    source.unreachable = false;
    await outbox().play('t2', t0.add(const Duration(minutes: 5)));
    await settle();
    expect(source.calls.where((c) => c.startsWith('played')), [
      'played:t1',
      'played:t2',
    ]);
    expect(pending(), isEmpty);
  });

  test('the saved list survives a restart and is sent then', () async {
    await launch();
    source.unreachable = true;
    await outbox().play('t1', t0);
    expect(prefs.getStringList('oamp.outbox.${source.serverId}'), hasLength(1));
    container.dispose();

    source.unreachable = false;
    await launch();
    await settle();
    expect(source.calls, contains('played:t1'));
    expect(pending(), isEmpty);
    expect(prefs.getStringList('oamp.outbox.${source.serverId}'), isEmpty);
  });

  test('a like made offline is kept; the last say wins', () async {
    await launch();
    source.unreachable = true;
    await outbox().like('t1', true, LikeTarget.track);
    await outbox().like('t1', false, LikeTarget.track);
    await outbox().like('t1', true, LikeTarget.track);
    await outbox().rate('t1', 4);
    expect(pending(), hasLength(2));

    source.unreachable = false;
    await outbox().flush();
    expect(source.calls, ['like:t1', 'rate:t1:4']);
    expect(pending(), isEmpty);
  });

  test('a like the server refuses for good is reported, not kept', () async {
    await launch();
    source.likesRefused = true;
    await expectLater(
      outbox().like('t1', true, LikeTarget.track),
      throwsA(isA<MusicSourceException>()),
    );
    expect(pending(), isEmpty);
  });

  test('a play the server refuses for good is dropped quietly', () async {
    await launch();
    source.unreachable = true;
    await outbox().play('gone', t0);
    source.unreachable = false;
    source.playsRefused = true;
    await outbox().flush();
    expect(pending(), isEmpty);
    expect(source.calls, isEmpty);
  });

  test('Offline mode keeps reports until it is switched off', () async {
    await launch();
    await container.read(settingsProvider.notifier).setOfflineMode(true);
    await outbox().play('t1', t0);
    expect(pending(), hasLength(1));
    expect(source.calls, isEmpty);

    await container.read(settingsProvider.notifier).setOfflineMode(false);
    await settle();
    expect(source.calls, contains('played:t1'));
    expect(pending(), isEmpty);
  });

  test('likes made through the app go through the outbox', () async {
    await launch();
    source.unreachable = true;
    await container
        .read(likesProvider(LikeTarget.track).notifier)
        .toggle('t1', fetched: false);
    expect(
      container.read(likesProvider(LikeTarget.track))['t1'],
      isTrue,
      reason: 'the heart stays filled',
    );
    expect(pending(), hasLength(1));
  });

  test('playlists can not be changed offline', () async {
    await launch();
    await container.read(settingsProvider.notifier).setOfflineMode(true);
    const p = Playlist(id: 'p1', name: 'Mix', owner: 'tester');
    final actions = container.read(playlistActionsProvider);
    expect(actions.canEdit(p), isFalse);
    await expectLater(
      actions.rename(p, 'New'),
      throwsA(isA<MusicSourceException>()),
    );
    await container.read(settingsProvider.notifier).setOfflineMode(false);
    expect(actions.canEdit(p), isTrue);
  });
}

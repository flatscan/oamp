import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/core/server_route.dart';
import 'package:oamp/platform/secure_store.dart';
import 'package:oamp/sources/subsonic/subsonic_client.dart';
import 'package:oamp/sources/subsonic/subsonic_source.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';
import 'package:oamp/ui/browse/away_address_tile.dart';
import 'package:oamp/ui/login_screen.dart';
import 'package:oamp/ui/server_address_field.dart';

import 'android_gaps_test.dart' show FakeNetwork;
import 'fakes/fakes.dart';

final home = Uri.parse('http://192.168.1.10:4533');
final away = Uri.parse('https://music.example.com');

MusicSourceException unreachable() =>
    MusicSourceException('down', kind: MusicSourceErrorKind.unreachable);

void main() {
  group('AddressPicker', () {
    test('home wins whenever it answers, even if away is faster', () async {
      final p = AddressPicker(home, away: away);
      await p.pick((base, _) async {
        if (base == home) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(p.route, ServerRoute.home);
      expect(p.active, home);
    });

    test('away is used when home does not answer', () async {
      final p = AddressPicker(home, away: away);
      final changes = <ServerRoute>[];
      p.changes.listen(changes.add);
      await p.pick((base, _) async {
        if (base == home) throw unreachable();
      });
      expect(p.active, away);
      expect(changes, [ServerRoute.away]);
      expect(await p.lastAwayAttempt, isNull);

      // Back home: the next check goes home again.
      await p.pick((_, _) async {});
      expect(p.active, home);
      expect(changes, [ServerRoute.away, ServerRoute.home]);
    });

    test('home gets only a short wait when there is an away address', () {
      fakeAsync((async) {
        final p = AddressPicker(home, away: away);
        final waits = <Uri, Duration>{};
        p.pick((base, timeout) async => waits[base] = timeout);
        async.flushMicrotasks();
        expect(waits[home], const Duration(seconds: 4));
        expect(waits[away], const Duration(seconds: 10));

        final single = AddressPicker(home);
        single.pick((base, timeout) async => waits[base] = timeout);
        async.flushMicrotasks();
        expect(waits[home], const Duration(seconds: 20));
      });
    });

    test('neither answering says so in words; a refused login wins', () async {
      final p = AddressPicker(home, away: away);
      await expectLater(
        p.pick((_, _) async => throw unreachable()),
        throwsA(
          isA<MusicSourceException>()
              .having((e) => e.kind, 'kind', MusicSourceErrorKind.unreachable)
              .having((e) => e.message, 'message', contains('home or away')),
        ),
      );
      await expectLater(
        p.pick((base, _) async {
          if (base == home) throw unreachable();
          throw MusicSourceException('no', kind: MusicSourceErrorKind.auth);
        }),
        throwsA(
          isA<MusicSourceException>().having(
            (e) => e.kind,
            'kind',
            MusicSourceErrorKind.auth,
          ),
        ),
      );
    });

    test('recover checks again at most every few seconds', () async {
      var now = DateTime(2026, 11, 7);
      final p = AddressPicker(home, away: away, clock: () => now);
      var probes = 0;
      var homeUp = true;
      Future<void> probe(Uri base, Duration _) async {
        probes++;
        if (base == home && !homeUp) throw unreachable();
      }

      await p.pick(probe);
      expect(probes, 2);
      homeUp = false;
      expect(await p.recover(probe, home), isFalse, reason: 'just checked');
      expect(probes, 2);
      now = now.add(const Duration(seconds: 11));
      expect(await p.recover(probe, home), isTrue);
      expect(p.active, away);
    });

    test('removing the away address goes home', () async {
      final p = AddressPicker(home, away: away);
      await p.pick((base, _) async {
        if (base == home) throw unreachable();
      });
      expect(p.route, ServerRoute.away);
      p.away = null;
      expect(p.route, ServerRoute.home);
      expect(p.active, home);
    });
  });

  group('Subsonic with an away address', () {
    final ok = jsonEncode({
      'subsonic-response': {'status': 'ok', 'version': '1.16.1'},
    });

    SubsonicCredentials creds({Uri? awayUrl}) =>
        SubsonicCredentials.fromPassword(
          baseUrl: home,
          username: 'ed',
          password: 'pw',
        ).withAwayUrl(awayUrl);

    test('the server keeps its identity when an away address is added', () {
      final c = creds();
      final withAway = c.withAwayUrl(away, connected: true);
      expect(withAway.serverId, c.serverId);
      final back = SubsonicCredentials.fromJson(withAway.toJson());
      expect(back.awayUrl, away);
      expect(back.awayConnected, isTrue);
      expect(SubsonicCredentials.fromJson(c.toJson()).awayUrl, isNull);
    });

    test('a request that cannot reach home is sent again to away', () async {
      final hosts = <String>[];
      final source = SubsonicSource(
        creds(awayUrl: away),
        httpClient: MockClient((req) async {
          hosts.add(req.url.host);
          if (req.url.host == home.host) {
            throw http.ClientException('Connection refused');
          }
          return http.Response(ok, 200);
        }),
      );
      addTearDown(source.close);
      final routes = <ServerRoute>[];
      source.routeChanges.listen(routes.add);
      await source.ping();
      expect(source.route, ServerRoute.away);
      expect(routes, [ServerRoute.away]);
      // The stream URL now points away too.
      expect(source.streamUrl('t1').host, away.host);
      expect(hosts.first, home.host);
      expect(hosts.last, away.host);
    });

    test('connect prefers home when both answer', () async {
      final source = SubsonicSource(
        creds(awayUrl: away),
        httpClient: MockClient((_) async => http.Response(ok, 200)),
      );
      addTearDown(source.close);
      await source.connect();
      expect(source.route, ServerRoute.home);
      expect(source.streamUrl('t1').host, home.host);
    });
  });

  group('session', () {
    late SubsonicSource source;
    late MemorySecureStore store;
    var awayUp = true;
    var homeUp = true;

    ProviderContainer start() {
      awayUp = true;
      homeUp = true;
      store = MemorySecureStore();
      source = SubsonicSource(
        SubsonicCredentials.fromPassword(
          baseUrl: home,
          username: 'ed',
          password: 'pw',
        ),
        httpClient: MockClient((req) async {
          if ((req.url.host == away.host && !awayUp) ||
              (req.url.host == home.host && !homeUp)) {
            throw http.ClientException('Connection refused');
          }
          return http.Response(
            jsonEncode({
              'subsonic-response': {'status': 'ok', 'version': '1.16.1'},
            }),
            200,
          );
        }),
      );
      final c = ProviderContainer(
        overrides: [
          secureStoreProvider.overrideWithValue(store),
          sessionProvider.overrideWith(() => _SubsonicSession(source)),
        ],
      );
      addTearDown(c.dispose);
      c.listen(serverStatusProvider, (_, _) {});
      c.listen(serverRouteProvider, (_, _) {});
      c.listen(awayAddressProvider, (_, _) {});
      return c;
    }

    test('saving an away address that answered marks it connected', () async {
      final c = start();
      await c.read(sessionProvider.future);
      final session = c.read(awayAddressProvider.notifier);
      expect(await session.test('music.example.com'), isNull);
      await session.save('music.example.com', connected: true);
      final a = c.read(awayAddressProvider)!;
      expect(a.url, away);
      expect(a.connected, isTrue);
      final saved = jsonDecode(
        (await store.read('oamp.server.${source.serverId}'))!,
      );
      expect(saved['credentials']['awayUrl'], away.toString());
      expect(c.read(sessionProvider).value!.serverId, source.serverId);
    });

    test('an away address saved anyway warns until it connects', () async {
      final c = start();
      await c.read(sessionProvider.future);
      final session = c.read(awayAddressProvider.notifier);
      awayUp = false;
      expect(await session.test('music.example.com'), isNotNull);
      await session.save('music.example.com');
      expect(c.read(awayAddressProvider)!.connected, isFalse);

      // Later, home stops answering and the away address takes over.
      await pumpEventQueue();
      awayUp = true;
      homeUp = false;
      await c.read(serverStatusProvider.notifier).check();
      await pumpEventQueue();
      expect(c.read(serverRouteProvider), ServerRoute.away);
      expect(c.read(awayAddressProvider)!.connected, isTrue);

      await session.save(null);
      expect(c.read(awayAddressProvider), isNull);
      expect(source.route, ServerRoute.home);
    });
  });

  group('server status', () {
    test('while away, looks for home every minute and after a network '
        'change', () {
      fakeAsync((async) {
        final src = FakeMusicSource()..routeOnConnect = ServerRoute.away;
        final net = FakeNetwork();
        final c = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(() => FakeSessionNotifier(src)),
            networkMonitorProvider.overrideWithValue(net),
            awayAddressProvider.overrideWithBuild((_, _) => AwayAddress(away)),
          ],
        );
        c.listen(serverStatusProvider, (_, _) {});
        async.elapse(const Duration(milliseconds: 1));
        expect(src.pings, 1);
        expect(src.route, ServerRoute.away);

        async.elapse(const Duration(seconds: 61));
        expect(src.pings, 2);

        net.hop();
        async.flushMicrotasks();
        expect(src.pings, 3);

        // Home again: no more home checks.
        src.routeOnConnect = ServerRoute.home;
        async.elapse(const Duration(seconds: 61));
        expect(src.route, ServerRoute.home);
        final pings = src.pings;
        async.elapse(const Duration(minutes: 5));
        expect(src.pings, pings);
        c.dispose();
      });
    });

    test('without an away address a network change sends nothing', () {
      fakeAsync((async) {
        final src = FakeMusicSource();
        final net = FakeNetwork();
        final c = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(() => FakeSessionNotifier(src)),
            networkMonitorProvider.overrideWithValue(net),
          ],
        );
        c.listen(serverStatusProvider, (_, _) {});
        async.elapse(const Duration(milliseconds: 1));
        net.hop();
        async.elapse(const Duration(minutes: 5));
        expect(src.pings, 1);
        c.dispose();
      });
    });
  });

  group('address field', () {
    test('keeps the scheme apart and reads it from a pasted address', () {
      final c = ServerAddressController();
      expect(c.secure, isTrue);
      c.text.text = 'http://nas:4533';
      expect(c.secure, isFalse);
      expect(c.text.text, 'nas:4533');
      expect(c.url, 'http://nas:4533');
      c.secure = true;
      expect(c.url, 'https://nas:4533');
      c.set('https://music.example.com');
      expect(c.text.text, 'music.example.com');
      c.dispose();
    });

    test('warns only for plain http on the open internet', () {
      final c = ServerAddressController('http://music.example.com');
      expect(c.unencryptedOverInternet, isTrue);
      for (final private in [
        'http://192.168.1.10:4533',
        'http://10.0.0.2',
        'http://100.101.102.103',
        'http://nas.tail1234.ts.net',
        'http://nas',
        'http://nas.local',
      ]) {
        c.set(private);
        expect(c.unencryptedOverInternet, isFalse, reason: private);
      }
      c.set('https://music.example.com');
      expect(c.unencryptedOverInternet, isFalse);
      c.dispose();
    });

    testWidgets('sign-in starts at https and toggles to http', (t) async {
      await t.pumpWidget(
        const ProviderScope(child: MaterialApp(home: LoginScreen())),
      );
      expect(find.text('https://'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('scheme-toggle')));
      await t.pump();
      expect(find.text('http://'), findsOneWidget);

      expect(find.byKey(const ValueKey('away-address')), findsNothing);
      await t.tap(find.text('Add an away address'));
      await t.pump();
      expect(find.byKey(const ValueKey('away-address')), findsOneWidget);
      expect(find.text('https://'), findsOneWidget, reason: 'away is https');
    });
  });

  group('settings', () {
    Future<void> show(WidgetTester t, AwayAddress? a, ServerRoute r) =>
        t.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              sessionProvider.overrideWith(() => FakeSessionNotifier()),
              awayAddressProvider.overrideWithBuild((_, _) => a),
              serverRouteProvider.overrideWithBuild((_, _) => r),
            ],
            child: const MaterialApp(home: Scaffold(body: AwayAddressTile())),
          ),
        );

    testWidgets('warns until the away address has connected', (t) async {
      await show(t, AwayAddress(away), ServerRoute.home);
      expect(find.textContaining('Not connected yet'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

      await show(t, AwayAddress(away, connected: true), ServerRoute.away);
      expect(find.textContaining('Connected via away'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);

      await show(t, AwayAddress(away, connected: true), ServerRoute.home);
      expect(find.textContaining('Connected via home'), findsOneWidget);

      await show(t, null, ServerRoute.home);
      expect(find.textContaining('Add a second address'), findsOneWidget);
    });
  });
}

class _SubsonicSession extends SessionNotifier {
  _SubsonicSession(this.source);
  final SubsonicSource source;

  @override
  Future<ServerSession?> build() async => ServerSession(source);
}

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/sources/subsonic/subsonic_client.dart';
import 'package:oamp/sources/subsonic/subsonic_source.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

void main() {
  group('Subsonic errors in words', () {
    SubsonicSource source(Future<http.Response> Function() reply) =>
        SubsonicSource(
          SubsonicCredentials.fromPassword(
            baseUrl: Uri.parse('https://music.example.com'),
            username: 'ed',
            password: 'x',
          ),
          httpClient: MockClient((_) => reply()),
        );

    Future<MusicSourceException> failure(SubsonicSource s) async {
      try {
        await s.ping();
      } on MusicSourceException catch (e) {
        return e;
      }
      fail('ping did not throw');
    }

    test('a host that is not there is unreachable, without raw text', () async {
      final e = await failure(
        source(
          () => throw http.ClientException(
            'Failed host lookup: music.example.com',
          ),
        ),
      );
      expect(e.kind, MusicSourceErrorKind.unreachable);
      expect(e.message, 'Could not find music.example.com. Check the address.');
    });

    test('a refused connection is unreachable', () async {
      final e = await failure(
        source(() => throw http.ClientException('Connection refused')),
      );
      expect(e.kind, MusicSourceErrorKind.unreachable);
      expect(e.message, contains('server is running'));
      expect(e.message, isNot(contains('ClientException')));
    });

    test('a timeout says the server did not answer', () async {
      final e = await failure(source(() => throw TimeoutException('t')));
      expect(e.kind, MusicSourceErrorKind.unreachable);
      expect(e.message, contains('did not answer'));
    });

    test('a web page instead of the API is not a server', () async {
      final e = await failure(
        source(() async => http.Response('<html></html>', 200)),
      );
      expect(e.kind, MusicSourceErrorKind.notAServer);
      final e404 = await failure(source(() async => http.Response('', 404)));
      expect(e404.kind, MusicSourceErrorKind.notAServer);
    });

    test('a 500 is a server problem', () async {
      final e = await failure(source(() async => http.Response('', 502)));
      expect(e.kind, MusicSourceErrorKind.server);
    });

    test('code 40 is a sign-in problem', () async {
      final e = await failure(
        source(
          () async => http.Response(
            jsonEncode({
              'subsonic-response': {
                'status': 'failed',
                'error': {'code': 40, 'message': 'Wrong username or password'},
              },
            }),
            200,
          ),
        ),
      );
      expect(e.kind, MusicSourceErrorKind.auth);
      expect(e.toString(), 'Wrong username or password.');
    });
  });

  group('launch check', () {
    late FakeMusicSource src;
    late ProviderContainer container;

    ProviderContainer start() {
      final c = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier(src)),
        ],
      );
      addTearDown(c.dispose);
      c.listen(serverStatusProvider, (_, _) {});
      return c;
    }

    setUp(() => src = FakeMusicSource());

    test('pings on launch and reports ok', () async {
      container = start();
      await container.read(sessionProvider.future);
      expect(
        container.read(serverStatusProvider).health,
        ServerHealth.checking,
      );
      await pumpEventQueue();
      expect(container.read(serverStatusProvider).health, ServerHealth.ok);
      expect(src.pings, 1);
    });

    test('a bad password asks to sign in again', () async {
      src.pingError = MusicSourceException(
        'Wrong username or password.',
        kind: MusicSourceErrorKind.auth,
      );
      container = start();
      await container.read(sessionProvider.future);
      await pumpEventQueue();
      final s = container.read(serverStatusProvider);
      expect(s.health, ServerHealth.signedOut);
      expect(s.message, 'Wrong username or password.');
    });

    test('a server that is down is retried until it answers', () {
      fakeAsync((async) {
        src.pingError = MusicSourceException(
          'Could not reach music.example.com.',
          kind: MusicSourceErrorKind.unreachable,
        );
        container = start();
        container.read(sessionProvider);
        async.elapse(Duration.zero);
        expect(
          container.read(serverStatusProvider).health,
          ServerHealth.unreachable,
        );
        src.pingError = null;
        async.elapse(ServerStatusNotifier.retryEvery);
        expect(container.read(serverStatusProvider).health, ServerHealth.ok);
        expect(src.pings, 2);
        // No more pings once it is back.
        async.elapse(ServerStatusNotifier.retryEvery * 3);
        expect(src.pings, 2);
      });
    });
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/audio/stream_cache.dart';
import 'package:oamp/core/track_cache.dart';

/// The playback cache when the server moves between its home and away
/// addresses part way through a download. Kept apart from widget tests,
/// whose binding fakes every HttpClient.
void main() {
  group('playback cache across a move', () {
    late HttpServer a;
    late HttpServer b;
    late Directory dir;
    late HttpTrackCache cache;
    final body = Uint8List.fromList(List.generate(300000, (j) => j % 253));
    final hits = <String>[];

    Future<HttpServer> serve(String name, {bool dropFirst = false}) async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var first = true;
      s.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        hits.add('$name${range == null ? '' : ' $range'}');
        final res = req.response;
        res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (range != null) {
          final start = int.parse(
            RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!,
          );
          res
            ..statusCode = 206
            ..headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-${body.length - 1}/${body.length}',
            )
            ..headers.contentLength = body.length - start
            ..add(body.sublist(start));
          await res.close();
          return;
        }
        res.headers
          ..contentType = ContentType('audio', 'flac')
          ..contentLength = body.length;
        if (dropFirst && first) {
          first = false;
          // Send part, then lose the connection, as walking out of Wi-Fi
          // range does.
          final socket = await res.detachSocket();
          socket.add(body.sublist(0, 100000));
          await socket.flush();
          socket.destroy();
          return;
        }
        res.add(body);
        await res.close();
      });
      return s;
    }

    setUp(() async {
      hits.clear();
      a = await serve('home', dropFirst: true);
      b = await serve('away');
      dir = await Directory.systemTemp.createTemp('oamp_away_test');
      cache = await HttpTrackCache.open(
        dir,
        retryDelays: const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
        ],
        stallAfter: const Duration(seconds: 2),
      );
    });

    tearDown(() async {
      await cache.dispose();
      await a.close(force: true);
      await b.close(force: true);
      await dir.delete(recursive: true);
    });

    Future<List<int>> get(Uri url) async {
      final c = HttpClient();
      try {
        final res = await (await c.getUrl(url)).close();
        return await res.fold<List<int>>([], (x, y) => x..addAll(y));
      } finally {
        c.close();
      }
    }

    test('a track streaming when the connection drops carries on from the '
        'new address without a break in the bytes', () async {
      var base = 'http://127.0.0.1:${a.port}';
      var reports = 0;
      final req = CacheRequest.lazy(
        'srv|t1|raw',
        () => Uri.parse('$base/t1'),
        onUnreachable: () {
          reports++;
          // The source finds home gone and moves to away.
          base = 'http://127.0.0.1:${b.port}';
        },
      );
      final bytes = await get(cache.urlFor(req));
      expect(bytes, body);
      expect(reports, 1);
      expect(hits, ['home', 'away bytes=100000-']);
      for (var i = 0; i < 100 && !cache.isCached('srv|t1|raw'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.isCached('srv|t1|raw'), isTrue);
    });

    test('pre-caching moves to the new address too', () async {
      var base = 'http://127.0.0.1:${a.port}';
      final req = CacheRequest.lazy(
        'srv|t2|raw',
        () => Uri.parse('$base/t2'),
        onUnreachable: () => base = 'http://127.0.0.1:${b.port}',
      );
      cache.prefetch([req]);
      for (var i = 0; i < 200 && !cache.isCached('srv|t2|raw'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.isCached('srv|t2|raw'), isTrue);
      expect(hits, ['home', 'away bytes=100000-']);
    });
  });
}

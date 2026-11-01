import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/audio/stream_cache.dart';
import 'package:oamp/core/track_cache.dart';

void main() {
  late HttpServer upstream;
  late Directory dir;
  late HttpTrackCache cache;
  final hits = <String>[];
  final bodies = {
    for (var i = 0; i < 4; i++)
      '/t$i': Uint8List.fromList(List.generate(200000, (j) => (i + j) % 251)),
  };

  setUp(() async {
    hits.clear();
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      hits.add('${req.uri.path}${range == null ? '' : ' $range'}');
      final body = bodies[req.uri.path];
      if (body == null) {
        req.response.statusCode = 404;
      } else if (range != null) {
        final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        req.response
          ..statusCode = 206
          ..headers.contentLength = body.length - start
          ..add(body.sublist(start));
      } else {
        req.response
          ..headers.contentType = ContentType('audio', 'flac')
          ..headers.contentLength = body.length
          ..add(body);
      }
      await req.response.close();
    });
    dir = await Directory.systemTemp.createTemp('oamp_cache_test');
    cache = await HttpTrackCache.open(dir);
  });

  tearDown(() async {
    await cache.dispose();
    await upstream.close(force: true);
    await dir.delete(recursive: true);
  });

  CacheRequest req(int i) => CacheRequest(
    'srv|t$i|raw',
    Uri.parse('http://127.0.0.1:${upstream.port}/t$i'),
  );

  Future<(int, List<int>)> get(Uri url, {String? range}) async {
    final c = HttpClient();
    try {
      final r = await c.getUrl(url);
      if (range != null) r.headers.set(HttpHeaders.rangeHeader, range);
      final res = await r.close();
      final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      return (res.statusCode, bytes);
    } finally {
      c.close();
    }
  }

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ok(), isTrue);
  }

  test(
    'a played track is saved on the way through, then served from disk',
    () async {
      final url = cache.urlFor(req(0));
      expect(url.host, '127.0.0.1');
      final (code, bytes) = await get(url);
      expect(code, 200);
      expect(bytes, bodies['/t0']);
      await until(() => cache.isCached('srv|t0|raw'));

      final (code2, part) = await get(url, range: 'bytes=1000-1999');
      expect(code2, 206);
      expect(part, bodies['/t0']!.sublist(1000, 2000));
      expect(hits, ['/t0'], reason: 'second read never reached the server');
      expect((await cache.usage()).files, 1);
    },
  );

  test(
    'a range request for an uncached track passes straight through',
    () async {
      final url = cache.urlFor(req(1));
      final (code, bytes) = await get(url, range: 'bytes=500-');
      expect(code, 206);
      expect(bytes, bodies['/t1']!.sublist(500));
      expect(cache.isCached('srv|t1|raw'), isFalse);
    },
  );

  test('prefetch downloads wanted tracks in order', () async {
    cache.prefetch([req(2), req(3)]);
    await until(
      () => cache.isCached('srv|t2|raw') && cache.isCached('srv|t3|raw'),
    );
    expect(hits, ['/t2', '/t3']);
    final (_, bytes) = await get(cache.urlFor(req(3)));
    expect(bytes, bodies['/t3']);
    expect(hits, hasLength(2));
  });

  test('the size limit evicts the oldest track not wanted next', () async {
    cache.prefetch([req(0), req(1)]);
    await until(() => cache.isCached('srv|t1|raw'));
    // Room for two tracks: fetching two more pushes out the oldest.
    cache.limitBytes = 450000;
    cache.prefetch([req(2)]);
    await until(() => cache.isCached('srv|t2|raw'));
    await until(() => !cache.isCached('srv|t0|raw'));
    expect(cache.isCached('srv|t1|raw'), isTrue);
    expect(cache.isCached('srv|t2|raw'), isTrue);
  });

  test('clear empties the cache, and files survive a restart', () async {
    cache.prefetch([req(0), req(1)]);
    await until(() => cache.isCached('srv|t1|raw'));
    await cache.dispose();
    cache = await HttpTrackCache.open(dir);
    expect(cache.isCached('srv|t0|raw'), isTrue);
    expect((await cache.usage()).bytes, 400000);
    await cache.clear();
    expect((await cache.usage()).files, 0);
  });

  test('only the cache’s own addresses are served', () async {
    final url = cache.urlFor(req(0));
    final wrong = url.replace(pathSegments: ['nope', url.pathSegments.last]);
    final (code, _) = await get(wrong);
    expect(code, 404);
  });
}

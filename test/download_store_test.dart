import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/downloads.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/platform/disk_download_store.dart';

/// The on-disk download store against a real local server. Kept apart from
/// widget tests, whose binding fakes every HttpClient.
void main() {
  late HttpServer server;
  late Directory dir;
  late DiskDownloadStore store;
  final body = Uint8List.fromList(List.generate(300000, (j) => j % 251));
  final hits = <String>[];
  var dropFirst = false;
  var mode = 'audio';

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');

  Future<void> fetch(
    String id, {
    FetchCancel? cancel,
    void Function()? onUnreachable,
    String path = 'song',
    void Function(int, int?)? onProgress,
  }) => store.fetch(
    'srv',
    id,
    upstream: () => url(path),
    extension: 'flac',
    variant: 'raw',
    cancel: cancel ?? FetchCancel(),
    onUnreachable: onUnreachable,
    onProgress: onProgress,
  );

  setUp(() async {
    hits.clear();
    dropFirst = false;
    mode = 'audio';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var first = true;
    server.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      hits.add('${req.uri.path}${range == null ? '' : ' $range'}');
      final res = req.response;
      if (req.uri.path == '/missing') {
        res.statusCode = 404;
        await res.close();
        return;
      }
      if (mode == 'json') {
        res.headers.contentType = ContentType.json;
        res.write('{"subsonic-response":{"status":"failed"}}');
        await res.close();
        return;
      }
      if (range != null) {
        final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        res
          ..statusCode = 206
          ..headers.contentType = ContentType('audio', 'flac')
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
        final socket = await res.detachSocket();
        socket.add(body.sublist(0, 100000));
        await socket.flush();
        socket.destroy();
        return;
      }
      res.add(body);
      await res.close();
    });
    dir = await Directory.systemTemp.createTemp('oamp_downloads_test');
    store = await DiskDownloadStore.open(
      dir,
      retryDelays: const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
      ],
      stallAfter: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  test(
    'a fetched track is on disk, complete and playable from its file',
    () async {
      expect(store.has('srv', 't1'), isFalse);
      await fetch('t1');
      expect(store.has('srv', 't1'), isTrue);
      final file = File.fromUri(store.fileUri('srv', 't1')!);
      expect(file.readAsBytesSync(), body);
      expect(file.path, endsWith('.flac'));
      expect(file.path, isNot(contains('t1')), reason: 'names are hashed');
      expect(await store.usageBytes('srv'), body.length);
      expect(store.has('other', 't1'), isFalse, reason: 'kept per server');
    },
  );

  test('a dropped connection carries on from the byte it reached', () async {
    dropFirst = true;
    var reports = 0;
    await fetch('t1', onUnreachable: () => reports++);
    expect(File.fromUri(store.fileUri('srv', 't1')!).readAsBytesSync(), body);
    expect(reports, 1);
    expect(hits, ['/song', '/song bytes=100000-']);
  });

  test('gives up as unreachable when the server never answers', () async {
    await server.close(force: true);
    var reports = 0;
    await expectLater(
      fetch('t1', onUnreachable: () => reports++),
      throwsA(
        isA<DownloadException>().having(
          (e) => e.kind,
          'kind',
          DownloadFailure.unreachable,
        ),
      ),
    );
    expect(reports, 3);
    expect(store.has('srv', 't1'), isFalse);
  });

  test('a refusal or an error body is a server failure, not audio', () async {
    await expectLater(
      fetch('t1', path: 'missing'),
      throwsA(
        isA<DownloadException>().having(
          (e) => e.kind,
          'kind',
          DownloadFailure.server,
        ),
      ),
    );
    mode = 'json';
    await expectLater(
      fetch('t2'),
      throwsA(
        isA<DownloadException>().having(
          (e) => e.kind,
          'kind',
          DownloadFailure.server,
        ),
      ),
    );
    expect(store.has('srv', 't1'), isFalse);
    expect(store.has('srv', 't2'), isFalse);
  });

  test('cancelling stops the download and leaves no finished file', () async {
    final cancel = FetchCancel();
    await expectLater(
      fetch('t1', cancel: cancel, onProgress: (_, _) => cancel.cancel()),
      throwsA(
        isA<DownloadException>().having(
          (e) => e.kind,
          'kind',
          DownloadFailure.cancelled,
        ),
      ),
    );
    expect(store.has('srv', 't1'), isFalse);
  });

  test('pins are saved, listed in order and removed', () async {
    const t = Track(
      id: 't1',
      title: 'Song',
      artist: 'Air',
      duration: Duration(minutes: 3),
      liked: true,
      rating: 4,
      replayGain: ReplayGain(trackGain: -6.5, trackPeak: 0.9),
      genres: ['Electronic'],
    );
    await store.savePin(
      'srv',
      Pin(
        kind: PinKind.album,
        itemId: 'a1',
        name: 'Moon Safari',
        coverArt: 'al-1',
        tracks: const [t],
        pinnedAt: DateTime.utc(2026, 11, 1),
      ),
    );
    await store.savePin(
      'srv',
      Pin(
        kind: PinKind.playlist,
        itemId: 'p1',
        name: 'Mix',
        tracks: const [],
        pinnedAt: DateTime.utc(2026, 11, 2),
      ),
    );
    final pins = await store.pins('srv');
    expect([for (final p in pins) p.key], ['album:a1', 'playlist:p1']);
    final back = pins.first.tracks.single;
    expect(back.title, 'Song');
    expect(back.duration, const Duration(minutes: 3));
    expect(back.liked, isTrue);
    expect(back.rating, 4);
    expect(back.replayGain!.trackGain, -6.5);
    expect(back.genres, ['Electronic']);
    expect(pins.first.coverArt, 'al-1');
    expect(await store.pins('other'), isEmpty);

    await store.removePin('srv', 'album:a1');
    expect([for (final p in await store.pins('srv')) p.key], ['playlist:p1']);
  });

  test(
    'files survive a restart, and retain removes what no pin needs',
    () async {
      await fetch('t1');
      await fetch('t2');
      final reopened = await DiskDownloadStore.open(dir);
      expect(reopened.has('srv', 't1'), isTrue);
      expect(reopened.has('srv', 't2'), isTrue);

      await reopened.retain('srv', {'t1'});
      expect(reopened.has('srv', 't1'), isTrue);
      expect(reopened.has('srv', 't2'), isFalse);
      expect((await DiskDownloadStore.open(dir)).has('srv', 't2'), isFalse);
    },
  );

  test('retain leaves files alone when a pin could not be read', () async {
    await fetch('t1');
    final pins = Directory(
      '${dir.path}${Platform.pathSeparator}${DiskDownloadStore.hash('srv')}'
      '${Platform.pathSeparator}pins',
    )..createSync(recursive: true);
    File('${pins.path}${Platform.pathSeparator}broken.json')
        .writeAsStringSync('{ not json');
    expect(await store.pins('srv'), isEmpty);
    await store.retain('srv', {});
    expect(store.has('srv', 't1'), isTrue);
  });

  test('many tracks go in one call, files and half-finished parts', () async {
    await fetch('t1');
    await fetch('t2');
    await fetch('t3');
    final usage = await store.usageBytes('srv');
    expect(usage, body.length * 3);
    final part = File(
      '${dir.path}/${DiskDownloadStore.hash('srv')}/tracks/'
      '${DiskDownloadStore.hash('t4')}.raw.part',
    );
    await part.writeAsBytes([1, 2, 3]);
    await store.removeTracks('srv', ['t1', 't2', 't4']);
    expect(store.has('srv', 't1'), isFalse);
    expect(store.has('srv', 't2'), isFalse);
    expect(store.has('srv', 't3'), isTrue);
    expect(await part.exists(), isFalse);
    expect(await store.usageBytes('srv'), body.length);
  });

  test('removing a track or a whole server deletes the files', () async {
    await fetch('t1');
    await fetch('t2');
    await store.removeTrack('srv', 't1');
    expect(store.has('srv', 't1'), isFalse);
    expect(store.has('srv', 't2'), isTrue);
    await store.removeServer('srv');
    expect(store.has('srv', 't2'), isFalse);
    expect(await store.usageBytes('srv'), 0);
  });
}

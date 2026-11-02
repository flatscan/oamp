import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oamp/audio/audio_engine.dart';
import 'package:oamp/audio/mpv_deck.dart';
import 'package:oamp/audio/stream_cache.dart';
import 'package:oamp/core/track_cache.dart';

/// Plays real audio through libmpv with a null output. Runs where libmpv is
/// installed (`apt install libmpv-dev`), and is skipped elsewhere, such as
/// on CI. Exercises the same code the Windows build uses.
void main() {
  final hasMpv =
      Platform.isLinux &&
      [
        '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
        '/usr/lib/libmpv.so.2',
      ].any((p) => File(p).existsSync());

  late Directory dir;
  late List<Uri> files;

  /// A sine tone as a 16-bit stereo WAV.
  Uint8List wav(double freq, Duration length) {
    const rate = 44100;
    final frames = rate * length.inMilliseconds ~/ 1000;
    final data = ByteData(44 + frames * 4);
    void str(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + frames * 4, Endian.little);
    str(8, 'WAVEfmt ');
    data
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 2, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 4, Endian.little)
      ..setUint16(32, 4, Endian.little)
      ..setUint16(34, 16, Endian.little);
    str(36, 'data');
    data.setUint32(40, frames * 4, Endian.little);
    for (var i = 0; i < frames; i++) {
      final v = (sin(2 * pi * freq * i / rate) * 8000).round();
      data
        ..setInt16(44 + i * 4, v, Endian.little)
        ..setInt16(46 + i * 4, v, Endian.little);
    }
    return data.buffer.asUint8List();
  }

  setUpAll(() async {
    if (!hasMpv) return;
    MediaKit.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('oamp_mpv_test');
    files = [];
    for (var i = 0; i < 3; i++) {
      final f = File('${dir.path}/t$i.wav');
      await f.writeAsBytes(wav(220.0 * (i + 1), const Duration(seconds: 5)));
      files.add(f.uri);
    }
  });

  tearDownAll(() async {
    if (hasMpv) await dir.delete(recursive: true);
  });

  MpvDeck deck() => MpvDeck(mpvOptions: const {'ao': 'null'});

  Future<void> waitFor(bool Function() ok, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (!ok() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test(
    'gapless queue plays through and finishes',
    () async {
      final engine = MixingEngine(deck);
      final states = <EngineState>[];
      engine.stateStream.listen(states.add);
      await engine.setQueue(files.sublist(0, 2));
      await engine.play();
      await waitFor(
        () => states.any((s) => s.completed),
        const Duration(seconds: 15),
      );
      expect(states.map((s) => s.currentIndex).toSet(), containsAll([0, 1]));
      expect(states.last.completed, isTrue);
      await engine.dispose();
    },
    skip: !hasMpv,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'queue edits land in the right place',
    () async {
      final d = deck();
      await d.setQueue([files[0]]);
      await d.addAll([files[2]]);
      await d.insertAll(1, [files[1]]);
      await d.move(0, 2);
      await d.seek(Duration.zero, index: 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(d.currentIndex, 2);
      expect(d.playing, isFalse, reason: 'moving while paused stays paused');
      await d.dispose();
    },
    skip: !hasMpv,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'crossfade hands over to a second player through the cache',
    () async {
      final cacheDir = Directory('${dir.path}/cache');
      final cache = await HttpTrackCache.open(cacheDir);
      // Serve the files over HTTP as a server would.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final f = File('${dir.path}${req.uri.path}');
        req.response.headers.contentLength = await f.length();
        await req.response.addStream(f.openRead());
        await req.response.close();
      });
      final urls = [
        for (var i = 0; i < 3; i++)
          cache.urlFor(
            CacheRequest(
              'k$i',
              Uri.parse('http://127.0.0.1:${server.port}/t$i.wav'),
            ),
          ),
      ];
      final made = <MpvDeck>[];
      final engine = MixingEngine(() {
        final d = deck();
        made.add(d);
        return d;
      });
      await engine.setCrossfade(const Duration(seconds: 2));
      final states = <EngineState>[];
      engine.stateStream.listen(states.add);
      await engine.setQueue(urls);
      await engine.play();
      await waitFor(() => engine.isFading, const Duration(seconds: 10));
      expect(engine.isFading, isTrue);
      expect(made, hasLength(2));
      expect(made[1].playing, isTrue);
      await waitFor(() => !engine.isFading, const Duration(seconds: 5));
      expect(states.last.currentIndex, 1);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(made[0].playing, isFalse);
      // The old player is silent, already loaded at the track after next for
      // the following crossfade.
      expect(made[0].currentIndex, 2);
      expect(cache.isCached('k0'), isTrue, reason: 'played track was cached');
      await engine.dispose();
      await cache.dispose();
      await server.close(force: true);
    },
    skip: !hasMpv,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/audio/audio_engine.dart';
import 'package:oamp/audio/output_switcher.dart';
import 'package:oamp/audio/remote_engine.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/output_device.dart';
import 'package:oamp/core/remote_player.dart';

import 'fakes/fake_remote_player.dart';
import 'fakes/fakes.dart';

RemoteMedia _m(int i) => RemoteMedia(
  url: Uri.parse('http://server/stream/$i'),
  contentType: 'audio/flac',
  title: 'Track $i',
);

class _Info implements QueueInfo {
  @override
  double gainAt(int index) => 1;
  @override
  bool crossfadeBetween(int from, int to) => false;
  @override
  Duration? durationAt(int index) => const Duration(minutes: 3);
  @override
  double get boostHeadroom => 1;

  /// Originals with an MP3 to fall back on, when [withFallback].
  bool withFallback = false;

  @override
  RemoteMedia? remoteMediaAt(int index, OutputProtocol protocol) {
    if (index < 0) return null;
    if (!withFallback) return _m(index);
    return RemoteMedia(
      url: _m(index).url,
      contentType: 'audio/flac',
      title: 'Track $index',
      fallback: _mp3(index),
    );
  }
}

RemoteMedia _mp3(int i) => RemoteMedia(
  url: Uri.parse('http://server/stream/$i?format=mp3'),
  contentType: 'audio/mpeg',
  title: 'Track $i',
  transcoded: true,
);

List<Uri> _uris(int n) => [for (var i = 0; i < n; i++) Uri.parse('file:/$i')];

void main() {
  late FakeRemotePlayer device;
  late RemoteEngine engine;
  final states = <EngineState>[];

  setUp(() {
    device = FakeRemotePlayer();
    engine = RemoteEngine(device)..queueInfo = _Info();
    states.clear();
    engine.stateStream.listen(states.add);
  });

  tearDown(() => engine.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('RemoteEngine', () {
    test('loads the current track with the next one lined up', () async {
      await engine.setQueue(
        _uris(4),
        initialIndex: 1,
        initialPosition: const Duration(seconds: 30),
      );
      expect(device.current, _m(1));
      expect(device.next, _m(2));
      expect(device.loadedAt, const Duration(seconds: 30));
      expect(device.playing, isFalse);
      await engine.play();
      expect(device.playing, isTrue);
    });

    test('lines up the next track when the device moves on', () async {
      await engine.setQueue(_uris(3));
      await engine.play();
      device.moveOn();
      await settle();
      expect(states.last.currentIndex, 1);
      expect(device.current, _m(1));
      expect(device.next, _m(2));
      device.moveOn();
      await settle();
      expect(states.last.currentIndex, 2);
      expect(device.next, isNull);
    });

    test('repeat queue wraps the next track to the start', () async {
      await engine.setQueue(_uris(2), initialIndex: 1);
      expect(device.next, isNull);
      await engine.setRepeatMode(PlaybackRepeat.all);
      expect(device.next, _m(0));
      await engine.setRepeatMode(PlaybackRepeat.one);
      expect(device.next, _m(1));
    });

    test('queue edits keep the device in step', () async {
      await engine.setQueue(_uris(3));
      // Inserting right after the current track changes what is next.
      await engine.insertAll(1, [Uri.parse('file:/new')]);
      expect(device.next, _m(1));
      // Removing the next track lines up the one after it.
      await engine.removeAt(1);
      expect(device.next, _m(1));
      // Moving the current track keeps it playing at its new place.
      final loads = device.loads;
      await engine.move(0, 2);
      expect(device.loads, loads);
      expect(device.next, isNull);
      await engine.removeAt(0);
      expect(device.next, isNull);
      expect(device.current, _m(0), reason: 'still the same track');
    });

    test('removing the current track plays the one after it', () async {
      await engine.setQueue(_uris(3), initialIndex: 1);
      await engine.removeAt(1);
      expect(device.current, _m(1));
      expect(device.next, isNull);
    });

    test('next, previous and seeking to another track load it', () async {
      await engine.setQueue(_uris(3));
      await engine.next();
      expect(device.current, _m(1));
      await engine.previous();
      expect(device.current, _m(0));
      await engine.seek(const Duration(seconds: 5), index: 2);
      expect(device.current, _m(2));
      expect(device.loadedAt, const Duration(seconds: 5));
      await engine.seek(const Duration(seconds: 9));
      expect(device.loadedAt, const Duration(seconds: 9));
    });

    test('reports the end of the queue, and play starts over', () async {
      await engine.setQueue(_uris(2), initialIndex: 1);
      await engine.play();
      device.report(const RemoteStatus(ended: true));
      await settle();
      expect(states.last.completed, isTrue);
      expect(states.last.playing, isFalse);
      await engine.play();
      expect(device.current, _m(0));
      expect(device.playing, isTrue);
    });

    test('passes status through as position and duration', () async {
      final positions = <Duration>[];
      engine.positionStream.listen(positions.add);
      await engine.setQueue(_uris(1));
      device.report(
        const RemoteStatus(
          state: RemoteState.playing,
          position: Duration(seconds: 12),
          volume: 0.4,
        ),
      );
      await settle();
      expect(positions.last, const Duration(seconds: 12));
      expect(engine.position, const Duration(seconds: 12));
      expect(engine.deviceVolume, 0.4);
      expect(states.last.playing, isTrue);
    });

    test('stays playing while the device changes track', () async {
      await engine.setQueue(_uris(2));
      await engine.play();
      for (final s in [
        RemoteState.playing,
        RemoteState.idle,
        RemoteState.buffering,
        RemoteState.playing,
      ]) {
        device.report(RemoteStatus(state: s));
        await settle();
        expect(states.last.playing, isTrue, reason: '$s');
      }
    });

    test('follows pause and play from the device itself', () async {
      await engine.setQueue(_uris(2));
      await engine.play();
      device.report(const RemoteStatus(state: RemoteState.playing));
      await settle();
      device.report(const RemoteStatus(state: RemoteState.paused));
      await settle();
      expect(states.last.playing, isFalse);
      device.report(const RemoteStatus(state: RemoteState.idle));
      await settle();
      expect(states.last.playing, isFalse);
      device.report(const RemoteStatus(state: RemoteState.playing));
      await settle();
      expect(states.last.playing, isTrue);
    });

    test('a refused file is sent again as MP3, and so is the rest', () async {
      final info = _Info()..withFallback = true;
      engine.queueInfo = info;
      device.refuses = (m) => !m.transcoded;
      await engine.setQueue(
        _uris(3),
        initialPosition: const Duration(seconds: 9),
      );
      expect(device.current, _mp3(0));
      expect(device.loadedAt, const Duration(seconds: 9));
      expect(device.next, _mp3(1));
      await engine.next();
      expect(device.current, _mp3(1));
    });

    test(
      'a track the device moved on to and refused is retried as MP3',
      () async {
        final info = _Info()..withFallback = true;
        engine.queueInfo = info;
        await engine.setQueue(_uris(3));
        await engine.play();
        device.moveOn();
        await settle();
        device.report(const RemoteStatus(failed: true));
        await settle();
        expect(device.current, _mp3(1));
        expect(device.playing, isTrue);
        expect(device.next, _mp3(2));
      },
    );

    test('a refusal with nothing to fall back on pauses, uncaught', () async {
      await engine.setQueue(_uris(3));
      await engine.play();
      device.refuses = (_) => true;
      await engine.next();
      await settle();
      expect(states.last.playing, isFalse);
    });

    test('clear stops the device', () async {
      await engine.setQueue(_uris(2));
      await engine.clear();
      expect(device.stopped, isTrue);
      expect(states.last.currentIndex, isNull);
    });
  });

  group('OutputSwitcher', () {
    late FakeAudioEngine local;
    late OutputSwitcher switcher;

    setUp(() {
      local = FakeAudioEngine();
      switcher = OutputSwitcher(local)..queueInfo = _Info();
    });

    tearDown(() => switcher.dispose());

    test('moves playback to the device at the same track and spot', () async {
      await switcher.setQueue(_uris(3), initialIndex: 1);
      await switcher.play();
      await settle();
      local.currentPosition = const Duration(seconds: 42);

      await switcher.switchTo(engine);
      expect(switcher.isRemote, isTrue);
      expect(local.queue, isEmpty, reason: 'local playback released');
      expect(device.current, _m(1));
      expect(device.loadedAt, const Duration(seconds: 42));
      expect(device.playing, isTrue);
    });

    test('queue edits while casting reach the device, and come back', () async {
      await switcher.setQueue(_uris(2));
      await settle();
      await switcher.switchTo(engine);
      await switcher.addAll([Uri.parse('file:/2')]);
      await switcher.next();
      await settle();
      expect(device.current, _m(1));
      expect(device.next, _m(2));

      device.report(
        const RemoteStatus(
          state: RemoteState.paused,
          position: Duration(seconds: 7),
        ),
      );
      await settle();
      await switcher.switchTo(null, play: false);
      expect(switcher.isRemote, isFalse);
      expect(device.playing, isFalse, reason: 'device paused');
      expect(local.queue, hasLength(3));
      expect(local.index, 1);
      expect(local.startPosition, const Duration(seconds: 7));
      expect(local.playing, isFalse);
    });

    test('this device keeps its own volume while casting', () async {
      await switcher.setVolume(0.8);
      await switcher.setQueue(_uris(1));
      await settle();
      await switcher.switchTo(engine);
      await switcher.setVolume(0.3);
      expect(device.volume, isNull, reason: 'the device is set separately');
      expect(local.volume, 0.8);
      await switcher.switchTo(null);
      expect(local.volume, 0.3);
    });

    test('streams follow the active output', () async {
      final seen = <int?>[];
      switcher.stateStream.listen((s) => seen.add(s.currentIndex));
      await switcher.setQueue(_uris(3));
      await settle();
      await switcher.switchTo(engine);
      device.moveOn();
      await settle();
      expect(seen.last, 1);
      expect(switcher.lastState.currentIndex, 1);
    });
  });
}

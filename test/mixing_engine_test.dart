import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/audio/audio_engine.dart';
import 'package:oamp/core/equalizer.dart';
import 'package:oamp/core/output_device.dart';
import 'package:oamp/core/remote_player.dart';
import 'package:oamp/core/models.dart';

/// A deck whose position the test moves by hand.
class FakeDeck implements AudioDeck {
  final String name;
  FakeDeck(this.name);

  final _state = StreamController<EngineState>.broadcast(sync: true);
  final _pos = StreamController<Duration>.broadcast(sync: true);
  final _dur = StreamController<Duration?>.broadcast(sync: true);
  final _errors = StreamController<Object>.broadcast(sync: true);
  List<Uri> queue = [];

  /// While set, loading a queue fails, as it does with the network down.
  bool offline = false;

  /// Pretends the stream dropped: the deck stops and reports it.
  void fail() {
    playing = false;
    _emit();
    _errors.add('network');
  }

  int? index;
  @override
  bool playing = false;
  double volume = 1;
  bool gapless = true;
  PlaybackRepeat repeat = PlaybackRepeat.off;
  Duration _p = Duration.zero;
  @override
  Duration? duration = const Duration(seconds: 60);
  final log = <String>[];

  void at(Duration p) {
    _p = p;
    _pos.add(p);
  }

  void _emit() =>
      _state.add(EngineState(playing: playing, currentIndex: index));

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Object> get errors => _errors.stream;
  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration?> get durationStream => _dur.stream;
  @override
  Duration get position => _p;
  @override
  int? get currentIndex => index;
  @override
  double maxVolume = 2;

  @override
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    log.add('setQueue@$initialIndex');
    if (offline) {
      _errors.add('offline');
      throw Exception('offline');
    }
    queue = List.of(uris);
    index = initialIndex;
    _p = initialPosition;
    _emit();
  }

  @override
  Future<void> addAll(List<Uri> uris) async => queue.addAll(uris);
  @override
  Future<void> insertAll(int i, List<Uri> uris) async =>
      queue.insertAll(i, uris);
  @override
  Future<void> removeAt(int i) async => queue.removeAt(i);
  @override
  Future<void> move(int from, int to) async =>
      queue.insert(to, queue.removeAt(from));
  @override
  Future<void> clear() async {
    log.add('clear');
    queue.clear();
    index = null;
    playing = false;
    _emit();
  }

  @override
  Future<void> play() async {
    log.add('play');
    playing = true;
    _emit();
  }

  @override
  Future<void> pause() async {
    log.add('pause');
    playing = false;
    _emit();
  }

  @override
  Future<void> seek(Duration p, {int? index}) async {
    if (index != null) this.index = index;
    _p = p;
    _emit();
  }

  @override
  Future<void> next() async {
    index = index! + 1;
    _emit();
  }

  @override
  Future<void> previous() async {
    index = index! - 1;
    _emit();
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeat mode) async => repeat = mode;
  @override
  Future<void> setVolume(double v) async => volume = v;
  @override
  Future<void> setGapless(bool enabled) async => gapless = enabled;
  EqPreset equalizer = EqPreset.off;
  @override
  bool hasEqualizer = true;
  @override
  Future<void> setEqualizer(EqPreset p) async => equalizer = p;
  @override
  Future<void> dispose() async {}
}

class Info implements QueueInfo {
  Map<int, double> gains = {};
  bool Function(int, int) fade = (_, _) => true;
  @override
  double gainAt(int index) => gains[index] ?? 1;
  @override
  bool crossfadeBetween(int from, int to) => fade(from, to);
  @override
  Duration? durationAt(int index) => const Duration(seconds: 60);
  double headroom = 1;
  @override
  double get boostHeadroom => headroom;
  @override
  RemoteMedia? remoteMediaAt(int index, OutputProtocol protocol) => null;
}

void main() {
  late List<FakeDeck> decks;
  late MixingEngine engine;
  late Info info;
  // What new decks can output; Android's player can't go above 1.
  var deckMax = 2.0;
  final uris = [for (var i = 0; i < 4; i++) Uri.parse('t://$i')];

  // Called again inside fakeAsync by tests that need the engine's own
  // timers and listeners to run on fake time.
  void build() {
    decks = [];
    deckMax = 2;
    info = Info();
    engine = MixingEngine(() {
      final d = FakeDeck('deck${decks.length}')..maxVolume = deckMax;
      decks.add(d);
      return d;
    })..queueInfo = info;
  }

  setUp(build);

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'without crossfade one deck plays and ReplayGain sets its level',
    () async {
      info.gains = {0: 0.5, 1: 1.5};
      await engine.setVolume(0.8);
      await engine.setQueue(uris);
      await engine.play();
      expect(decks, hasLength(1));
      expect(decks[0].volume, closeTo(0.4, 1e-9));
      decks[0].at(const Duration(seconds: 59));
      await settle();
      expect(decks, hasLength(1), reason: 'no spare deck when not fading');
      // A gapless move to the next track picks up that track's gain.
      await decks[0].next();
      await settle();
      expect(decks[0].volume, closeTo(1.2, 1e-9));
    },
  );

  test('gain is capped at what the deck can output', () async {
    info.gains = {0: 4};
    await engine.setQueue(uris);
    expect(decks[0].volume, 2);
  });

  test('a deck that cannot boost lowers every track by the headroom', () async {
    deckMax = 1;
    for (final d in decks) {
      d.maxVolume = 1;
    }
    info.headroom = 2;
    info.gains = {0: 2, 1: 0.5};
    await engine.setQueue(uris);
    // The loudest boost lands at full volume, the rest keep their ratio.
    expect(decks[0].volume, closeTo(1, 1e-9));
    await decks[0].next();
    await settle();
    expect(decks[0].volume, closeTo(0.25, 1e-9));
  });

  test('a deck that can boost ignores the headroom', () async {
    info.headroom = 2;
    info.gains = {0: 1.5};
    await engine.setQueue(uris);
    expect(decks[0].volume, closeTo(1.5, 1e-9));
  });

  test('crossfade loads the next track on the spare deck and swaps', () async {
    await engine.setCrossfade(const Duration(seconds: 6));
    await engine.setQueue(uris, initialIndex: 1);
    await engine.play();
    final a = decks[0];
    final states = <EngineState>[];
    engine.stateStream.listen(states.add);

    a.at(const Duration(seconds: 40));
    await settle();
    expect(decks, hasLength(1));

    // Inside the prepare window the spare deck loads, silent and paused.
    a.at(const Duration(seconds: 50));
    await settle();
    expect(decks, hasLength(2));
    final b = decks[1];
    expect(b.index, 2);
    expect(b.queue, uris);
    expect(b.playing, isFalse);
    expect(b.volume, 0);

    a.at(const Duration(seconds: 55));
    await settle();
    expect(engine.isFading, isTrue);
    expect(b.playing, isTrue);
    expect(states.last.currentIndex, 2, reason: 'now playing moves on');

    // Equal power: half way through both decks are at about 0.71.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(b.volume, inInclusiveRange(0.55, 0.85));
    expect(a.volume, inInclusiveRange(0.55, 0.85));

    await Future<void>.delayed(const Duration(milliseconds: 3000));
    await settle();
    expect(engine.isFading, isFalse);
    expect(b.volume, 1);
    expect(a.log.last, 'clear', reason: 'outgoing deck lets go of its file');

    // Positions now come from the new deck.
    final seen = <Duration>[];
    engine.positionStream.listen(seen.add);
    b.at(const Duration(seconds: 3));
    await settle();
    expect(seen, [const Duration(seconds: 3)]);
  });

  test('pausing mid-fade cuts straight to the incoming track', () async {
    await engine.setCrossfade(const Duration(seconds: 6));
    await engine.setQueue(uris);
    await engine.play();
    decks[0].at(const Duration(seconds: 56));
    await settle();
    expect(engine.isFading, isTrue);
    await engine.pause();
    expect(engine.isFading, isFalse);
    final b = decks[1];
    expect(b.playing, isFalse);
    expect(b.volume, 1);
    expect(decks[0].log.last, 'clear');
  });

  test('no crossfade where the player says not to, or at the end', () async {
    info.fade = (from, to) => from != 0;
    await engine.setCrossfade(const Duration(seconds: 6));
    await engine.setQueue(uris);
    await engine.play();
    decks[0].at(const Duration(seconds: 57));
    await settle();
    expect(engine.isFading, isFalse);

    await engine.seek(Duration.zero, index: 3);
    decks[0].at(const Duration(seconds: 57));
    await settle();
    expect(engine.isFading, isFalse, reason: 'last track, repeat off');

    await engine.setRepeatMode(PlaybackRepeat.all);
    decks[0].at(const Duration(seconds: 57));
    await settle();
    expect(engine.isFading, isTrue);
    expect(decks[1].index, 0, reason: 'repeat queue wraps to the start');
  });

  test('a queue edit while preparing reloads the spare deck', () async {
    await engine.setCrossfade(const Duration(seconds: 6));
    await engine.setQueue(uris);
    await engine.play();
    decks[0].at(const Duration(seconds: 50));
    await settle();
    final extra = Uri.parse('t://new');
    await engine.insertAll(1, [extra]);
    decks[0].at(const Duration(seconds: 56));
    await settle();
    expect(engine.isFading, isTrue);
    expect(decks[1].queue[1], extra);
    expect(decks[1].index, 1);
  });

  test('the library length stands in when the stream has none', () async {
    await engine.setCrossfade(const Duration(seconds: 6));
    await engine.setQueue(uris);
    await engine.play();
    decks[0].duration = null;
    decks[0].at(const Duration(seconds: 56));
    await settle();
    expect(engine.isFading, isTrue);
  });

  test('removing the last remaining entry clears the engine', () async {
    final states = <EngineState>[];
    engine.stateStream.listen(states.add);
    await engine.setQueue([uris.first]);
    await engine.play();
    await settle();
    expect(states.last.currentIndex, 0);
    expect(states.last.playing, isTrue);

    await engine.removeAt(0);
    await settle();
    expect(decks[0].queue, isEmpty);
    expect(decks[0].index, isNull);
    expect(decks[0].playing, isFalse);
    expect(states.last.currentIndex, isNull);
    expect(states.last.playing, isFalse);
  });

  test('settings reach the decks', () async {
    await engine.setGapless(false);
    expect(decks[0].gapless, isFalse);
    await engine.setCrossfade(const Duration(seconds: 6));
    await engine.setQueue(uris);
    await engine.play();
    decks[0].at(const Duration(seconds: 50));
    await settle();
    expect(decks[1].gapless, isFalse);
  });

  group('equaliser', () {
    test('reaches both decks and makes room for its boost', () async {
      info.gains = {0: 1};
      await engine.setVolume(0.8);
      await engine.setQueue(uris);
      await engine.setEqualizer(EqPreset.moreBass);
      expect(decks[0].equalizer, EqPreset.moreBass);
      expect(decks[0].volume, closeTo(0.8 / EqPreset.moreBass.headroom, 1e-9));

      // The crossfade deck picks the preset up when it is made.
      await engine.setCrossfade(const Duration(seconds: 6));
      await engine.play();
      decks[0].at(const Duration(seconds: 50));
      await settle();
      expect(decks[1].equalizer, EqPreset.moreBass);

      await engine.setEqualizer(EqPreset.off);
      expect(decks[0].equalizer, EqPreset.off);
      expect(decks[1].equalizer, EqPreset.off);
    });

    test('a preset that only cuts keeps the level', () async {
      info.gains = {0: 1};
      await engine.setQueue(uris);
      await engine.setEqualizer(EqPreset.lessBass);
      expect(decks[0].volume, closeTo(1, 1e-9));
    });

    test('a deck without an equaliser is not turned down', () async {
      decks[0].hasEqualizer = false;
      info.gains = {0: 1};
      await engine.setQueue(uris);
      await engine.setEqualizer(EqPreset.moreBass);
      expect(decks[0].volume, closeTo(1, 1e-9));
    });
  });

  group('ducking', () {
    test('turns the level down and back up', () async {
      info.gains = {0: 0.5};
      await engine.setQueue(uris);
      await engine.setDucked(true);
      expect(decks[0].volume, closeTo(0.5 * MixingEngine.duckLevel, 1e-9));
      await engine.setDucked(false);
      expect(decks[0].volume, closeTo(0.5, 1e-9));
    });
  });

  group('a dropped stream', () {
    late List<EngineState> states;
    late List<Duration> positions;

    void start(FakeAsync async, {int index = 1}) {
      states = [];
      positions = [];
      engine.stateStream.listen(states.add);
      engine.positionStream.listen(positions.add);
      engine.setQueue(uris, initialIndex: index);
      engine.play();
      async.flushMicrotasks();
      decks[0].at(const Duration(seconds: 25));
      async.flushMicrotasks();
    }

    test('reopens where it stopped and keeps playing', () {
      fakeAsync((async) {
        build();
        start(async);
        final deck = decks[0]..log.clear();
        deck.fail();
        async.flushMicrotasks();
        expect(engine.isRecovering, isTrue);
        expect(states.last.playing, isTrue, reason: 'still meant to play');
        expect(states.last.buffering, isTrue);
        expect(states.last.currentIndex, 1);
        expect(engine.position, const Duration(seconds: 25));

        async.elapse(MixingEngine.retryDelays.first);
        expect(deck.log, ['setQueue@1', 'play']);
        expect(deck.position, const Duration(seconds: 25));
        expect(deck.queue, uris, reason: 'the queue is kept');
        expect(engine.isRecovering, isFalse);
        expect(states.last.playing, isTrue);
        expect(states.last.buffering, isFalse);
      });
    });

    test('waits longer each time, then pauses where it stopped', () {
      fakeAsync((async) {
        build();
        start(async);
        final deck = decks[0]..offline = true;
        deck.fail();
        async.flushMicrotasks();
        deck.log.clear();
        async.elapse(const Duration(seconds: 3));
        expect(deck.log, ['setQueue@1', 'setQueue@1'], reason: 'at 1s, 3s');
        async.elapse(const Duration(minutes: 2));
        expect(deck.log.length, MixingEngine.retryDelays.length);
        expect(states.last.playing, isFalse);
        expect(states.last.buffering, isFalse);
        expect(states.last.currentIndex, 1);
        expect(engine.position, const Duration(seconds: 25));

        // Back online, play tries again at once.
        deck.offline = false;
        deck.log.clear();
        engine.play();
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        expect(deck.log, ['setQueue@1', 'play']);
        expect(deck.position, const Duration(seconds: 25));
        expect(engine.isRecovering, isFalse);
      });
    });

    test('a second drop soon after keeps the longer waits', () {
      fakeAsync((async) {
        build();
        start(async);
        final deck = decks[0];
        deck.fail();
        async.elapse(const Duration(seconds: 1));
        expect(engine.isRecovering, isFalse);
        deck
          ..log.clear()
          ..fail();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        expect(deck.log, isEmpty, reason: 'the next wait is 2s');
        async.elapse(const Duration(seconds: 1));
        expect(deck.log, ['setQueue@1', 'play']);
      });
    });

    test('pausing stops the attempts and play reopens', () {
      fakeAsync((async) {
        build();
        start(async);
        final deck = decks[0];
        deck.fail();
        async.flushMicrotasks();
        deck.log.clear();
        engine.pause();
        async.flushMicrotasks();
        expect(states.last.playing, isFalse);
        async.elapse(const Duration(minutes: 2));
        expect(deck.log, ['pause'], reason: 'no attempts while paused');
        engine.play();
        async.elapse(Duration.zero);
        expect(deck.log, ['pause', 'setQueue@1', 'play']);
      });
    });

    test('skipping while it is down opens the next track', () {
      fakeAsync((async) {
        build();
        start(async);
        final deck = decks[0]..offline = true;
        deck.fail();
        async.flushMicrotasks();
        engine.next();
        async.flushMicrotasks();
        expect(states.last.currentIndex, 2);
        deck.offline = false;
        deck.log.clear();
        async.elapse(const Duration(seconds: 2));
        expect(deck.log, ['setQueue@2', 'play']);
        expect(deck.position, Duration.zero);
      });
    });

    test('queue edits while it is down keep the same track', () {
      fakeAsync((async) {
        build();
        start(async);
        final deck = decks[0]..offline = true;
        deck.fail();
        async.flushMicrotasks();
        engine.insertAll(0, [Uri.parse('t://new')]);
        async.flushMicrotasks();
        deck.offline = false;
        deck.log.clear();
        async.elapse(const Duration(seconds: 5));
        expect(deck.log.first, 'setQueue@2');
        expect(deck.queue[2], uris[1]);
      });
    });

    test('a queue that cannot open yet opens on play', () {
      fakeAsync((async) {
        build();
        states = [];
        engine.stateStream.listen(states.add);
        final deck = decks[0]..offline = true;
        engine.setQueue(uris, initialIndex: 2);
        async.flushMicrotasks();
        expect(engine.isRecovering, isTrue);
        deck.offline = false;
        engine.play();
        async.elapse(Duration.zero);
        expect(deck.log.last, 'play');
        expect(deck.index, 2);
        expect(engine.isRecovering, isFalse);
      });
    });

    test('a crossfade that cannot be prepared becomes a plain change', () {
      fakeAsync((async) {
        build();
        engine.setCrossfade(const Duration(seconds: 6));
        start(async);
        // The spare deck is made as the prepare window opens, and cannot
        // open the next track.
        decks[0].at(const Duration(seconds: 50));
        expect(decks, hasLength(2));
        decks[1].offline = true;
        async.flushMicrotasks();
        decks[0].at(const Duration(seconds: 50, milliseconds: 500));
        decks[0].at(const Duration(seconds: 55));
        async.flushMicrotasks();
        expect(decks[1].log.where((l) => l.startsWith('setQueue')), [
          'setQueue@2',
        ], reason: 'not tried again on every position update');
        async.elapse(const Duration(seconds: 1));
        expect(engine.isFading, isFalse);
        expect(decks[0].playing, isTrue);
      });
    });
  });
}

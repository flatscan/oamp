import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/audio/audio_engine.dart';
import 'package:oamp/core/models.dart';

/// A deck whose position the test moves by hand.
class FakeDeck implements AudioDeck {
  final String name;
  FakeDeck(this.name);

  final _state = StreamController<EngineState>.broadcast(sync: true);
  final _pos = StreamController<Duration>.broadcast(sync: true);
  final _dur = StreamController<Duration?>.broadcast(sync: true);
  List<Uri> queue = [];
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
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration?> get durationStream => _dur.stream;
  @override
  Duration get position => _p;
  @override
  int? get currentIndex => index;
  @override
  double get maxVolume => 2;

  @override
  Future<void> setQueue(List<Uri> uris, {int initialIndex = 0}) async {
    log.add('setQueue@$initialIndex');
    queue = List.of(uris);
    index = initialIndex;
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
}

void main() {
  late List<FakeDeck> decks;
  late MixingEngine engine;
  late Info info;
  final uris = [for (var i = 0; i < 4; i++) Uri.parse('t://$i')];

  setUp(() {
    decks = [];
    info = Info();
    engine = MixingEngine(() {
      final d = FakeDeck('deck${decks.length}');
      decks.add(d);
      return d;
    })..queueInfo = info;
  });

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
}

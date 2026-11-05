import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/audio/audio_focus.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

/// Calls, other apps and unplugged headphones, as PlayerController handles
/// them.
void main() {
  late FakeAudioEngine engine;
  late FakeAudioFocus focus;
  late ProviderContainer container;

  final tracks = [
    for (var i = 0; i < 3; i++)
      Track(id: 't$i', title: 'Track $i', duration: const Duration(minutes: 3)),
  ];

  setUp(() async {
    engine = FakeAudioEngine();
    focus = FakeAudioFocus();
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => FakeSessionNotifier(FakeMusicSource()),
        ),
        audioEngineProvider.overrideWithValue(engine),
        audioFocusProvider.overrideWithValue(focus),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  PlayerController player() => container.read(playerProvider.notifier);
  bool playing() => container.read(playerProvider).playing;

  Future<void> send(FocusChange change) async {
    focus.send(change);
    await settle();
  }

  Future<void> startPlaying() async {
    await player().playTracks(tracks);
    await settle();
    expect(playing(), isTrue);
  }

  test('a call pauses and playback carries on when it ends', () async {
    await startPlaying();
    await send(FocusChange.interrupted);
    expect(playing(), isFalse);
    await send(FocusChange.resumed);
    expect(playing(), isTrue);
  });

  test('an interruption while paused does not start playback', () async {
    await startPlaying();
    await player().pause();
    await settle();
    await send(FocusChange.interrupted);
    await send(FocusChange.resumed);
    expect(playing(), isFalse);
  });

  test('pausing during a call keeps it paused afterwards', () async {
    await startPlaying();
    await send(FocusChange.interrupted);
    await player().play();
    await player().pause();
    await settle();
    await send(FocusChange.resumed);
    expect(playing(), isFalse);
  });

  test('another player taking over pauses for good', () async {
    await startPlaying();
    await send(FocusChange.lost);
    expect(playing(), isFalse);
    // Focus can come back later (the other app stopped): stay paused.
    await send(FocusChange.resumed);
    expect(playing(), isFalse);
  });

  test('an interruption the system says not to resume from', () async {
    await startPlaying();
    await send(FocusChange.interrupted);
    await send(FocusChange.ended);
    expect(playing(), isFalse);
  });

  test('a short prompt turns playback down, then back up', () async {
    await startPlaying();
    await send(FocusChange.duck);
    expect(engine.ducked, isTrue);
    expect(playing(), isTrue);
    await send(FocusChange.resumed);
    expect(engine.ducked, isFalse);
    expect(playing(), isTrue);
  });

  test('the end of any interruption undoes ducking', () async {
    await startPlaying();
    await send(FocusChange.duck);
    await send(FocusChange.interrupted);
    await send(FocusChange.resumed);
    expect(engine.ducked, isFalse);
    expect(playing(), isTrue);
  });

  test('unplugging headphones pauses', () async {
    await startPlaying();
    await send(FocusChange.becomingNoisy);
    expect(playing(), isFalse);
    await send(FocusChange.resumed);
    expect(playing(), isFalse);
  });

  test('audio_session events map to focus changes', () {
    FocusChange map(bool begin, AudioInterruptionType type) =>
        AudioSessionFocus.fromInterruption(begin, type);
    expect(map(true, AudioInterruptionType.pause), FocusChange.interrupted);
    expect(map(true, AudioInterruptionType.unknown), FocusChange.lost);
    expect(map(true, AudioInterruptionType.duck), FocusChange.duck);
    expect(map(false, AudioInterruptionType.pause), FocusChange.resumed);
    expect(map(false, AudioInterruptionType.duck), FocusChange.resumed);
    expect(map(false, AudioInterruptionType.unknown), FocusChange.ended);
  });
}

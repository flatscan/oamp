import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/platform/system_controls.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/system_controls_bridge.dart';

import 'fakes/fakes.dart';

void main() {
  late FakeAudioEngine engine;
  late FakeSystemControls controls;
  late ProviderContainer container;

  setUp(() async {
    engine = FakeAudioEngine();
    controls = FakeSystemControls();
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(FakeSessionNotifier.new),
        audioEngineProvider.overrideWithValue(engine),
        systemControlsProvider.overrideWithValue(controls),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    container.read(systemControlsBridgeProvider);
  });

  // Lets stream events and the bridge's async sends run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  PlayerController player() => container.read(playerProvider.notifier);

  test('shows the current track in the OS media UI', () async {
    await player().playTracks(FakeMusicSource.tracks);
    await settle();

    final info = controls.last!;
    expect(info.title, 'La femme d’argent');
    expect(info.artist, 'Air');
    expect(info.album, 'Moon Safari');
    expect(info.playing, isTrue);
    expect(info.duration, const Duration(minutes: 7, seconds: 8));
    expect(info.canGoNext, isTrue);
  });

  test('media keys go through the player', () async {
    await player().playTracks(FakeMusicSource.tracks);
    await settle();

    controls.press(const NextCommand());
    await settle();
    expect(engine.index, 1);
    expect(controls.last!.title, 'Sexy Boy');
    expect(controls.last!.canGoNext, isFalse);

    controls.press(const PauseCommand());
    await settle();
    expect(engine.playing, isFalse);
    expect(controls.last!.playing, isFalse);

    controls.press(const TogglePlayCommand());
    await settle();
    expect(engine.playing, isTrue);

    // Previous near the start of a track goes back one, like the app button.
    controls.press(const PreviousCommand());
    await settle();
    expect(engine.index, 0);
  });

  test('clearing the queue removes OAmp from the OS media UI', () async {
    await player().playTracks(FakeMusicSource.tracks);
    await settle();
    await player().clear();
    await settle();
    expect(controls.last, isNull);
  });

  test('play with an empty queue does nothing', () async {
    controls.press(const PlayCommand());
    await settle();
    expect(engine.playing, isFalse);
  });
}

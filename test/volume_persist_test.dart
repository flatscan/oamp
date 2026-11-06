import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/platform/preferences.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/state/settings.dart';

import 'fakes/fakes.dart';

void main() {
  ProviderContainer start(Preferences prefs, FakeAudioEngine engine) {
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier()),
        audioEngineProvider.overrideWithValue(engine),
        preferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('volume starts full when nothing was saved', () {
    final engine = FakeAudioEngine();
    final c = start(MemoryPreferences(), engine);
    expect(c.read(playerProvider).volume, 1);
    expect(engine.volume, 1);
  });

  test('volume set on the slider comes back on the next run', () async {
    final prefs = MemoryPreferences();
    final first = start(prefs, FakeAudioEngine());
    final p = first.read(playerProvider.notifier);
    await p.setVolume(0.2);
    await p.setVolume(0.35);
    // Saving waits for the slider to settle.
    expect(prefs.getDouble(PlayerController.volumeKey), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(prefs.getDouble(PlayerController.volumeKey), 0.35);

    final engine = FakeAudioEngine();
    final second = start(prefs, engine);
    expect(second.read(playerProvider).volume, 0.35);
    expect(engine.volume, 0.35);
  });

  test('a level still waiting to be saved is saved on shutdown', () async {
    final prefs = MemoryPreferences();
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier()),
        audioEngineProvider.overrideWithValue(FakeAudioEngine()),
        preferencesProvider.overrideWithValue(prefs),
      ],
    );
    await c.read(playerProvider.notifier).setVolume(0.6);
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getDouble(PlayerController.volumeKey), 0.6);
  });

  test('clearing the queue keeps the saved level', () async {
    final prefs = MemoryPreferences();
    await prefs.setDouble(PlayerController.volumeKey, 0.5);
    final c = start(prefs, FakeAudioEngine());
    await c.read(playerProvider.notifier).clear();
    expect(c.read(playerProvider).volume, 0.5);
  });
}

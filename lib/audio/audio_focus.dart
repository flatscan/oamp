import 'dart:async';

import 'package:audio_session/audio_session.dart';

/// Something else on the device wants the speaker, or the output went away.
enum FocusChange {
  /// Another app or a call needs the audio for a while (a phone call, a
  /// navigation prompt that cannot be ducked under). Pause, and play again
  /// on [resumed] if this paused us.
  interrupted,

  /// Another app took the audio for good (the listener started music in
  /// another player). Pause and stay paused.
  lost,

  /// Another app needs a moment of quieter audio, such as a notification
  /// sound or a navigation prompt. Turn down until [resumed] or [ended].
  duck,

  /// The interruption is over and playback may carry on.
  resumed,

  /// The interruption is over, but the system says not to resume by itself.
  ended,

  /// Headphones were unplugged or a Bluetooth output disconnected, so sound
  /// would come out of the speaker. Pause.
  becomingNoisy,
}

/// The OS audio session: who has the speaker, and when the output changes.
///
/// [PlayerController] listens to [changes] and decides what to do, so the
/// rules live in one place for every platform.
abstract class AudioFocus {
  Stream<FocusChange> get changes;
  Future<void> dispose();
}

/// For platforms that need no audio session (Windows) and for tests.
class NoAudioFocus implements AudioFocus {
  const NoAudioFocus();
  @override
  Stream<FocusChange> get changes => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

/// [AudioFocus] through the audio_session package (Android audio focus and
/// becoming noisy, the AVAudioSession on iOS).
///
/// just_audio asks for focus each time a deck starts playing, through the
/// same shared session, so this only configures it and reports changes.
/// The players are told not to react to interruptions themselves (see
/// JustAudioDeck), since a crossfade uses two of them at once.
class AudioSessionFocus implements AudioFocus {
  AudioSessionFocus._(AudioSession session) {
    _subs
      ..add(
        session.interruptionEventStream.listen(
          (e) => _changes.add(fromInterruption(e.begin, e.type)),
        ),
      )
      ..add(
        session.becomingNoisyEventStream.listen(
          (_) => _changes.add(FocusChange.becomingNoisy),
        ),
      );
  }

  /// Configures the session for music playback and starts listening.
  static Future<AudioSessionFocus> open() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    return AudioSessionFocus._(session);
  }

  final _changes = StreamController<FocusChange>.broadcast();
  final List<StreamSubscription<void>> _subs = [];

  /// What an audio_session interruption event means for the player.
  ///
  /// On Android a permanent focus loss arrives as a `begin` of type
  /// unknown, a transient loss as `pause`, and "may duck" as `duck`; the
  /// matching `end` comes when focus returns. On iOS an interruption ends
  /// as `pause` when the system says playback should resume and as
  /// unknown when it should not.
  static FocusChange fromInterruption(bool begin, AudioInterruptionType type) {
    if (begin) {
      return switch (type) {
        AudioInterruptionType.duck => FocusChange.duck,
        AudioInterruptionType.pause => FocusChange.interrupted,
        AudioInterruptionType.unknown => FocusChange.lost,
      };
    }
    return switch (type) {
      AudioInterruptionType.unknown => FocusChange.ended,
      _ => FocusChange.resumed,
    };
  }

  @override
  Stream<FocusChange> get changes => _changes.stream;

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _changes.close();
  }
}

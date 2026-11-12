import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../core/equalizer.dart';
import '../core/models.dart';
import 'audio_engine.dart';

/// [AudioDeck] on just_audio's platform players (Android, iOS, macOS).
/// Those players are gapless on their own, so [setGapless] does nothing.
///
/// The player still asks for audio focus when it starts, but leaves
/// interruptions (calls, ducking, headphones unplugged) to
/// PlayerController: a crossfade plays two decks at once, and each pausing
/// and resuming on its own would fight the queue. Failed streams are
/// reported on [errors] for [MixingEngine] to retry, rather than skipped.
///
/// On Android, [setEqualizer] drives the system equaliser attached to the
/// player's audio session. Its bands (usually five) differ between phones,
/// so each preset is sampled at whatever bands this phone has. Other
/// platforms have no equaliser here and play the preset as [EqPreset.off].
class JustAudioDeck implements AudioDeck {
  JustAudioDeck() : this._(_hasEqualizer ? AndroidEqualizer() : null);

  JustAudioDeck._(this._eq)
    : _player = AudioPlayer(
        handleInterruptions: false,
        audioPipeline: _eq == null
            ? null
            : AudioPipeline(androidAudioEffects: [_eq]),
      ) {
    // Play/pause and buffering come from playerStateStream, track changes
    // from currentIndexStream; fold both into one EngineState stream.
    _subs.add(_player.playerStateStream.listen((_) => _emit()));
    _subs.add(_player.currentIndexStream.listen((_) => _emit()));
  }

  static bool get _hasEqualizer =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final AndroidEqualizer? _eq;
  final AudioPlayer _player;
  final _state = StreamController<EngineState>.broadcast();
  final List<StreamSubscription> _subs = [];
  EqPreset _preset = EqPreset.off;

  void _emit() {
    final ps = _player.processingState;
    _state.add(
      EngineState(
        playing: _player.playing,
        buffering:
            ps == ProcessingState.loading || ps == ProcessingState.buffering,
        completed: ps == ProcessingState.completed,
        currentIndex: _player.currentIndex,
      ),
    );
  }

  List<AudioSource> _sources(List<Uri> uris) => [
    for (final u in uris) AudioSource.uri(u),
  ];

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Object> get errors => _player.errorStream;
  @override
  Stream<Duration> get positionStream => _player.positionStream;
  @override
  Stream<Duration?> get durationStream => _player.durationStream;
  @override
  Duration get position => _player.position;
  @override
  Duration? get duration => _player.duration;
  @override
  int? get currentIndex => _player.currentIndex;
  @override
  bool get playing => _player.playing;
  @override
  double get maxVolume => 1;

  @override
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) => _player.setAudioSources(
    _sources(uris),
    initialIndex: initialIndex,
    initialPosition: initialPosition,
  );
  @override
  Future<void> addAll(List<Uri> uris) =>
      _player.addAudioSources(_sources(uris));
  @override
  Future<void> insertAll(int index, List<Uri> uris) =>
      _player.insertAudioSources(index, _sources(uris));
  @override
  Future<void> removeAt(int index) => _player.removeAudioSourceAt(index);
  @override
  Future<void> move(int from, int to) => _player.moveAudioSource(from, to);
  @override
  Future<void> clear() async {
    await _player.stop();
    await _player.clearAudioSources();
  }

  /// just_audio's play() only completes once playback stops again, so
  /// this returns as soon as it has been asked to start.
  @override
  Future<void> play() async => unawaited(_player.play());
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position, {int? index}) =>
      _player.seek(position, index: index);
  @override
  Future<void> next() => _player.seekToNext();
  @override
  Future<void> previous() => _player.seekToPrevious();

  @override
  Future<void> setRepeatMode(PlaybackRepeat mode) =>
      _player.setLoopMode(switch (mode) {
        PlaybackRepeat.off => LoopMode.off,
        PlaybackRepeat.all => LoopMode.all,
        PlaybackRepeat.one => LoopMode.one,
      });
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> setGapless(bool enabled) async {}

  @override
  bool get hasEqualizer => _eq != null;

  @override
  Future<void> setEqualizer(EqPreset preset) async {
    final eq = _eq;
    _preset = preset;
    if (eq == null) return;
    await eq.setEnabled(!preset.isOff);
    if (preset.isOff) return;
    // The bands are only known once the player has opened its first
    // track, so this waits for that the first time.
    unawaited(_applyBands(eq, preset));
  }

  Future<void> _applyBands(AndroidEqualizer eq, EqPreset preset) async {
    try {
      final p = await eq.parameters;
      if (_preset != preset) return; // Changed again meanwhile.
      final gains = preset.bandGains(
        [for (final b in p.bands) b.centerFrequency],
        minDb: p.minDecibels,
        maxDb: p.maxDecibels,
      );
      for (var i = 0; i < p.bands.length; i++) {
        await p.bands[i].setGain(gains[i]);
      }
    } catch (e) {
      debugPrint('Equaliser unavailable: $e');
    }
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _state.close();
    await _player.dispose();
  }
}

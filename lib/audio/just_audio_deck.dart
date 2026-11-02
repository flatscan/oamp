import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../core/models.dart';
import 'audio_engine.dart';

/// [AudioDeck] on just_audio's platform players (Android, iOS, macOS).
/// Those players are gapless on their own, so [setGapless] does nothing.
class JustAudioDeck implements AudioDeck {
  final AudioPlayer _player = AudioPlayer();
  final _state = StreamController<EngineState>.broadcast();
  final List<StreamSubscription> _subs = [];

  JustAudioDeck() {
    // Play/pause and buffering come from playerStateStream, track changes
    // from currentIndexStream; fold both into one EngineState stream.
    _subs.add(_player.playerStateStream.listen((_) => _emit()));
    _subs.add(_player.currentIndexStream.listen((_) => _emit()));
  }

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
  Future<void> setQueue(List<Uri> uris, {int initialIndex = 0}) =>
      _player.setAudioSources(_sources(uris), initialIndex: initialIndex);
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
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _state.close();
    await _player.dispose();
  }
}

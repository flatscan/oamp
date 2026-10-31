import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Snapshot of what the engine is doing, independent of the backend.
class EngineState {
  final bool playing;
  final bool buffering;
  final bool completed;
  final int? currentIndex;

  const EngineState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.currentIndex,
  });
}

/// The only interface the rest of the app uses to make sound.
///
/// Keeping playback behind this interface means switching backends (for
/// example to `media_kit` on every platform if gapless playback disappoints)
/// is a change to one implementation file.
abstract class AudioEngine {
  Stream<EngineState> get stateStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Duration get position;

  Future<void> setQueue(List<Uri> uris, {int initialIndex = 0});
  Future<void> addAll(List<Uri> uris);
  Future<void> insertAll(int index, List<Uri> uris);
  Future<void> removeAt(int index);
  Future<void> move(int from, int to);
  Future<void> clear();

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position, {int? index});
  Future<void> next();
  Future<void> previous();
  Future<void> dispose();
}

/// [AudioEngine] backed by just_audio. On Windows just_audio is
/// served by libmpv through `just_audio_media_kit` (registered in main.dart);
/// on Android, iOS and macOS it uses the platform players.
class JustAudioEngine implements AudioEngine {
  final AudioPlayer _player = AudioPlayer();
  final _state = StreamController<EngineState>.broadcast();
  final List<StreamSubscription> _subs = [];

  JustAudioEngine() {
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

  @override
  Future<void> play() => _player.play();
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
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _state.close();
    await _player.dispose();
  }
}

import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../core/models.dart' show PlaybackRepeat;
import 'audio_engine.dart';

/// [AudioDeck] on libmpv through media_kit. Used on Windows, where
/// just_audio has no player of its own.
///
/// Talking to mpv directly (rather than through just_audio) lets gapless
/// playback be switched while playing and lets ReplayGain boost quiet
/// tracks past 100% volume.
class MpvDeck implements AudioDeck {
  /// [mpvOptions] are extra mpv properties set at start, such as
  /// `ao: null` in tests.
  MpvDeck({Map<String, String> mpvOptions = const {}})
    : _player = Player(
        configuration: const PlayerConfiguration(
          title: 'OAmp',
          // A full track of demuxer cache, so a short network stall does
          // not interrupt playback.
          bufferSize: 64 * 1024 * 1024,
          logLevel: MPVLogLevel.warn,
        ),
      ) {
    _ready = _setUp(mpvOptions);
    _subs.addAll([
      _player.stream.playing.listen((_) => _emit()),
      _player.stream.buffering.listen((_) => _emit()),
      _player.stream.completed.listen((_) => _emit()),
      _player.stream.playlist.listen((_) => _emit()),
      _player.stream.position.listen((p) {
        _pos = p;
        if (!_positions.isClosed) _positions.add(p);
      }),
      _player.stream.duration.listen((d) {
        _dur = d > Duration.zero ? d : null;
        if (!_durations.isClosed) _durations.add(_dur);
      }),
    ]);
  }

  /// mpv's volume runs to 100 for unity gain; up to [maxVolume] x 100 is
  /// allowed for ReplayGain boosts.
  static const _volumeMax = 200;

  final Player _player;
  late final Future<void> _ready;
  final _state = StreamController<EngineState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final List<StreamSubscription> _subs = [];
  PlaybackRepeat _repeat = PlaybackRepeat.off;
  Duration _pos = Duration.zero;
  Duration? _dur;

  /// Set by [clear]. media_kit keeps its copy of the old playlist after a
  /// stop, so the deck tracks emptiness itself.
  bool _empty = true;

  NativePlayer? get _mpv => _player.platform is NativePlayer
      ? _player.platform as NativePlayer
      : null;

  Future<void> _setUp(Map<String, String> options) async {
    final mpv = _mpv;
    if (mpv == null) return;
    await mpv.setProperty('volume-max', '$_volumeMax');
    for (final e in options.entries) {
      await mpv.setProperty(e.key, e.value);
    }
    await setGapless(true);
  }

  void _emit() {
    if (_state.isClosed) return;
    final s = _player.state;
    final last = s.playlist.medias.length - 1;
    final index = currentIndex;
    // mpv reports "completed" at the end of every file; the queue is only
    // finished at the end of the last one with repeat off.
    final completed =
        s.completed && index == last && _repeat == PlaybackRepeat.off;
    _state.add(
      EngineState(
        playing: s.playing && !completed,
        buffering: s.buffering,
        completed: completed,
        currentIndex: index,
      ),
    );
  }

  List<Media> _media(List<Uri> uris) => [
    for (final u in uris) Media(u.toString()),
  ];

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
  @override
  Duration get position => _pos;
  @override
  Duration? get duration => _dur;
  @override
  int? get currentIndex => _empty || _player.state.playlist.medias.isEmpty
      ? null
      : _player.state.playlist.index;
  @override
  bool get playing => _player.state.playing;
  @override
  double get maxVolume => _volumeMax / 100;

  @override
  Future<void> setQueue(List<Uri> uris, {int initialIndex = 0}) async {
    await _ready;
    _pos = Duration.zero;
    _empty = uris.isEmpty;
    await _player.open(
      Playlist(_media(uris), index: initialIndex),
      play: false,
    );
  }

  @override
  Future<void> addAll(List<Uri> uris) async {
    if (_empty) return setQueue(uris);
    for (final m in _media(uris)) {
      await _player.add(m);
    }
  }

  @override
  Future<void> insertAll(int index, List<Uri> uris) async {
    if (_empty) return setQueue(uris);
    var at = index;
    for (final m in _media(uris)) {
      await _player.add(m);
      final last = _player.state.playlist.medias.length - 1;
      // mpv's playlist-move puts the entry before the one at [at].
      if (at < last) await _player.move(last, at);
      at++;
    }
  }

  @override
  Future<void> removeAt(int index) => _player.remove(index);

  @override
  Future<void> move(int from, int to) =>
      // The entry should end up at [to]; mpv inserts before the entry at
      // its target, which is one further along when moving down.
      _player.move(from, from < to ? to + 1 : to);

  @override
  Future<void> clear() async {
    _empty = true;
    await _player.stop();
    _emit();
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position, {int? index}) async {
    if (index != null && index != currentIndex) {
      if (playing) {
        await _player.jump(index);
      } else {
        // jump() would start playback; moving the position stays paused.
        await _mpv?.setProperty('playlist-pos', '$index');
      }
      _pos = position;
      if (position > Duration.zero) await _player.seek(position);
      return;
    }
    _pos = position;
    await _player.seek(position);
  }

  @override
  Future<void> next() => _player.next();
  @override
  Future<void> previous() => _player.previous();

  @override
  Future<void> setRepeatMode(PlaybackRepeat mode) {
    _repeat = mode;
    return _player.setPlaylistMode(switch (mode) {
      PlaybackRepeat.off => PlaylistMode.none,
      PlaybackRepeat.all => PlaylistMode.loop,
      PlaybackRepeat.one => PlaylistMode.single,
    });
  }

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume((volume * 100).clamp(0, _volumeMax).toDouble());

  @override
  Future<void> setGapless(bool enabled) async {
    final mpv = _mpv;
    if (mpv == null) return;
    // prefetch-playlist opens the next stream before the current one ends,
    // which is what removes the gap for network streams; gapless-audio
    // keeps the audio output open across the change.
    await mpv.setProperty('prefetch-playlist', enabled ? 'yes' : 'no');
    await mpv.setProperty('gapless-audio', enabled ? 'weak' : 'no');
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _state.close();
    await _positions.close();
    await _durations.close();
    await _player.dispose();
  }
}

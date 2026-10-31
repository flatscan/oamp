import 'dart:async';

import 'package:oamp/audio/audio_engine.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/state/session.dart';

/// A small in-memory library. Driving the UI with this is the design doc's
/// check that no widget depends on Subsonic.
class FakeMusicSource implements MusicSource {
  static const air = Artist(id: 'ar1', name: 'Air', albumCount: 1);
  static const moonSafari = Album(
    id: 'al1',
    name: 'Moon Safari',
    artist: 'Air',
    artistId: 'ar1',
    year: 1998,
    songCount: 2,
  );
  static const tracks = [
    Track(
      id: 't1',
      title: 'La femme d’argent',
      artist: 'Air',
      album: 'Moon Safari',
      track: 1,
      duration: Duration(minutes: 7, seconds: 8),
    ),
    Track(
      id: 't2',
      title: 'Sexy Boy',
      artist: 'Air',
      album: 'Moon Safari',
      track: 2,
      duration: Duration(minutes: 4, seconds: 58),
    ),
  ];

  @override
  String get serverId => 'fake:1';
  @override
  String get displayName => 'tester @ fake';
  @override
  SourceCapabilities get capabilities => const SourceCapabilities();
  @override
  Future<void> ping() async {}
  @override
  Future<List<Artist>> getArtists() async => [air];
  @override
  Future<ArtistDetail> getArtist(String id) async =>
      const ArtistDetail(air, [moonSafari]);
  @override
  Future<List<Album>> getAlbums({
    AlbumSort sort = AlbumSort.alphabetical,
    int size = 100,
    int offset = 0,
  }) async => [moonSafari];
  @override
  Future<AlbumDetail> getAlbum(String id) async =>
      const AlbumDetail(moonSafari, tracks);
  @override
  Uri streamUrl(String trackId) => Uri.parse('fake://stream/$trackId');
  @override
  Uri? coverArtUrl(String? coverArtId, {int size = 300}) => null;
  @override
  void close() {}
}

class FakeSessionNotifier extends SessionNotifier {
  @override
  Future<ServerSession?> build() async => ServerSession(FakeMusicSource());
}

/// Records what the player asks for and reports it back as engine state.
class FakeAudioEngine implements AudioEngine {
  final _state = StreamController<EngineState>.broadcast();
  final List<Uri> queue = [];
  int? index;
  bool playing = false;

  void _emit() =>
      _state.add(EngineState(playing: playing, currentIndex: index));

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Duration get position => Duration.zero;

  @override
  Future<void> setQueue(List<Uri> uris, {int initialIndex = 0}) async {
    queue
      ..clear()
      ..addAll(uris);
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
    queue.clear();
    index = null;
    playing = false;
    _emit();
  }

  @override
  Future<void> play() async {
    playing = true;
    _emit();
  }

  @override
  Future<void> pause() async {
    playing = false;
    _emit();
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    if (index != null) this.index = index;
    _emit();
  }

  @override
  Future<void> next() async {
    index = (index ?? 0) + 1;
    _emit();
  }

  @override
  Future<void> previous() async {
    index = (index ?? 1) - 1;
    _emit();
  }

  @override
  Future<void> dispose() => _state.close();
}

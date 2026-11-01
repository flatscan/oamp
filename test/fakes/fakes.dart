import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:oamp/audio/audio_engine.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/platform/system_controls.dart';
import 'package:oamp/state/session.dart';

/// A small in-memory library. Driving the UI with this is the design doc's
/// check that no widget depends on Subsonic.
class FakeMusicSource implements MusicSource {
  FakeMusicSource({this.albums = const [moonSafari]});

  /// What album lists return; tests that need long rows pass more.
  final List<Album> albums;

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
      artistId: 'ar1',
      albumId: 'al1',
      track: 1,
      duration: Duration(minutes: 7, seconds: 8),
    ),
    Track(
      id: 't2',
      title: 'Sexy Boy',
      artist: 'Air',
      album: 'Moon Safari',
      artistId: 'ar1',
      albumId: 'al1',
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
  }) async => albums.skip(offset).take(size).toList();
  @override
  Future<AlbumDetail> getAlbum(String id) async =>
      const AlbumDetail(moonSafari, tracks);
  static const mixtape = Playlist(id: 'pl1', name: 'Mixtape', songCount: 2);

  /// Calls made to the server's write endpoints, for assertions.
  final List<String> calls = [];

  @override
  Future<SearchResults> search(String query, {int limit = 20}) async {
    bool m(String s) => s.toLowerCase().contains(query.toLowerCase());
    return SearchResults(
      artists: [if (m(air.name)) air],
      albums: [if (m(moonSafari.name)) moonSafari],
      tracks: [
        for (final t in tracks)
          if (m(t.title)) t,
      ],
    );
  }

  @override
  Future<List<Playlist>> getPlaylists() async => [mixtape];
  @override
  Future<PlaylistDetail> getPlaylist(String id) async =>
      PlaylistDetail(mixtape, tracks.reversed.toList());
  @override
  Future<List<Track>> getRandomTracks({int size = 100}) async => tracks;
  @override
  Future<List<Track>> getLikedTracks() async => [];
  @override
  Future<void> setLiked(String trackId, bool liked) async =>
      calls.add('${liked ? 'like' : 'unlike'}:$trackId');
  @override
  Future<void> reportPlayback(
    String trackId, {
    required bool submission,
  }) async => calls.add('${submission ? 'played' : 'playing'}:$trackId');

  @override
  Uri streamUrl(String trackId) => Uri.parse('fake://stream/$trackId');
  @override
  Uri? coverArtUrl(String? coverArtId, {int size = 300}) => null;
  @override
  void close() {}
}

class FakeSessionNotifier extends SessionNotifier {
  FakeSessionNotifier([FakeMusicSource? source])
    : source = source ?? FakeMusicSource();
  final FakeMusicSource source;

  @override
  Future<ServerSession?> build() async => ServerSession(source);
}

/// Records what the player asks for and reports it back as engine state.
class FakeAudioEngine implements AudioEngine {
  final _state = StreamController<EngineState>.broadcast();
  final List<Uri> queue = [];
  int? index;
  bool playing = false;
  PlaybackRepeat repeat = PlaybackRepeat.off;
  double volume = 1;
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();

  /// Pretends playback has reached [p].
  void emitPosition(Duration p) => _position.add(p);

  void _emit() =>
      _state.add(EngineState(playing: playing, currentIndex: index));

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
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
  Future<void> setRepeatMode(PlaybackRepeat mode) async => repeat = mode;
  @override
  Future<void> setVolume(double v) async => volume = v;

  @override
  Future<void> dispose() async {
    await _state.close();
    await _position.close();
    await _duration.close();
  }
}

/// Records what the app shows in the OS media UI, and lets a test press its
/// buttons.
class FakeSystemControls implements SystemControls {
  final _commands = StreamController<MediaCommand>.broadcast();
  final List<NowPlayingInfo?> shown = [];
  @override
  final ValueNotifier<String?> problem = ValueNotifier(null);

  NowPlayingInfo? get last => shown.isEmpty ? null : shown.last;

  void press(MediaCommand cmd) => _commands.add(cmd);

  @override
  Stream<MediaCommand> get commands => _commands.stream;
  @override
  Future<void> update(NowPlayingInfo info) async => shown.add(info);
  @override
  Future<void> clear() async => shown.add(null);
  @override
  Future<void> dispose() => _commands.close();
}

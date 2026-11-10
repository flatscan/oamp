import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:oamp/audio/audio_engine.dart';
import 'package:oamp/audio/audio_focus.dart';
import 'package:oamp/core/lyrics.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/core/play_queue.dart';
import 'package:oamp/core/playback_options.dart';
import 'package:oamp/core/server_route.dart';
import 'package:oamp/platform/system_controls.dart';
import 'package:oamp/state/session.dart';

/// A small in-memory library. Driving the UI with this is the design doc's
/// check that no widget depends on Subsonic.
class FakeMusicSource implements MusicSource {
  FakeMusicSource({
    this.albums = const [moonSafari],
    this.artists = const [air],
  }) {
    playlists[mixtape.id] = (mixtape, tracks.reversed.toList());
  }

  /// What album lists return; tests that need long rows pass more.
  final List<Album> albums;

  /// What the artist list returns.
  final List<Artist> artists;

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
  String get userName => 'tester';

  @override
  SourceCapabilities capabilities = const SourceCapabilities(
    hasSimilar: true,
    hasGenres: true,
    hasQueueSync: true,
  );
  @override
  Future<SourceCapabilities> detectCapabilities() async => capabilities;

  /// The play queue the server holds.
  SavedQueue? playQueue;

  /// Set to make the play queue calls fail, as if offline.
  bool queueOffline = false;
  int queueReads = 0;
  final List<SavedQueue> queueSaves = [];

  @override
  Future<SavedQueue?> getPlayQueue() async {
    queueReads++;
    if (queueOffline) throw MusicSourceException('offline');
    return playQueue;
  }

  @override
  Future<void> savePlayQueue(
    List<String> trackIds, {
    int? currentIndex,
    Duration position = Duration.zero,
  }) async {
    if (queueOffline) throw MusicSourceException('offline');
    final known = [...tracks, ...extraTracks];
    final saved = SavedQueue(
      tracks: [
        for (final id in trackIds)
          known.firstWhere(
            (t) => t.id == id,
            orElse: () => Track(id: id, title: id),
          ),
      ],
      currentIndex: currentIndex,
      position: position,
      changed: DateTime.now().toUtc(),
      changedBy: 'OAmp',
    );
    queueSaves.add(saved);
    playQueue = saved.isEmpty ? null : saved;
  }

  /// Tracks beyond the album that queue saves can name.
  List<Track> extraTracks = const [];
  @override
  Future<void> ping() async {
    pings++;
    final e = pingError;
    if (e != null) throw e;
  }

  /// Thrown by [ping] while set, to fake a server that is down or signed out.
  MusicSourceException? pingError;
  int pings = 0;

  @override
  ServerRoute route = ServerRoute.home;

  /// Add to it to fake a switch between home and away.
  final routeController = StreamController<ServerRoute>.broadcast(sync: true);

  @override
  Stream<ServerRoute> get routeChanges => routeController.stream;

  /// What [connect] switches to, to fake a server with an away address.
  ServerRoute? routeOnConnect;

  @override
  Future<void> connect() async {
    await ping();
    final next = routeOnConnect;
    if (next != null && next != route) {
      route = next;
      routeController.add(next);
    }
  }

  int unreachableReports = 0;
  @override
  void reportUnreachable() => unreachableReports++;
  @override
  Future<List<Artist>> getArtists() async => artists;
  @override
  Future<ArtistDetail> getArtist(String id) async =>
      ArtistDetail(air, [moonSafari, ...artistExtras]);

  /// More releases for Air's page, such as EPs.
  List<Album> artistExtras = const [];

  static const daftPunk = Artist(id: 'ar2', name: 'Daft Punk');

  @override
  Future<ArtistInfo> getArtistInfo(String id) async => const ArtistInfo(
    biography: 'Air are a French duo from Versailles.',
    similar: [daftPunk],
  );
  @override
  Future<List<Track>> getTopTracks(Artist artist, {int count = 10}) async =>
      tracks.reversed.take(count).toList();
  @override
  Future<List<Track>> getSimilarTracks(String id, {int count = 50}) async {
    calls.add('similar:$id');
    return similarTracks ?? tracks;
  }

  /// What getSimilarTracks returns; null means [tracks].
  List<Track>? similarTracks;

  /// What getRandomTracks returns for each genre.
  Map<String, List<Track>> tracksByGenre = {};

  @override
  Future<List<Album>> getAlbums({
    AlbumSort sort = AlbumSort.alphabetical,
    int size = 100,
    int offset = 0,
  }) async => albums.skip(offset).take(size).toList();
  @override
  Future<AlbumDetail> getAlbum(String id) async =>
      albumDetails[id] ?? const AlbumDetail(moonSafari, tracks);

  /// What getAlbum returns by id, falling back to Moon Safari.
  Map<String, AlbumDetail> albumDetails = {};

  /// What getTrack returns by id, falling back to [tracks].
  Map<String, Track> trackDetails = {};

  /// Ids getTrack was asked for, in order.
  final List<String> trackRequests = [];

  @override
  Future<Track> getTrack(String id) async {
    trackRequests.add(id);
    return trackDetails[id] ?? tracks.firstWhere((t) => t.id == id);
  }

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

  /// The server's playlists, which the write methods change.
  final Map<String, (Playlist, List<Track>)> playlists = {};
  int _nextPlaylist = 2;

  static final _byId = {for (final t in tracks) t.id: t};

  Playlist _summary(Playlist p, List<Track> ts) =>
      Playlist(id: p.id, name: p.name, songCount: ts.length, owner: p.owner);

  @override
  Future<List<Playlist>> getPlaylists() async => [
    for (final (p, ts) in playlists.values) _summary(p, ts),
  ];
  @override
  Future<PlaylistDetail> getPlaylist(String id) async {
    final (p, ts) = playlists[id]!;
    return PlaylistDetail(_summary(p, ts), List.of(ts));
  }

  @override
  Future<Playlist> createPlaylist(
    String name, {
    List<String> trackIds = const [],
  }) async {
    final p = Playlist(id: 'pl${_nextPlaylist++}', name: name, owner: 'tester');
    playlists[p.id] = (p, [for (final id in trackIds) _byId[id]!]);
    calls.add('create:$name:${trackIds.join(',')}');
    return _summary(p, playlists[p.id]!.$2);
  }

  @override
  Future<void> renamePlaylist(String id, String name) async {
    final (p, ts) = playlists[id]!;
    playlists[id] = (Playlist(id: id, name: name, owner: p.owner), ts);
    calls.add('rename:$id:$name');
  }

  @override
  Future<void> addToPlaylist(String id, List<String> trackIds) async {
    playlists[id]!.$2.addAll([for (final t in trackIds) _byId[t]!]);
    calls.add('add:$id:${trackIds.join(',')}');
  }

  @override
  Future<void> removeFromPlaylist(String id, List<int> indexes) async {
    final ts = playlists[id]!.$2;
    for (final i in [...indexes]..sort((a, b) => b.compareTo(a))) {
      ts.removeAt(i);
    }
    calls.add('remove:$id:${indexes.join(',')}');
  }

  @override
  Future<void> replacePlaylistTracks(String id, List<String> trackIds) async {
    final (p, _) = playlists[id]!;
    playlists[id] = (p, [for (final t in trackIds) _byId[t]!]);
    calls.add('replace:$id:${trackIds.join(',')}');
  }

  @override
  Future<void> deletePlaylist(String id) async {
    playlists.remove(id);
    calls.add('delete:$id');
  }

  @override
  Future<List<Track>> getRandomTracks({int size = 100, String? genre}) async {
    if (genre == null) return tracks;
    calls.add('random:$genre');
    return (tracksByGenre[genre] ?? const []).take(size).toList();
  }

  @override
  Future<List<Track>> getLikedTracks() async => likedTracks;

  /// What getLikedTracks returns.
  List<Track> likedTracks = [];
  @override
  Future<List<Artist>> getLikedArtists() async => [
    for (final a in artists)
      if (a.liked) a,
  ];
  @override
  Future<void> setLiked(
    String id,
    bool liked, {
    LikeTarget target = LikeTarget.track,
  }) async => calls.add(
    '${liked ? 'like' : 'unlike'}'
    '${target == LikeTarget.track ? '' : '-${target.name}'}:$id',
  );
  @override
  Future<void> setRating(String id, int rating) async =>
      calls.add('rate:$id:$rating');

  /// What [getLyrics] returns, by track id.
  final Map<String, Lyrics> lyrics = {};

  @override
  Future<Lyrics> getLyrics(Track track) async {
    calls.add('lyrics:${track.id}');
    return lyrics[track.id] ?? Lyrics.none;
  }

  /// Makes play reports fail the way the real source's do: with a future
  /// that really carries the server's reply type, not void.
  bool reportsFail = false;

  Future<void> _report(String call) {
    calls.add(call);
    if (reportsFail) {
      return Future<Map<String, dynamic>>.error(
        Exception('Could not reach the server'),
      );
    }
    return Future<void>.value();
  }

  @override
  Future<void> reportPlayback(String trackId, {required bool submission}) =>
      _report('${submission ? 'played' : 'playing'}:$trackId');

  @override
  Future<void> reportPlaybackState(
    String trackId,
    PlaybackPhase phase,
    Duration position,
  ) => _report('state:${phase.name}:$trackId:${position.inSeconds}');

  @override
  Uri streamUrl(
    String trackId, {
    StreamQuality quality = StreamQuality.original,
    Duration offset = Duration.zero,
  }) => Uri.parse(
    'fake://stream/$trackId${quality.isOriginal ? '' : '?q=${quality.tag}'}'
    '${offset > Duration.zero ? '&t=${offset.inSeconds}' : ''}',
  );
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

  /// Pretends the active stream reported [d] as its length.
  void emitDuration(Duration? d) => _duration.add(d);

  /// Pretends the current stream reached its end: with repeat off, moves
  /// on to the next entry or completes at the end of the queue.
  void finishTrack() {
    final at = index;
    if (at == null) return;
    if (repeat == PlaybackRepeat.one) {
      _emit();
    } else if (at + 1 < queue.length) {
      index = at + 1;
      _emit();
    } else if (repeat == PlaybackRepeat.all && queue.isNotEmpty) {
      index = 0;
      _emit();
    } else {
      playing = false;
      _state.add(
        EngineState(playing: false, completed: true, currentIndex: at),
      );
    }
  }

  void _emit() =>
      _state.add(EngineState(playing: playing, currentIndex: index));

  @override
  Stream<EngineState> get stateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;

  /// What [position] reports.
  Duration currentPosition = Duration.zero;

  @override
  Duration get position => currentPosition;

  /// Where the last [setQueue] asked to start.
  Duration startPosition = Duration.zero;

  @override
  Future<void> setQueue(
    List<Uri> uris, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
  }) async {
    queue
      ..clear()
      ..addAll(uris);
    index = initialIndex;
    startPosition = initialPosition;
    _emit();
  }

  @override
  Future<void> addAll(List<Uri> uris) async => queue.addAll(uris);

  /// Inserting or removing before the current entry moves the index, as
  /// real players do.
  @override
  Future<void> insertAll(int i, List<Uri> uris) async {
    queue.insertAll(i, uris);
    final at = index;
    if (at != null && i <= at && at < queue.length - uris.length) {
      index = at + uris.length;
      _emit();
    }
  }

  @override
  Future<void> removeAt(int i) async {
    if (queue.length <= 1 && i == 0) {
      await clear();
      return;
    }
    queue.removeAt(i);
    final at = index;
    if (at != null && i < at) {
      index = at - 1;
      _emit();
    }
  }

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

  /// How long [next] takes to report the new entry after it returns, as
  /// libmpv does from its own thread. Null reports it straight away.
  Duration? reportNextAfter;

  @override
  Future<void> next() async {
    index = (index ?? 0) + 1;
    final after = reportNextAfter;
    if (after == null) {
      _emit();
    } else {
      Timer(after, _emit);
    }
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
  QueueInfo? queueInfo;
  bool gapless = true;
  Duration crossfade = Duration.zero;
  int gainRefreshes = 0;

  @override
  Future<void> refreshGain() async => gainRefreshes++;
  @override
  Future<void> setGapless(bool enabled) async => gapless = enabled;
  @override
  Future<void> setCrossfade(Duration d) async => crossfade = d;

  bool ducked = false;
  @override
  Future<void> setDucked(bool d) async => ducked = d;

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
  bool needsLocalArt = false;
  @override
  Future<void> update(NowPlayingInfo info) async => shown.add(info);
  @override
  Future<void> clear() async => shown.add(null);
  @override
  Future<void> dispose() => _commands.close();
}

/// An OS audio session the test drives by hand.
class FakeAudioFocus implements AudioFocus {
  final _changes = StreamController<FocusChange>.broadcast(sync: true);

  void send(FocusChange change) => _changes.add(change);

  @override
  Stream<FocusChange> get changes => _changes.stream;
  @override
  Future<void> dispose() => _changes.close();
}

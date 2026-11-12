import 'lyrics.dart';
import 'models.dart';
import 'music_source.dart';
import 'offline_library.dart';
import 'play_queue.dart';
import 'playback_options.dart';
import 'server_route.dart';

/// A [MusicSource] that answers from the downloaded music while the app is
/// offline and from the server otherwise.
///
/// Everything that browses or searches the library goes through this, so
/// the screens, the voice search and Android Auto all show downloaded music
/// when there is no server, without knowing it. Anything that writes to the
/// server, or that downloads can't supply (similar tracks, biographies),
/// passes straight through, and fails the way it would for an unreachable
/// server.
class OfflineAwareSource implements MusicSource {
  OfflineAwareSource(
    this.inner, {
    required this.isOffline,
    required this.library,
  });

  final MusicSource inner;

  /// Whether to answer from downloads now. Asked on every call, so the
  /// source follows the app in and out of offline without being replaced.
  final bool Function() isOffline;
  final OfflineLibrary Function() library;

  bool get _offline => isOffline();

  // ---- Answered from downloads while offline ----------------------------

  @override
  Future<List<Artist>> getArtists() async =>
      _offline ? library().artists() : inner.getArtists();

  @override
  Future<ArtistDetail> getArtist(String id) async =>
      _offline ? library().artist(id) : inner.getArtist(id);

  @override
  Future<ArtistInfo> getArtistInfo(String id) async =>
      _offline ? const ArtistInfo() : inner.getArtistInfo(id);

  @override
  Future<List<Track>> getTopTracks(Artist artist, {int count = 10}) async =>
      _offline ? const [] : inner.getTopTracks(artist, count: count);

  @override
  Future<List<Track>> getSimilarTracks(String id, {int count = 50}) async =>
      _offline ? const [] : inner.getSimilarTracks(id, count: count);

  @override
  Future<List<Album>> getAlbums({
    AlbumSort sort = AlbumSort.alphabetical,
    int size = 100,
    int offset = 0,
  }) async => _offline
      ? library().albums(sort: sort, size: size, offset: offset)
      : inner.getAlbums(sort: sort, size: size, offset: offset);

  @override
  Future<AlbumDetail> getAlbum(String id) async =>
      _offline ? library().album(id) : inner.getAlbum(id);

  @override
  Future<Track> getTrack(String id) async {
    if (!_offline) return inner.getTrack(id);
    final t = library().track(id);
    if (t == null) throw StateError('Not downloaded');
    return t;
  }

  @override
  Future<SearchResults> search(String query, {int limit = 20}) async => _offline
      ? library().search(query, limit: limit)
      : inner.search(query, limit: limit);

  @override
  Future<List<Playlist>> getPlaylists() async =>
      _offline ? library().playlists() : inner.getPlaylists();

  @override
  Future<PlaylistDetail> getPlaylist(String id) async =>
      _offline ? library().playlist(id) : inner.getPlaylist(id);

  @override
  Future<List<Track>> getRandomTracks({int size = 100, String? genre}) async =>
      _offline
      ? library().random(size: size, genre: genre)
      : inner.getRandomTracks(size: size, genre: genre);

  @override
  Future<List<Track>> getLikedTracks() async =>
      _offline ? library().liked() : inner.getLikedTracks();

  @override
  Future<List<Artist>> getLikedArtists() async =>
      _offline ? const [] : inner.getLikedArtists();

  @override
  Future<Lyrics> getLyrics(Track track) async =>
      _offline ? Lyrics.none : inner.getLyrics(track);

  // ---- Everything else goes to the server -------------------------------

  @override
  String get serverId => inner.serverId;
  @override
  String get displayName => inner.displayName;
  @override
  String get userName => inner.userName;
  @override
  SourceCapabilities get capabilities => inner.capabilities;
  @override
  Future<SourceCapabilities> detectCapabilities() => inner.detectCapabilities();
  @override
  Future<void> ping() => inner.ping();
  @override
  ServerRoute get route => inner.route;
  @override
  Stream<ServerRoute> get routeChanges => inner.routeChanges;
  @override
  Stream<void> get loginRejected => inner.loginRejected;
  @override
  Future<void> connect() => inner.connect();
  @override
  void reportUnreachable() => inner.reportUnreachable();

  @override
  Future<Playlist> createPlaylist(
    String name, {
    List<String> trackIds = const [],
  }) => inner.createPlaylist(name, trackIds: trackIds);
  @override
  Future<void> renamePlaylist(String id, String name) =>
      inner.renamePlaylist(id, name);
  @override
  Future<void> addToPlaylist(String id, List<String> trackIds) =>
      inner.addToPlaylist(id, trackIds);
  @override
  Future<void> removeFromPlaylist(String id, List<int> indexes) =>
      inner.removeFromPlaylist(id, indexes);
  @override
  Future<void> replacePlaylistTracks(String id, List<String> trackIds) =>
      inner.replacePlaylistTracks(id, trackIds);
  @override
  Future<void> deletePlaylist(String id) => inner.deletePlaylist(id);

  @override
  Future<void> setLiked(
    String id,
    bool liked, {
    LikeTarget target = LikeTarget.track,
  }) => inner.setLiked(id, liked, target: target);
  @override
  Future<void> setRating(String id, int rating) => inner.setRating(id, rating);

  @override
  Future<void> reportPlayback(String trackId, {required bool submission}) =>
      inner.reportPlayback(trackId, submission: submission);
  @override
  Future<void> reportPlaybackState(
    String trackId,
    PlaybackPhase phase,
    Duration position,
  ) => inner.reportPlaybackState(trackId, phase, position);

  @override
  Future<SavedQueue?> getPlayQueue() => inner.getPlayQueue();
  @override
  Future<void> savePlayQueue(
    List<String> trackIds, {
    int? currentIndex,
    Duration position = Duration.zero,
  }) => inner.savePlayQueue(
    trackIds,
    currentIndex: currentIndex,
    position: position,
  );

  @override
  Uri streamUrl(
    String trackId, {
    StreamQuality quality = StreamQuality.original,
    Duration offset = Duration.zero,
  }) => inner.streamUrl(trackId, quality: quality, offset: offset);
  @override
  Uri? coverArtUrl(String? coverArtId, {int size = 300}) =>
      inner.coverArtUrl(coverArtId, size: size);

  @override
  void close() => inner.close();
}

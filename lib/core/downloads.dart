import 'models.dart';
import 'music_source.dart';
import 'playback_options.dart';
import 'track_cache.dart';
import 'track_resolver.dart';

/// What a download was asked for. A pin keeps the whole thing on the
/// device and, once auto-sync arrives, follows it as it changes on the
/// server.
enum PinKind { album, playlist, artist, liked }

/// One thing the user chose to keep on the device: an album, a playlist,
/// an artist or their liked tracks. Several pins can hold the same track;
/// its file is kept while any of them does.
class Pin {
  final PinKind kind;

  /// The server's id for the album, playlist or artist. Liked tracks have
  /// no id of their own, so they use [likedItemId].
  final String itemId;
  final String name;
  final String? coverArt;

  /// The tracks the item had when it was last read, in order.
  final List<Track> tracks;
  final DateTime pinnedAt;

  const Pin({
    required this.kind,
    required this.itemId,
    required this.name,
    this.coverArt,
    required this.tracks,
    required this.pinnedAt,
  });

  static const likedItemId = 'liked';

  String get key => keyFor(kind, itemId);

  static String keyFor(PinKind kind, String itemId) => '${kind.name}:$itemId';

  Pin copyWith({String? name, String? coverArt, List<Track>? tracks}) => Pin(
    kind: kind,
    itemId: itemId,
    name: name ?? this.name,
    coverArt: coverArt ?? this.coverArt,
    tracks: tracks ?? this.tracks,
    pinnedAt: pinnedAt,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'itemId': itemId,
    'name': name,
    'coverArt': ?coverArt,
    'pinnedAt': pinnedAt.toUtc().toIso8601String(),
    'tracks': [for (final t in tracks) t.toJson()],
  };

  static Pin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = PinKind.values.where((k) => k.name == raw['kind']).firstOrNull;
    final itemId = raw['itemId'];
    final name = raw['name'];
    final tracks = raw['tracks'];
    if (kind == null || itemId is! String || name is! String) return null;
    if (tracks is! List) return null;
    return Pin(
      kind: kind,
      itemId: itemId,
      name: name,
      coverArt: raw['coverArt'] is String ? raw['coverArt'] as String : null,
      tracks: [for (final t in tracks) ?Track.fromJson(t)],
      pinnedAt:
          DateTime.tryParse('${raw['pinnedAt']}') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// How downloads are fetched. Applies to tracks downloaded from now on.
class DownloadOptions {
  final StreamQuality quality;

  /// Whether downloading waits for Wi-Fi when the phone is on mobile data.
  final bool wifiOnly;

  const DownloadOptions({
    this.quality = StreamQuality.original,
    this.wifiOnly = true,
  });

  DownloadOptions copyWith({StreamQuality? quality, bool? wifiOnly}) =>
      DownloadOptions(
        quality: quality ?? this.quality,
        wifiOnly: wifiOnly ?? this.wifiOnly,
      );
}

/// Why a download did not finish.
enum DownloadFailure {
  /// The server could not be reached, at either address.
  unreachable,

  /// The server answered but would not send the track (it is gone, or the
  /// server returned an error).
  server,

  /// The device has no room for the file.
  storageFull,

  /// The download was cancelled on purpose.
  cancelled,

  /// The server turned the login down. Every other track would be refused
  /// the same way, and each refusal counts as a failed login (Navidrome
  /// locks the account for a while after a run of them), so downloading
  /// stops until the server accepts the login again.
  login,
}

/// The Subsonic error code in an error reply's body (JSON or XML), or null
/// when there is none.
int? subsonicErrorCode(String body) {
  final m = RegExp(r'"code"\s*:\s*(\d+)|code="(\d+)"').firstMatch(body);
  final n = m?[1] ?? m?[2];
  return n == null ? null : int.tryParse(n);
}

/// Whether a reply means the login itself was refused: HTTP 401 or 403, or
/// a Subsonic error 40 (wrong credentials), 41 (token login not allowed)
/// or 44 (bad API key).
bool isLoginRefusal({int? status, int? code}) =>
    status == 401 || status == 403 || code == 40 || code == 41 || code == 44;

class DownloadException implements Exception {
  final DownloadFailure kind;
  final String message;
  const DownloadException(this.kind, this.message);

  @override
  String toString() => message;
}

/// Lets the manager stop a download that is under way.
class FetchCancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Everything downloaded for offline use: the pins, the tracks' files and
/// their saved details. All of it is kept per server, so signing out of one
/// server (or, later, several servers) never touches another's.
///
/// This is not the playback cache: nothing here is ever evicted to make
/// room. Files go only when no pin holds them any more.
abstract class DownloadStore {
  /// Every pin saved for [serverId].
  Future<List<Pin>> pins(String serverId);

  Future<void> savePin(String serverId, Pin pin);

  /// Forgets a pin. The files its tracks used stay until [retain] or
  /// [removeTrack] says no pin needs them.
  Future<void> removePin(String serverId, String pinKey);

  /// Whether the track's file is complete on the device.
  bool has(String serverId, String trackId);

  /// The file to play, or null when the track is not downloaded.
  Uri? fileUri(String serverId, String trackId);

  /// Downloads a track to the device. [upstream] is asked for each time a
  /// connection is made, so a move between the server's home and away
  /// addresses carries on from the byte the download had reached.
  /// [extension] names the file's type; [variant] names the quality, so a
  /// half-finished file is only resumed at the same quality.
  ///
  /// Throws [DownloadException].
  Future<void> fetch(
    String serverId,
    String trackId, {
    required Uri Function() upstream,
    required String extension,
    required String variant,
    required FetchCancel cancel,
    void Function()? onUnreachable,
    void Function(int received, int? total)? onProgress,
  });

  Future<void> removeTrack(String serverId, String trackId);

  /// Deletes every file for [serverId] that is not in [keep], and any
  /// half-finished one, such as left behind by a crash.
  Future<void> retain(String serverId, Set<String> keep);

  /// Deletes everything downloaded for [serverId], pins included.
  Future<void> removeServer(String serverId);

  /// Disk used by [serverId]'s downloads.
  Future<int> usageBytes(String serverId);

  /// Fires when a file finishes or is removed.
  Stream<void> get changes;
}

/// Plays a downloaded track from its file and hands every other track to
/// [inner], which streams it as before. Downloaded tracks skip the
/// playback cache, since they are already on disk.
class DownloadedTrackResolver implements TrackResolver {
  final TrackResolver inner;
  final DownloadStore store;
  final MusicSource source;

  const DownloadedTrackResolver(this.inner, this.store, this.source);

  bool _local(Track track) => store.has(source.serverId, track.id);

  @override
  Future<Uri> resolve(Track track) async =>
      store.fileUri(source.serverId, track.id) ?? await inner.resolve(track);

  @override
  CacheRequest? cacheRequest(Track track) =>
      _local(track) ? null : inner.cacheRequest(track);

  @override
  Uri? resolveFrom(Track track, Duration offset) =>
      _local(track) ? null : inner.resolveFrom(track, offset);
}

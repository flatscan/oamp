import 'models.dart';

/// A play queue saved to resume later: on this device after a restart, or
/// on another device through the server.
class SavedQueue {
  final List<Track> tracks;

  /// The entry that was playing. An index rather than a track id, so a
  /// queue that lists a track twice resumes at the right one.
  final int? currentIndex;

  /// How far into the current track playback had got.
  final Duration position;

  /// When the queue was saved, or null when unknown.
  final DateTime? changed;

  /// The client that saved it, as the server reports it.
  final String? changedBy;

  /// Where the queue came from, such as an album name.
  final String? from;

  /// Whether the queue was started by playing a whole album in order, which
  /// decides the endless play mode. Only kept on this device.
  final bool albumQueue;

  /// Positions in [tracks] that endless play added. Only kept on this
  /// device.
  final Set<int> endless;

  const SavedQueue({
    this.tracks = const [],
    this.currentIndex,
    this.position = Duration.zero,
    this.changed,
    this.changedBy,
    this.from,
    this.albumQueue = false,
    this.endless = const {},
  });

  bool get isEmpty => tracks.isEmpty;

  Track? get current =>
      currentIndex != null &&
          currentIndex! >= 0 &&
          currentIndex! < tracks.length
      ? tracks[currentIndex!]
      : null;

  /// Identifies what the queue holds and where it stands, ignoring
  /// metadata and timestamps, to tell whether two copies are the same.
  String get fingerprint =>
      '${tracks.map((t) => t.id).join(',')}'
      '|${current?.id}|${position.inMilliseconds}';

  /// Like [fingerprint] but without the position.
  String get contentFingerprint =>
      '${tracks.map((t) => t.id).join(',')}|${current?.id}';

  /// Like [contentFingerprint], plus what only this device keeps, to tell
  /// whether its saved copy needs rewriting.
  String get localFingerprint =>
      '$contentFingerprint|$from|$albumQueue'
      '|${(endless.toList()..sort()).join(',')}';

  SavedQueue copyWith({
    int? currentIndex,
    Duration? position,
    DateTime? changed,
    String? from,
  }) => SavedQueue(
    tracks: tracks,
    currentIndex: currentIndex ?? this.currentIndex,
    position: position ?? this.position,
    changed: changed ?? this.changed,
    changedBy: changedBy,
    from: from ?? this.from,
    albumQueue: albumQueue,
    endless: endless,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'tracks': [for (final t in tracks) trackToJson(t)],
    'index': ?currentIndex,
    'positionMs': position.inMilliseconds,
    'changed': ?changed?.toUtc().toIso8601String(),
    'from': ?from,
    if (albumQueue) 'album': true,
    if (endless.isNotEmpty) 'endless': (endless.toList()..sort()),
  };

  static SavedQueue? fromJson(Map<String, Object?> j) {
    if (j['v'] != 1) return null;
    final tracks = [
      for (final t in (j['tracks'] as List? ?? const []))
        if (t is Map) ?trackFromJson(t.cast<String, Object?>()),
    ];
    return SavedQueue(
      tracks: tracks,
      currentIndex: j['index'] as int?,
      position: Duration(milliseconds: (j['positionMs'] as int?) ?? 0),
      changed: DateTime.tryParse('${j['changed']}'),
      from: j['from'] as String?,
      albumQueue: j['album'] == true,
      endless: {
        for (final i in (j['endless'] as List? ?? const []))
          if (i is int && i >= 0 && i < tracks.length) i,
      },
    );
  }

  /// A track as JSON for the saved queue. Only set fields are written.
  static Map<String, Object?> trackToJson(Track t) => {
    'id': t.id,
    'title': t.title,
    'artist': ?t.artist,
    'artistId': ?t.artistId,
    'album': ?t.album,
    'albumId': ?t.albumId,
    'track': ?t.track,
    'disc': ?t.discNumber,
    'durationMs': ?t.duration?.inMilliseconds,
    'coverArt': ?t.coverArt,
    if (t.liked) 'liked': true,
    'year': ?t.year,
    'format': ?t.format,
    'bitRate': ?t.bitRate,
    'sampleRate': ?t.sampleRate,
    'bitDepth': ?t.bitDepth,
    if (t.replayGain case final rg?)
      'replayGain': {
        'trackGain': ?rg.trackGain,
        'albumGain': ?rg.albumGain,
        'trackPeak': ?rg.trackPeak,
        'albumPeak': ?rg.albumPeak,
      },
  };

  static Track? trackFromJson(Map<String, Object?> j) {
    final id = j['id'];
    if (id is! String) return null;
    double? d(Object? v) => v is num ? v.toDouble() : null;
    final rg = j['replayGain'];
    final ms = j['durationMs'] as int?;
    return Track(
      id: id,
      title: (j['title'] as String?) ?? 'Unknown track',
      artist: j['artist'] as String?,
      artistId: j['artistId'] as String?,
      album: j['album'] as String?,
      albumId: j['albumId'] as String?,
      track: j['track'] as int?,
      discNumber: j['disc'] as int?,
      duration: ms == null ? null : Duration(milliseconds: ms),
      coverArt: j['coverArt'] as String?,
      liked: j['liked'] == true,
      year: j['year'] as int?,
      format: j['format'] as String?,
      bitRate: j['bitRate'] as int?,
      sampleRate: j['sampleRate'] as int?,
      bitDepth: j['bitDepth'] as int?,
      replayGain: rg is Map
          ? ReplayGain(
              trackGain: d(rg['trackGain']),
              albumGain: d(rg['albumGain']),
              trackPeak: d(rg['trackPeak']),
              albumPeak: d(rg['albumPeak']),
            )
          : null,
    );
  }
}

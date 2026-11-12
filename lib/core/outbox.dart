import 'models.dart';
import 'music_source.dart';

/// What a saved report is about.
enum OutboxKind { play, like, rating }

/// Something the user did that the server has not heard about yet: a track
/// played, a like or a star rating. Holds only ids and times.
class OutboxEntry {
  final OutboxKind kind;

  /// The track, album or artist the report is about.
  final String id;

  /// When it happened. A play is sent with this time.
  final DateTime at;

  /// For [OutboxKind.like]: the new state, and what was liked.
  final bool liked;
  final LikeTarget target;

  /// For [OutboxKind.rating]: 0 to 5, 0 clearing it.
  final int rating;

  const OutboxEntry({
    required this.kind,
    required this.id,
    required this.at,
    this.liked = false,
    this.target = LikeTarget.track,
    this.rating = 0,
  });

  factory OutboxEntry.play(String trackId, DateTime at) =>
      OutboxEntry(kind: OutboxKind.play, id: trackId, at: at);

  factory OutboxEntry.like(
    String id,
    bool liked,
    LikeTarget target,
    DateTime at,
  ) => OutboxEntry(
    kind: OutboxKind.like,
    id: id,
    at: at,
    liked: liked,
    target: target,
  );

  factory OutboxEntry.rating(String id, int rating, DateTime at) =>
      OutboxEntry(kind: OutboxKind.rating, id: id, at: at, rating: rating);

  /// Two entries with the same key are about the same thing, so the later
  /// one replaces the earlier. Plays are all kept.
  String? get replaceKey => switch (kind) {
    OutboxKind.play => null,
    OutboxKind.like => 'like:${target.name}:$id',
    OutboxKind.rating => 'rating:$id',
  };

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    'at': at.millisecondsSinceEpoch,
    if (kind == OutboxKind.like) ...{'liked': liked, 'target': target.name},
    if (kind == OutboxKind.rating) 'rating': rating,
  };

  static OutboxEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = OutboxKind.values
        .where((k) => k.name == raw['kind'])
        .firstOrNull;
    final id = raw['id'];
    final at = raw['at'];
    if (kind == null || id is! String || at is! int) return null;
    final target =
        LikeTarget.values.where((t) => t.name == raw['target']).firstOrNull ??
        LikeTarget.track;
    return OutboxEntry(
      kind: kind,
      id: id,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      liked: raw['liked'] == true,
      target: target,
      rating: raw['rating'] is int ? (raw['rating'] as int).clamp(0, 5) : 0,
    );
  }
}

/// What to do about a report that did not get through.
enum OutboxFailure {
  /// Try again later: the server could not be reached or had a problem.
  retry,

  /// The login was refused. Keep the report; signing in again fixes it.
  keep,

  /// The server will never take this report, such as for a track that was
  /// deleted.
  drop,
}

OutboxFailure classifyFailure(Object e) {
  if (e is! MusicSourceException) return OutboxFailure.retry;
  return switch (e.kind) {
    MusicSourceErrorKind.unreachable ||
    MusicSourceErrorKind.server => OutboxFailure.retry,
    MusicSourceErrorKind.auth => OutboxFailure.keep,
    MusicSourceErrorKind.notFound ||
    MusicSourceErrorKind.notAServer ||
    MusicSourceErrorKind.other => OutboxFailure.drop,
  };
}

/// Sends one saved report.
Future<void> deliverEntry(MusicSource source, OutboxEntry e) async {
  switch (e.kind) {
    case OutboxKind.play:
      await source.reportPlayback(e.id, submission: true, at: e.at);
    case OutboxKind.like:
      await source.setLiked(e.id, e.liked, target: e.target);
    case OutboxKind.rating:
      await source.setRating(e.id, e.rating);
  }
}

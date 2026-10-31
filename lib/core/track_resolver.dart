import 'models.dart';
import 'music_source.dart';

/// Turns a track into something the audio engine can play.
///
/// In v1 this is always the server's stream URL. Offline downloads (v2) add
/// a resolver that returns a local file URI when the track is downloaded and
/// falls back to streaming otherwise; nothing else in the player changes.
abstract class TrackResolver {
  Future<Uri> resolve(Track track);
}

class StreamingTrackResolver implements TrackResolver {
  final MusicSource source;
  const StreamingTrackResolver(this.source);

  @override
  Future<Uri> resolve(Track track) async => source.streamUrl(track.id);
}

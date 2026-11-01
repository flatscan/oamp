import 'dart:math' as math;

import 'models.dart';

/// The codec a server is asked to transcode to.
enum StreamFormat {
  /// The file as stored, with no transcoding.
  original,
  opus,
  mp3,
}

/// What a [MusicSource] is asked to stream. Backend neutral: each source
/// maps it to its own stream parameters.
class StreamQuality {
  final StreamFormat format;

  /// Upper limit in kilobits per second. Only used when [format] is not
  /// [StreamFormat.original].
  final int bitRate;

  const StreamQuality({
    this.format = StreamFormat.original,
    this.bitRate = 320,
  });

  static const original = StreamQuality();

  /// Bit rates offered for transcoded streams, best first.
  static const bitRates = [320, 256, 192, 160, 128, 96, 64];

  bool get isOriginal => format == StreamFormat.original;

  /// Short stable tag, used in cache keys so a track cached at one quality
  /// is never served for another.
  String get tag => isOriginal ? 'raw' : '${format.name}$bitRate';

  @override
  bool operator ==(Object other) =>
      other is StreamQuality &&
      other.format == format &&
      (isOriginal || other.bitRate == bitRate);

  @override
  int get hashCode =>
      isOriginal ? format.hashCode : Object.hash(format, bitRate);
}

/// Which ReplayGain value levels the volume.
enum ReplayGainMode {
  off,

  /// Every track at the same loudness.
  track,

  /// Albums keep their own dynamics: tracks on one album are levelled
  /// together. Falls back to the track value when there is no album value.
  album,
}

/// How playback sounds. Everything here is applied while playing, without
/// restarting the queue.
class PlaybackOptions {
  final bool gapless;

  /// Zero means no crossfade.
  final Duration crossfade;

  /// Whether consecutive tracks from the same album are crossfaded. Off by
  /// default, so albums meant to run together play gaplessly.
  final bool crossfadeSameAlbum;

  final ReplayGainMode replayGain;

  /// Extra gain in decibels applied on top of ReplayGain.
  final double preampDb;

  /// Gain in decibels for tracks with no ReplayGain data.
  final double fallbackGainDb;

  /// Whether a track's peak may limit its gain so it never clips.
  final bool preventClipping;

  const PlaybackOptions({
    this.gapless = true,
    this.crossfade = Duration.zero,
    this.crossfadeSameAlbum = false,
    this.replayGain = ReplayGainMode.off,
    this.preampDb = 0,
    this.fallbackGainDb = 0,
    this.preventClipping = true,
  });

  /// Crossfade lengths offered in settings, in seconds.
  static const crossfadeSeconds = [0, 2, 4, 6, 8, 10, 12];

  /// Whether to crossfade from [from] into [to].
  bool shouldCrossfade(Track from, Track to) {
    if (crossfade <= Duration.zero) return false;
    if (crossfadeSameAlbum) return true;
    final a = from.albumId, b = to.albumId;
    return a == null || a != b;
  }

  /// The linear volume factor for [track]: 1 leaves it alone, 0.5 is about
  /// 6 dB quieter. Can be above 1 for quiet tracks; the engine caps it at
  /// what its output can do.
  double gainFor(Track track) {
    if (replayGain == ReplayGainMode.off) return 1;
    final rg = track.replayGain;
    double? db;
    double? peak;
    if (rg != null) {
      if (replayGain == ReplayGainMode.album && rg.albumGain != null) {
        db = rg.albumGain;
        peak = rg.albumPeak ?? rg.trackPeak;
      } else {
        db = rg.trackGain ?? rg.albumGain;
        peak = rg.trackPeak ?? rg.albumPeak;
      }
    }
    var factor = math
        .pow(10, ((db ?? fallbackGainDb) + preampDb) / 20)
        .toDouble();
    if (preventClipping && db != null && peak != null && peak > 0) {
      factor = math.min(factor, 1 / peak);
    }
    return factor;
  }

  PlaybackOptions copyWith({
    bool? gapless,
    Duration? crossfade,
    bool? crossfadeSameAlbum,
    ReplayGainMode? replayGain,
    double? preampDb,
    double? fallbackGainDb,
    bool? preventClipping,
  }) => PlaybackOptions(
    gapless: gapless ?? this.gapless,
    crossfade: crossfade ?? this.crossfade,
    crossfadeSameAlbum: crossfadeSameAlbum ?? this.crossfadeSameAlbum,
    replayGain: replayGain ?? this.replayGain,
    preampDb: preampDb ?? this.preampDb,
    fallbackGainDb: fallbackGainDb ?? this.fallbackGainDb,
    preventClipping: preventClipping ?? this.preventClipping,
  );
}

/// How many upcoming tracks to keep ready on disk, and how much disk the
/// cache may use. This is a temporary playback cache: files are evicted
/// oldest first and nothing in it counts as downloaded for offline use.
class CacheOptions {
  /// Upcoming tracks to fetch ahead of playback. Zero turns pre-caching off.
  final int precacheTracks;

  final int limitMb;

  const CacheOptions({this.precacheTracks = 3, this.limitMb = 1024});

  static const precacheChoices = [0, 1, 3, 5, 10, 25];
  static const limitChoicesMb = [256, 512, 1024, 2048, 5120, 10240];

  int get limitBytes => limitMb * 1024 * 1024;

  CacheOptions copyWith({int? precacheTracks, int? limitMb}) => CacheOptions(
    precacheTracks: precacheTracks ?? this.precacheTracks,
    limitMb: limitMb ?? this.limitMb,
  );
}

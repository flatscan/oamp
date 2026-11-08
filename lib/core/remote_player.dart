/// Playing on a speaker or TV over the network.
///
/// [RemotePlayer] is what each protocol (Cast, DLNA) implements in
/// lib/outputs. It holds at most two tracks: the one playing and the one
/// after it, so the device can move on by itself without a gap while the
/// app tops it up. The queue itself stays in the app (see `RemoteEngine`).
library;

import 'models.dart';
import 'music_source.dart';
import 'output_device.dart';
import 'playback_options.dart';

/// A track as a device fetches and shows it.
class RemoteMedia {
  /// Where the device streams it from: the server itself, never the app's
  /// local cache, which the device cannot reach.
  final Uri url;

  /// MIME type of what [url] returns, such as `audio/flac`.
  final String contentType;

  final String title;
  final String? artist;
  final String? album;
  final Uri? artwork;
  final Duration? duration;

  /// Transcoded by the server, so the stream usually can't be seeked.
  final bool transcoded;

  const RemoteMedia({
    required this.url,
    required this.contentType,
    required this.title,
    this.artist,
    this.album,
    this.artwork,
    this.duration,
    this.transcoded = false,
  });

  @override
  bool operator ==(Object other) =>
      other is RemoteMedia &&
      other.url == url &&
      other.contentType == contentType;

  @override
  int get hashCode => Object.hash(url, contentType);
}

/// Formats each protocol plays as they are, by the server's file
/// extension, with the MIME type to announce them as. Anything else is
/// transcoded to MP3 by the server.
///
/// Cast devices all play these (Google's supported media list). DLNA
/// renderers vary; MP3, FLAC, AAC and WAV are the ones nearly all of them
/// take.
const _castFormats = {
  'mp3': 'audio/mpeg',
  'flac': 'audio/flac',
  'm4a': 'audio/mp4',
  'mp4': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'opus': 'audio/ogg',
  'wav': 'audio/wav',
};

const _dlnaFormats = {
  'mp3': 'audio/mpeg',
  // The type DLNA renderers list for FLAC; some (Samsung TVs) don't list
  // audio/flac at all.
  'flac': 'audio/x-flac',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
};

/// What MP3 transcoding asks for when a device can't play the original.
const remoteTranscode = StreamQuality(format: StreamFormat.mp3, bitRate: 320);

/// How [track] is sent to a device that speaks [protocol]: the original
/// file when the device plays its format, otherwise MP3 from the server.
///
/// Originals are preferred because they can be seeked by byte range;
/// transcoded streams usually can't be.
RemoteMedia remoteMediaFor(
  Track track,
  MusicSource source,
  OutputProtocol protocol,
) {
  final formats = switch (protocol) {
    OutputProtocol.cast => _castFormats,
    OutputProtocol.dlna => _dlnaFormats,
  };
  final type = formats[track.format?.toLowerCase()];
  return RemoteMedia(
    url: type == null
        ? source.streamUrl(track.id, quality: remoteTranscode)
        : source.streamUrl(track.id),
    contentType: type ?? 'audio/mpeg',
    title: track.title,
    artist: track.artist,
    album: track.album,
    artwork: source.coverArtUrl(track.coverArt, size: 600),
    duration: track.duration,
    transcoded: type == null,
  );
}

enum RemoteState { idle, buffering, playing, paused }

/// What a device says it is doing.
class RemoteStatus {
  final RemoteState state;
  final Duration position;
  final Duration? duration;

  /// The device finished the current track with nothing after it.
  final bool ended;

  /// The device's own volume from 0 to 1, when it says.
  final double? volume;

  const RemoteStatus({
    this.state = RemoteState.idle,
    this.position = Duration.zero,
    this.duration,
    this.ended = false,
    this.volume,
  });
}

/// One connected speaker or TV.
abstract class RemotePlayer {
  OutputDevice get device;

  /// Updates at least once a second while something is loaded.
  Stream<RemoteStatus> get status;

  /// Fires when the device moved on to the track given as `next` by
  /// itself. That track is now the current one, and there is no next until
  /// [setNext] gives one.
  Stream<void> get advanced;

  /// Completes when the connection is gone: the device was switched off,
  /// left the network, or another app took it over. Never completes with
  /// an error.
  Future<void> get closed;

  /// Plays [current] from [position], or holds it paused there when [play]
  /// is false, with [next] lined up to follow.
  Future<void> load(
    RemoteMedia current, {
    RemoteMedia? next,
    Duration position = Duration.zero,
    bool play = true,
  });

  /// Lines up the track to play after the current one, or none.
  Future<void> setNext(RemoteMedia? next);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Stops playback and unloads the track.
  Future<void> stop();

  Future<void> setVolume(double volume);

  /// Disconnects. With [stopPlayback], the device stops too (and a Cast
  /// device closes the receiver app); otherwise it carries on by itself.
  Future<void> close({bool stopPlayback = true});
}

/// Opens a connection to a device.
typedef RemoteConnector = Future<RemotePlayer> Function(OutputDevice device);

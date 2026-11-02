import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../core/track_cache.dart';
import 'audio_engine.dart';
import 'just_audio_deck.dart';
import 'mpv_deck.dart';
import 'stream_cache.dart';

/// Picks the player for this platform. just_audio has no Windows player,
/// so libmpv (through media_kit) plays there; Android, iOS and macOS use
/// just_audio's own players.
AudioDeck Function() createDeckFactory() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    MediaKit.ensureInitialized();
    return MpvDeck.new;
  }
  return JustAudioDeck.new;
}

/// Opens the playback cache in the app's cache folder, or returns null
/// (tracks then stream directly) when that is not possible.
Future<TrackCache?> openTrackCache() async {
  if (kIsWeb) return null;
  try {
    final base = await getApplicationCacheDirectory();
    return await HttpTrackCache.open(
      Directory('${base.path}${Platform.pathSeparator}stream_cache'),
    );
  } catch (e) {
    debugPrint('Playback cache unavailable: $e');
    return null;
  }
}

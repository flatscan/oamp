import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'system_controls.dart';

/// What the Android home screen widget shows. Only what the widget draws,
/// so position ticks and queue changes don't redraw it.
@immutable
class HomeWidgetState {
  final String title;
  final String? artist;

  /// The cover as a file in the artwork cache, or null for none.
  final String? artPath;
  final bool playing;
  final bool canGoNext;
  final bool canGoPrevious;

  const HomeWidgetState({
    required this.title,
    this.artist,
    this.artPath,
    this.playing = false,
    this.canGoNext = false,
    this.canGoPrevious = false,
  });

  factory HomeWidgetState.from(NowPlayingInfo info) => HomeWidgetState(
    title: info.title,
    artist: info.artist,
    artPath: artPathOf(info.artUri),
    playing: info.playing,
    canGoNext: info.canGoNext,
    canGoPrevious: info.canGoPrevious,
  );

  /// Only covers already on disk are passed on: the widget is drawn by the
  /// launcher, and must never be handed the signed server URL.
  @visibleForTesting
  static String? artPathOf(Uri? art) =>
      art != null && art.scheme == 'file' ? art.toFilePath() : null;

  Map<String, Object?> toMap() => {
    'title': title,
    'artist': artist,
    'art': artPath,
    'playing': playing,
    'canGoNext': canGoNext,
    'canGoPrevious': canGoPrevious,
  };

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetState &&
      other.title == title &&
      other.artist == artist &&
      other.artPath == artPath &&
      other.playing == playing &&
      other.canGoNext == canGoNext &&
      other.canGoPrevious == canGoPrevious;

  @override
  int get hashCode =>
      Object.hash(title, artist, artPath, playing, canGoNext, canGoPrevious);
}

/// Keeps OAmp's home screen widget (NowPlayingWidget.kt) in step with the
/// player. MainActivity answers on `oamp/widget`. The widget's buttons go
/// straight to the media session, so they arrive as ordinary
/// [MediaCommand]s; this class only tells the widget what to draw.
class AndroidHomeWidget {
  static const _channel = MethodChannel('oamp/widget');

  final Future<void> Function(HomeWidgetState? state) _send;

  /// What the widget was last told, so unchanged state isn't sent again.
  /// Null when it shows "nothing playing".
  HomeWidgetState? _shown;
  bool _cleared = false;

  AndroidHomeWidget({Future<void> Function(HomeWidgetState? state)? send})
    : _send = send ?? _sendToPlatform;

  static Future<void> _sendToPlatform(HomeWidgetState? state) => state == null
      ? _channel.invokeMethod<void>('clear')
      : _channel.invokeMethod<void>('show', state.toMap());

  void show(NowPlayingInfo info) {
    final state = HomeWidgetState.from(info);
    if (state == _shown) return;
    _shown = state;
    _cleared = false;
    _deliver(state);
  }

  void clear() {
    if (_cleared) return;
    _shown = null;
    _cleared = true;
    _deliver(null);
  }

  void _deliver(HomeWidgetState? state) {
    // The widget is a nice-to-have: a failure (no widget support, or the
    // engine running without the app's channels) never reaches the player.
    unawaited(
      _send(state).then(
        (_) {},
        onError: (Object e) =>
            debugPrint('Updating the home widget failed: $e'),
      ),
    );
  }
}

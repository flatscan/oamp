import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/playback_options.dart';
import '../platform/preferences.dart';

/// The settings store. main.dart overrides this with the platform store;
/// tests get an in-memory one.
final preferencesProvider = Provider<Preferences>((_) => MemoryPreferences());

class AppSettings {
  /// Whether the desktop window shows OAmp's title bar (drag strip and
  /// window buttons). Hidden, the window is moved by dragging the top of
  /// the Home header or the now playing artwork.
  final bool showTitleBar;

  final PlaybackOptions playback;
  final StreamQuality quality;
  final CacheOptions cache;

  const AppSettings({
    this.showTitleBar = true,
    this.playback = const PlaybackOptions(),
    this.quality = StreamQuality.original,
    this.cache = const CacheOptions(),
  });

  AppSettings copyWith({
    bool? showTitleBar,
    PlaybackOptions? playback,
    StreamQuality? quality,
    CacheOptions? cache,
  }) => AppSettings(
    showTitleBar: showTitleBar ?? this.showTitleBar,
    playback: playback ?? this.playback,
    quality: quality ?? this.quality,
    cache: cache ?? this.cache,
  );
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// Narrow views, so the player only rebuilds for the settings it uses.
final playbackOptionsProvider = Provider<PlaybackOptions>(
  (ref) => ref.watch(settingsProvider.select((s) => s.playback)),
);
final streamQualityProvider = Provider<StreamQuality>(
  (ref) => ref.watch(settingsProvider.select((s) => s.quality)),
);
final cacheOptionsProvider = Provider<CacheOptions>(
  (ref) => ref.watch(settingsProvider.select((s) => s.cache)),
);

class SettingsNotifier extends Notifier<AppSettings> {
  static const _titleBarKey = 'oamp.window.showTitleBar';
  static const _gapless = 'oamp.playback.gapless';
  static const _crossfadeMs = 'oamp.playback.crossfadeMs';
  static const _crossfadeAlbum = 'oamp.playback.crossfadeSameAlbum';
  static const _rgMode = 'oamp.playback.replayGain';
  static const _rgPreamp = 'oamp.playback.replayGainPreampDb';
  static const _rgFallback = 'oamp.playback.replayGainFallbackDb';
  static const _rgClip = 'oamp.playback.replayGainPreventClipping';
  static const _format = 'oamp.stream.format';
  static const _bitRate = 'oamp.stream.maxBitRate';
  static const _precache = 'oamp.cache.precacheTracks';
  static const _cacheLimit = 'oamp.cache.limitMb';

  Preferences get _prefs => ref.read(preferencesProvider);

  static T _enum<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  @override
  AppSettings build() {
    final p = _prefs;
    const d = AppSettings();
    return AppSettings(
      showTitleBar: p.getBool(_titleBarKey) ?? true,
      playback: PlaybackOptions(
        gapless: p.getBool(_gapless) ?? d.playback.gapless,
        crossfade: Duration(
          milliseconds:
              p.getInt(_crossfadeMs) ?? d.playback.crossfade.inMilliseconds,
        ),
        crossfadeSameAlbum:
            p.getBool(_crossfadeAlbum) ?? d.playback.crossfadeSameAlbum,
        replayGain: _enum(
          ReplayGainMode.values,
          p.getString(_rgMode),
          d.playback.replayGain,
        ),
        preampDb: p.getDouble(_rgPreamp) ?? d.playback.preampDb,
        fallbackGainDb: p.getDouble(_rgFallback) ?? d.playback.fallbackGainDb,
        preventClipping: p.getBool(_rgClip) ?? d.playback.preventClipping,
      ),
      quality: StreamQuality(
        format: _enum(
          StreamFormat.values,
          p.getString(_format),
          StreamFormat.original,
        ),
        bitRate: p.getInt(_bitRate) ?? d.quality.bitRate,
      ),
      cache: CacheOptions(
        precacheTracks: p.getInt(_precache) ?? d.cache.precacheTracks,
        limitMb: p.getInt(_cacheLimit) ?? d.cache.limitMb,
      ),
    );
  }

  Future<void> setShowTitleBar(bool show) async {
    state = state.copyWith(showTitleBar: show);
    await _prefs.setBool(_titleBarKey, show);
  }

  Future<void> setPlayback(PlaybackOptions o) async {
    state = state.copyWith(playback: o);
    await Future.wait([
      _prefs.setBool(_gapless, o.gapless),
      _prefs.setInt(_crossfadeMs, o.crossfade.inMilliseconds),
      _prefs.setBool(_crossfadeAlbum, o.crossfadeSameAlbum),
      _prefs.setString(_rgMode, o.replayGain.name),
      _prefs.setDouble(_rgPreamp, o.preampDb),
      _prefs.setDouble(_rgFallback, o.fallbackGainDb),
      _prefs.setBool(_rgClip, o.preventClipping),
    ]);
  }

  Future<void> setQuality(StreamQuality q) async {
    state = state.copyWith(quality: q);
    await _prefs.setString(_format, q.format.name);
    await _prefs.setInt(_bitRate, q.bitRate);
  }

  Future<void> setCache(CacheOptions c) async {
    state = state.copyWith(cache: c);
    await _prefs.setInt(_precache, c.precacheTracks);
    await _prefs.setInt(_cacheLimit, c.limitMb);
  }
}

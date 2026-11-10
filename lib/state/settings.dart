import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/downloads.dart';
import '../core/playback_options.dart';
import '../platform/network_monitor.dart';
import '../platform/preferences.dart';

/// The settings store. main.dart overrides this with the platform store;
/// tests get an in-memory one.
final preferencesProvider = Provider<Preferences>((_) => MemoryPreferences());

class AppSettings {
  /// Whether the desktop window shows OAmp's title bar (drag strip and
  /// window buttons). Hidden, the window is moved by dragging the top of
  /// the Home header or the now playing artwork.
  final bool showTitleBar;

  /// Whether the now playing screen shows a debug line with the track's
  /// ReplayGain tags and applied gain.
  final bool showReplayGainDebug;

  /// Whether the play queue is saved to the server and picked up from it,
  /// so listening can carry on from another device. The queue is always
  /// saved on this device.
  final bool syncQueue;

  final PlaybackOptions playback;

  /// The quality on Wi-Fi, and everywhere [mobileQuality] doesn't apply.
  final StreamQuality quality;

  /// The quality on mobile data, or null for the same as [quality].
  final StreamQuality? mobileQuality;
  final CacheOptions cache;

  /// How tracks are downloaded for offline use.
  final DownloadOptions downloads;

  const AppSettings({
    this.showTitleBar = true,
    this.showReplayGainDebug = false,
    this.syncQueue = true,
    this.playback = const PlaybackOptions(),
    this.quality = StreamQuality.original,
    this.mobileQuality,
    this.cache = const CacheOptions(),
    this.downloads = const DownloadOptions(),
  });

  /// The quality to stream at on [network].
  StreamQuality qualityOn(NetworkKind network) =>
      network == NetworkKind.mobile ? (mobileQuality ?? quality) : quality;

  AppSettings copyWith({
    bool? showTitleBar,
    bool? showReplayGainDebug,
    bool? syncQueue,
    PlaybackOptions? playback,
    StreamQuality? quality,
    StreamQuality? Function()? mobileQuality,
    CacheOptions? cache,
    DownloadOptions? downloads,
  }) => AppSettings(
    showTitleBar: showTitleBar ?? this.showTitleBar,
    showReplayGainDebug: showReplayGainDebug ?? this.showReplayGainDebug,
    syncQueue: syncQueue ?? this.syncQueue,
    playback: playback ?? this.playback,
    quality: quality ?? this.quality,
    mobileQuality: mobileQuality == null ? this.mobileQuality : mobileQuality(),
    cache: cache ?? this.cache,
    downloads: downloads ?? this.downloads,
  );
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// Watches whether the device is on Wi-Fi or mobile data. main.dart
/// provides the platform's; elsewhere it is always Wi-Fi.
final networkMonitorProvider = Provider<NetworkMonitor>(
  (_) => const FixedNetworkMonitor(),
);

/// The network the device is on now.
final networkKindProvider = NotifierProvider<_NetworkKindNotifier, NetworkKind>(
  _NetworkKindNotifier.new,
);

class _NetworkKindNotifier extends Notifier<NetworkKind> {
  @override
  NetworkKind build() {
    final monitor = ref.watch(networkMonitorProvider);
    final sub = monitor.changes.listen((k) => state = k);
    ref.onDispose(sub.cancel);
    return monitor.current;
  }
}

/// Narrow views, so the player only rebuilds for the settings it uses.
final playbackOptionsProvider = Provider<PlaybackOptions>(
  (ref) => ref.watch(settingsProvider.select((s) => s.playback)),
);

/// The quality to stream at now: the mobile data quality while on mobile
/// data, otherwise the Wi-Fi one.
final streamQualityProvider = Provider<StreamQuality>((ref) {
  final network = ref.watch(networkKindProvider);
  return ref.watch(settingsProvider.select((s) => s.qualityOn(network)));
});
final syncQueueProvider = Provider<bool>(
  (ref) => ref.watch(settingsProvider.select((s) => s.syncQueue)),
);

/// The cache settings as they apply now: pre-caching is off on mobile data
/// when the listener turned it off there.
final cacheOptionsProvider = Provider<CacheOptions>((ref) {
  final cache = ref.watch(settingsProvider.select((s) => s.cache));
  final mobile = ref.watch(networkKindProvider) == NetworkKind.mobile;
  return mobile && !cache.precacheOnMobile
      ? cache.copyWith(precacheTracks: 0)
      : cache;
});

class SettingsNotifier extends Notifier<AppSettings> {
  static const _titleBarKey = 'oamp.window.showTitleBar';
  static const _rgDebugKey = 'oamp.debug.showReplayGain';
  static const _syncQueue = 'oamp.queue.sync';
  static const _gapless = 'oamp.playback.gapless';
  static const _crossfadeMs = 'oamp.playback.crossfadeMs';
  static const _crossfadeAlbum = 'oamp.playback.crossfadeSameAlbum';
  static const _rgMode = 'oamp.playback.replayGain';
  static const _rgPreamp = 'oamp.playback.replayGainPreampDb';
  static const _rgFallback = 'oamp.playback.replayGainFallbackDb';
  static const _rgClip = 'oamp.playback.replayGainPreventClipping';
  static const _format = 'oamp.stream.format';
  static const _bitRate = 'oamp.stream.maxBitRate';
  static const _mobileFormat = 'oamp.stream.mobile.format';
  static const _mobileBitRate = 'oamp.stream.mobile.maxBitRate';
  static const _precacheMobile = 'oamp.cache.precacheOnMobile';

  /// Stored as the mobile format when mobile data follows Wi-Fi.
  static const _sameAsWifi = 'sameAsWifi';
  static const _precache = 'oamp.cache.precacheTracks';
  static const _cacheLimit = 'oamp.cache.limitMb';
  static const _dlFormat = 'oamp.downloads.format';
  static const _dlBitRate = 'oamp.downloads.maxBitRate';
  static const _dlWifiOnly = 'oamp.downloads.wifiOnly';

  Preferences get _prefs => ref.read(preferencesProvider);

  static T _enum<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  @override
  AppSettings build() {
    final p = _prefs;
    const d = AppSettings();
    return AppSettings(
      showTitleBar: p.getBool(_titleBarKey) ?? true,
      showReplayGainDebug: p.getBool(_rgDebugKey) ?? false,
      syncQueue: p.getBool(_syncQueue) ?? true,
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
      mobileQuality: switch (p.getString(_mobileFormat)) {
        null || _sameAsWifi => null,
        final name => StreamQuality(
          format: _enum(StreamFormat.values, name, StreamFormat.original),
          bitRate: p.getInt(_mobileBitRate) ?? d.quality.bitRate,
        ),
      },
      cache: CacheOptions(
        precacheTracks: p.getInt(_precache) ?? d.cache.precacheTracks,
        limitMb: p.getInt(_cacheLimit) ?? d.cache.limitMb,
        precacheOnMobile:
            p.getBool(_precacheMobile) ?? d.cache.precacheOnMobile,
      ),
      downloads: DownloadOptions(
        quality: StreamQuality(
          format: _enum(
            StreamFormat.values,
            p.getString(_dlFormat),
            StreamFormat.original,
          ),
          bitRate: p.getInt(_dlBitRate) ?? d.downloads.quality.bitRate,
        ),
        wifiOnly: p.getBool(_dlWifiOnly) ?? d.downloads.wifiOnly,
      ),
    );
  }

  Future<void> setShowTitleBar(bool show) async {
    state = state.copyWith(showTitleBar: show);
    await _prefs.setBool(_titleBarKey, show);
  }

  Future<void> setShowReplayGainDebug(bool show) async {
    state = state.copyWith(showReplayGainDebug: show);
    await _prefs.setBool(_rgDebugKey, show);
  }

  Future<void> setSyncQueue(bool sync) async {
    state = state.copyWith(syncQueue: sync);
    await _prefs.setBool(_syncQueue, sync);
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

  /// Sets the mobile data quality; null follows the Wi-Fi quality.
  Future<void> setMobileQuality(StreamQuality? q) async {
    state = state.copyWith(mobileQuality: () => q);
    await _prefs.setString(_mobileFormat, q?.format.name ?? _sameAsWifi);
    if (q != null) await _prefs.setInt(_mobileBitRate, q.bitRate);
  }

  Future<void> setCache(CacheOptions c) async {
    state = state.copyWith(cache: c);
    await _prefs.setInt(_precache, c.precacheTracks);
    await _prefs.setInt(_cacheLimit, c.limitMb);
    await _prefs.setBool(_precacheMobile, c.precacheOnMobile);
  }

  Future<void> setDownloads(DownloadOptions o) async {
    state = state.copyWith(downloads: o);
    await _prefs.setString(_dlFormat, o.quality.format.name);
    await _prefs.setInt(_dlBitRate, o.quality.bitRate);
    await _prefs.setBool(_dlWifiOnly, o.wifiOnly);
  }
}

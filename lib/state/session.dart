import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/artwork_cache.dart';
import '../core/downloads.dart';
import '../core/music_source.dart';
import '../core/offline_source.dart';
import '../core/server_route.dart';
import '../core/track_cache.dart';
import '../core/track_resolver.dart';
import '../platform/secure_store.dart';
import '../sources/subsonic/subsonic_client.dart';
import '../sources/subsonic/subsonic_source.dart';
import 'diagnostics.dart';
import 'offline.dart';
import 'settings.dart';

final secureStoreProvider = Provider<SecureStore>((_) => PlatformSecureStore());

/// The signed-in server. v1 has at most one, but everything that persists
/// (credentials, caches, the saved queue) is keyed by [serverId] so a v2
/// server switcher only has to change which session is active.
class ServerSession {
  final MusicSource source;
  const ServerSession(this.source);

  String get serverId => source.serverId;
}

/// The active [ServerSession], or `null` when signed out.
final sessionProvider = AsyncNotifierProvider<SessionNotifier, ServerSession?>(
  SessionNotifier.new,
);

/// The active [MusicSource] for widgets that only render when signed in.
final musicSourceProvider = Provider<MusicSource>((ref) {
  final session = ref.watch(sessionProvider).value;
  if (session == null) throw StateError('Not signed in');
  // Browsing answers from the downloaded music while offline.
  return OfflineAwareSource(
    session.source,
    isOffline: () => ref.read(offlineProvider),
    library: () => ref.read(offlineLibraryProvider),
  );
});

/// What the server told us it supports, asked once per sign-in. Until the
/// answer arrives (or if the server cannot say) it is the source's baseline,
/// so features never wait on it.
final capabilitiesProvider = Provider<SourceCapabilities>((ref) {
  final session = ref.watch(sessionProvider).value;
  if (session == null) return const SourceCapabilities();
  return ref.watch(_detectedCapabilitiesProvider(session.source)).value ??
      session.source.capabilities;
});

final _detectedCapabilitiesProvider =
    FutureProvider.family<SourceCapabilities, MusicSource>(
      (ref, source) => source.detectCapabilities(),
    );

/// The playback cache. main.dart provides the on-disk one where the
/// platform has a file system; without it tracks stream directly.
final trackCacheProvider = Provider<TrackCache?>((_) => null);

/// The on-disk artwork cache. main.dart provides it where the platform has
/// a file system; without it images are fetched from the server each run.
final artworkCacheProvider = Provider<ArtworkCache?>((_) => null);

/// Where downloads for offline use are kept. main.dart provides the
/// on-disk store where the platform has a file system; without one,
/// downloading is switched off.
final downloadStoreProvider = Provider<DownloadStore?>((_) => null);

/// Turns a track into something to play: its downloaded file when it has
/// one, otherwise a stream from the server (through the playback cache).
final trackResolverProvider = Provider<TrackResolver>((ref) {
  final source = ref.watch(musicSourceProvider);
  final streaming = StreamingTrackResolver(
    source,
    quality: ref.watch(streamQualityProvider),
    cache: ref.watch(trackCacheProvider),
    canStartAt: ref.watch(capabilitiesProvider).canStartTranscodeAt,
  );
  final downloads = ref.watch(downloadStoreProvider);
  return downloads == null
      ? streaming
      : DownloadedTrackResolver(streaming, downloads, source);
});

/// Saved servers are stored as `oamp.server.<serverId>` with a `type` field
/// naming the backend, and `oamp.activeServer` holds the active id. The plain
/// password is never stored.
class SessionNotifier extends AsyncNotifier<ServerSession?> {
  static const _activeKey = 'oamp.activeServer';
  static String _serverKey(String id) => 'oamp.server.$id';

  SecureStore get _store => ref.read(secureStoreProvider);

  @override
  Future<ServerSession?> build() async {
    try {
      final id = await _store.read(_activeKey);
      if (id == null) return null;
      final raw = await _store.read(_serverKey(id));
      if (raw == null) return null;
      final source = _sourceFromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (source is SubsonicSource) _hideFromLog(source.credentials);
      return source == null ? null : ServerSession(source);
    } catch (e) {
      debugPrint('Could not restore saved login: $e');
      return null;
    }
  }

  /// Builds a source from its saved config. New backends add a case here.
  static MusicSource? _sourceFromJson(Map<String, dynamic> j) =>
      switch (j['type']) {
        'subsonic' => SubsonicSource(
          SubsonicCredentials.fromJson(
            j['credentials'] as Map<String, dynamic>,
          ),
        ),
        _ => null,
      };

  /// Signs in to a Subsonic/Navidrome server: checks the credentials with
  /// `ping`, saves them and makes the server active. Throws
  /// [MusicSourceException] with a readable message on failure, leaving the
  /// current session untouched.
  ///
  /// With an [awayUrl], signs in at whichever address answers (home first)
  /// and throws [AwayAddressUnreachable] when the away address didn't
  /// answer, unless [keepUnreachableAway] is set.
  Future<void> loginSubsonic({
    required String serverUrl,
    required String username,
    required String password,
    String? awayUrl,
    bool keepUnreachableAway = false,
  }) => _login(
    SubsonicCredentials.fromPassword(
      baseUrl: SubsonicClient.normaliseServerUrl(serverUrl),
      username: username.trim(),
      password: password,
    ).withAwayUrl(_awayFrom(awayUrl)),
    keepUnreachableAway: keepUnreachableAway,
  );

  /// Signs in with an API key instead of a username and password, on
  /// servers with the `apiKeyAuthentication` extension.
  Future<void> loginSubsonicWithApiKey({
    required String serverUrl,
    required String apiKey,
    String? awayUrl,
    bool keepUnreachableAway = false,
  }) => _login(
    SubsonicCredentials.fromApiKey(
      baseUrl: SubsonicClient.normaliseServerUrl(serverUrl),
      apiKey: apiKey.trim(),
    ).withAwayUrl(_awayFrom(awayUrl)),
    keepUnreachableAway: keepUnreachableAway,
  );

  static Uri? _awayFrom(String? url) => url == null || url.trim().isEmpty
      ? null
      : SubsonicClient.normaliseServerUrl(url);

  /// Keeps the server's address, the user name and the credentials out
  /// of the diagnostics log.
  void _hideFromLog(SubsonicCredentials c) {
    final redact = ref.read(diagnosticsLogProvider).redact;
    redact.hide(c.baseUrl.host, '<server>');
    if (c.awayUrl case final away?) redact.hide(away.host, '<server>');
    redact.hide(c.username, '<user>', wholeWord: true);
    for (final secret in [c.token, c.salt, ?c.apiKey]) {
      redact.hide(secret, '<hidden>');
    }
  }

  Future<void> _login(
    SubsonicCredentials creds, {
    bool keepUnreachableAway = false,
  }) async {
    _hideFromLog(creds);
    final source = SubsonicSource(creds);
    try {
      await source.connect();
      if (creds.awayUrl != null) {
        final awayError = await source.client.picker.lastAwayAttempt;
        if (awayError == null || await _awayWorkedBefore(creds)) {
          source.client.markAwayConnected();
        }
        if (awayError != null && !keepUnreachableAway) {
          throw AwayAddressUnreachable('$awayError');
        }
      }
    } catch (e) {
      debugPrint('Sign-in failed: $e');
      source.close();
      rethrow;
    }
    debugPrint(
      source.route == ServerRoute.away
          ? 'Signed in (away address)'
          : 'Signed in',
    );
    await _save(source.credentials);
    await _store.write(_activeKey, source.serverId);
    state.value?.source.close();
    state = AsyncData(ServerSession(source));
  }

  /// Whether this login's away address is the one already saved for the
  /// server and reached before, as when signing in again.
  Future<bool> _awayWorkedBefore(SubsonicCredentials creds) async {
    try {
      final raw = await _store.read(_serverKey(creds.serverId));
      if (raw == null) return false;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final saved = SubsonicCredentials.fromJson(
        j['credentials'] as Map<String, dynamic>,
      );
      return saved.awayConnected && saved.awayUrl == creds.awayUrl;
    } catch (_) {
      return false;
    }
  }

  Future<void> _save(SubsonicCredentials creds) => _store.write(
    _serverKey(creds.serverId),
    jsonEncode({'type': 'subsonic', 'credentials': creds.toJson()}),
  );

  SubsonicSource? get _subsonic => switch (state.value?.source) {
    final SubsonicSource s => s,
    _ => null,
  };

  /// Signs in at [awayUrl] with the active server's login, to check it
  /// before saving. Returns null when it worked, or what went wrong. The
  /// home network often cannot reach its own public address, so a failure
  /// here doesn't mean the address is wrong.
  Future<String?> testAwayAddress(String awayUrl) async {
    final source = _subsonic;
    if (source == null) return 'Not signed in.';
    final url = SubsonicClient.normaliseServerUrl(awayUrl);
    _hideFromLog(source.credentials.withAwayUrl(url));
    try {
      await source.client.probe(url, const Duration(seconds: 10));
      return null;
    } catch (e) {
      debugPrint('Away address check failed: $e');
      return '$e';
    }
  }

  /// Sets the away address of the active server ([awayUrl] null removes
  /// it), noting whether it has been reached. The server, its queue and
  /// caches stay as they are. Use [AwayAddressNotifier.save], which also
  /// updates settings and checks which address to use.
  Future<void> saveAwayAddress(
    String? awayUrl, {
    bool connected = false,
  }) async {
    final source = _subsonic;
    if (source == null) return;
    final url = awayUrl == null || awayUrl.trim().isEmpty
        ? null
        : SubsonicClient.normaliseServerUrl(awayUrl);
    source.setAwayUrl(url, connected: connected);
    _hideFromLog(source.credentials);
    await _save(source.credentials);
    debugPrint(url == null ? 'Away address removed' : 'Away address saved');
  }

  /// Records that the away address has worked, which clears the warning in
  /// settings.
  Future<void> markAwayConnected() async {
    final source = _subsonic;
    if (source == null || source.credentials.awayConnected) return;
    source.client.markAwayConnected();
    await _save(source.credentials);
  }

  /// The address and username saved for the active server, to fill in the
  /// login form when the server asks to sign in again.
  Future<({String serverUrl, String username, bool apiKey, String? awayUrl})?>
  savedLoginHint() async {
    final id = state.value?.serverId;
    if (id == null) return null;
    try {
      final raw = await _store.read(_serverKey(id));
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final c = j['credentials'] as Map<String, dynamic>;
      return (
        serverUrl: c['baseUrl'] as String,
        username: (c['username'] as String?) ?? '',
        apiKey: c['apiKey'] != null,
        awayUrl: c['awayUrl'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Signs out of the active server and forgets its credentials.
  Future<void> logout() async {
    final current = state.value;
    if (current != null) {
      await _store.delete(_serverKey(current.serverId));
      current.source.close();
    }
    await _store.delete(_activeKey);
    debugPrint('Signed out');
    state = const AsyncData(null);
  }
}

/// Thrown by sign-in when the server answered but its away address didn't.
/// The sign-in can be repeated keeping the address anyway.
class AwayAddressUnreachable implements Exception {
  final String reason;
  const AwayAddressUnreachable(this.reason);

  @override
  String toString() => reason;
}

/// The active server's away address, or null when it has none.
class AwayAddress {
  final Uri url;

  /// Whether OAmp has reached the server there at least once. Until then
  /// settings warn that it may not work.
  final bool connected;
  const AwayAddress(this.url, {this.connected = false});
}

final awayAddressProvider = NotifierProvider<AwayAddressNotifier, AwayAddress?>(
  AwayAddressNotifier.new,
);

class AwayAddressNotifier extends Notifier<AwayAddress?> {
  SubsonicSource? _source;

  @override
  AwayAddress? build() {
    final source = ref.watch(sessionProvider).value?.source;
    _source = source is SubsonicSource ? source : null;
    if (source == null) return null;
    final sub = source.routeChanges.listen((route) {
      if (route == ServerRoute.away) unawaited(_reached());
    });
    ref.onDispose(sub.cancel);
    return _current();
  }

  AwayAddress? _current() {
    final c = _source?.credentials;
    final url = c?.awayUrl;
    return url == null ? null : AwayAddress(url, connected: c!.awayConnected);
  }

  /// Checks [url] with the active login. Null when it answered, otherwise
  /// what went wrong.
  Future<String?> test(String url) =>
      ref.read(sessionProvider.notifier).testAwayAddress(url);

  /// Saves (or with null, removes) the away address. The server status
  /// then checks which address to use.
  Future<void> save(String? url, {bool connected = false}) async {
    await ref
        .read(sessionProvider.notifier)
        .saveAwayAddress(url, connected: connected);
    state = _current();
  }

  Future<void> _reached() async {
    final now = state;
    if (now == null || now.connected) return;
    await ref.read(sessionProvider.notifier).markAwayConnected();
    if (ref.mounted) state = _current();
  }
}

/// Which of the active server's addresses OAmp is using.
final serverRouteProvider = NotifierProvider<_ServerRouteNotifier, ServerRoute>(
  _ServerRouteNotifier.new,
);

class _ServerRouteNotifier extends Notifier<ServerRoute> {
  @override
  ServerRoute build() {
    final source = ref.watch(sessionProvider).value?.source;
    if (source == null) return ServerRoute.home;
    final sub = source.routeChanges.listen((route) {
      debugPrint('Server address: now using ${route.name}');
      state = route;
    });
    ref.onDispose(sub.cancel);
    return source.route;
  }
}

/// Whether the signed-in server is answering, checked on launch so a server
/// that is down, or a password that changed, says so up front instead of as
/// a row of failed pages.
enum ServerHealth { checking, ok, unreachable, signedOut }

class ServerStatus {
  final ServerHealth health;

  /// What went wrong, in words, when [health] is not ok.
  final String? message;
  const ServerStatus(this.health, [this.message]);

  static const ok = ServerStatus(ServerHealth.ok);
}

final serverStatusProvider =
    NotifierProvider<ServerStatusNotifier, ServerStatus>(
      ServerStatusNotifier.new,
    );

class ServerStatusNotifier extends Notifier<ServerStatus> {
  /// How often to try again while the server cannot be reached.
  static const retryEvery = Duration(seconds: 30);

  /// How often to look for the home address while using the away one, so
  /// OAmp goes back to the local network soon after getting home.
  static const homeCheckEvery = Duration(minutes: 1);

  Timer? _retry;
  Timer? _homeCheck;
  int _generation = 0;

  @override
  ServerStatus build() {
    final session = ref.watch(sessionProvider).value;
    _retry?.cancel();
    _homeCheck?.cancel();
    ref.onDispose(() {
      _retry?.cancel();
      _homeCheck?.cancel();
    });
    final generation = ++_generation;
    if (session == null) return ServerStatus.ok;
    final source = session.source;
    // Look for the other address when the network changes (Android), and
    // keep looking for home while away.
    final network = ref
        .watch(networkMonitorProvider)
        .anyChange
        .listen((_) => recheckAddress());
    final route = source.routeChanges.listen(_scheduleHomeCheck);
    ref.onDispose(network.cancel);
    ref.onDispose(route.cancel);
    // An away address added, changed or removed: choose again.
    ref.listen(awayAddressProvider, (before, after) {
      if (before?.url != after?.url) unawaited(check());
    });
    Future.microtask(() => _check(source, generation));
    return const ServerStatus(ServerHealth.checking);
  }

  /// Checks again which address to use, when the server has an away
  /// address: after a network change or when the app comes back to the
  /// front.
  Future<void> recheckAddress() async {
    if (ref.read(awayAddressProvider) == null) return;
    await check();
  }

  void _scheduleHomeCheck(ServerRoute route) {
    _homeCheck?.cancel();
    _homeCheck = null;
    if (route != ServerRoute.away) return;
    _homeCheck = Timer(homeCheckEvery, () {
      _homeCheck = null;
      unawaited(check());
    });
  }

  /// Pings the server now, as the banner's Retry does.
  Future<void> check() async {
    final session = ref.read(sessionProvider).value;
    if (session == null) return;
    _retry?.cancel();
    if (state.health != ServerHealth.ok) {
      state = ServerStatus(ServerHealth.checking, state.message);
    }
    await _check(session.source, _generation);
  }

  Future<void> _check(MusicSource source, int generation) async {
    final wasDown =
        state.health == ServerHealth.unreachable ||
        state.health == ServerHealth.signedOut;
    ServerStatus next;
    try {
      await source.connect();
      next = ServerStatus.ok;
    } on MusicSourceException catch (e) {
      next = ServerStatus(
        e.kind == MusicSourceErrorKind.auth
            ? ServerHealth.signedOut
            : ServerHealth.unreachable,
        e.message,
      );
    } catch (e) {
      next = ServerStatus(ServerHealth.unreachable, '$e');
    }
    // Signed out or switched server while the ping was out.
    if (!ref.mounted || generation != _generation) return;
    if (next.health != ServerHealth.ok && next.health != state.health) {
      debugPrint('Server ${next.health.name}: ${next.message}');
    } else if (next.health == ServerHealth.ok && wasDown) {
      debugPrint('Server reachable again');
    }
    state = next;
    _scheduleHomeCheck(source.route);
    if (next.health == ServerHealth.ok) {
      // Extensions are detected once per sign-in; if that ran while the
      // server was down it fell back to the baseline, so ask again.
      if (wasDown) ref.invalidate(_detectedCapabilitiesProvider(source));
    } else if (next.health == ServerHealth.unreachable) {
      _retry = Timer(retryEvery, () => _check(source, generation));
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/artwork_cache.dart';
import '../core/music_source.dart';
import '../core/track_cache.dart';
import '../core/track_resolver.dart';
import '../platform/secure_store.dart';
import '../sources/subsonic/subsonic_client.dart';
import '../sources/subsonic/subsonic_source.dart';
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
  return session.source;
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

final trackResolverProvider = Provider<TrackResolver>(
  (ref) => StreamingTrackResolver(
    ref.watch(musicSourceProvider),
    quality: ref.watch(streamQualityProvider),
    cache: ref.watch(trackCacheProvider),
    canStartAt: ref.watch(capabilitiesProvider).canStartTranscodeAt,
  ),
);

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
  Future<void> loginSubsonic({
    required String serverUrl,
    required String username,
    required String password,
  }) => _login(
    SubsonicCredentials.fromPassword(
      baseUrl: SubsonicClient.normaliseServerUrl(serverUrl),
      username: username.trim(),
      password: password,
    ),
  );

  /// Signs in with an API key instead of a username and password, on
  /// servers with the `apiKeyAuthentication` extension.
  Future<void> loginSubsonicWithApiKey({
    required String serverUrl,
    required String apiKey,
  }) => _login(
    SubsonicCredentials.fromApiKey(
      baseUrl: SubsonicClient.normaliseServerUrl(serverUrl),
      apiKey: apiKey.trim(),
    ),
  );

  Future<void> _login(SubsonicCredentials creds) async {
    final source = SubsonicSource(creds);
    try {
      await source.ping();
    } catch (_) {
      source.close();
      rethrow;
    }
    await _store.write(
      _serverKey(source.serverId),
      jsonEncode({'type': 'subsonic', 'credentials': creds.toJson()}),
    );
    await _store.write(_activeKey, source.serverId);
    state.value?.source.close();
    state = AsyncData(ServerSession(source));
  }

  /// The address and username saved for the active server, to fill in the
  /// login form when the server asks to sign in again.
  Future<({String serverUrl, String username, bool apiKey})?>
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
    state = const AsyncData(null);
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

  Timer? _retry;
  int _generation = 0;

  @override
  ServerStatus build() {
    final session = ref.watch(sessionProvider).value;
    _retry?.cancel();
    ref.onDispose(() => _retry?.cancel());
    final generation = ++_generation;
    if (session == null) return ServerStatus.ok;
    Future.microtask(() => _check(session.source, generation));
    return const ServerStatus(ServerHealth.checking);
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
      await source.ping();
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
    if (generation != _generation) return;
    state = next;
    if (next.health == ServerHealth.ok) {
      // Extensions are detected once per sign-in; if that ran while the
      // server was down it fell back to the baseline, so ask again.
      if (wasDown) ref.invalidate(_detectedCapabilitiesProvider(source));
    } else if (next.health == ServerHealth.unreachable) {
      _retry = Timer(retryEvery, () => _check(source, generation));
    }
  }
}

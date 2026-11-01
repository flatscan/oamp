import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The playback cache. main.dart provides the on-disk one where the
/// platform has a file system; without it tracks stream directly.
final trackCacheProvider = Provider<TrackCache?>((_) => null);

final trackResolverProvider = Provider<TrackResolver>(
  (ref) => StreamingTrackResolver(
    ref.watch(musicSourceProvider),
    quality: ref.watch(streamQualityProvider),
    cache: ref.watch(trackCacheProvider),
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
  }) async {
    final creds = SubsonicCredentials.fromPassword(
      baseUrl: SubsonicClient.normaliseServerUrl(serverUrl),
      username: username.trim(),
      password: password,
    );
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

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/subsonic_client.dart';

/// The logged-in Subsonic client, or `null` when signed out.
///
/// Credentials (server URL, username, token and salt) are kept in the OS
/// secure store: Windows Credential Manager, macOS/iOS Keychain, Android
/// Keystore. The plain password is never written anywhere.
final sessionProvider = AsyncNotifierProvider<SessionNotifier, SubsonicClient?>(
  SessionNotifier.new,
);

/// Convenience accessor for widgets that only render when signed in.
final clientProvider = Provider<SubsonicClient>((ref) {
  final client = ref.watch(sessionProvider).value;
  if (client == null) throw StateError('Not signed in');
  return client;
});

class SessionNotifier extends AsyncNotifier<SubsonicClient?> {
  static const _key = 'oamp.credentials';
  static const _storage = FlutterSecureStorage();

  @override
  Future<SubsonicClient?> build() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      return SubsonicClient(
        SubsonicCredentials.fromJson(jsonDecode(raw) as Map<String, dynamic>),
      );
    } catch (e) {
      debugPrint('Could not restore saved login: $e');
      return null;
    }
  }

  /// Checks the credentials with `ping` and saves them on success.
  /// Throws [SubsonicException] with a readable message on failure, leaving
  /// the current state untouched.
  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final creds = SubsonicCredentials.fromPassword(
      baseUrl: SubsonicClient.normaliseServerUrl(serverUrl),
      username: username.trim(),
      password: password,
    );
    final client = SubsonicClient(creds);
    try {
      await client.ping();
    } catch (_) {
      client.close();
      rethrow;
    }
    await _storage.write(key: _key, value: jsonEncode(creds.toJson()));
    state.value?.close();
    state = AsyncData(client);
  }

  Future<void> logout() async {
    await _storage.delete(key: _key);
    state.value?.close();
    state = const AsyncData(null);
  }
}

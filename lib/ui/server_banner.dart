import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/offline.dart';
import '../state/session.dart';
import '../state/settings.dart';
import 'login_screen.dart';
import 'theme.dart';

/// A strip across the top of the app while the server is down or wants the
/// user to sign in again. Hidden while all is well.
///
/// On a phone it sits under the status bar, and while it shows, the pages
/// below it no longer pad for the status bar themselves.
class ServerStatusBanner extends ConsumerWidget {
  const ServerStatusBanner({super.key});

  /// Whether the banner is showing.
  static bool visibleFor(ServerStatus status, {bool offlineMode = false}) {
    final health = status.health;
    return offlineMode ||
        health == ServerHealth.unreachable ||
        health == ServerHealth.signedOut ||
        (health == ServerHealth.checking && status.message != null);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(serverStatusProvider);
    final health = status.health;
    // Offline mode is the user's own choice, so it says so and offers the
    // way back, whatever the server is doing.
    final offlineMode = ref.watch(
      settingsProvider.select((s) => s.offlineMode),
    );
    final fallback = !offlineMode && ref.watch(offlineProvider);
    final visible = visibleFor(status, offlineMode: offlineMode);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Material(
              color: OAmpColors.surfaceHigh,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8 + MediaQuery.paddingOf(context).top,
                  8,
                  8,
                ),
                child: Row(
                  children: [
                    Icon(
                      health == ServerHealth.signedOut && !offlineMode
                          ? Icons.lock_outline
                          : Icons.cloud_off_rounded,
                      size: 20,
                      color: oampAccent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        offlineMode
                            ? 'Offline mode is on. Only downloaded music is '
                                  'shown and played.'
                            : fallback
                            ? '${status.message ?? ''} Showing your downloaded '
                                  'music.'
                            : status.message ?? '',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (offlineMode)
                      TextButton(
                        onPressed: () => ref
                            .read(settingsProvider.notifier)
                            .setOfflineMode(false),
                        child: const Text('Go online'),
                      )
                    else if (health == ServerHealth.checking)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else if (health == ServerHealth.signedOut)
                      TextButton(
                        onPressed: () => _signInAgain(context, ref),
                        child: const Text('Sign in'),
                      )
                    else
                      TextButton(
                        onPressed: () =>
                            ref.read(serverStatusProvider.notifier).check(),
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _signInAgain(BuildContext context, WidgetRef ref) async {
    final hint = await ref.read(sessionProvider.notifier).savedLoginHint();
    if (!context.mounted) return;
    final nav = Navigator.of(context);
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) => LoginScreen(
          initialServerUrl: hint?.serverUrl,
          initialUsername: hint?.username,
          initialApiKey: hint?.apiKey ?? false,
          initialAwayUrl: hint?.awayUrl,
          onSignedIn: nav.pop,
        ),
      ),
    );
  }
}

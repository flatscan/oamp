import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';
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
  static bool visibleFor(ServerStatus status) {
    final health = status.health;
    return health == ServerHealth.unreachable ||
        health == ServerHealth.signedOut ||
        (health == ServerHealth.checking && status.message != null);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(serverStatusProvider);
    final health = status.health;
    final visible = visibleFor(status);
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
                      health == ServerHealth.signedOut
                          ? Icons.lock_outline
                          : Icons.cloud_off_rounded,
                      size: 20,
                      color: oampAccent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        status.message ?? '',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (health == ServerHealth.checking)
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_updates.dart';
import '../state/diagnostics.dart';
import 'theme.dart';

/// A strip across the top of the app when a new release is out, shown once
/// per version. View opens the release page; Skip hides it.
class UpdateBanner extends ConsumerWidget {
  /// Whether to pad for the status bar, which the server banner does
  /// instead while it shows above this one.
  final bool padTop;

  const UpdateBanner({super.key, this.padTop = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(appUpdatesProvider.select((s) => s.announce));
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: release == null
          ? const SizedBox(width: double.infinity)
          : Material(
              color: OAmpColors.surfaceHigh,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8 + (padTop ? MediaQuery.paddingOf(context).top : 0),
                  8,
                  8,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.system_update_alt_rounded,
                      size: 20,
                      color: oampAccent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'OAmp ${release.tag} is available.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => ref
                          .read(appUpdatesProvider.notifier)
                          .dismissAnnouncement(),
                      child: const Text('Skip'),
                    ),
                    TextButton(
                      onPressed: () {
                        ref
                            .read(appUpdatesProvider.notifier)
                            .dismissAnnouncement();
                        ref.read(externalActionsProvider).openUrl(release.page);
                      },
                      child: const Text('View'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// The first-launch question: may OAmp look for new releases?
Future<void> askAboutUpdateChecks(BuildContext context, WidgetRef ref) async {
  final yes = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Check for updates?'),
      content: const Text(
        'OAmp can ask GitHub once a day whether a new version is out, and '
        'let you know. Nothing about you, your server or your music is '
        'sent. You can change this in Settings.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('No thanks'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Check for updates'),
        ),
      ],
    ),
  );
  if (yes != null) await ref.read(appUpdatesProvider.notifier).setEnabled(yes);
}

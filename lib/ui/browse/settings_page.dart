import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session.dart';
import '../../state/settings.dart';
import '../theme.dart';
import '../widgets.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(musicSourceProvider);
    final settings = ref.watch(settingsProvider);
    final t = Theme.of(context).textTheme;
    final windows = defaultTargetPlatform == TargetPlatform.windows;

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text.toUpperCase(),
        style: t.labelMedium?.copyWith(
          color: OAmpColors.textFaint,
          letterSpacing: 1.2,
        ),
      ),
    );

    return ListScaffold(
      title: 'Settings',
      slivers: [
        SliverList.list(
          children: [
            heading('Server'),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(source.displayName),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Sign out'),
              onTap: () => ref.read(sessionProvider.notifier).logout(),
            ),
            if (windows) ...[
              heading('Window'),
              SwitchListTile(
                secondary: const Icon(Icons.web_asset_rounded),
                title: const Text('Show title bar'),
                subtitle: const Text(
                  'When hidden, drag the top of Home or of the now playing '
                  'artwork to move the window.',
                ),
                value: settings.showTitleBar,
                onChanged: (v) =>
                    ref.read(settingsProvider.notifier).setShowTitleBar(v),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

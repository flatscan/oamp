import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_updates.dart';
import '../../state/app_updates.dart';
import '../../state/diagnostics.dart';
import '../browser.dart';
import '../nearby_devices_page.dart';
import '../widgets.dart';

/// The bottom of Settings: the version, the update check, and diagnostics
/// for bug reports.
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key});

  static final _newIssue = Uri.parse(
    'https://github.com/${GitHubReleaseFeed.repository}/issues/new',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final build = ref.watch(buildInfoProvider);
    final updates = ref.watch(appUpdatesProvider);
    final notifier = ref.read(appUpdatesProvider.notifier);
    final android = defaultTargetPlatform == TargetPlatform.android;
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final available = updates.available;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline_rounded),
          title: const Text('OAmp'),
          subtitle: Text(build.label),
          // Hidden test page for casting discovery.
          onLongPress: () => openPage(const NearbyDevicesPage()),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.update_rounded),
          title: const Text('Check for updates'),
          subtitle: Text(
            build.isRelease
                ? 'Asks GitHub once a day for a new version. Nothing about '
                      'you or your music is sent.'
                : 'Test builds don’t check on their own.',
          ),
          value: updates.choice == UpdateCheckChoice.on,
          onChanged: notifier.setEnabled,
        ),
        ListTile(
          leading: const Icon(Icons.refresh_rounded),
          title: const Text('Check now'),
          subtitle: Text(_status(updates, build.isRelease)),
          enabled: !updates.checking,
          trailing: available == null
              ? null
              : TextButton(
                  onPressed: () =>
                      ref.read(externalActionsProvider).openUrl(available.page),
                  child: const Text('View'),
                ),
          onTap: () => notifier.check(manual: true),
        ),
        ListTile(
          leading: const Icon(Icons.content_copy_rounded),
          title: const Text('Copy diagnostics'),
          subtitle: const Text(
            'Version, device, server software, settings and recent errors, '
            'for a bug report. No song titles, names or addresses.',
          ),
          onTap: () async {
            await _copy(ref);
            if (context.mounted) toast(context, 'Diagnostics copied');
          },
        ),
        if (android)
          ListTile(
            leading: const Icon(Icons.share_rounded),
            title: const Text('Share diagnostics'),
            subtitle: const Text('The full log, as a text file.'),
            onTap: () => _share(context, ref),
          ),
        if (windows)
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Open diagnostics folder'),
            subtitle: const Text(
              'Saves the full log as oamp-diagnostics.txt and shows it.',
            ),
            onTap: () => _openFolder(context, ref),
          ),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Report a bug'),
          subtitle: const Text(
            'Copies the diagnostics and opens a new issue on GitHub. Paste '
            'them in where it asks.',
          ),
          onTap: () async {
            await _copy(ref);
            final device = ref.read(deviceDetailsProvider);
            final opened = await ref
                .read(externalActionsProvider)
                .openUrl(
                  _newIssue.replace(
                    queryParameters: {
                      'template': 'bug_report.yml',
                      'version': build.label,
                      if (android) 'platform': 'Android',
                      if (windows) 'platform': 'Windows',
                      'device': [?device.model, device.system].join(', '),
                    },
                  ),
                );
            if (!context.mounted) return;
            toast(
              context,
              opened
                  ? 'Diagnostics copied, paste them into the issue'
                  : 'Diagnostics copied. Couldn’t open the browser.',
            );
          },
        ),
      ],
    );
  }

  static String _status(AppUpdatesState s, bool isRelease) {
    if (s.checking) return 'Checking…';
    if (s.error != null) return s.error!;
    final latest = s.latest;
    if (s.available != null) return '${s.available!.tag} is available';
    if (latest == null) return 'Looks for a newer version on GitHub.';
    if (!isRelease) return 'Latest release: ${latest.tag}';
    return 'You’re up to date';
  }

  static Future<void> _copy(WidgetRef ref) async {
    final text = await ref.read(diagnosticsReportProvider).forClipboard();
    await Clipboard.setData(ClipboardData(text: text));
  }

  static Future<String?> _writeReport(WidgetRef ref) async {
    final text = await ref.read(diagnosticsReportProvider).build();
    return ref.read(diagnosticsLogProvider).store.writeReport(text);
  }

  static Future<void> _share(BuildContext context, WidgetRef ref) async {
    final path = await _writeReport(ref);
    final ok =
        path != null &&
        await ref
            .read(externalActionsProvider)
            .shareFile(path, subject: 'OAmp diagnostics');
    if (!ok && context.mounted) toast(context, 'Couldn’t share the log');
  }

  static Future<void> _openFolder(BuildContext context, WidgetRef ref) async {
    await _writeReport(ref);
    final folder = ref.read(diagnosticsLogProvider).store.folder;
    final ok =
        folder != null &&
        await ref.read(externalActionsProvider).openFolder(folder);
    if (!ok && context.mounted) toast(context, 'Couldn’t open the folder');
  }
}

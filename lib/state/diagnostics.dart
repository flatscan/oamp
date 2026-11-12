import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/build_info.dart';
import '../core/diagnostics.dart';
import '../core/playback_options.dart';
import '../platform/device_details.dart';
import '../platform/external_actions.dart';
import 'app_updates.dart';
import 'session.dart';
import 'settings.dart';

/// The app's diagnostics log. main.dart provides the one on disk, which
/// also collects everything printed with `debugPrint` and uncaught errors.
final diagnosticsLogProvider = Provider<DiagnosticsLog>(
  (_) => DiagnosticsLog(MemoryLogStore()),
);

/// The OS and device model, read once at startup by main.dart.
final deviceDetailsProvider = Provider<DeviceDetails>(
  (_) => DeviceDetails(system: defaultTargetPlatform.name),
);

/// Which build this is.
final buildInfoProvider = Provider<BuildInfo>((_) => BuildInfo.current);

/// Opening web pages, folders and the share sheet.
final externalActionsProvider = Provider<ExternalActions>(
  (_) => const NoExternalActions(),
);

/// The bug report text: the app, the device, the server software and the
/// settings, then the recent log. Contains nothing personal: no track
/// titles, user names, server addresses or credentials.
final diagnosticsReportProvider = Provider<DiagnosticsReport>(
  DiagnosticsReport.new,
);

class DiagnosticsReport {
  final Ref ref;
  DiagnosticsReport(this.ref);

  /// About how much fits in the body of a GitHub issue, with room for the
  /// user's own words.
  static const clipboardLimit = 40000;

  /// The summary lines above the log.
  List<String> summary() {
    final build = ref.read(buildInfoProvider);
    final device = ref.read(deviceDetailsProvider);
    final caps = ref.read(capabilitiesProvider);
    final settings = ref.read(settingsProvider);
    final p = settings.playback;
    final updates = ref.read(appUpdatesProvider);
    final signedIn = ref.read(sessionProvider).value != null;
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    String quality(StreamQuality q) =>
        q.isOriginal ? 'original' : '${q.format.name} ${q.bitRate} kbps';
    final software = [?caps.serverType, ?caps.serverVersion].join(' ');
    final extensions = caps.extensions.keys.toList()..sort();
    return [
      'App: OAmp ${build.label}',
      'System: ${device.system}',
      if (device.model != null) 'Device: ${device.model}',
      'Audio engine: ${windows ? 'libmpv' : 'just_audio'}',
      if (!signedIn)
        'Server: not signed in'
      else ...[
        'Server: ${software.isEmpty ? 'unknown' : software}',
        'Extensions: ${extensions.isEmpty ? 'none' : extensions.join(', ')}',
        'Server status: ${ref.read(serverStatusProvider).health.name}',
      ],
      'Network: ${ref.read(networkKindProvider).name}',
      'Playback: gapless ${_onOff(p.gapless)}, '
          'crossfade ${p.crossfade.inSeconds} s'
          '${p.crossfade > Duration.zero ? ' (same album ${_onOff(p.crossfadeSameAlbum)})' : ''}, '
          'equaliser ${p.equalizer.name}',
      'ReplayGain: ${p.replayGain.name}, pre-amp ${p.preampDb} dB, '
          'untagged ${p.fallbackGainDb} dB, '
          'prevent clipping ${_onOff(p.preventClipping)}',
      'Quality: ${quality(settings.quality)}'
          '${settings.mobileQuality == null ? '' : ', mobile data ${quality(settings.mobileQuality!)}'}',
      'Cache: pre-cache ${settings.cache.precacheTracks}, '
          'limit ${settings.cache.limitMb} MB',
      'Queue sync: ${_onOff(settings.syncQueue)}',
      'Update check: ${updates.choice.name}',
    ];
  }

  static String _onOff(bool v) => v ? 'on' : 'off';

  /// The report with the last [maxLines] log lines.
  Future<String> build({int maxLines = 2000}) async {
    final log = await ref
        .read(diagnosticsLogProvider)
        .recent(maxLines: maxLines);
    final head = summary().join('\n');
    return 'OAmp diagnostics\n\n$head\n\nRecent log (oldest first):\n'
        '${log.isEmpty ? '(empty)' : log}\n';
  }

  /// The report cut to fit in a GitHub issue, keeping the newest lines.
  Future<String> forClipboard() async {
    final full = await build(maxLines: 400);
    if (full.length <= clipboardLimit) return full;
    final head = summary().join('\n');
    final intro = 'OAmp diagnostics\n\n$head\n\nRecent log (newest part):\n';
    final room = clipboardLimit - intro.length;
    final log = await ref.read(diagnosticsLogProvider).recent(maxLines: 400);
    var tail = log.length > room ? log.substring(log.length - room) : log;
    // Start at a whole line.
    final nl = tail.indexOf('\n');
    if (nl >= 0) tail = tail.substring(nl + 1);
    return '$intro$tail\n';
  }
}

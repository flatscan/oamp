import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playback_options.dart';
import '../../state/precache.dart';
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
    final notifier = ref.read(settingsProvider.notifier);
    final playback = settings.playback;
    final quality = settings.quality;
    final cache = settings.cache;
    final hasCache = ref.watch(trackCacheProvider) != null;
    final windows = defaultTargetPlatform == TargetPlatform.windows;

    void setPlayback(PlaybackOptions o) => notifier.setPlayback(o);

    return ListScaffold(
      title: 'Settings',
      slivers: [
        SliverList.list(
          children: [
            const SettingsHeading('Playback'),
            SwitchListTile(
              secondary: const Icon(Icons.join_inner_rounded),
              title: const Text('Gapless playback'),
              subtitle: const Text(
                'Loads the next track early so albums play without a break.',
              ),
              value: playback.gapless,
              onChanged: (v) => setPlayback(playback.copyWith(gapless: v)),
            ),
            SliderTile(
              icon: Icons.swap_horiz_rounded,
              title: 'Crossfade',
              valueLabel: playback.crossfade == Duration.zero
                  ? 'Off'
                  : '${playback.crossfade.inSeconds} s',
              value: playback.crossfade.inSeconds.toDouble(),
              min: 0,
              max: PlaybackOptions.crossfadeSeconds.last.toDouble(),
              divisions: PlaybackOptions.crossfadeSeconds.last,
              onChanged: (v) => setPlayback(
                playback.copyWith(crossfade: Duration(seconds: v.round())),
              ),
            ),
            if (playback.crossfade > Duration.zero)
              SwitchListTile(
                secondary: const SizedBox(width: 24),
                title: const Text('Crossfade within an album'),
                subtitle: const Text(
                  'Off keeps tracks from the same album gapless.',
                ),
                value: playback.crossfadeSameAlbum,
                onChanged: (v) =>
                    setPlayback(playback.copyWith(crossfadeSameAlbum: v)),
              ),
            const SettingsHeading('Volume levelling'),
            ChoiceTile<ReplayGainMode>(
              icon: Icons.equalizer_rounded,
              title: 'ReplayGain',
              subtitle: switch (playback.replayGain) {
                ReplayGainMode.off => 'Tracks play at their own loudness.',
                ReplayGainMode.track => 'Every track at the same loudness.',
                ReplayGainMode.album =>
                  'Albums at the same loudness, keeping the quiet and loud '
                      'songs within them.',
              },
              value: playback.replayGain,
              choices: const {
                ReplayGainMode.off: 'Off',
                ReplayGainMode.track: 'Track',
                ReplayGainMode.album: 'Album',
              },
              onChanged: (v) => setPlayback(playback.copyWith(replayGain: v)),
            ),
            if (playback.replayGain != ReplayGainMode.off) ...[
              SliderTile(
                icon: Icons.tune_rounded,
                title: 'Pre-amp',
                valueLabel: _db(playback.preampDb),
                value: playback.preampDb,
                min: -12,
                max: 12,
                divisions: 24,
                onChanged: (v) => setPlayback(playback.copyWith(preampDb: v)),
              ),
              SliderTile(
                icon: Icons.label_off_outlined,
                title: 'Tracks without ReplayGain',
                valueLabel: _db(playback.fallbackGainDb),
                value: playback.fallbackGainDb,
                min: -12,
                max: 0,
                divisions: 12,
                onChanged: (v) =>
                    setPlayback(playback.copyWith(fallbackGainDb: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.graphic_eq_rounded),
                title: const Text('Prevent clipping'),
                subtitle: const Text(
                  'Uses each track’s peak so a boost never distorts.',
                ),
                value: playback.preventClipping,
                onChanged: (v) =>
                    setPlayback(playback.copyWith(preventClipping: v)),
              ),
            ],
            const SettingsHeading('Streaming quality'),
            ChoiceTile<StreamFormat>(
              icon: Icons.high_quality_outlined,
              title: 'Format',
              subtitle: quality.isOriginal
                  ? 'The file as stored on the server.'
                  : 'The server converts each track as it streams.',
              value: quality.format,
              choices: const {
                StreamFormat.original: 'Original',
                StreamFormat.opus: 'Opus',
                StreamFormat.mp3: 'MP3',
              },
              onChanged: (v) => notifier.setQuality(
                StreamQuality(format: v, bitRate: quality.bitRate),
              ),
            ),
            if (!quality.isOriginal)
              ChoiceTile<int>(
                icon: Icons.speed_rounded,
                title: 'Maximum bit rate',
                value: quality.bitRate,
                choices: {for (final b in StreamQuality.bitRates) b: '$b kbps'},
                onChanged: (v) => notifier.setQuality(
                  StreamQuality(format: quality.format, bitRate: v),
                ),
              ),
            if (hasCache) ...[
              const SettingsHeading('Cache'),
              ChoiceTile<int>(
                icon: Icons.downloading_rounded,
                title: 'Pre-cache upcoming tracks',
                subtitle:
                    'Fetches tracks in the queue ahead of time, so they '
                    'start at once and play through network hiccups.',
                value: cache.precacheTracks,
                choices: {
                  for (final n in CacheOptions.precacheChoices)
                    n: n == 0 ? 'Off' : (n == 1 ? 'Next track' : 'Next $n'),
                },
                onChanged: (v) =>
                    notifier.setCache(cache.copyWith(precacheTracks: v)),
              ),
              ChoiceTile<int>(
                icon: Icons.storage_rounded,
                title: 'Cache size limit',
                subtitle: 'The oldest tracks are removed to stay under it.',
                value: cache.limitMb,
                choices: {
                  for (final mb in CacheOptions.limitChoicesMb) mb: _size(mb),
                },
                onChanged: (v) => notifier.setCache(cache.copyWith(limitMb: v)),
              ),
              const _CacheUsageTile(),
            ],
            const SettingsHeading('Server'),
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
              const SettingsHeading('Window'),
              SwitchListTile(
                secondary: const Icon(Icons.web_asset_rounded),
                title: const Text('Show title bar'),
                subtitle: const Text(
                  'When hidden, drag the top of Home or of the now playing '
                  'artwork to move the window.',
                ),
                value: settings.showTitleBar,
                onChanged: notifier.setShowTitleBar,
              ),
            ],
          ],
        ),
      ],
    );
  }

  static String _db(double db) {
    final r = (db * 2).round() / 2;
    if (r == 0) return '0 dB';
    final s = r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r';
    return r > 0 ? '+$s dB' : '$s dB';
  }

  static String _size(int mb) =>
      mb >= 1024 ? '${(mb / 1024).toStringAsFixed(0)} GB' : '$mb MB';
}

class _CacheUsageTile extends ConsumerWidget {
  const _CacheUsageTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(cacheUsageProvider).value;
    final mb = (usage?.bytes ?? 0) / (1024 * 1024);
    final used = mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    return ListTile(
      leading: const Icon(Icons.delete_sweep_outlined),
      title: const Text('Clear cache'),
      subtitle: Text(
        usage == null
            ? 'Checking…'
            : '$used in ${usage.files} '
                  '${usage.files == 1 ? 'track' : 'tracks'}',
      ),
      enabled: (usage?.files ?? 0) > 0,
      onTap: () async {
        await ref.read(trackCacheProvider)?.clear();
        if (context.mounted) toast(context, 'Cache cleared');
      },
    );
  }
}

/// A small caps label above a group of settings.
class SettingsHeading extends StatelessWidget {
  final String text;
  const SettingsHeading(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: OAmpColors.textFaint, letterSpacing: 1.2),
    ),
  );
}

/// A setting with a few named values. Shows the current one on the right
/// and opens a menu of the others.
class ChoiceTile<T> extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final T value;
  final Map<T, String> choices;
  final ValueChanged<T> onChanged;

  const ChoiceTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Builder(
      builder: (context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              choices[value] ?? '$value',
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: accent, fontWeight: FontWeight.w600),
            ),
            const Icon(Icons.arrow_drop_down_rounded),
          ],
        ),
        onTap: () async {
          final picked = await showMenuAt<T>(context, [
            for (final e in choices.entries)
              PopupMenuItem(
                value: e.key,
                child: Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: e.key == value
                          ? Icon(Icons.check_rounded, size: 20, color: accent)
                          : null,
                    ),
                    Text(e.value),
                  ],
                ),
              ),
          ], at: centreOf(context));
          if (picked != null && picked != value) onChanged(picked);
        },
      ),
    );
  }
}

/// A setting on a slider, with its value shown beside the title.
class SliderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const SliderTile({
    super.key,
    required this.icon,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ListTile(
      leading: Icon(icon),
      title: Row(
        children: [
          Expanded(child: Text(title)),
          Text(
            valueLabel,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: accent, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      subtitle: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          overlayShape: SliderComponentShape.noOverlay,
          tickMarkShape: SliderTickMarkShape.noTickMark,
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

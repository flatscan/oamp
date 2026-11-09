import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/outputs.dart';
import '../../state/player.dart';
import '../cover_art.dart';
import '../theme.dart';
import 'now_playing.dart';

/// The bar above the tabs while something is queued: cover, title, play and
/// next, with a thin progress line. Click or swipe up for now playing.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((s) => s.current));
    final hasNext = ref.watch(playerProvider.select((s) => s.hasNext));
    final t = Theme.of(context).textTheme;
    final p = ref.read(playerProvider.notifier);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: track == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Material(
                color: OAmpColors.surfaceHigh,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => showNowPlaying(context),
                  child: GestureDetector(
                    onVerticalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) < -200) {
                        showNowPlaying(context);
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                          child: Row(
                            children: [
                              CoverArt(track.coverArt, size: 44, radius: 6),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      track.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: t.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    _Subtitle(artist: track.artist),
                                  ],
                                ),
                              ),
                              const _MiniPlayPause(),
                              IconButton(
                                tooltip: 'Next',
                                onPressed: hasNext ? p.next : null,
                                icon: const Icon(Icons.skip_next_rounded),
                              ),
                            ],
                          ),
                        ),
                        const _Progress(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// The artist, or where the music is playing while casting, or why
/// casting just stopped.
class _Subtitle extends ConsumerWidget {
  final String? artist;
  const _Subtitle({required this.artist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(outputProvider);
    final style = Theme.of(context).textTheme.bodySmall;
    Widget line(String text, {IconData? icon, Color? color}) => Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style?.copyWith(color: color),
          ),
        ),
      ],
    );
    final name = output.device?.name;
    return switch (output.phase) {
      OutputPhase.connected => line(
        'Playing on $name',
        icon: Icons.cast_connected_rounded,
        color: oampAccent,
      ),
      OutputPhase.connecting => line(
        'Connecting to $name…',
        icon: Icons.cast_rounded,
        color: oampAccent,
      ),
      OutputPhase.local when output.message != null => line(
        output.message!,
        icon: Icons.cast_rounded,
        color: OAmpColors.textMuted,
      ),
      _ => line(artist ?? ''),
    };
  }
}

class _MiniPlayPause extends ConsumerWidget {
  const _MiniPlayPause();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playerProvider.select((s) => s.playing));
    return IconButton(
      tooltip: playing ? 'Pause' : 'Play',
      iconSize: 30,
      onPressed: ref.read(playerProvider.notifier).togglePlay,
      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
    );
  }
}

class _Progress extends ConsumerWidget {
  const _Progress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final dur =
        ref.watch(durationProvider).value ??
        ref.watch(playerProvider.select((s) => s.current?.duration));
    final v = (dur == null || dur == Duration.zero)
        ? 0.0
        : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    return LinearProgressIndicator(
      value: v,
      minHeight: 2,
      color: Colors.white,
      backgroundColor: Colors.white12,
    );
  }
}

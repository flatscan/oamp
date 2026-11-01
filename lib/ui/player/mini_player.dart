import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
                                    Text(
                                      track.artist ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: t.bodySmall,
                                    ),
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

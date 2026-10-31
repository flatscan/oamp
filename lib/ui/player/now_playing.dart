import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/player.dart';
import '../cover_art.dart';

/// Artwork, track info, scrubber and transport controls.
///
/// [compact] shows a small thumbnail beside the text (used when the window is
/// short); otherwise the artwork is a large square, Plexamp style.
class NowPlaying extends ConsumerWidget {
  final bool compact;
  const NowPlaying({super.key, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((s) => s.current));
    final t = Theme.of(context).textTheme;

    final info = Column(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track?.title ?? 'Nothing playing',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: compact ? t.titleMedium : t.titleLarge,
        ),
        Text(
          [track?.artist, track?.album].whereType<String>().join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.bodyMedium,
        ),
      ],
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          children: [
            Row(
              children: [
                CoverArt(track?.coverArt, size: 56),
                const SizedBox(width: 12),
                Expanded(child: info),
                const _Transport(small: true),
              ],
            ),
            const _Scrubber(),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final size = c.maxWidth.clamp(120.0, 360.0);
              return CoverArt(track?.coverArt, size: size, radius: 8);
            },
          ),
          const SizedBox(height: 16),
          info,
          const _Scrubber(),
          const _Transport(),
        ],
      ),
    );
  }
}

class _Scrubber extends ConsumerStatefulWidget {
  const _Scrubber();

  @override
  ConsumerState<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends ConsumerState<_Scrubber> {
  double? _dragValue; // seconds, while the user is dragging

  @override
  Widget build(BuildContext context) {
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final dur =
        ref.watch(durationProvider).value ??
        ref.watch(playerProvider.select((s) => s.current?.duration)) ??
        Duration.zero;
    final max = dur.inMilliseconds / 1000.0;
    final value = (_dragValue ?? pos.inMilliseconds / 1000.0).clamp(0.0, max);
    final small = Theme.of(context).textTheme.bodySmall;

    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            formatDuration(Duration(seconds: value.round())),
            style: small,
          ),
        ),
        Expanded(
          child: Slider(
            value: max > 0 ? value : 0,
            max: max > 0 ? max : 1,
            onChanged: max > 0 ? (v) => setState(() => _dragValue = v) : null,
            onChangeEnd: (v) {
              ref
                  .read(playerProvider.notifier)
                  .seek(Duration(milliseconds: (v * 1000).round()));
              setState(() => _dragValue = null);
            },
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            formatDuration(dur),
            textAlign: TextAlign.right,
            style: small,
          ),
        ),
      ],
    );
  }
}

class _Transport extends ConsumerWidget {
  final bool small;
  const _Transport({this.small = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playerProvider);
    final p = ref.read(playerProvider.notifier);
    final enabled = s.queue.isNotEmpty;

    final playIcon = s.buffering
        ? const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(s.playing ? Icons.pause : Icons.play_arrow);

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Previous',
          onPressed: enabled ? p.previous : null,
          icon: const Icon(Icons.skip_previous),
        ),
        small
            ? IconButton(
                tooltip: s.playing ? 'Pause' : 'Play',
                onPressed: enabled ? p.togglePlay : null,
                icon: playIcon,
              )
            : IconButton.filled(
                iconSize: 36,
                tooltip: s.playing ? 'Pause' : 'Play',
                onPressed: enabled ? p.togglePlay : null,
                icon: playIcon,
              ),
        IconButton(
          tooltip: 'Next',
          onPressed: s.hasNext ? p.next : null,
          icon: const Icon(Icons.skip_next),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/player.dart';
import '../cover_art.dart';
import '../theme.dart';

/// Thin seek bar with elapsed and remaining time underneath.
class Scrubber extends ConsumerStatefulWidget {
  const Scrubber({super.key});

  @override
  ConsumerState<Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends ConsumerState<Scrubber> {
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
    final small = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: OAmpColors.textMuted);
    final remaining = dur - Duration(seconds: value.round());

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context)
              .copyWith(padding: const EdgeInsets.symmetric(vertical: 8)),
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
        Row(
          children: [
            Text(
              formatDuration(Duration(seconds: value.round())),
              style: small,
            ),
            const Spacer(),
            Text(max > 0 ? '-${formatDuration(remaining)}' : '', style: small),
          ],
        ),
      ],
    );
  }
}

/// Repeat, previous, play/pause, next and shuffle.
class TransportControls extends ConsumerWidget {
  const TransportControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playerProvider);
    final p = ref.read(playerProvider.notifier);
    final enabled = s.queue.isNotEmpty;

    final repeatLabel = switch (s.repeat) {
      PlaybackRepeat.off => 'Repeat is off',
      PlaybackRepeat.all => 'Repeating queue',
      PlaybackRepeat.one => 'Repeating track',
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          tooltip: repeatLabel,
          onPressed: p.cycleRepeat,
          color: s.repeat == PlaybackRepeat.off
              ? OAmpColors.textMuted
              : oampAccent,
          icon: Icon(
            s.repeat == PlaybackRepeat.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
          ),
        ),
        IconButton(
          tooltip: 'Previous',
          iconSize: 38,
          onPressed: enabled ? p.previous : null,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        PlayPauseButton(size: 68, enabled: enabled),
        IconButton(
          tooltip: 'Next',
          iconSize: 38,
          onPressed: s.hasNext ? p.next : null,
          icon: const Icon(Icons.skip_next_rounded),
        ),
        IconButton(
          tooltip: 'Shuffle up next',
          onPressed: s.upcoming.length > 1 ? p.shuffleUpcoming : null,
          color: OAmpColors.textMuted,
          icon: const Icon(Icons.shuffle_rounded),
        ),
      ],
    );
  }
}

/// The big round white play/pause button.
class PlayPauseButton extends ConsumerWidget {
  final double size;
  final bool enabled;
  const PlayPauseButton({super.key, required this.size, this.enabled = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playerProvider.select((s) => s.playing));
    final buffering = ref.watch(playerProvider.select((s) => s.buffering));
    final p = ref.read(playerProvider.notifier);
    return SizedBox.square(
      dimension: size,
      child: IconButton.filled(
        tooltip: playing ? 'Pause' : 'Play',
        style: IconButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          disabledBackgroundColor: Colors.white24,
        ),
        iconSize: size * 0.55,
        onPressed: enabled ? p.togglePlay : null,
        icon: buffering && playing
            ? SizedBox.square(
                dimension: size * 0.4,
                child: const CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.black,
                ),
              )
            : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
      ),
    );
  }
}

/// Volume icon (click to mute) and slider.
class VolumeControl extends ConsumerStatefulWidget {
  const VolumeControl({super.key});

  @override
  ConsumerState<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<VolumeControl> {
  double _beforeMute = 1;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(playerProvider.select((s) => s.volume));
    final p = ref.read(playerProvider.notifier);
    return Row(
      children: [
        IconButton(
          tooltip: v == 0 ? 'Unmute' : 'Mute',
          color: OAmpColors.textMuted,
          icon: Icon(
            v == 0
                ? Icons.volume_off_rounded
                : v < 0.5
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
            size: 20,
          ),
          onPressed: () {
            if (v == 0) {
              p.setVolume(_beforeMute == 0 ? 1 : _beforeMute);
            } else {
              _beforeMute = v;
              p.setVolume(0);
            }
          },
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: OAmpColors.textMuted,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            ),
            child: Slider(value: v, onChanged: p.setVolume),
          ),
        ),
      ],
    );
  }
}

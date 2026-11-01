import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/player.dart';
import '../cover_art.dart';
import '../theme.dart';

/// Seek bar with the elapsed time on the left and the length on the right.
class SeekBar extends ConsumerStatefulWidget {
  final Color accent;
  const SeekBar({super.key, this.accent = Colors.white});

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
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
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            formatDuration(Duration(seconds: value.round())),
            style: style,
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: widget.accent,
              thumbColor: widget.accent,
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
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
        ),
        SizedBox(
          width: 48,
          child: Text(
            max > 0 ? formatDuration(dur) : '',
            textAlign: TextAlign.right,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// Previous, play/pause and next.
class TransportControls extends ConsumerWidget {
  final Color playColor;
  const TransportControls({super.key, required this.playColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(playerProvider.select((s) => s.queue.isNotEmpty));
    final hasNext = ref.watch(playerProvider.select((s) => s.hasNext));
    final p = ref.read(playerProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Previous',
          iconSize: 40,
          onPressed: enabled ? p.previous : null,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        const SizedBox(width: 20),
        PlayPauseButton(size: 64, enabled: enabled, color: playColor),
        const SizedBox(width: 20),
        IconButton(
          tooltip: 'Next',
          iconSize: 40,
          onPressed: hasNext ? p.next : null,
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );
  }
}

/// The big round play/pause button.
class PlayPauseButton extends ConsumerWidget {
  final double size;
  final bool enabled;
  final Color color;
  const PlayPauseButton({
    super.key,
    required this.size,
    this.enabled = true,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playerProvider.select((s) => s.playing));
    final buffering = ref.watch(playerProvider.select((s) => s.buffering));
    final p = ref.read(playerProvider.notifier);
    final onColor = color.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    return SizedBox.square(
      dimension: size,
      child: IconButton.filled(
        tooltip: playing ? 'Pause' : 'Play',
        style: IconButton.styleFrom(
          backgroundColor: color,
          foregroundColor: onColor,
          disabledBackgroundColor: Colors.white12,
        ),
        iconSize: size * 0.55,
        onPressed: enabled ? p.togglePlay : null,
        icon: buffering && playing
            ? SizedBox.square(
                dimension: size * 0.4,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: onColor,
                ),
              )
            : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
      ),
    );
  }
}

/// Cycles repeat off, repeat queue and repeat track.
class RepeatButton extends ConsumerWidget {
  const RepeatButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repeat = ref.watch(playerProvider.select((s) => s.repeat));
    return IconButton(
      tooltip: switch (repeat) {
        PlaybackRepeat.off => 'Repeat is off',
        PlaybackRepeat.all => 'Repeating queue',
        PlaybackRepeat.one => 'Repeating track',
      },
      onPressed: ref.read(playerProvider.notifier).cycleRepeat,
      isSelected: repeat != PlaybackRepeat.off,
      style: _toggleStyle,
      icon: Icon(
        repeat == PlaybackRepeat.one
            ? Icons.repeat_one_rounded
            : Icons.repeat_rounded,
      ),
    );
  }
}

/// Puts up next in a random order.
class ShuffleButton extends ConsumerWidget {
  const ShuffleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canShuffle = ref.watch(
      playerProvider.select((s) => s.upcoming.length > 1),
    );
    return IconButton(
      tooltip: 'Shuffle up next',
      onPressed: canShuffle
          ? ref.read(playerProvider.notifier).shuffleUpcoming
          : null,
      style: _toggleStyle,
      icon: const Icon(Icons.shuffle_rounded),
    );
  }
}

/// Small rounded-square buttons for the row under the transport controls;
/// a selected one gets a light background.
final _toggleStyle = ButtonStyle(
  iconSize: const WidgetStatePropertyAll(22),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  ),
  foregroundColor: WidgetStateProperty.resolveWith(
    (s) => s.contains(WidgetState.disabled)
        ? OAmpColors.textFaint
        : s.contains(WidgetState.selected)
        ? Colors.white
        : OAmpColors.textMuted,
  ),
  backgroundColor: WidgetStateProperty.resolveWith(
    (s) => s.contains(WidgetState.selected) ? Colors.white24 : null,
  ),
);

/// Volume icon (click to mute) and slider.
class VolumeControl extends ConsumerStatefulWidget {
  final Color accent;
  const VolumeControl({super.key, this.accent = Colors.white});

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
              trackHeight: 3,
              activeTrackColor: widget.accent,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(value: v, onChanged: p.setVolume),
          ),
        ),
      ],
    );
  }
}

/// "FLAC · 44.1 / 16" or "MP3 · 320 kbps", or null when the server did
/// not say.
String? qualityLabel(Track t) {
  final parts = <String>[
    if (t.format != null) t.format!.toUpperCase(),
    if (t.sampleRate != null && t.bitDepth != null)
      '${_khz(t.sampleRate!)} / ${t.bitDepth}'
    else if (t.bitRate != null && t.bitRate! > 0)
      '${t.bitRate} kbps',
  ];
  return parts.isEmpty ? null : parts.join('  ·  ');
}

String _khz(int hz) {
  final k = hz / 1000;
  return k == k.roundToDouble() ? '${k.round()}' : k.toStringAsFixed(1);
}

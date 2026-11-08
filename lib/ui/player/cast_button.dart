import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/output_device.dart';
import '../../platform/platform_info.dart';
import '../../state/outputs.dart';
import '../theme.dart';

/// The icon for a speaker or TV.
IconData deviceIcon(OutputDevice device) {
  if (device.isGroup) return Icons.speaker_group_rounded;
  if (device.hasScreen) return Icons.tv_rounded;
  return Icons.speaker_rounded;
}

/// Opens the list of speakers and TVs to play on. Sits over the top-left
/// corner of the now playing artwork, opposite the mode switch.
///
/// Hidden where casting isn't available (the web, iOS and macOS for now).
class CastButton extends ConsumerWidget {
  /// Gives it the dark circle the other buttons over the artwork have, so
  /// it stays visible on light covers.
  final bool overArt;
  const CastButton({super.key, this.overArt = false});

  static const size = 48.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(castingAvailableProvider)) {
      return const SizedBox.square(dimension: size);
    }
    final output = ref.watch(outputProvider);
    final connected = output.isConnected;
    final color = output.isRemote
        ? oampAccent
        : (overArt ? Colors.white : OAmpColors.textMuted);
    final icon = Icon(
      connected ? Icons.cast_connected_rounded : Icons.cast_rounded,
    );
    final button = IconButton(
      tooltip: switch (output.phase) {
        OutputPhase.local => 'Play on…',
        OutputPhase.connecting => 'Connecting to ${output.device?.name}',
        OutputPhase.connected => 'Playing on ${output.device?.name}',
      },
      padding: EdgeInsets.zero,
      iconSize: 20,
      color: color,
      style: overArt
          ? IconButton.styleFrom(
              backgroundColor: Colors.black45,
              hoverColor: Colors.white24,
              fixedSize: const Size.square(40),
              minimumSize: const Size.square(40),
            )
          : null,
      icon: output.phase == OutputPhase.connecting
          ? Stack(
              alignment: Alignment.center,
              children: [
                icon,
                SizedBox.square(
                  dimension: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                ),
              ],
            )
          : icon,
      onPressed: () => showCastPicker(context),
    );
    return SizedBox.square(
      dimension: size,
      child: overArt ? Center(child: button) : button,
    );
  }
}

/// The list of places to play: this device, then every speaker and TV
/// found on the network.
Future<void> showCastPicker(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  backgroundColor: OAmpColors.surfaceHigh,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => const CastPicker(),
);

class CastPicker extends ConsumerStatefulWidget {
  const CastPicker({super.key});

  /// How long to look before saying nothing was found.
  static const searchTime = Duration(seconds: 8);

  @override
  ConsumerState<CastPicker> createState() => _CastPickerState();
}

class _CastPickerState extends ConsumerState<CastPicker> {
  Timer? _searching;
  bool _searched = false;

  /// The device picked here, so the sheet closes once it is playing.
  String? _picked;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(deviceDiscoveryProvider).scan());
    _searching = Timer(CastPicker.searchTime, () {
      if (mounted) setState(() => _searched = true);
    });
  }

  @override
  void dispose() {
    _searching?.cancel();
    super.dispose();
  }

  void _pick(OutputDevice device) {
    final output = ref.read(outputProvider);
    if (output.isRemote && output.device?.key == device.key) return;
    _picked = device.key;
    unawaited(ref.read(outputProvider.notifier).connect(device));
  }

  void _pickHere() {
    _picked = null;
    unawaited(ref.read(outputProvider.notifier).disconnect());
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(outputProvider, (before, now) {
      // Close once the chosen device is playing.
      if (now.isConnected &&
          now.device?.key == _picked &&
          before?.isConnected != true) {
        _picked = null;
        Navigator.of(context).maybePop();
      }
    });
    final devices = ref.watch(nearbyDevicesProvider).value ?? const [];
    final output = ref.watch(outputProvider);
    final t = Theme.of(context).textTheme;
    final here = !output.isRemote;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Play on', style: t.titleLarge),
            ),
            if (output.message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  output.message!,
                  style: t.bodyMedium?.copyWith(color: oampAccent),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _PlaceTile(
                    icon: isDesktop
                        ? Icons.computer_rounded
                        : Icons.smartphone_rounded,
                    title: 'This device',
                    selected: here,
                    onTap: _pickHere,
                  ),
                  for (final d in devices)
                    _PlaceTile(
                      icon: deviceIcon(d),
                      title: d.name,
                      selected: output.device?.key == d.key && output.isRemote,
                      connecting:
                          output.device?.key == d.key &&
                          output.phase == OutputPhase.connecting,
                      onTap: () => _pick(d),
                    ),
                  if (output.isConnected) const _DeviceVolume(),
                  if (devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                      child: _searched
                          ? Text(
                              'No speakers or TVs found. They need to be on '
                              'the same network as this device.',
                              style: t.bodyMedium?.copyWith(
                                color: OAmpColors.textMuted,
                              ),
                            )
                          : Row(
                              children: [
                                const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Looking for speakers and TVs…',
                                    style: t.bodyMedium?.copyWith(
                                      color: OAmpColors.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool selected;
  final bool connecting;
  final VoidCallback onTap;

  const _PlaceTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    this.connecting = false,
  });

  @override
  Widget build(BuildContext context) {
    final highlight = selected || connecting;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Icon(icon, color: highlight ? oampAccent : null),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: highlight ? const TextStyle(color: oampAccent) : null,
      ),
      trailing: connecting
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : selected
          ? const Icon(Icons.check_rounded, color: oampAccent)
          : null,
      onTap: onTap,
    );
  }
}

/// The speaker or TV's own volume, under its entry in the picker.
class _DeviceVolume extends ConsumerWidget {
  const _DeviceVolume();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(outputProvider.select((s) => s.volume));
    final outputs = ref.read(outputProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
      child: Row(
        children: [
          const Icon(
            Icons.volume_down_rounded,
            size: 20,
            color: OAmpColors.textMuted,
          ),
          Expanded(
            child: Slider(
              value: volume ?? 0.5,
              onChanged: volume == null ? null : outputs.setVolume,
            ),
          ),
          const Icon(
            Icons.volume_up_rounded,
            size: 20,
            color: OAmpColors.textMuted,
          ),
        ],
      ),
    );
  }
}

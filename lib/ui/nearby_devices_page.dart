import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/output_device.dart';
import '../state/outputs.dart';
import 'theme.dart';
import 'widgets.dart';

/// A test page listing the speakers and TVs OAmp can find, opened by a
/// long press on the version in Settings. It is there to check discovery
/// on real networks before casting itself is built.
class NearbyDevicesPage extends ConsumerStatefulWidget {
  const NearbyDevicesPage({super.key});

  @override
  ConsumerState<NearbyDevicesPage> createState() => _NearbyDevicesPageState();
}

class _NearbyDevicesPageState extends ConsumerState<NearbyDevicesPage> {
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      await ref.read(deviceDiscoveryProvider).scan();
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(nearbyDevicesProvider).value ?? const [];
    final output = ref.watch(outputProvider);
    final outputs = ref.read(outputProvider.notifier);
    return ListScaffold(
      title: 'Nearby devices',
      onRefresh: _scan,
      actions: [
        IconButton(
          tooltip: 'Scan again',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _scanning ? null : _scan,
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _scanning
                  ? 'Looking for Cast and DLNA devices…'
                  : devices.isEmpty
                  ? 'Nothing found. Check this device is on the same network '
                        'as your speakers and TVs.'
                  : 'Found ${devices.length}. Tap one to play there; tap '
                        'it again to bring playback back here. A test page '
                        'until the cast button arrives.',
              style: const TextStyle(color: OAmpColors.textMuted),
            ),
          ),
        ),
        if (_scanning)
          const SliverToBoxAdapter(child: LinearProgressIndicator()),
        if (output.message != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(output.message!),
            ),
          ),
        SliverList.list(
          children: [
            for (final d in devices)
              _DeviceTile(
                device: d,
                phase: output.device?.key == d.key ? output.phase : null,
                onTap: () => output.device?.key == d.key && output.isRemote
                    ? outputs.disconnect()
                    : outputs.connect(d),
              ),
          ],
        ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final OutputDevice device;

  /// Set when playback is going to this device.
  final OutputPhase? phase;
  final VoidCallback onTap;
  const _DeviceTile({required this.device, required this.onTap, this.phase});

  @override
  Widget build(BuildContext context) {
    final icon = device.isGroup
        ? Icons.speaker_group_rounded
        : device.hasScreen
        ? Icons.tv_rounded
        : switch (device.protocol) {
            OutputProtocol.cast => Icons.cast_rounded,
            OutputProtocol.dlna => Icons.speaker_rounded,
          };
    return ListTile(
      leading: Icon(icon, color: phase == null ? null : oampAccent),
      onTap: onTap,
      trailing: switch (phase) {
        OutputPhase.connecting => const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        OutputPhase.connected => const Text('Playing here'),
        _ => null,
      },
      title: Text(device.name),
      subtitle: Text(
        [
          device.protocol.label,
          ?device.model,
          '${device.host}:${device.port}',
        ].join(' · '),
      ),
    );
  }
}

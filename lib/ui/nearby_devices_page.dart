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
                  : 'Found ${devices.length}. Casting itself isn’t built '
                        'yet; this list checks that OAmp can find them.',
              style: const TextStyle(color: OAmpColors.textMuted),
            ),
          ),
        ),
        if (_scanning)
          const SliverToBoxAdapter(child: LinearProgressIndicator()),
        SliverList.list(
          children: [for (final d in devices) _DeviceTile(device: d)],
        ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final OutputDevice device;
  const _DeviceTile({required this.device});

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
      leading: Icon(icon),
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

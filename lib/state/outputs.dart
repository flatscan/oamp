import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/output_device.dart';

/// Finds speakers and TVs to play to. main.dart swaps in the network
/// finder on Windows and Android; tests and the web find nothing.
final deviceDiscoveryProvider = Provider<DeviceDiscovery>(
  (_) => const NoDeviceDiscovery(),
);

/// The speakers and TVs found so far, merged across protocols.
final nearbyDevicesProvider = StreamProvider<List<OutputDevice>>(
  (ref) => ref.watch(deviceDiscoveryProvider).devices,
);

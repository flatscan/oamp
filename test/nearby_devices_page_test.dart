import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/output_device.dart';
import 'package:oamp/state/outputs.dart';
import 'package:oamp/ui/nearby_devices_page.dart';
import 'package:oamp/ui/theme.dart';

// Kept apart from output_discovery_test.dart: widget tests stub out real
// HTTP, which the loopback discovery test needs.
void main() {
  testWidgets('the test page scans and lists what it finds', (tester) async {
    final fake = _FakeDiscovery();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [deviceDiscoveryProvider.overrideWithValue(fake)],
        child: MaterialApp(
          theme: buildTheme(),
          home: const NearbyDevicesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.scans, 1);
    expect(find.text('Living room TV'), findsOneWidget);
    expect(find.textContaining('Cast · Chromecast'), findsOneWidget);
    await tester.tap(find.byTooltip('Scan again'));
    await tester.pumpAndSettle();
    expect(fake.scans, 2);
  });
}

class _FakeDiscovery implements DeviceDiscovery {
  int scans = 0;
  @override
  List<OutputDevice> current = const [];

  @override
  Stream<List<OutputDevice>> get devices => Stream.value(const [
    OutputDevice(
      id: 'abc',
      protocol: OutputProtocol.cast,
      name: 'Living room TV',
      model: 'Chromecast',
      host: '192.168.1.20',
      port: 8009,
      hasScreen: true,
    ),
  ]);

  @override
  bool get scanning => false;

  @override
  Future<void> scan() async => scans++;

  @override
  Future<void> dispose() async {}
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/output_device.dart';
import 'package:oamp/core/remote_player.dart';
import 'package:oamp/main.dart';
import 'package:oamp/state/outputs.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';
import 'package:oamp/ui/player/cast_button.dart';
import 'package:oamp/ui/player/mini_player.dart';

import 'fakes/fake_remote_player.dart';
import 'fakes/fakes.dart';

const _tv = OutputDevice(
  id: 'tv',
  protocol: OutputProtocol.dlna,
  name: 'Living room TV',
  host: '192.0.2.5',
  port: 9197,
  hasScreen: true,
);

class _Discovery implements DeviceDiscovery {
  int scans = 0;
  @override
  List<OutputDevice> current = const [_tv];
  @override
  Stream<List<OutputDevice>> get devices => Stream.value(const [_tv]);
  @override
  bool get scanning => false;
  @override
  Future<void> scan() async => scans++;

  @override
  Future<void> dispose() async {}
}

void main() {
  late FakeAudioEngine engine;
  late _Discovery discovery;
  late List<FakeRemotePlayer> players;

  Future<void> pumpApp(WidgetTester tester, {bool casting = true}) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    engine = FakeAudioEngine();
    discovery = _Discovery();
    players = [];
    final source = FakeMusicSource();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
          audioEngineProvider.overrideWithValue(engine),
          castingAvailableProvider.overrideWithValue(casting),
          deviceDiscoveryProvider.overrideWithValue(discovery),
          remoteConnectorProvider.overrideWithValue((device) async {
            final p = FakeRemotePlayer(device);
            players.add(p);
            return p;
          }),
        ],
        child: const OAmpApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openNowPlaying(WidgetTester tester) async {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(OAmpApp)),
    );
    await container.read(playerProvider.notifier).playTracks([
      for (var i = 0; i < 3; i++)
        Track(
          id: 't$i',
          title: 'Track $i',
          format: 'flac',
          duration: const Duration(minutes: 3),
        ),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();
  }

  /// Picks the TV, which then reports playing (until it does, the app
  /// shows it buffering).
  Future<void> connectTv(WidgetTester tester) async {
    await tester.tap(find.text('Living room TV'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    players.single.report(
      const RemoteStatus(state: RemoteState.playing, volume: 0.4),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the list looks again by itself and on the refresh button', (
    tester,
  ) async {
    await pumpApp(tester);
    await openNowPlaying(tester);
    await tester.tap(find.byTooltip('Play on…'));
    await tester.pump();
    expect(discovery.scans, 1);

    await tester.pump(CastPicker.rescanEvery);
    expect(discovery.scans, 2);
    await tester.pump(CastPicker.rescanEvery);
    expect(discovery.scans, 3);

    // The button looks again at once.
    await tester.tap(find.byTooltip('Look for speakers and TVs again'));
    await tester.pump();
    expect(discovery.scans, 4);

    // In the background the list stops looking, and looks again at once
    // when the app is back.
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final asleep = discovery.scans;
    await tester.pump(CastPicker.rescanEvery * 3);
    expect(discovery.scans, asleep);
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(discovery.scans, asleep + 1);
    await tester.pump(CastPicker.rescanEvery);
    expect(discovery.scans, asleep + 2);

    // Closing the list stops the repeats.
    await tester.tap(find.text('This device'));
    await tester.pumpAndSettle();
    final before = discovery.scans;
    await tester.pump(CastPicker.rescanEvery * 3);
    expect(discovery.scans, before);
  });

  testWidgets('cast from now playing and back', (tester) async {
    await pumpApp(tester);
    await openNowPlaying(tester);

    await tester.tap(find.byTooltip('Play on…'));
    await tester.pumpAndSettle();
    expect(discovery.scans, 1);
    expect(find.text('Play on'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);

    await connectTv(tester);
    // Connected: the picker closes and the device takes over.
    expect(find.text('Play on'), findsNothing);
    expect(players.single.current, isNotNull);
    expect(find.byTooltip('Playing on Living room TV'), findsOneWidget);

    // The picker shows the device's volume while casting.
    await tester.tap(find.byTooltip('Playing on Living room TV'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsWidgets);

    await tester.tap(find.text('This device'));
    await tester.pumpAndSettle();
    expect(players.single.closedWithStop, isTrue);
    expect(find.byTooltip('Play on…'), findsOneWidget);
    expect(engine.queue, isNotEmpty, reason: 'playback is back here');
  });

  testWidgets('the mini player says where it is playing', (tester) async {
    await pumpApp(tester);
    await openNowPlaying(tester);
    await tester.tap(find.byTooltip('Play on…'));
    await tester.pumpAndSettle();
    await connectTv(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Playing on Living room TV'), findsOneWidget);
  });

  testWidgets('no cast button where casting is not available', (tester) async {
    await pumpApp(tester, casting: false);
    await openNowPlaying(tester);
    expect(find.byType(CastButton), findsOneWidget);
    expect(find.byTooltip('Play on…'), findsNothing);
  });
}

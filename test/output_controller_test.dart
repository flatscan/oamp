import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/output_device.dart';
import 'package:oamp/core/remote_player.dart';
import 'package:oamp/state/outputs.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fake_remote_player.dart';
import 'fakes/fakes.dart';

void main() {
  late FakeAudioEngine local;
  late FakeMusicSource source;
  late ProviderContainer container;
  late List<FakeRemotePlayer> devices;
  Object? connectError;

  final tracks = [
    for (var i = 0; i < 3; i++)
      Track(
        id: 't$i',
        title: 'Track $i',
        format: i == 1 ? 'dsf' : 'flac',
        duration: const Duration(minutes: 3),
      ),
  ];

  setUp(() async {
    local = FakeAudioEngine();
    source = FakeMusicSource();
    devices = [];
    connectError = null;
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        audioEngineProvider.overrideWithValue(local),
        remoteConnectorProvider.overrideWithValue((device) async {
          if (connectError != null) throw connectError!;
          final d = FakeRemotePlayer(device);
          devices.add(d);
          return d;
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  PlayerController player() => container.read(playerProvider.notifier);
  OutputController outputs() => container.read(outputProvider.notifier);
  OutputState output() => container.read(outputProvider);

  test('casting carries on from the same track and spot', () async {
    await player().playTracks(tracks, startIndex: 0);
    await settle();
    local.currentPosition = const Duration(seconds: 50);

    await outputs().connect(fakeCastDevice);
    expect(output().phase, OutputPhase.connected);
    expect(output().device, fakeCastDevice);
    final d = devices.single;
    expect(d.current!.url, source.streamUrl('t0'));
    expect(d.current!.contentType, 'audio/flac');
    expect(d.loadedAt, const Duration(seconds: 50));
    expect(d.playing, isTrue);
    // A format the device can't play comes transcoded from the server.
    expect(d.next!.url, source.streamUrl('t1', quality: remoteTranscode));
    expect(d.next!.contentType, 'audio/mpeg');
    expect(d.next!.transcoded, isTrue);
    expect(d.current!.transcoded, isFalse);
    expect(local.queue, isEmpty);
  });

  test('the player follows the device as it moves on', () async {
    await player().playTracks(tracks, startIndex: 0);
    await settle();
    await outputs().connect(fakeCastDevice);
    devices.single.moveOn();
    await settle();
    expect(container.read(playerProvider).currentIndex, 1);
    await player().next();
    expect(devices.single.current!.url, source.streamUrl('t2'));
  });

  test('disconnecting brings playback back paused at the same spot', () async {
    await player().playTracks(tracks, startIndex: 0);
    await settle();
    await outputs().connect(fakeCastDevice);
    final d = devices.single
      ..report(
        const RemoteStatus(
          state: RemoteState.playing,
          position: Duration(seconds: 70),
        ),
      );
    await settle();

    await outputs().disconnect();
    expect(output().phase, OutputPhase.local);
    expect(d.closedWithStop, isTrue);
    expect(local.queue, hasLength(3));
    expect(local.index, 0);
    expect(local.startPosition, const Duration(seconds: 70));
    expect(local.playing, isFalse);
  });

  test('a device that drops off comes back here with a message', () async {
    await player().playTracks(tracks, startIndex: 0);
    await settle();
    await outputs().connect(fakeCastDevice);
    devices.single.drop();
    await settle();
    await settle();
    expect(output().phase, OutputPhase.local);
    expect(output().message, 'Lost the connection to Kitchen');
    expect(local.queue, hasLength(3));
    expect(local.playing, isFalse);
  });

  test('a failed connection leaves playback here', () async {
    await player().playTracks(tracks, startIndex: 0);
    await settle();
    connectError = StateError('refused');
    await outputs().connect(fakeCastDevice);
    expect(output().phase, OutputPhase.local);
    expect(output().message, 'Couldn’t connect to Kitchen');
    expect(local.queue, hasLength(3));
  });

  test('switching devices stops the first one', () async {
    await player().playTracks(tracks, startIndex: 0);
    await settle();
    await outputs().connect(fakeCastDevice);
    const tv = OutputDevice(
      id: 'tv',
      protocol: OutputProtocol.dlna,
      name: 'TV',
      host: '192.0.2.9',
      port: 9197,
    );
    await outputs().connect(tv);
    expect(devices, hasLength(2));
    expect(devices.first.closedWithStop, isTrue);
    expect(output().device, tv);
    expect(devices.last.current!.url, source.streamUrl('t0'));
    // The FLAC type DLNA renderers list.
    expect(devices.last.current!.contentType, 'audio/x-flac');
  });
}

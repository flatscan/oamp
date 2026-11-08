import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/output_device.dart';
import 'package:oamp/core/remote_player.dart';
import 'package:oamp/outputs/cast/cast_channel.dart';
import 'package:oamp/outputs/cast/cast_player.dart';

RemoteMedia _m(int i) => RemoteMedia(
  url: Uri.parse('http://server/stream/$i'),
  contentType: 'audio/flac',
  title: 'Track $i',
  duration: const Duration(minutes: 3),
);

/// A Cast device on loopback that speaks just enough of the protocol:
/// receiver status and launch, and a media queue.
class FakeCastDevice {
  late final ServerSocket _server;
  Socket? _socket;
  final _buffer = BytesBuilder();
  final received = <CastMessage>[];
  final _arrived = StreamController<CastMessage>.broadcast();

  bool appRunning = false;
  List<int> items = [];
  int? currentItem;
  int _nextItemId = 1;
  String playerState = 'IDLE';
  double currentTime = 0;
  bool stopped = false;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((s) {
      _socket = s;
      s.listen(_onData);
    });
  }

  Future<void> close() async {
    await _socket?.close();
    await _server.close();
  }

  Future<CastMessage> next(String type) =>
      _arrived.stream.firstWhere((m) => m.type == type);

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    while (bytes.length >= 4) {
      final len = ByteData.sublistView(bytes).getUint32(0);
      if (bytes.length < 4 + len) break;
      final m = CastMessage.decode(bytes.sublist(4, 4 + len));
      bytes = bytes.sublist(4 + len);
      if (m != null) _handle(m);
    }
    _buffer.add(bytes);
  }

  void send(String ns, Map<String, dynamic> payload, {String from = 't-1'}) {
    final bytes = CastMessage(
      source: from,
      destination: CastChannel.senderId,
      namespace: ns,
      payload: payload,
    ).encode();
    _socket!
      ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
      ..add(bytes);
  }

  Map<String, dynamic> _receiverStatus() => {
    'volume': {'level': 0.5, 'muted': false},
    'applications': [
      if (appRunning)
        {'appId': 'CC1AD845', 'sessionId': 's-1', 'transportId': 't-1'},
    ],
  };

  Map<String, dynamic> mediaStatus() => {
    'mediaSessionId': 7,
    'playerState': playerState,
    if (playerState == 'IDLE') 'idleReason': 'FINISHED',
    'currentTime': currentTime,
    'currentItemId': ?currentItem,
    'items': [
      for (final i in items) {'itemId': i},
    ],
    'media': {'duration': 180},
  };

  /// Pretends the current track finished and the next began.
  void moveOn() {
    final at = items.indexOf(currentItem!);
    if (at + 1 < items.length) {
      currentItem = items[at + 1];
      currentTime = 0;
      playerState = 'PLAYING';
    } else {
      playerState = 'IDLE';
    }
    send(CastChannel.mediaNs, {
      'type': 'MEDIA_STATUS',
      'requestId': 0,
      'status': [mediaStatus()],
    });
  }

  void _handle(CastMessage m) {
    received.add(m);
    _arrived.add(m);
    final id = m.requestId;
    if (m.namespace == CastChannel.receiverNs) {
      switch (m.type) {
        case 'GET_STATUS':
          break;
        case 'LAUNCH':
          appRunning = true;
        case 'STOP':
          appRunning = false;
          stopped = true;
        default:
          return;
      }
      send(CastChannel.receiverNs, {
        'type': 'RECEIVER_STATUS',
        'requestId': id,
        'status': _receiverStatus(),
      }, from: CastChannel.receiverId);
      return;
    }
    if (m.namespace != CastChannel.mediaNs) return;
    final p = m.payload;
    switch (m.type) {
      case 'QUEUE_LOAD':
        items = [for (final _ in p['items'] as List) _nextItemId++];
        currentItem = items.first;
        currentTime = (p['currentTime'] as num).toDouble();
        final autoplay = (p['items'] as List).first['autoplay'] as bool;
        playerState = autoplay ? 'PLAYING' : 'PAUSED';
      case 'QUEUE_INSERT':
        items.addAll([for (final _ in p['items'] as List) _nextItemId++]);
      case 'QUEUE_REMOVE':
        items.removeWhere((i) => (p['itemIds'] as List).contains(i));
      case 'QUEUE_GET_ITEM_IDS':
        send(CastChannel.mediaNs, {
          'type': 'QUEUE_ITEM_IDS',
          'requestId': id,
          'itemIds': items,
        });
        return;
      case 'PLAY':
        playerState = 'PLAYING';
      case 'PAUSE':
        playerState = 'PAUSED';
      case 'SEEK':
        currentTime = (p['currentTime'] as num).toDouble();
      case 'STOP':
        playerState = 'IDLE';
        items = [];
        currentItem = null;
    }
    send(CastChannel.mediaNs, {
      'type': 'MEDIA_STATUS',
      'requestId': id,
      'status': [mediaStatus()],
    });
  }
}

void main() {
  late FakeCastDevice fake;
  late CastPlayer player;

  setUp(() async {
    fake = FakeCastDevice();
    await fake.start();
    player = await CastPlayer.connect(
      OutputDevice(
        id: 'cast',
        protocol: OutputProtocol.cast,
        name: 'Kitchen',
        host: InternetAddress.loopbackIPv4.address,
        port: fake.port,
      ),
      open: (h, p) async => CastChannel.open(await Socket.connect(h, p)),
    );
  });

  tearDown(() async {
    await player.close();
    await fake.close();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('launches the default receiver and reads its volume', () async {
    expect(fake.appRunning, isTrue);
    expect(fake.received.map((m) => m.type), contains('LAUNCH'));
    final status = player.status.first;
    await player.load(_m(0), play: false);
    expect((await status).volume, 0.5);
  });

  test('loads two tracks and lines up the next when it moves on', () async {
    await player.load(
      _m(0),
      next: _m(1),
      position: const Duration(seconds: 20),
    );
    expect(fake.items, hasLength(2));
    expect(fake.currentTime, 20);
    expect(fake.playerState, 'PLAYING');

    final advanced = player.advanced.first;
    fake.moveOn();
    await advanced;

    await player.setNext(_m(2));
    await settle();
    // The played track is dropped and the new one added after the current.
    expect(fake.items, hasLength(2));
    expect(fake.items.first, fake.currentItem);
  });

  test('replacing the next track removes the old one first', () async {
    await player.load(_m(0), next: _m(1));
    final before = List.of(fake.items);
    await player.setNext(_m(5));
    expect(fake.items, hasLength(2));
    expect(fake.items.last, isNot(before.last));
    await player.setNext(null);
    expect(fake.items, [fake.currentItem]);
  });

  test('reports the end when the last track finishes', () async {
    await player.load(_m(0));
    final ended = player.status.firstWhere((s) => s.ended);
    fake.moveOn();
    await ended;
  });

  test('play, pause, seek and volume reach the device', () async {
    await player.load(_m(0), play: false);
    expect(fake.playerState, 'PAUSED');
    await player.play();
    expect(fake.playerState, 'PLAYING');
    await player.seek(const Duration(seconds: 90));
    expect(fake.currentTime, 90);
    await player.pause();
    expect(fake.playerState, 'PAUSED');
    final volume = fake.next('SET_VOLUME');
    await player.setVolume(0.25);
    expect(((await volume).payload['volume'] as Map)['level'], 0.25);
  });

  test('closing stops the receiver app', () async {
    await player.close();
    expect(fake.stopped, isTrue);
  });

  test('closes when another app takes over the device', () async {
    await player.load(_m(0));
    fake.appRunning = false;
    fake.send(CastChannel.receiverNs, {
      'type': 'RECEIVER_STATUS',
      'requestId': 0,
      'status': fake._receiverStatus(),
    }, from: CastChannel.receiverId);
    await player.closed.timeout(const Duration(seconds: 2));
  });
}

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

  /// The media session, new with every load. It starts at an old session
  /// left over from before, as a device that played earlier reports.
  int session = 1;
  final rejected = <String>[];

  /// Content types the speaker can't play: it reports an error a moment
  /// after loading and never answers the load, as a Nest Mini did.
  Set<String> refuses = {};
  final List<String> types = [];

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
    'mediaSessionId': session,
    'playerState': playerState,
    if (playerState == 'IDLE') 'idleReason': 'FINISHED',
    'currentTime': currentTime,
    'currentItemId': ?currentItem,
    'items': [
      for (final i in items) {'itemId': i},
    ],
    'media': {'duration': 180},
    // Real receivers report the stream's own level here, not the speaker's.
    'volume': {'level': 1.0, 'muted': false},
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
    final sent = p['mediaSessionId'];
    if (sent != null && sent != session) {
      rejected.add(m.type!);
      send(CastChannel.mediaNs, {
        'type': 'INVALID_REQUEST',
        'requestId': id,
        'reason': 'INVALID_MEDIA_SESSION_ID',
      });
      return;
    }
    if (m.type == 'QUEUE_LOAD') {
      final type =
          ((p['items'] as List).first['media'] as Map)['contentType'] as String;
      if (refuses.contains(type)) {
        session++;
        Timer(const Duration(milliseconds: 50), () {
          playerState = 'IDLE';
          send(CastChannel.mediaNs, {
            'type': 'MEDIA_STATUS',
            'requestId': 0,
            'status': [
              {...mediaStatus(), 'idleReason': 'ERROR'},
            ],
          });
        });
        return;
      }
    }
    switch (m.type) {
      case 'QUEUE_LOAD':
        session++;
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
    expect(fake.rejected, isEmpty, reason: 'requests with an old session');
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

  test(
    "the stream's volume in media status isn't taken as the speaker's",
    () async {
      await player.load(_m(0));
      await settle();
      expect(fake.received.map((m) => m.type), contains('QUEUE_LOAD'));
      final last = await player.status.first;
      expect(last.volume, 0.5);
    },
  );

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

  test('a file the speaker can\'t play fails the load at once', () async {
    fake.refuses = {'audio/flac'};
    final watch = Stopwatch()..start();
    await expectLater(player.load(_m(0)), throwsA(isA<RemoteMediaError>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    // A file it can play loads fine after.
    await player.load(
      RemoteMedia(
        url: Uri.parse('http://server/stream/0?format=mp3'),
        contentType: 'audio/mpeg',
        title: 'Track 0',
      ),
    );
    expect(fake.playerState, 'PLAYING');
  });

  test('a lined-up track the speaker can\'t play is reported', () async {
    await player.load(_m(0), next: _m(1));
    final failed = player.status.firstWhere((s) => s.failed);
    fake
      ..moveOn()
      ..playerState = 'IDLE'
      ..send(CastChannel.mediaNs, {
        'type': 'MEDIA_STATUS',
        'requestId': 0,
        'status': [
          {...fake.mediaStatus(), 'idleReason': 'ERROR'},
        ],
      });
    await failed.timeout(const Duration(seconds: 2));
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

  test(
    'CastMessage.decode rejects overlong varints and out-of-bounds lengths',
    () {
      // Overlong varint (> 64 bits of continuation bytes).
      final overlong = Uint8List.fromList([for (var i = 0; i < 12; i++) 0x80]);
      expect(CastMessage.decode(overlong), isNull);

      // Field 2 (length-delimited, tag = 2 << 3 | 2 = 0x12) with a 10-byte
      // varint encoding -1 (0xffffffffffffffff). Without bounds checking,
      // i + (-1) would loop forever.
      final negativeLen = Uint8List.fromList([
        0x12,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01,
      ]);
      expect(CastMessage.decode(negativeLen), isNull);

      // Field 2 with a length larger than the remaining buffer.
      final pastEnd = Uint8List.fromList([0x12, 0x64, 0x41, 0x42]);
      expect(CastMessage.decode(pastEnd), isNull);
    },
  );
}

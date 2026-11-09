import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// One Cast V2 message: a JSON payload on a namespace, between a sender
/// and a receiver id.
class CastMessage {
  final String source;
  final String destination;
  final String namespace;
  final Map<String, dynamic> payload;

  const CastMessage({
    required this.source,
    required this.destination,
    required this.namespace,
    required this.payload,
  });

  String? get type => payload['type'] as String?;
  int? get requestId => (payload['requestId'] as num?)?.toInt();

  /// The protobuf `CastMessage` from Google's cast_channel.proto, written
  /// by hand: it has seven fields and only these are ever used.
  Uint8List encode() {
    final out = BytesBuilder();
    void varint(int v) {
      while (v >= 0x80) {
        out.addByte((v & 0x7f) | 0x80);
        v >>= 7;
      }
      out.addByte(v);
    }

    void str(int field, String s) {
      final bytes = utf8.encode(s);
      varint(field << 3 | 2);
      varint(bytes.length);
      out.add(bytes);
    }

    varint(1 << 3); // protocol_version = CASTV2_1_0
    varint(0);
    str(2, source);
    str(3, destination);
    str(4, namespace);
    varint(5 << 3); // payload_type = STRING
    varint(0);
    str(6, jsonEncode(payload));
    return out.toBytes();
  }

  /// Reads a protobuf `CastMessage`. Null for binary payloads or anything
  /// malformed.
  static CastMessage? decode(Uint8List data) {
    var i = 0;
    int varint() {
      var result = 0;
      var shift = 0;
      while (true) {
        final b = data[i++];
        result |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
      }
    }

    final strings = <int, String>{};
    try {
      while (i < data.length) {
        final key = varint();
        final field = key >> 3;
        switch (key & 7) {
          case 0:
            varint();
          case 2:
            final len = varint();
            if (field != 7) {
              strings[field] = utf8.decode(
                data.sublist(i, i + len),
                allowMalformed: true,
              );
            }
            i += len;
          default:
            return null;
        }
      }
      final json = strings[6];
      if (json == null) return null;
      final payload = jsonDecode(json);
      if (payload is! Map<String, dynamic>) return null;
      return CastMessage(
        source: strings[2] ?? '',
        destination: strings[3] ?? '',
        namespace: strings[4] ?? '',
        payload: payload,
      );
    } on Object {
      return null;
    }
  }
}

/// A Cast V2 connection to a device: length-prefixed protobuf messages
/// over TLS on port 8009, with the heartbeat that keeps it open.
class CastChannel {
  CastChannel._(this._socket) {
    _sub = _socket.listen(
      _onData,
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
      cancelOnError: true,
    );
    // A write to a connection the device has dropped fails here, not in
    // send(). The listener above already notices the drop.
    unawaited(_socket.done.then<void>((_) {}, onError: (Object _) {}));
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      send(receiverId, heartbeatNs, {'type': 'PING'});
      // No reply to three pings in a row: the device has gone.
      if (++_missedPongs > 3) unawaited(close());
    });
  }

  static const senderId = 'sender-oamp';
  static const receiverId = 'receiver-0';
  static const connectionNs = 'urn:x-cast:com.google.cast.tp.connection';
  static const heartbeatNs = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const receiverNs = 'urn:x-cast:com.google.cast.receiver';
  static const mediaNs = 'urn:x-cast:com.google.cast.media';

  /// Opens a channel to [host]. Cast devices present their own
  /// certificates, signed by Google rather than a public authority, so the
  /// certificate is not checked against the system's trusted roots. The
  /// connection only ever carries play commands on the home network.
  static Future<CastChannel> connect(String host, int port) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      onBadCertificate: (_) => true,
      timeout: const Duration(seconds: 5),
    );
    return open(socket);
  }

  /// A channel over an already open socket (plain TCP in tests).
  static CastChannel open(Socket socket) =>
      CastChannel._(socket)
        ..send(receiverId, connectionNs, {'type': 'CONNECT'});

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  late final Timer _heartbeat;
  final _messages = StreamController<CastMessage>.broadcast();
  final _closed = Completer<void>();
  final _buffer = BytesBuilder();
  final Map<int, Completer<CastMessage>> _pending = {};
  int _nextRequest = 1;
  int _missedPongs = 0;

  /// Every message the device sends to this app.
  Stream<CastMessage> get messages => _messages.stream;
  Future<void> get closed => _closed.future;
  bool get isClosed => _closed.isCompleted;

  void send(String destination, String namespace, Map<String, dynamic> body) {
    if (isClosed) return;
    final bytes = CastMessage(
      source: senderId,
      destination: destination,
      namespace: namespace,
      payload: body,
    ).encode();
    final header = ByteData(4)..setUint32(0, bytes.length);
    try {
      _socket
        ..add(header.buffer.asUint8List())
        ..add(bytes);
    } on Object {
      unawaited(close());
    }
  }

  /// Sends [body] with a new request id and waits for the reply that
  /// carries the same id.
  Future<CastMessage> request(
    String destination,
    String namespace,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final id = _nextRequest++;
    final reply = Completer<CastMessage>();
    _pending[id] = reply;
    send(destination, namespace, {...body, 'requestId': id});
    return reply.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('No reply to ${body['type']}');
      },
    );
  }

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    while (bytes.length >= 4) {
      final len = ByteData.sublistView(bytes).getUint32(0);
      if (bytes.length < 4 + len) break;
      final message = CastMessage.decode(bytes.sublist(4, 4 + len));
      bytes = bytes.sublist(4 + len);
      if (message != null) _handle(message);
    }
    _buffer.add(bytes);
  }

  void _handle(CastMessage m) {
    _missedPongs = 0;
    if (m.namespace == heartbeatNs) {
      if (m.type == 'PING') send(m.source, heartbeatNs, {'type': 'PONG'});
      return;
    }
    if (m.namespace == connectionNs &&
        m.type == 'CLOSE' &&
        m.source == receiverId) {
      unawaited(close());
      return;
    }
    final id = m.requestId;
    if (id != null && id != 0) _pending.remove(id)?.complete(m);
    _messages.add(m);
  }

  void _onClosed() {
    if (_closed.isCompleted) return;
    _heartbeat.cancel();
    for (final p in _pending.values) {
      if (!p.isCompleted) p.completeError(const SocketException('Closed'));
    }
    _pending.clear();
    _closed.complete();
    unawaited(_messages.close());
  }

  Future<void> close() async {
    if (isClosed) return;
    send(receiverId, connectionNs, {'type': 'CLOSE'});
    await _sub.cancel();
    try {
      await _socket.close();
    } on Object catch (e) {
      debugPrint('Cast: closing the connection failed ($e)');
    }
    _onClosed();
  }
}

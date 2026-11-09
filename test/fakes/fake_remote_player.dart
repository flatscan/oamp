import 'dart:async';

import 'package:oamp/core/output_device.dart';
import 'package:oamp/core/remote_player.dart';

const fakeCastDevice = OutputDevice(
  id: 'speaker',
  protocol: OutputProtocol.cast,
  name: 'Kitchen',
  host: '127.0.0.1',
  port: 8009,
);

/// Records what a device was told, and lets a test act as the device.
class FakeRemotePlayer implements RemotePlayer {
  FakeRemotePlayer([this.fakeDevice = fakeCastDevice]);

  final OutputDevice fakeDevice;

  /// Files the device turns down, as a speaker does with a format it
  /// can't play.
  bool Function(RemoteMedia media)? refuses;
  final _status = StreamController<RemoteStatus>.broadcast();
  final _advanced = StreamController<void>.broadcast();
  final _closed = Completer<void>();

  RemoteMedia? current;
  RemoteMedia? next;
  Duration loadedAt = Duration.zero;
  bool playing = false;
  int loads = 0;
  double? volume;
  bool stopped = false;
  bool? closedWithStop;

  @override
  OutputDevice get device => fakeDevice;
  @override
  Stream<RemoteStatus> get status => _status.stream;
  @override
  Stream<void> get advanced => _advanced.stream;
  @override
  Future<void> get closed => _closed.future;

  void report(RemoteStatus s) => _status.add(s);

  /// The device moves on to [next] by itself.
  void moveOn() {
    current = next;
    next = null;
    _advanced.add(null);
  }

  @override
  Future<void> load(
    RemoteMedia current, {
    RemoteMedia? next,
    Duration position = Duration.zero,
    bool play = true,
  }) async {
    loads++;
    if (refuses?.call(current) ?? false) {
      throw const RemoteMediaError('refused');
    }
    this.current = current;
    this.next = next;
    loadedAt = position;
    playing = play;
    stopped = false;
  }

  @override
  Future<void> setNext(RemoteMedia? next) async => this.next = next;
  @override
  Future<void> play() async => playing = true;
  @override
  Future<void> pause() async => playing = false;
  @override
  Future<void> seek(Duration position) async => loadedAt = position;
  @override
  Future<void> stop() async {
    stopped = true;
    current = null;
    next = null;
  }

  @override
  Future<void> setVolume(double v) async => volume = v;

  @override
  Future<void> close({bool stopPlayback = true}) async {
    closedWithStop = stopPlayback;
    if (!_closed.isCompleted) _closed.complete();
  }

  /// The device goes away by itself.
  void drop() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

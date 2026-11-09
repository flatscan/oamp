import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/remote_engine.dart';
import '../core/output_device.dart';
import '../core/remote_player.dart';
import 'player.dart';

/// Finds speakers and TVs to play to. main.dart swaps in the network
/// finder on Windows and Android; tests and the web find nothing.
final deviceDiscoveryProvider = Provider<DeviceDiscovery>(
  (_) => const NoDeviceDiscovery(),
);

/// The speakers and TVs found so far, merged across protocols.
final nearbyDevicesProvider = StreamProvider<List<OutputDevice>>(
  (ref) => ref.watch(deviceDiscoveryProvider).devices,
);

/// Whether this platform can cast at all: main.dart turns it on for
/// Windows and Android. Hides the cast button elsewhere.
final castingAvailableProvider = Provider<bool>((_) => false);

/// Opens a connection to a device. main.dart plugs in Cast and DLNA.
final remoteConnectorProvider = Provider<RemoteConnector>(
  (_) =>
      (device) async => throw UnsupportedError('Casting is not available here'),
);

enum OutputPhase { local, connecting, connected }

/// Where playback is going.
class OutputState {
  final OutputPhase phase;

  /// The speaker or TV, while connecting or connected.
  final OutputDevice? device;

  /// Why the last connection failed or ended, for the listener.
  final String? message;

  /// The device's own volume from 0 to 1, once it has said.
  final double? volume;

  const OutputState({
    this.phase = OutputPhase.local,
    this.device,
    this.message,
    this.volume,
  });

  bool get isRemote => phase != OutputPhase.local;
  bool get isConnected => phase == OutputPhase.connected;

  OutputState withVolume(double? v) =>
      OutputState(phase: phase, device: device, message: message, volume: v);
}

final outputProvider = NotifierProvider<OutputController, OutputState>(
  OutputController.new,
);

/// Moves playback between this device and a speaker or TV.
///
/// The queue never moves: the player keeps it, and the [OutputSwitcher]
/// loads the device at the same track and position. When the device goes
/// away (switched off, off the network, or taken over by another app),
/// playback comes back here, paused where the device was.
class OutputController extends Notifier<OutputState> {
  RemotePlayer? _player;
  RemoteEngine? _engine;
  StreamSubscription<RemoteStatus>? _volumeSub;

  /// When the listener last moved the volume, so the device's reports
  /// (which lag) don't pull the slider back while it is being dragged.
  final _sinceVolumeSet = Stopwatch();

  Timer? _clearMessage;

  /// A message stays a little while, then goes.
  @override
  set state(OutputState value) {
    super.state = value;
    _clearMessage?.cancel();
    if (value.message != null) {
      _clearMessage = Timer(messageTime, () {
        if (ref.mounted && identical(state, value)) {
          super.state = OutputState(phase: value.phase, device: value.device);
        }
      });
    }
  }

  static const messageTime = Duration(seconds: 10);

  /// Bumped on every change, so a slow connection that is no longer
  /// wanted is closed instead of taking over.
  int _attempt = 0;

  @override
  OutputState build() {
    ref.onDispose(() {
      _clearMessage?.cancel();
      unawaited(_release(stopPlayback: false));
    });
    return const OutputState();
  }

  /// Starts playing on [device]. Playback carries on there from where it
  /// is, or stays paused if it was paused.
  Future<void> connect(OutputDevice device) async {
    if (state.device?.key == device.key && state.isRemote) return;
    final attempt = ++_attempt;
    if (_player != null) await _backToLocal(stopPlayback: true);
    state = OutputState(phase: OutputPhase.connecting, device: device);
    final RemotePlayer player;
    try {
      player = await ref.read(remoteConnectorProvider)(device);
    } on Object catch (e) {
      debugPrint(
        'Casting: could not connect to a ${device.protocol.label} '
        'device (${device.model ?? 'unknown model'}): $e',
      );
      if (attempt == _attempt) {
        state = OutputState(message: 'Couldn’t connect to ${device.name}');
      }
      return;
    }
    if (attempt != _attempt || !ref.mounted) {
      await player.close();
      return;
    }
    final engine = RemoteEngine(player);
    _player = player;
    _engine = engine;
    unawaited(player.closed.then((_) => _onDropped(player)));
    debugPrint(
      'Casting: connected to a ${device.protocol.label} device '
      '(${device.model ?? 'unknown model'})',
    );
    state = OutputState(phase: OutputPhase.connected, device: device);
    _volumeSub = player.status.listen((s) {
      final v = s.volume;
      if (v == null || v == state.volume || !state.isConnected) return;
      if (_sinceVolumeSet.isRunning &&
          _sinceVolumeSet.elapsed < const Duration(seconds: 2)) {
        return;
      }
      state = state.withVolume(v);
    });
    try {
      await ref.read(outputSwitcherProvider).switchTo(engine);
    } on Object catch (e) {
      debugPrint('Casting: the device would not play ($e)');
      await _backToLocal(stopPlayback: true);
      state = OutputState(message: '${device.name} couldn’t play this');
    }
  }

  /// Sets the speaker or TV's own volume, from 0 to 1.
  Future<void> setVolume(double volume) async {
    final engine = _engine;
    if (engine == null || !state.isConnected) return;
    final v = volume.clamp(0.0, 1.0);
    _sinceVolumeSet
      ..reset()
      ..start();
    state = state.withVolume(v);
    try {
      await engine.setVolume(v);
    } on Object catch (e) {
      debugPrint('Casting: setting the volume failed ($e)');
    }
  }

  /// Turns the device up or down a step, as volume keys do.
  Future<void> stepVolume(int steps) =>
      setVolume((state.volume ?? 0.5) + steps * volumeStep);

  static const volumeStep = 0.05;

  /// Brings playback back to this device, paused where the speaker or TV
  /// was, and stops the device.
  Future<void> disconnect() async {
    _attempt++;
    await _backToLocal(stopPlayback: true);
    state = const OutputState();
  }

  Future<void> _onDropped(RemotePlayer player) async {
    if (!identical(player, _player) || !ref.mounted) return;
    final name = state.device?.name;
    debugPrint('Casting: the device went away');
    await _backToLocal(stopPlayback: false);
    state = OutputState(
      message: name == null ? null : 'Lost the connection to $name',
    );
  }

  Future<void> _backToLocal({required bool stopPlayback}) async {
    final engine = _engine;
    if (engine != null) {
      final at = engine.position;
      await ref
          .read(outputSwitcherProvider)
          .switchTo(null, play: false, at: at);
    }
    await _release(stopPlayback: stopPlayback);
  }

  Future<void> _release({required bool stopPlayback}) async {
    final player = _player;
    final engine = _engine;
    _player = null;
    _engine = null;
    unawaited(_volumeSub?.cancel());
    _volumeSub = null;
    // The device first: stopping it matters more than tidying up here.
    await player?.close(stopPlayback: stopPlayback);
    await engine?.dispose();
  }
}

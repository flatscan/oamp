import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/output_device.dart';
import 'cast_discovery.dart';
import 'dlna_discovery.dart';

/// [DeviceDiscovery] over the local network: Google Cast by mDNS and DLNA
/// renderers by SSDP, both in Dart so Windows and Android share them.
class NetworkDeviceDiscovery implements DeviceDiscovery {
  NetworkDeviceDiscovery({
    CastFinder? cast,
    DlnaFinder? dlna,
    this.listenFor = const Duration(seconds: 3),
  }) : _cast = cast ?? CastFinder(),
       _dlna = dlna ?? DlnaFinder();

  final CastFinder _cast;
  final DlnaFinder _dlna;
  final Duration listenFor;

  final _out = StreamController<List<OutputDevice>>.broadcast();
  final Map<String, OutputDevice> _known = {};

  /// How many scans in a row each known device has stayed silent.
  final Map<String, int> _missed = {};

  /// Scans in a row a device may stay silent before it is forgotten.
  static const missesToForget = 2;
  List<OutputDevice> _current = const [];
  Future<void>? _scan;
  bool _disposed = false;

  @override
  Stream<List<OutputDevice>> get devices async* {
    yield _current;
    yield* _out.stream;
  }

  @override
  List<OutputDevice> get current => _current;

  @override
  bool get scanning => _scan != null;

  @override
  Future<void> scan() => _scan ??= _run().whenComplete(() {
    _scan = null;
    _publish();
  });

  Future<void> _run() async {
    final watch = Stopwatch()..start();
    final heard = <String>{};
    void add(OutputDevice d) {
      if (_disposed) return;
      heard.add(d.key);
      if (_known[d.key] != d) {
        _known[d.key] = d;
        _publish();
      }
    }

    await Future.wait([
      _cast.find(listenFor: listenFor).forEach(add).catchError(_failed),
      _dlna.find(listenFor: listenFor).forEach(add).catchError(_failed),
    ]);
    // UDP drops packets, so one quiet scan isn't enough to say a device
    // has gone.
    for (final key in _known.keys.toList()) {
      if (heard.contains(key)) {
        _missed.remove(key);
      } else if ((_missed[key] = (_missed[key] ?? 0) + 1) >= missesToForget) {
        _known.remove(key);
        _missed.remove(key);
      }
    }
    // Models only: device names can identify people.
    final models = _known.values
        .map((d) => '${d.protocol.label} ${d.model ?? '?'}')
        .join(', ');
    debugPrint(
      'Discovery: ${_known.length} device(s) in ${watch.elapsedMilliseconds} ms'
      '${models.isEmpty ? '' : ' ($models)'}',
    );
  }

  void _failed(Object e) => debugPrint('Discovery failed: $e');

  void _publish() {
    if (_disposed) return;
    _current = mergeDevices(_known.values);
    _out.add(_current);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _dlna.dispose();
    await _out.close();
  }
}

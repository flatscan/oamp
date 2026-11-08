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
    _known.removeWhere((key, _) => !heard.contains(key));
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

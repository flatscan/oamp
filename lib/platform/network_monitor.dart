import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../core/startup_trace.dart';

/// What kind of network the phone is streaming over.
enum NetworkKind {
  /// Wi-Fi, Ethernet, or nothing known: settings apply as set.
  wifi,

  /// Mobile data, where the separate mobile data quality applies.
  mobile,
}

/// Reports whether the device is on Wi-Fi or mobile data.
abstract class NetworkMonitor {
  NetworkKind get current;
  Stream<NetworkKind> get changes;

  /// Fires once the network has changed in any way and settled, including
  /// from one Wi-Fi network to another, which [changes] doesn't report.
  Stream<void> get anyChange;
  Future<void> dispose();
}

/// A monitor that never changes: desktops, tests, or when the platform
/// can't say.
class FixedNetworkMonitor implements NetworkMonitor {
  @override
  final NetworkKind current;
  const FixedNetworkMonitor([this.current = NetworkKind.wifi]);

  @override
  Stream<NetworkKind> get changes => const Stream.empty();

  @override
  Stream<void> get anyChange => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// [NetworkMonitor] on Android, through `connectivity_plus`.
///
/// A change is passed on only once it has held for [settle], so walking
/// out of Wi-Fi range doesn't swap the queue's streams back and forth.
class ConnectivityNetworkMonitor implements NetworkMonitor {
  ConnectivityNetworkMonitor._(
    this._current,
    Stream<NetworkKind> source,
    this.settle,
  ) {
    _sub = source.listen(_onChange);
  }

  final Duration settle;
  NetworkKind _current;
  NetworkKind? _pending;
  Timer? _timer;
  Timer? _anyTimer;
  final _any = StreamController<void>.broadcast();
  late final StreamSubscription<NetworkKind> _sub;
  final _changes = StreamController<NetworkKind>.broadcast();

  /// Starts watching, or returns a [FixedNetworkMonitor] when the platform
  /// can't report its network.
  static Future<NetworkMonitor> open({
    Duration settle = const Duration(seconds: 3),
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const FixedNetworkMonitor();
    }
    try {
      final c = Connectivity();
      final first = await c.checkConnectivity();
      startupTrace.mark('network is ${describe(first)}');
      return ConnectivityNetworkMonitor._(
        kindOf(first),
        c.onConnectivityChanged.map((results) {
          debugPrint('Network: ${describe(results)}');
          return kindOf(results);
        }),
        settle,
      );
    } catch (e) {
      debugPrint('Network type unavailable: $e');
      return const FixedNetworkMonitor();
    }
  }

  @visibleForTesting
  static ConnectivityNetworkMonitor forTest(
    NetworkKind initial,
    Stream<NetworkKind> source, {
    Duration settle = const Duration(seconds: 3),
  }) => ConnectivityNetworkMonitor._(initial, source, settle);

  /// The connections up, such as "wifi + vpn", for the diagnostics log.
  /// Names only the kind of link, never a network name or address.
  static String describe(List<ConnectivityResult> results) =>
      results.isEmpty ? 'none' : results.map((r) => r.name).join(' + ');

  /// Mobile data only when nothing better is up. A VPN (such as Tailscale)
  /// is reported alongside the network underneath it, so it doesn't count.
  static NetworkKind kindOf(List<ConnectivityResult> results) {
    final unmetered =
        results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    return results.contains(ConnectivityResult.mobile) && !unmetered
        ? NetworkKind.mobile
        : NetworkKind.wifi;
  }

  void _onChange(NetworkKind kind) {
    _anyTimer?.cancel();
    _anyTimer = Timer(settle, () => _any.add(null));
    _timer?.cancel();
    if (kind == _current) {
      _pending = null;
      return;
    }
    _pending = kind;
    _timer = Timer(settle, () {
      final next = _pending;
      _pending = null;
      if (next == null || next == _current) return;
      _current = next;
      _changes.add(next);
    });
  }

  @override
  NetworkKind get current => _current;

  @override
  Stream<NetworkKind> get changes => _changes.stream;

  @override
  Stream<void> get anyChange => _any.stream;

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _anyTimer?.cancel();
    await _any.close();
    await _sub.cancel();
    await _changes.close();
  }
}

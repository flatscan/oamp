import 'dart:async';

import 'music_source.dart';

/// Which of a server's addresses requests go to.
enum ServerRoute {
  /// The address the user signed in with, normally on the home network.
  home,

  /// The optional second address for when home cannot be reached, such as
  /// a public address used on mobile data or away from home.
  away,
}

/// Checks that the server answers at [base] within [timeout]. Throws a
/// [MusicSourceException] when it does not.
typedef AddressProbe = Future<void> Function(Uri base, Duration timeout);

/// Chooses between a server's home address and its optional away address.
///
/// Home always wins when it answers, so traffic for a server on the local
/// network never goes out over the internet when it doesn't need to. Both
/// addresses are tried at once, so falling back to away costs no more than
/// home's short wait.
///
/// Backend neutral: a source passes its own [AddressProbe]. Multiple servers
/// (Alpha3) can keep one picker per server.
class AddressPicker {
  AddressPicker(
    this.home, {
    Uri? away,
    this.homeWait = const Duration(seconds: 4),
    this.awayWait = const Duration(seconds: 10),
    this.singleWait = const Duration(seconds: 20),
    this.recoverEvery = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : // A private named parameter would change the public name.
       // ignore: prefer_initializing_formals
       _away = away,
       _now = clock ?? DateTime.now;

  final Uri home;
  Uri? _away;

  /// How long home gets to answer before away is used, when there is one.
  final Duration homeWait;

  /// How long the away address gets to answer.
  final Duration awayWait;

  /// How long the only address gets when there is no away address.
  final Duration singleWait;

  /// [recover] checks again at most this often.
  final Duration recoverEvery;

  final DateTime Function() _now;
  ServerRoute _route = ServerRoute.home;
  Future<void>? _picking;
  DateTime? _lastPick;
  final _changes = StreamController<ServerRoute>.broadcast(sync: true);

  Uri? get away => _away;

  /// How the away address answered during the last [pick]: null when it
  /// worked, otherwise the error. Null itself when the last pick didn't
  /// try away.
  Future<Object?>? get lastAwayAttempt => _lastAwayAttempt;
  Future<Object?>? _lastAwayAttempt;

  /// Sets or clears the away address. Clearing it goes back to home.
  set away(Uri? url) {
    _away = url;
    if (url == null) _set(ServerRoute.home);
  }

  ServerRoute get route => _away == null ? ServerRoute.home : _route;

  /// Where requests go now.
  Uri get active => route == ServerRoute.away ? _away! : home;

  /// Fires when [route] changes.
  Stream<ServerRoute> get changes => _changes.stream;

  /// Checks the server and chooses the address: home when it answers,
  /// otherwise away. Throws when neither answers, with an auth error if
  /// either address turned the login down. Calls made while a check is
  /// running share it.
  Future<void> pick(AddressProbe probe) =>
      _picking ??= _pick(probe).whenComplete(() {
        _picking = null;
        _lastPick = _now();
      });

  /// After a request failed to reach [failed]: checks again unless that
  /// happened very recently, and says whether requests now go somewhere
  /// else. Never throws.
  Future<bool> recover(AddressProbe probe, Uri failed) async {
    if (_away == null) return false;
    final last = _lastPick;
    if (_picking == null &&
        last != null &&
        _now().difference(last) < recoverEvery) {
      return active != failed;
    }
    try {
      await pick(probe);
    } catch (_) {}
    return active != failed;
  }

  Future<void> _pick(AddressProbe probe) async {
    final away = _away;
    if (away == null) {
      _lastAwayAttempt = null;
      await probe(home, singleWait);
      return;
    }
    // Started now so it runs while home is tried.
    final awayTry = _lastAwayAttempt = _attempt(probe, away, awayWait);
    final homeError = await _attempt(probe, home, homeWait);
    if (homeError == null) {
      _set(ServerRoute.home);
      // Let the away check finish quietly.
      unawaited(awayTry);
      return;
    }
    final awayError = await awayTry;
    if (_away != away) return; // Changed while checking.
    if (awayError == null) {
      _set(ServerRoute.away);
      return;
    }
    for (final e in [homeError, awayError]) {
      if (e is MusicSourceException && e.kind == MusicSourceErrorKind.auth) {
        throw e;
      }
    }
    throw MusicSourceException(
      'Could not reach your server at its home or away address. Check that '
      'the server is running.',
      kind: MusicSourceErrorKind.unreachable,
    );
  }

  static Future<Object?> _attempt(
    AddressProbe probe,
    Uri base,
    Duration timeout,
  ) async {
    try {
      await probe(base, timeout);
      return null;
    } catch (e) {
      return e;
    }
  }

  void _set(ServerRoute r) {
    if (r == _route) return;
    _route = r;
    if (!_changes.isClosed) _changes.add(r);
  }

  void close() => _changes.close();
}

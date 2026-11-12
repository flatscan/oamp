import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import '../core/outbox.dart';
import 'downloads.dart';
import 'session.dart';
import 'settings.dart';

/// Plays, likes and ratings the server has not heard about yet, saved on
/// the device and sent, oldest first, as soon as the server answers.
///
/// Holds only ids and times, per server. Watched once from the app root.
final outboxProvider = NotifierProvider<OutboxNotifier, List<OutboxEntry>>(
  OutboxNotifier.new,
);

class OutboxNotifier extends Notifier<List<OutboxEntry>> {
  /// The most reports kept. Older ones go first.
  static const maxEntries = 1000;

  /// Reports older than this are not worth sending.
  static const maxAge = Duration(days: 60);

  /// How often to try again while reports are waiting.
  static const retryEvery = Duration(minutes: 5);

  bool _flushing = false;
  Timer? _timer;
  String? _serverId;

  String get _key => 'oamp.outbox.$_serverId';

  @override
  List<OutboxEntry> build() {
    final session = ref.watch(sessionProvider).value;
    _serverId = session?.serverId;
    _timer?.cancel();
    ref.onDispose(() => _timer?.cancel());
    if (session == null) return const [];

    ref.listen(serverStatusProvider, (prev, next) {
      if (next.health == ServerHealth.ok && prev?.health != ServerHealth.ok) {
        unawaited(flush());
      }
    });
    ref.listen(settingsProvider.select((s) => s.offlineMode), (prev, on) {
      if (!on && prev == true) unawaited(flush());
    });

    final saved = _read();
    if (saved.isNotEmpty) scheduleMicrotask(flush);
    return saved;
  }

  List<OutboxEntry> _read() {
    final raw = ref.read(preferencesProvider).getStringList(_key) ?? const [];
    final cutoff = DateTime.now().subtract(maxAge);
    final out = <OutboxEntry>[];
    for (final line in raw) {
      try {
        final e = OutboxEntry.fromJson(jsonDecode(line));
        if (e != null && e.at.isAfter(cutoff)) out.add(e);
      } catch (_) {
        // A damaged line is skipped; the rest still counts.
      }
    }
    return out;
  }

  void _save(List<OutboxEntry> entries) {
    state = entries;
    unawaited(
      ref
          .read(preferencesProvider)
          .setStringList(_key, [
            for (final e in entries) jsonEncode(e.toJson()),
          ])
          .then(
            (_) {},
            onError: (Object e) =>
                debugPrint('Could not save pending reports: ${e.runtimeType}'),
          ),
    );
    _timer?.cancel();
    _timer = entries.isEmpty
        ? null
        : Timer.periodic(retryEvery, (_) => unawaited(flush()));
  }

  void _add(OutboxEntry entry) {
    final key = entry.replaceKey;
    final next = [
      for (final e in state)
        if (key == null || e.replaceKey != key) e,
      entry,
    ];
    final trimmed = next.length > maxEntries
        ? next.sublist(next.length - maxEntries)
        : next;
    _save(trimmed);
  }

  /// Whether sending now is pointless: Offline mode is on, or the server
  /// could not be reached at either address.
  bool get _cannotSend =>
      ref.read(settingsProvider).offlineMode ||
      ref.read(serverStatusProvider).health == ServerHealth.unreachable;

  /// A track was listened to.
  Future<void> play(String trackId, DateTime at) =>
      _submit(OutboxEntry.play(trackId, at), quiet: true);

  /// A like or unlike. Throws when the server refuses it for good; saves it
  /// when the server can't be reached.
  Future<void> like(String id, bool liked, LikeTarget target) => _submit(
    OutboxEntry.like(id, liked, target, DateTime.now()),
    quiet: false,
  );

  /// A star rating, 0 clearing it. Throws and saves as [like] does.
  Future<void> rate(String id, int rating) =>
      _submit(OutboxEntry.rating(id, rating, DateTime.now()), quiet: false);

  Future<void> _submit(OutboxEntry entry, {required bool quiet}) async {
    final source = ref.read(sessionProvider).value?.source;
    if (source == null) return;
    // Earlier reports go first, and nothing is tried against a server that
    // is known to be out of reach.
    if (state.isNotEmpty || _cannotSend) {
      _add(entry);
      unawaited(flush());
      return;
    }
    try {
      await deliverEntry(source, entry);
    } on Object catch (e) {
      switch (classifyFailure(e)) {
        case OutboxFailure.retry || OutboxFailure.keep:
          debugPrint('Saved a ${entry.kind.name} report for later');
          _add(entry);
        case OutboxFailure.drop:
          debugPrint(
            'A ${entry.kind.name} report was refused: ${e.runtimeType}',
          );
          if (!quiet) rethrow;
      }
    }
  }

  /// Sends what is waiting, oldest first, stopping at the first report the
  /// server can't take now.
  Future<void> flush() async {
    if (_flushing || state.isEmpty || _cannotSend) return;
    final source = ref.read(sessionProvider).value?.source;
    if (source == null) return;
    _flushing = true;
    var likedTracksSent = false;
    try {
      while (state.isNotEmpty && ref.mounted) {
        final entry = state.first;
        try {
          await deliverEntry(source, entry);
        } on Object catch (e) {
          if (classifyFailure(e) != OutboxFailure.drop) {
            debugPrint('Pending reports wait: ${e.runtimeType}');
            return;
          }
          debugPrint(
            'A ${entry.kind.name} report was refused: ${e.runtimeType}',
          );
        }
        if (!ref.mounted) return;
        if (entry.kind == OutboxKind.like && entry.target == LikeTarget.track) {
          likedTracksSent = true;
        }
        // Something may have been added meanwhile; drop only what was sent.
        _save([
          for (final e in state)
            if (!identical(e, entry)) e,
        ]);
      }
    } finally {
      _flushing = false;
      if (likedTracksSent && ref.mounted) {
        // Downloaded liked tracks follow likes that just reached the server.
        unawaited(
          ref
              .read(downloadsProvider.notifier)
              .syncPin(PinKind.liked, Pin.likedItemId, force: true),
        );
      }
    }
  }
}

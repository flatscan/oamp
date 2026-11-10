import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/music_source.dart';
import '../core/offline_library.dart';
import 'downloads.dart';
import 'player.dart';
import 'session.dart';
import 'settings.dart';

/// Whether the app is offline: the user switched Offline mode on, or the
/// server can't be reached at either address and there is downloaded music
/// to fall back to. Without downloads an unreachable server keeps its usual
/// banner and Retry, since there is nothing else to show.
final offlineProvider = Provider<bool>((ref) {
  if (ref.watch(settingsProvider.select((s) => s.offlineMode))) return true;
  final hasDownloads = ref.watch(
    downloadsProvider.select((s) => s.downloaded.isNotEmpty),
  );
  if (!hasDownloads) return false;
  return ref.watch(
    serverStatusProvider.select((s) => s.health == ServerHealth.unreachable),
  );
});

/// The downloaded music as a library, current as of this moment.
final offlineLibraryProvider = Provider<OfflineLibrary>((ref) {
  final s = ref.watch(downloadsProvider);
  return OfflineLibrary(s.pins, s.downloaded.contains);
});

/// While offline, moves past queue entries that are not downloaded, since
/// there is nothing to play for them, and pauses when none are left.
final offlineSkipProvider = Provider<void>((ref) {
  void check() {
    if (!ref.read(offlineProvider)) return;
    final s = ref.read(playerProvider);
    final cur = s.current;
    final i = s.currentIndex;
    if (cur == null || i == null || !s.playing) return;
    final have = ref.read(downloadsProvider).downloaded;
    if (have.contains(cur.id)) return;
    final player = ref.read(playerProvider.notifier);
    final ahead = s.queue.skip(i + 1).any((t) => have.contains(t.id));
    unawaited(ahead ? player.next() : player.pause());
  }

  ref.listen(playerProvider, (prev, next) {
    if (prev?.currentIndex != next.currentIndex ||
        prev?.playing != next.playing) {
      check();
    }
  });
  ref.listen(offlineProvider, (_, _) => check());
});

extension LibraryRef on Ref {
  /// The source for browsing the library. Watching it also rebuilds the
  /// caller when the app goes offline or comes back, so each screen
  /// refetches from downloads or from the server as it should.
  MusicSource watchLibrary() {
    watch(offlineProvider);
    return watch(musicSourceProvider);
  }
}

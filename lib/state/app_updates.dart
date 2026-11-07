import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_updates.dart';
import 'diagnostics.dart';
import 'settings.dart';

/// Whether the user wants OAmp to look for new releases. Asked once, at
/// first launch.
enum UpdateCheckChoice { unasked, on, off }

class AppUpdatesState {
  final UpdateCheckChoice choice;
  final bool checking;

  /// The newest published release, once a check has run.
  final ReleaseInfo? latest;

  /// [latest], when it is newer than this build. Always null on test and
  /// local builds, which can't be compared with a release.
  final ReleaseInfo? available;

  /// The update to announce in the banner this run, until the user acts on
  /// it. Each version is announced once.
  final ReleaseInfo? announce;

  final DateTime? lastChecked;

  /// Why the last check failed, in words.
  final String? error;

  const AppUpdatesState({
    this.choice = UpdateCheckChoice.unasked,
    this.checking = false,
    this.latest,
    this.available,
    this.announce,
    this.lastChecked,
    this.error,
  });

  AppUpdatesState copyWith({
    UpdateCheckChoice? choice,
    bool? checking,
    ReleaseInfo? Function()? latest,
    ReleaseInfo? Function()? available,
    ReleaseInfo? Function()? announce,
    DateTime? lastChecked,
    String? Function()? error,
  }) => AppUpdatesState(
    choice: choice ?? this.choice,
    checking: checking ?? this.checking,
    latest: latest == null ? this.latest : latest(),
    available: available == null ? this.available : available(),
    announce: announce == null ? this.announce : announce(),
    lastChecked: lastChecked ?? this.lastChecked,
    error: error == null ? this.error : error(),
  );
}

/// Where releases are read from: GitHub, or a fake in tests.
final releaseFeedProvider = Provider<ReleaseFeed>((_) => GitHubReleaseFeed());

/// Whether to ask the first-launch question. main.dart turns it on; tests
/// leave it off so the dialog doesn't cover the screen they drive.
final askAboutUpdatesProvider = Provider<bool>((_) => false);

final appUpdatesProvider = NotifierProvider<AppUpdates, AppUpdatesState>(
  AppUpdates.new,
);

/// Looks for a newer release on GitHub: on its own at most once a day in
/// release builds when the user said yes, or when asked from Settings.
class AppUpdates extends Notifier<AppUpdatesState> {
  static const checkEvery = Duration(hours: 24);

  static const _choiceKey = 'oamp.update.check';
  static const _lastCheckKey = 'oamp.update.lastCheckMs';
  static const _announcedKey = 'oamp.update.announced';

  Timer? _timer;

  @override
  AppUpdatesState build() {
    final prefs = ref.read(preferencesProvider);
    final choice = switch (prefs.getBool(_choiceKey)) {
      true => UpdateCheckChoice.on,
      false => UpdateCheckChoice.off,
      null => UpdateCheckChoice.unasked,
    };
    final last = prefs.getInt(_lastCheckKey);
    ref.onDispose(() => _timer?.cancel());
    if (choice == UpdateCheckChoice.on) _keepChecking();
    return AppUpdatesState(
      choice: choice,
      lastChecked: last == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(last),
    );
  }

  /// Looks again every so often, so a window left open for days still
  /// hears about a release. Only release builds check on their own.
  void _keepChecking() {
    if (_timer != null || !_canCompare) return;
    _timer = Timer.periodic(const Duration(hours: 1), (_) => checkIfDue());
  }

  bool get _canCompare => ref.read(buildInfoProvider).isRelease;

  /// The user's answer to the first-launch question, or the switch in
  /// Settings.
  Future<void> setEnabled(bool on) async {
    state = state.copyWith(
      choice: on ? UpdateCheckChoice.on : UpdateCheckChoice.off,
      announce: on ? null : () => null,
    );
    await ref.read(preferencesProvider).setBool(_choiceKey, on);
    if (on) {
      _keepChecking();
      unawaited(checkIfDue());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Checks now if the user said yes, this is a release build, and the last
  /// check was over a day ago.
  Future<void> checkIfDue() async {
    if (state.choice != UpdateCheckChoice.on || !_canCompare) return;
    final last = state.lastChecked;
    if (last != null && DateTime.now().difference(last) < checkEvery) return;
    await check();
  }

  /// Reads the releases list now. A check the user asked for shows its
  /// result in Settings but never the banner.
  Future<void> check({bool manual = false}) async {
    if (state.checking) return;
    state = state.copyWith(checking: true, error: () => null);
    final prefs = ref.read(preferencesProvider);
    try {
      final latest = newestRelease(
        await ref.read(releaseFeedProvider).releases(),
      );
      final current = ref.read(buildInfoProvider).version;
      final available =
          latest != null && current != null && latest.version > current
          ? latest
          : null;
      final now = DateTime.now();
      final announce =
          !manual &&
              available != null &&
              prefs.getString(_announcedKey) != available.tag
          ? available
          : null;
      if (announce != null) {
        await prefs.setString(_announcedKey, announce.tag);
        debugPrint('Update available: ${announce.tag}');
      }
      await prefs.setInt(_lastCheckKey, now.millisecondsSinceEpoch);
      state = state.copyWith(
        checking: false,
        latest: () => latest,
        available: () => available,
        announce: announce == null ? null : () => announce,
        lastChecked: now,
      );
    } catch (e) {
      debugPrint('Update check failed: $e');
      state = state.copyWith(
        checking: false,
        error: () => 'Couldn’t reach GitHub. Try again later.',
      );
    }
  }

  /// Hides the banner; the update still shows in Settings.
  void dismissAnnouncement() => state = state.copyWith(announce: () => null);
}

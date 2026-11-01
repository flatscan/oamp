import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/preferences.dart';

/// The settings store. main.dart overrides this with the platform store;
/// tests get an in-memory one.
final preferencesProvider = Provider<Preferences>((_) => MemoryPreferences());

class AppSettings {
  /// Whether the desktop window shows OAmp's title bar (drag strip and
  /// window buttons). Hidden, the window is moved by dragging the top of
  /// the Home header or the now playing artwork.
  final bool showTitleBar;

  const AppSettings({this.showTitleBar = true});
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  static const _titleBarKey = 'oamp.window.showTitleBar';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  AppSettings build() =>
      AppSettings(showTitleBar: _prefs.getBool(_titleBarKey) ?? true);

  Future<void> setShowTitleBar(bool show) async {
    state = AppSettings(showTitleBar: show);
    await _prefs.setBool(_titleBarKey, show);
  }
}

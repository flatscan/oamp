import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'state/session.dart';
import 'ui/home_shell.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // just_audio has no native Windows backend, so libmpv (via media_kit)
  // provides it there. Android, iOS and macOS use just_audio's own players.
  JustAudioMediaKit.ensureInitialized(windows: true, linux: false);

  if (_isDesktop) {
    // Open as a tall, phone-shaped column like Plexamp's desktop window.
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(460, 860),
        minimumSize: Size(360, 560),
        center: true,
        title: 'OAmp',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const ProviderScope(child: OAmpApp()));
}

class OAmpApp extends StatelessWidget {
  const OAmpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OAmp',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return switch (session) {
      AsyncData(value: final client?) => HomeShell(key: ValueKey(client)),
      AsyncData() || AsyncError() => const LoginScreen(),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}

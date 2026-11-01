import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'platform/platform_info.dart';
import 'platform/platform_system_controls.dart';
import 'state/session.dart';
import 'state/system_controls_bridge.dart';
import 'ui/home_shell.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // just_audio has no native Windows backend, so libmpv (via media_kit)
  // provides it there. Android, iOS and macOS use just_audio's own players.
  JustAudioMediaKit.ensureInitialized(windows: true, linux: false);

  if (isDesktop) {
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

  // The OS media session: the Windows media overlay and keyboard media keys.
  final systemControls = await createSystemControls();

  runApp(
    ProviderScope(
      overrides: [systemControlsProvider.overrideWithValue(systemControls)],
      child: const OAmpApp(),
    ),
  );
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
    // Mirror the player into the OS media controls for the app's lifetime.
    ref.watch(systemControlsBridgeProvider);
    final session = ref.watch(sessionProvider);
    return switch (session) {
      AsyncData(value: final session?) => HomeShell(
        key: ValueKey(session.serverId),
      ),
      AsyncData() || AsyncError() => const LoginScreen(),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}

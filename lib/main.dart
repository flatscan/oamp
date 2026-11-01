import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'platform/platform_info.dart';
import 'platform/platform_system_controls.dart';
import 'state/playback_reporter.dart';
import 'state/session.dart';
import 'state/system_controls_bridge.dart';
import 'ui/app_frame.dart';
import 'ui/home_shell.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';
import 'ui/window_mode.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // just_audio has no native Windows backend, so libmpv (via media_kit)
  // provides it there. Android, iOS and macOS use just_audio's own players.
  JustAudioMediaKit.ensureInitialized(windows: true, linux: false);

  if (isDesktop) {
    // Open as a tall, phone-shaped column. On Windows the system title bar
    // is replaced by the app's own dark one (see WindowBar).
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: const Size(FlyoutController.columnWidth, 880),
        center: true,
        title: 'OAmp',
        backgroundColor: oampBackground,
        titleBarStyle: defaultTargetPlatform == TargetPlatform.windows
            ? TitleBarStyle.hidden
            : TitleBarStyle.normal,
      ),
      () async {
        await FlyoutController.lockToColumn();
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
      navigatorKey: rootNavigatorKey,
      theme: buildTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, child) => AppFrame(child: child!),
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mirror the player into the OS media controls, and report plays to the
    // server, for the app's lifetime.
    ref.watch(systemControlsBridgeProvider);
    ref.watch(playbackReporterProvider);
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

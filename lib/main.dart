import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'audio/platform_audio.dart';
import 'platform/disk_artwork_cache.dart';
import 'platform/platform_info.dart';
import 'platform/platform_system_controls.dart';
import 'platform/preferences.dart';
import 'platform/window_geometry.dart';
import 'state/playback_reporter.dart';
import 'state/player.dart';
import 'state/precache.dart';
import 'state/queue_sync.dart';
import 'state/session.dart';
import 'state/settings.dart';
import 'state/system_controls_bridge.dart';
import 'ui/app_frame.dart';
import 'ui/home_shell.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';
import 'ui/window_mode.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final createDeck = createDeckFactory();
  final preferences = await PlatformPreferences.load();

  if (isDesktop) {
    // Open where the window was last time, if that is still on a screen.
    final saved = WindowGeometry.read(preferences)?.fitTo(
      await WindowGeometry.screens(),
      width: FlyoutController.columnWidth,
      minHeight: FlyoutController.minHeight,
    );
    // Open as a tall, phone-shaped column. On Windows the system title bar
    // is replaced by the app's own dark one (see WindowBar).
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: Size(FlyoutController.columnWidth, saved?.height ?? 880),
        center: saved == null,
        title: 'OAmp',
        backgroundColor: oampBackground,
        titleBarStyle: defaultTargetPlatform == TargetPlatform.windows
            ? TitleBarStyle.hidden
            : TitleBarStyle.normal,
      ),
      () async {
        if (saved != null) await windowManager.setPosition(saved.position);
        await FlyoutController.lockToColumn();
        await windowManager.show();
        WindowGeometrySaver(preferences).start();
        await windowManager.focus();
      },
    );
  }

  // The OS media session: the Windows media overlay and keyboard media keys.
  final systemControls = await createSystemControls();
  // Calls, other apps and unplugged headphones on phones.
  final audioFocus = await openAudioFocus();
  final trackCache = await openTrackCache();
  final artworkCache = await DiskArtworkCache.open();

  runApp(
    ProviderScope(
      overrides: [
        systemControlsProvider.overrideWithValue(systemControls),
        preferencesProvider.overrideWithValue(preferences),
        audioDeckFactoryProvider.overrideWithValue(createDeck),
        audioFocusProvider.overrideWithValue(audioFocus),
        trackCacheProvider.overrideWithValue(trackCache),
        artworkCacheProvider.overrideWithValue(artworkCache),
      ],
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
      // No visible scrollbars; lists scroll with the wheel, trackpad or touch.
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
      ),
      theme: buildTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, child) => AppFrame(child: child!),
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerStatefulWidget {
  const _Root();

  @override
  ConsumerState<_Root> createState() => _RootState();
}

class _RootState extends ConsumerState<_Root> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    QueueSync sync() => ref.read(queueSyncProvider);
    _lifecycle = AppLifecycleListener(
      // Back in front: pick up a queue saved meanwhile on another device.
      onResume: () => sync().checkServer(),
      onHide: () => sync().flush(),
      onExitRequested: () async {
        // Save where playback stands before the window closes, without
        // holding it open for a slow server.
        ref.read(playbackReporterProvider).stop();
        await sync().flush().timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mirror the player into the OS media controls, report plays to the
    // server, and save the queue, for the app's lifetime.
    ref.watch(systemControlsBridgeProvider);
    ref.watch(playbackReporterProvider);
    ref.watch(precacheProvider);
    ref.watch(queueSyncProvider);
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

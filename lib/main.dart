import 'dart:async';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'audio/platform_audio.dart';
import 'core/build_info.dart';
import 'core/diagnostics.dart';
import 'core/startup_trace.dart';
import 'platform/device_details.dart';
import 'platform/external_actions.dart';
import 'platform/file_log_store.dart';
import 'platform/disk_artwork_cache.dart';
import 'platform/android_download_activity.dart';
import 'platform/disk_download_store.dart';
import 'platform/network_monitor.dart';
import 'platform/platform_info.dart';
import 'platform/platform_system_controls.dart';
import 'platform/preferences.dart';
import 'outputs/network_discovery.dart';
import 'outputs/remote_connector.dart';
import 'platform/window_geometry.dart';
import 'state/app_updates.dart';
import 'state/diagnostics.dart';
import 'state/downloads.dart';
import 'state/endless_play.dart';
import 'state/offline.dart';
import 'state/outputs.dart';
import 'state/playback_reporter.dart';
import 'state/outbox.dart';
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
  startupTrace.enabled = true;

  // The log for bug reports collects everything the app prints and any
  // error nothing else caught, from here on.
  final log = DiagnosticsLog(await FileLogStore.open());
  _captureIntoLog(log);
  final device = await startupTrace.step('device details', DeviceDetails.read);
  debugPrint(
    'OAmp ${BuildInfo.current.label} starting on ${device.system}'
    '${device.model == null ? '' : ', ${device.model}'}',
  );

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    _applySystemBars();
  }

  final createDeck = createDeckFactory();
  final preferences = await startupTrace.step(
    'preferences',
    PlatformPreferences.load,
  );

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
  final systemControls = await startupTrace.step(
    'media session',
    createSystemControls,
  );
  // Calls, other apps and unplugged headphones on phones.
  final audioFocus = await startupTrace.step('audio focus', openAudioFocus);
  final trackCache = await startupTrace.step('track cache', openTrackCache);
  final artworkCache = await startupTrace.step(
    'artwork cache',
    DiskArtworkCache.open,
  );
  final downloadStore = await startupTrace.step(
    'downloads',
    DiskDownloadStore.openDefault,
  );
  // Wi-Fi or mobile data, for the mobile data quality on phones.
  final network = await startupTrace.step(
    'network monitor',
    ConnectivityNetworkMonitor.open,
  );

  final container = ProviderContainer(
    overrides: [
      systemControlsProvider.overrideWithValue(systemControls),
      preferencesProvider.overrideWithValue(preferences),
      audioDeckFactoryProvider.overrideWithValue(createDeck),
      audioFocusProvider.overrideWithValue(audioFocus),
      trackCacheProvider.overrideWithValue(trackCache),
      artworkCacheProvider.overrideWithValue(artworkCache),
      downloadStoreProvider.overrideWithValue(downloadStore),
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
        downloadActivityProvider.overrideWithValue(AndroidDownloadActivity()),
      networkMonitorProvider.overrideWithValue(network),
      diagnosticsLogProvider.overrideWithValue(log),
      askAboutUpdatesProvider.overrideWithValue(true),
      deviceDetailsProvider.overrideWithValue(device),
      externalActionsProvider.overrideWithValue(
        const PlatformExternalActions(),
      ),
      // Speakers and TVs to cast to, on Windows and Android.
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.android)) ...[
        deviceDiscoveryProvider.overrideWithValue(NetworkDeviceDiscovery()),
        remoteConnectorProvider.overrideWithValue(connectToDevice),
        castingAvailableProvider.overrideWithValue(true),
      ],
    ],
  );
  // The OS media controls (and Android Auto), play reports and the saved
  // queue run for the app's lifetime, also when Android starts the app
  // without a screen, such as for a car connecting while the phone is
  // locked.
  container
    ..listen(systemControlsBridgeProvider, (_, _) {})
    ..listen(playbackReporterProvider, (_, _) {})
    ..listen(precacheProvider, (_, _) {})
    ..listen(downloadsProvider, (_, _) {})
    ..listen(downloadActivityBridgeProvider, (_, _) {})
    ..listen(pinSyncProvider, (_, _) {})
    ..listen(outboxProvider, (_, _) {})
    ..listen(offlineSkipProvider, (_, _) {})
    ..listen(queueSyncProvider, (_, _) {})
    ..listen(endlessPlayProvider, (_, _) {});

  // Whether a screen is showing tells a start by the car (Android Auto
  // binding the media service while the app is closed) from one by the
  // user, and the first frame shows when OAmp actually appeared.
  startupTrace.mark(
    'starting the app (screen: '
    '${WidgetsBinding.instance.lifecycleState?.name ?? 'none yet'})',
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => startupTrace.mark('first frame drawn'),
  );
  _logLifecycle();

  runApp(
    UncontrolledProviderScope(container: container, child: const OAmpApp()),
  );
}

/// Logs the app coming to the front or going away, so a log shows when the
/// screen was opened and closed around a problem.
void _logLifecycle() {
  AppLifecycleListener(
    onStateChange: (state) => debugPrint('App: ${state.name}'),
    onResume: () {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        _applySystemBars();
      }
    },
  );
}

/// Draws under clear status and navigation bars; pages pad themselves for
/// the bars and any display cutout.
///
/// Never awaited: when Android Auto starts OAmp in the background there is
/// no screen to answer, and the call never returns, which left start-up
/// (and then the opened app) stuck on the splash. Applied again whenever
/// the screen comes to the front, as a call made with no screen is lost.
void _applySystemBars() {
  unawaited(
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
        .catchError((Object e) => debugPrint('System bars: $e')),
  );
  SystemChrome.setSystemUIOverlayStyle(oampSystemBars);
}

/// Sends `debugPrint` output, Flutter errors and uncaught async errors to
/// [log] as well as to the console.
void _captureIntoLog(DiagnosticsLog log) {
  final print = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) log.add(message);
    print(message, wrapWidth: wrapWidth);
  };
  final onFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    log.add(
      'Error: ${details.exceptionAsString()}\n${_shortStack(details.stack)}',
    );
    onFlutterError?.call(details);
  };
  final dispatcher = PlatformDispatcher.instance;
  final onError = dispatcher.onError;
  dispatcher.onError = (error, stack) {
    log.add('Uncaught error: $error\n${_shortStack(stack)}');
    return onError?.call(error, stack) ?? false;
  };
}

/// The top of a stack trace, which is where the cause usually is.
String _shortStack(StackTrace? stack) =>
    (stack?.toString() ?? '').trim().split('\n').take(12).join('\n');

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
      // Back in front: pick up a queue saved meanwhile on another device,
      // and check whether the server is now at home or away.
      onResume: () {
        sync().checkServer();
        ref.read(serverStatusProvider.notifier).recheckAddress();
      },
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
    ref.watch(downloadsProvider);
    ref.watch(downloadActivityBridgeProvider);
    ref.watch(pinSyncProvider);
    ref.watch(outboxProvider);
    ref.watch(offlineSkipProvider);
    ref.watch(queueSyncProvider);
    ref.watch(endlessPlayProvider);
    ref.watch(serverRouteProvider);
    ref.watch(awayAddressProvider);
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

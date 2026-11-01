import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/platform_info.dart';
import '../state/player.dart';
import '../state/settings.dart';
import 'browser.dart';
import 'player/now_playing.dart';
import 'theme.dart';

/// The app's root navigator, which the now playing view is pushed onto.
final rootNavigatorKey = GlobalKey<NavigatorState>();

void _closeOverlays() {
  rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
  final context = rootNavigatorKey.currentContext;
  if (context != null) hideNowPlaying(context);
}

/// Wraps every screen: the custom window bar on desktop, and app-wide
/// keyboard shortcuts.
///
/// Space plays or pauses, Ctrl+Left/Right skip, Ctrl+Up/Down change volume
/// and Ctrl+F jumps to search. Text fields keep their own keys, so typing a
/// space in search still types a space.
class AppFrame extends ConsumerWidget {
  final Widget child;
  const AppFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    PlayerController player() => ref.read(playerProvider.notifier);
    void nudgeVolume(double by) =>
        player().setVolume(ref.read(playerProvider).volume + by);

    // Playback keys stand aside while a text field has focus, so typing a
    // space or moving the cursor by word still works there.
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space): _TogglePlay(),
        SingleActivator(LogicalKeyboardKey.arrowRight, control: true): _Skip(1),
        SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): _Skip(-1),
        SingleActivator(LogicalKeyboardKey.arrowUp, control: true): _Volume(
          0.1,
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown, control: true): _Volume(
          -0.1,
        ),
        SingleActivator(LogicalKeyboardKey.keyF, control: true): _Search(),
      },
      child: Actions(
        actions: {
          _TogglePlay: _NotWhileTyping<_TogglePlay>(
            (_) => player().togglePlay(),
          ),
          _Skip: _NotWhileTyping<_Skip>(
            (i) => i.by > 0 ? player().next() : player().previous(),
          ),
          _Volume: _NotWhileTyping<_Volume>((i) => nudgeVolume(i.by)),
          _Search: CallbackAction<_Search>(
            onInvoke: (_) {
              _closeOverlays();
              Browser.globalKey.currentState?.select(BrowserTab.search);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              if (isDesktop && ref.watch(settingsProvider).showTitleBar)
                const WindowBar(),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _TogglePlay extends Intent {
  const _TogglePlay();
}

class _Skip extends Intent {
  final int by;
  const _Skip(this.by);
}

class _Volume extends Intent {
  final double by;
  const _Volume(this.by);
}

class _Search extends Intent {
  const _Search();
}

/// An action that is disabled while a text field has focus, which lets the
/// key event carry on to the field.
class _NotWhileTyping<T extends Intent> extends Action<T> {
  final void Function(T intent) run;
  _NotWhileTyping(this.run);

  @override
  bool isEnabled(T intent) {
    final ctx = primaryFocus?.context;
    if (ctx == null) return true;
    return ctx.widget is! EditableText &&
        ctx.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  Object? invoke(T intent) {
    run(intent);
    return null;
  }
}

/// A slim dark title bar in place of the system one: drag to move,
/// double-click to maximise, and the window buttons.
///
/// It sits above the app's navigator, where there is no overlay, so its
/// buttons go without tooltips.
class WindowBar extends StatelessWidget {
  const WindowBar({super.key});

  static const height = 34.0;

  @override
  Widget build(BuildContext context) {
    final windows = defaultTargetPlatform == TargetPlatform.windows;

    return Material(
      color: oampBackground,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: windows
                  ? const DragToMoveArea(child: _Title())
                  : const _Title(),
            ),
            if (windows) ...[
              WindowCaptionButton.minimize(
                brightness: Brightness.dark,
                onPressed: windowManager.minimize,
              ),
              const _MaximizeButton(),
              WindowCaptionButton.close(
                brightness: Brightness.dark,
                onPressed: windowManager.close,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand(
      child: Padding(
        padding: EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Icon(Icons.graphic_eq_rounded, size: 16, color: oampAccent),
            SizedBox(width: 6),
            Text(
              'OAmp',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: OAmpColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MaximizeButton extends StatefulWidget {
  const _MaximizeButton();

  @override
  State<_MaximizeButton> createState() => _MaximizeButtonState();
}

class _MaximizeButtonState extends State<_MaximizeButton> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((m) {
      if (mounted) setState(() => _maximized = m);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    return _maximized
        ? WindowCaptionButton.unmaximize(
            brightness: Brightness.dark,
            onPressed: windowManager.unmaximize,
          )
        : WindowCaptionButton.maximize(
            brightness: Brightness.dark,
            onPressed: windowManager.maximize,
          );
  }
}

/// Drags the window when the title bar is hidden (Windows only); otherwise
/// just [child].
class WindowDragArea extends ConsumerWidget {
  final Widget child;
  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = !ref.watch(settingsProvider).showTitleBar;
    if (!hidden || defaultTargetPlatform != TargetPlatform.windows) {
      return child;
    }
    return DragToMoveArea(child: child);
  }
}

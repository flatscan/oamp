import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lyrics.dart';
import '../../core/models.dart';
import '../../state/lyrics.dart';
import '../../state/player.dart';
import '../theme.dart';

/// The current track's lyrics, shown over the dimmed artwork. Synced lyrics
/// follow the music, with the line being sung highlighted and kept in view;
/// click a line to jump there. Plain lyrics just scroll.
class LyricsView extends ConsumerWidget {
  final Track track;
  const LyricsView({super.key, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(lyricsProvider(lyricsRequestFor(track)));
    final t = Theme.of(context).textTheme;
    return switch (lyrics) {
      AsyncData(:final value) when !value.isEmpty => _LyricsLines(
        key: ValueKey(track.id),
        lyrics: value,
      ),
      AsyncError(:final error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'Could not load lyrics: $error',
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: OAmpColors.textMuted),
          ),
        ),
      ),
      AsyncData() => Center(
        child: Text(
          'No lyrics for this track',
          style: t.titleMedium?.copyWith(color: OAmpColors.textMuted),
        ),
      ),
      _ => const Center(
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    };
  }
}

class _LyricsLines extends ConsumerStatefulWidget {
  final Lyrics lyrics;
  const _LyricsLines({super.key, required this.lyrics});

  @override
  ConsumerState<_LyricsLines> createState() => _LyricsLinesState();
}

class _LyricsLinesState extends ConsumerState<_LyricsLines> {
  late List<GlobalKey> _keys = _makeKeys();
  final _scroll = ScrollController();

  /// After the user scrolls by hand, the view stops following the music
  /// for a few seconds so they can read ahead.
  DateTime _manualUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastFollowed = -2;

  List<GlobalKey> _makeKeys() =>
      List.generate(widget.lyrics.lines.length, (_) => GlobalKey());

  @override
  void didUpdateWidget(_LyricsLines old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _keys = _makeKeys();
      _lastFollowed = -2;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow(int index, {bool force = false}) {
    if (index < 0 || index >= _keys.length) return;
    if (!force &&
        (index == _lastFollowed || DateTime.now().isBefore(_manualUntil))) {
      return;
    }
    _lastFollowed = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[index].currentContext;
      if (ctx == null || !mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.4,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    final current = lyrics.synced
        ? ref.watch(
            positionProvider.select(
              (p) => lyrics.lineAt(p.value ?? Duration.zero),
            ),
          )
        : -1;
    if (lyrics.synced) _follow(current);

    final base = Theme.of(context).textTheme.titleLarge
        ?.copyWith(fontWeight: FontWeight.w800, height: 1.3);
    final plain = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.45,
      color: Colors.white.withValues(alpha: 0.9),
    );

    final lines = <Widget>[
      for (var i = 0; i < lyrics.lines.length; i++)
        if (lyrics.synced)
          _SyncedLine(
            key: _keys[i],
            text: lyrics.lines[i].text,
            style: base!,
            state: i == current
                ? _LineState.current
                : (i < current ? _LineState.past : _LineState.upcoming),
            onTap: () {
              _manualUntil = DateTime.fromMillisecondsSinceEpoch(0);
              ref.read(playerProvider.notifier).seek(lyrics.lines[i].start!);
            },
          )
        else
          Padding(
            key: _keys[i],
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(
              lyrics.lines[i].text.isEmpty ? ' ' : lyrics.lines[i].text,
              style: plain,
            ),
          ),
    ];

    return NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        if (n.direction == ScrollDirection.idle) return false;
        _manualUntil = DateTime.now().add(const Duration(seconds: 4));
        return false;
      },
      // Fades the top and bottom edges so lines slide in and out softly.
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0, 0.12, 0.88, 1],
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
        ).createShader(r),
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(28, 72, 28, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lines,
          ),
        ),
      ),
    );
  }
}

enum _LineState { past, current, upcoming }

class _SyncedLine extends StatelessWidget {
  final String text;
  final TextStyle style;
  final _LineState state;
  final VoidCallback onTap;

  const _SyncedLine({
    super.key,
    required this.text,
    required this.style,
    required this.state,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final alpha = switch (state) {
      _LineState.current => 1.0,
      _LineState.past => 0.38,
      _LineState.upcoming => 0.55,
    };
    // An instrumental gap in synced lyrics is an empty line.
    final shown = text.trim().isEmpty ? '♪' : text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 250),
            style: style.copyWith(color: Colors.white.withValues(alpha: alpha)),
            child: Text(shown),
          ),
        ),
      ),
    );
  }
}

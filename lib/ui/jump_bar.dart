import 'package:flutter/material.dart';

import '../core/models.dart';
import 'theme.dart';

/// A column of letters down the right of a long list. Clicking a letter,
/// or dragging along the column, jumps the list to it, and a bubble shows
/// the letter under the pointer.
class JumpBar extends StatefulWidget {
  /// Letters that have entries. Others are drawn faint; jumping to one goes
  /// to the next letter that has entries. Null treats every letter as
  /// having entries, for lists that are not fully loaded.
  final Set<String>? available;
  final ValueChanged<String> onJump;

  const JumpBar({super.key, this.available, required this.onJump});

  static const width = 24.0;

  @override
  State<JumpBar> createState() => _JumpBarState();
}

class _JumpBarState extends State<JumpBar> {
  String? _active;

  /// [letter], or the next letter with entries.
  String _target(String letter) {
    final available = widget.available;
    if (available == null || available.contains(letter)) return letter;
    final start = indexLetters.indexOf(letter);
    for (final l in indexLetters.skip(start)) {
      if (available.contains(l)) return l;
    }
    for (final l in indexLetters.reversed) {
      if (available.contains(l)) return l;
    }
    return letter;
  }

  void _at(double dy, double height) {
    final i = (dy / height * indexLetters.length).floor().clamp(
      0,
      indexLetters.length - 1,
    );
    final letter = indexLetters[i];
    if (letter == _active) return;
    setState(() => _active = letter);
    widget.onJump(_target(letter));
  }

  void _end() => setState(() => _active = null);

  @override
  Widget build(BuildContext context) {
    final available = widget.available;
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        final fontSize = (h / indexLetters.length * 0.62).clamp(7.0, 12.0);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Semantics(
              label: 'Jump to letter',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _at(d.localPosition.dy, h),
                onTapUp: (_) => _end(),
                onTapCancel: _end,
                onVerticalDragStart: (d) => _at(d.localPosition.dy, h),
                onVerticalDragUpdate: (d) => _at(d.localPosition.dy, h),
                onVerticalDragEnd: (_) => _end(),
                onVerticalDragCancel: _end,
                child: SizedBox(
                  width: JumpBar.width,
                  height: h,
                  child: Column(
                    children: [
                      for (final l in indexLetters)
                        Expanded(
                          child: Center(
                            child: Text(
                              l,
                              style: TextStyle(
                                fontSize: fontSize,
                                height: 1,
                                fontWeight: FontWeight.w700,
                                color: l == _active
                                    ? oampAccent
                                    : (available == null ||
                                          available.contains(l))
                                    ? OAmpColors.textMuted
                                    : const Color(0x33FFFFFF),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_active != null)
              Positioned(
                right: JumpBar.width + 12,
                top:
                    (indexLetters.indexOf(_active!) + 0.5) *
                        h /
                        indexLetters.length -
                    28,
                child: IgnorePointer(
                  child: Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: OAmpColors.surfaceHigh,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Color(0x88000000), blurRadius: 12),
                      ],
                    ),
                    child: Text(
                      _target(_active!),
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: oampAccent,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

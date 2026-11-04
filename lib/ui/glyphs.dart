import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Small icons drawn with paths rather than taken from the icon font, so
/// they show up however the app is built. (A release build keeps only the
/// font glyphs it can see being used, and a missed one draws as blank.)

/// A five-point star, filled or as an outline.
class StarGlyph extends StatelessWidget {
  final double size;
  final Color color;
  final bool filled;
  const StarGlyph({
    super.key,
    required this.size,
    required this.color,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _StarPainter(color, filled)),
  );
}

class _StarPainter extends CustomPainter {
  final Color color;
  final bool filled;
  const _StarPainter(this.color, this.filled);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.width * 0.5;
    final inner = outer * 0.46;
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? outer : inner;
      final a = -math.pi / 2 + i * math.pi / 5;
      final p = c + Offset(math.cos(a), math.sin(a)) * r;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = math.max(1.4, size.width * 0.09)
      // The stroke is also drawn on filled stars, to round the points.
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke;
    canvas.drawPath(path, paint);
    if (filled) {
      canvas.drawPath(path, paint..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(_StarPainter old) =>
      old.color != color || old.filled != filled;
}

/// A speech bubble with lines of text in it, for the lyrics button.
class LyricsGlyph extends StatelessWidget {
  final double size;
  final Color color;
  final bool filled;
  const LyricsGlyph({
    super.key,
    this.size = 24,
    required this.color,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _LyricsPainter(color, filled)),
  );
}

class _LyricsPainter extends CustomPainter {
  final Color color;
  final bool filled;
  const _LyricsPainter(this.color, this.filled);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final bubble = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3 * s, 3.5 * s, 18 * s, 14 * s),
          Radius.circular(3 * s),
        ),
      )
      ..moveTo(8 * s, 17 * s)
      ..lineTo(8 * s, 21.5 * s)
      ..lineTo(13 * s, 17 * s);
    final stroke = Paint()
      ..color = color
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * s
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    if (filled) {
      canvas.drawPath(bubble, Paint()..color = color.withValues(alpha: 0.25));
    }
    canvas.drawPath(bubble, stroke);
    // Lines of text, the last one shorter.
    for (final (y, x2) in [(8.0, 17.0), (12.0, 13.5)]) {
      canvas.drawLine(Offset(7 * s, y * s), Offset(x2 * s, y * s), stroke);
    }
  }

  @override
  bool shouldRepaint(_LyricsPainter old) =>
      old.color != color || old.filled != filled;
}

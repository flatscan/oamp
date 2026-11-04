/// One line of lyrics. [start] is set when the lyrics are synced to the
/// music.
class LyricLine {
  final Duration? start;
  final String text;
  const LyricLine(this.text, {this.start});
}

/// A track's lyrics, either synced (every line has a start time, in order)
/// or plain text.
class Lyrics {
  final List<LyricLine> lines;
  final bool synced;

  const Lyrics(this.lines, {this.synced = false});

  static const none = Lyrics([]);

  bool get isEmpty => lines.every((l) => l.text.trim().isEmpty);

  /// The index of the line being sung at [position]: the last line that has
  /// started. -1 before the first line, or when the lyrics are not synced.
  int lineAt(Duration position) {
    if (!synced) return -1;
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].start! <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  static final _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final _metaTag = RegExp(r'^\[[a-zA-Z#]+:.*\]\s*$');

  /// Reads lyrics text. Text in LRC form (`[01:23.45]A line`, several time
  /// tags per line allowed) becomes synced lyrics; anything else is plain.
  static Lyrics parse(String text) {
    final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (raw.isEmpty) return none;
    final rows = raw.split('\n');
    final timed = <LyricLine>[];
    var untimed = 0;
    for (final row in rows) {
      final line = row.trim();
      if (line.isEmpty || _metaTag.hasMatch(line)) continue;
      final tags = <Duration>[];
      var rest = line;
      while (true) {
        final m = _timeTag.matchAsPrefix(rest);
        if (m == null) break;
        final frac = m.group(3) ?? '0';
        // `.5` is half a second, `.50` is too, `.500` is milliseconds.
        final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
        tags.add(
          Duration(
            minutes: int.parse(m.group(1)!),
            seconds: int.parse(m.group(2)!),
            milliseconds: ms,
          ),
        );
        rest = rest.substring(m.end).trimLeft();
      }
      if (tags.isEmpty) {
        untimed++;
        continue;
      }
      for (final t in tags) {
        timed.add(LyricLine(rest, start: t));
      }
    }
    if (timed.isNotEmpty && timed.length >= untimed) {
      timed.sort((a, b) => a.start!.compareTo(b.start!));
      return Lyrics(timed, synced: true);
    }
    return Lyrics([for (final r in rows) LyricLine(r.trimRight())]);
  }
}

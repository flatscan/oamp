import 'dart:math' as math;

/// A handful of named sound shapes, rather than a wall of sliders: pick
/// one and it suits whatever device is playing. Applied on this device
/// only; speakers and TVs being cast to use their own sound settings.
enum EqPreset {
  off('Off', 'Tracks play as they were mastered.', []),
  moreBass('More bass', 'Fuller low end.', [EqFilter.lowShelf(120, 5)]),
  lessBass('Less bass', 'Tames boomy headphones and rooms.', [
    EqFilter.lowShelf(120, -5),
  ]),
  moreTreble('More treble', 'Crisper detail.', [EqFilter.highShelf(5000, 4)]),
  lessTreble('Less treble', 'Softens harsh or bright earbuds.', [
    EqFilter.highShelf(5000, -4),
  ]),
  vocals('Vocals', 'Brings voices forward.', [
    EqFilter.lowShelf(150, -2),
    EqFilter.peak(2500, 3, q: 0.8),
  ]),
  smallSpeakers(
    'Small speakers',
    'For phone and laptop speakers: drops bass they can’t play and '
        'lifts voices.',
    [EqFilter.lowShelf(100, -6), EqFilter.peak(3000, 2, q: 0.7)],
  );

  const EqPreset(this.label, this.description, this.filters);

  final String label;
  final String description;

  /// The shape, as standard biquad filters.
  final List<EqFilter> filters;

  bool get isOff => filters.isEmpty;

  /// The preset's level change at [hz], in decibels.
  double responseDb(double hz) {
    var db = 0.0;
    for (final f in filters) {
      db += f.responseDb(hz);
    }
    return db;
  }

  /// The most the preset raises any frequency, in decibels (0 when it only
  /// cuts). Playback is turned down by this much so a boost never clips.
  double get maxBoostDb {
    var most = 0.0;
    // 1/12-octave steps across the audible range.
    for (var hz = 20.0; hz <= 20000; hz *= 1.059463) {
      most = math.max(most, responseDb(hz));
    }
    return most;
  }

  /// [maxBoostDb] as a linear volume factor, 1 or more.
  double get headroom => math.pow(10, maxBoostDb / 20).toDouble();

  /// Gains for an equaliser with fixed bands (Android's), one per entry of
  /// [centresHz], clamped to what the bands can do.
  List<double> bandGains(
    List<double> centresHz, {
    required double minDb,
    required double maxDb,
  }) => [
    for (final hz in centresHz) responseDb(hz).clamp(minDb, maxDb).toDouble(),
  ];

  /// The preset as an mpv `af` value: a labelled lavfi graph of FFmpeg
  /// biquads, or an empty string for [off].
  String get mpvFilter {
    if (isOff) return '';
    final graph = filters.map((f) => f.ffmpeg).join(',');
    return '@oamp-eq:lavfi=[$graph]';
  }
}

enum EqFilterType { lowShelf, highShelf, peak }

/// One biquad, as in the Audio EQ Cookbook (the same maths FFmpeg's
/// `lowshelf`, `highshelf` and `equalizer` filters use).
class EqFilter {
  final EqFilterType type;
  final double hz;
  final double gainDb;
  final double q;

  const EqFilter.lowShelf(this.hz, this.gainDb)
    : type = EqFilterType.lowShelf,
      q = 0.707;
  const EqFilter.highShelf(this.hz, this.gainDb)
    : type = EqFilterType.highShelf,
      q = 0.707;
  const EqFilter.peak(this.hz, this.gainDb, {this.q = 1})
    : type = EqFilterType.peak;

  /// Sample rate the response is worked out at. The shapes barely change
  /// between 44.1 and 48 kHz.
  static const _rate = 48000.0;

  String get ffmpeg {
    final name = switch (type) {
      EqFilterType.lowShelf => 'lowshelf',
      EqFilterType.highShelf => 'highshelf',
      EqFilterType.peak => 'equalizer',
    };
    return '$name=f=${_num(hz)}:t=q:w=${_num(q)}:g=${_num(gainDb)}';
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// This filter's level change at [hz], in decibels.
  double responseDb(double atHz) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * hz / _rate;
    final cw = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    final double b0, b1, b2, a0, a1, a2;
    switch (type) {
      case EqFilterType.peak:
        b0 = 1 + alpha * a;
        b1 = -2 * cw;
        b2 = 1 - alpha * a;
        a0 = 1 + alpha / a;
        a1 = -2 * cw;
        a2 = 1 - alpha / a;
      case EqFilterType.lowShelf:
        final s = 2 * math.sqrt(a) * alpha;
        b0 = a * ((a + 1) - (a - 1) * cw + s);
        b1 = 2 * a * ((a - 1) - (a + 1) * cw);
        b2 = a * ((a + 1) - (a - 1) * cw - s);
        a0 = (a + 1) + (a - 1) * cw + s;
        a1 = -2 * ((a - 1) + (a + 1) * cw);
        a2 = (a + 1) + (a - 1) * cw - s;
      case EqFilterType.highShelf:
        final s = 2 * math.sqrt(a) * alpha;
        b0 = a * ((a + 1) + (a - 1) * cw + s);
        b1 = -2 * a * ((a - 1) + (a + 1) * cw);
        b2 = a * ((a + 1) + (a - 1) * cw - s);
        a0 = (a + 1) - (a - 1) * cw + s;
        a1 = 2 * ((a - 1) - (a + 1) * cw);
        a2 = (a + 1) - (a - 1) * cw - s;
    }
    // |H(e^jw)| at the asked frequency.
    final w = 2 * math.pi * atHz / _rate;
    final c1 = math.cos(w), s1 = math.sin(w);
    final c2 = math.cos(2 * w), s2 = math.sin(2 * w);
    final numRe = b0 + b1 * c1 + b2 * c2, numIm = -(b1 * s1 + b2 * s2);
    final denRe = a0 + a1 * c1 + a2 * c2, denIm = -(a1 * s1 + a2 * s2);
    final mag2 =
        (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm);
    return 10 * math.log(mag2) / math.ln10;
  }
}

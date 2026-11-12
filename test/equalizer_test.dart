import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/equalizer.dart';

void main() {
  group('filter response', () {
    // Reference levels measured with FFmpeg's own filters on sine tones.
    test('matches FFmpeg', () {
      const low = EqFilter.lowShelf(120, 5);
      const high = EqFilter.highShelf(5000, 4);
      const peak = EqFilter.peak(2500, 3, q: 0.8);
      expect(low.responseDb(60), closeTo(4.7, 0.2));
      expect(low.responseDb(1000), closeTo(0, 0.2));
      expect(high.responseDb(10000), closeTo(3.9, 0.2));
      expect(high.responseDb(60), closeTo(0, 0.1));
      expect(peak.responseDb(1000), closeTo(0.8, 0.2));
      expect(peak.responseDb(2500), closeTo(3, 0.01));
    });
  });

  test('off changes nothing', () {
    expect(EqPreset.off.isOff, isTrue);
    expect(EqPreset.off.maxBoostDb, 0);
    expect(EqPreset.off.headroom, 1);
    expect(EqPreset.off.mpvFilter, '');
    expect(EqPreset.off.bandGains([60, 230, 910], minDb: -15, maxDb: 15), [
      0,
      0,
      0,
    ]);
  });

  test('every preset stays gentle', () {
    for (final p in EqPreset.values) {
      for (var hz = 20.0; hz <= 20000; hz *= 1.5) {
        expect(p.responseDb(hz).abs(), lessThanOrEqualTo(6.5), reason: p.name);
      }
    }
  });

  test('headroom covers the biggest boost, and cuts need none', () {
    expect(EqPreset.moreBass.maxBoostDb, closeTo(5, 0.1));
    expect(EqPreset.moreTreble.maxBoostDb, closeTo(4, 0.1));
    expect(EqPreset.lessBass.maxBoostDb, 0);
    expect(EqPreset.lessTreble.headroom, 1);
    expect(EqPreset.moreBass.headroom, closeTo(1.778, 0.02));
  });

  test('presets are sampled at whatever bands the phone has', () {
    // A typical five-band phone equaliser.
    final gains = EqPreset.moreBass.bandGains(
      [60, 230, 910, 3600, 14000],
      minDb: -15,
      maxDb: 15,
    );
    expect(gains[0], closeTo(4.7, 0.3));
    expect(gains[1], inExclusiveRange(0.2, 1));
    expect(gains[2], closeTo(0, 0.2));
    expect(gains[4], closeTo(0, 0.1));

    // A phone with a narrow range gets clamped, not refused.
    final narrow = EqPreset.smallSpeakers.bandGains(
      [60, 3000],
      minDb: -3,
      maxDb: 1,
    );
    expect(narrow, [-3, 1]);
  });

  test('mpv gets a labelled FFmpeg filter graph', () {
    expect(
      EqPreset.vocals.mpvFilter,
      '@oamp-eq:lavfi=[lowshelf=f=150:t=q:w=0.707:g=-2,'
      'equalizer=f=2500:t=q:w=0.8:g=3]',
    );
  });
}

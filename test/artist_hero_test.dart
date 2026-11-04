import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/ui/browse/artist_page.dart';

void main() {
  // The visible band's top edge in the photo, for an alignment.
  double bandTop(Alignment a, double side, double height) =>
      (side - height) * (a.y + 1) / 2;

  test('a wide header shows the middle of the photo, not the top', () {
    // The size from the report: 720 wide, 320 high.
    final a = heroAlignment(720, 320);
    final top = bandTop(a, 720, 320);
    // Centred on 40% of the photo's height: 288 px, so 128 to 448.
    expect(top, closeTo(128, 0.01));
  });

  test('a header about as tall as it is wide shows it all', () {
    expect(heroAlignment(320, 320), Alignment.center);
    expect(heroAlignment(300, 320), Alignment.center);
  });

  test('the band never runs off either end of the photo', () {
    expect(bandTop(heroAlignment(330, 320), 330, 320), inInclusiveRange(0, 10));
    final low = heroAlignment(1000, 320, focus: 0.95);
    expect(bandTop(low, 1000, 320), closeTo(680, 0.01));
    final high = heroAlignment(1000, 320, focus: 0);
    expect(bandTop(high, 1000, 320), 0);
  });
}

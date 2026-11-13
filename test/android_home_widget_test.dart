import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/platform/android_home_widget.dart';
import 'package:oamp/platform/android_system_controls.dart';
import 'package:oamp/platform/system_controls.dart';

void main() {
  late List<HomeWidgetState?> sent;
  late AndroidHomeWidget widget;

  NowPlayingInfo info({
    String title = 'Track',
    bool playing = true,
    Duration position = Duration.zero,
    Uri? art,
  }) => NowPlayingInfo(
    title: title,
    artist: 'Artist',
    album: 'Album',
    artUri: art,
    playing: playing,
    position: position,
    canGoNext: true,
  );

  setUp(() {
    sent = [];
    widget = AndroidHomeWidget(send: (s) async => sent.add(s));
  });

  test('sends the track and play state, not position ticks', () {
    widget.show(info());
    widget.show(info(position: const Duration(seconds: 1)));
    widget.show(info(position: const Duration(seconds: 2)));
    expect(sent, hasLength(1));
    expect(sent.single!.toMap(), {
      'title': 'Track',
      'artist': 'Artist',
      'art': null,
      'playing': true,
      'canGoNext': true,
      'canGoPrevious': false,
    });

    widget.show(info(playing: false));
    widget.show(info(title: 'Next one', playing: false));
    expect(sent.map((s) => (s!.title, s.playing)), [
      ('Track', true),
      ('Track', false),
      ('Next one', false),
    ]);
  });

  test('passes on only covers already on disk, never the server URL', () {
    widget.show(
      info(art: Uri.parse('https://music.local/rest/getCoverArt?id=1&t=tok')),
    );
    expect(sent.last!.artPath, isNull);

    widget.show(
      info(art: Uri.file('/data/user/0/dev.oamp.oamp/cache/artwork/ab.art')),
    );
    expect(
      sent.last!.artPath,
      '/data/user/0/dev.oamp.oamp/cache/artwork/ab.art',
    );
  });

  test('clears once, and shows again after', () {
    widget.clear();
    widget.clear();
    expect(sent, [null]);

    widget.show(info());
    widget.clear();
    expect(sent, hasLength(3));
    expect(sent.last, isNull);
  });

  test('a failing platform call never reaches the player', () async {
    final failing = AndroidHomeWidget(send: (_) async => throw Exception('x'));
    failing.show(info());
    failing.clear();
    await Future<void>.delayed(Duration.zero);
  });

  test('the media controls keep the widget in step', () async {
    final controls = AndroidSystemControls(
      OampAudioHandler(),
      requestNotifications: () async => true,
      keepForeground: (_) async {},
      homeWidget: widget,
    );
    await controls.update(info());
    await controls.update(info(playing: false));
    await controls.clear();
    expect(sent.map((s) => s?.playing), [true, false, null]);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/lyrics.dart';
import '../core/models.dart';
import 'session.dart';

/// Which track to fetch lyrics for. A record, so equal requests share one
/// fetch; the classic lookup goes by artist and title, not id.
typedef LyricsRequest = ({String id, String title, String? artist});

LyricsRequest lyricsRequestFor(Track t) =>
    (id: t.id, title: t.title, artist: t.artist);

/// A track's lyrics from the active source. Failures count as no lyrics,
/// since lyrics are a nice extra and an error would only be noise.
final lyricsProvider = FutureProvider.family<Lyrics, LyricsRequest>((
  ref,
  r,
) async {
  final source = ref.watch(musicSourceProvider);
  try {
    return await source.getLyrics(
      Track(id: r.id, title: r.title, artist: r.artist),
    );
  } catch (_) {
    return Lyrics.none;
  }
});

/// Whether now playing shows lyrics over the artwork.
final showLyricsProvider = NotifierProvider<ShowLyricsNotifier, bool>(
  ShowLyricsNotifier.new,
);

class ShowLyricsNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void set(bool show) => state = show;
}

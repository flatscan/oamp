import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/lyrics.dart';
import '../core/models.dart';
import 'session.dart';

/// Which track to fetch lyrics for. A record, so equal requests share one
/// fetch; the classic lookup goes by artist and title, not id.
typedef LyricsRequest = ({String id, String title, String? artist});

LyricsRequest lyricsRequestFor(Track t) =>
    (id: t.id, title: t.title, artist: t.artist);

/// A track's lyrics from the active source. An error is kept, so the
/// lyrics view can say what went wrong.
final lyricsProvider = FutureProvider.family<Lyrics, LyricsRequest>(
  (ref, r) => ref
      .watch(musicSourceProvider)
      .getLyrics(Track(id: r.id, title: r.title, artist: r.artist)),
);

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

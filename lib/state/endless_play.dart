import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/music_source.dart';
import '../platform/preferences.dart';
import 'player.dart';
import 'radio.dart';
import 'session.dart';
import 'settings.dart';

/// What happens when the queue is about to run out.
enum EndlessMode {
  /// Play ends with the queue.
  stop('Stop', 'Play ends with the queue'),

  /// The artist's next album, round to the first after the last. Only for
  /// album queues ([PlayerState.albumQueue]).
  nextAlbum('Next album', "The artist's next album"),

  /// Tracks like the last few in the queue.
  similar('Similar', 'More like the last few songs'),

  /// The listener's liked tracks, shuffled.
  liked('Liked', 'Your liked songs, shuffled'),

  /// Random tracks from the genres of the last few in the queue.
  genre('Genre shuffle', 'Random songs from the same genres');

  const EndlessMode(this.label, this.description);
  final String label;
  final String description;

  static EndlessMode? byName(String? name) {
    for (final m in values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// The endless play mode for each kind of queue, saved per server.
class EndlessSettings {
  /// For queues started by playing a whole album.
  final EndlessMode album;

  /// For everything else: playlists, radio, shuffles, single tracks.
  final EndlessMode other;

  const EndlessSettings({
    this.album = EndlessMode.nextAlbum,
    this.other = EndlessMode.stop,
  });

  /// The mode for an album queue or another queue. Next album only makes
  /// sense after an album, so other queues never get it.
  EndlessMode forQueue({required bool album}) => album
      ? this.album
      : (other == EndlessMode.nextAlbum ? EndlessMode.stop : other);
}

final endlessSettingsProvider =
    NotifierProvider<EndlessSettingsNotifier, EndlessSettings>(
      EndlessSettingsNotifier.new,
    );

class EndlessSettingsNotifier extends Notifier<EndlessSettings> {
  static String albumKey(String serverId) => 'oamp.endless.$serverId.album';
  static String otherKey(String serverId) => 'oamp.endless.$serverId.other';

  String? _serverId;
  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  EndlessSettings build() {
    _serverId = ref.watch(sessionProvider.select((s) => s.value?.serverId));
    final id = _serverId;
    if (id == null) return const EndlessSettings();
    const d = EndlessSettings();
    return EndlessSettings(
      album: EndlessMode.byName(_prefs.getString(albumKey(id))) ?? d.album,
      other: EndlessMode.byName(_prefs.getString(otherKey(id))) ?? d.other,
    );
  }

  /// Sets the mode for album queues or for other queues.
  Future<void> set(EndlessMode mode, {required bool album}) async {
    if (!album && mode == EndlessMode.nextAlbum) return;
    state = album
        ? EndlessSettings(album: mode, other: state.other)
        : EndlessSettings(album: state.album, other: mode);
    final id = _serverId;
    if (id == null) return;
    await _prefs.setString(album ? albumKey(id) : otherKey(id), mode.name);
  }
}

/// The endless play mode for what is queued now.
final endlessModeProvider = Provider<EndlessMode>((ref) {
  final album = ref.watch(playerProvider.select((s) => s.albumQueue));
  return ref.watch(endlessSettingsProvider).forQueue(album: album);
});

/// The modes the listener can pick for what is queued now.
final endlessChoicesProvider = Provider<List<EndlessMode>>((ref) {
  final album = ref.watch(playerProvider.select((s) => s.albumQueue));
  return [
    for (final m in EndlessMode.values)
      if (album || m != EndlessMode.nextAlbum) m,
  ];
});

/// Tops the queue up when it is about to run out, by the mode in
/// [endlessModeProvider]. Watched once from the app root so it lives as
/// long as the app.
final endlessPlayProvider = Provider<EndlessPlay>((ref) {
  final e = EndlessPlay(ref);
  ref.listen(playerProvider, e._onPlayer);
  ref.listen(endlessModeProvider, (_, _) => e._check());
  ref.listen(sessionProvider, (prev, next) {
    if (prev?.value?.serverId != next.value?.serverId) e._played.clear();
  });
  return e;
});

class EndlessPlay {
  EndlessPlay(this.ref, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;
  final Ref ref;
  final DateTime Function() _now;

  /// Top up once this many tracks or fewer are left after the current one.
  static const topUpAt = 6;

  /// Tracks played this recently are not picked again.
  static const recent = Duration(hours: 1);

  /// When each track last started playing, by id.
  final Map<String, DateTime> _played = {};

  /// Set while tracks are being picked.
  Future<void>? _busy;

  /// The queue a top-up last came back empty or failed for, so it is not
  /// asked again until something changes.
  String? _gaveUpOn;

  /// Completes when any top-up under way has finished. For tests.
  Future<void> get idle => _busy ?? Future.value();

  void _onPlayer(PlayerState? prev, PlayerState next) {
    final cur = next.current;
    if (cur != null &&
        (prev?.currentIndex != next.currentIndex ||
            !identical(prev?.current, cur))) {
      _played[cur.id] = _now();
    }
    _check();
  }

  void _check() {
    if (_busy != null || !ref.mounted) return;
    final s = ref.read(playerProvider);
    final mode = ref.read(endlessModeProvider);
    final cur = s.currentIndex;
    if (mode == EndlessMode.stop ||
        s.queue.isEmpty ||
        cur == null ||
        s.repeat != PlaybackRepeat.off) {
      return;
    }
    if (s.queue.length - 1 - cur > topUpAt) return;
    final key = '${mode.name}|${s.queue.length}|${s.queue.last.id}';
    if (key == _gaveUpOn) return;
    _busy = _topUp(mode, s, key).whenComplete(() {
      _busy = null;
      // Something may have changed while the tracks were being picked, or
      // a short album may still leave the queue near its end.
      Future(_check);
    });
  }

  Future<void> _topUp(EndlessMode mode, PlayerState s, String key) async {
    final session = ref.read(sessionProvider).value;
    if (session == null) return;
    final source = session.source;
    final cutoff = _now().subtract(recent);
    _played.removeWhere((_, at) => at.isBefore(cutoff));
    final exclude = {for (final t in s.queue) t.id, ..._played.keys};
    List<Track> tracks;
    try {
      tracks = await EndlessMixer(
        source,
        capabilities: source.capabilities,
      ).pick(mode, s.queue, exclude: exclude);
    } catch (e) {
      debugPrint('Endless play could not pick tracks: $e');
      tracks = const [];
    }
    if (!ref.mounted) return;
    final now = ref.read(playerProvider);
    // The queue was replaced or added to meanwhile, or the mode changed:
    // these tracks no longer follow on. The next check starts again.
    final stillLast =
        now.queue.length == s.queue.length &&
        now.queue.isNotEmpty &&
        identical(now.queue.last, s.queue.last);
    if (!stillLast || ref.read(endlessModeProvider) != mode) return;
    if (tracks.isEmpty) {
      _gaveUpOn = key;
      return;
    }
    await ref.read(playerProvider.notifier).addEndless(tracks);
  }
}

/// Picks the tracks endless play adds, from the queue so far.
class EndlessMixer {
  EndlessMixer(this.source, {required this.capabilities, Random? random})
    : _random = random ?? Random();

  final MusicSource source;
  final SourceCapabilities capabilities;
  final Random _random;

  /// How many tracks a top-up adds (Next album adds the whole album).
  static const batch = 20;

  /// How many of the last queued tracks the mix is built from.
  static const seeds = 6;

  /// Similar tracks asked for per seed.
  static const perSeed = 15;

  /// At most this many genres are mixed.
  static const maxGenres = 3;

  /// Tracks to add after [queue], leaving out ids in [exclude] (except for
  /// Next album, which plays the album as it is). Empty when there is
  /// nothing to add.
  Future<List<Track>> pick(
    EndlessMode mode,
    List<Track> queue, {
    Set<String> exclude = const {},
  }) async {
    if (queue.isEmpty) return const [];
    final from = queue.sublist(max(0, queue.length - seeds));
    return switch (mode) {
      EndlessMode.stop => const [],
      EndlessMode.nextAlbum => nextAlbum(queue.last),
      EndlessMode.similar => similar(from, exclude),
      EndlessMode.liked => liked(exclude, queue),
      EndlessMode.genre => genreShuffle(from, exclude),
    };
  }

  /// The tracks of the album after [last]'s, by its album artist, ordered
  /// by year then name; after the last album, the first.
  Future<List<Track>> nextAlbum(Track last) async {
    final albumId = last.albumId;
    if (albumId == null) return const [];
    final album = (await source.getAlbum(albumId)).album;
    final artistId = album.artistId ?? last.artistId;
    if (artistId == null) return const [];
    final albums = [...(await source.getArtist(artistId)).albums]
      ..sort(albumOrder);
    if (albums.isEmpty) return const [];
    final i = albums.indexWhere((a) => a.id == albumId);
    final next = albums[(i + 1) % albums.length];
    return (await source.getAlbum(next.id)).tracks;
  }

  /// Oldest first, then by name.
  static int albumOrder(Album a, Album b) {
    final y = (a.year ?? 0).compareTo(b.year ?? 0);
    if (y != 0) return y;
    return (a.sortName ?? a.name).toLowerCase().compareTo(
      (b.sortName ?? b.name).toLowerCase(),
    );
  }

  /// Tracks like each of [from], merged and shuffled. Falls back to (or is
  /// topped up from) the genre shuffle when the server finds too few.
  Future<List<Track>> similar(List<Track> from, Set<String> exclude) async {
    final picked = <Track>[];
    if (capabilities.hasSimilar) {
      final ids = {for (final t in from) t.id};
      final pools = await Future.wait([
        for (final id in ids)
          source
              .getSimilarTracks(id, count: perSeed)
              .catchError((Object _) => const <Track>[]),
      ]);
      picked.addAll(_fresh(pools.expand((p) => p), exclude));
      picked.shuffle(_random);
    }
    if (picked.length >= batch ~/ 2) return picked.take(batch).toList();
    final more = await genreShuffle(from, {
      ...exclude,
      for (final t in picked) t.id,
    });
    return [...picked, ...more].take(batch).toList();
  }

  /// Liked tracks, shuffled. When every liked track was played recently,
  /// any that aren't in the last stretch of the queue.
  Future<List<Track>> liked(Set<String> exclude, List<Track> queue) async {
    final all = await source.getLikedTracks();
    var pool = _fresh(all, exclude);
    if (pool.isEmpty) {
      final tail = {
        for (final t in queue.sublist(max(0, queue.length - batch))) t.id,
      };
      pool = _fresh(all, tail);
    }
    return (pool..shuffle(_random)).take(batch).toList();
  }

  /// Random tracks from the genres of [from] (or their albums'), or from
  /// the whole library when they have none.
  Future<List<Track>> genreShuffle(
    List<Track> from,
    Set<String> exclude,
  ) async {
    final genres = capabilities.hasGenres
        ? (await _genres(from)).take(maxGenres).toList()
        : const <String>[];
    final List<Track> pool;
    if (genres.isEmpty) {
      pool = await source.getRandomTracks(size: batch * 2);
    } else {
      final per = (batch * 2 / genres.length).ceil();
      final pools = await Future.wait([
        for (final g in genres) source.getRandomTracks(size: per, genre: g),
      ]);
      pool = RadioMixer.interleave(pools);
    }
    return _fresh(pool, exclude).take(batch).toList();
  }

  Future<List<String>> _genres(List<Track> from) async {
    final tagged = RadioMixer.topGenres(from.expand((t) => t.genres));
    if (tagged.isNotEmpty) return tagged;
    final albumIds = {for (final t in from) ?t.albumId}.take(maxGenres);
    final albums = await Future.wait([
      for (final id in albumIds)
        source
            .getAlbum(id)
            .then<String?>((d) => d.album.genre)
            .catchError((Object _) => null),
    ]);
    return RadioMixer.topGenres(albums.whereType<String>());
  }

  /// [tracks] without those in [exclude] or repeated.
  static List<Track> _fresh(Iterable<Track> tracks, Set<String> exclude) {
    final seen = {...exclude};
    return [
      for (final t in tracks)
        if (seen.add(t.id)) t,
    ];
  }
}

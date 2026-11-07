import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/platform/system_controls.dart';
import 'package:oamp/state/car_library.dart';
import 'package:oamp/state/player.dart';
import 'package:oamp/state/session.dart';

import 'fakes/fakes.dart';

void main() {
  late FakeAudioEngine engine;
  late FakeMusicSource source;
  late ProviderContainer container;

  ProviderContainer start(FakeMusicSource s) {
    source = s;
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => FakeSessionNotifier(source)),
        audioEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => start(FakeMusicSource()));

  CarLibrary library() => container.read(carLibraryProvider);
  PlayerState player() => container.read(playerProvider);
  List<String> ids(List<MediaNode> nodes) => [for (final n in nodes) n.id];

  test('the root holds the four tabs', () async {
    final tabs = await library().children(MediaLibrary.rootId);
    expect(ids(tabs), ['home', 'playlists', 'artists', 'albums']);
    expect(tabs.every((t) => !t.playable), isTrue);
  });

  test('signed out, the car is told to sign in on the phone', () async {
    final c = ProviderContainer(
      overrides: [sessionProvider.overrideWith(_SignedOut.new)],
    );
    addTearDown(c.dispose);
    final root = await c.read(carLibraryProvider).children('root');
    expect(root.single.title, 'Sign in on your phone');
    expect(await c.read(carLibraryProvider).children('home'), isEmpty);
  });

  test('home has the mixes, then album rows under headings', () async {
    final home = await library().children('home');
    expect(ids(home).take(2), ['shuffle/all', 'shuffle/liked']);
    expect(home.take(2).every((n) => n.playable), isTrue);
    final rows = home.skip(2).toList();
    expect(rows.map((n) => n.group).toSet(), {
      'Recently played',
      'Recently added',
      'Most played',
      'Liked albums',
    });
    expect(rows.first.id, 'album/al1');
    expect(rows.first.title, 'Moon Safari');
    expect(rows.first.subtitle, 'Air');
  });

  test('an album lists its tracks; picking one plays from there', () async {
    final tracks = await library().children('album/al1');
    expect(ids(tracks), ['play/album/al1/0', 'play/album/al1/1']);
    expect(tracks.every((t) => t.playable), isTrue);

    await library().play(tracks[1].id);
    expect(player().queue.map((t) => t.id), ['t1', 't2']);
    expect(player().currentIndex, 1);
    expect(player().from, 'Moon Safari');
    expect(engine.playing, isTrue);
  });

  test('playlists open with a shuffle entry first', () async {
    final playlists = await library().children('playlists');
    expect(ids(playlists), ['playlist/pl1']);
    expect(playlists.single.subtitle, '2 songs');

    final entries = await library().children('playlist/pl1');
    expect(ids(entries), [
      'shuffle/playlist/pl1',
      'play/playlist/pl1/0',
      'play/playlist/pl1/1',
    ]);
    await library().play('play/playlist/pl1/0');
    // The fake playlist holds the album backwards.
    expect(player().queue.map((t) => t.id), ['t2', 't1']);
    expect(player().from, 'Mixtape');
  });

  test('an artist shuffles all their tracks or opens an album', () async {
    final page = await library().children('artist/ar1');
    expect(ids(page), ['shuffle/artist/ar1', 'album/al1']);
    await library().play('shuffle/artist/ar1');
    expect(player().queue.map((t) => t.id).toSet(), {'t1', 't2'});
    expect(player().shuffled, isTrue);
  });

  test('long artist and album lists are split by first letter', () async {
    start(
      FakeMusicSource(
        artists: [
          for (var i = 0; i < 150; i++)
            Artist(id: 'a$i', name: '${i.isEven ? 'B' : 'Z'}and $i'),
        ],
        albums: [
          for (var i = 0; i < 700; i++)
            Album(id: 'b$i', name: '${i % 3 == 0 ? '9' : 'Q'}uiet $i'),
        ],
      ),
    );
    expect(ids(await library().children('artists')), [
      'artists/B',
      'artists/Z',
    ]);
    final bs = await library().children('artists/B');
    expect(bs, hasLength(75));
    expect(bs.first.id, 'artist/a0');

    // Albums come from every page, not just the first 500.
    expect(ids(await library().children('albums')), ['albums/%23', 'albums/Q']);
    expect(await library().children('albums/#'), hasLength(234));
    expect(
      await library().children('albums/Q'),
      hasLength(CarLibrary.maxItems),
    );
  });

  test('short lists are shown whole', () async {
    expect(ids(await library().children('artists')), ['artist/ar1']);
    expect(ids(await library().children('albums')), ['album/al1']);
  });

  test('search groups songs, albums and artists', () async {
    final found = await library().search('sexy');
    expect(ids(found), ['play/track/t2']);
    expect(found.single.group, 'Songs');

    final air = await library().search('air');
    expect(air.map((n) => n.group), ['Artists']);
    expect(ids(air), ['artist/ar1']);
  });

  test('a song from search plays with more like it after', () async {
    await library().play('play/track/t2');
    expect(player().queue.first.id, 't2');
    expect(player().from, 'Sexy Boy radio');
  });

  test('voice: an artist name plays that artist, shuffled', () async {
    await library().playFromVoice(const VoiceRequest('air'));
    expect(player().from, 'Air');
    expect(player().shuffled, isTrue);
  });

  test('voice: album focus plays the album in order', () async {
    await library().playFromVoice(
      const VoiceRequest(
        'moon safari',
        focus: VoiceFocus.album,
        album: 'Moon Safari',
      ),
    );
    expect(player().queue.map((t) => t.id), ['t1', 't2']);
    expect(player().from, 'Moon Safari');
  });

  test('voice: a playlist by name', () async {
    await library().playFromVoice(
      const VoiceRequest('mixtape playlist', focus: VoiceFocus.playlist),
    );
    expect(player().from, 'Mixtape');
  });

  test('voice: a song title starts a radio from it', () async {
    await library().playFromVoice(const VoiceRequest('sexy boy'));
    expect(player().queue.first.id, 't2');
  });

  test(
    'voice: "play music" resumes, or shuffles when nothing is loaded',
    () async {
      await library().playFromVoice(const VoiceRequest(''));
      expect(player().from, 'Library shuffle');

      await container.read(playerProvider.notifier).pause();
      expect(engine.playing, isFalse);
      await library().playFromVoice(const VoiceRequest(''));
      expect(engine.playing, isTrue);
      expect(player().from, 'Library shuffle');
    },
  );

  test('recent offers the loaded track to resume', () async {
    expect(await library().children(MediaLibrary.recentId), isEmpty);
    await library().play('play/album/al1/0');
    final recent = await library().children(MediaLibrary.recentId);
    expect(recent.single.id, 'resume');
    expect(recent.single.title, 'La femme d’argent');
  });

  test('signing in tells the car to reload', () async {
    final c = ProviderContainer(
      overrides: [sessionProvider.overrideWith(_SignedOut.new)],
    );
    addTearDown(c.dispose);
    final lib = c.read(carLibraryProvider);
    var changes = 0;
    lib.changes.listen((_) => changes++);
    await c.read(sessionProvider.future);
    (c.read(sessionProvider.notifier) as _SignedOut).signIn(FakeMusicSource());
    await Future<void>.delayed(Duration.zero);
    expect(changes, 1);
    expect(ids(await lib.children('root')), hasLength(4));
  });
}

class _SignedOut extends SessionNotifier {
  @override
  Future<ServerSession?> build() async => null;

  void signIn(FakeMusicSource source) =>
      state = AsyncData(ServerSession(source));
}

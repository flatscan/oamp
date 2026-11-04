import 'package:flutter_test/flutter_test.dart';
import 'package:oamp/core/models.dart';
import 'package:oamp/core/music_source.dart';
import 'package:oamp/state/radio.dart';

import 'fakes/fakes.dart';

List<Track> songs(String prefix, int n, {String? genre}) => [
  for (var i = 0; i < n; i++)
    Track(id: '$prefix$i', title: '$prefix $i', genres: [?genre]),
];

void main() {
  const caps = SourceCapabilities(hasSimilar: true, hasGenres: true);
  const seed = Track(id: 'seed', title: 'Seed', genres: ['Trip hop']);

  test('enough similar tracks play as they are, led by the seed', () async {
    final source = FakeMusicSource()..similarTracks = songs('s', 20);
    final mix = await RadioMixer(source, capabilities: caps).forTrack(seed);
    expect(mix.basis, RadioBasis.similar);
    expect(mix.tracks.first.id, 'seed');
    expect(mix.tracks, hasLength(21));
    expect(source.calls.where((c) => c.startsWith('random:')), isEmpty);
  });

  test('no similar tracks falls back to the seed genre', () async {
    final source = FakeMusicSource()
      ..similarTracks = const []
      ..tracksByGenre = {
        'Trip hop': [seed, ...songs('g', 30, genre: 'Trip hop')],
      };
    final mix = await RadioMixer(source, capabilities: caps).forTrack(seed);
    expect(mix.basis, RadioBasis.genre);
    expect(mix.genres, ['Trip hop']);
    expect(mix.tracks.first.id, 'seed');
    expect(mix.tracks.where((t) => t.id == 'seed'), hasLength(1));
    expect(mix.tracks, hasLength(31));
    expect(source.calls, contains('random:Trip hop'));
  });

  test('a few similar tracks are topped up from the genre', () async {
    final source = FakeMusicSource()
      ..similarTracks = songs('s', 3)
      ..tracksByGenre = {'Trip hop': songs('g', 60, genre: 'Trip hop')};
    final mix = await RadioMixer(
      source,
      capabilities: caps,
      size: 20,
    ).forTrack(seed);
    expect(mix.basis, RadioBasis.similarAndGenre);
    expect(mix.tracks.map((t) => t.id).take(4), ['seed', 's0', 's1', 's2']);
    expect(mix.tracks, hasLength(20));
  });

  test('a track with no genre anywhere gives no radio', () async {
    final source = FakeMusicSource(albums: const [])..similarTracks = const [];
    final mix = await RadioMixer(
      source,
      capabilities: caps,
    ).forTrack(const Track(id: 'x', title: 'X', albumId: 'al1'));
    expect(mix.isEmpty, isTrue);
    expect(mix.basis, RadioBasis.none);
  });

  test('artist radio mixes the genres the artist releases in most', () async {
    final source = FakeMusicSource()
      ..similarTracks = const []
      ..artistExtras = const [
        Album(id: 'a2', name: 'B', genre: 'Electronic'),
        Album(id: 'a3', name: 'C', genre: 'Electronic'),
        Album(id: 'a4', name: 'D', genre: 'Ambient'),
      ]
      ..tracksByGenre = {
        'Electronic': songs('e', 30, genre: 'Electronic'),
        'Ambient': songs('a', 30, genre: 'Ambient'),
      };
    final mix = await RadioMixer(
      source,
      capabilities: caps,
      size: 10,
    ).forArtist('ar1');
    expect(mix.basis, RadioBasis.genre);
    expect(mix.genres, ['Electronic', 'Ambient']);
    // Interleaved, not one genre in a block.
    expect(mix.tracks.map((t) => t.id).take(4), ['e0', 'a0', 'e1', 'a1']);
    expect(mix.tracks, hasLength(10));
  });

  test('a server without similar tracks goes straight to genres', () async {
    final source = FakeMusicSource()
      ..tracksByGenre = {'Trip hop': songs('g', 5, genre: 'Trip hop')};
    final mix = await RadioMixer(
      source,
      capabilities: const SourceCapabilities(hasGenres: true),
    ).forTrack(seed);
    expect(source.calls.where((c) => c.startsWith('similar:')), isEmpty);
    expect(mix.basis, RadioBasis.genre);
  });

  test('topGenres orders by count, then first seen', () {
    expect(RadioMixer.topGenres(['Jazz', 'Rock', 'Rock', ' ', 'Pop']), [
      'Rock',
      'Jazz',
      'Pop',
    ]);
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../app_frame.dart';
import '../async_view.dart';
import '../cover_art.dart';
import '../mode_switch.dart';
import '../theme.dart';
import '../widgets.dart';
import 'artist_page.dart';

/// What the results show: a bit of everything, or more of one kind.
enum SearchFilter { all, artists, albums, tracks }

/// Searches artists, albums and tracks as the user types. With no query it
/// lists recent searches.
class SearchView extends ConsumerStatefulWidget {
  final FocusNode focusNode;
  const SearchView({super.key, required this.focusNode});

  @override
  ConsumerState<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends ConsumerState<SearchView> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  SearchFilter _filter = SearchFilter.all;

  /// How many of each kind to ask for.
  static const _fewOfEach = 20;
  static const _manyOfOne = 100;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String text) {
    setState(() {}); // Shows or hides the clear button.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  void _run(String text) {
    _debounce?.cancel();
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _query = text.trim());
    _remember();
  }

  /// Keeps the query in recent searches. Called when the user submits or
  /// picks a result, so half-typed queries are not kept.
  void _remember() =>
      ref.read(recentSearchesProvider.notifier).add(_controller.text);

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _query = '';
      _filter = SearchFilter.all;
    });
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final key = (
      query: _query,
      limit: _filter == SearchFilter.all ? _fewOfEach : _manyOfOne,
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            // With the title bar hidden, the bar moves the window.
            flexibleSpace: const WindowDragArea(child: SizedBox.expand()),
            toolbarHeight: ModeSwitchButton.toolbarHeight,
            actions: ModeSwitchButton.withActions(null),
            title: TextField(
              controller: _controller,
              focusNode: widget.focusNode,
              onChanged: _changed,
              onSubmitted: _run,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Artists, albums or tracks',
                prefixIcon: const Icon(Icons.search_rounded),
                isDense: true,
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: _clear,
                      ),
              ),
            ),
          ),
          if (_query.isEmpty)
            _RecentSearches(onPick: _run)
          else ...[
            SliverToBoxAdapter(
              child: _FilterChips(
                selected: _filter,
                onSelected: (f) => setState(() => _filter = f),
              ),
            ),
            AsyncSliver(
              value: ref.watch(searchProvider(key)),
              onRetry: () => ref.invalidate(searchProvider(key)),
              builder: (r) => _Results(
                query: _query,
                results: r,
                filter: _filter,
                onFilter: (f) => setState(() => _filter = f),
                onPicked: _remember,
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _FilterChips extends StatelessWidget {
  final SearchFilter selected;
  final ValueChanged<SearchFilter> onSelected;
  const _FilterChips({required this.selected, required this.onSelected});

  static const _labels = {
    SearchFilter.all: 'All',
    SearchFilter.artists: 'Artists',
    SearchFilter.albums: 'Albums',
    SearchFilter.tracks: 'Tracks',
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          for (final f in SearchFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(_labels[f]!),
                selected: f == selected,
                showCheckmark: false,
                onSelected: (_) => onSelected(f),
                selectedColor: Colors.white,
                backgroundColor: OAmpColors.surfaceHigh,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: f == selected ? Colors.black : Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RecentSearches extends ConsumerWidget {
  final ValueChanged<String> onPick;
  const _RecentSearches({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentSearchesProvider);
    if (recent.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: EmptyMessage(
            icon: Icons.search_rounded,
            text: 'Search your library',
          ),
        ),
      );
    }
    final notifier = ref.read(recentSearchesProvider.notifier);
    return SliverList.list(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Recent searches',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(
                onPressed: notifier.clear,
                style: TextButton.styleFrom(
                  foregroundColor: OAmpColors.textMuted,
                ),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        for (final q in recent)
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              tooltip: 'Forget "$q"',
              color: OAmpColors.textFaint,
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => notifier.remove(q),
            ),
            onTap: () => onPick(q),
          ),
      ],
    );
  }
}

/// The best match: an exact name first, then a name that starts with the
/// query, preferring artists, then albums, then tracks. Falls back to the
/// first artist, album or track.
Object? topResult(String query, SearchResults r) {
  final q = query.trim().toLowerCase();
  final candidates = <(Object, String)>[
    for (final a in r.artists) (a, a.name),
    for (final a in r.albums) (a, a.name),
    for (final t in r.tracks) (t, t.title),
  ];
  for (final test in [(String n) => n == q, (String n) => n.startsWith(q)]) {
    for (final (item, name) in candidates) {
      if (test(name.toLowerCase())) return item;
    }
  }
  return candidates.isEmpty ? null : candidates.first.$1;
}

class _Results extends ConsumerWidget {
  final String query;
  final SearchResults results;
  final SearchFilter filter;
  final ValueChanged<SearchFilter> onFilter;
  final VoidCallback onPicked;

  const _Results({
    required this.query,
    required this.results,
    required this.filter,
    required this.onFilter,
    required this.onPicked,
  });

  static const _tracksOnAll = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = results;
    final empty = switch (filter) {
      SearchFilter.all => r.isEmpty,
      SearchFilter.artists => r.artists.isEmpty,
      SearchFilter.albums => r.albums.isEmpty,
      SearchFilter.tracks => r.tracks.isEmpty,
    };
    if (empty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: EmptyMessage(
            icon: Icons.search_off_rounded,
            text: 'No matches',
          ),
        ),
      );
    }
    final tracks = r.tracks;
    void playTrack(List<Track> list, int i) {
      onPicked();
      // A search result plays, then keeps going through the other
      // matching tracks.
      ref
          .read(playerProvider.notifier)
          .playTracks(list, startIndex: i, from: 'Search');
    }

    Widget trackTile(List<Track> list, int i) =>
        TrackTile(track: list[i], onTap: () => playTrack(list, i));

    // Taps on artists and albums open them; noting the search on the way.
    Widget picked(Widget child) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: (_) => onPicked(),
      child: child,
    );

    switch (filter) {
      case SearchFilter.artists:
        return SliverList.builder(
          itemCount: r.artists.length,
          itemBuilder: (_, i) => picked(_ArtistRow(artist: r.artists[i])),
        );
      case SearchFilter.albums:
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverGrid.builder(
            gridDelegate: albumGridDelegate,
            itemCount: r.albums.length,
            itemBuilder: (_, i) => picked(AlbumCard(album: r.albums[i])),
          ),
        );
      case SearchFilter.tracks:
        return SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (_, i) => trackTile(tracks, i),
        );
      case SearchFilter.all:
    }

    final top = topResult(query, r);
    return SliverList.list(
      children: [
        if (top != null) ...[
          const SectionHeader('Top result'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: picked(
              _TopResultCard(item: top, onPlayTrack: (t) => playTrack([t], 0)),
            ),
          ),
        ],
        if (tracks.isNotEmpty) ...[
          SectionHeader(
            'Tracks',
            onSeeAll: tracks.length > _tracksOnAll
                ? () => onFilter(SearchFilter.tracks)
                : null,
          ),
          for (var i = 0; i < tracks.length && i < _tracksOnAll; i++)
            trackTile(tracks, i),
        ],
        if (r.artists.isNotEmpty)
          picked(
            HorizontalShelf(
              title: 'Artists',
              onSeeAll: r.artists.length > 3
                  ? () => onFilter(SearchFilter.artists)
                  : null,
              height: 140,
              spacing: 16,
              itemCount: r.artists.length,
              itemBuilder: (_, i) =>
                  ArtistBubble(artist: r.artists[i], size: 100),
            ),
          ),
        if (r.albums.isNotEmpty)
          picked(
            AlbumCarousel(
              title: 'Albums',
              albums: AsyncData(r.albums),
              onSeeAll: r.albums.length > 2
                  ? () => onFilter(SearchFilter.albums)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// A large card for the best match, whatever kind it is.
class _TopResultCard extends ConsumerWidget {
  final Object item;
  final ValueChanged<Track> onPlayTrack;
  const _TopResultCard({required this.item, required this.onPlayTrack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final (
      Widget art,
      String title,
      String kind,
      VoidCallback onTap,
    ) = switch (item) {
      Artist a => (
        CoverArt(
          a.coverArt,
          size: 88,
          circle: true,
          placeholderIcon: Icons.person_rounded,
        ),
        a.name,
        'Artist',
        () => openArtist(a),
      ),
      Album a => (
        CoverArt(a.coverArt, size: 88, radius: 6),
        a.name,
        ['Album', ?a.artist].join(' · '),
        () => openAlbum(a),
      ),
      Track tr => (
        CoverArt(tr.coverArt, size: 88, radius: 6),
        tr.title,
        ['Track', ?tr.artist].join(' · '),
        () => onPlayTrack(tr),
      ),
      _ => throw ArgumentError.value(item),
    };
    return Material(
      color: OAmpColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: (d) => switch (item) {
          Album a => showAlbumMenu(context, ref, a, at: d.globalPosition),
          Track tr => showTrackMenu(context, ref, tr, at: d.globalPosition),
          _ => null,
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              art,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      kind,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
              Icon(
                item is Track
                    ? Icons.play_circle_fill_rounded
                    : Icons.chevron_right_rounded,
                size: item is Track ? 40 : 24,
                color: item is Track ? oampAccent : OAmpColors.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistRow extends StatelessWidget {
  final Artist artist;
  const _ArtistRow({required this.artist});

  @override
  Widget build(BuildContext context) {
    final n = artist.albumCount;
    return ListTile(
      leading: CoverArt(
        artist.coverArt,
        size: 48,
        circle: true,
        placeholderIcon: Icons.person_rounded,
      ),
      title: Text(
        artist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: n == 0
          ? null
          : Text(
              '$n album${n == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
      onTap: () => openArtist(artist),
    );
  }
}

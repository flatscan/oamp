import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../async_view.dart';
import '../widgets.dart';

/// Searches artists, albums and tracks as the user types.
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

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            toolbarHeight: 72,
            title: TextField(
              controller: _controller,
              focusNode: widget.focusNode,
              onChanged: _changed,
              onSubmitted: (t) => setState(() => _query = t.trim()),
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
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                          widget.focusNode.requestFocus();
                        },
                      ),
              ),
            ),
          ),
          if (_query.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: EmptyMessage(
                  icon: Icons.search_rounded,
                  text: 'Search your library',
                ),
              ),
            )
          else
            AsyncSliver(
              value: ref.watch(searchProvider(_query)),
              onRetry: () => ref.invalidate(searchProvider(_query)),
              builder: (r) => _Results(results: r),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  final SearchResults results;
  const _Results({required this.results});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (results.isEmpty) {
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
    final tracks = results.tracks;
    return SliverList.list(
      children: [
        if (results.artists.isNotEmpty) ...[
          const SectionHeader('Artists'),
          SizedBox(
            height: 140,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: results.artists.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (_, i) =>
                  ArtistBubble(artist: results.artists[i], size: 100),
            ),
          ),
        ],
        AlbumCarousel(title: 'Albums', albums: AsyncData(results.albums)),
        if (tracks.isNotEmpty) ...[
          const SectionHeader('Tracks'),
          for (var i = 0; i < tracks.length; i++)
            TrackTile(
              track: tracks[i],
              // A search result plays on its own, then keeps going through
              // the other matching tracks.
              onTap: () => ref
                  .read(playerProvider.notifier)
                  .playTracks(tracks, startIndex: i, from: 'Search'),
            ),
        ],
      ],
    );
  }
}

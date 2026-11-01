import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../async_view.dart';
import '../widgets.dart';
import 'artist_page.dart';

/// Every album in the library in a chosen order, loaded a page at a time.
class AllAlbumsPage extends ConsumerStatefulWidget {
  final AlbumSort initialSort;
  const AllAlbumsPage({super.key, this.initialSort = AlbumSort.alphabetical});

  @override
  ConsumerState<AllAlbumsPage> createState() => _AllAlbumsPageState();
}

class _AllAlbumsPageState extends ConsumerState<AllAlbumsPage> {
  late AlbumSort _sort = widget.initialSort;

  static const _labels = {
    AlbumSort.alphabetical: 'A to Z',
    AlbumSort.newest: 'Recently added',
    AlbumSort.recent: 'Recently played',
    AlbumSort.frequent: 'Most played',
    AlbumSort.starred: 'Liked',
    AlbumSort.random: 'Random',
  };

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(albumPagesProvider(_sort));
    final notifier = ref.read(albumPagesProvider(_sort).notifier);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 600) notifier.loadMore();
        return false;
      },
      child: ListScaffold(
        title: 'Albums',
        onRefresh: () async => ref.invalidate(albumPagesProvider(_sort)),
        actions: [
          PopupMenuButton<AlbumSort>(
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => [
              for (final e in _labels.entries)
                PopupMenuItem(value: e.key, child: Text(e.value)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(_labels[_sort]!),
                  const Icon(Icons.arrow_drop_down_rounded),
                ],
              ),
            ),
          ),
        ],
        slivers: [
          if (pages.albums.isEmpty && pages.error != null)
            AsyncSliver<void>(
              value: AsyncError<void>(pages.error!, StackTrace.empty),
              builder: (_) => const SliverToBoxAdapter(),
              onRetry: () => ref.invalidate(albumPagesProvider(_sort)),
            )
          else if (pages.albums.isEmpty && pages.done)
            const SliverToBoxAdapter(
              child: EmptyMessage(
                icon: Icons.album_outlined,
                text: 'No albums',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: AlbumSliverGrid(albums: pages.albums),
            ),
          if (pages.loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../async_view.dart';
import '../jump_bar.dart';
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
  final _scroll = ScrollController();

  static const _gridPadding = EdgeInsets.fromLTRB(16, 8, 16 + JumpBar.width, 0);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Loads pages as far as [letter], then scrolls so its first album's row
  /// is at the top.
  Future<void> _jump(String letter) async {
    final index = await ref
        .read(albumPagesProvider(_sort).notifier)
        .loadThrough(letter);
    // Scroll once the grid has laid out any page that just arrived.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _scrollToIndex(index))
      ..scheduleFrame();
  }

  /// Scrolls to [index]'s row. The grid can be a frame or two behind the
  /// pages just loaded, so while the row is past the end it tries again
  /// next frame.
  void _scrollToIndex(int index, [int tries = 5]) {
    if (!mounted || !_scroll.hasClients) return;
    final width = (context.size?.width ?? 0) - _gridPadding.horizontal;
    if (width <= 0) return;
    final row = index ~/ _columns(width);
    final offset = _gridPadding.top + row * _rowStride(width);
    final p = _scroll.position;
    _scroll.jumpTo(offset.clamp(p.minScrollExtent, p.maxScrollExtent));
    if (offset > p.maxScrollExtent && tries > 0) {
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => _scrollToIndex(index, tries - 1))
        ..scheduleFrame();
    }
  }

  // The same sums SliverGridDelegateWithMaxCrossAxisExtent does.
  static int _columns(double width) {
    final d = albumGridDelegate;
    return (width / (d.maxCrossAxisExtent + d.crossAxisSpacing)).ceil().clamp(
      1,
      1 << 20,
    );
  }

  static double _rowStride(double width) {
    final d = albumGridDelegate;
    final n = _columns(width);
    final cell = (width - d.crossAxisSpacing * (n - 1)) / n;
    return cell / d.childAspectRatio + d.mainAxisSpacing;
  }

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
        controller: _scroll,
        // Only A to Z order can be jumped through by letter.
        jumpBar: _sort == AlbumSort.alphabetical && pages.albums.length > 12
            ? JumpBar(onJump: _jump)
            : null,
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
              padding: _sort == AlbumSort.alphabetical
                  ? _gridPadding
                  : const EdgeInsets.fromLTRB(16, 8, 16, 0),
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

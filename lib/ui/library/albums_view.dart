import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/library.dart';
import '../async_view.dart';
import 'album_page.dart';

class AlbumsView extends ConsumerWidget {
  const AlbumsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(
      value: ref.watch(albumsProvider),
      onRetry: () => ref.invalidate(albumsProvider),
      builder: (albums) => RefreshIndicator(
        onRefresh: () => ref.refresh(albumsProvider.future),
        child: AlbumGrid(albums: albums),
      ),
    );
  }
}

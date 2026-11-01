import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../../state/player.dart';
import '../../state/session.dart';
import '../app_frame.dart';
import '../mode_switch.dart';
import '../theme.dart';
import '../../state/system_controls_bridge.dart';
import '../browser.dart';
import '../widgets.dart';
import 'albums_view.dart';
import 'liked_view.dart';
import 'settings_page.dart';

/// The landing tab: quick ways to start music, then rows of albums from the
/// server's own lists.
class HomeView extends ConsumerWidget {
  const HomeView({super.key});

  static const _sections = [
    (AlbumSort.recent, 'Recently played'),
    (AlbumSort.newest, 'Recently added'),
    (AlbumSort.frequent, 'Most played'),
    (AlbumSort.starred, 'Liked albums'),
    (AlbumSort.random, 'Rediscover'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> refresh() async {
      for (final (sort, _) in _sections) {
        ref.invalidate(homeAlbumsProvider(sort));
      }
      await ref.read(homeAlbumsProvider(AlbumSort.recent).future);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // Fixed above the scrolling rows, so the mode switch stays put.
          const _HomeHeader(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: refresh,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  const _QuickStart(),
                  for (final (sort, title) in _sections)
                    AlbumCarousel(
                      title: title,
                      albums: ref.watch(homeAlbumsProvider(sort)),
                      onSeeAll: sort == AlbumSort.random
                          ? null
                          : () => openPage(AllAlbumsPage(initialSort: sort)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeHeader extends ConsumerWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaProblem = ref.watch(systemControlsProblemProvider);
    // The mode switch sits exactly where it does over the now playing
    // artwork; see ModeSwitchButton.
    return WindowDragArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          16,
          ModeSwitchButton.inset,
          ModeSwitchButton.inset,
          4,
        ),
        child: SizedBox(
          height: ModeSwitchButton.size,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Home',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              if (mediaProblem != null)
                IconButton(
                  tooltip: 'Media keys and overlay are not working',
                  icon: const Icon(Icons.warning_amber_rounded),
                  color: Theme.of(context).colorScheme.error,
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Media controls unavailable'),
                      content: SelectableText(mediaProblem),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Settings',
                color: OAmpColors.textMuted,
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => openPage(const SettingsPage()),
              ),
              const ModeSwitchButton(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Large buttons that start music in one click.
class _QuickStart extends ConsumerWidget {
  const _QuickStart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> shuffleAll() async {
      try {
        final tracks = await ref.read(musicSourceProvider).getRandomTracks();
        if (tracks.isEmpty) {
          if (context.mounted) toast(context, 'Your library is empty');
          return;
        }
        await ref
            .read(playerProvider.notifier)
            .playTracks(tracks, from: 'Library shuffle');
      } catch (e) {
        if (context.mounted) toast(context, 'Could not shuffle: $e');
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _QuickTile(
              icon: Icons.shuffle_rounded,
              label: 'Shuffle library',
              colors: const [Color(0xFFFF6B4A), Color(0xFFB8336A)],
              onTap: shuffleAll,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _QuickTile(
              icon: Icons.favorite_rounded,
              label: 'Liked tracks',
              colors: const [Color(0xFF5B5BD6), Color(0xFF2E2E8A)],
              onTap: () => openPage(const LikedTracksPage()),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<Color> colors;
  final VoidCallback onTap;

  const _QuickTile({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            child: Row(
              children: [
                Icon(icon, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

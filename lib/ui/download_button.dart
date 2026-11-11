import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import '../state/downloads.dart';
import '../state/offline.dart';
import '../state/session.dart';
import 'theme.dart';
import 'widgets.dart';

/// Keeps an album, playlist, artist or the liked tracks on the device.
///
/// Shows a download arrow, a ring that fills while the tracks arrive, and a
/// tick once they are all there. Tapping a pinned item asks before removing
/// the download. Hidden where the platform has no place to keep files.
class DownloadButton extends ConsumerStatefulWidget {
  final PinKind kind;
  final String itemId;
  final String name;
  final String? coverArt;

  /// The item's tracks, once they are known. The button is disabled until
  /// there are some, unless [loadTracks] can fetch them.
  final List<Track> tracks;

  /// Fetches the tracks when the button is tapped, for items (an artist's
  /// whole catalogue) that are costly to list before anyone asks.
  final Future<List<Track>> Function()? loadTracks;

  const DownloadButton({
    super.key,
    required this.kind,
    required this.itemId,
    required this.name,
    this.coverArt,
    this.tracks = const [],
    this.loadTracks,
  });

  @override
  ConsumerState<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends ConsumerState<DownloadButton> {
  PinKind get kind => widget.kind;
  String get itemId => widget.itemId;
  String get name => widget.name;
  String? get coverArt => widget.coverArt;
  List<Track> get tracks => widget.tracks;
  Future<List<Track>> Function()? get loadTracks => widget.loadTracks;

  @override
  void initState() {
    super.initState();
    // Opening a downloaded item reads it from the server again, so it
    // shows what is there now.
    Future.microtask(() {
      if (!mounted) return;
      final manager = ref.read(downloadsProvider.notifier);
      if (ref.read(downloadsProvider).pinFor(kind, itemId) != null) {
        unawaited(manager.syncPin(kind, itemId));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(downloadStoreProvider) == null) {
      return const SizedBox.shrink();
    }
    final status = ref.watch(
      downloadsProvider.select((s) => s.statusOf(kind, itemId)),
    );
    final manager = ref.read(downloadsProvider.notifier);
    // Nothing new can be downloaded with no server to download from.
    if (status == null && ref.watch(offlineProvider)) {
      return const SizedBox.shrink();
    }

    Future<void> onTap() async {
      if (status == null) {
        final List<Track> wanted;
        try {
          wanted = loadTracks == null ? tracks : await loadTracks!();
        } catch (e) {
          if (context.mounted) toast(context, 'Could not list the tracks: $e');
          return;
        }
        if (wanted.isEmpty) {
          if (context.mounted) toast(context, 'Nothing to download');
          return;
        }
        await manager.pin(
          kind,
          itemId,
          name: name,
          coverArt: coverArt,
          tracks: wanted,
        );
        if (context.mounted) {
          toast(context, 'Downloading "$name"');
        }
        return;
      }
      final remove = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove download?'),
          content: Text(
            '"$name" will be removed from this device. It stays on the '
            'server.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (remove == true) await manager.unpin(kind, itemId);
    }

    final Widget icon;
    final String tooltip;
    if (status == null) {
      icon = const Icon(Icons.arrow_circle_down_rounded);
      tooltip = 'Download';
    } else if (status.complete) {
      icon = const Icon(Icons.download_done_rounded, color: oampAccent);
      tooltip = 'Downloaded. Tap to remove';
    } else {
      icon = SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          value: status.progress > 0 ? status.progress : null,
          color: oampAccent,
        ),
      );
      tooltip = 'Downloading ${status.done} of ${status.total}. Tap to remove';
    }
    return IconButton(
      tooltip: tooltip,
      color: OAmpColors.textMuted,
      icon: icon,
      onPressed: status == null && tracks.isEmpty && loadTracks == null
          ? null
          : onTap,
    );
  }
}

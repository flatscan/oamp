import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';

/// Square cover image fetched with Subsonic `getCoverArt`, with a placeholder.
class CoverArt extends ConsumerWidget {
  final String? coverArtId;
  final double size;
  final double radius;

  const CoverArt(this.coverArtId, {super.key, this.size = 48, this.radius = 4});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(sessionProvider).value;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Request a size bucket so the same image is reused across widgets.
    final px = (size * dpr) <= 150 ? 150 : ((size * dpr) <= 300 ? 300 : 600);
    final url = client?.coverArtUrl(coverArtId, size: px);
    final placeholder = Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.album, size: size * 0.5),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? placeholder
            : Image.network(
                url.toString(),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

String formatDuration(Duration? d) {
  if (d == null) return '';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

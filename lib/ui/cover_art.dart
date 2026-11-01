import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';
import 'theme.dart';

/// Picks a size bucket for [logicalSize] so the same image is fetched once
/// and reused by every widget that shows it.
int coverArtBucket(double logicalSize, double dpr) {
  final px = logicalSize * dpr;
  if (px <= 150) return 150;
  if (px <= 300) return 300;
  if (px <= 600) return 600;
  return 1000;
}

/// Square cover art from the active source, with a placeholder when there is
/// none. Set [circle] for artist pictures.
class CoverArt extends ConsumerWidget {
  final String? coverArtId;
  final double size;
  final double radius;
  final bool circle;
  final IconData placeholderIcon;

  const CoverArt(
    this.coverArtId, {
    super.key,
    this.size = 48,
    this.radius = 6,
    this.circle = false,
    this.placeholderIcon = Icons.album_rounded,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(sessionProvider).value?.source;
    final px = coverArtBucket(size, MediaQuery.devicePixelRatioOf(context));
    final url = source?.coverArtUrl(coverArtId, size: px);
    final placeholder = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2A2F), Color(0xFF17171A)],
        ),
      ),
      child: Center(
        child: Icon(
          placeholderIcon,
          size: size * 0.42,
          color: OAmpColors.textFaint,
        ),
      ),
    );
    final image = SizedBox.square(
      dimension: size,
      child: url == null
          ? placeholder
          : Image.network(
              url.toString(),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
              frameBuilder: (context, child, frame, sync) => sync
                  ? child
                  : AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      child: child,
                    ),
            ),
    );
    return circle
        ? ClipOval(child: image)
        : ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }
}

String formatDuration(Duration? d) {
  if (d == null) return '';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// A total running time in words, such as "1 hr 12 min" or "42 min".
String formatLongDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return m > 0 ? '$h hr $m min' : '$h hr';
  return '${d.inMinutes} min';
}

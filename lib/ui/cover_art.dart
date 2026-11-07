import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/artwork_cache.dart';
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

/// An image from the [ArtworkCache]: from disk when it has been seen
/// before, otherwise fetched once and saved. Two providers with the same
/// [cacheKey] are equal, so Flutter's in-memory image cache shares them too.
class CachedArtworkImage extends ImageProvider<CachedArtworkImage> {
  final String cacheKey;
  final Uri url;
  final ArtworkCache cache;

  const CachedArtworkImage(this.cacheKey, this.url, this.cache);

  @override
  Future<CachedArtworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CachedArtworkImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: cacheKey,
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await cache.load(cacheKey, url);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is CachedArtworkImage && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;

  @override
  String toString() => 'CachedArtworkImage($cacheKey)';
}

/// The image for [coverArtId] at [size] pixels from the active server,
/// through the artwork cache when there is one. Null when there is no
/// image or nobody is signed in.
ImageProvider? coverArtImage(WidgetRef ref, String? coverArtId, int size) {
  // Rebuild on a move between home and away, so a picture that failed on
  // the old address loads from the new one.
  ref.watch(serverRouteProvider);
  return coverArtImageFrom(
    ref.watch(sessionProvider).value,
    ref.watch(artworkCacheProvider),
    coverArtId,
    size,
  );
}

ImageProvider? coverArtImageFrom(
  ServerSession? session,
  ArtworkCache? cache,
  String? coverArtId,
  int size,
) {
  final url = session?.source.coverArtUrl(coverArtId, size: size);
  if (url == null) return null;
  if (cache == null) return NetworkImage(url.toString());
  return CachedArtworkImage(
    '${session!.serverId}/$coverArtId/$size',
    url,
    cache,
  );
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
    final px = coverArtBucket(size, MediaQuery.devicePixelRatioOf(context));
    final image = coverArtImage(ref, coverArtId, px);
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
    final box = SizedBox.square(
      dimension: size,
      child: image == null
          ? placeholder
          : Image(
              image: image,
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
        ? ClipOval(child: box)
        : ClipRRect(borderRadius: BorderRadius.circular(radius), child: box);
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

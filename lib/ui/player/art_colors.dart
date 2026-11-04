import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session.dart';
import '../cover_art.dart';

/// The most characteristic colour of a cover, for tinting the now playing
/// screen. Null when there is no cover or it cannot be read.
final artColorProvider = FutureProvider.family<Color?, String?>((
  ref,
  coverArt,
) async {
  final image = coverArtImageFrom(
    ref.watch(sessionProvider).value,
    ref.watch(artworkCacheProvider),
    coverArt,
    150,
  );
  if (image == null) return null;
  try {
    final scheme = await ColorScheme.fromImageProvider(
      provider: image,
      brightness: Brightness.dark,
    );
    return scheme.primary;
  } catch (_) {
    return null;
  }
});

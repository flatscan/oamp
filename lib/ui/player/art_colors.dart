import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session.dart';

/// The most characteristic colour of a cover, for tinting the now playing
/// screen. Null when there is no cover or it cannot be read.
final artColorProvider = FutureProvider.family<Color?, String?>((
  ref,
  coverArt,
) async {
  final url = ref.watch(musicSourceProvider).coverArtUrl(coverArt, size: 150);
  if (url == null) return null;
  try {
    final scheme = await ColorScheme.fromImageProvider(
      provider: NetworkImage(url.toString()),
      brightness: Brightness.dark,
    );
    return scheme.primary;
  } catch (_) {
    return null;
  }
});

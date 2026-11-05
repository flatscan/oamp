import 'dart:typed_data';

import 'track_cache.dart';

/// An on-disk cache of cover and artist images, so artwork already seen is
/// shown from disk instead of being fetched from the server again.
///
/// Images are named by [key], which a caller builds from the server, the
/// image id and the size; [url] is only where to fetch it on a miss, so a
/// URL that changes with each sign-in (fresh auth salt) still hits.
abstract class ArtworkCache {
  /// The image's bytes: from disk when cached, otherwise fetched from [url]
  /// and saved. Throws when it can be neither read nor fetched.
  Future<Uint8List> load(String key, Uri url);

  /// A `file:` URI for the image, fetching and saving it first if needed,
  /// so it can be handed to the OS without the signed server URL. Null
  /// when the image can't be kept on disk (the cache has no files, or the
  /// server said not to store it). Throws when it can't be fetched.
  Future<Uri?> localUri(String key, Uri url);

  Future<CacheUsage> usage();

  /// Deletes every cached image.
  Future<void> clear();
}

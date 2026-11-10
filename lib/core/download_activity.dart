/// Tells the operating system that downloads are under way, so it keeps the
/// app running with the screen off. On Android this is the "Downloading N
/// of M" notification; other platforms need nothing.
abstract class DownloadActivity {
  /// Shows, or updates, the sign that [done] of [total] tracks are in.
  Future<void> show({required int done, required int total});

  /// Takes the sign away.
  Future<void> hide();
}

/// For platforms where the app keeps running anyway, and for tests.
class NoDownloadActivity implements DownloadActivity {
  const NoDownloadActivity();

  @override
  Future<void> show({required int done, required int total}) async {}

  @override
  Future<void> hide() async {}
}

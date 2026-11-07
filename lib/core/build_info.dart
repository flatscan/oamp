import 'app_version.dart';

/// What this build is. The Release workflow stamps the release tag in with
/// `--dart-define=OAMP_RELEASE_TAG=v1.0.0-Alpha2`, and CI stamps its run
/// number with `--dart-define=OAMP_CI_RUN=123`. A local build has neither.
class BuildInfo {
  final String releaseTag;
  final String ciRun;

  const BuildInfo({this.releaseTag = '', this.ciRun = ''});

  /// This build, from the values stamped in at build time.
  static const current = BuildInfo(
    releaseTag: String.fromEnvironment('OAMP_RELEASE_TAG'),
    ciRun: String.fromEnvironment('OAMP_CI_RUN'),
  );

  /// Whether this is a published release, which is the only kind of build
  /// that checks for updates on its own.
  bool get isRelease => version != null;

  /// The release this build is, or null for test and local builds.
  AppVersion? get version => AppVersion.tryParse(releaseTag);

  /// How the build is named in Settings and in diagnostics.
  String get label => isRelease
      ? releaseTag
      : ciRun.isNotEmpty
      ? 'Test build #$ciRun'
      : 'Development build';
}

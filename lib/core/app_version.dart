/// A release version from a tag such as `v1.0.0-Alpha1`, `v1.2.0-Beta3`,
/// `v1.2.0-RC1` or `v1.2.0`. Alphas come before betas, betas before release
/// candidates, and those before the plain release of the same number.
class AppVersion implements Comparable<AppVersion> {
  final int major;
  final int minor;
  final int patch;

  /// `alpha`, `beta` or `rc`, lower case; empty for a final release.
  final String stage;
  final int stageNumber;

  const AppVersion(
    this.major,
    this.minor,
    this.patch, {
    this.stage = '',
    this.stageNumber = 0,
  });

  static final _pattern = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:[-.]?([A-Za-z]+)[-.]?(\d*))?$',
  );

  /// The version in [tag], or null when the tag is not one.
  static AppVersion? tryParse(String tag) {
    final m = _pattern.firstMatch(tag.trim());
    if (m == null) return null;
    final stage = (m[4] ?? '').toLowerCase();
    if (stage.isNotEmpty && _rank(stage) == null) return null;
    return AppVersion(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      stage: stage,
      stageNumber: int.tryParse(m[5] ?? '') ?? 0,
    );
  }

  static int? _rank(String stage) => switch (stage) {
    'alpha' || 'a' => 0,
    'beta' || 'b' => 1,
    'rc' => 2,
    '' => 3,
    _ => null,
  };

  bool get isPreRelease => stage.isNotEmpty;

  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
      (_rank(stage)!, _rank(other.stage)!),
      (stageNumber, other.stageNumber),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, stage, stageNumber);

  @override
  String toString() =>
      '$major.$minor.$patch${stage.isEmpty ? '' : '-$stage$stageNumber'}';
}

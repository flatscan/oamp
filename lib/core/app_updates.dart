import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_version.dart';

/// A published release on the project's releases page.
class ReleaseInfo {
  final String tag;
  final AppVersion version;

  /// The release page, where the downloads and notes are.
  final Uri page;

  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.page,
  });
}

/// Where releases are listed. GitHub in the app; a fake in tests.
abstract class ReleaseFeed {
  /// Published releases, in any order. Throws when the list can't be read.
  Future<List<ReleaseInfo>> releases();
}

/// The newest release in [releases], or null when there are none.
ReleaseInfo? newestRelease(Iterable<ReleaseInfo> releases) {
  ReleaseInfo? best;
  for (final r in releases) {
    if (best == null || r.version > best.version) best = r;
  }
  return best;
}

/// The project's public GitHub releases, pre-releases included, read
/// without signing in. Only GitHub sees the request: it carries no details
/// about the user, their server or their music.
class GitHubReleaseFeed implements ReleaseFeed {
  static const repository = 'flatscan/oamp';
  static final releasesPage = Uri.parse(
    'https://github.com/$repository/releases',
  );
  static final _api = Uri.parse(
    'https://api.github.com/repos/$repository/releases?per_page=20',
  );

  final http.Client _client;
  GitHubReleaseFeed([http.Client? client]) : _client = client ?? http.Client();

  @override
  Future<List<ReleaseInfo>> releases() async {
    final reply = await _client
        .get(
          _api,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'OAmp',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (reply.statusCode != 200) {
      throw ReleaseFeedException('GitHub answered ${reply.statusCode}');
    }
    return parse(reply.body);
  }

  /// The releases in a GitHub releases list, leaving out drafts and tags
  /// that aren't versions.
  static List<ReleaseInfo> parse(String body) {
    final list = jsonDecode(body);
    if (list is! List) throw const ReleaseFeedException('Unexpected reply');
    return [
      for (final r in list.whereType<Map<String, dynamic>>())
        if (r['draft'] != true)
          if (AppVersion.tryParse('${r['tag_name']}') case final version?)
            ReleaseInfo(
              tag: '${r['tag_name']}',
              version: version,
              page: _page(r['html_url']),
            ),
    ];
  }

  /// The release's own page when GitHub gave one on github.com, else the
  /// releases list. Never somewhere else, whatever the reply says.
  static Uri _page(Object? url) {
    final uri = Uri.tryParse('$url');
    if (uri != null && uri.scheme == 'https' && uri.host == 'github.com') {
      return uri;
    }
    return releasesPage;
  }
}

class ReleaseFeedException implements Exception {
  final String message;
  const ReleaseFeedException(this.message);

  @override
  String toString() => message;
}

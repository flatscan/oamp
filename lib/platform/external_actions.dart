import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Handing things to other apps: web pages to the browser, a folder to the
/// file manager, a file to the share sheet.
abstract class ExternalActions {
  Future<bool> openUrl(Uri url);
  Future<bool> openFolder(String path);
  Future<bool> shareFile(String path, {required String subject});
}

class PlatformExternalActions implements ExternalActions {
  const PlatformExternalActions();

  @override
  Future<bool> openUrl(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openFolder(String path) async {
    try {
      return await launchUrl(Uri.directory(path, windows: true));
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> shareFile(String path, {required String subject}) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'text/plain')],
          subject: subject,
        ),
      );
      return result.status != ShareResultStatus.unavailable;
    } catch (_) {
      return false;
    }
  }
}

/// Does nothing, for tests and before startup wires in the real one.
class NoExternalActions implements ExternalActions {
  const NoExternalActions();

  @override
  Future<bool> openUrl(Uri url) async => false;

  @override
  Future<bool> openFolder(String path) async => false;

  @override
  Future<bool> shareFile(String path, {required String subject}) async => false;
}

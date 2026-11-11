import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/download_activity.dart';

/// [DownloadActivity] on Android: a foreground service with a low-key
/// notification, so a long download carries on with the screen off.
/// MainActivity hands the calls to DownloadService on `oamp/downloads`.
class AndroidDownloadActivity implements DownloadActivity {
  AndroidDownloadActivity();

  static const _channel = MethodChannel('oamp/downloads');
  static const _notifications = MethodChannel('oamp/notifications');

  bool _asked = false;
  bool _reportedRefusal = false;
  bool _reportedStart = false;

  @override
  Future<void> show({required int done, required int total}) async {
    if (!_asked) {
      // Android 13+ asks before an app may post notifications; without the
      // answer the download still runs, only unseen.
      _asked = true;
      await _notifications.invokeMethod<bool>('requestPermission');
    }
    final started = await _channel.invokeMethod<bool>('show', {
      'done': done,
      'total': total,
    });
    if (started == true && !_reportedStart) {
      _reportedStart = true;
      debugPrint('Download notification started');
    }
    if (started == false && !_reportedRefusal) {
      // Shows up in the diagnostics log, so a missing notification can be
      // told apart from one Android refused to start.
      _reportedRefusal = true;
      debugPrint('Android would not start the download notification');
    }
  }

  @override
  Future<void> hide() => _channel.invokeMethod<void>('hide');
}

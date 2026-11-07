import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// The operating system and, on phones, the device model, for bug reports.
/// Deliberately leaves out anything that names the user or the machine,
/// such as the computer name, the Windows user or the device serial.
class DeviceDetails {
  final String system;
  final String? model;

  const DeviceDetails({required this.system, this.model});

  static Future<DeviceDetails> read() async {
    final fallback = DeviceDetails(system: defaultTargetPlatform.name);
    if (kIsWeb) return const DeviceDetails(system: 'Web');
    try {
      final info = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await info.androidInfo;
          return DeviceDetails(
            system: 'Android ${a.version.release} (SDK ${a.version.sdkInt})',
            model: '${a.manufacturer} ${a.model}',
          );
        case TargetPlatform.windows:
          final w = await info.windowsInfo;
          // Windows 11 still calls itself Windows 10 in the registry; the
          // build number tells them apart.
          final name = w.buildNumber >= 22000 ? 'Windows 11' : 'Windows 10';
          final release = w.displayVersion.isEmpty
              ? ''
              : '${w.displayVersion}, ';
          return DeviceDetails(
            system:
                '$name ($release'
                'build ${w.buildNumber})',
          );
        default:
          return fallback;
      }
    } catch (_) {
      return fallback;
    }
  }
}

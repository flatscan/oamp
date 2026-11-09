/// Speakers and TVs on the local network that OAmp can play to.
///
/// This is the backend-free part: what a found device looks like and how
/// the app asks for them. Finding them needs sockets, so the finders live
/// in lib/outputs and main.dart plugs them in.
library;

/// How OAmp talks to a device.
enum OutputProtocol {
  /// Google Cast: Chromecast, Google TV, Nest speakers and displays, and
  /// TVs with Cast built in.
  cast,

  /// DLNA / UPnP media renderers: many TVs, Kodi, AV receivers.
  dlna;

  /// Which protocol wins when one device speaks several. Lower is better.
  int get preference => switch (this) {
    OutputProtocol.cast => 0,
    OutputProtocol.dlna => 1,
  };

  String get label => switch (this) {
    OutputProtocol.cast => 'Cast',
    OutputProtocol.dlna => 'DLNA',
  };
}

/// A speaker, TV or group found on the network.
class OutputDevice {
  /// Stable for the device across scans and app restarts, and unique
  /// within [protocol].
  final String id;
  final OutputProtocol protocol;

  /// The name the owner gave it, such as "Living room TV". Shown in the
  /// app only: never logged, because a name can say who someone is.
  final String name;

  /// Make and model, such as "Google Nest Mini", when the device says.
  /// Safe for diagnostics.
  final String? model;

  /// Where to reach it.
  final String host;
  final int port;

  /// Where the device describes itself (DLNA only).
  final Uri? descriptionUrl;

  /// A Cast speaker group rather than a single device.
  final bool isGroup;

  /// Whether it has a screen, so it can show artwork.
  final bool hasScreen;

  const OutputDevice({
    required this.id,
    required this.protocol,
    required this.name,
    required this.host,
    required this.port,
    this.model,
    this.descriptionUrl,
    this.isGroup = false,
    this.hasScreen = false,
  });

  /// Identifies the device across protocols.
  String get key => '${protocol.name}:$id';

  @override
  bool operator ==(Object other) =>
      other is OutputDevice &&
      other.key == key &&
      other.name == name &&
      other.model == model &&
      other.host == host &&
      other.port == port &&
      other.descriptionUrl == descriptionUrl &&
      other.isGroup == isGroup &&
      other.hasScreen == hasScreen;

  @override
  int get hashCode => Object.hash(key, name, host, port);

  @override
  String toString() =>
      'OutputDevice(${protocol.label}, ${model ?? 'unknown model'}'
      '${isGroup ? ', group' : ''})';
}

/// Merges what every protocol found into the one list the listener sees.
///
/// A TV that speaks both Cast and DLNA is listed once, under the protocol
/// that works best ([OutputProtocol.preference]). Devices are matched by
/// address, since names differ between protocols. Cast groups share their
/// leader's address but are separate entries, so they are never merged.
/// The result is sorted by name.
List<OutputDevice> mergeDevices(Iterable<OutputDevice> found) {
  final byHost = <String, OutputDevice>{};
  final others = <OutputDevice>[];
  for (final d in found) {
    if (d.isGroup) {
      others.add(d);
      continue;
    }
    final seen = byHost[d.host];
    if (seen == null || d.protocol.preference < seen.protocol.preference) {
      byHost[d.host] = d;
    }
  }
  return [...byHost.values, ...others]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// Finds output devices on the local network.
abstract class DeviceDiscovery {
  /// The devices found so far, merged across protocols, updated as they
  /// answer. Starts with the last known list.
  Stream<List<OutputDevice>> get devices;
  List<OutputDevice> get current;

  /// Whether a scan is running.
  bool get scanning;

  /// Asks the network who is there. A device that stays silent for
  /// several scans in a row is dropped when the scan ends; one missed
  /// reply doesn't remove it.
  Future<void> scan();

  Future<void> dispose();
}

/// Finds nothing: the web, tests, and platforms without casting.
class NoDeviceDiscovery implements DeviceDiscovery {
  const NoDeviceDiscovery();

  @override
  Stream<List<OutputDevice>> get devices => const Stream.empty();

  @override
  List<OutputDevice> get current => const [];

  @override
  bool get scanning => false;

  @override
  Future<void> scan() async {}

  @override
  Future<void> dispose() async {}
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../core/output_device.dart';
import 'udp_query.dart';

/// Finds DLNA / UPnP media renderers with an SSDP M-SEARCH, then reads
/// each one's device description for its name and services.
class DlnaFinder {
  DlnaFinder({UdpQuery? query, http.Client? client})
    : _query =
          query ??
          UdpQuery(group: InternetAddress('239.255.255.250'), port: ssdpPort),
      _client = client ?? http.Client();

  static const ssdpPort = 1900;
  static const renderer = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const avTransport = 'urn:schemas-upnp-org:service:AVTransport:';

  final UdpQuery _query;
  final http.Client _client;

  /// The M-SEARCH request. MX is how many seconds devices may wait before
  /// answering, to spread replies out.
  static Uint8List searchRequest({int mx = 2}) => Uint8List.fromList(
    ascii.encode(
      'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:$ssdpPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: $mx\r\n'
      'ST: $renderer\r\n'
      'USER-AGENT: OAmp UPnP/1.1\r\n'
      '\r\n',
    ),
  );

  /// Each renderer as it answers, once per scan.
  Stream<OutputDevice> find({
    Duration listenFor = const Duration(seconds: 3),
  }) async* {
    final seen = <Uri>{};
    final pending = <Future<OutputDevice?>>[];
    final ready = StreamController<OutputDevice>();
    final replies = _query
        .send(searchRequest(), listenFor: listenFor)
        .listen(
          (reply) {
            final location = ssdpLocation(
              latin1.decode(reply.data, allowInvalid: true),
            );
            if (location == null || !seen.add(location)) return;
            final f = describe(location);
            pending.add(f);
            f.then((d) {
              if (d != null && !ready.isClosed) ready.add(d);
            });
          },
          onDone: () async {
            await Future.wait(pending);
            await ready.close();
          },
        );
    try {
      yield* ready.stream;
    } finally {
      await replies.cancel();
    }
  }

  /// Fetches and reads the description at [location]. Null when it can't
  /// be fetched or is not a renderer OAmp can drive.
  Future<OutputDevice?> describe(Uri location) async {
    try {
      final reply = await _client
          .get(location)
          .timeout(const Duration(seconds: 4));
      if (reply.statusCode != 200) return null;
      return dlnaDeviceFrom(
        utf8.decode(reply.bodyBytes, allowMalformed: true),
        location,
      );
    } on Object catch (e) {
      debugPrint('Discovery: a DLNA description could not be read ($e)');
      return null;
    }
  }

  void dispose() => _client.close();
}

/// The LOCATION header of an SSDP reply, when it is a media renderer's.
Uri? ssdpLocation(String reply) {
  final lines = const LineSplitter().convert(reply);
  if (lines.isEmpty || !lines.first.toUpperCase().startsWith('HTTP/1.1 200')) {
    return null;
  }
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim().toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  final st = headers['st'] ?? '';
  if (!st.toLowerCase().contains('mediarenderer')) return null;
  final location = Uri.tryParse(headers['location'] ?? '');
  if (location == null || !location.isScheme('http')) return null;
  return location;
}

final _screen = RegExp(
  r'\btv\b|television|bravia|webos|tizen|kodi',
  caseSensitive: false,
);

/// Reads a UPnP device description. Null unless it is a media renderer
/// with an AVTransport service, which is what OAmp needs to play to it.
OutputDevice? dlnaDeviceFrom(String xml, Uri location) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException {
    return null;
  }
  String? text(XmlElement e, String name) {
    final v = e.getElement(name)?.innerText.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  // The renderer may be the root device or one of its embedded devices.
  for (final device in doc.findAllElements('device')) {
    final type = text(device, 'deviceType') ?? '';
    if (!type.toLowerCase().contains('mediarenderer')) continue;
    final services = device
        .getElement('serviceList')
        ?.findElements('service')
        .map((s) => text(s, 'serviceType') ?? '');
    if (services == null ||
        !services.any((s) => s.startsWith(DlnaFinder.avTransport))) {
      continue;
    }
    final udn = text(device, 'UDN') ?? location.toString();
    final make = text(device, 'manufacturer');
    final model = text(device, 'modelName');
    final described = [?make, ?model].join(' ');
    final name = text(device, 'friendlyName') ?? model ?? 'Media renderer';
    // DLNA doesn't say whether a renderer has a screen; TVs and media
    // centres name themselves as such.
    final about = [
      name,
      ?model,
      ?text(device, 'modelDescription'),
      ?text(device, 'modelNumber'),
    ].join(' ');
    return OutputDevice(
      id: udn.replaceFirst(RegExp('^uuid:', caseSensitive: false), ''),
      protocol: OutputProtocol.dlna,
      name: name,
      model: described.isEmpty ? null : described,
      hasScreen: _screen.hasMatch(about),
      host: location.host,
      port: location.port,
      descriptionUrl: location,
    );
  }
  return null;
}

import '../core/output_device.dart';
import '../core/remote_player.dart';
import 'cast/cast_player.dart';
import 'dlna/dlna_player.dart';

/// Connects to a found device with the protocol it was found by.
Future<RemotePlayer> connectToDevice(OutputDevice device) =>
    switch (device.protocol) {
      OutputProtocol.cast => CastPlayer.connect(device),
      OutputProtocol.dlna => DlnaPlayer.connect(device),
    };

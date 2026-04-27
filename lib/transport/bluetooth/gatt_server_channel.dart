import 'dart:async';
import 'package:flutter/services.dart';

/// Dart wrapper around the `phantom/gatt_server` platform channel.
///
/// The Android side ([PhantomGattServer.kt]) exposes:
///   - A GATT server with the Phantom service + writable characteristic,
///     so remote phones (acting as GATT clients) can write mesh packets to us.
///   - A BLE advertiser that broadcasts our Phantom service UUID + nodeHint
///     in manufacturer data, so remote scanners can discover us.
///
/// Platform channel contract (`phantom/gatt_server`):
///
///   Dart → Android:
///     start(List<int> msdPayload)  — start server + advertising
///     stop()                       — stop both
///     notifyAll(List<int> data)    — push bytes to all connected centrals
///
///   Android → Dart:
///     onWrite(List<int> data)      — a remote device wrote to our characteristic
class GattServerChannel {
  static const _ch = MethodChannel('phantom/gatt_server');

  final _rxController = StreamController<Uint8List>.broadcast();

  /// Stream of raw bytes received from remote GATT clients writing to our characteristic.
  Stream<Uint8List> get received => _rxController.stream;

  GattServerChannel() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onWrite') {
        final bytes = Uint8List.fromList(
          (call.arguments as List).map((e) => (e as int) & 0xFF).toList(),
        );
        _rxController.add(bytes);
      }
    });
  }

  /// Start the GATT server and begin advertising.
  ///
  /// [msdPayload] must be the 8-byte output of [MeshAdvertisement.toAdvPayload()]:
  ///   [0xFF][0xFF][0x50][hint0][hint1][hint2][hint3][caps]
  Future<void> start(Uint8List msdPayload) async {
    await _ch.invokeMethod<void>('start', msdPayload.toList());
  }

  /// Stop the GATT server and advertising.
  Future<void> stop() async {
    await _ch.invokeMethod<void>('stop');
  }

  /// Notify all GATT clients currently connected to our server.
  /// Used to push ACKs or relay packets to peers that connected TO us
  /// (rather than us connecting to them as GATT client).
  Future<void> notifyAll(Uint8List data) async {
    await _ch.invokeMethod<void>('notifyAll', data.toList());
  }

  Future<void> dispose() async {
    await stop();
    await _rxController.close();
  }
}

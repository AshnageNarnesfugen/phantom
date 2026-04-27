import 'dart:async';
import 'package:flutter/services.dart';

// Platform channel contract (phantom/gatt_server):
//
//   Dart → Android:
//     start(Uint8List)     — start GATT server + advertising → GattStartResult
//     stop()               — stop both
//     notifyAll(Uint8List) — push bytes to all connected centrals → int (delivered count)
//
//   Android → Dart:
//     onWrite(Uint8List data)           — remote device wrote to our characteristic
//     onClientConnected(String address) — a central connected to our server
//     onClientDisconnected(String addr) — a central disconnected
//     onMtuChanged(int mtu)             — central negotiated a new MTU
//     onAdvertiseFailed(int errorCode)  — advertising failed permanently

// ── Start result ──────────────────────────────────────────────────────────────

sealed class GattStartResult {
  const GattStartResult();
  bool get success;
  bool get isUserActionable;
  String? get reason;
}

final class GattStartOk extends GattStartResult {
  const GattStartOk();
  @override
  bool get success => true;
  @override
  bool get isUserActionable => false;
  @override
  String? get reason => null;
}

final class GattStartFailed extends GattStartResult {
  final String code; // 'BT_DISABLED' | 'PERMISSION_DENIED' | 'GATT_SERVER_FAILED'
  final String message;
  const GattStartFailed({required this.code, required this.message});
  @override
  bool get success => false;
  @override
  bool get isUserActionable => code == 'BT_DISABLED' || code == 'PERMISSION_DENIED';
  @override
  String? get reason => message.isNotEmpty ? message : code;
}

// ── Event types ───────────────────────────────────────────────────────────────

sealed class GattServerEvent {}

final class ClientConnected extends GattServerEvent {
  final String deviceAddress;
  ClientConnected(this.deviceAddress);
}

final class ClientDisconnected extends GattServerEvent {
  final String deviceAddress;
  ClientDisconnected(this.deviceAddress);
}

final class MtuChanged extends GattServerEvent {
  final int mtu;
  MtuChanged(this.mtu);
  // Anything below 100 bytes means every ~80-byte Phantom packet splits into
  // multiple ATT writes, destroying latency. Most modern chipsets reach 185–517.
  bool get isSane => mtu >= 100;
}

final class AdvertiseFailed extends GattServerEvent {
  final int errorCode;
  AdvertiseFailed(this.errorCode);
  String get label => switch (errorCode) {
        1 => 'data_too_large',
        2 => 'too_many_advertisers',
        3 => 'already_started',
        4 => 'internal_error',
        5 => 'feature_unsupported',
        _ => 'error_$errorCode',
      };
}

// ── Channel wrapper ───────────────────────────────────────────────────────────

class GattServerChannel {
  static const _ch = MethodChannel('phantom/gatt_server');

  final _rxController = StreamController<Uint8List>.broadcast();
  final _eventsController = StreamController<GattServerEvent>.broadcast();

  bool _disposed = false;

  /// Raw bytes written by remote GATT clients to our characteristic.
  Stream<Uint8List> get received => _rxController.stream;

  /// Lifecycle events: connections, MTU negotiation, advertising failures.
  Stream<GattServerEvent> get events => _eventsController.stream;

  GattServerChannel() {
    _ch.setMethodCallHandler((call) async {
      if (_disposed) return;
      switch (call.method) {
        // ByteArray on Android → Uint8List via StandardMethodCodec
        case 'onWrite':
          _rxController.add(call.arguments as Uint8List);
        case 'onClientConnected':
          _eventsController.add(ClientConnected(call.arguments as String));
        case 'onClientDisconnected':
          _eventsController.add(ClientDisconnected(call.arguments as String));
        case 'onMtuChanged':
          _eventsController.add(MtuChanged(call.arguments as int));
        case 'onAdvertiseFailed':
          _eventsController.add(AdvertiseFailed(call.arguments as int));
      }
    });
  }

  /// Start the GATT server and begin advertising.
  ///
  /// [msdPayload] must be the 8-byte output of [MeshAdvertisement.toAdvPayload()].
  /// Returns [GattStartFailed] if BT is off or permissions are missing.
  Future<GattStartResult> start(Uint8List msdPayload) async {
    try {
      await _ch.invokeMethod<void>('start', msdPayload);
      return const GattStartOk();
    } on PlatformException catch (e) {
      return GattStartFailed(code: e.code, message: e.message ?? '');
    }
  }

  /// Stop the GATT server and advertising.
  Future<void> stop() async {
    await _ch.invokeMethod<void>('stop');
  }

  /// Notify all GATT clients currently connected to our server.
  /// Returns the number of clients that received the notification.
  Future<int> notifyAll(Uint8List data) async {
    return await _ch.invokeMethod<int>('notifyAll', data) ?? 0;
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    // Drain any pending callbacks that Kotlin posted before stop() returned.
    await Future<void>.delayed(Duration.zero);
    await _rxController.close();
    await _eventsController.close();
  }
}

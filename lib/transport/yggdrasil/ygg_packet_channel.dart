import 'package:flutter/services.dart';

/// Moves raw IPv6 packets between the Dart transport and the native in-process
/// Yggdrasil router (its `Send`/`Recv`). This replaces the OS TUN: instead of
/// the kernel routing our sockets through a VpnService, we hand the router the
/// exact IPv6 packets ourselves. See [YggIp6] for the packet format.
abstract class YggPacketChannel {
  /// Push a fully-formed IPv6 packet into the router (→ `Yggdrasil.Send`).
  Future<void> send(Uint8List ipv6Packet);

  /// Fully-formed IPv6 packets coming out of the router (`Yggdrasil.Recv`),
  /// each already addressed to us with its source anti-spoof-verified.
  Stream<Uint8List> get incoming;

  Future<void> dispose();
}

/// Production channel: `send` over a MethodChannel, `incoming` over an
/// EventChannel that the native YggdrasilService feeds from its Recv pump.
class PlatformYggPacketChannel implements YggPacketChannel {
  static const MethodChannel _method =
      MethodChannel('phantom/yggdrasil_io');
  static const EventChannel _events =
      EventChannel('phantom/yggdrasil_io/incoming');

  Stream<Uint8List>? _incoming;

  @override
  Future<void> send(Uint8List ipv6Packet) async {
    // StandardMethodCodec encodes Uint8List as a byte array → Kotlin ByteArray.
    await _method.invokeMethod<void>('send', ipv6Packet);
  }

  @override
  Stream<Uint8List> get incoming => _incoming ??= _events
      .receiveBroadcastStream()
      .map<Uint8List>((e) => e is Uint8List
          ? e
          : Uint8List.fromList(List<int>.from(e as List)));

  @override
  Future<void> dispose() async {}
}

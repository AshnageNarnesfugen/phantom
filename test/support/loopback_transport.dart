import 'dart:async';
import 'dart:typed_data';

import 'package:phantom_messenger/phantom_messenger.dart';

/// In-memory "network": routes published envelopes to the recipient's inbox
/// inside the same process. Lets the lab run several PhantomCore identities
/// against each other with zero daemons, zero sockets and zero latency, so
/// the full X3DH handshake + double-ratchet messaging flow can be debugged
/// on the dev machine instead of by installing APKs on physical devices.
class LoopbackHub {
  final Map<String, StreamController<IncomingEnvelope>> _inboxes = {};

  /// Flip to false to simulate total network loss: publishes throw, exactly
  /// like a real transport whose daemon died.
  bool online = true;

  /// Extra delivery latency, to surface ordering races that a 0ms in-memory
  /// hop would hide.
  Duration latency = Duration.zero;

  /// Every frame that crossed the hub, in order — lets tests assert on wire
  /// traffic (how many frames a handshake produced, payload sizes, …).
  final List<({String recipientId, Uint8List bytes})> trace = [];

  StreamController<IncomingEnvelope> _inbox(String id) => _inboxes.putIfAbsent(
      id, () => StreamController<IncomingEnvelope>.broadcast());

  Stream<IncomingEnvelope> streamFor(String ourId) => _inbox(ourId).stream;

  Future<void> deliver({
    required String recipientId,
    required Uint8List bytes,
  }) async {
    if (!online) {
      throw const TransportException('loopback hub is offline');
    }
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    trace.add((recipientId: recipientId, bytes: Uint8List.fromList(bytes)));
    _inbox(recipientId).add(IncomingEnvelope(
      data: Uint8List.fromList(bytes),
      transportName: 'loopback',
      receivedAt: DateTime.now(),
    ));
  }

  /// Re-injects a previously traced frame — simulates a duplicate delivery
  /// (e.g. the same message arriving via Waku live AND Waku store).
  void replay(int traceIndex) {
    final f = trace[traceIndex];
    _inbox(f.recipientId).add(IncomingEnvelope(
      data: Uint8List.fromList(f.bytes),
      transportName: 'loopback-replay',
      receivedAt: DateTime.now(),
    ));
  }

  Future<void> dispose() async {
    for (final c in _inboxes.values) {
      await c.close();
    }
  }
}

class LoopbackTransport implements PhantomTransport {
  final LoopbackHub hub;
  LoopbackTransport(this.hub);

  @override
  String get name => 'loopback';

  @override
  bool get isAvailable => hub.online;

  @override
  Future<bool> checkAvailability() async => hub.online;

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) =>
      hub.deliver(recipientId: recipientId, bytes: encryptedEnvelope);

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) =>
      hub.streamFor(ourId);

  @override
  Future<void> dispose() async {}
}

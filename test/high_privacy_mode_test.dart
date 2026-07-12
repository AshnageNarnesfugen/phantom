import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/transport.dart';

/// High-privacy mode routes the control plane (key exchange) over I2P ONLY, so
/// session setup never reveals the user's IP to the Waku fleet / IPFS peers.
/// The critical invariant is a SAFETY property: in this mode a control frame
/// must NEVER go out over a non-I2P transport — a silent fallback would leak
/// exactly what the mode exists to hide. These tests pin that (and that normal
/// data traffic is unaffected) without any real I2P/SAM.
class _RecordingTransport implements PhantomTransport {
  final List<Uint8List> sent = [];
  final _in = StreamController<IncomingEnvelope>.broadcast();

  @override
  String get name => 'rec-loopback';
  @override
  bool get isAvailable => true;
  @override
  Future<bool> checkAvailability() async => true;
  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) => _in.stream;

  @override
  Future<void> publish(
      {required String recipientId, required Uint8List encryptedEnvelope}) async {
    sent.add(encryptedEnvelope);
  }

  @override
  Future<void> dispose() async {
    if (!_in.isClosed) await _in.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bob = 'bobLongEnoughId';
  Uint8List payload() => Uint8List.fromList([1, 2, 3, 4]);

  late _RecordingTransport rec;
  late TransportManager mgr;

  Future<void> boot({required bool highPrivacy}) async {
    rec = _RecordingTransport();
    mgr = TransportManager(transportsOverride: [rec])
      ..highPrivacyMode = highPrivacy;
    await mgr.initialize(ourId: 'highPrivacyTestSelf');
  }

  tearDown(() async {
    await mgr.dispose();
  });

  test('high-privacy: a control frame is NEVER sent over a non-I2P transport '
      '(no leak) — it fails instead', () async {
    await boot(highPrivacy: true);
    await expectLater(
      mgr.publish(
          recipientId: bob,
          encryptedEnvelope: payload(),
          priority: TransportPriority.control),
      throwsA(isA<TransportException>()),
      reason: 'with no I2P path, the control frame must fail — not fall back',
    );
    expect(rec.sent, isEmpty,
        reason: 'the IP-revealing transport must never carry a control frame '
            'in high-privacy mode');
  });

  test('high-privacy: DATA frames are unaffected (normal stack)', () async {
    await boot(highPrivacy: true);
    await mgr.publish(
        recipientId: bob,
        encryptedEnvelope: payload(),
        priority: TransportPriority.data);
    expect(rec.sent, hasLength(1),
        reason: 'only the control plane is restricted to I2P; data flows normally');
  });

  test('normal mode: a control frame fans out over available transports',
      () async {
    await boot(highPrivacy: false);
    await mgr.publish(
        recipientId: bob,
        encryptedEnvelope: payload(),
        priority: TransportPriority.control);
    expect(rec.sent, hasLength(1),
        reason: 'with high-privacy off the control plane uses the full stack');
  });

  test('secret: a secret frame is I2P-only even with global privacy OFF — '
      'never leaks over another transport', () async {
    await boot(highPrivacy: false); // global mode off; secret is per-message
    await expectLater(
      mgr.publish(
          recipientId: bob,
          encryptedEnvelope: payload(),
          priority: TransportPriority.data,
          secret: true),
      throwsA(isA<TransportException>()),
      reason: 'no I2P path → a secret frame must fail, not fall back',
    );
    expect(rec.sent, isEmpty,
        reason: 'a secret-chat frame must never ride a non-I2P transport');
  });
}

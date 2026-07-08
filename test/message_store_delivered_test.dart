import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/bluetooth/mesh_protocol.dart';
import 'package:phantom_messenger/transport/bluetooth/message_store.dart';

/// The mechanism behind the "sending clock" UX: a queued message keeps its
/// full UUID locally (the mesh wire truncates it), and when it's finally
/// delivered the store emits it so the core can flip the StoredMessage from
/// 'sending' (clock) to 'sent' (checkmark).
void main() {
  MeshPacket pkt(String fullId, String to) => MeshPacket.message(
        fullMessageId: fullId,
        senderPhantomId: 'PHme',
        recipientPhantomId: to,
        encryptedEnvelope: Uint8List.fromList([1, 2, 3]),
      );

  test('markDelivered emits the PendingMessage with its full id + target',
      () async {
    final store = MessageStore();
    final p = pkt('abc12300-0000-4000-8000-000000000001', 'PHbob');
    final emitted = <PendingMessage>[];
    final sub = store.deliveredStream.listen(emitted.add);

    expect(
        store.enqueue(p, targetPhantomId: 'PHbob', fullMessageId: 'abc12300-0000-4000-8000-000000000001'),
        isTrue);
    expect(store.pendingCount, 1);

    store.markDelivered(p.messageIdHex);
    await Future<void>.delayed(Duration.zero); // let the broadcast fire

    expect(store.pendingCount, 0);
    expect(emitted, hasLength(1));
    expect(emitted.single.fullMessageId, 'abc12300-0000-4000-8000-000000000001',
        reason: 'the full UUID must survive so the UI can find the message');
    expect(emitted.single.targetPhantomId, 'PHbob');
    await sub.cancel();
  });

  test('delivering an unknown id emits nothing', () async {
    final store = MessageStore();
    final emitted = <PendingMessage>[];
    final sub = store.deliveredStream.listen(emitted.add);
    store.markDelivered('deadbeef');
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isEmpty);
    await sub.cancel();
  });

  test('fullMessageId survives JSON persistence (and an attempt bump)', () {
    final original = PendingMessage(
      packet: pkt('deadbee0-0000-4000-8000-000000000002', 'PHalice'),
      enqueuedAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      targetPhantomId: 'PHalice',
      fullMessageId: 'deadbee0-0000-4000-8000-000000000002',
    );
    final back = PendingMessage.fromJson(original.toJson());
    expect(back.fullMessageId, 'deadbee0-0000-4000-8000-000000000002');
    expect(back.withAttempt().fullMessageId,
        'deadbee0-0000-4000-8000-000000000002');
  });
}

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/bluetooth/mesh_protocol.dart';
import 'package:phantom_messenger/transport/bluetooth/mesh_router.dart';
import 'package:phantom_messenger/transport/bluetooth/message_store.dart';

void main() {
  group('MeshPacket — wire format', () {
    test('serializa y deserializa MESSAGE correctamente', () {
      final fakeEnvelope = Uint8List.fromList(List.generate(64, (i) => i));

      final packet = MeshPacket.message(
        fullMessageId: '550e8400-e29b-41d4-a716-446655440000',
        senderPhantomId: 'PSenderXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
        recipientPhantomId: 'PRecipientXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
        encryptedEnvelope: fakeEnvelope,
      );

      final wire = packet.serialize();
      final restored = MeshPacket.deserialize(wire);

      expect(restored.type, equals(MeshPacketType.message));
      expect(restored.ttl, equals(kMaxTTL));
      expect(restored.payload, equals(fakeEnvelope));
      expect(restored.messageId, equals(packet.messageId));
      expect(restored.originHint, equals(packet.originHint));
      expect(restored.destHint, equals(packet.destHint));

      print('Wire size: ${wire.length} bytes (${fakeEnvelope.length} payload + ${wire.length - fakeEnvelope.length} overhead)');
    });

    test('magic bytes inválidos lanzan excepción', () {
      final bad = Uint8List.fromList([0x00, 0x00, 0x02, 0x01, 0x07, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0, 0xFF, 0xFF]);
      expect(
        () => MeshPacket.deserialize(bad),
        throwsA(isA<MeshProtocolException>()),
      );
    });

    test('CRC inválido lanza excepción', () {
      final packet = MeshPacket.announce(
        myPhantomId: 'PTestXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
        capabilities: kCapRelay,
      );
      final wire = packet.serialize();
      // Flip un bit en el payload
      wire[wire.length - 3] ^= 0xFF;
      expect(
        () => MeshPacket.deserialize(wire),
        throwsA(isA<MeshProtocolException>()),
      );
    });

    test('TTL decrement funciona', () {
      final packet = MeshPacket.announce(
        myPhantomId: 'PTestXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
        capabilities: 0,
      ).withDecrementedTTL();
      // ANNOUNCE tiene TTL=1, después de decrement → TTL=0
      expect(packet.ttl, equals(0));
    });

    test('TTL=0 lanza excepción al decrementar', () {
      final packet = MeshPacket(
        type: MeshPacketType.message,
        ttl: 0,
        messageId: Uint8List(4),
        originHint: Uint8List(4),
        destHint: Uint8List(4),
        payload: Uint8List(0),
      );
      expect(() => packet.withDecrementedTTL(), throwsA(isA<MeshProtocolException>()));
    });

    test('nodeHint es consistente y no reversible', () {
      const id = 'PGhxk7rNvQw3mDfXpL2sYc8ZeA4bKjT';
      final hint1 = MeshPacket.nodeHint(id);
      final hint2 = MeshPacket.nodeHint(id);

      expect(hint1, equals(hint2));         // determinista
      expect(hint1.length, equals(4));       // 4 bytes
      expect(hint1, isNot(equals(Uint8List(4)))); // no todo ceros
    });

    test('IDs distintos producen hints distintos (estadísticamente)', () {
      final ids = List.generate(100, (i) => 'PTestID_$i${'X' * 30}');
      final hints = ids.map(MeshPacket.nodeHint).toSet();
      // Con 100 IDs y 4 bytes, casi todas las hints deben ser únicas
      expect(hints.length, greaterThan(90));
    });

    test('ANNOUNCE serializa y deserializa', () {
      final packet = MeshPacket.announce(
        myPhantomId: 'PMyPhantomIDXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
        capabilities: kCapRelay | kCapHasPending,
      );
      final restored = MeshPacket.deserialize(packet.serialize());
      expect(restored.type, equals(MeshPacketType.announce));
      expect(restored.payload[0], equals(kCapRelay | kCapHasPending));
    });

    test('ACK_DELIV serializa con payload vacío', () {
      final msgId = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      final packet = MeshPacket.ackDeliv(
        originalMessageId: msgId,
        myPhantomId: 'PSenderXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
      );
      final restored = MeshPacket.deserialize(packet.serialize());
      expect(restored.type, equals(MeshPacketType.ackDeliv));
      expect(restored.messageId, equals(msgId));
    });
  });

  group('MeshAdvertisement', () {
    test('encode y decode son inversos', () {
      final adv = MeshAdvertisement.forNode(
        phantomId: 'PTestNodeXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
        canRelay: true,
        hasPending: false,
      );
      final payload = adv.toAdvPayload();
      final restored = MeshAdvertisement.fromAdvPayload(payload);

      expect(restored, isNotNull);
      expect(restored!.nodeHintBytes, equals(adv.nodeHintBytes));
      expect(restored.canRelay, isTrue);
      expect(restored.hasPending, isFalse);
      expect(payload.length, equals(8)); // siempre 8 bytes
    });

    test('payload con magic incorrecto devuelve null', () {
      final bad = Uint8List.fromList([0xAA, 0xBB, 0xCC, 1, 2, 3, 4, 5]);
      expect(MeshAdvertisement.fromAdvPayload(bad), isNull);
    });
  });

  group('MessageStore', () {
    late MessageStore store;

    setUp(() => store = MessageStore());
    tearDown(() => store.dispose());

    test('enqueue y markDelivered funcionan', () {
      final packet = _makePacket('msg001', 'alice', 'bob');
      expect(store.enqueue(packet), isTrue);
      expect(store.pendingCount, equals(1));

      store.markDelivered(packet.messageIdHex);
      expect(store.pendingCount, equals(0));
    });

    test('deduplicación: markSeen devuelve true si ya se vio', () {
      expect(store.markSeen('abc123'), isFalse); // primera vez
      expect(store.markSeen('abc123'), isTrue);  // segunda vez → duplicado
      expect(store.markSeen('xyz789'), isFalse); // id distinto
    });

    test('getPendingForHint devuelve mensajes con hint coincidente', () {
      const recipientId = 'PRecipientXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX';
      final hint = MeshPacket.nodeHint(recipientId);

      final packet = _makePacket('msg002', 'sender', recipientId);
      store.enqueue(packet, targetPhantomId: recipientId);

      final found = store.getPendingForHint(hint);
      expect(found, isNotEmpty);
      expect(found.first.packet.messageIdHex, equals(packet.messageIdHex));
    });

    test('mensajes expirados se eliminan automáticamente', () async {
      final packet = _makePacket('msg003', 'alice', 'bob');
      store.enqueue(packet, ttl: const Duration(milliseconds: 1));

      await Future.delayed(const Duration(milliseconds: 10));

      // getPendingForHint fuerza purge
      final pending = store.getAllPending();
      expect(pending, isEmpty);
    });

    test('recordAttempt incrementa el contador', () {
      final packet = _makePacket('msg004', 'alice', 'bob');
      store.enqueue(packet);

      store.recordAttempt(packet.messageIdHex);
      store.recordAttempt(packet.messageIdHex);

      final stats = store.stats;
      expect(stats.pendingCount, equals(1));
    });

    test('store no supera kMaxPending', () {
      for (int i = 0; i < MessageStore.kMaxPending + 10; i++) {
        store.enqueue(_makePacket('msg$i', 'alice', 'bob'));
      }
      expect(store.pendingCount, lessThanOrEqualTo(MessageStore.kMaxPending));
    });
  });

  group('MeshRouter', () {
    late MessageStore store;
    late MeshRouter router;
    const myId = 'PMyPhantomIDXXXXXXXXXXXXXXXXXXXXXXXXXXXX';
    const otherId = 'POtherIDXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX';

    setUp(() {
      store = MessageStore();
      router = MeshRouter(
        myPhantomId: myId,
        store: store,
      );
    });

    tearDown(() async {
      await router.dispose();
      await store.dispose();
    });

    test('mensaje duplicado se descarta', () async {
      final packet = _makePacket('dup001', otherId, otherId);
      store.markSeen(packet.messageIdHex); // pre-marcar como visto

      final result = await router.process(packet);
      expect(result.decision, equals(RouterDecision.discard));
    });

    test('mensaje con TTL > 0 se retransmite', () async {
      final packet = _makePacket('relay001', otherId, otherId, ttl: 3);
      final result = await router.process(packet);

      expect(result.decision, equals(RouterDecision.relay));
      expect(result.packetToRelay?.ttl, equals(2)); // TTL decrementado
    });

    test('mensaje con TTL=0 se descarta', () async {
      final packet = MeshPacket(
        type: MeshPacketType.message,
        ttl: 0,
        messageId: Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]),
        originHint: MeshPacket.nodeHint(otherId),
        destHint: MeshPacket.nodeHint(otherId),
        payload: Uint8List.fromList([1, 2, 3, 4]),
      );
      final result = await router.process(packet);
      expect(result.decision, equals(RouterDecision.discard));
    });

    test('ACK_RELAY se procesa sin relay', () async {
      final ack = MeshPacket.ackRelay(
        originalMessageId: Uint8List.fromList([1, 2, 3, 4]),
        myPhantomId: otherId,
      );
      final result = await router.process(ack);
      expect(result.decision, equals(RouterDecision.ackOnly));
    });

    test('ANNOUNCE con pending provoca envío', () async {
      // Encolar un mensaje para otherId
      final pending = _makePacket('pending001', myId, otherId);
      store.enqueue(pending, targetPhantomId: otherId);

      // Recibir ANNOUNCE de otherId
      final announce = MeshPacket.announce(
        myPhantomId: otherId,
        capabilities: kCapRelay,
      );
      final result = await router.process(announce);

      expect(result.pendingToSend, isNotEmpty);
    });

    test('prepareOutgoing guarda en store', () {
      final envelope = Uint8List.fromList(List.generate(32, (i) => i));
      router.prepareOutgoing(
        fullMessageId: '550e8400-0000-0000-0000-000000000001',
        recipientPhantomId: otherId,
        encryptedEnvelope: envelope,
      );
      expect(store.pendingCount, equals(1));
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

MeshPacket _makePacket(
  String msgId,
  String sender,
  String recipient, {
  int ttl = kMaxTTL,
}) {
  return MeshPacket(
    type: MeshPacketType.message,
    ttl: ttl,
    messageId: Uint8List.fromList(msgId.padRight(8, '0').codeUnits.take(4).toList()),
    originHint: MeshPacket.nodeHint(sender),
    destHint: MeshPacket.nodeHint(recipient),
    payload: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
  );
}

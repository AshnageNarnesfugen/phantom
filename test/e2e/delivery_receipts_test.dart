@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/phantom_messenger.dart';

import '../support/loopback_transport.dart';

/// Entrega confirmada de punta a punta, sobre el lab loopback.
///
/// Reproduce el fallo de campo del 2026-10-26 entre el Nothing y el Thor: el
/// primer mensaje ("hola thor 1") salió como INIT, I2P dijo "delivery OK"
/// (el SAM local aceptó el UDP), IPFS dijo "published OK" (a un tópico sin
/// peers) y Waku falló la confirmación del store. El mensaje quedó con ✓ y
/// jamás llegó: nadie lo reintentó porque nada distinguía "salió del
/// teléfono" de "llegó al otro". `hub.dropIf` modela exactamente esa pérdida
/// silenciosa.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LoopbackHub hub;
  late Directory aliceDir;
  late Directory bobDir;
  late PhantomCore alice;
  late PhantomCore bob;

  final defaultDeliveryBase = PhantomCore.deliveryRetryBase;
  final defaultHandshakeBase = PhantomCore.handshakeRetryBase;

  Future<StoredMessage> nextText(PhantomCore core,
      {Duration timeout = const Duration(seconds: 20)}) {
    return core.incomingMessages
        .firstWhere((m) => m.type == MessageType.text)
        .timeout(timeout);
  }

  Future<MessageStatus?> statusOf(
      PhantomCore core, String convId, String id) async {
    final msgs = await core.storage.getMessages(convId, limit: 100);
    return msgs.where((m) => m.id == id).firstOrNull?.status;
  }

  Future<void> waitFor(Future<bool> Function() cond,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!await cond()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condición no cumplida en ${timeout.inSeconds}s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  setUp(() async {
    PhantomCore.deliveryRetryBase = const Duration(milliseconds: 400);
    PhantomCore.handshakeRetryBase = const Duration(milliseconds: 600);
    hub      = LoopbackHub();
    aliceDir = await Directory.systemTemp.createTemp('phantom_dlv_alice_');
    bobDir   = await Directory.systemTemp.createTemp('phantom_dlv_bob_');
    alice = (await PhantomCore.createAccount(
      storagePath:    aliceDir.path,
      storage:        PhantomStorage.isolated(),
      transports:     [LoopbackTransport(hub)],
      enablePresence: false,
      enableBleMesh:  false,
    )).core;
    bob = (await PhantomCore.createAccount(
      storagePath:    bobDir.path,
      storage:        PhantomStorage.isolated(),
      transports:     [LoopbackTransport(hub)],
      enablePresence: false,
      enableBleMesh:  false,
    )).core;
    await alice.addContact(contactAddress: (await bob.getMyContactAddress())!);
  });

  tearDown(() async {
    PhantomCore.deliveryRetryBase = defaultDeliveryBase;
    PhantomCore.handshakeRetryBase = defaultHandshakeBase;
    await alice.dispose();
    await bob.dispose();
    await hub.dispose();
    try { await aliceDir.delete(recursive: true); } catch (_) {}
    try { await bobDir.delete(recursive: true); } catch (_) {}
  });

  test('el receptor acusa entrega: el mensaje pasa a delivered (✓✓)',
      () async {
    final got = nextText(bob);
    final sent = await alice.sendMessage(recipientId: bob.myId, text: 'hola');
    await got;
    await waitFor(() async =>
        await statusOf(alice, bob.myId, sent.id) == MessageStatus.delivered);
  });

  test('un transporte lento que termina después del acuse no baja ✓✓ a ✓',
      () async {
    // Campo, 2026-10-26: el acuse volvió en 3 s por I2P mientras Waku seguía
    // reintentando su confirmación ~30 s; al terminar, el envío escribía
    // "sent" encima de "delivered".
    final warm = nextText(bob);
    await alice.sendMessage(recipientId: bob.myId, text: 'calentar');
    await warm;
    hub.returnDelay =
        (to) => to == bob.myId ? const Duration(seconds: 2) : null;
    final sending = alice.sendMessage(recipientId: bob.myId, text: 'lento');
    final got = await nextText(bob);
    await waitFor(() async =>
        await statusOf(alice, bob.myId, got.id) == MessageStatus.delivered);
    await sending;
    hub.returnDelay = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await statusOf(alice, bob.myId, got.id), MessageStatus.delivered);
  });

  test('el primer mensaje (INIT) perdido en la red se reenvía y llega',
      () async {
    // Se traga el PRIMER frame hacia Bob — el INIT que lleva el texto. Lo
    // que viene detrás (connectivityInfo, también INIT con el mismo EK)
    // pasa, así que Bob arma la sesión y responde con el ack: el handshake
    // "funciona" y aun así el texto se habría perdido para siempre.
    var swallowed = false;
    hub.dropIf = (to, _) {
      if (to != bob.myId || swallowed) return false;
      swallowed = true;
      return true;
    };
    final got = nextText(bob);
    final sent =
        await alice.sendMessage(recipientId: bob.myId, text: 'hola thor 1');
    expect(hub.dropped, 1);
    expect((await got).textContent, 'hola thor 1');
    await waitFor(() async =>
        await statusOf(alice, bob.myId, sent.id) == MessageStatus.delivered);
  });

  test('un mensaje perdido a mitad de conversación se reenvía', () async {
    final warm = nextText(bob);
    await alice.sendMessage(recipientId: bob.myId, text: 'uno');
    await warm;
    final back = nextText(alice);
    await bob.sendMessage(recipientId: alice.myId, text: 'dos');
    await back;

    var swallowed = false;
    hub.dropIf = (to, _) {
      if (to != bob.myId || swallowed) return false;
      swallowed = true;
      return true;
    };
    final got = nextText(bob);
    await alice.sendMessage(recipientId: bob.myId, text: 'tres');
    expect((await got).textContent, 'tres');
  });

  test('un reenvío de algo que ya llegó no duplica ni re-notifica', () async {
    // Bob recibe, pero su acuse de entrega se pierde: Alice reenvía.
    hub.dropIf = (to, bytes) => to == alice.myId;
    final texts = <String>[];
    final sub = bob.incomingMessages
        .where((m) => m.type == MessageType.text)
        .listen((m) => texts.add(m.textContent));
    final sent = await alice.sendMessage(recipientId: bob.myId, text: 'único');
    // Al menos un reenvío completo cruza mientras los acuses no vuelven.
    await Future<void>.delayed(const Duration(seconds: 3));
    hub.dropIf = null;
    await waitFor(() async =>
        await statusOf(alice, bob.myId, sent.id) == MessageStatus.delivered);
    await sub.cancel();
    expect(texts, ['único'], reason: 'el reenvío no debe duplicar: $texts');
    final stored = await bob.storage.getMessages(alice.myId, limit: 100);
    expect(stored.where((m) => m.id == sent.id), hasLength(1));
  });

  test('las OPK que anuncia el peer se guardan (el pool remoto no queda vacío)',
      () async {
    // getRemoteOpks devolvía `const []` sin datos previos y addRemoteOpk
    // hacía removeWhere encima: cada preKeyShare tronaba, el caché jamás
    // guardó una sola OPK y todo handshake caía a X3DH sin OPK.
    final got = nextText(bob);
    await alice.sendMessage(recipientId: bob.myId, text: 'hola');
    await got;
    await waitFor(() async =>
        (await alice.storage.getRemoteOpks(bob.myId)).isNotEmpty);
  });

  test('un ack de handshake perdido se vuelve a pedir y se re-acusa',
      () async {
    // Todo lo que Bob manda se pierde mientras Alice está esperando: el ack
    // original nunca llega. Antes Bob descifraba los reintentos de Alice
    // (INIT con EK conocido) en silencio y Alice esperaba para siempre.
    //
    // El handshake lo abre un mensaje de sistema (no rastreado por el outbox
    // de entrega), así que lo único que puede destrabar a Alice es que Bob
    // conteste a esos reintentos.
    hub.dropIf = (to, _) => to == alice.myId;
    await alice.sendReadReceipts(bob.myId, ['nada']);
    await waitFor(() async => await bob.storage.getContact(alice.myId) != null);
    // Que se pierda también la ráfaga post-handshake de Bob (ack,
    // connectivityInfo, preKeyShares): cualquiera de esos frames destrabaría
    // a Alice por accidente.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(alice.isAwaitingHandshakeAck(bob.myId), isTrue);

    hub.dropIf = null;
    await waitFor(() async => !alice.isAwaitingHandshakeAck(bob.myId));
  });
}

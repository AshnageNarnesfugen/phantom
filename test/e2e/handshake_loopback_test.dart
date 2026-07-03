@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/phantom_messenger.dart';

import '../support/loopback_transport.dart';

/// E2E del protocolo completo SIN red ni daemons: dos PhantomCore reales
/// (Alice y Bob) en el mismo proceso, conectados por un transporte loopback
/// en memoria. Ejercita exactamente el mismo código que corre en los
/// teléfonos — X3DH híbrido (X25519+Kyber768), INIT wrapping, double
/// ratchet, handshakeAck, preKeyShare, persistencia Hive — de forma
/// determinista y en segundos. Es la herramienta para depurar handshake y
/// mensajería sin instalar APKs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LoopbackHub hub;
  late Directory aliceDir;
  late Directory bobDir;
  late PhantomCore alice;
  late PhantomCore bob;

  /// Espera el próximo mensaje de chat visible (no system) que reciba [core].
  Future<StoredMessage> nextMessage(PhantomCore core,
      {Duration timeout = const Duration(seconds: 20)}) {
    return core.incomingMessages
        .firstWhere((m) =>
            m.type == MessageType.text ||
            m.type == MessageType.image ||
            m.type == MessageType.file)
        .timeout(timeout);
  }

  setUp(() async {
    hub      = LoopbackHub();
    aliceDir = await Directory.systemTemp.createTemp('phantom_lab_alice_');
    bobDir   = await Directory.systemTemp.createTemp('phantom_lab_bob_');

    final a = await PhantomCore.createAccount(
      storagePath:    aliceDir.path,
      storage:        PhantomStorage.isolated(),
      transports:     [LoopbackTransport(hub)],
      enablePresence: false,
      enableBleMesh:  false,
    );
    alice = a.core;

    final b = await PhantomCore.createAccount(
      storagePath:    bobDir.path,
      storage:        PhantomStorage.isolated(),
      transports:     [LoopbackTransport(hub)],
      enablePresence: false,
      enableBleMesh:  false,
    );
    bob = b.core;
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    await hub.dispose();
    try { await aliceDir.delete(recursive: true); } catch (_) {}
    try { await bobDir.delete(recursive: true); } catch (_) {}
  });

  test('handshake X3DH + mensajería bidireccional', () async {
    // Alice importa la dirección de contacto de Bob (equivale a escanear
    // su QR) — Bob NO conoce a Alice todavía.
    final bobAddress = await bob.getMyContactAddress();
    expect(bobAddress, isNotNull);
    await alice.addContact(contactAddress: bobAddress!, nickname: 'Bob');

    // 1) Primer mensaje: PhantomCore lo envuelve como INIT X3DH (híbrido
    //    Kyber si el bundle lo permite) con la CA de Alice embebida.
    final bobGets = nextMessage(bob);
    await alice.sendMessage(recipientId: bob.myId, text: 'hola bob — INIT');
    final first = await bobGets;
    expect(first.textContent, 'hola bob — INIT');
    expect(first.conversationId, alice.myId);

    // El INIT llevaba la ContactAddress de Alice: Bob debe haberla
    // persistido como contacto sin intervención manual.
    final aliceAsSeenByBob = await bob.storage.getContact(alice.myId);
    expect(aliceAsSeenByBob, isNotNull,
        reason: 'el INIT debe auto-registrar al remitente como contacto');

    // 2) Respuesta de Bob → camino responder del ratchet.
    final aliceGets = nextMessage(alice);
    await bob.sendMessage(recipientId: alice.myId, text: 'hola alice');
    expect((await aliceGets).textContent, 'hola alice');

    // 3) Varias idas y vueltas: avanza cadenas del double ratchet en ambas
    //    direcciones (detecta bugs de skipped keys / DH ratchet).
    for (var i = 0; i < 5; i++) {
      final b1 = nextMessage(bob);
      await alice.sendMessage(recipientId: bob.myId, text: 'a→b #$i');
      expect((await b1).textContent, 'a→b #$i');

      final a1 = nextMessage(alice);
      await bob.sendMessage(recipientId: alice.myId, text: 'b→a #$i');
      expect((await a1).textContent, 'b→a #$i');
    }

    // 4) Sesiones persistidas en ambos lados.
    expect(await alice.storage.getSessionState(bob.myId), isNotNull);
    expect(await bob.storage.getSessionState(alice.myId), isNotNull);
  });

  test('ráfaga bidireccional sin ping-pong (patrón post-handshake real)',
      () async {
    // Reproduce el patrón de campo que reseteaba sesiones sanas: tras el
    // INIT, ambos lados encolan MUCHOS envíos (preKeyShares, connectivity,
    // texto) mientras simultáneamente reciben frames del otro. Si el camino
    // de envío y el de recepción no comparten exclusión sobre la sesión,
    // los descifrados fallan en cascada y el auto-revive destruye la sesión.
    final bobAddress = await bob.getMyContactAddress();
    await alice.addContact(contactAddress: bobAddress!);

    final bobGot   = <String>[];
    final aliceGot = <String>[];
    final s1 = bob.incomingMessages
        .where((m) => m.type == MessageType.text)
        .listen((m) => bobGot.add(m.textContent));
    final s2 = alice.incomingMessages
        .where((m) => m.type == MessageType.text)
        .listen((m) => aliceGot.add(m.textContent));

    // Handshake por primer mensaje.
    await alice.sendMessage(recipientId: bob.myId, text: 'INIT');
    // Ráfaga cruzada: cada lado dispara 8 envíos SIN esperar al otro.
    final burst = <Future<void>>[];
    for (var i = 0; i < 8; i++) {
      burst.add(alice.sendMessage(recipientId: bob.myId, text: 'a→b #$i'));
      burst.add(bob.sendMessage(recipientId: alice.myId, text: 'b→a #$i'));
    }
    await Future.wait(burst);

    // Todo debe llegar (el orden puede variar, la pérdida no se tolera).
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while ((bobGot.length < 9 || aliceGot.length < 8) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await s1.cancel();
    await s2.cancel();

    expect(bobGot.toSet(),
        {'INIT', for (var i = 0; i < 8; i++) 'a→b #$i'},
        reason: 'Bob perdió mensajes de la ráfaga: $bobGot');
    expect(aliceGot.toSet(),
        {for (var i = 0; i < 8; i++) 'b→a #$i'},
        reason: 'Alice perdió mensajes de la ráfaga: $aliceGot');

    // Y las sesiones deben seguir vivas (sin auto-revive destructivo).
    expect(await alice.storage.getSessionState(bob.myId), isNotNull);
    expect(await bob.storage.getSessionState(alice.myId), isNotNull);
  });

  test('media pequeño viaja inline (sin IPFS) y llega íntegro', () async {
    final bobAddress = await bob.getMyContactAddress();
    await alice.addContact(contactAddress: bobAddress!);

    // Handshake por primer mensaje.
    final warm = nextMessage(bob);
    await alice.sendMessage(recipientId: bob.myId, text: 'hola');
    await warm;

    // Imagen de 30 KB — bajo el umbral inline: NO debe tocar IPFS (en este
    // lab no hay daemon, así que si lo tocara fallaría o quedaría pendiente
    // como "[image]"). El receptor debe obtener los bytes EXACTOS, listos
    // para renderizar, sin paso de resolución.
    final img = Uint8List.fromList(
        List<int>.generate(30 * 1024, (i) => (i * 31 + 7) & 0xff));
    final bobGets = bob.incomingMessages
        .firstWhere((m) => m.type == MessageType.image)
        .timeout(const Duration(seconds: 20));
    await alice.sendFile(
        recipientId: bob.myId, bytes: img, fileName: 'foto.png');
    final got = await bobGets;
    expect(got.content, img,
        reason: 'la imagen inline debe llegar byte a byte, sin CID');
    expect(PhantomCore.tryParseFileWireContent(got.content), isNull,
        reason: 'el contenido inline no debe parsear como puntero CID');

    // Archivo genérico (no imagen): display form name\0bytes.
    final doc = Uint8List.fromList(List<int>.generate(2048, (i) => i & 0xff));
    final bobGetsFile = bob.incomingMessages
        .firstWhere((m) => m.type == MessageType.file)
        .timeout(const Duration(seconds: 20));
    await alice.sendFile(
        recipientId: bob.myId, bytes: doc, fileName: 'notas.pdf');
    final gotFile = await bobGetsFile;
    expect(gotFile.content, PhantomCore.encodeFileDisplayContent('notas.pdf', doc));
  });

  test('frames duplicados no producen mensajes duplicados', () async {
    final bobAddress = await bob.getMyContactAddress();
    await alice.addContact(contactAddress: bobAddress!);

    final bobGets = nextMessage(bob);
    await alice.sendMessage(recipientId: bob.myId, text: 'mensaje único');
    await bobGets;

    // Reinyecta TODOS los frames que cruzaron el hub (como si llegaran otra
    // vez por Waku store después de recibirlos por relay). Ninguno debe
    // producir un nuevo evento de mensaje.
    final duplicates = <StoredMessage>[];
    final sub = bob.incomingMessages.listen(duplicates.add);
    for (var i = 0; i < hub.trace.length; i++) {
      hub.replay(i);
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await sub.cancel();
    expect(duplicates.where((m) => m.type == MessageType.text), isEmpty,
        reason: 'la dedupe de frames debe absorber réplicas del store');
  });

  test('mensajes en cola sobreviven a un corte total de red', () async {
    final bobAddress = await bob.getMyContactAddress();
    await alice.addContact(contactAddress: bobAddress!);

    // Con la "red" caída el envío no debe lanzar hacia la UI: el mensaje
    // queda almacenado local con estado failed/pending.
    hub.online = false;
    StoredMessage? result;
    Object? error;
    try {
      result = await alice.sendMessage(recipientId: bob.myId, text: 'offline');
    } catch (e) {
      error = e;
    }
    // Contrato mínimo: o devuelve el StoredMessage (marcado no-sent) o
    // lanza PhantomCoreException — pero nunca corrompe el estado para
    // envíos posteriores.
    if (result != null) {
      expect(result.status, isNot(MessageStatus.sent));
    } else {
      expect(error, isA<Object>());
    }

    // Al volver la red, un mensaje nuevo entrega con normalidad.
    hub.online = true;
    final bobGets = nextMessage(bob);
    await alice.sendMessage(recipientId: bob.myId, text: 'de vuelta');
    expect((await bobGets).textContent, 'de vuelta');
  });
}

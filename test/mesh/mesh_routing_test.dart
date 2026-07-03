@Timeout(Duration(minutes: 2))
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/bluetooth/mesh_protocol.dart';

import '../support/mesh_sim.dart';

// Distinct 40-char phantom-id-like strings whose 4-byte node hints differ
// (verified below so hint collisions don't confound delivery assertions).
const _alice = 'PAliceMeshIdAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _bob   = 'PBobMeshIdBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _carol = 'PCarolMeshIdCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const _dave  = 'PDaveMeshIdDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';

Uint8List _env(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  test('los node hints de los actores no colisionan (sanity)', () {
    final hints = [_alice, _bob, _carol, _dave]
        .map((id) => MeshPacket.nodeHint(id).join(','))
        .toSet();
    expect(hints.length, 4);
  });

  group('MeshSim — entrega multi-nodo', () {
    late MeshSim sim;
    setUp(() => sim = MeshSim());
    tearDown(() => sim.dispose());

    test('entrega directa A↔B', () async {
      sim.addNode(_alice);
      sim.addNode(_bob);
      await sim.connect(_alice, _bob);

      final msg = _env('hola bob');
      await sim.send(_alice, _bob, msg);

      expect(sim.node(_bob).timesReceived(msg), 1);
      // El emisor no se entrega a sí mismo.
      expect(sim.node(_alice).received, isEmpty);
    });

    test('multi-hop A→B→C (B solo relaya, A y C no se ven)', () async {
      sim.addNode(_alice);
      sim.addNode(_bob);
      sim.addNode(_carol);
      await sim.connect(_alice, _bob);
      await sim.connect(_bob, _carol);
      // A y C NO están conectados: el único camino es a través de B.

      final msg = _env('para carol via bob');
      await sim.send(_alice, _carol, msg);

      expect(sim.node(_carol).timesReceived(msg), 1,
          reason: 'C debe recibir el mensaje relayado por B');
      // B es solo relay: nunca entrega a su propia app.
      expect(sim.node(_bob).received, isEmpty,
          reason: 'B no es el destinatario — no debe entregar a su app');
    });

    test('dedup en diamante: A→{B,C}→D, D entrega UNA sola vez', () async {
      sim.addNode(_alice);
      sim.addNode(_bob);
      sim.addNode(_carol);
      sim.addNode(_dave);
      // Diamante: A conecta con B y C; ambos con D. Dos caminos hacia D.
      await sim.connect(_alice, _bob);
      await sim.connect(_alice, _carol);
      await sim.connect(_bob, _dave);
      await sim.connect(_carol, _dave);

      final msg = _env('mensaje diamante');
      await sim.send(_alice, _dave, msg);

      expect(sim.node(_dave).timesReceived(msg), 1,
          reason: 'llega por dos caminos pero la dedup debe entregar una vez');
    });

    test('horizonte de TTL: cadena más larga que kMaxTTL no llega', () async {
      // Cadena de kMaxTTL + 3 saltos. El mensaje nace con ttl=kMaxTTL y se
      // decrementa en cada relay; más allá de kMaxTTL saltos debe morir.
      final chain = <String>[];
      for (var i = 0; i < kMaxTTL + 3; i++) {
        final id = 'PChainNode${i.toString().padLeft(2, '0')}'
            'XXXXXXXXXXXXXXXXXXXXXXXXXXXX';
        chain.add(id);
        sim.addNode(id);
      }
      for (var i = 0; i < chain.length - 1; i++) {
        await sim.connect(chain[i], chain[i + 1]);
      }

      final msg = _env('demasiado lejos');
      await sim.send(chain.first, chain.last, msg);

      expect(sim.node(chain.last).received, isEmpty,
          reason: 'el destino está más allá del horizonte de TTL');
      // Un nodo dentro del horizonte (salto kMaxTTL exacto) sí lo ve pasar.
      expect(sim.trace.any((t) => t.to == chain[kMaxTTL]), isTrue);
    });

    test('store-and-forward: C aparece DESPUÉS de que A envió', () async {
      sim.addNode(_alice);
      sim.addNode(_bob);
      sim.addNode(_carol);
      await sim.connect(_alice, _bob);
      // C todavía no está en el mesh.

      final msg = _env('mensaje diferido');
      await sim.send(_alice, _carol, msg);
      expect(sim.node(_carol).received, isEmpty,
          reason: 'C aún no existe en el mesh');

      // C entra en rango de B; el ANNOUNCE debe drenar el store de B hacia C.
      await sim.connect(_bob, _carol);

      expect(sim.node(_carol).timesReceived(msg), 1,
          reason: 'B guardó el mensaje y lo entregó a C al aparecer');
    });

    test('ACK_DELIV: el store del emisor se vacía tras la entrega', () async {
      sim.addNode(_alice);
      sim.addNode(_bob);
      await sim.connect(_alice, _bob);

      await sim.send(_alice, _bob, _env('confirma esto'));

      expect(sim.node(_bob).received, hasLength(1));
      // Tras el ACK_DELIV que B propaga, A ya no debe retener el mensaje.
      expect(sim.node(_alice).store.pendingCount, 0,
          reason: 'el ACK_DELIV debe limpiar el pending del emisor');
    });

    test('payload tamaño-handshake (3699 B) atraviesa un relay con MTU chico',
        () async {
      // El bug real: sin reensamblaje, cualquier paquete > MTU se troceaba y
      // cada fragmento fallaba el deserialize → los handshakes por mesh eran
      // imposibles. chunkSize=185 simula un MTU BLE modesto.
      final s = MeshSim(chunkSize: 185);
      s.addNode(_alice);
      s.addNode(_bob);
      s.addNode(_carol);
      await s.connect(_alice, _bob);
      await s.connect(_bob, _carol);

      final init = Uint8List.fromList(
          List.generate(3699, (i) => (i * 37 + 11) & 0xff));
      await s.send(_alice, _carol, init);

      expect(s.node(_carol).timesReceived(init), 1,
          reason: 'un INIT de 3699 B debe reensamblarse tras el relay de B');
      await s.dispose();
    });

    test('reenvío del mismo mensaje no genera doble entrega', () async {
      sim.addNode(_alice);
      sim.addNode(_bob);
      await sim.connect(_alice, _bob);

      final msg = _env('idempotente');
      await sim.send(_alice, _bob, msg, messageId: 'aabbccdd-1111-2222-3333-444455556666');
      await sim.send(_alice, _bob, msg, messageId: 'aabbccdd-1111-2222-3333-444455556666');

      expect(sim.node(_bob).timesReceived(msg), 1,
          reason: 'mismo messageId ⇒ la dedup absorbe el reenvío');
    });

    test('un relay que no es el destinatario nunca entrega a su app', () async {
      // Cadena A→B→C→D; el mensaje es para D. B y C solo relayan.
      sim.addNode(_alice);
      sim.addNode(_bob);
      sim.addNode(_carol);
      sim.addNode(_dave);
      await sim.connect(_alice, _bob);
      await sim.connect(_bob, _carol);
      await sim.connect(_carol, _dave);

      final msg = _env('privado para dave');
      await sim.send(_alice, _dave, msg);

      expect(sim.node(_dave).timesReceived(msg), 1);
      expect(sim.node(_bob).received, isEmpty);
      expect(sim.node(_carol).received, isEmpty,
          reason: 'los relays intermedios no ven el contenido en su app');
    });

    test('resiliencia: si un camino se cae, el otro entrega', () async {
      // Diamante A→{B,C}→D. Antes de enviar, cae el enlace B–D.
      sim.addNode(_alice);
      sim.addNode(_bob);
      sim.addNode(_carol);
      sim.addNode(_dave);
      await sim.connect(_alice, _bob);
      await sim.connect(_alice, _carol);
      await sim.connect(_bob, _dave);
      await sim.connect(_carol, _dave);

      sim.disconnect(_bob, _dave); // el camino por B queda roto

      final msg = _env('ruta alterna');
      await sim.send(_alice, _dave, msg);

      expect(sim.node(_dave).timesReceived(msg), 1,
          reason: 'con B–D caído, D debe recibir por el camino A→C→D');
    });
  });
}

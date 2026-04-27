import 'dart:async';
import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'mesh_protocol.dart';
import 'message_store.dart';

/// Router del mesh — decide qué hacer con cada paquete recibido.
///
/// Reglas por tipo de paquete:
///
///   MESSAGE recibido:
///     1. ¿Ya lo vimos? → descartar (deduplicación)
///     2. ¿Es para nosotros? → intentar descifrar → entregar
///     3. ¿TTL > 0? → decrementar TTL → reencolar para broadcast
///     4. Enviar ACK_RELAY al peer que nos lo mandó
///
///   ACK_RELAY recibido:
///     → registrar que el peer recibió el mensaje
///
///   ACK_DELIV recibido:
///     → marcar mensaje como entregado en el store
///     → propagar (TTL--) para que llegue al sender original
///
///   ANNOUNCE recibido:
///     → registrar peer nuevo
///     → intentar entregar pending messages para ese hint

enum RouterDecision {
  deliverToApp,   // descifrar y entregar a la app
  relay,          // retransmitir a otros peers
  discard,        // duplicado, TTL agotado, o malformado
  ackOnly,        // ACK procesado, nada más que hacer
}

@immutable
class RouterResult {
  final RouterDecision decision;
  final MeshPacket? packetToRelay;    // si decision == relay
  final Uint8List? ackToSend;         // ACK_RELAY serializado para devolver al sender
  final List<MeshPacket> pendingToSend; // mensajes del store para el nuevo peer

  const RouterResult({
    required this.decision,
    this.packetToRelay,
    this.ackToSend,
    this.pendingToSend = const [],
  });
}

class MeshRouter {
  final String _myPhantomId;
  final MessageStore _store;
  final Uint8List _myHint;

  // Stream de paquetes que el router decide retransmitir
  final _relayController = StreamController<MeshPacket>.broadcast();
  Stream<MeshPacket> get packetsToRelay => _relayController.stream;

  // Stream de envelopes cuyo destHint coincide con el nuestro.
  // PhantomCore intenta descifrar; si falla, descarta silenciosamente.
  final _deliveryController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get deliveredEnvelopes => _deliveryController.stream;

  // Peers conocidos: hint → última vez visto
  final Map<String, DateTime> _knownPeers = {};

  MeshRouter({
    required String myPhantomId,
    required MessageStore store,
  })  : _myPhantomId = myPhantomId,
        _store = store,
        _myHint = MeshPacket.nodeHint(myPhantomId);

  // ── Procesamiento de paquetes ─────────────────────────────────────────────

  Future<RouterResult> process(MeshPacket packet, {String? fromPeerHint}) async {
    return switch (packet.type) {
      MeshPacketType.message   => _handleMessage(packet, fromPeerHint: fromPeerHint),
      MeshPacketType.ackRelay  => _handleAckRelay(packet),
      MeshPacketType.ackDeliv  => _handleAckDeliv(packet),
      MeshPacketType.announce  => _handleAnnounce(packet),
      MeshPacketType.query     => _handleQuery(packet),
      MeshPacketType.queryResp => _handleQueryResp(packet),
    };
  }

  // ── MESSAGE ───────────────────────────────────────────────────────────────

  Future<RouterResult> _handleMessage(
    MeshPacket packet, {
    String? fromPeerHint,
  }) async {
    final msgId = packet.messageIdHex;

    // 1. Deduplicación
    if (_store.markSeen(msgId)) {
      return const RouterResult(decision: RouterDecision.discard);
    }

    // 2. Construir ACK_RELAY para devolver al peer que nos lo mandó
    final ackRelay = MeshPacket.ackRelay(
      originalMessageId: packet.messageId,
      myPhantomId: _myPhantomId,
    ).serialize();

    // 3. ¿Es para nosotros?
    final isForMe = _hintsMatch(packet.destHint, _myHint);

    if (isForMe && packet.payload.isNotEmpty) {
      // Emitir el envelope para que PhantomCore intente descifrarlo.
      // Si el descifrado falla (colisión de hint), PhantomCore lo descarta.
      _deliveryController.add(packet.payload);

      // Propagar ACK_DELIV por el mesh
      final ackDeliv = MeshPacket.ackDeliv(
        originalMessageId: packet.messageId,
        myPhantomId: _myPhantomId,
      );
      _relayController.add(ackDeliv);

      return RouterResult(
        decision: RouterDecision.deliverToApp,
        ackToSend: ackRelay,
      );
    }

    // 4. ¿TTL agotado?
    if (packet.ttl == 0) {
      return RouterResult(
        decision: RouterDecision.discard,
        ackToSend: ackRelay,
      );
    }

    // 5. Relay — decrementar TTL y reencolar
    final toRelay = packet.withDecrementedTTL();

    // Guardar en store para entrega futura (store-and-forward)
    _store.enqueue(toRelay);

    _relayController.add(toRelay);

    return RouterResult(
      decision: RouterDecision.relay,
      packetToRelay: toRelay,
      ackToSend: ackRelay,
    );
  }

  // ── ACK_RELAY ─────────────────────────────────────────────────────────────

  Future<RouterResult> _handleAckRelay(MeshPacket packet) async {
    // Solo registrar — el mensaje fue recibido por el siguiente hop
    _store.recordAttempt(packet.messageIdHex);
    return const RouterResult(decision: RouterDecision.ackOnly);
  }

  // ── ACK_DELIV ─────────────────────────────────────────────────────────────

  Future<RouterResult> _handleAckDeliv(MeshPacket packet) async {
    final msgId = packet.messageIdHex;

    // Marcar como entregado — eliminar del store
    _store.markDelivered(msgId);

    // ¿Ya vimos este ACK?
    if (_store.hasSeen('ack_deliv_$msgId')) {
      return const RouterResult(decision: RouterDecision.discard);
    }
    _store.markSeen('ack_deliv_$msgId');

    // Propagar el ACK_DELIV para que llegue al sender original
    if (packet.ttl > 0) {
      final toRelay = packet.withDecrementedTTL();
      _relayController.add(toRelay);
      return RouterResult(
        decision: RouterDecision.relay,
        packetToRelay: toRelay,
      );
    }

    return const RouterResult(decision: RouterDecision.ackOnly);
  }

  // ── ANNOUNCE ──────────────────────────────────────────────────────────────

  Future<RouterResult> _handleAnnounce(MeshPacket packet) async {
    final peerHint = packet.originHint;
    final hintHex = peerHint.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    // Registrar peer
    _knownPeers[hintHex] = DateTime.now();

    // Buscar mensajes pendientes para este peer
    final pendingForPeer = _store.getPendingForHint(peerHint);

    if (pendingForPeer.isNotEmpty) {
      return RouterResult(
        decision: RouterDecision.relay,
        pendingToSend: pendingForPeer.map((p) => p.packet).toList(),
      );
    }

    return const RouterResult(decision: RouterDecision.ackOnly);
  }

  // ── QUERY / QUERY_RESP ────────────────────────────────────────────────────

  Future<RouterResult> _handleQuery(MeshPacket packet) async {
    // Por ahora: ignorar queries — implementar en fase 2
    return const RouterResult(decision: RouterDecision.discard);
  }

  Future<RouterResult> _handleQueryResp(MeshPacket packet) async {
    return const RouterResult(decision: RouterDecision.discard);
  }

  // ── API de envío ──────────────────────────────────────────────────────────

  /// Encola un mensaje outgoing para envío por mesh.
  /// Devuelve el paquete listo para transmitir.
  MeshPacket prepareOutgoing({
    required String fullMessageId,
    required String recipientPhantomId,
    required Uint8List encryptedEnvelope,
  }) {
    final packet = MeshPacket.message(
      fullMessageId: fullMessageId,
      senderPhantomId: _myPhantomId,
      recipientPhantomId: recipientPhantomId,
      encryptedEnvelope: encryptedEnvelope,
    );

    // Guardar en store — si no hay peers ahora, se entregará cuando aparezcan
    _store.enqueue(packet, targetPhantomId: recipientPhantomId);

    // Marcar como visto para no reprocessarlo si nos lo rebotan
    _store.markSeen(packet.messageIdHex);

    return packet;
  }

  /// Genera el paquete ANNOUNCE para broadcast periódico.
  MeshPacket buildAnnounce() {
    return MeshPacket.announce(
      myPhantomId: _myPhantomId,
      capabilities: kCapRelay |
          (_store.pendingCount > 0 ? kCapHasPending : 0),
    );
  }

  // ── Peers ─────────────────────────────────────────────────────────────────

  int get knownPeerCount => _knownPeers.length;

  void pruneStalePeers({Duration timeout = const Duration(minutes: 5)}) {
    final cutoff = DateTime.now().subtract(timeout);
    _knownPeers.removeWhere((_, ts) => ts.isBefore(cutoff));
  }

  // ── Utils ─────────────────────────────────────────────────────────────────

  static bool _hintsMatch(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Future<void> dispose() async {
    await _relayController.close();
    await _deliveryController.close();
  }
}

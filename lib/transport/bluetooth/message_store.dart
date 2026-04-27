import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:meta/meta.dart';
import 'mesh_protocol.dart';

/// Store-and-forward local — 100% en dispositivo, cero nube.
///
/// Cuando un mensaje no puede entregarse (destinatario fuera de rango,
/// sin internet), se guarda aquí con una expiración.
///
/// Al conectar un nuevo peer BLE, el router consulta este store
/// para intentar entregar mensajes pendientes.
///
/// Persistencia: serializado a JSON en Hive (mismo storage cifrado del core).
/// Por ahora en memoria — integración con Hive en la fase de wiring.

@immutable
class PendingMessage {
  final MeshPacket packet;
  final DateTime enqueuedAt;
  final DateTime expiresAt;
  final int deliveryAttempts;
  final String? targetPhantomId; // si se conoce el ID completo del destinatario

  const PendingMessage({
    required this.packet,
    required this.enqueuedAt,
    required this.expiresAt,
    this.deliveryAttempts = 0,
    this.targetPhantomId,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get shouldRetry => deliveryAttempts < 10 && !isExpired;

  Duration get timeToExpiry => expiresAt.difference(DateTime.now());

  PendingMessage withAttempt() => PendingMessage(
        packet: packet,
        enqueuedAt: enqueuedAt,
        expiresAt: expiresAt,
        deliveryAttempts: deliveryAttempts + 1,
        targetPhantomId: targetPhantomId,
      );

  Map<String, dynamic> toJson() => {
        'packet': base64.encode(packet.serialize()),
        'enqueued': enqueuedAt.millisecondsSinceEpoch,
        'expires': expiresAt.millisecondsSinceEpoch,
        'attempts': deliveryAttempts,
        'target': targetPhantomId,
      };

  static PendingMessage fromJson(Map<String, dynamic> j) => PendingMessage(
        packet: MeshPacket.deserialize(base64.decode(j['packet'] as String)),
        enqueuedAt: DateTime.fromMillisecondsSinceEpoch(j['enqueued'] as int),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(j['expires'] as int),
        deliveryAttempts: j['attempts'] as int,
        targetPhantomId: j['target'] as String?,
      );
}

class MessageStore {
  // Mensajes que aún no hemos podido entregar (outgoing o relay)
  final Map<String, PendingMessage> _pending = {};

  // Mensajes que ya vimos (para deduplicación del mesh)
  // Clave: messageIdHex — valor: timestamp de cuando lo vimos
  final Map<String, DateTime> _seen = {};

  // Límites
  static const int kMaxPending = 500;
  static const int kSeenCacheSize = 2000;
  static const Duration kDefaultTTL = Duration(hours: 72);
  static const Duration kSeenExpiry = Duration(hours: 24);

  // Stream de cambios para que la UI pueda reaccionar
  final _pendingController = StreamController<int>.broadcast();
  Stream<int> get pendingCountStream => _pendingController.stream;
  int get pendingCount => _pending.length;

  // ── API pública ────────────────────────────────────────────────────────────

  /// Agrega un mensaje al store para entrega futura.
  /// Devuelve false si el store está lleno.
  bool enqueue(
    MeshPacket packet, {
    Duration ttl = kDefaultTTL,
    String? targetPhantomId,
  }) {
    if (_pending.length >= kMaxPending) {
      // Intentar hacer espacio expirando mensajes viejos
      _purgeExpired();
      if (_pending.length >= kMaxPending) return false;
    }

    final key = packet.messageIdHex;
    if (_pending.containsKey(key)) return true; // ya estaba

    _pending[key] = PendingMessage(
      packet: packet,
      enqueuedAt: DateTime.now(),
      expiresAt: DateTime.now().add(ttl),
      targetPhantomId: targetPhantomId,
    );

    _pendingController.add(_pending.length);
    return true;
  }

  /// Marca un mensaje como entregado — lo elimina del store.
  void markDelivered(String messageIdHex) {
    if (_pending.remove(messageIdHex) != null) {
      _pendingController.add(_pending.length);
    }
  }

  /// Devuelve mensajes pendientes que podrían ser para este peer.
  ///
  /// Usa el hint para filtrar — mejor retransmitir de más que de menos.
  /// Si el hint coincide exactamente, prioriza esos mensajes.
  List<PendingMessage> getPendingForHint(Uint8List peerHint) {
    _purgeExpired();

    final exact = <PendingMessage>[];
    final possible = <PendingMessage>[];

    for (final pending in _pending.values) {
      if (!pending.shouldRetry) continue;

      final destHint = pending.packet.destHint;
      if (_hintsMatch(destHint, peerHint)) {
        exact.add(pending);
      } else if (pending.packet.ttl > 0) {
        // Mensajes con TTL aún pueden retransmitirse en broadcast
        possible.add(pending);
      }
    }

    // Priorizar exactos, luego el resto
    return [...exact, ...possible.take(10)];
  }

  /// Todos los mensajes pendientes (para broadcast a nuevos peers).
  List<PendingMessage> getAllPending() {
    _purgeExpired();
    return _pending.values.where((m) => m.shouldRetry).toList();
  }

  /// Incrementa el contador de intentos de un mensaje.
  void recordAttempt(String messageIdHex) {
    final existing = _pending[messageIdHex];
    if (existing != null) {
      _pending[messageIdHex] = existing.withAttempt();
    }
  }

  // ── Deduplicación ──────────────────────────────────────────────────────────

  /// Registra que vimos este messageId.
  /// Devuelve true si ya lo habíamos visto (duplicado → descartar).
  bool markSeen(String messageIdHex) {
    final already = _seen.containsKey(messageIdHex);
    if (!already) {
      _seen[messageIdHex] = DateTime.now();
      _trimSeenCache();
    }
    return already;
  }

  bool hasSeen(String messageIdHex) => _seen.containsKey(messageIdHex);

  // ── Persistencia (JSON para Hive) ─────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'pending': _pending.map((k, v) => MapEntry(k, v.toJson())),
        'seen': _seen.map((k, v) => MapEntry(k, v.millisecondsSinceEpoch)),
      };

  void loadFromJson(Map<String, dynamic> json) {
    final pendingRaw = json['pending'] as Map<String, dynamic>? ?? {};
    for (final entry in pendingRaw.entries) {
      try {
        final msg = PendingMessage.fromJson(
            Map<String, dynamic>.from(entry.value as Map));
        if (!msg.isExpired) _pending[entry.key] = msg;
      } catch (_) {
        // Ignorar entradas corruptas
      }
    }

    final seenRaw = json['seen'] as Map<String, dynamic>? ?? {};
    final cutoff = DateTime.now().subtract(kSeenExpiry);
    for (final entry in seenRaw.entries) {
      final ts = DateTime.fromMillisecondsSinceEpoch(entry.value as int);
      if (ts.isAfter(cutoff)) _seen[entry.key] = ts;
    }
  }

  // ── Estadísticas ───────────────────────────────────────────────────────────

  MessageStoreStats get stats => MessageStoreStats(
        pendingCount: _pending.length,
        seenCount: _seen.length,
        oldestPendingAge: _pending.isEmpty
            ? null
            : DateTime.now().difference(
                _pending.values
                    .map((m) => m.enqueuedAt)
                    .reduce((a, b) => a.isBefore(b) ? a : b),
              ),
      );

  // ── Internals ──────────────────────────────────────────────────────────────

  void _purgeExpired() {
    _pending.removeWhere((_, v) => v.isExpired);
    final cutoff = DateTime.now().subtract(kSeenExpiry);
    _seen.removeWhere((_, ts) => ts.isBefore(cutoff));
  }

  void _trimSeenCache() {
    if (_seen.length > kSeenCacheSize) {
      // Eliminar los más viejos
      final sorted = _seen.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final entry in sorted.take(_seen.length - kSeenCacheSize)) {
        _seen.remove(entry.key);
      }
    }
  }

  static bool _hintsMatch(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> dispose() async {
    await _pendingController.close();
  }
}

@immutable
class MessageStoreStats {
  final int pendingCount;
  final int seenCount;
  final Duration? oldestPendingAge;

  const MessageStoreStats({
    required this.pendingCount,
    required this.seenCount,
    this.oldestPendingAge,
  });

  @override
  String toString() =>
      'MessageStoreStats(pending=$pendingCount, seen=$seenCount, '
      'oldest=${oldestPendingAge?.inHours}h)';
}

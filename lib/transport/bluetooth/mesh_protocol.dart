import 'dart:typed_data';
import 'dart:convert';
import 'package:meta/meta.dart';

// ── Constantes del protocolo ──────────────────────────────────────────────────

const int kMagic0 = 0x50; // 'P'
const int kMagic1 = 0x48; // 'H'
const int kProtocolVersion = 0x01;
const int kMaxTTL = 7;
const int kMaxPayloadSize = 4096; // bytes — el transport fragmenta en chunks BLE internamente
const int kNodeHintSize = 4;     // bytes del hash truncado
const int kMessageIdSize = 4;    // bytes del UUID truncado

// Advertisement
const int kAdvCompanyId0 = 0xFF;
const int kAdvCompanyId1 = 0xFF;
const int kAdvTypeByte   = 0x50; // 'P'

// Capabilities bitmask
const int kCapRelay      = 0x01;
const int kCapHasPending = 0x02;

// ── Tipos de paquete ──────────────────────────────────────────────────────────

enum MeshPacketType {
  announce  (0x01),
  message   (0x02),
  ackRelay  (0x03),
  ackDeliv  (0x04),
  query     (0x05),
  queryResp (0x06);

  final int code;
  const MeshPacketType(this.code);

  static MeshPacketType fromCode(int code) => MeshPacketType.values
      .firstWhere((t) => t.code == code,
          orElse: () => throw MeshProtocolException('Tipo desconocido: 0x${code.toRadixString(16)}'));
}

// ── MeshPacket — paquete base ─────────────────────────────────────────────────

@immutable
class MeshPacket {
  final MeshPacketType type;
  final int version;
  final int ttl;
  final Uint8List messageId;   // 4 bytes
  final Uint8List originHint;  // 4 bytes — hash(senderPhantomId) truncado
  final Uint8List destHint;    // 4 bytes — hash(recipientPhantomId) truncado
  final Uint8List payload;     // envelope cifrado (opaco para relayers)

  const MeshPacket({
    required this.type,
    required this.ttl,
    required this.messageId,
    required this.originHint,
    required this.destHint,
    required this.payload,
    this.version = kProtocolVersion,
  });

  // ── Factory constructors ───────────────────────────────────────────────────

  /// Paquete MESSAGE: envelope cifrado en tránsito.
  factory MeshPacket.message({
    required String fullMessageId,   // UUID completo del mensaje
    required String senderPhantomId,
    required String recipientPhantomId,
    required Uint8List encryptedEnvelope,
    int ttl = kMaxTTL,
  }) {
    if (encryptedEnvelope.length > kMaxPayloadSize) {
      throw MeshProtocolException(
          'Payload demasiado grande: ${encryptedEnvelope.length} > $kMaxPayloadSize bytes');
    }
    return MeshPacket(
      type: MeshPacketType.message,
      ttl: ttl,
      messageId: _truncateId(fullMessageId),
      originHint: nodeHint(senderPhantomId),
      destHint: nodeHint(recipientPhantomId),
      payload: encryptedEnvelope,
    );
  }

  /// Paquete ACK_RELAY: confirma recepción y relay.
  factory MeshPacket.ackRelay({
    required Uint8List originalMessageId,
    required String myPhantomId,
  }) {
    return MeshPacket(
      type: MeshPacketType.ackRelay,
      ttl: 1, // ACKs no se retransmiten más allá de un salto
      messageId: originalMessageId,
      originHint: nodeHint(myPhantomId),
      destHint: Uint8List(kNodeHintSize), // empty — no tiene dest específico
      payload: Uint8List(0),
    );
  }

  /// Paquete ACK_DELIV: el destinatario real recibió y descifró.
  factory MeshPacket.ackDeliv({
    required Uint8List originalMessageId,
    required String myPhantomId,
  }) {
    return MeshPacket(
      type: MeshPacketType.ackDeliv,
      ttl: kMaxTTL, // se propaga para que el sender sepa
      messageId: originalMessageId,
      originHint: nodeHint(myPhantomId),
      destHint: Uint8List(kNodeHintSize),
      payload: Uint8List(0),
    );
  }

  /// Paquete ANNOUNCE: anuncio de presencia en el mesh.
  factory MeshPacket.announce({
    required String myPhantomId,
    required int capabilities,
  }) {
    final payload = Uint8List(1)..[0] = capabilities;
    return MeshPacket(
      type: MeshPacketType.announce,
      ttl: 1,
      messageId: Uint8List(kMessageIdSize),
      originHint: nodeHint(myPhantomId),
      destHint: Uint8List(kNodeHintSize),
      payload: payload,
    );
  }

  // ── Serialización ──────────────────────────────────────────────────────────

  /// Wire format:
  /// [0]    magic0   (0x50)
  /// [1]    magic1   (0x48)
  /// [2]    type     (1 byte)
  /// [3]    version  (1 byte)
  /// [4]    ttl      (1 byte)
  /// [5..8] msgId    (4 bytes)
  /// [9..12]  originHint (4 bytes)
  /// [13..16] destHint   (4 bytes)
  /// [17..18] payloadLen (2 bytes big-endian)
  /// [19..N]  payload
  /// [N+1..N+2] crc16   (2 bytes)
  /// Total header: 19 bytes + payload + 2 CRC = 21 + payload bytes
  Uint8List serialize() {
    final payloadLen = payload.length;
    final totalLen = 19 + payloadLen + 2;
    final buf = Uint8List(totalLen);
    int o = 0;

    buf[o++] = kMagic0;
    buf[o++] = kMagic1;
    buf[o++] = type.code;
    buf[o++] = version;
    buf[o++] = ttl;

    buf.setRange(o, o + kMessageIdSize, messageId); o += kMessageIdSize;
    buf.setRange(o, o + kNodeHintSize, originHint); o += kNodeHintSize;
    buf.setRange(o, o + kNodeHintSize, destHint);   o += kNodeHintSize;

    buf[o++] = (payloadLen >> 8) & 0xFF;
    buf[o++] = payloadLen & 0xFF;

    if (payloadLen > 0) {
      buf.setRange(o, o + payloadLen, payload);
      o += payloadLen;
    }

    // CRC16-CCITT sobre todo excepto el propio CRC
    final crc = _crc16(buf.sublist(0, o));
    buf[o++] = (crc >> 8) & 0xFF;
    buf[o++] = crc & 0xFF;

    return buf;
  }

  static MeshPacket deserialize(Uint8List data) {
    if (data.length < 21) {
      throw MeshProtocolException('Paquete demasiado corto: ${data.length} bytes');
    }

    // Verificar magic
    if (data[0] != kMagic0 || data[1] != kMagic1) {
      throw MeshProtocolException(
          'Magic inválido: 0x${data[0].toRadixString(16)} 0x${data[1].toRadixString(16)}');
    }

    // Verificar CRC
    final crcExpected = (data[data.length - 2] << 8) | data[data.length - 1];
    final crcActual = _crc16(data.sublist(0, data.length - 2));
    if (crcExpected != crcActual) {
      throw MeshProtocolException(
          'CRC inválido: esperado $crcExpected, calculado $crcActual');
    }

    int o = 2;
    final type = MeshPacketType.fromCode(data[o++]);
    final version = data[o++];
    final ttl = data[o++];

    final messageId = Uint8List.fromList(data.sublist(o, o + kMessageIdSize)); o += kMessageIdSize;
    final originHint = Uint8List.fromList(data.sublist(o, o + kNodeHintSize)); o += kNodeHintSize;
    final destHint   = Uint8List.fromList(data.sublist(o, o + kNodeHintSize)); o += kNodeHintSize;

    final payloadLen = (data[o] << 8) | data[o + 1]; o += 2;

    if (o + payloadLen > data.length - 2) {
      throw MeshProtocolException('payloadLen incoherente: $payloadLen');
    }

    final payload = payloadLen > 0
        ? Uint8List.fromList(data.sublist(o, o + payloadLen))
        : Uint8List(0);

    return MeshPacket(
      type: type,
      version: version,
      ttl: ttl,
      messageId: messageId,
      originHint: originHint,
      destHint: destHint,
      payload: payload,
    );
  }

  // ── TTL decrement ──────────────────────────────────────────────────────────

  /// Devuelve una copia del paquete con TTL decrementado.
  /// Lanza [MeshProtocolException] si TTL ya es 0.
  MeshPacket withDecrementedTTL() {
    if (ttl == 0) throw const MeshProtocolException('TTL agotado — no retransmitir');
    return MeshPacket(
      type: type,
      version: version,
      ttl: ttl - 1,
      messageId: messageId,
      originHint: originHint,
      destHint: destHint,
      payload: payload,
    );
  }

  // ── Utilidades ─────────────────────────────────────────────────────────────

  /// Hash truncado a 4 bytes de un PhantomID — usado como hint de routing.
  /// No reversible: un observador no puede reconstruir el PhantomID completo.
  static Uint8List nodeHint(String phantomId) {
    // FNV-1a 32-bit sobre los bytes del ID
    int hash = 0x811c9dc5;
    for (final byte in utf8.encode(phantomId)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return Uint8List(4)
      ..[0] = (hash >> 24) & 0xFF
      ..[1] = (hash >> 16) & 0xFF
      ..[2] = (hash >> 8) & 0xFF
      ..[3] = hash & 0xFF;
  }

  static Uint8List _truncateId(String uuid) {
    // Primeros 4 bytes del UUID sin guiones
    final clean = uuid.replaceAll('-', '');
    final bytes = Uint8List(4);
    for (int i = 0; i < 4; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// CRC16-CCITT (polinomio 0x1021)
  static int _crc16(Uint8List data) {
    int crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte << 8;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
      }
    }
    return crc;
  }

  String get messageIdHex =>
      messageId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() =>
      'MeshPacket(${type.name}, ttl=$ttl, msgId=$messageIdHex)';
}

// ── BLE Advertisement payload ─────────────────────────────────────────────────

@immutable
class MeshAdvertisement {
  final Uint8List nodeHintBytes; // 4 bytes
  final int capabilities;        // bitmask

  const MeshAdvertisement({
    required this.nodeHintBytes,
    required this.capabilities,
  });

  factory MeshAdvertisement.forNode({
    required String phantomId,
    required bool canRelay,
    required bool hasPending,
  }) {
    int caps = 0;
    if (canRelay) caps |= kCapRelay;
    if (hasPending) caps |= kCapHasPending;
    return MeshAdvertisement(
      nodeHintBytes: MeshPacket.nodeHint(phantomId),
      capabilities: caps,
    );
  }

  /// Payload BLE:
  /// [0..1] company_id (0xFF 0xFF)
  /// [2]    type byte  (0x50)
  /// [3..6] nodeHint   (4 bytes)
  /// [7]    capabilities
  /// Total: 8 bytes
  Uint8List toAdvPayload() {
    return Uint8List.fromList([
      kAdvCompanyId0,
      kAdvCompanyId1,
      kAdvTypeByte,
      ...nodeHintBytes,
      capabilities,
    ]);
  }

  static MeshAdvertisement? fromAdvPayload(Uint8List payload) {
    if (payload.length < 8) return null;
    if (payload[0] != kAdvCompanyId0 ||
        payload[1] != kAdvCompanyId1 ||
        payload[2] != kAdvTypeByte) {
      return null;
    }

    return MeshAdvertisement(
      nodeHintBytes: Uint8List.fromList(payload.sublist(3, 7)),
      capabilities: payload[7],
    );
  }

  bool get canRelay => (capabilities & kCapRelay) != 0;
  bool get hasPending => (capabilities & kCapHasPending) != 0;

  @override
  String toString() {
    final hint = nodeHintBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'MeshAdv(hint=$hint, relay=$canRelay, pending=$hasPending)';
  }
}

// ── Fragmentación de nivel de aplicación ──────────────────────────────────────
//
// BLE entrega cada write/notify como un evento independiente acotado por el
// MTU (~20 bytes en chipsets viejos, hasta ~512 negociado). Un MeshPacket
// serializado supera eso fácil: un frame cifrado ronda 1130 bytes y un INIT de
// handshake ~3699. Sin reensamblaje, el receptor hacía deserialize sobre cada
// fragmento suelto → magic/CRC inválidos → descartado. Es decir, el mesh solo
// podía cargar paquetes que cupieran en un MTU y los handshakes eran
// imposibles.
//
// Esta capa parte un paquete en fragmentos autodescriptivos y los reensambla
// del otro lado. Se distingue de un MeshPacket por su magic 'PF' (vs 'PH'),
// así que los paquetes que caben en un chunk pueden seguir viajando crudos.

const int kFragMagic0 = 0x50; // 'P'
const int kFragMagic1 = 0x46; // 'F'

/// Cabecera de fragmento (9 bytes) + datos:
/// [0] 'P' [1] 'F' [2..3] groupId(BE) [4] idx [5] total [6..7] len(BE) [8..]
const int kFragHeaderSize = 8;

class MeshFragment {
  /// Parte [full] en fragmentos de a lo sumo [chunkSize] bytes de payload
  /// cada uno (sin contar la cabecera de 8 bytes), etiquetados con [groupId]
  /// para que el receptor los reagrupe. Máximo 255 fragmentos.
  static List<Uint8List> split(
    Uint8List full, {
    required int chunkSize,
    required int groupId,
  }) {
    if (chunkSize < 1) {
      throw const MeshProtocolException('chunkSize inválido');
    }
    final total = (full.length + chunkSize - 1) ~/ chunkSize;
    if (total == 0) return const [];
    if (total > 255) {
      throw MeshProtocolException(
          'paquete demasiado grande para fragmentar: $total > 255 fragmentos');
    }
    final out = <Uint8List>[];
    for (int idx = 0; idx < total; idx++) {
      final start = idx * chunkSize;
      final end = (start + chunkSize) < full.length ? start + chunkSize : full.length;
      final len = end - start;
      final frame = Uint8List(kFragHeaderSize + len);
      frame[0] = kFragMagic0;
      frame[1] = kFragMagic1;
      frame[2] = (groupId >> 8) & 0xFF;
      frame[3] = groupId & 0xFF;
      frame[4] = idx;
      frame[5] = total;
      frame[6] = (len >> 8) & 0xFF;
      frame[7] = len & 0xFF;
      frame.setRange(kFragHeaderSize, kFragHeaderSize + len, full, start);
      out.add(frame);
    }
    return out;
  }

  /// True si [data] es un frame de fragmento (empieza con el magic 'PF').
  static bool isFragment(Uint8List data) =>
      data.length >= kFragHeaderSize &&
      data[0] == kFragMagic0 &&
      data[1] == kFragMagic1;
}

/// Reensambla fragmentos por groupId. Acotado en memoria y en tiempo: como el
/// mesh puede reordenar/duplicar/perder fragmentos, cada grupo caduca y el
/// total de grupos concurrentes está limitado (se descarta el más viejo).
class MeshReassembler {
  final int maxGroups;
  final Duration groupTtl;

  MeshReassembler({this.maxGroups = 64, this.groupTtl = const Duration(seconds: 30)});

  final Map<int, _FragGroup> _groups = {};

  /// Procesa un frame recibido:
  ///  - si NO es fragmento → lo devuelve tal cual (el caller hace deserialize);
  ///  - si es fragmento incompleto → null;
  ///  - si completa un grupo → devuelve el paquete reensamblado.
  Uint8List? offer(Uint8List data) {
    if (!MeshFragment.isFragment(data)) return data;
    if (data.length < kFragHeaderSize) return null;

    final groupId = (data[2] << 8) | data[3];
    final idx = data[4];
    final total = data[5];
    final len = (data[6] << 8) | data[7];
    if (total == 0 || idx >= total) return null;
    if (kFragHeaderSize + len > data.length) return null;

    final payload = Uint8List.sublistView(data, kFragHeaderSize, kFragHeaderSize + len);

    _evictStale();
    final group = _groups.putIfAbsent(groupId, () {
      if (_groups.length >= maxGroups) {
        // Descartar el grupo más viejo para acotar memoria.
        final oldest = _groups.entries
            .reduce((a, b) => a.value.createdAt.isBefore(b.value.createdAt) ? a : b);
        _groups.remove(oldest.key);
      }
      return _FragGroup(total);
    });

    if (group.total != total) {
      // Colisión de groupId con distinto total → reiniciar el grupo.
      _groups[groupId] = _FragGroup(total)..add(idx, payload);
      return _tryComplete(groupId);
    }

    group.add(idx, payload);
    return _tryComplete(groupId);
  }

  Uint8List? _tryComplete(int groupId) {
    final group = _groups[groupId];
    if (group == null || !group.isComplete) return null;
    final full = group.assemble();
    _groups.remove(groupId);
    return full;
  }

  void _evictStale() {
    final now = DateTime.now();
    _groups.removeWhere((_, g) => now.difference(g.createdAt) > groupTtl);
  }

  void clear() => _groups.clear();
}

class _FragGroup {
  final int total;
  final DateTime createdAt = DateTime.now();
  final Map<int, Uint8List> _parts = {};

  _FragGroup(this.total);

  void add(int idx, Uint8List data) => _parts[idx] = data;

  bool get isComplete => _parts.length == total;

  Uint8List assemble() {
    final size = _parts.values.fold<int>(0, (s, p) => s + p.length);
    final out = Uint8List(size);
    int o = 0;
    for (int i = 0; i < total; i++) {
      final part = _parts[i]!;
      out.setRange(o, o + part.length, part);
      o += part.length;
    }
    return out;
  }
}

class MeshProtocolException implements Exception {
  final String message;
  const MeshProtocolException(this.message);
  @override
  String toString() => 'MeshProtocolException: $message';
}

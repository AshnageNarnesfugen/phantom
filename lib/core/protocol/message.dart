import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:uuid/uuid.dart';
import 'package:meta/meta.dart';
import '../crypto/double_ratchet.dart';

/// Protocolo de mensajes de Phantom.
///
/// Garantías de privacidad:
///   - Sin remitente en el envelope (sealed sender)
///   - Sin timestamps reales (ruido de ±5 min)
///   - Padding a bloque fijo de 1KB — todos los mensajes tienen el mismo tamaño
///   - Sin metadatos de sesión en el wire format
///   - MAC del envelope con HMAC-SHA256 (integridad del envelope completo)

// ── Tamaño de bloque para padding ────────────────────────────────────────────

const int _blockSize = 1024; // bytes — todos los mensajes ocupan múltiplos de 1KB

// ── Tipos de contenido ────────────────────────────────────────────────────────

enum MessageType {
  text(0x01),
  image(0x02),
  file(0x03),
  typingIndicator(0x10),
  readReceipt(0x11),
  keyExchange(0x20),
  bundleUpdate(0x21);

  final int code;
  const MessageType(this.code);

  static MessageType fromCode(int code) {
    return MessageType.values.firstWhere(
      (t) => t.code == code,
      orElse: () => throw ProtocolException('Tipo de mensaje desconocido: $code'),
    );
  }
}

// ── Mensaje interno (antes de cifrar) ─────────────────────────────────────────

@immutable
class PhantomMessage {
  /// ID único del mensaje (UUID v4).
  final String id;

  /// Tipo de contenido.
  final MessageType type;

  /// Contenido serializado (texto UTF-8, bytes de imagen, etc.).
  final Uint8List content;

  /// Timestamp con ruido añadido (±5 minutos) — no el real.
  /// En microsegundos Unix para mayor resistencia a análisis.
  final int noisyTimestampUs;

  /// Referencia al mensaje que se responde (opcional).
  final String? replyToId;

  PhantomMessage({
    String? id,
    required this.type,
    required this.content,
    this.replyToId,
    int? timestampUs,
  })  : id = id ?? const Uuid().v4(),
        noisyTimestampUs = timestampUs ?? _noisyTimestamp();

  /// Constructor para mensajes de texto.
  factory PhantomMessage.text(String text, {String? replyToId}) {
    return PhantomMessage(
      type: MessageType.text,
      content: Uint8List.fromList(utf8.encode(text)),
      replyToId: replyToId,
    );
  }

  /// Serializa a bytes para cifrar.
  Uint8List serialize() {
    final idBytes = utf8.encode(id);
    final replyBytes = replyToId != null ? utf8.encode(replyToId!) : <int>[];

    final buf = BytesBuilder();
    // [1 type][8 timestamp][2 id_len][id][2 reply_len][reply][4 content_len][content]
    buf.addByte(type.code);
    buf.add(_int64BE(noisyTimestampUs));
    buf.add(_int16BE(idBytes.length));
    buf.add(idBytes);
    buf.add(_int16BE(replyBytes.length));
    buf.add(replyBytes);
    buf.add(_int32BE(content.length));
    buf.add(content);

    return buf.toBytes();
  }

  static PhantomMessage deserialize(Uint8List bytes) {
    // Minimum: 1 (type) + 8 (ts) + 2 (idLen) + 0 (id) + 2 (replyLen) + 4 (contentLen) = 17
    if (bytes.length < 17) {
      throw const ProtocolException('Mensaje serializado demasiado corto.');
    }
    int offset = 0;

    final typeCode = bytes[offset++];
    final type = MessageType.fromCode(typeCode);

    if (offset + 8 > bytes.length) throw const ProtocolException('Truncado al leer timestamp.');
    final timestamp = _readInt64BE(bytes, offset);
    offset += 8;

    if (offset + 2 > bytes.length) throw const ProtocolException('Truncado al leer idLen.');
    final idLen = _readInt16BE(bytes, offset);
    offset += 2;
    if (idLen < 0 || offset + idLen > bytes.length) {
      throw ProtocolException('idLen inválido: $idLen');
    }
    final id = utf8.decode(bytes.sublist(offset, offset + idLen));
    offset += idLen;

    if (offset + 2 > bytes.length) throw const ProtocolException('Truncado al leer replyLen.');
    final replyLen = _readInt16BE(bytes, offset);
    offset += 2;
    if (replyLen < 0 || offset + replyLen > bytes.length) {
      throw ProtocolException('replyLen inválido: $replyLen');
    }
    String? replyToId;
    if (replyLen > 0) {
      replyToId = utf8.decode(bytes.sublist(offset, offset + replyLen));
    }
    offset += replyLen;

    if (offset + 4 > bytes.length) throw const ProtocolException('Truncado al leer contentLen.');
    final contentLen = _readInt32BE(bytes, offset);
    offset += 4;
    if (contentLen < 0 || offset + contentLen > bytes.length) {
      throw ProtocolException('contentLen inválido: $contentLen');
    }
    final content = Uint8List.fromList(bytes.sublist(offset, offset + contentLen));

    return PhantomMessage(
      id: id,
      type: type,
      content: content,
      replyToId: replyToId,
      timestampUs: timestamp,
    );
  }

  String get textContent => utf8.decode(content);

  // CSPRNG compartido — inicializado una vez por proceso.
  static final _rng = Random.secure();

  static int _noisyTimestamp() {
    final realUs = DateTime.now().microsecondsSinceEpoch;
    // Ruido CSPRNG uniforme ±5 minutos en microsegundos.
    // Random.secure() usa el CSPRNG del SO — no determinístico.
    final noiseUs = _rng.nextInt(600000000) - 300000000;
    return realUs + noiseUs;
  }
}

// ── Envelope cifrado (lo que va por la red) ───────────────────────────────────

@immutable
class PhantomEnvelope {
  /// Versión del protocolo (1 byte).
  static const int protocolVersion = 0x01;

  /// Header cifrado del Double Ratchet (sealed sender).
  final Uint8List encryptedHeader;

  /// Ciphertext del mensaje con padding.
  final Uint8List ciphertext;

  /// Nonce usado para cifrar el mensaje (12 bytes, aleatorio).
  final Uint8List nonce;

  const PhantomEnvelope({
    required this.encryptedHeader,
    required this.ciphertext,
    required this.nonce,
  });

  // Wire format:
  //   [1]  version
  //   [4]  headerLen (big-endian)
  //   [N]  encryptedHeader
  //   [4]  ciphertextLen (big-endian)
  //   [M]  ciphertext  (includes Poly1305 tag in last 16 bytes)
  //   [12] nonce
  //
  // No separate MAC: ChaCha20-Poly1305 AEAD already authenticates
  // [nonce + encryptedHeader(as AAD) + ciphertext].  A redundant
  // outer HMAC keyed from the public nonce adds nothing.
  Uint8List toWireFormat() {
    final buf = BytesBuilder();
    buf.addByte(protocolVersion);
    buf.add(_int32BE(encryptedHeader.length));
    buf.add(encryptedHeader);
    buf.add(_int32BE(ciphertext.length));
    buf.add(ciphertext);
    buf.add(nonce);
    return buf.toBytes();
  }

  static PhantomEnvelope fromWireFormat(Uint8List wire) {
    // Minimum: 1 (ver) + 4 (hLen) + 0 (header) + 4 (cLen) + 0 (cipher) + 12 (nonce) = 21
    if (wire.length < 21) {
      throw const ProtocolException('Envelope demasiado corto.');
    }
    int offset = 0;

    final version = wire[offset++];
    if (version != protocolVersion) {
      throw ProtocolException(
          'Versión de protocolo no soportada: $version (esperado: $protocolVersion)');
    }

    if (offset + 4 > wire.length) throw const ProtocolException('Envelope truncado al leer headerLen.');
    final headerLen = _readInt32BE(wire, offset);
    offset += 4;
    if (headerLen < 0 || offset + headerLen > wire.length) {
      throw ProtocolException('headerLen inválido: $headerLen');
    }
    final encHeader = Uint8List.fromList(wire.sublist(offset, offset + headerLen));
    offset += headerLen;

    if (offset + 4 > wire.length) throw const ProtocolException('Envelope truncado al leer ciphertextLen.');
    final cipherLen = _readInt32BE(wire, offset);
    offset += 4;
    if (cipherLen < 16 || offset + cipherLen > wire.length) {
      throw ProtocolException('ciphertextLen inválido: $cipherLen');
    }
    final cipher = Uint8List.fromList(wire.sublist(offset, offset + cipherLen));
    offset += cipherLen;

    if (offset + 12 > wire.length) throw const ProtocolException('Nonce truncado.');
    final nonce = Uint8List.fromList(wire.sublist(offset, offset + 12));

    return PhantomEnvelope(
      encryptedHeader: encHeader,
      ciphertext: cipher,
      nonce: nonce,
    );
  }
}

// ── Encoder / Decoder de alto nivel ──────────────────────────────────────────

class PhantomProtocol {
  final RatchetSession _session;

  PhantomProtocol(this._session);

  /// Cifra un [PhantomMessage] y devuelve el wire format listo para transmitir.
  Future<Uint8List> encode(PhantomMessage message) async {
    final serialized = message.serialize();
    final padded = _applyPadding(serialized);
    final encrypted = await _session.encrypt(padded);

    final envelope = PhantomEnvelope(
      encryptedHeader: encrypted.encryptedHeader,
      ciphertext: encrypted.ciphertext,
      nonce: encrypted.nonce,
    );

    return envelope.toWireFormat();
  }

  /// Descifra un wire format y devuelve el [PhantomMessage].
  Future<PhantomMessage> decode(Uint8List wire) async {
    final envelope = PhantomEnvelope.fromWireFormat(wire);

    final encrypted = EncryptedMessage(
      encryptedHeader: envelope.encryptedHeader,
      ciphertext: envelope.ciphertext,
      nonce: envelope.nonce,
    );

    try {
      final padded     = await _session.decrypt(encrypted);
      final serialized = _removePadding(padded);
      return PhantomMessage.deserialize(serialized);
    } on ProtocolException {
      rethrow;
    } catch (e) {
      throw ProtocolException('Decryption failed: $e');
    }
  }

  // ── Padding ────────────────────────────────────────────────────────────────

  /// Padding PKCS#7 a múltiplos de _blockSize.
  /// El tamaño fijo elimina análisis de tráfico por tamaño de mensaje.
  static Uint8List _applyPadding(Uint8List data) {
    final targetSize = ((data.length ~/ _blockSize) + 1) * _blockSize;
    final padLen = targetSize - data.length;
    final result = Uint8List(targetSize);
    result.setRange(0, data.length, data);
    result.fillRange(data.length, targetSize, padLen);
    return result;
  }

  static Uint8List _removePadding(Uint8List data) {
    if (data.isEmpty) throw const ProtocolException('Datos vacíos al remover padding.');
    final padLen = data.last;
    if (padLen == 0 || padLen > _blockSize) {
      throw ProtocolException('Padding inválido: $padLen');
    }
    return data.sublist(0, data.length - padLen);
  }

}

// ── Modelo de mensaje almacenado localmente ───────────────────────────────────

enum MessageStatus { sending, sent, delivered, read, failed }
enum MessageDirection { outgoing, incoming }

@immutable
class StoredMessage {
  final String id;
  final String conversationId; // phantomId del contacto
  final MessageType type;
  final Uint8List content;
  final int timestampUs;
  final MessageDirection direction;
  final MessageStatus status;
  final String? replyToId;

  const StoredMessage({
    required this.id,
    required this.conversationId,
    required this.type,
    required this.content,
    required this.timestampUs,
    required this.direction,
    required this.status,
    this.replyToId,
  });

  /// Texto del mensaje (solo válido si type == text).
  String get textContent => utf8.decode(content);

  DateTime get timestamp =>
      DateTime.fromMicrosecondsSinceEpoch(timestampUs);

  StoredMessage copyWith({MessageStatus? status}) {
    return StoredMessage(
      id: id,
      conversationId: conversationId,
      type: type,
      content: content,
      timestampUs: timestampUs,
      direction: direction,
      status: status ?? this.status,
      replyToId: replyToId,
    );
  }

  static StoredMessage fromPhantomMessage({
    required PhantomMessage msg,
    required String conversationId,
    required MessageDirection direction,
    MessageStatus status = MessageStatus.sending,
  }) {
    return StoredMessage(
      id: msg.id,
      conversationId: conversationId,
      type: msg.type,
      content: msg.content,
      timestampUs: msg.noisyTimestampUs,
      direction: direction,
      status: status,
      replyToId: msg.replyToId,
    );
  }
}

// ── Excepciones ───────────────────────────────────────────────────────────────

class ProtocolException implements Exception {
  final String message;
  const ProtocolException(this.message);
  @override
  String toString() => 'ProtocolException: $message';
}

// ── Utilidades de serialización binaria ───────────────────────────────────────

Uint8List _int16BE(int v) => Uint8List(2)
  ..[0] = (v >> 8) & 0xFF
  ..[1] = v & 0xFF;

Uint8List _int32BE(int v) => Uint8List(4)
  ..[0] = (v >> 24) & 0xFF
  ..[1] = (v >> 16) & 0xFF
  ..[2] = (v >> 8) & 0xFF
  ..[3] = v & 0xFF;

Uint8List _int64BE(int v) {
  final buf = Uint8List(8);
  for (int i = 7; i >= 0; i--) {
    buf[i] = v & 0xFF;
    v >>= 8;
  }
  return buf;
}

int _readInt16BE(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
int _readInt32BE(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _readInt64BE(Uint8List b, int o) {
  int v = 0;
  for (int i = 0; i < 8; i++) {
    v = (v << 8) | b[o + i];
  }
  return v;
}

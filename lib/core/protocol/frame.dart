import 'dart:typed_data';
import 'package:bs58check/bs58check.dart' as bs58check;

/// Wire frame wrapper for all Phantom network messages.
///
/// Frame types:
///
///   INIT (0x49 = 'I') — classical X3DH session open:
///     [1=0x49][32 IK][32 EK][165 ContactAddress_v1][PhantomEnvelope]
///
///   HYBRID_INIT (0x48 = 'H') — quantum-resistant hybrid X3DH session open:
///     [1=0x48][32 IK][32 EK]
///     [2 kyber_cipher_len][kyber_cipher_bytes]
///     [2 CA_len][ContactAddress_v2_bytes]
///     [PhantomEnvelope]
///     Kyber-768 ciphertext (1088 bytes) is transmitted so the receiver can
///     decapsulate and combine with the X3DH secret via HKDF.
///
///   MSG  (0x4D = 'M') — subsequent Double Ratchet messages:
///     [1=0x4D][PhantomEnvelope]
///
/// The PhantomEnvelope is always opaque (encrypted + MACed).

const int _kInit       = 0x49; // 'I'
const int _kHybridInit = 0x48; // 'H'
const int _kMsg        = 0x4D; // 'M'

class WireFrame {
  const WireFrame._();

  static Uint8List wrapInit({
    required Uint8List senderIdentityKeyBytes,    // 32-byte X25519 pub
    required Uint8List senderEphemeralKeyBytes,   // 32-byte X25519 pub
    required Uint8List senderContactAddressBytes, // 165-byte ContactAddress
    required Uint8List envelopeBytes,
  }) {
    assert(senderIdentityKeyBytes.length == 32);
    assert(senderEphemeralKeyBytes.length == 32);
    assert(senderContactAddressBytes.length == 165);
    final out = Uint8List(1 + 32 + 32 + 165 + envelopeBytes.length);
    out[0] = _kInit;
    out.setRange(1,   33,  senderIdentityKeyBytes);
    out.setRange(33,  65,  senderEphemeralKeyBytes);
    out.setRange(65,  230, senderContactAddressBytes);
    out.setRange(230, out.length, envelopeBytes);
    return out;
  }

  /// Hybrid INIT frame carrying a Kyber-768 ciphertext alongside X3DH data.
  ///
  /// Format: [1='H'][32 IK][32 EK][2 kyber_len][kyber_cipher][2 CA_len][CA][payload]
  static Uint8List wrapHybridInit({
    required Uint8List senderIdentityKeyBytes,    // 32-byte X25519 pub
    required Uint8List senderEphemeralKeyBytes,   // 32-byte X25519 pub
    required Uint8List kyberCipherBytes,          // 1088 bytes for Kyber-768
    required Uint8List senderContactAddressBytes, // 1349 bytes for CA v2
    required Uint8List envelopeBytes,
  }) {
    assert(senderIdentityKeyBytes.length  == 32);
    assert(senderEphemeralKeyBytes.length == 32);

    final kyberLen = kyberCipherBytes.length;
    final caLen    = senderContactAddressBytes.length;

    final buf = BytesBuilder();
    buf.addByte(_kHybridInit);
    buf.add(senderIdentityKeyBytes);
    buf.add(senderEphemeralKeyBytes);

    final klBuf = ByteData(2)..setUint16(0, kyberLen, Endian.big);
    buf.add(klBuf.buffer.asUint8List());
    buf.add(kyberCipherBytes);

    final caLenBuf = ByteData(2)..setUint16(0, caLen, Endian.big);
    buf.add(caLenBuf.buffer.asUint8List());
    buf.add(senderContactAddressBytes);

    buf.add(envelopeBytes);
    return buf.toBytes();
  }

  static Uint8List wrapMsg({required Uint8List envelopeBytes}) {
    final out = Uint8List(1 + envelopeBytes.length);
    out[0] = _kMsg;
    out.setRange(1, out.length, envelopeBytes);
    return out;
  }

  /// Parse a frame from wire bytes.
  /// Falls back to treating unrecognized bytes as a bare MSG payload
  /// for backward-compatibility with any pre-frame messages.
  static ParsedFrame parse(Uint8List bytes) {
    if (bytes.isEmpty) throw const FrameException('Empty frame');
    final type = bytes[0];

    if (type == _kInit) {
      // Minimum: 1 + 32 + 32 + 165 = 230 bytes header
      if (bytes.length < 230) {
        throw FrameException('INIT frame too short: ${bytes.length}');
      }
      return ParsedFrame._(
        isInit:    true,
        isHybrid:  false,
        senderIdentityKeyBytes:    Uint8List.fromList(bytes.sublist(1,   33)),
        senderEphemeralKeyBytes:   Uint8List.fromList(bytes.sublist(33,  65)),
        senderContactAddressBytes: Uint8List.fromList(bytes.sublist(65,  230)),
        payload:                   Uint8List.fromList(bytes.sublist(230)),
      );

    } else if (type == _kHybridInit) {
      // [1='H'][32 IK][32 EK][2 kyber_len][kyber][2 CA_len][CA][payload]
      const base = 1 + 32 + 32; // 65
      if (bytes.length < base + 4) {
        throw FrameException('HYBRID_INIT frame too short: ${bytes.length}');
      }
      final bd = ByteData.sublistView(bytes);
      int offset = base;

      final kyberLen = bd.getUint16(offset, Endian.big);
      offset += 2;
      if (bytes.length < offset + kyberLen + 2) {
        throw const FrameException('HYBRID_INIT Kyber cipher truncated');
      }
      final kyberCipher = Uint8List.fromList(bytes.sublist(offset, offset + kyberLen));
      offset += kyberLen;

      final caLen = bd.getUint16(offset, Endian.big);
      offset += 2;
      if (bytes.length < offset + caLen) {
        throw const FrameException('HYBRID_INIT ContactAddress truncated');
      }
      final ca      = Uint8List.fromList(bytes.sublist(offset, offset + caLen));
      offset       += caLen;
      final payload = Uint8List.fromList(bytes.sublist(offset));

      return ParsedFrame._(
        isInit:    true,
        isHybrid:  true,
        senderIdentityKeyBytes:    Uint8List.fromList(bytes.sublist(1, 33)),
        senderEphemeralKeyBytes:   Uint8List.fromList(bytes.sublist(33, 65)),
        kyberCipherBytes:          kyberCipher,
        senderContactAddressBytes: ca,
        payload:                   payload,
      );

    } else if (type == _kMsg) {
      return ParsedFrame._(
        isInit:   false,
        isHybrid: false,
        payload:  Uint8List.fromList(bytes.sublist(1)),
      );
    } else {
      // Unrecognized frame type — treat entire buffer as bare envelope.
      return ParsedFrame._(isInit: false, isHybrid: false, payload: bytes);
    }
  }
}

class ParsedFrame {
  final bool isInit;
  /// True when the frame is a HYBRID_INIT (Kyber-768 + X3DH).
  final bool isHybrid;
  final Uint8List? senderIdentityKeyBytes;
  final Uint8List? senderEphemeralKeyBytes;
  /// Raw ContactAddress bytes (v1=165 B, v2=1349 B). Present on INIT frames only.
  final Uint8List? senderContactAddressBytes;
  /// Kyber-768 ciphertext (1088 bytes). Present on HYBRID_INIT frames only.
  final Uint8List? kyberCipherBytes;
  final Uint8List payload;

  ParsedFrame._({
    required this.isInit,
    required this.isHybrid,
    this.senderIdentityKeyBytes,
    this.senderEphemeralKeyBytes,
    this.senderContactAddressBytes,
    this.kyberCipherBytes,
    required this.payload,
  });

  /// Derives the sender's PhantomID from their identity key bytes.
  String get senderPhantomId {
    assert(isInit && senderIdentityKeyBytes != null);
    final idPayload = Uint8List(33)
      ..[0] = 0x50
      ..setRange(1, 33, senderIdentityKeyBytes!);
    return bs58check.encode(idPayload);
  }
}

class FrameException implements Exception {
  final String message;
  const FrameException(this.message);
  @override
  String toString() => 'FrameException: $message';
}

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

const int _kInit            = 0x49; // 'I'
const int _kHybridInit      = 0x48; // 'H'
const int _kHybridInitOpk   = 0x47; // 'G' — hybrid INIT carrying a one-time prekey id
/// Hybrid INIT carrying OPK + sender's current transport endpoints
/// (I2P destination, IPFS peer id, Yggdrasil address) as a cleartext
/// trailer. Lets the receiver refresh their stale contact record before
/// they send the handshakeAck back — fixes the case where the peer
/// imported our ContactAddress when we had different addresses.
const int _kHybridInitFull  = 0x46; // 'F'
const int _kMsg             = 0x4D; // 'M'

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

  /// Hybrid INIT carrying a one-time prekey id consumed by the responder.
  ///
  /// Format: [1='G'][32 IK][32 EK][2 kyber_len][kyber][2 CA_len][CA][4 opk_id][payload]
  static Uint8List wrapHybridInitWithOpk({
    required Uint8List senderIdentityKeyBytes,
    required Uint8List senderEphemeralKeyBytes,
    required Uint8List kyberCipherBytes,
    required Uint8List senderContactAddressBytes,
    required int opkId,
    required Uint8List envelopeBytes,
  }) {
    assert(senderIdentityKeyBytes.length  == 32);
    assert(senderEphemeralKeyBytes.length == 32);
    assert(opkId >= 0 && opkId <= 0xFFFFFFFF);

    final kyberLen = kyberCipherBytes.length;
    final caLen    = senderContactAddressBytes.length;

    final buf = BytesBuilder();
    buf.addByte(_kHybridInitOpk);
    buf.add(senderIdentityKeyBytes);
    buf.add(senderEphemeralKeyBytes);

    final klBuf = ByteData(2)..setUint16(0, kyberLen, Endian.big);
    buf.add(klBuf.buffer.asUint8List());
    buf.add(kyberCipherBytes);

    final caLenBuf = ByteData(2)..setUint16(0, caLen, Endian.big);
    buf.add(caLenBuf.buffer.asUint8List());
    buf.add(senderContactAddressBytes);

    final opkBuf = ByteData(4)..setUint32(0, opkId, Endian.big);
    buf.add(opkBuf.buffer.asUint8List());

    buf.add(envelopeBytes);
    return buf.toBytes();
  }

  /// Hybrid INIT carrying OPK + sender's current transport endpoints.
  ///
  /// Format:
  ///   [1='F'][32 IK][32 EK]
  ///   [2 kyber_len][kyber]
  ///   [2 CA_len][CA]
  ///   [4 opk_id]
  ///   [2 i2p_len][i2p_dest]            // empty → 0-length
  ///   [2 ipfs_len][ipfs_peer_id]       // empty → 0-length
  ///   [2 ygg_len][ygg_addr]            // empty → 0-length
  ///   [payload]
  ///
  /// Endpoint strings are ASCII (UTF-8 fits trivially); the receiver uses
  /// them to refresh their saved contact record before sending the
  /// handshakeAck back, which fixes the "stale dest after peer reinstall"
  /// dead-letter problem on the very first round trip.
  static Uint8List wrapHybridInitFull({
    required Uint8List senderIdentityKeyBytes,
    required Uint8List senderEphemeralKeyBytes,
    required Uint8List kyberCipherBytes,
    required Uint8List senderContactAddressBytes,
    required int opkId,
    required String senderI2pDest,
    required String senderIpfsPeerId,
    required String senderYggAddr,
    required Uint8List envelopeBytes,
  }) {
    assert(senderIdentityKeyBytes.length  == 32);
    assert(senderEphemeralKeyBytes.length == 32);
    assert(opkId >= 0 && opkId <= 0xFFFFFFFF);

    final kyberLen = kyberCipherBytes.length;
    final caLen    = senderContactAddressBytes.length;
    final i2pBytes  = senderI2pDest.codeUnits;
    final ipfsBytes = senderIpfsPeerId.codeUnits;
    final yggBytes  = senderYggAddr.codeUnits;
    assert(i2pBytes.length  <= 0xFFFF);
    assert(ipfsBytes.length <= 0xFFFF);
    assert(yggBytes.length  <= 0xFFFF);

    final buf = BytesBuilder();
    buf.addByte(_kHybridInitFull);
    buf.add(senderIdentityKeyBytes);
    buf.add(senderEphemeralKeyBytes);

    buf.add((ByteData(2)..setUint16(0, kyberLen, Endian.big)).buffer.asUint8List());
    buf.add(kyberCipherBytes);

    buf.add((ByteData(2)..setUint16(0, caLen, Endian.big)).buffer.asUint8List());
    buf.add(senderContactAddressBytes);

    buf.add((ByteData(4)..setUint32(0, opkId, Endian.big)).buffer.asUint8List());

    buf.add((ByteData(2)..setUint16(0, i2pBytes.length, Endian.big)).buffer.asUint8List());
    buf.add(i2pBytes);

    buf.add((ByteData(2)..setUint16(0, ipfsBytes.length, Endian.big)).buffer.asUint8List());
    buf.add(ipfsBytes);

    buf.add((ByteData(2)..setUint16(0, yggBytes.length, Endian.big)).buffer.asUint8List());
    buf.add(yggBytes);

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

    } else if (type == _kHybridInit ||
               type == _kHybridInitOpk ||
               type == _kHybridInitFull) {
      // 'H': [1][32 IK][32 EK][2 kyber_len][kyber][2 CA_len][CA][payload]
      // 'G': 'H' format + [4 opk_id] before payload
      // 'F': 'G' format + [2 i2p_len][i2p][2 ipfs_len][ipfs][2 ygg_len][ygg]
      //      before payload
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
      final ca = Uint8List.fromList(bytes.sublist(offset, offset + caLen));
      offset  += caLen;

      int? opkId;
      if (type == _kHybridInitOpk || type == _kHybridInitFull) {
        if (bytes.length < offset + 4) {
          throw const FrameException('HYBRID_INIT_OPK opk_id truncated');
        }
        opkId = bd.getUint32(offset, Endian.big);
        offset += 4;
      }

      String? senderI2pDest;
      String? senderIpfsPeerId;
      String? senderYggAddr;
      if (type == _kHybridInitFull) {
        for (final assign in <void Function(String)>[
          (v) => senderI2pDest = v,
          (v) => senderIpfsPeerId = v,
          (v) => senderYggAddr = v,
        ]) {
          if (bytes.length < offset + 2) {
            throw const FrameException('HYBRID_INIT_FULL endpoint length truncated');
          }
          final len = bd.getUint16(offset, Endian.big);
          offset += 2;
          if (bytes.length < offset + len) {
            throw const FrameException('HYBRID_INIT_FULL endpoint truncated');
          }
          assign(String.fromCharCodes(bytes.sublist(offset, offset + len)));
          offset += len;
        }
      }

      final payload = Uint8List.fromList(bytes.sublist(offset));

      return ParsedFrame._(
        isInit:    true,
        isHybrid:  true,
        senderIdentityKeyBytes:    Uint8List.fromList(bytes.sublist(1, 33)),
        senderEphemeralKeyBytes:   Uint8List.fromList(bytes.sublist(33, 65)),
        kyberCipherBytes:          kyberCipher,
        senderContactAddressBytes: ca,
        opkId:                     opkId,
        senderI2pDest:             senderI2pDest,
        senderIpfsPeerId:          senderIpfsPeerId,
        senderYggAddr:             senderYggAddr,
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
  /// Raw ContactAddress bytes (v1=165 B, v2=1349 B, v3=1413 B). Present on INIT frames only.
  final Uint8List? senderContactAddressBytes;
  /// Kyber-768 ciphertext (1088 bytes). Present on HYBRID_INIT frames only.
  final Uint8List? kyberCipherBytes;
  /// One-time prekey id consumed for X3DH DH4. Present on HYBRID_INIT_OPK only.
  final int? opkId;
  /// Sender's current I2P destination. Present on HYBRID_INIT_FULL only.
  /// Used by the receiver to refresh their saved contact record before
  /// sending the handshakeAck back — so the ack goes to the live dest
  /// even if the original ContactAddress import is stale.
  final String? senderI2pDest;
  /// Sender's current IPFS peer id. Same purpose as [senderI2pDest].
  final String? senderIpfsPeerId;
  /// Sender's current Yggdrasil IPv6 address. Same purpose as [senderI2pDest].
  final String? senderYggAddr;
  final Uint8List payload;

  ParsedFrame._({
    required this.isInit,
    required this.isHybrid,
    this.senderIdentityKeyBytes,
    this.senderEphemeralKeyBytes,
    this.senderContactAddressBytes,
    this.kyberCipherBytes,
    this.opkId,
    this.senderI2pDest,
    this.senderIpfsPeerId,
    this.senderYggAddr,
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

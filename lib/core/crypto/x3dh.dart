import 'dart:convert';
import 'dart:typed_data';
import 'package:bs58check/bs58check.dart' as bs58check;
import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';
import 'hybrid_kem.dart';

/// Extended Triple Diffie-Hellman (X3DH) — Signal Protocol.
///
/// Flow (Alice → Bob):
///   1. Alice gets Bob's PreKeyBundle (ContactAddress)
///   2. Alice generates ephemeral keypair EK_A
///   3. DH1 = DH(IK_A,  SPK_B)
///      DH2 = DH(EK_A,  IK_B)
///      DH3 = DH(EK_A,  SPK_B)
///      DH4 = DH(EK_A,  OPK_B)  [if OPK available]
///   4. SK = KDF(DH1 || DH2 || DH3 [|| DH4])
///   5. Alice sends: IK_A, EK_A, OPK_B_id, first encrypted message
///   6. Bob recomputes SK and inits Double Ratchet

// ── PreKeyBundle ──────────────────────────────────────────────────────────────

@immutable
class PreKeyBundle {
  /// X25519 identity public key — used in DH2 (DH(EK_A, IK_B)).
  final Uint8List identityKeyBytes;

  /// Ed25519 signing public key — used ONLY to verify the SPK signature.
  /// Separate from identityKeyBytes because X25519 and Ed25519 are different curves.
  final Uint8List signingKeyBytes;

  /// X25519 Signed PreKey — used in DH1 and DH3.
  final Uint8List signedPreKeyBytes;
  final int signedPreKeyId;

  /// Ed25519 signature of signedPreKeyBytes, signed with signingKeyBytes.
  final Uint8List signedPreKeySignature;

  /// Optional one-time prekeys (each used exactly once).
  final List<({int id, Uint8List keyBytes})> oneTimePreKeys;

  /// Optional Kyber-768 public key (1184 bytes). Present only for accounts
  /// that have been initialised with quantum-resistant key generation.
  final Uint8List? kyber768PublicKeyBytes;

  const PreKeyBundle({
    required this.identityKeyBytes,
    required this.signingKeyBytes,
    required this.signedPreKeyBytes,
    required this.signedPreKeyId,
    required this.signedPreKeySignature,
    required this.oneTimePreKeys,
    this.kyber768PublicKeyBytes,
  });

  Map<String, dynamic> toJson() => {
        'ik':     _hex(identityKeyBytes),
        'sk':     _hex(signingKeyBytes),
        'spk':    _hex(signedPreKeyBytes),
        'spk_id': signedPreKeyId,
        'sig':    _hex(signedPreKeySignature),
        'opks':   oneTimePreKeys
            .map((e) => {'id': e.id, 'key': _hex(e.keyBytes)})
            .toList(),
        if (kyber768PublicKeyBytes != null)
          'kyber768_pk': _hex(kyber768PublicKeyBytes!),
      };

  static PreKeyBundle fromJson(Map<String, dynamic> j) => PreKeyBundle(
        identityKeyBytes:       _unhex(j['ik']  as String),
        signingKeyBytes:        _unhex(j['sk']  as String),
        signedPreKeyBytes:      _unhex(j['spk'] as String),
        signedPreKeyId:         j['spk_id'] as int,
        signedPreKeySignature:  _unhex(j['sig'] as String),
        oneTimePreKeys: (j['opks'] as List)
            .map((e) => (
                  id: e['id'] as int,
                  keyBytes: _unhex(e['key'] as String),
                ))
            .toList(),
        kyber768PublicKeyBytes: j['kyber768_pk'] != null
            ? _unhex(j['kyber768_pk'] as String)
            : null,
      );
}

// ── ContactAddress — what gets shared between users ───────────────────────────

/// Compact binary-encoded bundle of everything needed to initiate a session.
///
/// Wire format v1 (165 bytes → base64url ~220 chars):
///   [1 version=0x01][32 x25519_ik][32 ed25519_sk][32 spk][4 spk_id][64 sig]
///
/// Wire format v2 — with Kyber-768 public key (1349 bytes → ~1800 chars):
///   [1 version=0x02][32 x25519_ik][32 ed25519_sk][32 spk][4 spk_id][64 sig]
///   [1184 kyber768_pk]
///
/// The PhantomID is DERIVED from x25519_ik so it is not stored separately.
@immutable
class ContactAddress {
  final Uint8List x25519IdentityKey;      // 32 bytes
  final Uint8List ed25519SigningKey;      // 32 bytes
  final Uint8List signedPreKeyBytes;      // 32 bytes
  final int       signedPreKeyId;
  final Uint8List signature;              // 64 bytes
  /// Kyber-768 public key (1184 bytes). Null for v1 addresses.
  final Uint8List? kyber768PublicKeyBytes;

  static const _v1Len = 165;
  static const _v2Len = 1349; // 165 + 1184

  const ContactAddress({
    required this.x25519IdentityKey,
    required this.ed25519SigningKey,
    required this.signedPreKeyBytes,
    required this.signedPreKeyId,
    required this.signature,
    this.kyber768PublicKeyBytes,
  });

  /// PhantomID derived from the X25519 identity key.
  String get phantomId {
    final payload = Uint8List(33)
      ..[0] = 0x50
      ..setRange(1, 33, x25519IdentityKey);
    return bs58check.encode(payload);
  }

  PreKeyBundle get bundle => PreKeyBundle(
        identityKeyBytes:       x25519IdentityKey,
        signingKeyBytes:        ed25519SigningKey,
        signedPreKeyBytes:      signedPreKeyBytes,
        signedPreKeyId:         signedPreKeyId,
        signedPreKeySignature:  signature,
        oneTimePreKeys:         const [],
        kyber768PublicKeyBytes: kyber768PublicKeyBytes,
      );

  String encode() {
    if (kyber768PublicKeyBytes != null) {
      // v2: 1349 bytes
      final buf = ByteData(_v2Len);
      buf.setUint8(0, 0x02);
      _setBytes(buf, 1,   x25519IdentityKey,       32);
      _setBytes(buf, 33,  ed25519SigningKey,         32);
      _setBytes(buf, 65,  signedPreKeyBytes,         32);
      buf.setUint32(97, signedPreKeyId, Endian.big);
      _setBytes(buf, 101, signature,                 64);
      _setBytes(buf, 165, kyber768PublicKeyBytes!, 1184);
      return base64Url.encode(buf.buffer.asUint8List()).replaceAll('=', '');
    } else {
      // v1: 165 bytes
      final buf = ByteData(_v1Len);
      buf.setUint8(0, 0x01);
      _setBytes(buf, 1,   x25519IdentityKey, 32);
      _setBytes(buf, 33,  ed25519SigningKey,  32);
      _setBytes(buf, 65,  signedPreKeyBytes,  32);
      buf.setUint32(97, signedPreKeyId, Endian.big);
      _setBytes(buf, 101, signature,          64);
      return base64Url.encode(buf.buffer.asUint8List()).replaceAll('=', '');
    }
  }

  static ContactAddress decode(String s) {
    try {
      final padded = s.padRight(s.length + (4 - s.length % 4) % 4, '=');
      final bytes  = base64Url.decode(padded);
      if (bytes.length < _v1Len) {
        throw const FormatException('ContactAddress too short');
      }
      final view = ByteData.sublistView(Uint8List.fromList(bytes));
      final version = bytes[0];

      if (version == 0x01) {
        return ContactAddress(
          x25519IdentityKey: Uint8List.fromList(bytes.sublist(1,   33)),
          ed25519SigningKey:  Uint8List.fromList(bytes.sublist(33,  65)),
          signedPreKeyBytes:  Uint8List.fromList(bytes.sublist(65,  97)),
          signedPreKeyId:     view.getUint32(97, Endian.big),
          signature:          Uint8List.fromList(bytes.sublist(101, 165)),
        );
      } else if (version == 0x02 && bytes.length >= _v2Len) {
        return ContactAddress(
          x25519IdentityKey:       Uint8List.fromList(bytes.sublist(1,    33)),
          ed25519SigningKey:        Uint8List.fromList(bytes.sublist(33,   65)),
          signedPreKeyBytes:        Uint8List.fromList(bytes.sublist(65,   97)),
          signedPreKeyId:           view.getUint32(97, Endian.big),
          signature:                Uint8List.fromList(bytes.sublist(101,  165)),
          kyber768PublicKeyBytes:   Uint8List.fromList(bytes.sublist(165, 1349)),
        );
      } else {
        throw const FormatException('Unknown ContactAddress version');
      }
    } catch (e) {
      throw InvalidPhantomIdException('Invalid contact address: $e');
    }
  }

  static void _setBytes(ByteData buf, int offset, Uint8List src, int len) {
    for (int i = 0; i < len; i++) {
      buf.setUint8(offset + i, src[i]);
    }
  }
}

// ── X3DH Initiator (Alice) ────────────────────────────────────────────────────

@immutable
class X3DHInitResult {
  final Uint8List sharedSecret;
  final Uint8List ephemeralPublicKeyBytes;
  final int? usedOneTimePreKeyId;

  /// Kyber-768 ciphertext to send in the INIT frame (null if classical only).
  final Uint8List? kyberCipherBytes;

  /// Combined hybrid session key (null if classical only).
  /// When non-null, use this as the Double Ratchet root key instead of [sharedSecret].
  final Uint8List? hybridSecret;

  /// The key to use for Double Ratchet initialisation.
  Uint8List get sessionKey => hybridSecret ?? sharedSecret;

  const X3DHInitResult({
    required this.sharedSecret,
    required this.ephemeralPublicKeyBytes,
    this.usedOneTimePreKeyId,
    this.kyberCipherBytes,
    this.hybridSecret,
  });
}

class X3DHHandshake {
  /// Alice initiates with Bob's bundle.
  static Future<X3DHInitResult> initiate({
    required SimpleKeyPairData ourIdentityKP,
    required PreKeyBundle theirBundle,
  }) async {
    // Verify SPK signature using Bob's Ed25519 signing key (NOT X25519 identity key)
    final valid = await _verifySignedPreKey(
      signingKeyBytes:    theirBundle.signingKeyBytes,
      signedPreKeyBytes:  theirBundle.signedPreKeyBytes,
      signature:          theirBundle.signedPreKeySignature,
    );
    if (!valid) {
      throw const X3DHException('SignedPreKey signature invalid — possible MITM.');
    }

    final ephemeralKP     = await X25519().newKeyPair();
    final ephemeralKPData = await ephemeralKP.extract();
    final ephemeralPub    = await ephemeralKPData.extractPublicKey();

    final opk = theirBundle.oneTimePreKeys.isNotEmpty
        ? theirBundle.oneTimePreKeys.first
        : null;

    // DH computations
    final dh1 = await _dh(ourIdentityKP,  theirBundle.signedPreKeyBytes);  // DH(IK_A, SPK_B)
    final dh2 = await _dh(ephemeralKPData, theirBundle.identityKeyBytes);  // DH(EK_A, IK_B)
    final dh3 = await _dh(ephemeralKPData, theirBundle.signedPreKeyBytes); // DH(EK_A, SPK_B)
    final dh4 = opk != null ? await _dh(ephemeralKPData, opk.keyBytes) : null;

    final sharedSecret = await _kdf(dh1, dh2, dh3, dh4);

    // Hybrid KEM: if the recipient advertises a Kyber-768 public key,
    // encapsulate a random secret to it and mix with the X3DH secret.
    Uint8List? kyberCipher;
    Uint8List? hybridSecret;
    if (theirBundle.kyber768PublicKeyBytes != null) {
      final (cipher, kyberShared) =
          HybridKEM.encapsulate(theirBundle.kyber768PublicKeyBytes!);
      kyberCipher   = cipher;
      hybridSecret  = await HybridKEM.combineSecrets(sharedSecret, kyberShared);
    }

    return X3DHInitResult(
      sharedSecret:            sharedSecret,
      ephemeralPublicKeyBytes: Uint8List.fromList(ephemeralPub.bytes),
      usedOneTimePreKeyId:     opk?.id,
      kyberCipherBytes:        kyberCipher,
      hybridSecret:            hybridSecret,
    );
  }

  /// Bob responds — recomputes the same shared secret.
  static Future<Uint8List> respond({
    required SimpleKeyPairData ourIdentityKP,
    required SimpleKeyPairData ourSignedPreKP,
    SimpleKeyPairData? ourOneTimePreKP,
    required Uint8List theirIdentityKeyBytes,
    required Uint8List theirEphemeralKeyBytes,
  }) async {
    final dh1 = await _dh(ourSignedPreKP,  theirIdentityKeyBytes);   // DH(SPK_B, IK_A)
    final dh2 = await _dh(ourIdentityKP,   theirEphemeralKeyBytes);  // DH(IK_B,  EK_A)
    final dh3 = await _dh(ourSignedPreKP,  theirEphemeralKeyBytes);  // DH(SPK_B, EK_A)
    final dh4 = ourOneTimePreKP != null
        ? await _dh(ourOneTimePreKP, theirEphemeralKeyBytes)
        : null;

    return _kdf(dh1, dh2, dh3, dh4);
  }

  // ── Bundle generation ──────────────────────────────────────────────────────

  static Future<({
    PreKeyBundle bundle,
    List<SimpleKeyPairData> oneTimePreKeyPairs,
    SimpleKeyPairData signedPreKeyPair,
    Uint8List signedPreKeyPublicBytes,
  })> generateBundle({
    required SimpleKeyPairData identityKP,
    required SimpleKeyPairData signingKP,
    int numOneTimePreKeys = 20,
  }) async {
    final x25519 = X25519();

    // Signed PreKey
    final spkKP   = await x25519.newKeyPair();
    final spkData = await spkKP.extract();
    final spkPub  = await spkData.extractPublicKey();

    // Sign with Ed25519 signing key
    final sig = await Ed25519().sign(spkPub.bytes, keyPair: signingKP);

    // One-Time PreKeys
    final opkPairs  = <SimpleKeyPairData>[];
    final opkPublic = <({int id, Uint8List keyBytes})>[];
    for (int i = 0; i < numOneTimePreKeys; i++) {
      final kp    = await x25519.newKeyPair();
      final kpData = await kp.extract();
      final pub   = await kpData.extractPublicKey();
      opkPairs.add(kpData);
      opkPublic.add((id: i, keyBytes: Uint8List.fromList(pub.bytes)));
    }

    final identityPub = await identityKP.extractPublicKey();
    final signingPub  = await signingKP.extractPublicKey();

    return (
      bundle: PreKeyBundle(
        identityKeyBytes:      Uint8List.fromList(identityPub.bytes),
        signingKeyBytes:       Uint8List.fromList(signingPub.bytes),
        signedPreKeyBytes:     Uint8List.fromList(spkPub.bytes),
        signedPreKeyId:        1,
        signedPreKeySignature: Uint8List.fromList(sig.bytes),
        oneTimePreKeys:        opkPublic,
      ),
      oneTimePreKeyPairs:      opkPairs,
      signedPreKeyPair:        spkData,
      signedPreKeyPublicBytes: Uint8List.fromList(spkPub.bytes),
    );
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  static Future<Uint8List> _dh(
      SimpleKeyPairData ourKP, Uint8List theirPubBytes) async {
    final theirPub = SimplePublicKey(theirPubBytes, type: KeyPairType.x25519);
    final shared   = await X25519().sharedSecretKey(
      keyPair: ourKP,
      remotePublicKey: theirPub,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  static Future<Uint8List> _kdf(
    Uint8List dh1,
    Uint8List dh2,
    Uint8List dh3,
    Uint8List? dh4,
  ) async {
    // F: 32 × 0xFF domain separator (Signal spec)
    final f = Uint8List(32)..fillRange(0, 32, 0xFF);
    final dhMaterial = Uint8List.fromList([
      ...dh1, ...dh2, ...dh3,
      if (dh4 != null) ...dh4,
    ]);
    final input = Uint8List.fromList([...f, ...dhMaterial]);

    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
    final out  = await hkdf.deriveKey(
      secretKey: SecretKey(input),
      nonce: Uint8List(0),
      info: Uint8List.fromList('phantom-x3dh-v1'.codeUnits),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  static Future<bool> _verifySignedPreKey({
    required Uint8List signingKeyBytes,
    required Uint8List signedPreKeyBytes,
    required Uint8List signature,
  }) async {
    try {
      final pub = SimplePublicKey(signingKeyBytes, type: KeyPairType.ed25519);
      return await Ed25519().verify(
        signedPreKeyBytes,
        signature: Signature(signature, publicKey: pub),
      );
    } catch (_) {
      return false;
    }
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) {
  final r = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < r.length; i++) {
    r[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return r;
}

class X3DHException implements Exception {
  final String message;
  const X3DHException(this.message);
  @override
  String toString() => 'X3DHException: $message';
}

class InvalidPhantomIdException implements Exception {
  final String message;
  const InvalidPhantomIdException(this.message);
  @override
  String toString() => 'InvalidPhantomIdException: $message';
}

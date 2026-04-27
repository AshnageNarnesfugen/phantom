import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:post_quantum/kyber.dart';

/// Kyber-768 + X25519 hybrid KEM.
///
/// Security guarantee: an attacker must break BOTH X25519 (classical) AND
/// Kyber-768 (post-quantum) to recover the session key. Used only during
/// the initial X3DH session establishment — the subsequent Double Ratchet
/// symmetric layer (ChaCha20-Poly1305) is already quantum-resistant.
///
/// Key sizes (Kyber-768, k=3):
///   public key : 1184 bytes
///   private key: 2400 bytes
///   ciphertext : 1088 bytes
///   shared secret: 32 bytes
class HybridKEM {
  HybridKEM._();

  static const _kyberVersion = 3; // Kyber-768 (k=3)
  static final _kyber = Kyber.kem768();

  // ── Key derivation ─────────────────────────────────────────────────────────

  /// Derives a deterministic 64-byte seed for Kyber key generation from the
  /// BIP39 seed phrase. Domain-separated from all other HKDF uses.
  static Future<Uint8List> deriveKyberSeed(String seedPhrase) async {
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 64);
    final out  = await hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(seedPhrase)),
      nonce: Uint8List.fromList(utf8.encode('phantom-kyber-v1')),
      info:  Uint8List.fromList(utf8.encode('phantom-kyber768-keypair')),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  // ── Core KEM operations ────────────────────────────────────────────────────

  /// Generate a Kyber-768 keypair from a 64-byte deterministic seed.
  /// Returns `(publicKeyBytes, privateKeyBytes)`.
  static (Uint8List pkBytes, Uint8List skBytes) generateKeys(Uint8List seed64) {
    assert(seed64.length == 64, 'Kyber seed must be exactly 64 bytes');
    final (pk, sk) = _kyber.generateKeys(seed64);
    return (pk.serialize(), sk.serialize());
  }

  /// Encapsulate: generate a shared secret and encrypt it to [kyberPkBytes].
  /// Returns `(ciphertextBytes, sharedSecret32)`.
  /// The ciphertext must be transmitted to the receiver so they can decapsulate.
  static (Uint8List cipherBytes, Uint8List secret32) encapsulate(
      Uint8List kyberPkBytes) {
    final pk    = KemPublicKey.deserialize(kyberPkBytes, _kyberVersion);
    final nonce = _randomBytes(32);
    final (cipher, secret) = _kyber.encapsulate(pk, nonce);
    return (cipher.serialize(), Uint8List.fromList(secret));
  }

  /// Decapsulate: recover the 32-byte shared secret from [cipherBytes]
  /// using [kyberSkBytes].
  static Uint8List decapsulate(
      Uint8List cipherBytes, Uint8List kyberSkBytes) {
    final cipher = PKECypher.deserialize(cipherBytes, _kyberVersion);
    final sk     = KemPrivateKey.deserialize(kyberSkBytes, _kyberVersion);
    return Uint8List.fromList(_kyber.decapsulate(cipher, sk));
  }

  // ── Hybrid combining ───────────────────────────────────────────────────────

  /// Combine the classical X3DH secret and the Kyber-768 secret into a single
  /// 32-byte hybrid session key via HKDF-SHA512.
  ///
  /// IKM = x3dhSecret || kyberSecret  (64 bytes total)
  static Future<Uint8List> combineSecrets(
      Uint8List x3dhSecret, Uint8List kyberSecret) async {
    assert(x3dhSecret.length == 32, 'X3DH secret must be 32 bytes');
    assert(kyberSecret.length == 32, 'Kyber shared secret must be 32 bytes');
    final ikm = Uint8List(64)
      ..setRange(0,  32, x3dhSecret)
      ..setRange(32, 64, kyberSecret);

    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
    final out  = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: Uint8List.fromList(utf8.encode('phantom-hybrid-v1')),
      info:  Uint8List.fromList(utf8.encode('phantom-x3dh-kyber768')),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  static Uint8List _randomBytes(int count) {
    final rng = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(count, (_) => rng.nextInt(256)));
  }
}

import 'dart:typed_data';
import 'package:bip39/bip39.dart' as bip39;
import 'package:ed25519_hd_key/ed25519_hd_key.dart';
import 'package:cryptography/cryptography.dart';
import 'package:bs58check/bs58check.dart' as bs58check;
import 'package:meta/meta.dart';

/// Phantom identity derived deterministically from a BIP39 seed phrase.
///
/// Derivation flow:
///   seed phrase (12/24 words)
///     → entropy (512 bits via PBKDF2)
///       → Ed25519 keypair (signing)
///         → X25519 keypair (Diffie-Hellman / encryption)
///           → PhantomID (base58check of X25519 public key)
///
/// The seed phrase is the ONLY credential. No email, no phone number, no server.
@immutable
class PhantomIdentity {
  /// Ed25519 private key (for signing messages).
  final SimpleKeyPairData signingKeyPair;

  /// X25519 private key (for DH / E2E encryption).
  final SimpleKeyPairData encryptionKeyPair;

  /// Public ID — what you share with other users.
  /// Format: base58check of X25519 public key (43-44 chars).
  final String phantomId;

  /// X25519 public key bytes (for DH).
  final Uint8List encryptionPublicKeyBytes;

  /// Ed25519 public key bytes (for signature verification).
  final Uint8List signingPublicKeyBytes;

  const PhantomIdentity._({
    required this.signingKeyPair,
    required this.encryptionKeyPair,
    required this.phantomId,
    required this.encryptionPublicKeyBytes,
    required this.signingPublicKeyBytes,
  });

  /// Generates a NEW identity with a random seed phrase.
  static Future<({PhantomIdentity identity, String seedPhrase})>
      generateNew() async {
    final mnemonic = bip39.generateMnemonic(strength: 256); // 24 words
    final identity = await fromSeedPhrase(mnemonic);
    return (identity: identity, seedPhrase: mnemonic);
  }

  /// Restores an existing identity from a seed phrase.
  /// Throws [InvalidSeedPhraseException] if the phrase is invalid.
  static Future<PhantomIdentity> fromSeedPhrase(String seedPhrase) async {
    final normalized = seedPhrase.trim().toLowerCase();
    if (!bip39.validateMnemonic(normalized)) {
      throw const InvalidSeedPhraseException(
        'Invalid seed phrase: check the words and their order.',
      );
    }

    // BIP39 → 512-bit seed
    final seedBytes = Uint8List.fromList(bip39.mnemonicToSeed(normalized));

    // Derive Ed25519 signing keypair via BIP32-Ed25519
    // Path: m/phantom'/0'/signing' (hardened)
    final signingRaw = await _deriveEd25519(seedBytes, "m/44'/7331'/0'/0'");

    // Derive X25519 encryption keypair
    // Path: m/phantom'/0'/encryption' (hardened, distinct path)
    final encryptionRaw = await _deriveX25519FromSeed(seedBytes, "m/44'/7331'/0'/1");

    // Build keypairs using the cryptography library
    final edAlgo = Ed25519();
    final signingKP = await edAlgo.newKeyPairFromSeed(signingRaw);

    final x25519Algo = X25519();
    final encryptionKP = await x25519Algo.newKeyPairFromSeed(encryptionRaw);

    // Extract public keys as bytes
    final signingPub = await signingKP.extractPublicKey();
    final encryptionPub = await encryptionKP.extractPublicKey();

    final signingPubBytes = Uint8List.fromList(signingPub.bytes);
    final encryptionPubBytes = Uint8List.fromList(encryptionPub.bytes);

    // PhantomID = base58check(version_byte + X25519_public_key)
    // Version byte 0x50 ('P' for Phantom)
    final idPayload = Uint8List(33);
    idPayload[0] = 0x50;
    idPayload.setRange(1, 33, encryptionPubBytes);
    final phantomId = bs58check.encode(idPayload);

    return PhantomIdentity._(
      signingKeyPair: await signingKP.extract(),
      encryptionKeyPair: await encryptionKP.extract(),
      phantomId: phantomId,
      encryptionPublicKeyBytes: encryptionPubBytes,
      signingPublicKeyBytes: signingPubBytes,
    );
  }

  /// Decodes a PhantomID and extracts the X25519 public key.
  /// Throws [InvalidPhantomIdException] if the ID is invalid.
  static Uint8List decodeId(String phantomId) {
    try {
      final decoded = bs58check.decode(phantomId);
      if (decoded.length != 33 || decoded[0] != 0x50) {
        throw const InvalidPhantomIdException('ID has incorrect format.');
      }
      return Uint8List.fromList(decoded.sublist(1));
    } catch (e) {
      throw InvalidPhantomIdException('Invalid PhantomID: $e');
    }
  }

  // ── Key derivation ────────────────────────────────────────────────────────

  /// Derives 32 bytes for Ed25519 using ed25519_hd_key (BIP32-Ed25519).
  static Future<Uint8List> _deriveEd25519(
      Uint8List seed, String path) async {
    final key = await ED25519_HD_KEY.derivePath(path, seed);
    return Uint8List.fromList(key.key);
  }

  /// Derives 32 bytes for X25519 using HKDF from the BIP39 seed.
  /// X25519 has no standard HD derivation, so we use HKDF with
  /// the path as "info" for domain separation.
  static Future<Uint8List> _deriveX25519FromSeed(
      Uint8List seed, String path) async {
    final hkdf = Hkdf(
      hmac: Hmac(Sha512()),
      outputLength: 32,
    );
    final secretKey = SecretKey(seed);
    final output = await hkdf.deriveKey(
      secretKey: secretKey,
      nonce: Uint8List(0), // no salt — seed already has high entropy
      info: Uint8List.fromList('phantom-x25519-$path'.codeUnits),
    );
    return Uint8List.fromList(await output.extractBytes());
  }

  @override
  String toString() => 'PhantomIdentity(id: $phantomId)';
}

// ── Exceptions ───────────────────────────────────────────────────────────────

class InvalidSeedPhraseException implements Exception {
  final String message;
  const InvalidSeedPhraseException(this.message);
  @override
  String toString() => 'InvalidSeedPhraseException: $message';
}

class InvalidPhantomIdException implements Exception {
  final String message;
  const InvalidPhantomIdException(this.message);
  @override
  String toString() => 'InvalidPhantomIdException: $message';
}

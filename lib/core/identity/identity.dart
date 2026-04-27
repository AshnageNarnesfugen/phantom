import 'dart:typed_data';
import 'package:bip39/bip39.dart' as bip39;
import 'package:ed25519_hd_key/ed25519_hd_key.dart';
import 'package:cryptography/cryptography.dart';
import 'package:bs58check/bs58check.dart' as bs58check;
import 'package:meta/meta.dart';

/// Phantom identity derivada deterministicamente desde una seed phrase BIP39.
///
/// Flujo:
///   seed phrase (12/24 palabras)
///     → entropy (512 bits via PBKDF2)
///       → Ed25519 keypair (signing)
///         → X25519 keypair (Diffie-Hellman / cifrado)
///           → PhantomID (base58check del public key X25519)
///
/// La seed phrase es la ÚNICA credencial. Sin email, sin número, sin servidor.
@immutable
class PhantomIdentity {
  /// Clave privada Ed25519 (para firmar mensajes).
  final SimpleKeyPairData signingKeyPair;

  /// Clave privada X25519 (para DH / cifrado E2E).
  final SimpleKeyPairData encryptionKeyPair;

  /// ID público — lo que compartes con otros usuarios.
  /// Formato: base58check del public key X25519 (43-44 chars).
  final String phantomId;

  /// Public key X25519 en bytes (para DH).
  final Uint8List encryptionPublicKeyBytes;

  /// Public key Ed25519 en bytes (para verificar firmas).
  final Uint8List signingPublicKeyBytes;

  const PhantomIdentity._({
    required this.signingKeyPair,
    required this.encryptionKeyPair,
    required this.phantomId,
    required this.encryptionPublicKeyBytes,
    required this.signingPublicKeyBytes,
  });

  /// Genera una identidad NUEVA con seed phrase aleatoria.
  static Future<({PhantomIdentity identity, String seedPhrase})>
      generateNew() async {
    final mnemonic = bip39.generateMnemonic(strength: 256); // 24 palabras
    final identity = await fromSeedPhrase(mnemonic);
    return (identity: identity, seedPhrase: mnemonic);
  }

  /// Restaura una identidad existente desde seed phrase.
  /// Lanza [InvalidSeedPhraseException] si la phrase es inválida.
  static Future<PhantomIdentity> fromSeedPhrase(String seedPhrase) async {
    final normalized = seedPhrase.trim().toLowerCase();
    if (!bip39.validateMnemonic(normalized)) {
      throw const InvalidSeedPhraseException(
        'Seed phrase inválida: verifica las palabras y el orden.',
      );
    }

    // BIP39 → seed de 512 bits
    final seedBytes = Uint8List.fromList(bip39.mnemonicToSeed(normalized));

    // Derivar Ed25519 signing keypair via BIP32-Ed25519
    // Path: m/phantom'/0'/signing' (hardened)
    final signingRaw = await _deriveEd25519(seedBytes, "m/44'/7331'/0'/0'");

    // Derivar X25519 encryption keypair
    // Path: m/phantom'/0'/encryption' (hardened, path diferente)
    final encryptionRaw = await _deriveX25519FromSeed(seedBytes, "m/44'/7331'/0'/1");

    // Construir keypairs usando la librería cryptography
    final edAlgo = Ed25519();
    final signingKP = await edAlgo.newKeyPairFromSeed(signingRaw);

    final x25519Algo = X25519();
    final encryptionKP = await x25519Algo.newKeyPairFromSeed(encryptionRaw);

    // Extraer public keys en bytes
    final signingPub = await signingKP.extractPublicKey();
    final encryptionPub = await encryptionKP.extractPublicKey();

    final signingPubBytes = Uint8List.fromList(signingPub.bytes);
    final encryptionPubBytes = Uint8List.fromList(encryptionPub.bytes);

    // PhantomID = base58check(version_byte + X25519_public_key)
    // Version byte 0x50 ('P' de Phantom)
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

  /// Decodifica un PhantomID y extrae el public key X25519.
  /// Lanza [InvalidPhantomIdException] si el ID es inválido.
  static Uint8List decodeId(String phantomId) {
    try {
      final decoded = bs58check.decode(phantomId);
      if (decoded.length != 33 || decoded[0] != 0x50) {
        throw const InvalidPhantomIdException('ID con formato incorrecto.');
      }
      return Uint8List.fromList(decoded.sublist(1));
    } catch (e) {
      throw InvalidPhantomIdException('PhantomID inválido: $e');
    }
  }

  // ── Derivación de claves ──────────────────────────────────────────────────

  /// Deriva 32 bytes para Ed25519 usando ed25519_hd_key (BIP32-Ed25519).
  static Future<Uint8List> _deriveEd25519(
      Uint8List seed, String path) async {
    final key = await ED25519_HD_KEY.derivePath(path, seed);
    return Uint8List.fromList(key.key);
  }

  /// Deriva 32 bytes para X25519 usando HKDF desde el seed BIP39.
  /// X25519 no tiene derivación HD estándar, así que usamos HKDF con
  /// el path como "info" para separación de dominios.
  static Future<Uint8List> _deriveX25519FromSeed(
      Uint8List seed, String path) async {
    final hkdf = Hkdf(
      hmac: Hmac(Sha512()),
      outputLength: 32,
    );
    final secretKey = SecretKey(seed);
    final output = await hkdf.deriveKey(
      secretKey: secretKey,
      nonce: Uint8List(0), // sin salt — el seed ya tiene alta entropía
      info: Uint8List.fromList('phantom-x25519-$path'.codeUnits),
    );
    return Uint8List.fromList(await output.extractBytes());
  }

  @override
  String toString() => 'PhantomIdentity(id: $phantomId)';
}

// ── Excepciones ──────────────────────────────────────────────────────────────

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

// Generates reference crypto vectors from the CURRENT Dart implementation so
// the Rust core (rust/phantom_crypto) can assert byte-for-byte parity.
//
//   dart run tool/gen_crypto_vectors.dart
//
// Replicates the exact constructions the app uses (double_ratchet.dart /
// x3dh.dart): HKDF-SHA512 with the documented salt/info, the X3DH KDF with the
// 32×0xFF F-prefix, X25519 DH, and ChaCha20-Poly1305 AEAD. Fixed inputs →
// deterministic outputs. Paste the printed hex into the Rust parity tests.
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List fill(int n, int v) => Uint8List(n)..fillRange(0, n, v);

Future<void> main() async {
  // ── X25519 DH ──────────────────────────────────────────────────────────────
  final x = X25519();
  final aliceSeed = fill(32, 0x11);
  final bobSeed = fill(32, 0x22);
  final aliceKp = await x.newKeyPairFromSeed(aliceSeed);
  final bobKp = await x.newKeyPairFromSeed(bobSeed);
  final bobPub = await bobKp.extractPublicKey();
  final shared = await x.sharedSecretKey(
    keyPair: aliceKp,
    remotePublicKey: bobPub,
  );
  print('x25519_bob_pub    = ${hex(bobPub.bytes)}');
  print('x25519_shared     = ${hex(await shared.extractBytes())}');

  // ── HKDF-SHA512 (storage key params) ────────────────────────────────────────
  final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
  final hk = await hkdf.deriveKey(
    secretKey: SecretKey(fill(32, 0x42)),
    nonce: Uint8List.fromList(utf8.encode('phantom-storage-v1')),
    info: Uint8List.fromList(utf8.encode('phantom-hive-encryption-key')),
  );
  print('hkdf_sha512       = ${hex(await hk.extractBytes())}');

  // ── X3DH KDF (F-prefix + concat + HKDF info "phantom-x3dh-v1") ───────────────
  final f = fill(32, 0xFF);
  final dh1 = fill(32, 0xaa);
  final dh2 = fill(32, 0xbb);
  final dh3 = fill(32, 0xcc);
  final dh4 = fill(32, 0xdd);
  final input =
      Uint8List.fromList([...f, ...dh1, ...dh2, ...dh3, ...dh4]);
  final x3 = await Hkdf(hmac: Hmac(Sha512()), outputLength: 32).deriveKey(
    secretKey: SecretKey(input),
    nonce: Uint8List(0),
    info: Uint8List.fromList(utf8.encode('phantom-x3dh-v1')),
  );
  print('x3dh_kdf          = ${hex(await x3.extractBytes())}');

  // ── ChaCha20-Poly1305 AEAD ──────────────────────────────────────────────────
  final key = fill(32, 0x01);
  final nonce = fill(12, 0x02);
  final aad = fill(16, 0x03);
  final pt = Uint8List.fromList(utf8.encode('phantom test vector'));
  final box = await Chacha20.poly1305Aead().encrypt(
    pt,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: aad,
  );
  print('chacha_ct         = ${hex(box.cipherText)}');
  print('chacha_mac        = ${hex(box.mac.bytes)}');
}

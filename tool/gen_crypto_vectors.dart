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

  // ── Ratchet: _kdfInitialHeaderKey ───────────────────────────────────────────
  // HKDF-SHA512(ikm = sharedSecret, salt = empty, info = direction, L = 32).
  final ihk = await Hkdf(hmac: Hmac(Sha512()), outputLength: 32).deriveKey(
    secretKey: SecretKey(fill(32, 0x55)),
    nonce: Uint8List(0),
    info: Uint8List.fromList(utf8.encode('phantom-ratchet-hk-atob')),
  );
  print('ratchet_ihk       = ${hex(await ihk.extractBytes())}');

  // ── Ratchet: _kdfRootKey ────────────────────────────────────────────────────
  // HKDF-SHA512(ikm = dhOutput, salt = rootKey, info = "phantom-ratchet-root-key",
  // L = 96) → (newRootKey | chainKey | nextHeaderKey).
  final rk = await Hkdf(hmac: Hmac(Sha512()), outputLength: 96).deriveKey(
    secretKey: SecretKey(fill(32, 0x77)), // dhOutput
    nonce: fill(32, 0x66), // rootKey (salt)
    info: Uint8List.fromList(utf8.encode('phantom-ratchet-root-key')),
  );
  final rkb = await rk.extractBytes();
  print('ratchet_rk_newrk  = ${hex(rkb.sublist(0, 32))}');
  print('ratchet_rk_ck     = ${hex(rkb.sublist(32, 64))}');
  print('ratchet_rk_nexthk = ${hex(rkb.sublist(64, 96))}');

  // ── Ratchet: _kdfChainKey ───────────────────────────────────────────────────
  // newCK = HMAC-SHA512(key=CK, msg=[0x01])[0:32]
  // mkMac = HMAC-SHA512(key=CK, msg="phantom-ratchet-chain-key")
  // mk    = HKDF-SHA512(ikm=mkMac, salt=empty, info="phantom-ratchet-message-key", L=64)
  //         encKey=mk[0:32]  headerKey=mk[32:64]
  final ck = fill(32, 0x88);
  final hmacS = Hmac(Sha512());
  final newCKMac =
      await hmacS.calculateMac(Uint8List.fromList([0x01]), secretKey: SecretKey(ck));
  final mkMac = await hmacS.calculateMac(
      Uint8List.fromList(utf8.encode('phantom-ratchet-chain-key')),
      secretKey: SecretKey(ck));
  final mkExp = await Hkdf(hmac: Hmac(Sha512()), outputLength: 64).deriveKey(
    secretKey: SecretKey(mkMac.bytes),
    nonce: Uint8List(0),
    info: Uint8List.fromList(utf8.encode('phantom-ratchet-message-key')),
  );
  final mkb = await mkExp.extractBytes();
  print('ratchet_ck_newck  = ${hex(newCKMac.bytes.sublist(0, 32))}');
  print('ratchet_ck_enckey = ${hex(mkb.sublist(0, 32))}');
  print('ratchet_ck_hdrkey = ${hex(mkb.sublist(32, 64))}');

  // ── Ed25519 sign/verify (SPK + IK signatures) ───────────────────────────────
  final ed = Ed25519();
  final edKp = await ed.newKeyPairFromSeed(fill(32, 0x44));
  final edPub = await edKp.extractPublicKey();
  final edMsg = Uint8List.fromList(utf8.encode('phantom ed25519 test'));
  final edSig = await ed.sign(edMsg, keyPair: edKp);
  print('ed25519_pub       = ${hex(edPub.bytes)}');
  print('ed25519_sig       = ${hex(edSig.bytes)}');

  // ── X3DH shared secret (initiate == respond) ────────────────────────────────
  // Fixed X25519 seeds for every key so the composed secret is deterministic.
  Future<Uint8List> dh(Uint8List seed, List<int> peerPub) async {
    final kp = await x.newKeyPairFromSeed(seed);
    final ss = await x.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(peerPub, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await ss.extractBytes());
  }

  Future<Uint8List> pub(Uint8List seed) async =>
      Uint8List.fromList((await (await x.newKeyPairFromSeed(seed)).extractPublicKey()).bytes);

  final aliceIk = fill(32, 0x31), aliceEph = fill(32, 0x32);
  final bobIk = fill(32, 0x33), bobSpk = fill(32, 0x34), bobOpk = fill(32, 0x35);
  final bobIkPub = await pub(bobIk), bobSpkPub = await pub(bobSpk), bobOpkPub = await pub(bobOpk);

  // Alice initiate: DH(IK_A,SPK_B) DH(EK_A,IK_B) DH(EK_A,SPK_B) DH(EK_A,OPK_B)
  final aDh1 = await dh(aliceIk, bobSpkPub);
  final aDh2 = await dh(aliceEph, bobIkPub);
  final aDh3 = await dh(aliceEph, bobSpkPub);
  final aDh4 = await dh(aliceEph, bobOpkPub);
  final aInput = Uint8List.fromList([...f, ...aDh1, ...aDh2, ...aDh3, ...aDh4]);
  final aShared = await Hkdf(hmac: Hmac(Sha512()), outputLength: 32).deriveKey(
    secretKey: SecretKey(aInput),
    nonce: Uint8List(0),
    info: Uint8List.fromList(utf8.encode('phantom-x3dh-v1')),
  );
  print('x3dh_shared       = ${hex(await aShared.extractBytes())}');

  // ── Hybrid combine (HybridKEM.combineSecrets) ───────────────────────────────
  // HKDF-SHA512(ikm = x3dhSecret || kyberSecret, salt = "phantom-hybrid-v1",
  // info = "phantom-x3dh-kyber768", L = 32).
  final combineIkm = Uint8List.fromList([...fill(32, 0x61), ...fill(32, 0x62)]);
  final combined = await Hkdf(hmac: Hmac(Sha512()), outputLength: 32).deriveKey(
    secretKey: SecretKey(combineIkm),
    nonce: Uint8List.fromList(utf8.encode('phantom-hybrid-v1')),
    info: Uint8List.fromList(utf8.encode('phantom-x3dh-kyber768')),
  );
  print('hybrid_combined   = ${hex(await combined.extractBytes())}');

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

// Generates Kyber-768 (round 3) reference vectors from the CURRENT Dart
// implementation (`post_quantum` via HybridKEM) so the Rust core can assert
// byte-for-byte wire compatibility before taking over the KEM.
//
//   dart run tool/gen_kyber_vectors.dart
//
// Uses the inner Kyber API directly (HybridKEM.encapsulate draws a random
// nonce; parity needs the deterministic form). Covers the full KEM surface:
// keygen from a fixed 64-byte seed, encapsulation with a fixed 32-byte nonce,
// decapsulation, AND the implicit-rejection path (tampered ciphertext must
// yield the same KDF(z ‖ H(ct)) secret in both implementations — it's part of
// the scheme, not an error).
import 'dart:typed_data';
import 'package:post_quantum/kyber.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final kyber = Kyber.kem768();

  // Fixed, arbitrary seed/nonce (same bytes hardcoded in the Rust test).
  final seed = Uint8List.fromList(List.generate(64, (i) => (i * 13 + 7) & 0xff));
  final nonce = Uint8List.fromList(List.generate(32, (i) => (i * 29 + 3) & 0xff));

  final (pk, sk) = kyber.generateKeys(seed);
  final pkBytes = pk.serialize();
  final skBytes = sk.serialize();
  print('seed            = ${hex(seed)}');
  print('nonce           = ${hex(nonce)}');
  print('pk (${pkBytes.length})    = ${hex(pkBytes)}');
  print('sk (${skBytes.length})    = ${hex(skBytes)}');

  final (cipher, ss) = kyber.encapsulate(pk, nonce);
  final ctBytes = cipher.serialize();
  print('ct (${ctBytes.length})    = ${hex(ctBytes)}');
  print('ss              = ${hex(ss)}');

  final ssDec = kyber.decapsulate(cipher, sk);
  print('ss_decaps       = ${hex(ssDec)} (must equal ss)');

  // Implicit rejection: flip one byte of the ciphertext. Round-3 decaps
  // returns KDF(z ‖ H(ct')) — deterministic, so Rust must match it too.
  final tampered = Uint8List.fromList(ctBytes);
  tampered[0] ^= 0x01;
  final ctTampered = PKECypher.deserialize(tampered, 3);
  final ssReject = kyber.decapsulate(ctTampered, sk);
  print('ss_reject       = ${hex(ssReject)}');
}

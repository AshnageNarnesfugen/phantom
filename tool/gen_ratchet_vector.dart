// Emits a cross-compatibility vector for the Rust ratchet port: a serialized
// Bob (receiver) session plus a message Alice encrypted, so the Rust
// RatchetSession can prove it decrypts real Dart-produced ciphertext.
//
//   dart run tool/gen_ratchet_vector.dart
//
// Captured once and embedded in the Rust test — the exchange is a fixed valid
// instance (Alice's ephemeral DH was random at capture time; that's fine, it's
// baked into the printed session/message).
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:phantom_messenger/core/crypto/double_ratchet.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  final sharedSecret = Uint8List(32)..fillRange(0, 32, 0x5a);

  // Bob's identity X25519 keypair from a fixed seed (deterministic).
  final bobKp = await X25519().newKeyPairFromSeed(Uint8List(32)..fillRange(0, 32, 0x33));
  final bobKpData = await bobKp.extract();
  final bobPub = await bobKpData.extractPublicKey();

  final alice = await RatchetSession.initAsSender(
    sharedSecret: sharedSecret,
    remotePublicKey: Uint8List.fromList(bobPub.bytes),
  );
  final bob = await RatchetSession.initAsReceiver(
    sharedSecret: sharedSecret,
    ourEncryptionKP: bobKpData,
  );

  // Serialize Bob's FRESH receiver session — Rust will load this and must
  // perform the DH ratchet + chain KDF to decrypt Alice's first message.
  final bobJson = jsonEncode(await bob.toJson());

  // Alice encrypts two messages (second exercises the sending chain advance).
  final m0 = await alice.encrypt(Uint8List.fromList(utf8.encode('hola desde dart 0')));
  final m1 = await alice.encrypt(Uint8List.fromList(utf8.encode('hola desde dart 1')));

  print('BOB_SESSION_JSON=$bobJson');
  print('M0_HDR=${hex(m0.encryptedHeader)}');
  print('M0_CT=${hex(m0.ciphertext)}');
  print('M0_NONCE=${hex(m0.nonce)}');
  print('M1_HDR=${hex(m1.encryptedHeader)}');
  print('M1_CT=${hex(m1.ciphertext)}');
  print('M1_NONCE=${hex(m1.nonce)}');
}

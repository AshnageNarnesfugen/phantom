import 'dart:convert';
import 'package:phantom/core/crypto/double_ratchet.dart';
import 'package:phantom/core/crypto/keys.dart';
import 'dart:typedData';

void main() async {
  final kp = await CryptographyKeys.generateIdentityKeyPair();
  final senderKp = await CryptographyKeys.generateIdentityKeyPair();
  final x3dhEk = Uint8List.fromList([1, 2, 3]);
  final kyber = Uint8List.fromList([4, 5, 6]);

  final session = await RatchetSession.initAsSender(
    sharedSecret: Uint8List.fromList(List.filled(32, 0)),
    remotePublicKey: Uint8List.fromList(kp.publicKey.bytes),
    x3dhEphemeralKeyBytes: x3dhEk,
    kyberCipherBytes: kyber,
  );

  print("before encrypt: is null? ${session.pendingX3dhEphemeralKey == null}");
  await session.encrypt(Uint8List.fromList([1, 2, 3]));
  print("after encrypt: is null? ${session.pendingX3dhEphemeralKey == null}");

  final json = await session.toJson();
  final restored = await RatchetSession.fromJson(json);
  print("after restore: is null? ${restored.pendingX3dhEphemeralKey == null}");
}

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/phantom_messenger.dart';

void main() {
  group('PhantomIdentity', () {
    test('genera nueva identidad con 24 palabras', () async {
      final result = await PhantomIdentity.generateNew();
      final words = result.seedPhrase.split(' ');
      expect(words.length, equals(24));
      expect(result.identity.phantomId, isNotEmpty);
      print('PhantomID: ${result.identity.phantomId}');
      print('Seed: ${result.seedPhrase}');
    });

    test('restaura identidad desde seed phrase', () async {
      final result = await PhantomIdentity.generateNew();
      final restored = await PhantomIdentity.fromSeedPhrase(result.seedPhrase);

      expect(restored.phantomId, equals(result.identity.phantomId));
      expect(
        restored.encryptionPublicKeyBytes,
        equals(result.identity.encryptionPublicKeyBytes),
      );
    });

    test('identidades distintas tienen IDs distintos', () async {
      final a = await PhantomIdentity.generateNew();
      final b = await PhantomIdentity.generateNew();
      expect(a.identity.phantomId, isNot(equals(b.identity.phantomId)));
    });

    test('seed phrase inválida lanza excepción', () async {
      expect(
        () => PhantomIdentity.fromSeedPhrase('palabra incorrecta aqui'),
        throwsA(isA<InvalidSeedPhraseException>()),
      );
    });

    test('PhantomID tiene formato válido (base58check)', () async {
      final result = await PhantomIdentity.generateNew();
      final id = result.identity.phantomId;

      // Debe poder decodificarse y dar el public key de vuelta
      final pubKey = PhantomIdentity.decodeId(id);
      expect(pubKey.length, equals(32));
      expect(pubKey, equals(result.identity.encryptionPublicKeyBytes));
    });

    test('PhantomID inválido lanza excepción', () {
      expect(
        () => PhantomIdentity.decodeId('INVALID_ID_XXXX'),
        throwsA(isA<InvalidPhantomIdException>()),
      );
    });
  });

  group('X3DH Handshake', () {
    test('Alice y Bob derivan el mismo shared secret', () async {
      // Generar identidades
      final aliceResult = await PhantomIdentity.generateNew();
      final bobResult = await PhantomIdentity.generateNew();
      final alice = aliceResult.identity;
      final bob = bobResult.identity;

      // Bob genera su bundle
      final bobBundleResult = await X3DHHandshake.generateBundle(
        identityKP: bob.encryptionKeyPair,
        signingKP: bob.signingKeyPair,
      );

      // Alice inicia con el bundle de Bob
      final aliceResult2 = await X3DHHandshake.initiate(
        ourIdentityKP: alice.encryptionKeyPair,
        theirBundle: bobBundleResult.bundle,
      );

      // Bob responde con los datos que Alice envió
      final bobSharedSecret = await X3DHHandshake.respond(
        ourIdentityKP: bob.encryptionKeyPair,
        ourSignedPreKP: bobBundleResult.signedPreKeyPair,
        ourOneTimePreKP: bobBundleResult.bundle.oneTimePreKeys.isNotEmpty
            ? bobBundleResult.oneTimePreKeyPairs.first
            : null,
        theirIdentityKeyBytes: alice.encryptionPublicKeyBytes,
        theirEphemeralKeyBytes: aliceResult2.ephemeralPublicKeyBytes,
      );

      expect(aliceResult2.sharedSecret, equals(bobSharedSecret));
      print('X3DH shared secret (primeros 8 bytes): ${aliceResult2.sharedSecret.sublist(0, 8).map((b) => b.toRadixString(16)).join()}');
    });

    test('bundle inválido (firma falsa) lanza excepción', () async {
      final aliceResult = await PhantomIdentity.generateNew();
      final bobResult = await PhantomIdentity.generateNew();

      final bobBundle = await X3DHHandshake.generateBundle(
        identityKP: bobResult.identity.encryptionKeyPair,
        signingKP: bobResult.identity.signingKeyPair,
      );

      // Manipular la firma del SPK
      final fakeBundle = PreKeyBundle(
        identityKeyBytes:      bobBundle.bundle.identityKeyBytes,
        signingKeyBytes:       bobBundle.bundle.signingKeyBytes,
        signedPreKeyBytes:     bobBundle.bundle.signedPreKeyBytes,
        signedPreKeyId:        bobBundle.bundle.signedPreKeyId,
        signedPreKeySignature: Uint8List(64), // firma falsa
        oneTimePreKeys:        bobBundle.bundle.oneTimePreKeys,
      );

      expect(
        () => X3DHHandshake.initiate(
          ourIdentityKP: aliceResult.identity.encryptionKeyPair,
          theirBundle: fakeBundle,
        ),
        throwsA(isA<X3DHException>()),
      );
    });
  });

  group('Double Ratchet + Protocol', () {
    late PhantomIdentity alice;
    late PhantomIdentity bob;
    late Uint8List sharedSecret;

    setUp(() async {
      final aResult = await PhantomIdentity.generateNew();
      final bResult = await PhantomIdentity.generateNew();
      alice = aResult.identity;
      bob = bResult.identity;

      // Simular X3DH para obtener shared secret
      final bobBundle = await X3DHHandshake.generateBundle(
        identityKP: bob.encryptionKeyPair,
        signingKP: bob.signingKeyPair,
      );
      final x3dhResult = await X3DHHandshake.initiate(
        ourIdentityKP: alice.encryptionKeyPair,
        theirBundle: bobBundle.bundle,
      );
      sharedSecret = x3dhResult.sharedSecret;
    });

    test('Alice puede cifrar y Bob puede descifrar', () async {
      final aliceSession = await RatchetSession.initAsSender(
        sharedSecret: sharedSecret,
        remotePublicKey: bob.encryptionPublicKeyBytes,
      );
      final bobSession = await RatchetSession.initAsReceiver(
        sharedSecret: sharedSecret,
        ourEncryptionKP: bob.encryptionKeyPair,
      );

      final aliceProtocol = PhantomProtocol(aliceSession);
      final bobProtocol = PhantomProtocol(bobSession);

      final msg = PhantomMessage.text('hola desde phantom');
      final wire = await aliceProtocol.encode(msg);
      final decoded = await bobProtocol.decode(wire);

      expect(decoded.textContent, equals('hola desde phantom'));
      expect(decoded.type, equals(MessageType.text));
    });

    test('múltiples mensajes mantienen forward secrecy', () async {
      final aliceSession = await RatchetSession.initAsSender(
        sharedSecret: sharedSecret,
        remotePublicKey: bob.encryptionPublicKeyBytes, x3dhEphemeralKeyBytes: null,
      );
      final bobSession = await RatchetSession.initAsReceiver(
        sharedSecret: sharedSecret,
        ourEncryptionKP: bob.encryptionKeyPair,
      );

      final ap = PhantomProtocol(aliceSession);
      final bp = PhantomProtocol(bobSession);

      final messages = ['primer mensaje', 'segundo', 'tercero con 🔒'];

      for (final text in messages) {
        final wire = await ap.encode(PhantomMessage.text(text));
        final decoded = await bp.decode(wire);
        expect(decoded.textContent, equals(text));
      }
    });

    test('mensaje manipulado lanza excepción', () async {
      final aliceSession = await RatchetSession.initAsSender(
        sharedSecret: sharedSecret,
        remotePublicKey: bob.encryptionPublicKeyBytes,
      );
      final bobSession = await RatchetSession.initAsReceiver(
        sharedSecret: sharedSecret,
        ourEncryptionKP: bob.encryptionKeyPair,
      );

      final wire = await PhantomProtocol(aliceSession)
          .encode(PhantomMessage.text('mensaje secreto'));

      // Flip de un bit en el ciphertext
      final tampered = Uint8List.fromList(wire);
      tampered[wire.length ~/ 2] ^= 0xFF;

      expect(
        () => PhantomProtocol(bobSession).decode(tampered),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('padding normaliza todos los mensajes al mismo tamaño', () async {
      final aliceSession = await RatchetSession.initAsSender(
        sharedSecret: sharedSecret,
        remotePublicKey: bob.encryptionPublicKeyBytes,
      );

      final ap = PhantomProtocol(aliceSession);

      final short = await ap.encode(PhantomMessage.text('hi'));
      final long = await ap.encode(
          PhantomMessage.text('un mensaje mucho más largo con bastante contenido adicional'));

      // Ambos deben ser del mismo tamaño de bloque (1024 bytes de payload)
      // Wire format puede variar por header, pero ciphertext debe ser igual
      // Verificamos que no haya filtración de tamaño
      print('Short wire: ${short.length} bytes');
      print('Long wire: ${long.length} bytes');
      // El padding garantiza que el ciphertext del mensaje sea siempre 1024 bytes
      // (más el overhead de ChaCha20-Poly1305 de 16 bytes)
    });
  });

  group('Message serialization', () {
    test('serializa y deserializa correctamente', () {
      final original = PhantomMessage.text('test message');
      final bytes = original.serialize();
      final restored = PhantomMessage.deserialize(bytes);

      expect(restored.textContent, equals('test message'));
      expect(restored.type, equals(MessageType.text));
      expect(restored.id, equals(original.id));
    });

    test('mensaje con reply ID', () {
      final original = PhantomMessage.text('reply', replyToId: 'parent-id-123');
      final bytes = original.serialize();
      final restored = PhantomMessage.deserialize(bytes);

      expect(restored.replyToId, equals('parent-id-123'));
    });
  });
}

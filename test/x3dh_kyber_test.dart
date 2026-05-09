import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/phantom_messenger.dart';
import 'package:phantom_messenger/core/crypto/hybrid_kem.dart';

/// X3DH and Hybrid KEM round-trip + tamper checks.

void main() {
  group('X3DH — initiate / respond', () {
    test('Alice and Bob derive the same shared secret (no OPK)', () async {
      final alice = await PhantomIdentity.generateNew();
      final bob   = await PhantomIdentity.generateNew();

      final bundleResult = await X3DHHandshake.generateBundle(
        identityKP: bob.identity.encryptionKeyPair,
        signingKP:  bob.identity.signingKeyPair,
        numOneTimePreKeys: 0,
      );

      final aliceResult = await X3DHHandshake.initiate(
        ourIdentityKP: alice.identity.encryptionKeyPair,
        theirBundle:   bundleResult.bundle,
      );

      final bobShared = await X3DHHandshake.respond(
        ourIdentityKP:          bob.identity.encryptionKeyPair,
        ourSignedPreKP:         bundleResult.signedPreKeyPair,
        theirIdentityKeyBytes:  alice.identity.encryptionPublicKeyBytes,
        theirEphemeralKeyBytes: aliceResult.ephemeralPublicKeyBytes,
      );

      expect(aliceResult.sharedSecret, equals(bobShared));
    });

    test('OPK is included in DH4 and matches on both sides', () async {
      final alice = await PhantomIdentity.generateNew();
      final bob   = await PhantomIdentity.generateNew();

      final bundleResult = await X3DHHandshake.generateBundle(
        identityKP: bob.identity.encryptionKeyPair,
        signingKP:  bob.identity.signingKeyPair,
        numOneTimePreKeys: 1,
      );

      final aliceResult = await X3DHHandshake.initiate(
        ourIdentityKP: alice.identity.encryptionKeyPair,
        theirBundle:   bundleResult.bundle,
      );
      expect(aliceResult.usedOneTimePreKeyId, equals(0));

      final bobShared = await X3DHHandshake.respond(
        ourIdentityKP:          bob.identity.encryptionKeyPair,
        ourSignedPreKP:         bundleResult.signedPreKeyPair,
        ourOneTimePreKP:        bundleResult.oneTimePreKeyPairs.first,
        theirIdentityKeyBytes:  alice.identity.encryptionPublicKeyBytes,
        theirEphemeralKeyBytes: aliceResult.ephemeralPublicKeyBytes,
      );

      expect(aliceResult.sharedSecret, equals(bobShared));
    });

    test('tampered SPK signature is rejected', () async {
      final bob = await PhantomIdentity.generateNew();
      final bundleResult = await X3DHHandshake.generateBundle(
        identityKP: bob.identity.encryptionKeyPair,
        signingKP:  bob.identity.signingKeyPair,
      );
      final tampered = PreKeyBundle(
        identityKeyBytes:      bundleResult.bundle.identityKeyBytes,
        signingKeyBytes:       bundleResult.bundle.signingKeyBytes,
        signedPreKeyBytes:     bundleResult.bundle.signedPreKeyBytes,
        signedPreKeyId:        bundleResult.bundle.signedPreKeyId,
        signedPreKeySignature: Uint8List.fromList(
            bundleResult.bundle.signedPreKeySignature)
          ..[0] ^= 0xFF,
        oneTimePreKeys:        const [],
      );
      final alice = await PhantomIdentity.generateNew();
      expect(
        () => X3DHHandshake.initiate(
          ourIdentityKP: alice.identity.encryptionKeyPair,
          theirBundle:   tampered,
        ),
        throwsA(isA<X3DHException>()),
      );
    });

    test('different ephemerals produce different secrets', () async {
      final alice = await PhantomIdentity.generateNew();
      final bob   = await PhantomIdentity.generateNew();
      final bundle = (await X3DHHandshake.generateBundle(
        identityKP: bob.identity.encryptionKeyPair,
        signingKP:  bob.identity.signingKeyPair,
      )).bundle;

      final r1 = await X3DHHandshake.initiate(
        ourIdentityKP: alice.identity.encryptionKeyPair,
        theirBundle:   bundle,
      );
      final r2 = await X3DHHandshake.initiate(
        ourIdentityKP: alice.identity.encryptionKeyPair,
        theirBundle:   bundle,
      );

      // Two independent ephemerals → two independent secrets.
      expect(r1.sharedSecret, isNot(equals(r2.sharedSecret)));
      expect(r1.ephemeralPublicKeyBytes,
          isNot(equals(r2.ephemeralPublicKeyBytes)));
    });
  });

  group('Hybrid KEM — Kyber-768', () {
    test('encapsulate / decapsulate round-trip', () async {
      final seed = await HybridKEM.deriveKyberSeed('seed-for-test-12345');
      final (pk, sk) = HybridKEM.generateKeys(seed);

      final (cipher, secretA) = HybridKEM.encapsulate(pk);
      final secretB = HybridKEM.decapsulate(cipher, sk);

      expect(secretA.length, equals(32));
      expect(secretA, equals(secretB));
    });

    test('combineSecrets is deterministic and 32 bytes', () async {
      final x3dh  = Uint8List(32)..fillRange(0, 32, 0xAA);
      final kyber = Uint8List(32)..fillRange(0, 32, 0xBB);
      final c1 = await HybridKEM.combineSecrets(x3dh, kyber);
      final c2 = await HybridKEM.combineSecrets(x3dh, kyber);
      expect(c1, equals(c2));
      expect(c1.length, equals(32));
    });

    test('combine output differs when either input differs', () async {
      final base   = await HybridKEM.combineSecrets(
          Uint8List(32)..fillRange(0, 32, 0x01),
          Uint8List(32)..fillRange(0, 32, 0x02));
      final altX3 = await HybridKEM.combineSecrets(
          Uint8List(32)..fillRange(0, 32, 0x03),
          Uint8List(32)..fillRange(0, 32, 0x02));
      final altK  = await HybridKEM.combineSecrets(
          Uint8List(32)..fillRange(0, 32, 0x01),
          Uint8List(32)..fillRange(0, 32, 0x04));
      expect(base, isNot(equals(altX3)));
      expect(base, isNot(equals(altK)));
    });

    test('seed derivation is deterministic per phrase', () async {
      final s1 = await HybridKEM.deriveKyberSeed('phantom test phrase');
      final s2 = await HybridKEM.deriveKyberSeed('phantom test phrase');
      final s3 = await HybridKEM.deriveKyberSeed('phantom test phras3');
      expect(s1, equals(s2));
      expect(s1, isNot(equals(s3)));
      expect(s1.length, equals(64));
    });
  });

  group('ContactAddress — version round-trips', () {
    Future<({Uint8List ik, Uint8List sk, Uint8List spk, Uint8List sig,
            Uint8List ikSig})>
        materials() async {
      final id = await PhantomIdentity.generateNew();
      final spk = await X25519().newKeyPair();
      final spkPub = await (await spk.extract()).extractPublicKey();
      final sig = await Ed25519().sign(spkPub.bytes,
          keyPair: id.identity.signingKeyPair);
      final ikSig = await Ed25519().sign(
          id.identity.encryptionPublicKeyBytes,
          keyPair: id.identity.signingKeyPair);
      return (
        ik:    id.identity.encryptionPublicKeyBytes,
        sk:    id.identity.signingPublicKeyBytes,
        spk:   Uint8List.fromList(spkPub.bytes),
        sig:   Uint8List.fromList(sig.bytes),
        ikSig: Uint8List.fromList(ikSig.bytes),
      );
    }

    test('v1 encode → decode round-trip', () async {
      final m = await materials();
      final ca = ContactAddress(
        x25519IdentityKey: m.ik,
        ed25519SigningKey:  m.sk,
        signedPreKeyBytes:  m.spk,
        signedPreKeyId:     1,
        signature:          m.sig,
      );
      final decoded = ContactAddress.decode(ca.encode());
      expect(decoded.x25519IdentityKey, equals(m.ik));
      expect(decoded.kyber768PublicKeyBytes, isNull);
      expect(decoded.identityKeySignature, isNull);
      expect(await decoded.verifyIdentityBinding(), isTrue);
    });

    test('v3 encode → decode preserves ik_sig and verifies binding', () async {
      final m = await materials();
      final kyberPk = Uint8List(1184)..fillRange(0, 1184, 0x42);
      final ca = ContactAddress(
        x25519IdentityKey:      m.ik,
        ed25519SigningKey:       m.sk,
        signedPreKeyBytes:       m.spk,
        signedPreKeyId:          1,
        signature:               m.sig,
        kyber768PublicKeyBytes:  kyberPk,
        identityKeySignature:    m.ikSig,
      );
      final decoded = ContactAddress.decode(ca.encode());
      expect(decoded.kyber768PublicKeyBytes, equals(kyberPk));
      expect(decoded.identityKeySignature, equals(m.ikSig));
      expect(await decoded.verifyIdentityBinding(), isTrue);
    });

    test('v3 with corrupted ik_sig fails binding verification', () async {
      final m = await materials();
      final kyberPk = Uint8List(1184)..fillRange(0, 1184, 0x42);
      final badSig  = Uint8List.fromList(m.ikSig)..[0] ^= 0xFF;
      final ca = ContactAddress(
        x25519IdentityKey:      m.ik,
        ed25519SigningKey:       m.sk,
        signedPreKeyBytes:       m.spk,
        signedPreKeyId:          1,
        signature:               m.sig,
        kyber768PublicKeyBytes:  kyberPk,
        identityKeySignature:    badSig,
      );
      final decoded = ContactAddress.decode(ca.encode());
      expect(await decoded.verifyIdentityBinding(), isFalse);
    });
  });
}

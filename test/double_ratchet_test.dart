import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/phantom_messenger.dart';

/// Property tests for the Double Ratchet implementation.
///
/// Each test simulates a full Alice ↔ Bob exchange over a configurable
/// "transport" so we can reorder, drop, and replay frames without touching
/// the network stack.

Future<({RatchetSession alice, RatchetSession bob, Uint8List sharedSecret})>
    _bootstrap() async {
  final ssRng = Random.secure();
  final sharedSecret = Uint8List.fromList(
      List<int>.generate(32, (_) => ssRng.nextInt(256)));

  final aliceIK = await X25519().newKeyPair();
  final bobIK   = await X25519().newKeyPair();
  final aliceKp = await aliceIK.extract();
  final bobKp   = await bobIK.extract();
  final bobPub  = Uint8List.fromList((await bobKp.extractPublicKey()).bytes);

  final alice = await RatchetSession.initAsSender(
    sharedSecret:    sharedSecret,
    remotePublicKey: bobPub,
  );
  final bob = await RatchetSession.initAsReceiver(
    sharedSecret:    sharedSecret,
    ourEncryptionKP: bobKp,
  );

  // Touch the unused alice IK to keep the analyzer happy.
  expect(aliceKp.bytes.length, equals(32));
  return (alice: alice, bob: bob, sharedSecret: sharedSecret);
}

Uint8List _msg(String s) => Uint8List.fromList(utf8.encode(s));
String _str(Uint8List b) => utf8.decode(b);

void main() {
  group('Double Ratchet — round-trip', () {
    test('Alice → Bob single message decrypts correctly', () async {
      final s = await _bootstrap();
      final ct = await s.alice.encrypt(_msg('hola bob'));
      final pt = await s.bob.decrypt(ct);
      expect(_str(pt), equals('hola bob'));
    });

    test('100 sequential A→B messages decrypt in order', () async {
      final s = await _bootstrap();
      for (int i = 0; i < 100; i++) {
        final ct = await s.alice.encrypt(_msg('m$i'));
        final pt = await s.bob.decrypt(ct);
        expect(_str(pt), equals('m$i'));
      }
    });

    test('full ping-pong drives DH ratchet steps', () async {
      final s = await _bootstrap();
      // First Alice → Bob primes Bob's receiving chain
      final c0 = await s.alice.encrypt(_msg('a0'));
      expect(_str(await s.bob.decrypt(c0)), equals('a0'));

      // Now Bob can send. This triggers a DH ratchet on Alice's side when received.
      final c1 = await s.bob.encrypt(_msg('b1'));
      expect(_str(await s.alice.decrypt(c1)), equals('b1'));

      // Alice replies again; keeps ratcheting.
      for (int i = 0; i < 10; i++) {
        final ca = await s.alice.encrypt(_msg('a$i'));
        expect(_str(await s.bob.decrypt(ca)), equals('a$i'));
        final cb = await s.bob.encrypt(_msg('b$i'));
        expect(_str(await s.alice.decrypt(cb)), equals('b$i'));
      }
    });
  });

  group('Double Ratchet — out-of-order delivery', () {
    test('Bob can decrypt skipped + reordered messages within same chain',
        () async {
      final s = await _bootstrap();
      final cts = <EncryptedMessage>[];
      for (int i = 0; i < 5; i++) {
        cts.add(await s.alice.encrypt(_msg('m$i')));
      }
      // Deliver in reverse order
      for (int i = 4; i >= 0; i--) {
        final pt = await s.bob.decrypt(cts[i]);
        expect(_str(pt), equals('m$i'));
      }
    });

    test('skipped key cache survives across many reorderings', () async {
      final s = await _bootstrap();
      final cts = <EncryptedMessage>[];
      for (int i = 0; i < 20; i++) {
        cts.add(await s.alice.encrypt(_msg('m$i')));
      }
      final indices = List.generate(20, (i) => i)..shuffle(Random(42));
      for (final i in indices) {
        final pt = await s.bob.decrypt(cts[i]);
        expect(_str(pt), equals('m$i'));
      }
    });

    test('skipped-key store stays bounded across lossy rounds', () async {
      // Skipped keys accumulate ACROSS DH-ratchet chains (within one chain the
      // per-gap _maxSkip already bounds work). Ping-pong 3 rounds; each round
      // Alice sends a burst and Bob decrypts only the last, retaining the
      // skipped keys of that chain. 3 × ~800 > the 2000 total cap, so the
      // store must evict oldest and stay bounded — no unbounded growth (and no
      // unbounded serialization into the encrypted store).
      final s = await _bootstrap();
      const perRound = 800;
      for (int r = 0; r < 3; r++) {
        final cts = <EncryptedMessage>[];
        for (int i = 0; i < perRound; i++) {
          cts.add(await s.alice.encrypt(_msg('r${r}m$i')));
        }
        // Bob decrypts only the last of the burst → skips the rest (retained).
        expect(_str(await s.bob.decrypt(cts.last)), equals('r${r}m${perRound - 1}'));
        // Bob replies so Alice performs a DH ratchet → next round is a new
        // chain, so its skipped keys add to the retained total.
        final reply = await s.bob.encrypt(_msg('ack$r'));
        expect(_str(await s.alice.decrypt(reply)), equals('ack$r'));
      }

      final sk = (await s.bob.toJson())['sk'] as Map;
      expect(sk.length, lessThanOrEqualTo(2000),
          reason: 'skipped-key store must be capped, not grow unbounded');
    });
  });

  group('Double Ratchet — adversarial inputs', () {
    test('tampered ciphertext fails AEAD', () async {
      final s = await _bootstrap();
      final ct = await s.alice.encrypt(_msg('integrity'));
      final tampered = EncryptedMessage(
        encryptedHeader: ct.encryptedHeader,
        ciphertext: Uint8List.fromList(ct.ciphertext)..[0] ^= 0x01,
        nonce: ct.nonce,
      );
      expect(() => s.bob.decrypt(tampered), throwsA(isA<RatchetException>()));
    });

    test('tampered header fails decryption', () async {
      final s = await _bootstrap();
      final ct = await s.alice.encrypt(_msg('header'));
      final tampered = EncryptedMessage(
        encryptedHeader: Uint8List.fromList(ct.encryptedHeader)..[15] ^= 0xFF,
        ciphertext: ct.ciphertext,
        nonce: ct.nonce,
      );
      expect(() => s.bob.decrypt(tampered), throwsA(isA<RatchetException>()));
    });

    test('skip beyond _maxSkip is rejected', () async {
      final s = await _bootstrap();
      // Drive Alice's send counter past 1000 without ever delivering anything.
      EncryptedMessage? last;
      for (int i = 0; i <= 1100; i++) {
        last = await s.alice.encrypt(_msg('skip$i'));
      }
      expect(() => s.bob.decrypt(last!), throwsA(isA<RatchetException>()));
    });

    test('Bob cannot encrypt before receiving Alice\'s first message',
        () async {
      final s = await _bootstrap();
      expect(() => s.bob.encrypt(_msg('too soon')),
          throwsA(isA<RatchetException>()));
    });
  });

  group('Double Ratchet — persistence', () {
    test('JSON round-trip preserves session and continues encrypt/decrypt',
        () async {
      final s = await _bootstrap();
      final c0 = await s.alice.encrypt(_msg('before save'));
      expect(_str(await s.bob.decrypt(c0)), equals('before save'));

      // Snapshot Alice mid-flight, restore, keep sending.
      final aliceJson = await s.alice.toJson();
      final restored  = await RatchetSession.fromJson(aliceJson);

      final c1 = await restored.encrypt(_msg('after restore'));
      expect(_str(await s.bob.decrypt(c1)), equals('after restore'));
    });

    test('takeSnapshot allows rollback if decryption attempt was wrong',
        () async {
      final s = await _bootstrap();
      // Establish baseline state on Bob.
      final c0 = await s.alice.encrypt(_msg('first'));
      expect(_str(await s.bob.decrypt(c0)), equals('first'));

      final snap = s.bob.takeSnapshot();

      // Now try decrypting a forged frame that should fail. Bob's state may
      // have advanced on header decrypt before AEAD failure; the snapshot
      // lets us roll back.
      final bogus = EncryptedMessage(
        encryptedHeader: Uint8List(40),
        ciphertext: Uint8List(32),
        nonce: Uint8List(12),
      );
      try { await s.bob.decrypt(bogus); } catch (_) {}

      final rollback = await RatchetSession.fromJson(snap);
      final c1 = await s.alice.encrypt(_msg('after fail'));
      expect(_str(await rollback.decrypt(c1)), equals('after fail'));
    });
  });
}

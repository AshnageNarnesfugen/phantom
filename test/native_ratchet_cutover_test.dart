import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/crypto/double_ratchet.dart';
import 'package:phantom_messenger/core/crypto/native/phantom_crypto_native.dart';

/// Exercises the REAL native-backed ratchet path (the production cutover) by
/// loading the host `libphantom_crypto.so` and forcing the gate on, so a
/// `RatchetSession` runs its crypto in the Rust core exactly as it does on a
/// device where the on-device oracle passed. The pure-Dart path is covered by
/// double_ratchet_test.dart; this file proves the native path and the Dart↔Rust
/// integration glue (metadata clearing, status-driven DH-ratchet detection,
/// persistence round-trip) are correct end-to-end.
///
/// Skips cleanly when the host .so isn't built (`cargo build --release` in
/// rust/phantom_crypto), so it never fails a CI without the toolchain.
void main() {
  const soPath = 'rust/phantom_crypto/target/release/libphantom_crypto.so';
  final soExists = File(soPath).existsSync();

  Uint8List m(String s) => Uint8List.fromList(s.codeUnits);
  String s(Uint8List b) => String.fromCharCodes(b);
  Uint8List rand(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  Future<({RatchetSession alice, RatchetSession bob})> pair(
      {Uint8List? aliceX3dhEk}) async {
    final sharedSecret = rand(32);
    final bobKp = await (await X25519().newKeyPair()).extract();
    final bobPub = Uint8List.fromList((await bobKp.extractPublicKey()).bytes);
    final alice = await RatchetSession.initAsSender(
      sharedSecret: sharedSecret,
      remotePublicKey: bobPub,
      x3dhEphemeralKeyBytes: aliceX3dhEk,
    );
    final bob = await RatchetSession.initAsReceiver(
        sharedSecret: sharedSecret, ourEncryptionKP: bobKp);
    return (alice: alice, bob: bob);
  }

  group('Native-backed ratchet cutover (host .so)', () {
    setUpAll(() async {
      if (!soExists) return;
      final ok = await NativeCryptoGate.instance.enableForTest(soPath);
      expect(ok, isTrue,
          reason: 'host parity + ratchet oracles must pass to trust native');
      // With a blob key set, every native session persists as a sealed blob —
      // so the tests below (persistence round-trips, metadata) exercise the blob
      // path end-to-end, not just plaintext.
      NativeCryptoGate.instance.sessionBlobKey =
          Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) & 0xff));
    });

    test('sessions become native-backed once the gate is enabled', () async {
      if (!soExists) return markTestSkipped('host .so not built');
      final p = await pair();
      expect(p.alice.isNativeBacked, isTrue);
      expect(p.bob.isNativeBacked, isTrue);
    });

    test('full ping-pong drives native DH ratchet on both sides', () async {
      if (!soExists) return markTestSkipped('host .so not built');
      final p = await pair();
      // A→B primes Bob's receiving chain (Bob DH-ratchets).
      expect(s(await p.bob.decrypt(await p.alice.encrypt(m('a0')))), 'a0');
      // Bob replies → Alice DH-ratchets on receipt.
      expect(s(await p.alice.decrypt(await p.bob.encrypt(m('b0')))), 'b0');
      for (var i = 1; i <= 12; i++) {
        expect(s(await p.bob.decrypt(await p.alice.encrypt(m('a$i')))), 'a$i');
        expect(s(await p.alice.decrypt(await p.bob.encrypt(m('b$i')))), 'b$i');
      }
    });

    test('out-of-order delivery uses native skipped keys', () async {
      if (!soExists) return markTestSkipped('host .so not built');
      final p = await pair();
      final cts = [for (var i = 0; i < 6; i++) await p.alice.encrypt(m('m$i'))];
      for (final i in [5, 3, 0, 4, 2, 1]) {
        expect(s(await p.bob.decrypt(cts[i])), 'm$i');
      }
    });

    test('a tampered frame is rejected without corrupting native state',
        () async {
      if (!soExists) return markTestSkipped('host .so not built');
      final p = await pair();
      final good = await p.alice.encrypt(m('clean'));
      final tampered = EncryptedMessage(
        encryptedHeader: good.encryptedHeader,
        ciphertext: Uint8List.fromList(good.ciphertext)..[0] ^= 1,
        nonce: good.nonce,
      );
      await expectLater(p.bob.decrypt(tampered), throwsA(isA<RatchetException>()));
      // The atomic native decrypt left Bob's state intact, so the clean frame
      // still decrypts.
      expect(s(await p.bob.decrypt(good)), 'clean');
    });

    test('handshake metadata: preserved in toJson, cleared on DH ratchet',
        () async {
      if (!soExists) return markTestSkipped('host .so not built');
      final ek = rand(32);
      final p = await pair(aliceX3dhEk: ek);
      // While the handshake is pending, native to_json + Dart metadata overlay
      // keeps x3dh_ek and the new-session flag.
      expect((await p.alice.toJson())['x3dh_ek'], isNotNull);
      expect(p.alice.isNewSession, isTrue);
      expect(p.alice.pendingX3dhEphemeralKey, isNotNull);
      // A reply triggers Alice's DH ratchet → the status-driven detection clears
      // the metadata, mirroring pure-Dart _dhRatchet.
      await p.bob.decrypt(await p.alice.encrypt(m('hi')));
      await p.alice.decrypt(await p.bob.encrypt(m('reply')));
      expect((await p.alice.toJson())['x3dh_ek'], isNull);
      expect(p.alice.isNewSession, isFalse);
      expect(p.alice.pendingX3dhEphemeralKey, isNull);
    });

    test('persistence round-trip: native toJson → fromJson keeps decrypting',
        () async {
      if (!soExists) return markTestSkipped('host .so not built');
      final p = await pair();
      expect(s(await p.bob.decrypt(await p.alice.encrypt(m('first')))), 'first');
      // Persist Bob's advanced state via native to_json, reload → native-backed
      // again, and continue the conversation from exactly where it left off.
      final bob2 = await RatchetSession.fromJson(await p.bob.toJson());
      expect(bob2.isNativeBacked, isTrue);
      expect(bob2.endpointKey, isNotNull, reason: 'metadata survives the blob');
      expect(s(await bob2.decrypt(await p.alice.encrypt(m('second')))), 'second');
    });

    test('native Alice interoperates across a persistence boundary on both ends',
        () async {
      if (!soExists) return markTestSkipped('host .so not built');
      final p = await pair();
      // Reload both sides mid-stream (as the app does after each message) and
      // confirm the chain stays coherent through several reloads.
      var alice = p.alice, bob = p.bob;
      for (var i = 0; i < 5; i++) {
        final ct = await alice.encrypt(m('r$i'));
        expect(s(await bob.decrypt(ct)), 'r$i');
        alice = await RatchetSession.fromJson(await alice.toJson());
        bob = await RatchetSession.fromJson(await bob.toJson());
      }
    });

    test('toJson yields an opaque sealed blob, not plaintext hex', () async {
      if (!soExists) return markTestSkipped('host .so not built');
      final p = await pair();
      final j = await p.alice.toJson();
      // Sealed shape: a blob, and none of the plaintext ratchet keys.
      expect(j.containsKey('blob'), isTrue);
      expect(j.containsKey('rk'), isFalse);
      expect(j.containsKey('dhsk_priv'), isFalse);
      // The blob's bytes must not embed the plaintext hex of any secret. Decode
      // it and confirm it doesn't decode as JSON with a root key.
      final blob = base64Decode(j['blob'] as String);
      expect(blob.length, greaterThan(28)); // nonce + tag + payload
      expect(() => jsonDecode(String.fromCharCodes(blob)),
          throwsA(anything)); // ciphertext isn't JSON
    });

    test('sealed blob opens in pure Dart when native is unavailable', () async {
      if (!soExists) return markTestSkipped('host .so not built');
      // Seal a live conversation state via native, then simulate the .so being
      // gone: the blob must still open (in Dart) and keep decrypting — no
      // orphaned session.
      final p = await pair();
      final c0 = await p.alice.encrypt(m('before'));
      expect(s(await p.bob.decrypt(c0)), 'before');
      final bobBlob = await p.bob.toJson();
      final aliceNext = await p.alice.encrypt(m('after'));

      NativeCryptoGate.instance.disableForTest();
      addTearDown(() async {
        await NativeCryptoGate.instance.enableForTest(soPath);
      });

      final bobDart = await RatchetSession.fromJson(bobBlob);
      expect(bobDart.isNativeBacked, isFalse); // fell back to pure Dart
      expect(s(await bobDart.decrypt(aliceNext)), 'after');
    });

    test('legacy plaintext sessions still load (no blob key path)', () async {
      if (!soExists) return markTestSkipped('host .so not built');
      // A session serialized the OLD way (plaintext map, no 'blob' key) must
      // still load. Build one by serializing with the blob key temporarily
      // cleared so toJson emits the legacy plaintext shape.
      final saved = NativeCryptoGate.instance.sessionBlobKey;
      NativeCryptoGate.instance.sessionBlobKey = null;
      addTearDown(() => NativeCryptoGate.instance.sessionBlobKey = saved);

      final p = await pair();
      final c0 = await p.alice.encrypt(m('legacy'));
      final bobPlain = await p.bob.toJson();
      expect(bobPlain.containsKey('rk'), isTrue); // legacy plaintext shape
      final bob2 = await RatchetSession.fromJson(bobPlain);
      expect(s(await bob2.decrypt(c0)), 'legacy');
    });
  });
}

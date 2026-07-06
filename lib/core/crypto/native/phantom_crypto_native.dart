import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ffi/ffi.dart';

import '../double_ratchet.dart';
import '../hybrid_kem.dart';
import '../../transport_debugger.dart';

/// Dart FFI binding to the Rust memory-safe crypto core (`libphantom_crypto.so`,
/// crate `rust/phantom_crypto`). This is the stateless slice: X25519 DH, the
/// X3DH shared-secret composition, Ed25519 verification, and the hybrid combine
/// — each proven byte-identical to the Dart implementation.
///
/// The app routes its stateless crypto through [NativeCryptoGate] below, which
/// uses this binding ONLY after [runParityOracle] confirms the native core is
/// byte-identical on the actual device (recomputing each op both ways with
/// random inputs), else it falls back to Dart. That gate catches any
/// platform/ABI drift on real hardware before trusting Rust with a signature.

/// App-facing gate over the native core. Every method falls back to the Dart
/// implementation, and only routes through Rust once the on-device parity
/// oracle has CONFIRMED they agree ([_verified]). So the cutover is safe by
/// construction: on a device where the native lib is missing or disagrees, the
/// app transparently uses Dart — a message can never be mis-encrypted by an
/// untrusted native path. Callers use [NativeCryptoGate.instance].
class NativeCryptoGate {
  static final NativeCryptoGate instance = NativeCryptoGate._();
  NativeCryptoGate._();

  PhantomCryptoNative? _native;
  bool _verified = false;
  bool _ratchetVerified = false;

  /// True when the native core is loaded AND ran the stateless parity oracle
  /// clean, so hot-path stateless calls route through Rust.
  bool get usingNative => _verified && _native != null;

  /// True when the native ratchet passed its on-device parity oracle
  /// (encrypt/decrypt/DH-ratchet cross-verified against Dart). This is the gate
  /// for the stateful cutover — the binding is wired and verified; the message
  /// body path itself is routed once this is confirmed green on real devices.
  bool get ratchetNative => _ratchetVerified && _native != null;

  /// The verified native core, or null. Exposed so the ratchet cutover can
  /// build [NativeRatchet] handles once [ratchetNative] is true.
  PhantomCryptoNative? get native => _native;

  /// Load + verify. Call once at startup, BEFORE the crypto hot path runs.
  Future<void> init() async {
    _native = PhantomCryptoNative.tryLoad();
    if (_native == null) {
      TransportDebugger.instance.log('NATIVE: Rust core not available — using Dart');
      return;
    }
    _verified = await _native!.runParityOracle();
    if (!_verified) {
      TransportDebugger.instance
          .log('NATIVE: oracle did not pass — staying on Dart crypto');
    }
    // Independent from the stateless verdict: the ratchet has its own on-device
    // oracle. A drift here only withholds the (not-yet-live) ratchet cutover; it
    // does not disable the already-live stateless path.
    _ratchetVerified = await _verifyRatchet(_native!);
  }

  /// On-device ratchet parity oracle. Drives a full 3-step Alice↔Bob
  /// conversation where the native ratchet plays one side and the Dart ratchet
  /// the other, so a single run exercises native decrypt, the native DH-ratchet
  /// (receiving + sending), and native encrypt — all cross-verified byte-for-
  /// byte with Dart. Any ABI/platform drift shows here before a real message
  /// ever touches the native ratchet.
  Future<bool> _verifyRatchet(PhantomCryptoNative n) async {
    final dbg = TransportDebugger.instance;
    NativeRatchet? bob;
    try {
      final rng = Random.secure();
      final sharedSecret =
          Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
      final bobKP = await (await X25519().newKeyPair()).extract();
      final bobPub = Uint8List.fromList((await bobKP.extractPublicKey()).bytes);

      // Dart Alice (initiator, has a sending chain immediately) ↔ native Bob
      // (receiver, built from Bob's serialized session).
      final alice = await RatchetSession.initAsSender(
          sharedSecret: sharedSecret, remotePublicKey: bobPub);
      final bobDart = await RatchetSession.initAsReceiver(
          sharedSecret: sharedSecret, ourEncryptionKP: bobKP);
      bob = NativeRatchet.fromJson(n, jsonEncode(await bobDart.toJson()));
      if (bob == null) return _ratFail(dbg, 'from_json');

      Uint8List pt(String s) => Uint8List.fromList(utf8.encode(s));

      // 1. Dart Alice → native Bob (native receiving DH-ratchet + decrypt).
      final m0 = await alice.encrypt(pt('oracle m0'));
      final d0 = bob.decrypt(m0.encryptedHeader, m0.ciphertext, m0.nonce);
      if (d0 == null || utf8.decode(d0) != 'oracle m0') {
        return _ratFail(dbg, 'native-decrypt');
      }

      // 2. native Bob → Dart Alice (native sending after DH-ratchet; Alice
      //    DH-ratchets on her side).
      final r0 = bob.encrypt(pt('oracle r0'));
      final dr0 = await alice.decrypt(EncryptedMessage(
          encryptedHeader: r0.$1, ciphertext: r0.$2, nonce: r0.$3));
      if (utf8.decode(dr0) != 'oracle r0') {
        return _ratFail(dbg, 'native-encrypt');
      }

      // 3. Dart Alice → native Bob again (steady-state chain advance).
      final m1 = await alice.encrypt(pt('oracle m1'));
      final d1 = bob.decrypt(m1.encryptedHeader, m1.ciphertext, m1.nonce);
      if (d1 == null || utf8.decode(d1) != 'oracle m1') {
        return _ratFail(dbg, 'native-decrypt-2');
      }

      dbg.log('NATIVE: ✓ Rust ratchet parity OK '
          '(decrypt, DH-ratchet, encrypt cross-verified with Dart)');
      return true;
    } catch (e) {
      dbg.log('NATIVE: ✗ ratchet oracle error: $e');
      return false;
    } finally {
      bob?.dispose();
    }
  }

  bool _ratFail(TransportDebugger dbg, String which) {
    dbg.log('NATIVE: ✗ RATCHET PARITY MISMATCH on $which — native ratchet NOT trusted');
    return false;
  }

  /// Ed25519 verify — native when trusted, Dart otherwise. Never throws.
  Future<bool> ed25519Verify(
      Uint8List publicKey, Uint8List message, Uint8List signature) async {
    if (usingNative) {
      try {
        return _native!.ed25519Verify(publicKey, message, signature);
      } catch (_) {/* fall through to Dart */}
    }
    try {
      return await Ed25519().verify(
        message,
        signature: Signature(signature,
            publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
      );
    } catch (_) {
      return false;
    }
  }

  /// Hybrid combine — native when trusted, Dart otherwise.
  Future<Uint8List> hybridCombine(Uint8List x3dh, Uint8List kyber) async {
    if (usingNative) {
      try {
        return _native!.hybridCombine(x3dh, kyber);
      } catch (_) {/* fall through */}
    }
    return HybridKEM.combineSecrets(x3dh, kyber);
  }
}

// ── C signatures ──────────────────────────────────────────────────────────────
typedef _SharedC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _SharedD = int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);

typedef _X3dhC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>,
    Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _X3dhD = int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>,
    Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);

typedef _CombineC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _CombineD = int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);

typedef _VerifyC = Int32 Function(
    Pointer<Uint8>, Pointer<Uint8>, IntPtr, Pointer<Uint8>);
typedef _VerifyD = int Function(
    Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>);

// Stateful ratchet: opaque handle + heap-buffer outputs.
typedef _RatFromJsonC = Pointer<Void> Function(Pointer<Uint8>, IntPtr);
typedef _RatFromJsonD = Pointer<Void> Function(Pointer<Uint8>, int);

typedef _RatEncryptC = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, IntPtr,
    Pointer<Pointer<Uint8>>, Pointer<IntPtr>,
    Pointer<Pointer<Uint8>>, Pointer<IntPtr>, Pointer<Uint8>);
typedef _RatEncryptD = int Function(
    Pointer<Void>, Pointer<Uint8>, int,
    Pointer<Pointer<Uint8>>, Pointer<IntPtr>,
    Pointer<Pointer<Uint8>>, Pointer<IntPtr>, Pointer<Uint8>);

typedef _RatDecryptC = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr,
    Pointer<Uint8>, Pointer<Pointer<Uint8>>, Pointer<IntPtr>);
typedef _RatDecryptD = int Function(
    Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>, int,
    Pointer<Uint8>, Pointer<Pointer<Uint8>>, Pointer<IntPtr>);

typedef _RatFreeC = Void Function(Pointer<Void>);
typedef _RatFreeD = void Function(Pointer<Void>);

typedef _BufFreeC = Void Function(Pointer<Uint8>, IntPtr);
typedef _BufFreeD = void Function(Pointer<Uint8>, int);

class PhantomCryptoNative {
  final DynamicLibrary _lib;
  late final _SharedD _x25519 = _lib.lookupFunction<_SharedC, _SharedD>('phantom_x25519_shared');
  late final _X3dhD _x3dh = _lib.lookupFunction<_X3dhC, _X3dhD>('phantom_x3dh_initiate');
  late final _CombineD _combine = _lib.lookupFunction<_CombineC, _CombineD>('phantom_hybrid_combine');
  late final _VerifyD _verify = _lib.lookupFunction<_VerifyC, _VerifyD>('phantom_ed25519_verify');
  late final _RatFromJsonD _ratFromJson = _lib.lookupFunction<_RatFromJsonC, _RatFromJsonD>('phantom_ratchet_from_json');
  late final _RatEncryptD _ratEncrypt = _lib.lookupFunction<_RatEncryptC, _RatEncryptD>('phantom_ratchet_encrypt');
  late final _RatDecryptD _ratDecrypt = _lib.lookupFunction<_RatDecryptC, _RatDecryptD>('phantom_ratchet_decrypt');
  late final _RatFreeD _ratFree = _lib.lookupFunction<_RatFreeC, _RatFreeD>('phantom_ratchet_free');
  late final _BufFreeD _bufFree = _lib.lookupFunction<_BufFreeC, _BufFreeD>('phantom_buf_free');

  PhantomCryptoNative._(this._lib);

  /// Loads the native library, or null if unavailable on this platform/build
  /// (only Android bundles the .so today).
  static PhantomCryptoNative? tryLoad() {
    try {
      if (!Platform.isAndroid) return null;
      return PhantomCryptoNative._(DynamicLibrary.open('libphantom_crypto.so'));
    } catch (_) {
      return null;
    }
  }

  // ── Wrappers ────────────────────────────────────────────────────────────────

  Uint8List x25519Shared(Uint8List ourSeed, Uint8List theirPub) =>
      _call2(_x25519, ourSeed, theirPub);

  Uint8List hybridCombine(Uint8List x3dh, Uint8List kyber) =>
      _call2(_combine, x3dh, kyber);

  Uint8List x3dhInitiate(Uint8List ourIk, Uint8List eph, Uint8List theirIk,
      Uint8List theirSpk, Uint8List? theirOpk) {
    final a = _toC(ourIk), b = _toC(eph), c = _toC(theirIk), d = _toC(theirSpk);
    final e = theirOpk == null ? nullptr : _toC(theirOpk);
    final out = calloc<Uint8>(32);
    try {
      final rc = _x3dh(a, b, c, d, e, out);
      if (rc != 0) throw StateError('phantom_x3dh_initiate rc=$rc');
      return _fromC(out, 32);
    } finally {
      calloc.free(a); calloc.free(b); calloc.free(c); calloc.free(d);
      if (e != nullptr) calloc.free(e);
      calloc.free(out);
    }
  }

  bool ed25519Verify(Uint8List pub, Uint8List msg, Uint8List sig) {
    final p = _toC(pub), s = _toC(sig);
    final m = calloc<Uint8>(msg.isEmpty ? 1 : msg.length);
    if (msg.isNotEmpty) m.asTypedList(msg.length).setAll(0, msg);
    try {
      return _verify(p, m, msg.length, s) == 1;
    } finally {
      calloc.free(p); calloc.free(s); calloc.free(m);
    }
  }

  Uint8List _call2(_SharedD fn, Uint8List x, Uint8List y) {
    final a = _toC(x), b = _toC(y), out = calloc<Uint8>(32);
    try {
      final rc = fn(a, b, out);
      if (rc != 0) throw StateError('native rc=$rc');
      return _fromC(out, 32);
    } finally {
      calloc.free(a); calloc.free(b); calloc.free(out);
    }
  }

  static Pointer<Uint8> _toC(Uint8List b) {
    final p = calloc<Uint8>(b.length);
    p.asTypedList(b.length).setAll(0, b);
    return p;
  }

  static Uint8List _fromC(Pointer<Uint8> p, int len) =>
      Uint8List.fromList(p.asTypedList(len));

  // ── Runtime parity oracle ─────────────────────────────────────────────────
  //
  // Recomputes each op both ways with random inputs and asserts agreement. Run
  // once at startup; logs the result. This is the gate that proves the native
  // core is correct on the actual device before any hot-path cutover.

  Future<bool> runParityOracle() async {
    final dbg = TransportDebugger.instance;
    try {
      final rng = Random.secure();
      Uint8List rand(int n) =>
          Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

      final x = X25519();

      // 1. X25519 DH: random our-seed + peer keypair.
      final ourSeed = rand(32);
      final peer = await x.newKeyPairFromSeed(rand(32));
      final peerPub = Uint8List.fromList((await peer.extractPublicKey()).bytes);
      final ourKp = await x.newKeyPairFromSeed(ourSeed);
      final dartShared = Uint8List.fromList(await (await x.sharedSecretKey(
              keyPair: ourKp,
              remotePublicKey:
                  SimplePublicKey(peerPub, type: KeyPairType.x25519)))
          .extractBytes());
      if (!_eq(x25519Shared(ourSeed, peerPub), dartShared)) {
        return _fail(dbg, 'x25519');
      }

      // 2. X3DH composition: random keys, native vs a manual Dart composition
      //    (DH ordering + KDF as in X3DHHandshake).
      Future<Uint8List> pubOf(Uint8List seed) async => Uint8List.fromList(
          (await (await x.newKeyPairFromSeed(seed)).extractPublicKey()).bytes);
      Future<Uint8List> dhOf(Uint8List seed, Uint8List peer) async {
        final kp = await x.newKeyPairFromSeed(seed);
        return Uint8List.fromList(await (await x.sharedSecretKey(
                keyPair: kp,
                remotePublicKey: SimplePublicKey(peer, type: KeyPairType.x25519)))
            .extractBytes());
      }

      final aIk = rand(32), aEph = rand(32);
      final bIk = rand(32), bSpk = rand(32), bOpk = rand(32);
      final bIkPub = await pubOf(bIk), bSpkPub = await pubOf(bSpk), bOpkPub = await pubOf(bOpk);
      final d1 = await dhOf(aIk, bSpkPub);
      final d2 = await dhOf(aEph, bIkPub);
      final d3 = await dhOf(aEph, bSpkPub);
      final d4 = await dhOf(aEph, bOpkPub);
      final ikm = Uint8List.fromList([
        ...List.filled(32, 0xFF), ...d1, ...d2, ...d3, ...d4,
      ]);
      final dartX3dh = Uint8List.fromList(await (await Hkdf(
                  hmac: Hmac(Sha512()), outputLength: 32)
              .deriveKey(
                  secretKey: SecretKey(ikm),
                  nonce: Uint8List(0),
                  info: Uint8List.fromList('phantom-x3dh-v1'.codeUnits)))
          .extractBytes());
      final nativeX3dh = x3dhInitiate(aIk, aEph, bIkPub, bSpkPub, bOpkPub);
      if (!_eq(nativeX3dh, dartX3dh)) return _fail(dbg, 'x3dh');

      // 3. Hybrid combine: random secrets vs HybridKEM.combineSecrets.
      final s1 = rand(32), s2 = rand(32);
      final dartCombine = await HybridKEM.combineSecrets(s1, s2);
      if (!_eq(hybridCombine(s1, s2), dartCombine)) {
        return _fail(dbg, 'hybrid-combine');
      }

      // 4. Ed25519: sign in Dart, verify via native (true), tamper (false).
      final ed = Ed25519();
      final edKp = await ed.newKeyPairFromSeed(rand(32));
      final edPub = Uint8List.fromList((await edKp.extractPublicKey()).bytes);
      final msg = rand(24);
      final sig = Uint8List.fromList((await ed.sign(msg, keyPair: edKp)).bytes);
      if (!ed25519Verify(edPub, msg, sig)) return _fail(dbg, 'ed25519-verify');
      final badMsg = Uint8List.fromList(msg)..[0] ^= 1;
      if (ed25519Verify(edPub, badMsg, sig)) return _fail(dbg, 'ed25519-tamper');

      dbg.log('NATIVE: ✓ Rust crypto core loaded + parity OK '
          '(x25519, x3dh, hybrid, ed25519)');
      return true;
    } catch (e) {
      dbg.log('NATIVE: ✗ parity oracle error: $e');
      return false;
    }
  }

  bool _fail(TransportDebugger dbg, String which) {
    dbg.log('NATIVE: ✗ PARITY MISMATCH on $which — Rust core NOT trusted');
    return false;
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ── Stateful ratchet handle ───────────────────────────────────────────────────

/// Holds the raw `*mut RatchetSession` and the free function, kept separate from
/// [NativeRatchet] so a [Finalizer] can reclaim it without a reference cycle
/// pinning the owner alive.
class _RatchetHandle {
  final _RatFreeD _free;
  final Pointer<Void> ptr;
  bool _freed = false;
  _RatchetHandle(this._free, this.ptr);
  void dispose() {
    if (_freed) return;
    _freed = true;
    _free(ptr);
  }
}

/// A live double-ratchet session owned by the Rust core. The secret state
/// (root/chain/message/header keys) lives in native memory and is zeroized when
/// the handle is freed — either explicitly via [dispose] or, as a safety net,
/// when this object is garbage-collected (via [Finalizer]).
///
/// Built from a Dart [RatchetSession]'s serialized form ([RatchetSession.toJson]
/// / [RatchetSession.takeSnapshot]); Rust reads only the ratchet fields and
/// ignores the handshake metadata Dart carries alongside.
class NativeRatchet {
  final PhantomCryptoNative _n;
  final _RatchetHandle _h;

  static final Finalizer<_RatchetHandle> _finalizer =
      Finalizer((h) => h.dispose());

  NativeRatchet._(this._n, this._h) {
    _finalizer.attach(this, _h, detach: this);
  }

  /// Parse a serialized session into a native handle, or null on bad JSON.
  static NativeRatchet? fromJson(PhantomCryptoNative n, String json) {
    final bytes = utf8.encode(json);
    final p = calloc<Uint8>(bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    try {
      final handle = n._ratFromJson(p, bytes.length);
      if (handle == nullptr) return null;
      return NativeRatchet._(n, _RatchetHandle(n._ratFree, handle));
    } finally {
      calloc.free(p);
    }
  }

  /// Encrypt [plaintext], advancing the sending chain in native memory. Returns
  /// (encryptedHeader, ciphertext, nonce). Throws if the session cannot send.
  (Uint8List, Uint8List, Uint8List) encrypt(Uint8List plaintext) {
    final pt = _alloc(plaintext);
    final hdrOut = calloc<Pointer<Uint8>>();
    final hdrLen = calloc<IntPtr>();
    final ctOut = calloc<Pointer<Uint8>>();
    final ctLen = calloc<IntPtr>();
    final nonce = calloc<Uint8>(12);
    try {
      final rc = _n._ratEncrypt(
          _h.ptr, pt, plaintext.length, hdrOut, hdrLen, ctOut, ctLen, nonce);
      if (rc != 0) throw StateError('ratchet encrypt rc=$rc');
      return (
        _takeBuf(hdrOut.value, hdrLen.value),
        _takeBuf(ctOut.value, ctLen.value),
        Uint8List.fromList(nonce.asTypedList(12)),
      );
    } finally {
      calloc.free(pt);
      calloc.free(hdrOut);
      calloc.free(hdrLen);
      calloc.free(ctOut);
      calloc.free(ctLen);
      calloc.free(nonce);
    }
  }

  /// Decrypt one message. Returns the plaintext, or null if undecryptable /
  /// tampered — in which case the native state is left untouched (the Rust side
  /// commits only on success), so a failed attempt never corrupts the ratchet.
  Uint8List? decrypt(Uint8List header, Uint8List ciphertext, Uint8List nonce) {
    final h = _alloc(header);
    final c = _alloc(ciphertext);
    final nn = _alloc(nonce);
    final ptOut = calloc<Pointer<Uint8>>();
    final ptLen = calloc<IntPtr>();
    try {
      final rc = _n._ratDecrypt(_h.ptr, h, header.length, c, ciphertext.length,
          nn, ptOut, ptLen);
      if (rc != 0) return null;
      return _takeBuf(ptOut.value, ptLen.value);
    } finally {
      calloc.free(h);
      calloc.free(c);
      calloc.free(nn);
      calloc.free(ptOut);
      calloc.free(ptLen);
    }
  }

  /// Free the native session now (idempotent). After this the handle must not
  /// be used again.
  void dispose() {
    _finalizer.detach(this);
    _h.dispose();
  }

  // Copy a Rust-allocated (ptr,len) buffer into a Dart list, then hand the
  // native memory back for freeing. Never leaks across the boundary.
  Uint8List _takeBuf(Pointer<Uint8> ptr, int len) {
    final out = Uint8List.fromList(ptr.asTypedList(len));
    _n._bufFree(ptr, len);
    return out;
  }

  // Allocate a C buffer holding [b] (min 1 byte so length-0 inputs still yield a
  // non-null pointer; the length passed separately tells Rust the true size).
  static Pointer<Uint8> _alloc(Uint8List b) {
    final p = calloc<Uint8>(b.isEmpty ? 1 : b.length);
    if (b.isNotEmpty) p.asTypedList(b.length).setAll(0, b);
    return p;
  }
}

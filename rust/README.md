# Rust crypto core (`phantom_crypto`)

Memory-safe reimplementation of Phantom's security-critical crypto, replacing
the Dart in `lib/core/crypto/` primitive by primitive. Motivation (from the
crypto audit): **Dart's GC cannot reliably wipe key material from RAM** — a
root/chain key in a `Uint8List` may be copied and left in memory. Rust closes
that gap and, as a bonus, uses the vetted dalek / RustCrypto families that
libsignal is built on.

## What Rust buys us here

- **Deterministic zeroization** (`zeroize`): every secret (`Secret32`) is wiped
  on drop — the key material's lifetime in RAM shrinks to its actual use.
- **Constant-time comparison** (`subtle`): no secret-dependent branches.
- **`mlock` (next slice)**: pin secret pages so they never hit swap/disk.
- **Audited primitives**: `x25519-dalek`, `chacha20poly1305`, `hkdf`, `sha2`.

## Proven byte-for-byte identical to Dart

The migration must not change on-wire behaviour. `tool/gen_crypto_vectors.dart`
runs the **live Dart** crypto over fixed inputs and prints reference hex; the
Rust parity tests assert exactly those bytes:

```
dart run tool/gen_crypto_vectors.dart      # regenerate reference vectors
cd rust/phantom_crypto && cargo test       # 6/6 parity + round-trip + tamper
```

Covered so far (byte-identical, 9/9 parity tests):

- **Slice 1** — X25519 public + DH, HKDF-SHA512, the X3DH KDF (F-prefix +
  concat), ChaCha20-Poly1305 AEAD (ciphertext + tag split the way the ratchet
  stores it), `Secret32` zeroization, constant-time compare.
- **Slice 2** — the double-ratchet KDFs: `_kdfInitialHeaderKey`,
  `_kdfRootKey` (root|chain|next-header split), `_kdfChainKey` (new-CK via
  HMAC + message enc/header keys via HMAC→HKDF), same domain-separation
  strings, intermediates zeroized.
- **Slice 3** — Ed25519 (public/sign/verify, for SPK + IK signatures) and the
  X3DH shared-secret composition (`x3dh_initiate` / `x3dh_respond`, same DH
  ordering as `X3DHHandshake`). Tests assert the Dart vector AND the
  fundamental property that initiate and respond derive the same secret, with
  and without a one-time prekey.
- **Slice 4** — `hybrid_combine` (the Kyber×X3DH mix, HKDF). Parity-proven.
  The Kyber-768 KEM *itself* is deliberately NOT ported yet — see the Kyber
  note below.
- **Slice 5** — the full stateful `RatchetSession` (`src/ratchet.rs`):
  encrypt / decrypt / DH-ratchet / skipped-key handling / the capped
  skipped-key store, plus `from_json` for the Dart session format. The crown
  test loads a session Bob **serialized in Dart** and decrypts two messages
  Alice **encrypted in Dart** — proving the Rust ratchet is wire-identical and
  can take over decryption. Secret state zeroizes on drop.
- **Slice 6** — the C-ABI (`src/ffi.rs`). Two shapes:
  - *Stateless*: X25519, X3DH, Ed25519 verify, hybrid combine, each writing
    into a caller buffer with 0/≠0 return (nothing to allocate/free).
  - *Stateful ratchet*: an opaque `*mut RatchetSession` handle from
    `phantom_ratchet_from_json`, mutated in place by `phantom_ratchet_encrypt`
    / `_decrypt`, released by `phantom_ratchet_free`. Variable-length outputs
    are heap-allocated by Rust and freed by the caller via `phantom_buf_free`.
    `_decrypt` is ATOMIC — it works on a clone and commits only on success, so
    a wrong-session / tampered frame leaves the ratchet state untouched
    (matching Dart's "try each session, restore on failure" contract).
  `cargo build --release` emits `libphantom_crypto.so` (Android/Linux) + `.a`
  (iOS).

`cargo test` → 20/20 (parity + ratchet cross-compat + FFI null-safety +
stateful-handle round-trip & atomicity).

## Kyber-768: why it stays in Dart for now

The Dart `post_quantum` package implements **round-3 Kyber** (SHAKE256 KDF over
the ciphertext hash). The Rust `ml-kem` crates implement **FIPS-203 ML-KEM**,
which changed the final KDF — so the same ciphertext decapsulates to a
*different* shared secret across the two. They are not wire-compatible. Kyber
therefore either (a) stays in Dart and hands its 32-byte secret to
`hybrid_combine`, or (b) migrates on BOTH sides at once during the cutover
(with a round-3 Rust crate, cross-verified). Forcing it now would silently
break hybrid sessions mid-migration.

## Status — crypto ported + parity-proven; FFI wiring is what remains

**This crate is validated but NOT yet wired into the app.** The Dart crypto is
still what ships. This slice proves the toolchain + primitives + parity, which
was the prerequisite before committing to the full port.

### Android: WIRED (loaded + runtime-verified on device)

The native core is built and connected on Android:

```
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/28.2.13676358
cd rust/phantom_crypto
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o ../../android/app/src/main/jniLibs build --release
```

produces `libphantom_crypto.so` for all three ABIs, committed under
`android/app/src/main/jniLibs/` (rebuild with the command above after any Rust
change — a gradle/cargokit build hook to automate this is a follow-up). The
`.so` is packaged in the APK (verified: `lib/<abi>/libphantom_crypto.so`).

`lib/core/crypto/native/phantom_crypto_native.dart` is the `dart:ffi` binding.
At startup (`main.dart`) it runs a **runtime parity oracle**: it recomputes
X25519 / X3DH / hybrid-combine / Ed25519-verify both ways (Dart + native) with
random inputs on the actual device and logs `NATIVE: ✓ … parity OK` (or a
mismatch) to the in-app Transport Debugger.

### Hot-path cutover: DONE for the stateless ops (safe by construction)

`NativeCryptoGate` (same file) is the app-facing facade. `init()` runs the
oracle once at startup and sets `usingNative` **only if it passed**. The real
crypto now routes through it:

- `ed25519Verify` — the SPK signature check (`X3DHHandshake._verifySignedPreKey`),
  the IK↔SK identity binding (`ContactAddress.verifyIdentityBinding` and
  `PhantomCore._verifyInitCaBinding`), and the endpoint-signature check in
  `addContact`.
- `hybridCombine` — the Kyber×X3DH mix in `X3DHHandshake` initiation.

Every method **falls back to Dart** when the native lib is missing or the
oracle didn't confirm parity, and again inside a `try/catch` per call. So on a
device where Rust is absent or disagrees, the app transparently uses Dart — a
signature can never be mis-verified nor a secret mis-combined by an untrusted
native path. The verdict shows as `NATIVE: ✓ … parity OK` / `staying on Dart
crypto` in the Transport Debugger.

### Stateful ratchet FFI: BUILT + on-device oracle (cutover staged)

The hand-written opaque-handle FFI (above) is wired into Dart as `NativeRatchet`
in `phantom_crypto_native.dart` — a handle with a `Finalizer` safety-net free,
marshalling the variable-length header/ciphertext/plaintext buffers and copying
them out before handing the native memory back to `phantom_buf_free`.

At startup `NativeCryptoGate.init()` now also runs a **ratchet parity oracle**
(`_verifyRatchet`): it drives a full 3-step Alice↔Bob conversation where the
native ratchet plays one side and the Dart ratchet the other, so one run
exercises native decrypt, the native DH-ratchet (receiving + sending), and
native encrypt — each cross-verified byte-for-byte with Dart. The verdict logs
as `NATIVE: ✓ Rust ratchet parity OK` (sets `ratchetNative`) or a mismatch to
the Transport Debugger. This is the same discipline used for the stateless ops:
prove the mechanism + on-device parity FIRST, then route real messages.

Routing the message body (`RatchetSession.encrypt`/`decrypt` in
`protocol/message.dart`) through `NativeRatchet` is the last step, staged behind
`ratchetNative` being confirmed green on real devices — because unlike the
stateless ops, it moves the ratchet state's ownership, so it warrants the
on-device confirmation first. The Dart `RatchetSession` keeps the handshake
metadata (`pendingX3dhEphemeralKey`, `endpointKey`, …) the transport reads.

### What remains

1. **Route the message body through `NativeRatchet`** once `ratchetNative` is
   confirmed green on both devices (needs a native `to_json` to persist the
   mutated state back for Hive, preserving Dart's metadata fields).
2. **iOS** — a **macOS builder** for the `.a`/xcframework (cross-compile from
   Linux isn't possible for the iOS targets); Linux desktop can load the
   host `.so` directly.
3. **`mlock`** the ratchet's secret pages, and **Kyber** per the note above.

Nothing changes the on-wire format — the parity vectors + the runtime oracle
are the guardrails.

## Threat-model honesty

This raises the bar; it is not magic. On a device already compromised with
root, an attacker can read live process memory regardless of language.
Zeroization shrinks the *window* a scrape can catch a key, and `mlock` stops
secrets reaching disk — meaningful defense-in-depth, not invulnerability.

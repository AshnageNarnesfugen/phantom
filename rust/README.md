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
- **Slice 6 (partial)** — the stateless C-ABI (`src/ffi.rs`): X25519, X3DH,
  Ed25519 verify, hybrid combine, each writing into a caller buffer with 0/≠0
  return (nothing to allocate/free across the boundary). `cargo build
  --release` now emits `libphantom_crypto.so` (Android/Linux) and `.a` (iOS).

`cargo test` → 18/18 (parity + ratchet cross-compat + FFI null-safety).

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

### What remains

1. **Stateful ratchet over FFI** — `RatchetSession` needs opaque session
   handles + a `free` + length-prefixed buffers; better generated by
   `flutter_rust_bridge` than hand-written. This is the message body path
   (encrypt/decrypt); the stateless cutover above is already live.
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

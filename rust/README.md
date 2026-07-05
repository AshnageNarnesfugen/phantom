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

## Status — slices 1–3 done, not yet wired into the app

**This crate is validated but NOT yet wired into the app.** The Dart crypto is
still what ships. This slice proves the toolchain + primitives + parity, which
was the prerequisite before committing to the full port.

Remaining slices, in order:

1. **Kyber-768 hybrid** — via a FIPS-203 `ml-kem` crate, `combineSecrets` (mix
   the X3DH secret with the Kyber shared secret).
2. **Double-ratchet state machine** — the stateful `RatchetSession`
   (encrypt/decrypt/skip/DH-ratchet), reusing the slice-2 KDFs + slice-3 X3DH,
   with `mlock`ed secret state. Kept behind a thin, byte-oriented API so the
   Dart session layer calls into it.
3. **FFI via `flutter_rust_bridge`** — compile to `.so` (Android via
   `cargo-ndk` + NDK 28, already installed), `.a`/xcframework (iOS), `.so`
   (Linux). FRB generates the Dart bindings. Add `cdylib`/`staticlib` to
   `[lib] crate-type`. Then swap `lib/core/crypto/` call sites to the bridge,
   keeping the Dart impl as a reference oracle in tests (both must agree).

Requires for slice 5: `cargo install cargo-ndk` and, for iOS, a macOS builder
(cross-compile from Linux isn't possible for the iOS targets).

## Threat-model honesty

This raises the bar; it is not magic. On a device already compromised with
root, an attacker can read live process memory regardless of language.
Zeroization shrinks the *window* a scrape can catch a key, and `mlock` stops
secrets reaching disk — meaningful defense-in-depth, not invulnerability.

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
- **`mlock`**: the live ratchet session's secret pages are pinned (best-effort)
  so the root/chain/header keys can't be paged out to swap/disk.
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

`cargo test` → 29/29 (parity + ratchet cross-compat + FFI null-safety +
stateful-handle round-trip, atomicity, status + to_json persistence, sealed-blob
round-trip & wrong-key rejection, Kyber-768 keygen/encaps/decaps parity +
implicit-rejection deviation lock).

## Kyber-768: MIGRATED (round-3 wire-compatible via libcrux)

The Dart `post_quantum` package implements **round-3 Kyber** (SHAKE256 KDF over
the ciphertext hash), NOT FIPS-203 ML-KEM (different final KDF — the two don't
cross-decapsulate). The escape hatch: **`libcrux-ml-kem` with the `kyber`
feature** — the formally verified (hax/F*) implementation libsignal uses for
PQXDH — implements exactly the round-3 variant. Parity-proven against vectors
from the live Dart (`tool/gen_kyber_vectors.dart` → `src/kyber_test_vectors.rs`):
**keygen, encapsulation (ct AND ss), and decapsulation are byte-identical**, so
the migration changes nothing on the wire (`src/kyber.rs`).

Bonus security fix: Dart's implicit-rejection comparison is not constant-time
(its own source warns about it); libcrux's decapsulation is verified
constant-time.

**Known deviation (interop-irrelevant, locked in by test)**: on a
tampered/foreign ciphertext, Dart derives the round-3 reference rejection
`SHAKE256(z ‖ H(ct))` while libcrux derives the ML-KEM-style
`SHAKE256(PRF(z ‖ ct) ‖ H(ct))`. That secret only exists on a corrupted/forged
ciphertext, where ANY value is equally wrong — the handshake fails identically
on every implementation pairing and nothing persists it. Security holds in both
(pseudorandom output, no failure signal).

Runtime: three more C-ABI functions (`phantom_kyber768_keypair` /
`_encapsulate` / `_decapsulate`, fixed-size buffers) behind their own on-device
oracle (`kyberNative`): keygen parity + same-nonce encaps parity + cross
decapsulation in BOTH directions (native ct → Dart decaps, Dart ct → native
decaps). Routed call sites: `_initKyberKeys` (keygen), X3DH initiation
(encapsulate), INIT-frame handling (decapsulate). Dart fallback as always.

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

### Stateful ratchet cutover: DONE (native is the source of truth)

The hand-written opaque-handle FFI is wired into Dart as `NativeRatchet` in
`phantom_crypto_native.dart` — a handle with a `Finalizer` safety-net free,
marshalling the variable-length header/ciphertext/plaintext buffers.

At startup `NativeCryptoGate.init()` runs a **ratchet parity oracle**
(`_verifyRatchet`): a full 3-step Alice↔Bob conversation with the native ratchet
on one side and Dart on the other, exercising native decrypt, the native
DH-ratchet (recv + send), and native encrypt — each cross-verified byte-for-byte.
It sets `ratchetNative` and logs `NATIVE: ✓ Rust ratchet parity OK`.

Once green on both devices, the cutover went live. When `ratchetNative`, a
`RatchetSession` becomes **native-backed**: the ratchet crypto state (root /
chain / message / header keys) lives in the Rust core (`_native` handle), not the
Dart `_…` fields. `encrypt`/`decrypt` delegate to it; the ephemeral message keys
and DH outputs are computed and **zeroized in native**, never touching Dart's GC
heap. The design keeps memory hygiene honest:

- **Secrets cross to Dart as hex only at persist** (`toJson` → `phantom_ratchet_to_json`),
  exactly as the pure-Dart ratchet already did when saving to Hive — no new
  exposure. Between messages the live state stays in native.
- **The hot path uses a non-secret status accessor** (`phantom_ratchet_status`:
  counters + the remote *public* key), so the wrapper drives its handshake-
  metadata logic (INIT-resend cutoff, DH-ratchet detection) without pulling any
  secret. `_tryDecryptAsMsg` skips its snapshot/restore for native sessions
  (native `decrypt` is atomic), so a decrypt probe never serializes secrets.
- **The Dart `RatchetSession` keeps the handshake metadata** (`pendingX3dhEphemeralKey`,
  `kyberCipher`, `opkId`, `endpointKey`, `isNewSession`) in both modes; Rust
  neither tracks nor needs it. `toJson` overlays it onto the native ratchet JSON.

Fully fallback-safe: where `ratchetNative` is false (no `.so`, oracle red,
non-Android), sessions stay pure-Dart and byte-identical. Verified end-to-end by
`test/native_ratchet_cutover_test.dart`, which loads the host `.so` and runs
native-backed sessions through ping-pong + DH ratchet + out-of-order + tamper +
persistence round-trips.

### `mlock`: DONE

`phantom_ratchet_from_json` `mlock`s the boxed session's page(s) so the
inline root / chain / message / header keys can't be swapped to disk;
`phantom_ratchet_free` `munlock`s before the `Drop` zeroizes and frees.
Best-effort — a failed `mlock` (e.g. `RLIMIT_MEMLOCK`) is non-fatal, the ratchet
just runs unpinned. The skipped-key map allocates separately, so its bounded,
transient keys aren't pinned; the crown secrets (inline in the struct) are.

### Opaque-blob persistence: DONE (closes the last hex gap)

A native-backed session no longer persists as a hex map. `toJson` calls
`phantom_ratchet_seal`, which ChaCha20-Poly1305's the state *inside native* under
a key HKDF'd from the seed (`phantom-ratchet-blob-v1`, set by
`PhantomStorage.initialize`) and returns only ciphertext — so the root / chain /
header keys never appear as plaintext hex in Dart memory, even at persist. Stored
as `{'blob': base64, …metadata}`; the handshake metadata stays plaintext (it's
Dart-owned live state anyway).

`fromJson` detects the `blob` key and calls `phantom_ratchet_open` → a native
handle (state stays in the Rust core). **No hard native dependency**: the blob is
a standard ChaCha20-Poly1305 payload, so if the `.so` is ever unavailable, Dart
opens it itself (`_openBlobDart`) and runs pure-Dart — a lost `.so` degrades
gracefully instead of orphaning sessions. Legacy plaintext sessions still load
and get re-sealed on their next save (transparent migration). Verified by
`test/native_ratchet_cutover_test.dart` (opaque-blob shape, native↔native
round-trip, Dart-open fallback, legacy load).

### What remains

Nothing — the migration is complete. Every security-critical primitive
(X25519/X3DH, Ed25519 verification, HKDF chains, the full double ratchet,
hybrid combine, and Kyber-768) now runs in Rust when the on-device oracles are
green, with the byte-identical Dart implementation as automatic fallback.
Possible future work: migrating both sides to FIPS-203 ML-KEM (a coordinated
on-wire change, only worth it if the round-3 scheme is ever deprecated).

Nothing changes the on-wire format — the parity vectors + the runtime oracle
are the guardrails.

### Platform scope: Android-first, iOS not a priority

The target is **Android**, and it stays that way. Flutter is kept for the
*option* of other platforms later (desktop labs already load the host `.so`),
not because iOS is on the roadmap — iOS is deliberately deprioritized (a more
restrictive sandbox, and it would need a macOS builder for the `.a`/xcframework
since the iOS targets can't cross-compile from Linux). If iOS ever happens, the
crate already emits a `staticlib`; until then no effort goes there.

## Threat-model honesty

This raises the bar; it is not magic. On a device already compromised with
root, an attacker can read live process memory regardless of language.
Zeroization shrinks the *window* a scrape can catch a key, and `mlock` stops
secrets reaching disk — meaningful defense-in-depth, not invulnerability.

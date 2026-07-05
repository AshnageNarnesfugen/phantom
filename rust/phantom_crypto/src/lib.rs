//! Memory-safe crypto core for Phantom.
//!
//! This crate replaces, primitive by primitive, the security-critical crypto
//! currently in Dart (`lib/core/crypto/`). Rust buys the two things Dart's
//! garbage collector cannot give us:
//!
//!   * **Deterministic secret zeroization** — every secret type here is
//!     `ZeroizeOnDrop`, so key material is wiped from RAM the moment it goes
//!     out of scope, shrinking the window where a memory scrape leaks keys.
//!     In Dart a `Uint8List` holding a root key may be copied by the GC and
//!     never overwritten.
//!   * **Constant-time comparison** (`subtle`) — no secret-dependent branches.
//!
//! Plus vetted, widely-audited implementations (the dalek / RustCrypto
//! families, as used by libsignal) instead of a single Dart package.
//!
//! Every function is proven **byte-for-byte identical** to the Dart it
//! replaces by the parity tests below (vectors generated from the live Dart
//! via `tool/gen_crypto_vectors.dart`), so the migration cannot silently
//! change on-wire behaviour.
//!
//! Scope of this first slice: the primitives + KDFs + AEAD + secret handling.
//! The double-ratchet state machine, X3DH orchestration, Kyber-768 and the
//! `flutter_rust_bridge` FFI are the next slices (see README).

use chacha20poly1305::aead::{AeadInPlace, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, Tag};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha512;
use subtle::ConstantTimeEq;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop};

type HmacSha512 = Hmac<Sha512>;

/// A 32-byte secret that is wiped from memory when dropped. Use this for any
/// key material (DH outputs, chain/root keys, derived keys) so it never
/// lingers in RAM — the core reason this crate exists.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct Secret32(pub [u8; 32]);

impl Secret32 {
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
    /// Constant-time equality — never leak whether two secrets match via timing.
    pub fn ct_eq(&self, other: &Secret32) -> bool {
        self.0.ct_eq(&other.0).into()
    }
}

/// Constant-time comparison of two byte slices (unequal lengths → false).
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.ct_eq(b).into()
}

// ── X25519 ────────────────────────────────────────────────────────────────────

/// X25519 public key from a 32-byte seed (RFC 7748 clamping applied by dalek).
pub fn x25519_public(seed: &[u8; 32]) -> [u8; 32] {
    let sk = StaticSecret::from(*seed);
    PublicKey::from(&sk).to_bytes()
}

/// X25519 Diffie-Hellman: shared secret from our seed and their public key.
/// The result is wrapped in [`Secret32`] so it is zeroized after use.
pub fn x25519_shared(our_seed: &[u8; 32], their_pub: &[u8; 32]) -> Secret32 {
    let sk = StaticSecret::from(*our_seed);
    let pk = PublicKey::from(*their_pub);
    Secret32(sk.diffie_hellman(&pk).to_bytes())
}

// ── HKDF-SHA512 ───────────────────────────────────────────────────────────────

/// HKDF-SHA512 extract-then-expand (RFC 5869). Empty `salt` is treated as the
/// RFC's HashLen-zeros salt, matching the Dart `cryptography` package.
pub fn hkdf_sha512(ikm: &[u8], salt: &[u8], info: &[u8], out: &mut [u8]) {
    let hk = Hkdf::<Sha512>::new(Some(salt), ikm);
    hk.expand(info, out).expect("hkdf expand length within bound");
}

/// X3DH shared-secret KDF, identical to `X3DHHandshake._kdf`:
/// `HKDF-SHA512(ikm = 0xFF*32 || dh1 || dh2 || dh3 [|| dh4], salt = "",
/// info = "phantom-x3dh-v1", L = 32)`.
pub fn x3dh_kdf(
    dh1: &[u8; 32],
    dh2: &[u8; 32],
    dh3: &[u8; 32],
    dh4: Option<&[u8; 32]>,
) -> Secret32 {
    let mut ikm = Vec::with_capacity(32 * 5);
    ikm.extend_from_slice(&[0xFFu8; 32]); // F domain separator
    ikm.extend_from_slice(dh1);
    ikm.extend_from_slice(dh2);
    ikm.extend_from_slice(dh3);
    if let Some(d4) = dh4 {
        ikm.extend_from_slice(d4);
    }
    let mut out = [0u8; 32];
    hkdf_sha512(&ikm, b"", b"phantom-x3dh-v1", &mut out);
    ikm.zeroize(); // wipe the concatenated DH material
    Secret32(out)
}

// ── Double-ratchet KDFs ───────────────────────────────────────────────────────
//
// Exact ports of double_ratchet.dart's _kdfInitialHeaderKey / _kdfRootKey /
// _kdfChainKey, same domain-separation strings, proven byte-identical below.

/// `_kdfInitialHeaderKey`: HKDF-SHA512(ikm = shared, salt = "", info = dir).
pub fn kdf_initial_header_key(shared: &[u8; 32], direction: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    hkdf_sha512(shared, b"", direction, &mut out);
    out
}

/// `_kdfRootKey`: HKDF-SHA512(ikm = dh_output, salt = root_key,
/// info = "phantom-ratchet-root-key", L = 96) → (new_root, chain, next_header).
pub fn kdf_root_key(
    root_key: &[u8; 32],
    dh_output: &[u8; 32],
) -> (Secret32, Secret32, [u8; 32]) {
    let hk = Hkdf::<Sha512>::new(Some(root_key), dh_output);
    let mut buf = [0u8; 96];
    hk.expand(b"phantom-ratchet-root-key", &mut buf)
        .expect("hkdf expand 96");
    let mut new_root = [0u8; 32];
    let mut chain = [0u8; 32];
    let mut next_hk = [0u8; 32];
    new_root.copy_from_slice(&buf[0..32]);
    chain.copy_from_slice(&buf[32..64]);
    next_hk.copy_from_slice(&buf[64..96]);
    buf.zeroize();
    (Secret32(new_root), Secret32(chain), next_hk)
}

/// `_kdfChainKey`:
///   new_ck  = HMAC-SHA512(key = ck, [0x01])[0..32]
///   mk_mac  = HMAC-SHA512(key = ck, "phantom-ratchet-chain-key")   (64 bytes)
///   mk      = HKDF-SHA512(ikm = mk_mac, salt = "",
///             info = "phantom-ratchet-message-key", L = 64)
///             enc_key = mk[0..32], header_key = mk[32..64]
pub fn kdf_chain_key(chain_key: &[u8; 32]) -> (Secret32, Secret32, [u8; 32]) {
    // new chain key
    let mut m1 = <HmacSha512 as Mac>::new_from_slice(chain_key).expect("hmac key");
    m1.update(&[0x01]);
    let ck_mac = m1.finalize().into_bytes(); // 64 bytes
    let mut new_ck = [0u8; 32];
    new_ck.copy_from_slice(&ck_mac[0..32]);

    // message-key material
    let mut m2 = <HmacSha512 as Mac>::new_from_slice(chain_key).expect("hmac key");
    m2.update(b"phantom-ratchet-chain-key");
    let mut mk_mac = m2.finalize().into_bytes(); // 64 bytes, used as HKDF ikm

    let mut mk = [0u8; 64];
    hkdf_sha512(&mk_mac, b"", b"phantom-ratchet-message-key", &mut mk);
    mk_mac.zeroize();

    let mut enc_key = [0u8; 32];
    let mut header_key = [0u8; 32];
    enc_key.copy_from_slice(&mk[0..32]);
    header_key.copy_from_slice(&mk[32..64]);
    mk.zeroize();

    (Secret32(new_ck), Secret32(enc_key), header_key)
}

// ── ChaCha20-Poly1305 AEAD ────────────────────────────────────────────────────

/// AEAD encrypt. Returns `(ciphertext, 16-byte tag)` split the same way the
/// Dart ratchet stores them (`[...cipherText, ...mac]`).
pub fn chacha20poly1305_encrypt(
    key: &[u8; 32],
    nonce12: &[u8; 12],
    aad: &[u8],
    plaintext: &[u8],
) -> (Vec<u8>, [u8; 16]) {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let mut buf = plaintext.to_vec();
    let tag: Tag = cipher
        .encrypt_in_place_detached(Nonce::from_slice(nonce12), aad, &mut buf)
        .expect("chacha encrypt");
    let mut tag_arr = [0u8; 16];
    tag_arr.copy_from_slice(&tag);
    (buf, tag_arr)
}

/// AEAD decrypt. Returns the plaintext, or `None` on authentication failure.
pub fn chacha20poly1305_decrypt(
    key: &[u8; 32],
    nonce12: &[u8; 12],
    aad: &[u8],
    ciphertext: &[u8],
    tag: &[u8; 16],
) -> Option<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let mut buf = ciphertext.to_vec();
    cipher
        .decrypt_in_place_detached(Nonce::from_slice(nonce12), aad, &mut buf, Tag::from_slice(tag))
        .ok()?;
    Some(buf)
}

// ── Parity tests (vs the live Dart implementation) ────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{:02x}", x)).collect()
    }
    fn seed(v: u8) -> [u8; 32] {
        [v; 32]
    }

    // Vectors produced by tool/gen_crypto_vectors.dart against the current
    // Dart crypto. If any of these ever drift, the Rust core has diverged
    // from on-wire behaviour and MUST NOT ship.
    const X25519_BOB_PUB: &str =
        "0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20";
    const X25519_SHARED: &str =
        "9e004098efc091d4ec2663b4e9f5cfd4d7064571690b4bea97ab146ab9f35056";
    const HKDF_SHA512: &str =
        "472396a479d03141000dd1730013b4a7e24b50e532db91d70d5203c5665a6e82";
    const X3DH_KDF: &str =
        "fe313ec6428b9b5204c867e4eacd78c4c83ca3528abdc41ece954cf5cac50dcd";
    const CHACHA_CT: &str = "96749340f9cc85fa05489a8df3fd814af8dc1e";
    const CHACHA_MAC: &str = "ca4f28877af57f334464cf6725ada260";
    const RATCHET_IHK: &str =
        "4012bb3061583eb1a61c284ffbe68d1e6210dd718e51e9e1c9d622567eb87025";
    const RATCHET_RK_NEWRK: &str =
        "4647733631a3096e435a3d3cd079ec64d2fc6746b4c65b920d73be841c7a75d8";
    const RATCHET_RK_CK: &str =
        "52c8b9e8f110d4abdc470a5f30d4a6bed309ccb12bac920e54ba73fdc56100ca";
    const RATCHET_RK_NEXTHK: &str =
        "c485259e1001be0e01195d95574ae098e473b817bac56729d4de9dd593c9feed";
    const RATCHET_CK_NEWCK: &str =
        "0839a07a4c8a9c2b42bb276e73eaff899c5828b5f706d0e572b38ea465943725";
    const RATCHET_CK_ENCKEY: &str =
        "06f418973c2a4600b3a9b9ccff8d8367c066ba3cfcfd0f90ff99e7608ab5c17e";
    const RATCHET_CK_HDRKEY: &str =
        "7e399762fb0e51881c84c51c55de20ec89c9897cb56ab1f256c886d76f6593d6";

    #[test]
    fn x25519_public_matches_dart() {
        assert_eq!(hex(&x25519_public(&seed(0x22))), X25519_BOB_PUB);
    }

    #[test]
    fn x25519_shared_matches_dart() {
        let bob_pub = x25519_public(&seed(0x22));
        let shared = x25519_shared(&seed(0x11), &bob_pub);
        assert_eq!(hex(shared.as_bytes()), X25519_SHARED);
    }

    #[test]
    fn hkdf_sha512_matches_dart() {
        let mut out = [0u8; 32];
        hkdf_sha512(
            &[0x42u8; 32],
            b"phantom-storage-v1",
            b"phantom-hive-encryption-key",
            &mut out,
        );
        assert_eq!(hex(&out), HKDF_SHA512);
    }

    #[test]
    fn x3dh_kdf_matches_dart() {
        let sk = x3dh_kdf(&seed(0xaa), &seed(0xbb), &seed(0xcc), Some(&seed(0xdd)));
        assert_eq!(hex(sk.as_bytes()), X3DH_KDF);
    }

    #[test]
    fn chacha20poly1305_matches_dart_and_round_trips() {
        let key = seed(0x01);
        let nonce = [0x02u8; 12];
        let aad = [0x03u8; 16];
        let pt = b"phantom test vector";
        let (ct, tag) = chacha20poly1305_encrypt(&key, &nonce, &aad, pt);
        assert_eq!(hex(&ct), CHACHA_CT, "ciphertext parity with Dart");
        assert_eq!(hex(&tag), CHACHA_MAC, "tag parity with Dart");

        let back = chacha20poly1305_decrypt(&key, &nonce, &aad, &ct, &tag).unwrap();
        assert_eq!(back, pt);

        // Tamper → auth fails (no panic, returns None).
        let mut bad = tag;
        bad[0] ^= 1;
        assert!(chacha20poly1305_decrypt(&key, &nonce, &aad, &ct, &bad).is_none());
    }

    #[test]
    fn kdf_initial_header_key_matches_dart() {
        let hk = kdf_initial_header_key(&seed(0x55), b"phantom-ratchet-hk-atob");
        assert_eq!(hex(&hk), RATCHET_IHK);
    }

    #[test]
    fn kdf_root_key_matches_dart() {
        let (new_root, ck, next_hk) = kdf_root_key(&seed(0x66), &seed(0x77));
        assert_eq!(hex(new_root.as_bytes()), RATCHET_RK_NEWRK);
        assert_eq!(hex(ck.as_bytes()), RATCHET_RK_CK);
        assert_eq!(hex(&next_hk), RATCHET_RK_NEXTHK);
    }

    #[test]
    fn kdf_chain_key_matches_dart() {
        let (new_ck, enc_key, header_key) = kdf_chain_key(&seed(0x88));
        assert_eq!(hex(new_ck.as_bytes()), RATCHET_CK_NEWCK);
        assert_eq!(hex(enc_key.as_bytes()), RATCHET_CK_ENCKEY);
        assert_eq!(hex(&header_key), RATCHET_CK_HDRKEY);
    }

    #[test]
    fn constant_time_eq_works() {
        assert!(ct_eq(&[1, 2, 3], &[1, 2, 3]));
        assert!(!ct_eq(&[1, 2, 3], &[1, 2, 4]));
        assert!(!ct_eq(&[1, 2, 3], &[1, 2]));
        let a = Secret32(seed(9));
        let b = Secret32(seed(9));
        let c = Secret32(seed(8));
        assert!(a.ct_eq(&b));
        assert!(!a.ct_eq(&c));
    }
}

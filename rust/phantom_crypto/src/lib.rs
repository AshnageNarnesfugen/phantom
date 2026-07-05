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
use sha2::Sha512;
use subtle::ConstantTimeEq;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop};

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

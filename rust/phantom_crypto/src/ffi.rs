//! C-ABI surface for `dart:ffi`.
//!
//! Two shapes here:
//!
//! * **Stateless** (X25519, X3DH composition, Ed25519 verify, hybrid combine):
//!   fixed-size pure functions that write into a caller-provided 32-byte buffer
//!   and return 0/≠0 — nothing to allocate or free across the boundary.
//!
//! * **Stateful ratchet** (`RatchetSession`): an opaque `*mut RatchetSession`
//!   handle created by `phantom_ratchet_from_json`, mutated in place by
//!   `phantom_ratchet_encrypt`/`_decrypt`, and released by
//!   `phantom_ratchet_free`. Variable-length outputs (header/ciphertext/
//!   plaintext) are heap-allocated by Rust, handed back as (ptr,len), and freed
//!   by the caller via `phantom_buf_free`. `_decrypt` is ATOMIC: it works on a
//!   clone and only commits to the handle on success, so a failed attempt (wrong
//!   session / tampered frame) leaves the ratchet state untouched — matching the
//!   Dart "try each session, restore on failure" contract.
//!
//! Safety: every pointer is null-checked; input slices are read-only and sized
//! by the contract (32-byte keys, caller-supplied lengths). No panics cross the
//! boundary; secret state zeroizes on drop (including the discarded clone).

use crate::ratchet::{EncryptedMessage, RatchetSession};
use crate::{
    chacha20poly1305_decrypt, chacha20poly1305_encrypt, ed25519_verify, hybrid_combine,
    x25519_shared, x3dh_initiate,
};
use rand_core::{OsRng, RngCore};
use zeroize::Zeroize;

/// # Safety: `p` must be null or point to at least 32 readable bytes.
unsafe fn arr32(p: *const u8) -> Option<[u8; 32]> {
    if p.is_null() {
        return None;
    }
    let mut a = [0u8; 32];
    a.copy_from_slice(std::slice::from_raw_parts(p, 32));
    Some(a)
}

/// out = X25519(our_seed, their_pub). Returns 0 on success.
///
/// # Safety: `our_seed`/`their_pub` point to 32 bytes; `out` to 32 writable.
#[no_mangle]
pub unsafe extern "C" fn phantom_x25519_shared(
    our_seed: *const u8,
    their_pub: *const u8,
    out: *mut u8,
) -> i32 {
    let (Some(s), Some(p)) = (arr32(our_seed), arr32(their_pub)) else {
        return 1;
    };
    if out.is_null() {
        return 1;
    }
    let secret = x25519_shared(&s, &p);
    std::ptr::copy_nonoverlapping(secret.as_bytes().as_ptr(), out, 32);
    0
}

/// out = X3DH shared secret (Alice/initiator). `their_opk` may be null (no
/// one-time prekey). Returns 0 on success.
///
/// # Safety: the four key pointers are 32 bytes each (`their_opk` null-ok);
/// `out` is 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn phantom_x3dh_initiate(
    our_ik_seed: *const u8,
    eph_seed: *const u8,
    their_ik_pub: *const u8,
    their_spk_pub: *const u8,
    their_opk_pub: *const u8, // null → None
    out: *mut u8,
) -> i32 {
    let (Some(ik), Some(eph), Some(tik), Some(tspk)) = (
        arr32(our_ik_seed),
        arr32(eph_seed),
        arr32(their_ik_pub),
        arr32(their_spk_pub),
    ) else {
        return 1;
    };
    if out.is_null() {
        return 1;
    }
    let opk = arr32(their_opk_pub);
    let secret = x3dh_initiate(&ik, &eph, &tik, &tspk, opk.as_ref());
    std::ptr::copy_nonoverlapping(secret.as_bytes().as_ptr(), out, 32);
    0
}

/// out = hybrid_combine(x3dh, kyber). Returns 0 on success.
///
/// # Safety: `x3dh`/`kyber` are 32 bytes; `out` is 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn phantom_hybrid_combine(
    x3dh: *const u8,
    kyber: *const u8,
    out: *mut u8,
) -> i32 {
    let (Some(a), Some(b)) = (arr32(x3dh), arr32(kyber)) else {
        return 1;
    };
    if out.is_null() {
        return 1;
    }
    let secret = hybrid_combine(&a, &b);
    std::ptr::copy_nonoverlapping(secret.as_bytes().as_ptr(), out, 32);
    0
}

/// Returns 1 if the Ed25519 signature verifies, 0 otherwise (also 0 on bad
/// args — a non-verifying result, never a panic).
///
/// # Safety: `public` is 32 bytes, `sig` is 64 bytes, `msg` points to
/// `msg_len` readable bytes (may be null iff `msg_len == 0`).
#[no_mangle]
pub unsafe extern "C" fn phantom_ed25519_verify(
    public: *const u8,
    msg: *const u8,
    msg_len: usize,
    sig: *const u8,
) -> i32 {
    let Some(pk) = arr32(public) else { return 0 };
    if sig.is_null() || (msg.is_null() && msg_len != 0) {
        return 0;
    }
    let mut s = [0u8; 64];
    s.copy_from_slice(std::slice::from_raw_parts(sig, 64));
    let m: &[u8] = if msg_len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(msg, msg_len)
    };
    ed25519_verify(&pk, m, &s) as i32
}

// ── Stateful ratchet: opaque handle + heap-buffer outputs ─────────────────────

/// Hand a Rust-owned `Vec<u8>` back to the caller as (ptr,len). The caller must
/// return it with `phantom_buf_free`. Uses a boxed slice so capacity == len,
/// making the free unambiguous.
///
/// # Safety: `out_ptr`/`out_len` must be writable.
unsafe fn slice_into_out(v: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) {
    let boxed = v.into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut u8;
    *out_ptr = ptr;
    *out_len = len;
}

/// Free a buffer previously returned by `phantom_ratchet_encrypt`/`_decrypt`.
///
/// # Safety: `ptr`/`len` must be exactly a pair produced by this library (or
/// `ptr` null). Never call twice on the same pointer.
#[no_mangle]
pub unsafe extern "C" fn phantom_buf_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    let s = std::slice::from_raw_parts_mut(ptr, len);
    drop(Box::from_raw(s as *mut [u8]));
}

// Pin/unpin the session's page(s) so the root/chain/message/header keys living
// inline in the boxed struct can't be paged out to swap/disk. Best-effort:
// mlock can fail (e.g. RLIMIT_MEMLOCK) and we ignore that — the ratchet still
// works, just unpinned. NOTE: the skipped-key map allocates separately on the
// heap, so its (bounded, transient) keys are not covered by this; the crown
// secrets (root/chain/header keys) are inline in the struct and thus pinned.
#[cfg(unix)]
unsafe fn lock_session(ptr: *mut RatchetSession) {
    libc::mlock(ptr as *const libc::c_void, std::mem::size_of::<RatchetSession>());
}
#[cfg(unix)]
unsafe fn unlock_session(ptr: *mut RatchetSession) {
    libc::munlock(ptr as *const libc::c_void, std::mem::size_of::<RatchetSession>());
}
#[cfg(not(unix))]
unsafe fn lock_session(_ptr: *mut RatchetSession) {}
#[cfg(not(unix))]
unsafe fn unlock_session(_ptr: *mut RatchetSession) {}

/// Parse a Dart-serialized `RatchetSession` (its `toJson`/`takeSnapshot` format)
/// into an opaque handle. Returns null on bad UTF-8 or bad JSON. The handle owns
/// the secret state (zeroized when freed) and must be released with
/// `phantom_ratchet_free`.
///
/// # Safety: `json` points to `json_len` readable bytes (null iff len 0).
#[no_mangle]
pub unsafe extern "C" fn phantom_ratchet_from_json(
    json: *const u8,
    json_len: usize,
) -> *mut RatchetSession {
    if json.is_null() && json_len != 0 {
        return std::ptr::null_mut();
    }
    let bytes: &[u8] = if json_len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(json, json_len)
    };
    let Ok(s) = std::str::from_utf8(bytes) else {
        return std::ptr::null_mut();
    };
    match RatchetSession::from_json(s) {
        Ok(sess) => {
            let ptr = Box::into_raw(Box::new(sess));
            lock_session(ptr); // pin secret pages against swap (best-effort)
            ptr
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// Encrypt `pt` with the session, advancing its sending chain in place. On
/// success writes the encrypted header and ciphertext as freshly-allocated
/// buffers (free with `phantom_buf_free`) and the 12-byte nonce into `nonce_out`.
/// Returns 0 on success, 1 on bad args, 2 if the session cannot send yet.
///
/// # Safety: `sess` is a live handle; `pt` points to `pt_len` bytes (null iff
/// 0); the four out-pointers and `nonce_out` (12 bytes) are writable.
#[no_mangle]
pub unsafe extern "C" fn phantom_ratchet_encrypt(
    sess: *mut RatchetSession,
    pt: *const u8,
    pt_len: usize,
    hdr_out: *mut *mut u8,
    hdr_len: *mut usize,
    ct_out: *mut *mut u8,
    ct_len: *mut usize,
    nonce_out: *mut u8,
) -> i32 {
    if sess.is_null()
        || hdr_out.is_null()
        || hdr_len.is_null()
        || ct_out.is_null()
        || ct_len.is_null()
        || nonce_out.is_null()
        || (pt.is_null() && pt_len != 0)
    {
        return 1;
    }
    let s = &mut *sess;
    let plaintext: &[u8] = if pt_len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(pt, pt_len)
    };
    match s.encrypt(plaintext) {
        Ok(m) => {
            std::ptr::copy_nonoverlapping(m.nonce.as_ptr(), nonce_out, 12);
            slice_into_out(m.encrypted_header, hdr_out, hdr_len);
            slice_into_out(m.ciphertext, ct_out, ct_len);
            0
        }
        Err(_) => 2,
    }
}

/// Decrypt one message, advancing the receiving chain in place ONLY on success
/// (atomic clone-commit). Writes the plaintext as a freshly-allocated buffer
/// (free with `phantom_buf_free`). Returns 0 on success, 1 on bad args, 2 if the
/// message is undecryptable/tampered (state left untouched).
///
/// # Safety: `sess` is a live handle; `hdr`/`ct` point to their lengths (null
/// iff 0); `nonce` is 12 bytes; `pt_out`/`pt_len` are writable.
#[no_mangle]
pub unsafe extern "C" fn phantom_ratchet_decrypt(
    sess: *mut RatchetSession,
    hdr: *const u8,
    hdr_len: usize,
    ct: *const u8,
    ct_len: usize,
    nonce: *const u8,
    pt_out: *mut *mut u8,
    pt_len: *mut usize,
) -> i32 {
    if sess.is_null()
        || nonce.is_null()
        || pt_out.is_null()
        || pt_len.is_null()
        || (hdr.is_null() && hdr_len != 0)
        || (ct.is_null() && ct_len != 0)
    {
        return 1;
    }
    let s = &mut *sess;
    let header = if hdr_len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(hdr, hdr_len).to_vec()
    };
    let ciphertext = if ct_len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(ct, ct_len).to_vec()
    };
    let mut nonce12 = [0u8; 12];
    nonce12.copy_from_slice(std::slice::from_raw_parts(nonce, 12));
    let msg = EncryptedMessage {
        encrypted_header: header,
        ciphertext,
        nonce: nonce12,
    };
    // Clone-commit: never mutate the caller's session unless decrypt succeeds.
    let mut trial = s.clone();
    match trial.decrypt(&msg) {
        Ok(pt) => {
            *s = trial; // old state dropped + zeroized here
            slice_into_out(pt, pt_out, pt_len);
            0
        }
        Err(_) => 2,
    }
}

/// Serialize the session to Dart's `toJson` format (a freshly-allocated UTF-8
/// buffer, free with `phantom_buf_free`). This is the PERSIST path — the only
/// place secret state crosses back to the caller as hex, exactly as the pure-
/// Dart ratchet already does when saving to storage. Returns 0 on success.
///
/// # Safety: `sess` is a live handle; `out_ptr`/`out_len` are writable.
#[no_mangle]
pub unsafe extern "C" fn phantom_ratchet_to_json(
    sess: *mut RatchetSession,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if sess.is_null() || out_ptr.is_null() || out_len.is_null() {
        return 1;
    }
    let s = &*sess;
    slice_into_out(s.to_json().into_bytes(), out_ptr, out_len);
    0
}

/// Read NON-SECRET status: the message counters, whether a sending chain exists,
/// and the remote party's ratchet public key. The Dart wrapper uses these on the
/// hot path (INIT-resend cutoff via `sn`; DH-ratchet detection via the remote
/// pub before/after a decrypt) WITHOUT pulling any secret to hex. Returns 0 on
/// success. `remote_pub` is zeroed and `has_remote` is 0 when no remote key yet.
///
/// # Safety: `sess` is a live handle; all out-pointers are writable
/// (`remote_pub` has room for 32 bytes).
#[no_mangle]
pub unsafe extern "C" fn phantom_ratchet_status(
    sess: *mut RatchetSession,
    out_sn: *mut u32,
    out_rn: *mut u32,
    out_psn: *mut u32,
    out_has_send: *mut u8,
    out_remote_pub: *mut u8,
    out_has_remote: *mut u8,
) -> i32 {
    if sess.is_null()
        || out_sn.is_null()
        || out_rn.is_null()
        || out_psn.is_null()
        || out_has_send.is_null()
        || out_remote_pub.is_null()
        || out_has_remote.is_null()
    {
        return 1;
    }
    let s = &*sess;
    *out_sn = s.sending_n();
    *out_rn = s.receiving_n();
    *out_psn = s.previous_sending_n();
    *out_has_send = s.has_sending_chain() as u8;
    match s.dh_remote_pub() {
        Some(p) => {
            std::ptr::copy_nonoverlapping(p.as_ptr(), out_remote_pub, 32);
            *out_has_remote = 1;
        }
        None => {
            std::ptr::write_bytes(out_remote_pub, 0, 32);
            *out_has_remote = 0;
        }
    }
    0
}

/// Seal the session into an ENCRYPTED blob: `to_json` is ChaCha20-Poly1305'd
/// with `key` (32 bytes), so the root/chain/header keys never cross to the
/// caller as plaintext hex — only ciphertext. Layout `[nonce12][ct][tag16]`,
/// freed with `phantom_buf_free`. This is the memory-hygiene persist path; the
/// caller (Dart) stores the blob instead of the hex map. Returns 0 on success.
///
/// # Safety: `sess` is a live handle; `key` is 32 bytes; `out_ptr`/`out_len`
/// are writable.
#[no_mangle]
pub unsafe extern "C" fn phantom_ratchet_seal(
    sess: *mut RatchetSession,
    key: *const u8,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if sess.is_null() || key.is_null() || out_ptr.is_null() || out_len.is_null() {
        return 1;
    }
    let mut k = [0u8; 32];
    k.copy_from_slice(std::slice::from_raw_parts(key, 32));
    let mut json_bytes = (*sess).to_json().into_bytes();
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let (ct, tag) = chacha20poly1305_encrypt(&k, &nonce, b"", &json_bytes);
    k.zeroize();
    json_bytes.zeroize(); // plaintext json held secret hex — wipe our copy
    let mut blob = Vec::with_capacity(12 + ct.len() + 16);
    blob.extend_from_slice(&nonce);
    blob.extend_from_slice(&ct);
    blob.extend_from_slice(&tag);
    slice_into_out(blob, out_ptr, out_len);
    0
}

/// Open a blob produced by `phantom_ratchet_seal` (or the Dart equivalent) into
/// a session handle. Same `[nonce12][ct][tag16]` layout + 32-byte `key`. Returns
/// null on a bad key/tag or bad JSON. The handle is `mlock`ed like `from_json`.
///
/// # Safety: `blob` points to `blob_len` bytes; `key` is 32 bytes.
#[no_mangle]
pub unsafe extern "C" fn phantom_ratchet_open(
    blob: *const u8,
    blob_len: usize,
    key: *const u8,
) -> *mut RatchetSession {
    if blob.is_null() || key.is_null() || blob_len < 28 {
        return std::ptr::null_mut();
    }
    let mut k = [0u8; 32];
    k.copy_from_slice(std::slice::from_raw_parts(key, 32));
    let b = std::slice::from_raw_parts(blob, blob_len);
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&b[0..12]);
    let ct = &b[12..blob_len - 16];
    let mut tag = [0u8; 16];
    tag.copy_from_slice(&b[blob_len - 16..]);
    let pt = chacha20poly1305_decrypt(&k, &nonce, b"", ct, &tag);
    k.zeroize();
    let Some(mut pt) = pt else {
        return std::ptr::null_mut();
    };
    let result = match std::str::from_utf8(&pt) {
        Ok(json) => match RatchetSession::from_json(json) {
            Ok(sess) => {
                let ptr = Box::into_raw(Box::new(sess));
                lock_session(ptr);
                ptr
            }
            Err(_) => std::ptr::null_mut(),
        },
        Err(_) => std::ptr::null_mut(),
    };
    pt.zeroize(); // decrypted json held secret hex
    result
}

/// Release a session handle (zeroizes its secret state).
///
/// # Safety: `sess` must be a handle from `phantom_ratchet_from_json` not yet
/// freed (or null). Never call twice.
#[no_mangle]
pub unsafe extern "C" fn phantom_ratchet_free(sess: *mut RatchetSession) {
    if sess.is_null() {
        return;
    }
    unlock_session(sess); // unpin before the Drop zeroizes + frees
    drop(Box::from_raw(sess));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_x25519_shared_round_trips_through_c_abi() {
        let our = [0x11u8; 32];
        let their = crate::x25519_public(&[0x22u8; 32]);
        let mut out = [0u8; 32];
        let rc = unsafe { phantom_x25519_shared(our.as_ptr(), their.as_ptr(), out.as_mut_ptr()) };
        assert_eq!(rc, 0);
        // Matches the direct API (and therefore the Dart vector).
        assert_eq!(out, *crate::x25519_shared(&our, &their).as_bytes());
    }

    #[test]
    fn ffi_null_args_are_rejected_not_ub() {
        let mut out = [0u8; 32];
        let rc = unsafe {
            phantom_x25519_shared(std::ptr::null(), std::ptr::null(), out.as_mut_ptr())
        };
        assert_eq!(rc, 1);
        // Ed25519 verify with a null key → 0 (no panic).
        let rc2 = unsafe {
            phantom_ed25519_verify(std::ptr::null(), std::ptr::null(), 0, std::ptr::null())
        };
        assert_eq!(rc2, 0);
    }

    // ── Stateful ratchet over the C-ABI ──────────────────────────────────────

    use crate::ratchet::{BOB_JSON, M0_CT, M0_HDR, M0_NONCE, M1_CT, M1_HDR, M1_NONCE};

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2)
            .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap())
            .collect()
    }

    unsafe fn ffi_decrypt(
        sess: *mut RatchetSession,
        h: &str,
        c: &str,
        n: &str,
    ) -> Result<Vec<u8>, i32> {
        let hdr = unhex(h);
        let ct = unhex(c);
        let nonce = unhex(n);
        let mut pt_ptr: *mut u8 = std::ptr::null_mut();
        let mut pt_len: usize = 0;
        let rc = phantom_ratchet_decrypt(
            sess,
            hdr.as_ptr(),
            hdr.len(),
            ct.as_ptr(),
            ct.len(),
            nonce.as_ptr(),
            &mut pt_ptr,
            &mut pt_len,
        );
        if rc != 0 {
            return Err(rc);
        }
        let out = std::slice::from_raw_parts(pt_ptr, pt_len).to_vec();
        phantom_buf_free(pt_ptr, pt_len);
        Ok(out)
    }

    #[test]
    fn ffi_ratchet_decrypts_dart_messages_and_is_atomic_on_failure() {
        unsafe {
            let sess = phantom_ratchet_from_json(BOB_JSON.as_ptr(), BOB_JSON.len());
            assert!(!sess.is_null());

            // A tampered M0 fails (rc 2) AND must NOT advance the ratchet — so
            // the untampered M0 still decrypts right after. This proves the
            // clone-commit atomicity through the C-ABI.
            let mut bad = M0_CT.to_string();
            bad.replace_range(0..2, "ff");
            assert_eq!(ffi_decrypt(sess, M0_HDR, &bad, M0_NONCE), Err(2));

            let p0 = ffi_decrypt(sess, M0_HDR, M0_CT, M0_NONCE).unwrap();
            assert_eq!(String::from_utf8(p0).unwrap(), "hola desde dart 0");
            let p1 = ffi_decrypt(sess, M1_HDR, M1_CT, M1_NONCE).unwrap();
            assert_eq!(String::from_utf8(p1).unwrap(), "hola desde dart 1");

            phantom_ratchet_free(sess);
        }
    }

    #[test]
    fn ffi_ratchet_from_json_rejects_garbage() {
        unsafe {
            let junk = b"not json";
            let sess = phantom_ratchet_from_json(junk.as_ptr(), junk.len());
            assert!(sess.is_null());
            // Freeing null is a no-op, not UB.
            phantom_ratchet_free(std::ptr::null_mut());
            phantom_buf_free(std::ptr::null_mut(), 0);
        }
    }

    #[test]
    fn ffi_ratchet_status_and_to_json_track_state() {
        unsafe {
            let sess = phantom_ratchet_from_json(BOB_JSON.as_ptr(), BOB_JSON.len());
            assert!(!sess.is_null());

            // Fresh Bob: no remote pub, no sending chain, counters zero.
            let (mut sn, mut rn, mut psn) = (0u32, 0u32, 0u32);
            let (mut has_send, mut has_remote) = (9u8, 9u8);
            let mut remote = [0u8; 32];
            assert_eq!(
                phantom_ratchet_status(
                    sess, &mut sn, &mut rn, &mut psn, &mut has_send,
                    remote.as_mut_ptr(), &mut has_remote,
                ),
                0
            );
            assert_eq!((sn, rn, psn, has_send, has_remote), (0, 0, 0, 0, 0));

            // After decrypting M0, Bob DH-ratcheted: a remote pub appears and a
            // sending chain exists.
            ffi_decrypt(sess, M0_HDR, M0_CT, M0_NONCE).unwrap();
            phantom_ratchet_status(
                sess, &mut sn, &mut rn, &mut psn, &mut has_send,
                remote.as_mut_ptr(), &mut has_remote,
            );
            assert_eq!(has_remote, 1);
            assert_eq!(has_send, 1);
            assert!(remote.iter().any(|&b| b != 0));

            // to_json round-trips through the C-ABI: reload and decrypt M1.
            let mut jp: *mut u8 = std::ptr::null_mut();
            let mut jl: usize = 0;
            assert_eq!(phantom_ratchet_to_json(sess, &mut jp, &mut jl), 0);
            let json = String::from_utf8(std::slice::from_raw_parts(jp, jl).to_vec()).unwrap();
            phantom_buf_free(jp, jl);
            phantom_ratchet_free(sess);

            let reloaded = phantom_ratchet_from_json(json.as_ptr(), json.len());
            assert!(!reloaded.is_null());
            let p1 = ffi_decrypt(reloaded, M1_HDR, M1_CT, M1_NONCE).unwrap();
            assert_eq!(String::from_utf8(p1).unwrap(), "hola desde dart 1");
            phantom_ratchet_free(reloaded);
        }
    }

    #[test]
    fn ffi_ratchet_seal_open_round_trips_and_rejects_wrong_key() {
        unsafe {
            let key = [0x5cu8; 32];
            let sess = phantom_ratchet_from_json(BOB_JSON.as_ptr(), BOB_JSON.len());
            // Advance state, then seal → the blob is opaque (not the plaintext json).
            ffi_decrypt(sess, M0_HDR, M0_CT, M0_NONCE).unwrap();
            let mut bp: *mut u8 = std::ptr::null_mut();
            let mut bl: usize = 0;
            assert_eq!(phantom_ratchet_seal(sess, key.as_ptr(), &mut bp, &mut bl), 0);
            let blob = std::slice::from_raw_parts(bp, bl).to_vec();
            phantom_buf_free(bp, bl);
            phantom_ratchet_free(sess);
            // The ciphertext must not contain the plaintext rk hex.
            assert!(!blob
                .windows(4)
                .any(|w| w == b"5a5a"));

            // Wrong key → null (auth fail), not a panic.
            let bad = [0u8; 32];
            assert!(phantom_ratchet_open(blob.as_ptr(), blob.len(), bad.as_ptr()).is_null());

            // Right key → a working session that continues decrypting M1.
            let opened = phantom_ratchet_open(blob.as_ptr(), blob.len(), key.as_ptr());
            assert!(!opened.is_null());
            let p1 = ffi_decrypt(opened, M1_HDR, M1_CT, M1_NONCE).unwrap();
            assert_eq!(String::from_utf8(p1).unwrap(), "hola desde dart 1");
            phantom_ratchet_free(opened);
        }
    }
}

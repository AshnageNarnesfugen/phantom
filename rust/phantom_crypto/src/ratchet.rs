//! Double-ratchet state machine — faithful port of `RatchetSession` in
//! `lib/core/crypto/double_ratchet.dart`. Reuses the slice-2 KDFs and the
//! slice-1 AEAD, all already parity-proven.
//!
//! Secret state (root/chain/message/header keys) is zeroized on drop. The
//! cross-compat test at the bottom loads a session Bob serialized in Dart and
//! decrypts messages Alice encrypted in Dart — the real proof that the Rust
//! ratchet is wire-identical and can take over decryption.

use crate::{
    chacha20poly1305_decrypt, chacha20poly1305_encrypt, kdf_chain_key, kdf_root_key,
    x25519_public, x25519_shared,
};
use rand_core::{OsRng, RngCore};
use std::collections::HashMap;
use zeroize::Zeroize;

const MAX_SKIP: u32 = 1000;
const MAX_STORED_SKIPPED: usize = 2000;

#[derive(Debug)]
pub enum RatchetError {
    HeaderTooShort,
    Undecryptable,
    TooManySkipped(u32),
    Auth,
    BadJson(&'static str),
}

#[derive(Clone)]
struct MessageKey {
    enc_key: [u8; 32],
    header_key: [u8; 32],
}
impl Drop for MessageKey {
    fn drop(&mut self) {
        self.enc_key.zeroize();
        self.header_key.zeroize();
    }
}

struct Header {
    dh_pub: [u8; 32],
    previous_chain_len: u32,
    message_number: u32,
}
impl Header {
    fn encode(&self) -> [u8; 40] {
        let mut out = [0u8; 40];
        out[0..4].copy_from_slice(&self.previous_chain_len.to_be_bytes());
        out[4..8].copy_from_slice(&self.message_number.to_be_bytes());
        out[8..40].copy_from_slice(&self.dh_pub);
        out
    }
    fn decode(b: &[u8]) -> Result<Header, RatchetError> {
        if b.len() < 40 {
            return Err(RatchetError::HeaderTooShort);
        }
        let mut dh = [0u8; 32];
        dh.copy_from_slice(&b[8..40]);
        Ok(Header {
            previous_chain_len: u32::from_be_bytes(b[0..4].try_into().unwrap()),
            message_number: u32::from_be_bytes(b[4..8].try_into().unwrap()),
            dh_pub: dh,
        })
    }
}

/// One outgoing message.
pub struct EncryptedMessage {
    pub encrypted_header: Vec<u8>,
    pub ciphertext: Vec<u8>, // ct || 16-byte tag, as Dart stores it
    pub nonce: [u8; 12],
}

#[derive(Clone)]
pub struct RatchetSession {
    root_key: [u8; 32],
    sending_chain_key: Option<[u8; 32]>,
    receiving_chain_key: Option<[u8; 32]>,
    dh_sending_priv: [u8; 32],
    dh_sending_pub: [u8; 32],
    dh_remote_pub: Option<[u8; 32]>,
    sending_n: u32,
    receiving_n: u32,
    previous_sending_n: u32,
    sending_header_key: Option<[u8; 32]>,
    receiving_header_key: Option<[u8; 32]>,
    next_sending_header_key: Option<[u8; 32]>,
    next_receiving_header_key: Option<[u8; 32]>,
    skipped: HashMap<String, MessageKey>,
}

impl Drop for RatchetSession {
    fn drop(&mut self) {
        self.root_key.zeroize();
        self.dh_sending_priv.zeroize();
        for k in [
            &mut self.sending_chain_key,
            &mut self.receiving_chain_key,
            &mut self.sending_header_key,
            &mut self.receiving_header_key,
            &mut self.next_sending_header_key,
            &mut self.next_receiving_header_key,
        ] {
            if let Some(v) = k {
                v.zeroize();
            }
        }
    }
}

// ── header AEAD (ChaCha20-Poly1305, no AAD, [nonce12][ct][mac16]) ──────────────

fn encrypt_header(header: &[u8; 40], hk: &[u8; 32]) -> Vec<u8> {
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let (ct, tag) = chacha20poly1305_encrypt(hk, &nonce, b"", header);
    let mut out = Vec::with_capacity(12 + ct.len() + 16);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    out.extend_from_slice(&tag);
    out
}

fn decrypt_header(enc: &[u8], hk: &[u8; 32]) -> Option<[u8; 40]> {
    if enc.len() < 28 {
        return None;
    }
    let nonce: [u8; 12] = enc[0..12].try_into().ok()?;
    let ct = &enc[12..enc.len() - 16];
    let tag: [u8; 16] = enc[enc.len() - 16..].try_into().ok()?;
    let pt = chacha20poly1305_decrypt(hk, &nonce, b"", ct, &tag)?;
    if pt.len() != 40 {
        return None;
    }
    let mut out = [0u8; 40];
    out.copy_from_slice(&pt);
    Some(out)
}

fn skipped_id(dh_pub: &[u8; 32], n: u32) -> String {
    let hexpub: String = dh_pub.iter().map(|b| format!("{:02x}", b)).collect();
    format!("{}:{}", hexpub, n)
}

impl RatchetSession {
    // ── Encrypt ───────────────────────────────────────────────────────────────
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<EncryptedMessage, RatchetError> {
        let ck = self.sending_chain_key.ok_or(RatchetError::Undecryptable)?;
        // kdf_chain_key gives (new chain key, message enc key, per-msg header
        // key). Dart uses enc_key for the body and the SESSION sending header
        // key for the header framing; the per-message header key is unused.
        let (new_ck, enc_key, _unused_hk) = kdf_chain_key(&ck);
        self.sending_chain_key = Some(*new_ck.as_bytes());

        let header = Header {
            dh_pub: self.dh_sending_pub,
            previous_chain_len: self.previous_sending_n,
            message_number: self.sending_n,
        };
        self.sending_n += 1;

        let shk = self.sending_header_key.ok_or(RatchetError::Undecryptable)?;
        let enc_header = encrypt_header(&header.encode(), &shk);
        let mut nonce = [0u8; 12];
        OsRng.fill_bytes(&mut nonce);
        let (ct, tag) = chacha20poly1305_encrypt(enc_key.as_bytes(), &nonce, &enc_header, plaintext);
        let mut ciphertext = ct;
        ciphertext.extend_from_slice(&tag);
        Ok(EncryptedMessage {
            encrypted_header: enc_header,
            ciphertext,
            nonce,
        })
    }

    // ── Decrypt ───────────────────────────────────────────────────────────────
    pub fn decrypt(&mut self, msg: &EncryptedMessage) -> Result<Vec<u8>, RatchetError> {
        // 1. current receiving header key → also handles skipped keys.
        if let Some(rhk) = self.receiving_header_key {
            if let Some(hbytes) = decrypt_header(&msg.encrypted_header, &rhk) {
                let header = Header::decode(&hbytes)?;
                let id = skipped_id(&header.dh_pub, header.message_number);
                if let Some(mk) = self.skipped.remove(&id) {
                    return self.open(&msg, &mk);
                }
                return self.decrypt_with_header(msg, header);
            }
        }
        // 2. next receiving header key → triggers DH ratchet.
        if let Some(nrhk) = self.next_receiving_header_key {
            if let Some(hbytes) = decrypt_header(&msg.encrypted_header, &nrhk) {
                let header = Header::decode(&hbytes)?;
                return self.decrypt_with_header(msg, header);
            }
        }
        Err(RatchetError::Undecryptable)
    }

    fn decrypt_with_header(
        &mut self,
        msg: &EncryptedMessage,
        header: Header,
    ) -> Result<Vec<u8>, RatchetError> {
        let needs_ratchet = match &self.dh_remote_pub {
            None => true,
            Some(p) => *p != header.dh_pub,
        };
        if needs_ratchet {
            self.skip_message_keys(header.previous_chain_len)?;
            self.dh_ratchet(&header.dh_pub);
        }
        self.skip_message_keys(header.message_number)?;

        let ck = self.receiving_chain_key.ok_or(RatchetError::Undecryptable)?;
        let (new_ck, enc_key, header_key) = kdf_chain_key(&ck);
        self.receiving_chain_key = Some(*new_ck.as_bytes());
        self.receiving_n += 1;
        let mk = MessageKey {
            enc_key: *enc_key.as_bytes(),
            header_key,
        };
        self.open(msg, &mk)
    }

    fn open(&self, msg: &EncryptedMessage, mk: &MessageKey) -> Result<Vec<u8>, RatchetError> {
        if msg.ciphertext.len() < 16 {
            return Err(RatchetError::Auth);
        }
        let ct = &msg.ciphertext[..msg.ciphertext.len() - 16];
        let tag: [u8; 16] = msg.ciphertext[msg.ciphertext.len() - 16..]
            .try_into()
            .map_err(|_| RatchetError::Auth)?;
        chacha20poly1305_decrypt(&mk.enc_key, &msg.nonce, &msg.encrypted_header, ct, &tag)
            .ok_or(RatchetError::Auth)
    }

    fn skip_message_keys(&mut self, until: u32) -> Result<(), RatchetError> {
        if self.receiving_n + MAX_SKIP < until {
            return Err(RatchetError::TooManySkipped(until));
        }
        let ck = match self.receiving_chain_key {
            Some(c) => c,
            None => return Ok(()),
        };
        let remote = match self.dh_remote_pub {
            Some(p) => p,
            None => return Ok(()),
        };
        let mut ck = ck;
        while self.receiving_n < until {
            let (new_ck, enc_key, header_key) = kdf_chain_key(&ck);
            ck = *new_ck.as_bytes();
            let id = skipped_id(&remote, self.receiving_n);
            self.skipped.insert(
                id,
                MessageKey {
                    enc_key: *enc_key.as_bytes(),
                    header_key,
                },
            );
            self.receiving_n += 1;
        }
        self.receiving_chain_key = Some(ck);
        self.evict_oldest_skipped();
        Ok(())
    }

    fn evict_oldest_skipped(&mut self) {
        // HashMap has no insertion order; a strict FIFO would need an ordered
        // map. Bounded eviction is enough to prevent unbounded growth (the
        // Dart cap is FIFO; parity of WHICH keys are dropped isn't security-
        // relevant — dropped skipped messages just become undecryptable).
        while self.skipped.len() > MAX_STORED_SKIPPED {
            if let Some(k) = self.skipped.keys().next().cloned() {
                self.skipped.remove(&k);
            } else {
                break;
            }
        }
    }

    fn dh_ratchet(&mut self, their_new_dh_pub: &[u8; 32]) {
        self.previous_sending_n = self.sending_n;
        self.sending_n = 0;
        self.receiving_n = 0;
        self.dh_remote_pub = Some(*their_new_dh_pub);

        // receiving step
        let dh_recv = x25519_shared(&self.dh_sending_priv, their_new_dh_pub);
        let (rk1, recv_ck, next_recv_hk) = kdf_root_key(&self.root_key, dh_recv.as_bytes());
        self.root_key = *rk1.as_bytes();
        self.receiving_chain_key = Some(*recv_ck.as_bytes());
        self.receiving_header_key = self.next_receiving_header_key;
        self.next_receiving_header_key = Some(next_recv_hk);

        // new sending keypair
        let mut new_priv = [0u8; 32];
        OsRng.fill_bytes(&mut new_priv);
        self.dh_sending_pub = x25519_public(&new_priv);
        self.dh_sending_priv = new_priv;

        // sending step
        let dh_send = x25519_shared(&self.dh_sending_priv, their_new_dh_pub);
        let (rk2, send_ck, next_send_hk) = kdf_root_key(&self.root_key, dh_send.as_bytes());
        self.root_key = *rk2.as_bytes();
        self.sending_chain_key = Some(*send_ck.as_bytes());
        self.sending_header_key = self.next_sending_header_key;
        self.next_sending_header_key = Some(next_send_hk);
        self.sending_n = 0;
    }

    // ── Deserialization (Dart toJson format) ──────────────────────────────────
    pub fn from_json(s: &str) -> Result<RatchetSession, RatchetError> {
        let v: serde_json::Value =
            serde_json::from_str(s).map_err(|_| RatchetError::BadJson("parse"))?;
        let req32 = |k: &str| -> Result<[u8; 32], RatchetError> {
            hex32(v.get(k)).ok_or(RatchetError::BadJson("field32"))
        };
        let opt32 = |k: &str| -> Option<[u8; 32]> { hex32(v.get(k)) };
        let u = |k: &str| -> u32 { v.get(k).and_then(|x| x.as_u64()).unwrap_or(0) as u32 };

        let mut skipped = HashMap::new();
        if let Some(sk) = v.get("sk").and_then(|x| x.as_object()) {
            for (id, mk) in sk {
                let ek = hex32(mk.get("ek")).ok_or(RatchetError::BadJson("sk.ek"))?;
                let hk = hex32(mk.get("hk")).ok_or(RatchetError::BadJson("sk.hk"))?;
                skipped.insert(
                    id.clone(),
                    MessageKey {
                        enc_key: ek,
                        header_key: hk,
                    },
                );
            }
        }

        Ok(RatchetSession {
            root_key: req32("rk")?,
            sending_chain_key: opt32("sck"),
            receiving_chain_key: opt32("rck"),
            dh_sending_priv: req32("dhsk_priv")?,
            dh_sending_pub: req32("dhsk_pub")?,
            dh_remote_pub: opt32("dhrpk"),
            sending_n: u("sn"),
            receiving_n: u("rn"),
            previous_sending_n: u("psn"),
            sending_header_key: opt32("shk"),
            receiving_header_key: opt32("rhk"),
            next_sending_header_key: opt32("nshk"),
            next_receiving_header_key: opt32("nrhk"),
            skipped,
        })
    }
}

fn hex32(v: Option<&serde_json::Value>) -> Option<[u8; 32]> {
    let s = v?.as_str()?;
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

// Vector captured from tool/gen_ratchet_vector.dart: Bob's fresh receiver
// session + two messages Alice encrypted in Dart. Shared by the ratchet tests
// and the FFI tests (which drive the same vector through the C-ABI). The Rust
// ratchet must load Bob and decrypt both — proving wire-identical decryption.
#[cfg(test)]
pub(crate) const BOB_JSON: &str = r#"{"rk":"5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a","sck":null,"rck":null,"dhsk_priv":"3033333333333333333333333333333333333333333333333333333333333373","dhsk_pub":"7b0d47d93427f8311160781c7c733fd89f88970aef490d8aa0ee19a4cb8a1b14","dhrpk":null,"sn":0,"rn":0,"psn":0,"shk":null,"rhk":null,"nshk":"ea5d4da81e706dc952f977e2ccee0c1ae06052493bdcdd66db7e9c3b97a902bb","nrhk":"52c60cbc3139c3dce7bef53be6f224d5300403950ef44420ec28a2bcd7b98870","x3dh_ek":null,"kyber_cipher":null,"opk_id":null,"epk":"5f0edaa1211451143fc590708fb0be4d98ae9e2eca43f4add4778b0e27ba1678","sk":{}}"#;
#[cfg(test)]
pub(crate) const M0_HDR: &str = "02e8a2835548478c6a0d3f3409229cb549e54e3d35f7d802d2a32fcc10f6ca4136de8193d24f3476925ffb861c6e1b9c90bb86624d162a8e8a75ea2b25b5ec80bda58cfd";
#[cfg(test)]
pub(crate) const M0_CT: &str = "529d3e2d51afa7cd714aa8dca3718e49f4bcb545977f0f7884cf0f2f4f3ad8499e";
#[cfg(test)]
pub(crate) const M0_NONCE: &str = "4ccb8439a47898fa27758534";
#[cfg(test)]
pub(crate) const M1_HDR: &str = "2e9445a983bca3b4b7a0533de0eff2a8006b0c3ceb52de0f7e04dcf5d822c91b12632fed978a3b7e1435b14ef25c11996bde604f66d8e6ef6449a84225701c6a7f600e26";
#[cfg(test)]
pub(crate) const M1_CT: &str = "37f2f9ed3147e6a9c30af20d8cd2d9a1fe8d66d01371dc7d41bd61e6fb1cfb0fb4";
#[cfg(test)]
pub(crate) const M1_NONCE: &str = "76e573c4b44c402a2a2475f1";

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2)
            .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap())
            .collect()
    }
    fn nonce12(s: &str) -> [u8; 12] {
        unhex(s).try_into().unwrap()
    }
    fn msg(h: &str, c: &str, n: &str) -> EncryptedMessage {
        EncryptedMessage {
            encrypted_header: unhex(h),
            ciphertext: unhex(c),
            nonce: nonce12(n),
        }
    }

    #[test]
    fn rust_decrypts_dart_encrypted_messages() {
        let mut bob = RatchetSession::from_json(BOB_JSON).unwrap();
        let p0 = bob.decrypt(&msg(M0_HDR, M0_CT, M0_NONCE)).unwrap();
        assert_eq!(String::from_utf8(p0).unwrap(), "hola desde dart 0");
        let p1 = bob.decrypt(&msg(M1_HDR, M1_CT, M1_NONCE)).unwrap();
        assert_eq!(String::from_utf8(p1).unwrap(), "hola desde dart 1");
    }

    #[test]
    fn out_of_order_uses_skipped_keys() {
        // Deliver M1 before M0: Bob skips M0's key, then M0 decrypts from the
        // skipped store.
        let mut bob = RatchetSession::from_json(BOB_JSON).unwrap();
        let p1 = bob.decrypt(&msg(M1_HDR, M1_CT, M1_NONCE)).unwrap();
        assert_eq!(String::from_utf8(p1).unwrap(), "hola desde dart 1");
        let p0 = bob.decrypt(&msg(M0_HDR, M0_CT, M0_NONCE)).unwrap();
        assert_eq!(String::from_utf8(p0).unwrap(), "hola desde dart 0");
    }

    #[test]
    fn tampered_ciphertext_is_rejected() {
        let mut bob = RatchetSession::from_json(BOB_JSON).unwrap();
        let mut m = msg(M0_HDR, M0_CT, M0_NONCE);
        m.ciphertext[0] ^= 1;
        assert!(bob.decrypt(&m).is_err());
    }
}

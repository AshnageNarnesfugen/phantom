# Phantom Messenger

**No phone number. No server. No metadata.**

Phantom is an end-to-end encrypted Android messenger designed for communications where privacy is not optional. Your identity is a 12-word phrase that exists only on your device. There is no account to create, no server to trust, no company that can hand you over.

---

## How it works

### Identity

Your identity is derived deterministically from a **BIP39 seed phrase** (12 words):

```
seed phrase (12 words)
  → 512-bit entropy via PBKDF2
    → Ed25519 keypair    (message signing)
    → X25519 keypair     (Diffie-Hellman encryption)
      → PhantomID        (base58check of X25519 public key — what you share)
```

No registration. No email. No phone number. If you lose your seed phrase, you lose access permanently — there is no account recovery because there is no account.

### Encryption: X3DH + Double Ratchet + Kyber-768

The messaging protocol is identical to Signal's, with additional support for post-quantum cryptography:

**First message (X3DH — Extended Triple Diffie-Hellman):**
```
DH1 = DH(IK_Alice,  SPK_Bob)
DH2 = DH(EK_Alice,  IK_Bob)
DH3 = DH(EK_Alice,  SPK_Bob)
SK  = HKDF(DH1 ‖ DH2 ‖ DH3)
```
Kyber-768 (quantum-resistant) is mixed into SK when both devices support it.

**Subsequent messages (Double Ratchet with header encryption):**
- Each message uses a different key derived via HKDF
- Compromising one key does not compromise past or future messages (forward secrecy + break-in recovery)
- Ratchet headers are also encrypted — an observer cannot correlate messages

### How to add a contact

Instead of phone numbers or usernames, Phantom uses a **ContactAddress**: a ~220-character base64url blob containing your full PreKeyBundle (identity key, signed prekey, one-time prekeys, Kyber public key). You share it once — via QR code, text, or any channel — and both parties can initiate conversations.

### Transport

All configured internet transports run **concurrently** — there is no priority order among them. Messages are published to every active backend simultaneously; incoming messages arrive from all of them and the Double Ratchet discards duplicates automatically.

| Layer | Transport | When active |
|-------|-----------|-------------|
| Internet (concurrent) | Yggdrasil | Global IPv6 mesh, no central server |
| Internet (concurrent) | I2P | Onion-layer routing, maximum network privacy |
| Internet (concurrent) | IPFS pubsub | Decentralized, works without dedicated nodes |
| Fallback | BLE Mesh | No internet — Bluetooth between nearby devices |

The only fallback boundary is **internet → BLE mesh → offline queue** (72h TTL). BLE is not a tiebreaker among internet transports; it activates only when internet is fully absent.

The transport layer **does not know the content** — it only moves encrypted bytes. Messages are published to topics derived from the recipient's PhantomID: `/phantom/v1/{phantomId}`.

### Local storage

Everything is stored in **Hive with AES-GCM**. The encryption key is derived from your seed phrase via HKDF-SHA512 with salt `phantom-storage-v1`. Nothing leaves the device unencrypted.

---

## Installation

### From GitHub Releases (recommended)

1. Download the latest APK from [Releases](https://github.com/AshnageNarnesfugen/phantom/releases)
2. On your Android device: **Settings → Security → Install unknown apps** → enable for your browser/file manager
3. Open the APK and install

> Every push to `main` automatically generates a release signed with RSA-4096.

### From source

**Prerequisites:** Flutter ≥ 3.27, Java 21, Android SDK

```bash
git clone https://github.com/AshnageNarnesfugen/phantom
cd phantom
flutter pub get
flutter build apk --release
```

The APK will be at `build/app/outputs/flutter-apk/app-release.apk`.

---

## Usage

### First time: create an account

1. Open Phantom → **Create new account**
2. The app generates a 12-word seed phrase
3. **Write it down on paper and store it somewhere safe** — it is your only credential
4. The app derives your identity and is ready to use

### Restore on another device

1. Open Phantom → **Restore account**
2. Enter your 12 words in order
3. Your identity (PhantomID, keys) is reconstructed deterministically — identical to the original

### Add a contact

1. Go to **Add contact**
2. Paste the other person's **ContactAddress** (the ~220 characters they shared with you)
3. Send a first message — the X3DH handshake happens automatically in the background

For someone to add you, share your ContactAddress from **Settings → My contact address**.

### Optional system transports

**IPFS (default internet transport):**
```bash
# Arch Linux
yay -S kubo
ipfs init
ipfs config --json Experimental.Pubsub true
ipfs daemon --enable-pubsub-experiment &
```

**Bluetooth mesh (automatic when there is no internet):**
Android requests the necessary permissions at runtime the first time they are needed.

---

## Code architecture

```
lib/
├── main.dart                        — startup, secure storage, routing
├── core_provider.dart               — InheritedWidget with PhantomCore and ThemeController
├── core/
│   ├── identity/identity.dart       — BIP39 → Ed25519 + X25519 → PhantomID
│   ├── crypto/
│   │   ├── x3dh.dart                — initial handshake, ContactAddress (165 bytes)
│   │   ├── double_ratchet.dart      — forward secrecy with header encryption
│   │   └── hybrid_kem.dart          — Kyber-768 + X25519 hybrid KEM
│   ├── protocol/
│   │   ├── frame.dart               — WireFrame: INIT (0x49) and MSG (0x4D)
│   │   └── message.dart             — PhantomMessage, PhantomEnvelope, StoredMessage
│   ├── storage/
│   │   ├── phantom_storage.dart     — Hive AES-GCM, key derived from seed
│   │   └── backup_manager.dart      — encrypted backup export/import
│   └── phantom_core.dart            — main facade: createAccount, sendMessage…
├── transport/
│   ├── transport.dart               — abstract interface + IPFS + Yggdrasil + I2P
│   ├── transport_manager_v2.dart    — automatic detection + internet→BLE fallback
│   └── bluetooth/
│       ├── bluetooth_mesh_transport.dart
│       ├── gatt_server_channel.dart
│       ├── mesh_protocol.dart
│       └── mesh_router.dart
└── ui/
    ├── theme/phantom_theme.dart
    ├── widgets/widgets.dart          — ChatBubble, MessageInput, ConversationTile…
    └── screens/screens.dart          — onboarding, conversations, chat, settings
```

---

## Security model

Phantom assumes the adversary knows the full protocol. Security does not depend on code secrecy.

**What Phantom protects:**
- Message content (E2E encrypted, no one else can read it)
- Network metadata (the transport sees only encrypted bytes and a topic hash)
- Sender identity within individual messages (header encryption)

**What Phantom does not protect (by design):**
- The fact that two PhantomIDs are communicating (observable by whoever controls the transport)
- Physical attacks on the device if the OS is compromised
- Loss of the seed phrase

**Cryptographic properties:**
- **Forward secrecy:** compromising today's key does not decrypt yesterday's messages
- **Break-in recovery:** compromising today's key does not decrypt tomorrow's messages
- **Post-quantum:** resistant to attacks from quantum computers (Kyber-768)

---

## License

[AGPL-3.0](LICENSE) — the code is free, modifications must be too.

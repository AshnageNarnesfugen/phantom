# Phantom Messenger

**Sin número de teléfono. Sin servidor. Sin metadatos.**

Phantom es un mensajero Android cifrado de extremo a extremo diseñado para comunicaciones donde la privacidad no es opcional. Tu identidad es una frase de 12 palabras que existe solo en tu dispositivo. No hay cuenta que crear, no hay servidor que confiar, no hay empresa que pueda entregarte.

---

## Cómo funciona

### Identidad

Tu identidad se deriva determinísticamente desde una **seed phrase BIP39** (12 palabras):

```
seed phrase (12 palabras)
  → entropy 512-bit via PBKDF2
    → Ed25519 keypair    (firma de mensajes)
    → X25519 keypair     (cifrado Diffie-Hellman)
      → PhantomID        (base58check del X25519 public key — lo que compartes)
```

No hay registro. No hay email. No hay número de teléfono. Si pierdes tu seed phrase, pierdes acceso permanentemente — no hay recuperación de cuenta porque no hay cuenta.

### Cifrado: X3DH + Double Ratchet + Kyber-768

El protocolo de mensajería es idéntico al de Signal, con soporte adicional para criptografía post-cuántica:

**Primer mensaje (X3DH — Extended Triple Diffie-Hellman):**
```
DH1 = DH(IK_Alice,  SPK_Bob)
DH2 = DH(EK_Alice,  IK_Bob)
DH3 = DH(EK_Alice,  SPK_Bob)
SK  = HKDF(DH1 ‖ DH2 ‖ DH3)
```
Kyber-768 (resistente a computadoras cuánticas) se mezcla en el SK cuando ambos dispositivos lo soportan.

**Mensajes siguientes (Double Ratchet con header encryption):**
- Cada mensaje usa una clave diferente derivada con HKDF
- Compromiso de una clave no compromete mensajes anteriores ni futuros (forward secrecy + break-in recovery)
- Los headers del ratchet también van cifrados — un observador no puede correlacionar mensajes

### Cómo agregar un contacto

En lugar de números de teléfono o usernames, Phantom usa **ContactAddress**: un blob de ~220 caracteres en base64url que contiene tu PreKeyBundle completo (identity key, signed prekey, one-time prekeys, public key Kyber). Lo compartes una vez — por QR, por texto, por cualquier canal — y ambos pueden iniciar conversaciones.

### Transporte

La app detecta automáticamente qué transporte está disponible y hace fallback en orden:

| Prioridad | Transporte | Característica |
|-----------|-----------|----------------|
| 1 | Yggdrasil | Mesh IPv6 global, sin servidor central |
| 2 | I2P | Routing en capas tipo onion, máxima privacidad de red |
| 3 | IPFS pubsub | Descentralizado, funciona sin nodos propios |
| 4 | BLE Mesh | Sin internet — Bluetooth entre dispositivos cercanos |

El transporte **no conoce el contenido** — solo mueve bytes cifrados. Los mensajes se publican en topics derivados del PhantomID del destinatario: `/phantom/v1/{phantomId}`.

### Almacenamiento local

Todo se guarda en **Hive con AES-GCM**. La clave de cifrado se deriva de tu seed phrase via HKDF-SHA512 con salt `phantom-storage-v1`. Nada sale del dispositivo sin cifrar.

---

## Instalación

### Desde GitHub Releases (recomendado)

1. Descarga el APK más reciente desde [Releases](https://github.com/AshnageNarnesfugen/phantom/releases)
2. En tu Android: **Ajustes → Seguridad → Instalar apps desconocidas** → habilitar para tu navegador/gestor de archivos
3. Abre el APK e instala

> Cada push a `main` genera automáticamente un release firmado con RSA-4096.

### Desde el código fuente

**Prerrequisitos:** Flutter ≥ 3.27, Java 21, Android SDK

```bash
git clone https://github.com/AshnageNarnesfugen/phantom
cd phantom
flutter pub get
flutter build apk --release
```

El APK queda en `build/app/outputs/flutter-apk/app-release.apk`.

---

## Uso

### Primera vez: crear cuenta

1. Abre Phantom → **Create new account**
2. La app genera una seed phrase de 12 palabras
3. **Anótala en papel y guárdala en un lugar seguro** — es tu única credencial
4. La app deriva tu identidad y queda lista

### Restaurar en otro dispositivo

1. Abre Phantom → **Restore account**
2. Introduce tus 12 palabras en orden
3. Tu identidad (PhantomID, claves) se reconstruye determinísticamente — idéntica al original

### Agregar un contacto

1. Ve a **Add contact**
2. Pega el **ContactAddress** de la otra persona (los ~220 caracteres que te compartió)
3. Envía un primer mensaje — el handshake X3DH ocurre automáticamente en el fondo

Para que alguien te agregue a ti, comparte tu ContactAddress desde **Settings → My contact address**.

### Transportes opcionales del sistema

**IPFS (transporte por defecto cuando hay internet):**
```bash
# Arch Linux
yay -S kubo
ipfs init
ipfs config --json Experimental.Pubsub true
ipfs daemon --enable-pubsub-experiment &
```

**Bluetooth mesh (automático cuando no hay internet):**
Android pide los permisos necesarios en runtime la primera vez que se necesitan.

---

## Arquitectura del código

```
lib/
├── main.dart                        — startup, secure storage, routing
├── core_provider.dart               — InheritedWidget con PhantomCore y ThemeController
├── core/
│   ├── identity/identity.dart       — BIP39 → Ed25519 + X25519 → PhantomID
│   ├── crypto/
│   │   ├── x3dh.dart                — handshake inicial, ContactAddress (165 bytes)
│   │   ├── double_ratchet.dart      — forward secrecy con header encryption
│   │   └── hybrid_kem.dart          — Kyber-768 + X25519 hybrid KEM
│   ├── protocol/
│   │   ├── frame.dart               — WireFrame: INIT (0x49) y MSG (0x4D)
│   │   └── message.dart             — PhantomMessage, PhantomEnvelope, StoredMessage
│   ├── storage/
│   │   ├── phantom_storage.dart     — Hive AES-GCM, clave derivada de seed
│   │   └── backup_manager.dart      — export/import cifrado de backup
│   └── phantom_core.dart            — fachada principal: createAccount, sendMessage…
├── transport/
│   ├── transport.dart               — interfaz abstracta + IPFS + Yggdrasil + I2P
│   ├── transport_manager_v2.dart    — detección automática + fallback internet→BLE
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

## Modelo de seguridad

Phantom asume que el adversario conoce el protocolo completo. La seguridad no depende del secreto del código.

**Lo que Phantom protege:**
- Contenido de los mensajes (cifrado E2E, nadie más puede leerlos)
- Metadatos de red (el transporte solo ve bytes cifrados y un topic hash)
- Identidad del remitente en mensajes individuales (header encryption)

**Lo que Phantom no protege (por diseño):**
- El hecho de que dos PhantomIDs se comunican (observable por quien controla el transporte)
- Ataques físicos al dispositivo si el SO está comprometido
- Pérdida de la seed phrase

**Propiedades criptográficas:**
- **Forward secrecy:** comprometer la clave de hoy no descifra mensajes de ayer
- **Break-in recovery:** comprometer la clave de hoy no descifra mensajes de mañana
- **Post-quantum:** resistente a ataques con computadoras cuánticas (Kyber-768)

---

## Licencia

[AGPL-3.0](LICENSE) — el código es libre, las modificaciones deben serlo también.

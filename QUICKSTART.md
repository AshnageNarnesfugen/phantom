# Phantom Messenger — Quickstart

## ⚠️ PASO OBLIGATORIO ANTES DE ABRIR EN VSCODE

Si abres el proyecto sin haber descargado las dependencias, **VSCode mostrará cientos de errores rojos** que en realidad son un solo problema. Asegúrate de correr `flutter pub get` PRIMERO.

```bash
cd phantom
flutter pub get
```

O usa el script de setup:

```bash
./setup.sh
```

## Correr la app

```bash
flutter run -d linux        # Linux desktop
flutter run -d android      # Android (dispositivo o emulador)
```

## Si VSCode sigue mostrando errores después de pub get

```
Cmd/Ctrl + Shift + P  →  Dart: Restart Analysis Server
```

Si tampoco así, ver `TROUBLESHOOTING.md`.

## Estructura

```
phantom/
├── pubspec.yaml          ← un solo pubspec, todas las dependencias
├── setup.sh              ← script automatizado de setup
├── TROUBLESHOOTING.md    ← problemas comunes
├── lib/
│   ├── main.dart                    ← entry point
│   ├── core/
│   │   ├── identity/identity.dart   ← BIP39, Ed25519, PhantomID
│   │   ├── crypto/
│   │   │   ├── x3dh.dart            ← handshake inicial
│   │   │   └── double_ratchet.dart  ← forward secrecy
│   │   ├── protocol/message.dart    ← wire format, padding, sealed sender
│   │   ├── storage/phantom_storage.dart ← Hive cifrado local
│   │   └── phantom_core.dart        ← fachada principal
│   ├── transport/
│   │   ├── transport.dart           ← IPFS / I2P / Yggdrasil
│   │   ├── transport_manager_v2.dart ← fallback automático internet → BLE
│   │   └── bluetooth/
│   │       ├── mesh_protocol.dart
│   │       ├── mesh_router.dart
│   │       ├── message_store.dart
│   │       └── bluetooth_mesh_transport.dart
│   └── ui/
│       ├── theme/phantom_theme.dart
│       ├── widgets/widgets.dart
│       └── screens/screens.dart
├── test/
└── android/app/src/main/AndroidManifest.xml
```

## Prerrequisitos opcionales del sistema

### IPFS (transporte por defecto cuando hay internet)

```bash
yay -S kubo                    # Arch Linux

ipfs init
ipfs config --json Experimental.Pubsub true
ipfs daemon --enable-pubsub-experiment &
```

### Bluetooth mesh (automático cuando no hay internet)

**Linux:**
```bash
sudo pacman -S bluez bluez-utils
sudo systemctl enable --now bluetooth
sudo usermod -aG bluetooth $USER
```

**Android:** la app pide los permisos en runtime.

# Troubleshooting

## "VSCode muestra cientos de errores rojos pero el código es correcto"

**Causa:** No se corrió `flutter pub get`. Las dependencias externas (`cryptography`, `flutter_blue_plus`, `meta`, `bip39`, etc.) no están descargadas, así que el analizador Dart no puede resolver ningún tipo de esos paquetes.

**Cuando una dependencia no se resuelve, los errores se propagan en cascada:**

```
flutter_blue_plus no descargado
  → BluetoothDevice no existe
    → MeshPeer.device es de tipo desconocido
      → todas las referencias a peer.device fallan
        → todos los métodos que usan peer.device fallan
```

Por eso ves **390 undefined_method, 310 undefined_identifier, 126 undefined_class** — no son 826 errores diferentes, son síntomas de **un solo problema**: las dependencias no descargadas.

**Solución:**

```bash
cd phantom
flutter pub get
```

Después de eso, en VSCode:
1. `Cmd/Ctrl+Shift+P`
2. `Dart: Restart Analysis Server`

Los errores rojos deben desaparecer.

---

## "flutter: command not found"

Instalar Flutter SDK 3.27+:

- **Arch Linux:** `yay -S flutter`
- **Manual:** https://flutter.dev/docs/get-started/install/linux
- **Verificar:** `flutter --version`

---

## "pub get failed: version solving failed"

### Caso específico: conflicto con `hive_generator` o `test`

Si ves un error como:
```
hive_generator >=2.0.1 depends on analyzer >=4.6.0 <7.0.0
flutter_test from sdk depends on analyzer >=8.0.0
```

Es porque `hive_generator` y `build_runner` requieren una versión vieja del analyzer que entra en conflicto con el Flutter SDK actual. **Ya están removidos del pubspec.yaml** — Phantom serializa a JSON manualmente, no necesita adaptadores generados.

Lo mismo con `package:test` — usamos `flutter_test` del SDK que provee `expect/test/group` sin el conflicto.

### Otros conflictos de versiones

Si hay conflicto entre otras dependencias, comenta líneas del `pubspec.yaml` una a una hasta encontrar la culpable.

Si quieres forzar las últimas versiones:
```bash
flutter pub upgrade --major-versions
```

---

## "MissingPluginException: No implementation found for method..."

Esto pasa cuando un plugin (como `flutter_blue_plus`) requiere reinstalación nativa:

```bash
flutter clean
flutter pub get
flutter run
```

---

## "El bluetooth no funciona en Linux"

```bash
# Arch Linux
sudo pacman -S bluez bluez-utils
sudo systemctl enable --now bluetooth
sudo usermod -aG bluetooth $USER

# Logout/login necesario después del usermod
```

Verificar con: `bluetoothctl power on`

---

## "El bluetooth pide permisos cada vez en Android"

Es comportamiento normal de Android 12+. La app debe pedir:
- `BLUETOOTH_SCAN`
- `BLUETOOTH_CONNECT`
- `BLUETOOTH_ADVERTISE`
- `ACCESS_FINE_LOCATION` (Android todavía lo requiere para BLE scan)

Estos están en `android/app/src/main/AndroidManifest.xml` y se piden en runtime.

---

## "IPFS no se conecta"

El transporte IPFS requiere un nodo Kubo local:

```bash
# Instalar (Arch)
yay -S kubo

# Init (primera vez)
ipfs init
ipfs config --json Experimental.Pubsub true

# Correr daemon
ipfs daemon --enable-pubsub-experiment

# Verificar: debería responder
curl http://127.0.0.1:5001/api/v0/id
```

Sin nodo IPFS local, la app cae al modo Bluetooth mesh automáticamente.

---

## "Dart: Restart Analysis Server" no funciona

A veces el caché de VSCode queda corrupto. Solución nuclear:

```bash
flutter clean
rm -rf .dart_tool/ .flutter-plugins .flutter-plugins-dependencies
flutter pub get
```

Y reiniciar VSCode completamente.

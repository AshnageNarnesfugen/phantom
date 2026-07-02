# Phantom Lab — depurar handshake y mensajería sin instalar APKs

Dos laboratorios reproducen en el escritorio lo que antes requería dos
teléfonos con APKs recién flasheados. Ambos ejercitan **el mismo código que
corre en producción** (PhantomCore / WakuTransport), no reimplementaciones.

## 1. Lab de protocolo (loopback) — `test/e2e/handshake_loopback_test.dart`

Dos `PhantomCore` reales (Alice y Bob) en el mismo proceso, conectados por un
transporte en memoria (`test/support/loopback_transport.dart`). Sin daemons,
sin red, determinista, ~10 s.

```bash
flutter test test/e2e/handshake_loopback_test.dart
```

Cubre: X3DH híbrido (X25519+Kyber768), wrapping INIT, auto-registro de
contacto desde el INIT, double ratchet bidireccional, handshakeAck/preKeyShare,
dedupe de frames replicados y comportamiento con la red caída.

El hub permite simular condiciones de red:
- `hub.online = false` — corte total (los publish lanzan).
- `hub.latency = Duration(...)` — latencia artificial.
- `hub.replay(i)` — reinyecta un frame ya entregado (réplica del store).
- `hub.trace` — todos los frames que cruzaron, en orden, para asertar sobre
  el tráfico de wire.

Primer dividendo: cazó una carrera real — frames en ráfaga descifrando
concurrentemente contra la misma sesión ratchet (uno gana, el resto falla con
"no session could decrypt"). En los teléfonos pasaba al llegar el backlog del
store de golpe. Arreglado serializando entrada y salida (`_SerialLock`).

## 2. Lab de red (Waku vivo) — `test/lab/waku_live_test.dart`

Levanta **dos daemons go-waku locales** con exactamente los flags de
producción (`WakuDaemon.launchArgs`) y ejercita `WakuTransport` contra el
fleet real `status.prod`: publish confirmado por store, backlog de store para
un nodo recién nacido (= "Alice estaba offline"), y gossip en vivo. ~10-60 s
según el peering.

Requiere el binario go-waku para Linux (no va al repo, `tool/bin/` está en
.gitignore):

```bash
gh release download v0.9.0 -R waku-org/go-waku -p '*x86_64.deb' -D /tmp/gowaku
cd /tmp/gowaku && ar x gowaku-0.9.0-x86_64.deb && tar xf data.tar.gz
mkdir -p <repo>/tool/bin && cp usr/bin/waku <repo>/tool/bin/waku
```

```bash
flutter test test/lab/waku_live_test.dart
# o con binario en otra ruta:
PHANTOM_WAKU_BIN=/ruta/al/waku flutter test test/lab/waku_live_test.dart
```

Si el binario no está, el test se salta solo (no rompe CI).

Dividendos del primer día:
- **`storeQuery` sin `pubsubTopic` → HTTP 500 "no suitable peers found"**
  incluso con el store node conectado y sirviendo. Era el error que veíamos
  en cada sesión de cada teléfono. Un parámetro.
- **Lightpush está muerto contra status.prod**: go-waku v0.9.0 solo habla
  `/vac/waku/lightpush/2.0.0-beta1` y el fleet ya no lo monta (503). No es
  red de seguridad: por eso el publish ahora se confirma contra el store.
- **Relay HTTP 200 ≠ entrega**: publicar antes del GRAFT del mesh evapora el
  mensaje. `WakuTransport.publish` ahora republica hasta ver el payload en el
  store del fleet (la única confirmación real que ofrece Waku).

## Trampas del entorno de test

- `TestWidgetsFlutterBinding` sustituye `HttpClient` por un mock que responde
  400 a todo. El lab de red **no** debe inicializar ese binding (y limpia
  `HttpOverrides.global`). El lab loopback puede, porque no usa HTTP real.
- Hive registra boxes por nombre global: cada `PhantomStorage.isolated()`
  recibe un prefijo de namespace propio en `initialize()`.

## Flujo recomendado antes de tocar un teléfono

```bash
flutter test                                    # suite completa (labs incluidos)
flutter test test/e2e/handshake_loopback_test.dart   # ¿bug de protocolo?
flutter test test/lab/waku_live_test.dart            # ¿bug de red/fleet?
```

Si ambos labs están en verde y el fallo solo aparece en dispositivos, el
sospechoso es la capa Android (foreground service, permisos, red del
dispositivo, binarios jniLibs) — no el protocolo ni Waku.

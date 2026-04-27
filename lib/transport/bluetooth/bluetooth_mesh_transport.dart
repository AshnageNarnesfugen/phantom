import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:meta/meta.dart';
import 'mesh_protocol.dart';
import 'mesh_router.dart';
import 'message_store.dart';
import 'gatt_server_channel.dart';

/// BluetoothMeshTransport — capa BLE del sistema de transporte Phantom.
///
/// Implementa el protocolo mesh definido en mesh_protocol.dart sobre BLE.
///
/// Arquitectura BLE:
///   - ADVERTISER: anuncia presencia con nodeHint en manufacturer data
///   - SCANNER: descubre nodos Phantom cercanos por su manufacturer data
///   - GATT SERVER: recibe mensajes de otros nodos (característica de escritura)
///   - GATT CLIENT: conecta a peers y escribe paquetes en su característica
///
/// UUIDs de servicio Phantom (custom):
///   Service:          PHANTOM-0001-MESH-BLE-0000-000000000001
///   Characteristic:   PHANTOM-0001-MESH-BLE-0000-000000000002
///
/// Flujo típico:
///   1. Advertiser anuncia cada 2s
///   2. Scanner detecta un nuevo peer Phantom
///   3. Conectar como GATT client
///   4. Escribir ANNOUNCE en su característica
///   5. Peer procesa y puede responder con pending messages
///   6. Relay bidireccional mientras la conexión dura
///   7. Desconectar (BLE no mantiene conexiones largas)

// ── UUIDs ─────────────────────────────────────────────────────────────────────

const String kPhantomServiceUuid = '50480001-4d45-5348-424c-450000000001';
const String kPhantomCharUuid    = '50480001-4d45-5348-424c-450000000002';

// ── Peer conectado ────────────────────────────────────────────────────────────

@immutable
class MeshPeer {
  final BluetoothDevice device;
  final Uint8List nodeHint;
  final bool canRelay;
  final DateTime discoveredAt;

  const MeshPeer({
    required this.device,
    required this.nodeHint,
    required this.canRelay,
    required this.discoveredAt,
  });

  String get hintHex =>
      nodeHint.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() => 'MeshPeer(hint=$hintHex, relay=$canRelay)';
}

// ── BluetoothMeshTransport ────────────────────────────────────────────────────

class BluetoothMeshTransport {
  final String _myPhantomId;
  final MeshRouter _router;
  final MessageStore _store;
  final GattServerChannel _gattServer = GattServerChannel();

  // Peers activos: deviceId → MeshPeer
  final Map<String, MeshPeer> _peers = {};

  // Característica GATT cacheada por peer para evitar discoverServices() en cada envío
  final Map<String, BluetoothCharacteristic> _peerChars = {};

  // Suscripciones activas
  final List<StreamSubscription> _subs = [];
  Timer? _announceTimer;
  Timer? _pruneTimer;

  // Estado
  bool _isRunning = false;
  bool _btAvailable = false;

  // Stream público de estado del mesh
  final _stateController = StreamController<MeshState>.broadcast();
  Stream<MeshState> get state => _stateController.stream;

  // Stream de envelopes entregados (para PhantomCore)
  Stream<Uint8List> get deliveredEnvelopes => _router.deliveredEnvelopes;

  BluetoothMeshTransport({
    required String myPhantomId,
    required MeshRouter router,
    required MessageStore store,
  })  : _myPhantomId = myPhantomId,
        _router = router,
        _store = store;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<bool> initialize() async {
    // Verificar disponibilidad de BT
    if (!await FlutterBluePlus.isSupported) {
      _emitState(MeshState.unavailable('Bluetooth no disponible en este dispositivo'));
      return false;
    }

    // Escuchar cambios de estado del adaptador
    _subs.add(FlutterBluePlus.adapterState.listen((state) {
      _btAvailable = state == BluetoothAdapterState.on;
      if (!_btAvailable) {
        _emitState(MeshState.unavailable('Bluetooth apagado'));
        _stopAll();
      } else if (_isRunning) {
        _startAll();
      }
    }));

    // Escuchar relay decisions del router
    _subs.add(_router.packetsToRelay.listen(_broadcastPacket));

    _btAvailable = FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
    return _btAvailable;
  }

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;

    if (!_btAvailable) {
      _emitState(MeshState.unavailable('Bluetooth apagado'));
      return;
    }

    await _startAll();
  }

  Future<void> _startAll() async {
    // Start GATT server + advertising so other devices can connect to us
    final advPayload = MeshAdvertisement.forNode(
      phantomId: _myPhantomId,
      canRelay: true,
      hasPending: _store.pendingCount > 0,
    ).toAdvPayload();
    final startResult = await _gattServer.start(advPayload);
    if (!startResult.success) {
      _emitState(MeshState.unavailable(startResult.reason ?? 'No se pudo iniciar BLE'));
      return;
    }

    // Wire incoming GATT server writes to our receive pipeline
    _subs.add(_gattServer.received.listen((data) {
      _receivePacket(data);
    }));

    // React to server-side lifecycle events
    _subs.add(_gattServer.events.listen((event) {
      switch (event) {
        case ClientConnected() || ClientDisconnected():
          _emitState(MeshState.active(peerCount: _peers.length));
        case MtuChanged(:final isSane):
          if (!isSane) {
            // Peer chipset is old — packets will be fragmented into many ATT writes
            _emitState(MeshState.active(peerCount: _peers.length));
          }
        case AdvertiseFailed():
          // Non-fatal: mesh still works via scanning
          _emitState(MeshState.active(peerCount: _peers.length));
      }
    }));

    await _startScanning();
    _startAnnounceTimer();
    _startPruneTimer();
    _emitState(MeshState.active(peerCount: _peers.length));
  }

  void _stopAll() {
    FlutterBluePlus.stopScan();
    _gattServer.stop();
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
  }

  // ── Scanning ──────────────────────────────────────────────────────────────

  Future<void> _startScanning() async {
    // Buscar dispositivos con nuestro service UUID
    await FlutterBluePlus.startScan(
      withServices: [Guid(kPhantomServiceUuid)],
      // withMsd: buscar por manufacturer data (alternativo)
      timeout: const Duration(days: 365), // continuo — se cancela en stop()
      androidUsesFineLocation: false,
    );

    _subs.add(FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        _handleScanResult(result);
      }
    }));
  }

  void _handleScanResult(ScanResult result) {
    final deviceId = result.device.remoteId.str;

    // Ya conocemos este peer
    if (_peers.containsKey(deviceId)) return;

    // Extraer nodeHint del manufacturer data
    final msd = result.advertisementData.manufacturerData;
    MeshAdvertisement? adv;

    for (final entry in msd.entries) {
      // Company ID 0xFFFF (big-endian en el payload)
      final payload = Uint8List.fromList([
        0xFF, 0xFF,
        ...entry.value,
      ]);
      adv = MeshAdvertisement.fromAdvPayload(payload);
      if (adv != null) break;
    }

    if (adv == null) return; // no es un nodo Phantom

    final peer = MeshPeer(
      device: result.device,
      nodeHint: adv.nodeHintBytes,
      canRelay: adv.canRelay,
      discoveredAt: DateTime.now(),
    );

    _peers[deviceId] = peer;
    _emitState(MeshState.active(peerCount: _peers.length));

    // Conectar y hacer handshake
    _connectAndHandshake(peer);
  }

  // ── GATT Client — conectar a un peer y enviar/recibir ─────────────────────

  Future<void> _connectAndHandshake(MeshPeer peer) async {
    final deviceId = peer.device.remoteId.str;
    try {
      // Conectar con timeout
      await peer.device.connect(license: License.free, timeout: const Duration(seconds: 8));

      // Request maximum MTU so large mesh packets don't get fragmented into
      // dozens of 20-byte ATT writes. Android negotiates; iOS does it automatically.
      if (Platform.isAndroid) {
        await peer.device.requestMtu(517);
      }

      // Descubrir servicios y cachear la característica
      final services = await peer.device.discoverServices();
      final phantomService = services.firstWhere(
        (s) => s.uuid == Guid(kPhantomServiceUuid),
        orElse: () => throw Exception('Servicio Phantom no encontrado'),
      );

      final characteristic = phantomService.characteristics.firstWhere(
        (c) => c.uuid == Guid(kPhantomCharUuid),
        orElse: () => throw Exception('Característica no encontrada'),
      );

      // Cachear para no volver a llamar discoverServices() en cada envío
      _peerChars[deviceId] = characteristic;

      // Suscribirse a notificaciones del peer (para recibir sus paquetes)
      if (characteristic.properties.notify) {
        await characteristic.setNotifyValue(true);
        _subs.add(characteristic.onValueReceived.listen((data) {
          _receivePacket(Uint8List.fromList(data), fromPeer: peer);
        }));
      }

      // Enviar ANNOUNCE primero
      await _writePacket(characteristic, _router.buildAnnounce());

      // Enviar pending messages que podrían ser para este peer
      final pending = _store.getPendingForHint(peer.nodeHint);
      for (final pendingMsg in pending) {
        await _writePacket(characteristic, pendingMsg.packet);
        _store.recordAttempt(pendingMsg.packet.messageIdHex);
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Monitorear desconexión — limpiar caché al desconectar
      _subs.add(peer.device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _peers.remove(deviceId);
          _peerChars.remove(deviceId);
          _emitState(MeshState.active(peerCount: _peers.length));
        }
      }));
    } catch (e) {
      // Conexión fallida — no es crítico, intentar de nuevo en el próximo scan
      _peers.remove(deviceId);
      _peerChars.remove(deviceId);
      try {
        await peer.device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _writePacket(
    BluetoothCharacteristic char,
    MeshPacket packet,
  ) async {
    final data = packet.serialize();

    // BLE MTU típico: 20-512 bytes. Fragmentar si es necesario.
    // flutter_blue_plus maneja Write With Response automáticamente.
    if (data.length <= 512) {
      await char.write(data, withoutResponse: false);
    } else {
      // Fragmentar en chunks de 512 bytes
      for (int i = 0; i < data.length; i += 512) {
        final end = min(i + 512, data.length);
        await char.write(data.sublist(i, end), withoutResponse: false);
      }
    }
  }

  // ── Recepción ─────────────────────────────────────────────────────────────

  Future<void> _receivePacket(Uint8List data, {MeshPeer? fromPeer}) async {
    MeshPacket packet;
    try {
      packet = MeshPacket.deserialize(data);
    } catch (e) {
      return;
    }

    // Try to match the sender to a known peer via nodeHint if not supplied
    final resolvedPeer = fromPeer ?? _findPeerByHint(packet.originHint);

    final result = await _router.process(
      packet,
      fromPeerHint: resolvedPeer?.hintHex ?? '',
    );

    if (resolvedPeer == null) return;

    for (final pending in result.pendingToSend) {
      await _sendToPeer(resolvedPeer, pending);
    }

    if (result.ackToSend != null) {
      try {
        await _sendBytesToPeer(resolvedPeer, result.ackToSend!);
      } catch (_) {}
    }
  }

  MeshPeer? _findPeerByHint(Uint8List hint) {
    for (final peer in _peers.values) {
      if (_hintMatches(peer.nodeHint, hint)) return peer;
    }
    return null;
  }

  static bool _hintMatches(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ── Broadcast / envío ─────────────────────────────────────────────────────

  /// Transmite un paquete a todos los peers conectados.
  Future<void> _broadcastPacket(MeshPacket packet) async {
    for (final peer in _peers.values) {
      await _sendToPeer(peer, packet);
    }
  }

  Future<void> _sendToPeer(MeshPeer peer, MeshPacket packet) async {
    await _sendBytesToPeer(peer, packet.serialize());
  }

  Future<void> _sendBytesToPeer(MeshPeer peer, Uint8List data) async {
    final char = _peerChars[peer.device.remoteId.str];
    if (char == null || !peer.device.isConnected) return;
    try {
      if (data.length <= 512) {
        await char.write(data, withoutResponse: false);
      } else {
        for (int i = 0; i < data.length; i += 512) {
          final end = min(i + 512, data.length);
          await char.write(data.sublist(i, end), withoutResponse: false);
        }
      }
    } catch (_) {
      // Peer desconectado mientras intentábamos escribir — ignorar
    }
  }

  // ── API pública ───────────────────────────────────────────────────────────

  /// Envía un mensaje cifrado por el mesh.
  Future<void> sendEncrypted({
    required String fullMessageId,
    required String recipientPhantomId,
    required Uint8List encryptedEnvelope,
  }) async {
    final packet = _router.prepareOutgoing(
      fullMessageId: fullMessageId,
      recipientPhantomId: recipientPhantomId,
      encryptedEnvelope: encryptedEnvelope,
    );

    // Enviar a todos los peers actuales
    await _broadcastPacket(packet);
  }

  /// Número de peers BLE activos.
  int get peerCount => _peers.length;

  /// ¿El mesh está activo?
  bool get isActive => _isRunning && _btAvailable;

  // ── Announce periódico ────────────────────────────────────────────────────

  void _startAnnounceTimer() {
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_peers.isNotEmpty) {
        await _broadcastPacket(_router.buildAnnounce());
      }
    });
  }

  void _startPruneTimer() {
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      _router.pruneStalePeers();
    });
  }

  // ── Estado ────────────────────────────────────────────────────────────────

  void _emitState(MeshState s) => _stateController.add(s);

  Future<void> stop() async {
    _isRunning = false;
    _stopAll();
    for (final peer in _peers.values) {
      try { await peer.device.disconnect(); } catch (_) {}
    }
    _peers.clear();
    _peerChars.clear();
    _emitState(const MeshState.stopped());
  }

  Future<void> dispose() async {
    await stop();
    for (final sub in _subs) { await sub.cancel(); }
    await _gattServer.dispose();
    await _stateController.close();
    await _router.dispose();
    await _store.dispose();
  }
}

// ── MeshState ─────────────────────────────────────────────────────────────────

@immutable
class MeshState {
  final MeshStatus status;
  final int peerCount;
  final String? message;

  const MeshState({
    required this.status,
    this.peerCount = 0,
    this.message,
  });

  const MeshState.stopped()
      : status = MeshStatus.stopped,
        peerCount = 0,
        message = null;

  factory MeshState.active({required int peerCount}) => MeshState(
        status: MeshStatus.active,
        peerCount: peerCount,
      );

  factory MeshState.unavailable(String reason) => MeshState(
        status: MeshStatus.unavailable,
        message: reason,
      );

  @override
  String toString() => 'MeshState($status, peers=$peerCount)';
}

enum MeshStatus { stopped, scanning, active, unavailable }


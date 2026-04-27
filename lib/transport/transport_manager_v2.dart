import 'dart:async';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'bluetooth/bluetooth_mesh_transport.dart';
import 'bluetooth/mesh_protocol.dart';
import 'bluetooth/message_store.dart';

/// TransportManager v2 — top-level transport coordinator.
///
/// Two modes, one fallback boundary:
///   internet  → all available backends (IPFS, I2P, Yggdrasil) run concurrently
///   no internet → Bluetooth mesh
///   no BT either → messages queued in local MessageStore (72h TTL)
///
/// All internet transports publish and receive simultaneously; there is no
/// priority order among them. The only fallback is internet → BLE → offline.

enum TransportMode { internet, bluetoothMesh, offline }

class TransportManagerV2 {
  final BluetoothMeshTransport _btMesh;
  final MessageStore _store;

  // Internet transport (from the original TransportManager)
  // Represented as a callback to avoid re-implementing everything
  final Future<void> Function({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  })? _internetPublish;

  TransportMode _mode = TransportMode.offline;
  bool _initialized = false;
  String _ourId = '';

  // Public streams
  final _incomingController = StreamController<IncomingEnvelope>.broadcast();
  final _modeController = StreamController<TransportMode>.broadcast();

  Stream<IncomingEnvelope> get incoming => _incomingController.stream;
  Stream<TransportMode> get modeChanges => _modeController.stream;
  TransportMode get currentMode => _mode;

  final List<StreamSubscription> _subs = [];

  TransportManagerV2({
    required BluetoothMeshTransport btMesh,
    required MessageStore store,
    Future<void> Function({
      required String recipientId,
      required Uint8List encryptedEnvelope,
    })? internetPublish,
  })  : _btMesh = btMesh,
        _store = store,
        _internetPublish = internetPublish;

  // ── Initialization ────────────────────────────────────────────────────────

  Future<void> initialize({required String ourId}) async {
    if (_initialized) return;
    _initialized = true;
    _ourId = ourId;

    // Monitor connectivity — connectivity_plus v6+ emits List<ConnectivityResult>
    _subs.add(
      Connectivity().onConnectivityChanged.listen((results) {
        _handleConnectivityChange(results);
      }),
    );

    // Always start BLE mesh (works in parallel or as fallback)
    final btOk = await _btMesh.initialize();
    if (btOk) {
      await _btMesh.start();

      // Receive messages from the BLE mesh
      _subs.add(
        _btMesh.deliveredEnvelopes.listen((envelope) {
          _incomingController.add(IncomingEnvelope(
            data: envelope,
            source: TransportSource.bluetoothMesh,
            receivedAt: DateTime.now(),
          ));
        }),
      );
    }

    // Check initial connectivity — v6+ returns List<ConnectivityResult>
    final results = await Connectivity().checkConnectivity();
    _handleConnectivityChange(results);
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  Future<SendResult> publish({
    required String recipientId,
    required String fullMessageId,
    required Uint8List encryptedEnvelope,
  }) async {
    switch (_mode) {
      case TransportMode.internet:
        try {
          await _internetPublish?.call(
            recipientId: recipientId,
            encryptedEnvelope: encryptedEnvelope,
          );
          return SendResult.sent(via: TransportSource.internet);
        } catch (e) {
          // Internet failed — fall back to BLE
          return _sendViaBluetooth(
            recipientId: recipientId,
            fullMessageId: fullMessageId,
            encryptedEnvelope: encryptedEnvelope,
          );
        }

      case TransportMode.bluetoothMesh:
        return _sendViaBluetooth(
          recipientId: recipientId,
          fullMessageId: fullMessageId,
          encryptedEnvelope: encryptedEnvelope,
        );

      case TransportMode.offline:
        // No transport available — save to local store
        final ok = _store.enqueue(
          MeshPacket.message(
            fullMessageId: fullMessageId,
            senderPhantomId: _ourId,
            recipientPhantomId: recipientId,
            encryptedEnvelope: encryptedEnvelope,
          ),
          targetPhantomId: recipientId,
        );
        return ok
            ? SendResult.queued()
            : SendResult.failed('Store full');
    }
  }

  Future<SendResult> _sendViaBluetooth({
    required String recipientId,
    required String fullMessageId,
    required Uint8List encryptedEnvelope,
  }) async {
    if (_btMesh.peerCount == 0) {
      // No BLE peers — save to store until they appear
      _store.enqueue(
        MeshPacket.message(
          fullMessageId: fullMessageId,
          senderPhantomId: _ourId,
          recipientPhantomId: recipientId,
          encryptedEnvelope: encryptedEnvelope,
        ),
        targetPhantomId: recipientId,
      );
      return SendResult.queued();
    }

    await _btMesh.sendEncrypted(
      fullMessageId: fullMessageId,
      recipientPhantomId: recipientId,
      encryptedEnvelope: encryptedEnvelope,
    );

    return SendResult.sent(via: TransportSource.bluetoothMesh);
  }

  // ── Connectivity ──────────────────────────────────────────────────────────

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final hasInternet = results.any((r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet);
    final hasBluetooth = _btMesh.isActive && _btMesh.peerCount > 0;

    final newMode = hasInternet
        ? TransportMode.internet
        : hasBluetooth
            ? TransportMode.bluetoothMesh
            : TransportMode.offline;

    if (newMode != _mode) {
      _mode = newMode;
      _modeController.add(_mode);

      // When internet is recovered, try to flush the store
      if (newMode == TransportMode.internet) {
        _flushStoreViaInternet();
      }
    }
  }

  Future<void> _flushStoreViaInternet() async {
    if (_internetPublish == null) return;
    final pending = _store.getAllPending();
    for (final msg in pending) {
      final recipientId = msg.targetPhantomId;
      // Skip relay-only messages with no known destination: sending to an empty
      // topic would publish to /phantom/v1/ which is invalid on IPFS pubsub.
      if (msg.packet.payload.isEmpty ||
          recipientId == null ||
          recipientId.isEmpty) {
        continue;
      }
      try {
        await _internetPublish(
          recipientId: recipientId,
          encryptedEnvelope: msg.packet.payload,
        );
        _store.markDelivered(msg.packet.messageIdHex);
      } catch (_) {
        _store.recordAttempt(msg.packet.messageIdHex);
      }
    }
  }

  // ── Public state ──────────────────────────────────────────────────────────

  MessageStore get messageStore => _store;

  TransportStatus get status => TransportStatus(
        mode: _mode,
        btPeerCount: _btMesh.peerCount,
        pendingMessages: _store.pendingCount,
        btMeshState: _btMesh.isActive,
      );

  Future<void> dispose() async {
    for (final sub in _subs) { await sub.cancel(); }
    await _btMesh.dispose();
    await _incomingController.close();
    await _modeController.close();
  }
}

// ── Result types ──────────────────────────────────────────────────────────────

enum TransportSource { internet, bluetoothMesh, stored }

class IncomingEnvelope {
  final Uint8List data;
  final TransportSource source;
  final DateTime receivedAt;

  const IncomingEnvelope({
    required this.data,
    required this.source,
    required this.receivedAt,
  });
}

class SendResult {
  final bool success;
  final bool queued;
  final TransportSource? via;
  final String? error;

  const SendResult._({
    required this.success,
    this.queued = false,
    this.via,
    this.error,
  });

  factory SendResult.sent({required TransportSource via}) =>
      SendResult._(success: true, via: via);

  factory SendResult.queued() =>
      const SendResult._(success: true, queued: true);

  factory SendResult.failed(String reason) =>
      SendResult._(success: false, error: reason);

  @override
  String toString() => queued
      ? 'SendResult(queued)'
      : success
          ? 'SendResult(sent via $via)'
          : 'SendResult(failed: $error)';
}

class TransportStatus {
  final TransportMode mode;
  final int btPeerCount;
  final int pendingMessages;
  final bool btMeshState;

  const TransportStatus({
    required this.mode,
    required this.btPeerCount,
    required this.pendingMessages,
    required this.btMeshState,
  });

  String get modeLabel => switch (mode) {
        TransportMode.internet       => 'internet',
        TransportMode.bluetoothMesh  => 'bluetooth mesh',
        TransportMode.offline        => 'offline',
      };

  @override
  String toString() =>
      'TransportStatus($modeLabel, bt_peers=$btPeerCount, pending=$pendingMessages)';
}

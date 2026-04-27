import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Abstract transport layer.
///
/// Supports multiple backends with automatic detection and fallback:
///   1. Yggdrasil (IPv6 mesh — lower latency, no central server)
///   2. I2P (maximum privacy — layered onion routing, slower)
///   3. IPFS pubsub (decentralized — works without dedicated nodes)
///
/// The app tries backends in that order and uses the first available one.
/// Users can force a specific transport in settings.

// ── Abstract interface ────────────────────────────────────────────────────────

abstract class PhantomTransport {
  String get name;
  bool get isAvailable;

  /// Publishes an encrypted message directed to [recipientId].
  /// The transport does NOT know the content — it only moves bytes.
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  });

  /// Subscribes to incoming messages for [ourId].
  /// Returns a stream of raw encrypted envelopes.
  Stream<IncomingEnvelope> subscribe({required String ourId});

  /// Verifica disponibilidad del transporte.
  Future<bool> checkAvailability();

  Future<void> dispose();
}

@immutable
class IncomingEnvelope {
  final Uint8List data;
  final String transportName;
  final DateTime receivedAt;

  const IncomingEnvelope({
    required this.data,
    required this.transportName,
    required this.receivedAt,
  });
}

// ── Transport Manager ─────────────────────────────────────────────────────────

class TransportManager {
  final List<PhantomTransport> _transports;
  PhantomTransport? _activeTransport;
  final StreamController<IncomingEnvelope> _incomingController =
      StreamController.broadcast();

  Stream<IncomingEnvelope> get incoming => _incomingController.stream;
  String? get activeTransportName => _activeTransport?.name;

  TransportManager({
    String? ipfsApiUrl,
    String? i2pSocksHost,
    int? i2pSocksPort,
    String? yggdrasilAddress,
  }) : _transports = [
          if (yggdrasilAddress != null)
            YggdrasilTransport(address: yggdrasilAddress),
          if (i2pSocksHost != null && i2pSocksPort != null)
            I2PTransport(socksHost: i2pSocksHost, socksPort: i2pSocksPort),
          IpfsTransport(apiUrl: ipfsApiUrl ?? 'http://127.0.0.1:5001'),
        ];

  /// Initializes and selects the best available transport.
  Future<void> initialize({required String ourId}) async {
    for (final transport in _transports) {
      final available = await transport.checkAvailability();
      if (available) {
        _activeTransport = transport;
        // Start listening in the background
        transport.subscribe(ourId: ourId).listen(
          _incomingController.add,
          onError: (e) => _handleTransportError(e),
        );
        return;
      }
    }
    throw const TransportException(
        'No transport available. Make sure IPFS, I2P, or Yggdrasil is running.');
  }

  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    final transport = _activeTransport;
    if (transport == null) {
      throw const TransportException('TransportManager not initialized.');
    }
    await transport.publish(
      recipientId: recipientId,
      encryptedEnvelope: encryptedEnvelope,
    );
  }

  void _handleTransportError(dynamic error) {
    // In production: attempt fallback to the next transport.
    // For now just propagate the error.
    _incomingController.addError(error);
  }

  Future<void> dispose() async {
    for (final t in _transports) {
      await t.dispose();
    }
    await _incomingController.close();
  }
}

// ── IPFS Transport ────────────────────────────────────────────────────────────

/// Transport over IPFS pubsub.
///
/// Each user has an IPFS topic derived from their PhantomID.
/// Messages are published as raw bytes to the recipient's topic.
///
/// Requires a local IPFS node with:
///   - ipfs config --json Experimental.Pubsub true
///   - ipfs daemon --enable-pubsub-experiment
class IpfsTransport implements PhantomTransport {
  final String _apiUrl;
  final http.Client _client = http.Client();
  StreamSubscription? _sub;

  @override
  final String name = 'ipfs-pubsub';

  @override
  bool get isAvailable => true; // verified in checkAvailability()

  IpfsTransport({required String apiUrl}) : _apiUrl = apiUrl;

  @override
  Future<bool> checkAvailability() async {
    try {
      final resp = await _client
          .post(Uri.parse('$_apiUrl/api/v0/id'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    final topic = _topicForId(recipientId);
    // IPFS pubsub publish expects the message as a multipart form
    final uri = Uri.parse('$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(topic)}');
    final response = await _client.post(
      uri,
      body: encryptedEnvelope,
      headers: {'Content-Type': 'application/octet-stream'},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw TransportException(
          'IPFS publish failed: ${response.statusCode} ${response.body}');
    }
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    final topic = _topicForId(ourId);
    final uri = Uri.parse(
        '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(topic)}');

    // IPFS pubsub sub returns NDJSON (one JSON line per message).
    // LineSplitter correctly handles partial chunks and multi-line data.
    final request = http.Request('POST', uri);
    final response = await _client.send(request);

    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final data = base64.decode(json['data'] as String);
        yield IncomingEnvelope(
          data: data,
          transportName: name,
          receivedAt: DateTime.now(),
        );
      } catch (_) {
        continue;
      }
    }
  }

  /// Topic IPFS = '/phantom/v1/{phantomId}'
  static String _topicForId(String phantomId) => '/phantom/v1/$phantomId';

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _client.close();
  }
}

// ── I2P Transport ─────────────────────────────────────────────────────────────

/// Transport over I2P via a local SOCKS5 proxy.
///
/// I2P must be running locally as a daemon.
/// The app connects via SOCKS5 (default: 127.0.0.1:4447).
///
/// For messaging over I2P we use the I2P HTTP proxy to communicate
/// with an anonymous relay service (Eepsite).
/// In a full implementation each user runs their own eepsite.
class I2PTransport implements PhantomTransport {
  final String socksHost;
  final int socksPort;

  @override
  final String name = 'i2p-socks5';

  @override
  bool get isAvailable => true;

  I2PTransport({required this.socksHost, required this.socksPort});

  @override
  Future<bool> checkAvailability() async {
    try {
      // Try to connect to the SOCKS5 proxy.
      // If I2P is not running, the connection fails.
      return await _checkSocksProxy();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkSocksProxy() async {
    // Real implementation: open a TCP socket to socksHost:socksPort
    // and verify the SOCKS5 handshake.
    // Placeholder — real code uses dart:io
    return false; // disabled until I2P is running
  }

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    // In I2P the recipient has a .i2p address derived from their ID.
    // Full implementation: send via I2P HTTP API or SAM bridge.
    throw UnimplementedError('I2P publish — implement with SAM bridge or I2P HTTP proxy');
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    // In I2P: listen on our I2P destination.
    // Full implementation: I2P SAM (Simple Anonymous Messaging) API.
    throw UnimplementedError('I2P subscribe — implement with SAM bridge');
  }

  @override
  Future<void> dispose() async {}
}

// ── Yggdrasil Transport ───────────────────────────────────────────────────────

/// Transport over the Yggdrasil network (encrypted IPv6 mesh).
///
/// Yggdrasil assigns a permanent IPv6 address derived from the keypair.
/// Messages are sent directly peer-to-peer over TCP/IPv6.
///
/// Advantages over IPFS/I2P:
///   - Lower latency (direct routing)
///   - No intermediary server
///   - Static address derived from identity
///
/// Requires Yggdrasil running as a system daemon.
class YggdrasilTransport implements PhantomTransport {
  final String address; // own Yggdrasil IPv6 address
  static const int listenPort = 7331; // Phantom port over Yggdrasil

  @override
  final String name = 'yggdrasil-direct';

  @override
  bool get isAvailable => true;

  YggdrasilTransport({required this.address});

  @override
  Future<bool> checkAvailability() async {
    // Verify Yggdrasil is active: ping own address.
    // Real implementation: dart:io RawServerSocket over IPv6.
    try {
      return await _checkYggdrasilInterface();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkYggdrasilInterface() async {
    // Placeholder — real code opens a UDP socket on address:listenPort
    return false;
  }

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    // In Yggdrasil: the recipient's IPv6 address is derived from their PhantomID.
    // Full implementation: TCP stream over Yggdrasil IPv6.
    throw UnimplementedError('Yggdrasil publish — implement with dart:io IPv6 socket');
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    // Listen on address:listenPort.
    throw UnimplementedError('Yggdrasil subscribe — implement with ServerSocket IPv6');
  }

  @override
  Future<void> dispose() async {}
}

class TransportException implements Exception {
  final String message;
  const TransportException(this.message);
  @override
  String toString() => 'TransportException: $message';
}

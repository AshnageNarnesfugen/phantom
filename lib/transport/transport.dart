import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import '../core/transport_debugger.dart';

/// Abstract transport layer.
///
/// All configured backends run concurrently when available:
///   - Yggdrasil (IPv6 mesh — lower latency, no central server)
///   - I2P (maximum privacy — layered onion routing, slower)
///   - IPFS pubsub (decentralized — works without dedicated nodes, embedded daemon)
///
/// Messages are published to every active backend simultaneously.
/// Incoming messages arrive from all active backends; the Double Ratchet
/// naturally discards duplicates by rejecting already-seen counters.
/// The only fallback boundary is internet (all backends) vs BLE mesh.

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
  final List<PhantomTransport> _activeTransports = [];
  final StreamController<IncomingEnvelope> _incomingController =
      StreamController.broadcast();

  // Used by _activateLateTransports to subscribe newly-available transports.
  String _ourId = '';
  DateTime? _lastRetryAt;

  Stream<IncomingEnvelope> get incoming => _incomingController.stream;

  /// Names of all currently active transports (empty until [initialize] is called).
  List<String> get activeTransportNames =>
      _activeTransports.map((t) => t.name).toList();

  /// True once at least one transport is active.
  bool get isActive => _activeTransports.isNotEmpty;

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

  /// Checks all transports in parallel and starts every reachable one.
  /// Does NOT throw when no transport is reachable — the daemon may still be
  /// starting; [publish] will retry via [_activateLateTransports].
  Future<void> initialize({required String ourId}) async {
    _ourId = ourId;
    final reachable = await Future.wait(
      _transports.map((t) async {
        try {
          return await t.checkAvailability() ? t : null;
        } catch (_) {
          return null;
        }
      }),
    );

    for (final t in reachable.whereType<PhantomTransport>()) {
      _activeTransports.add(t);
      t.subscribe(ourId: ourId).listen(
        _incomingController.add,
        onError: (_) {},
      );
    }
    // No throw when empty — [publish] retries late-starting transports.
  }

  /// Re-checks any transport that was not available at [initialize] time.
  /// Throttled to once per 20 s so it doesn't slow down every publish call.
  Future<void> _activateLateTransports() async {
    if (_ourId.isEmpty) return;
    final now = DateTime.now();
    if (_lastRetryAt != null &&
        now.difference(_lastRetryAt!) < const Duration(seconds: 10)) {
      return;
    }
    _lastRetryAt = now;

    for (final t in _transports) {
      if (_activeTransports.contains(t)) { continue; }
      try {
        if (await t.checkAvailability()) {
          _activeTransports.add(t);
          t.subscribe(ourId: _ourId).listen(
            _incomingController.add,
            onError: (_) {},
          );
        }
      } catch (_) {}
    }
  }

  /// Publishes to every active transport in parallel.
  /// Succeeds if at least one transport delivers the message.
  /// If no transport is active, attempts to activate late-starting ones first.
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    if (_activeTransports.isEmpty) {
      await _activateLateTransports();
    }
    if (_activeTransports.isEmpty) {
      throw const TransportException('No transport available (IPFS daemon not running).');
    }
    int successes = 0;
    Object? lastError;
    await Future.wait([
      for (final t in _activeTransports)
        t
            .publish(recipientId: recipientId, encryptedEnvelope: encryptedEnvelope)
            .then((_) { successes++; })
            .onError((e, _) { lastError = e; }),
    ]);
    if (successes == 0) throw lastError!;
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
  bool _disposed = false;

  @override
  final String name = 'ipfs-pubsub';

  @override
  bool get isAvailable => true;

  IpfsTransport({required String apiUrl}) : _apiUrl = apiUrl;

  @override
  Future<bool> checkAvailability() async {
    final dbg = TransportDebugger.instance;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final resp = await _client
            .post(Uri.parse('$_apiUrl/api/v0/id'))
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          dbg.log('IPFS: API reachable (attempt ${attempt + 1})');
          return true;
        }
        dbg.log('IPFS: /id returned ${resp.statusCode} on attempt ${attempt + 1}');
      } catch (e) {
        dbg.log('IPFS: /id error on attempt ${attempt + 1}: $e');
      }
      if (attempt < 4) await Future.delayed(const Duration(seconds: 2));
    }
    dbg.log('IPFS: API not reachable after 5 attempts');
    return false;
  }

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    final dbg   = TransportDebugger.instance;
    final topic = _topicForId(recipientId);
    final short = recipientId.substring(0, 8);

    dbg.log('IPFS: publish → $short (${encryptedEnvelope.length} bytes)');

    // Check if the recipient's node is in the gossipsub mesh for their topic.
    // Gossipsub subscription announcements take a few seconds to propagate, so
    // retry once after a short delay before giving up and queuing for later.
    var peers = await _checkTopicPeers(topic);
    dbg.log('IPFS: peer check pass-1 for $short → ${peers ? "✓ peers found" : "✗ no peers"}');

    if (!peers) {
      dbg.log('IPFS: waiting 4s for gossipsub propagation…');
      await Future.delayed(const Duration(seconds: 4));
      peers = await _checkTopicPeers(topic);
      dbg.log('IPFS: peer check pass-2 for $short → ${peers ? "✓ peers found" : "✗ still no peers — queuing"}');
    }

    if (!peers) {
      throw const TransportException('No IPFS pubsub peers on recipient topic');
    }

    final uri = Uri.parse('$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
    final response = await _client.post(
      uri,
      body: encryptedEnvelope,
      headers: {'Content-Type': 'application/octet-stream'},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      dbg.log('IPFS: publish HTTP ${response.statusCode} → ${response.body}');
      throw TransportException(
          'IPFS publish failed: ${response.statusCode} ${response.body}');
    }
    dbg.log('IPFS: published OK to $short');
  }

  Future<bool> _checkTopicPeers(String topic) async {
    try {
      final uri = Uri.parse(
          '$_apiUrl/api/v0/pubsub/peers?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
      final resp = await _client
          .post(uri)
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return false;
      final json  = jsonDecode(resp.body) as Map<String, dynamic>;
      final peers = (json['Strings'] as List?)?.cast<String>() ?? [];
      return peers.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    final dbg   = TransportDebugger.instance;
    final topic = _topicForId(ourId);
    final uri   = Uri.parse(
        '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');

    while (!_disposed) {
      dbg.log('IPFS: subscribing to ${topic.substring(topic.lastIndexOf('/') + 1)}…');
      try {
        final request  = http.Request('POST', uri);
        final response = await _client.send(request);

        // HTTP != 200 means pubsub is disabled or the daemon is not ready.
        // Drain the body (avoids socket leak) and back off — do NOT loop tight.
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          dbg.log('IPFS: sub returned HTTP ${response.statusCode}: $body — retrying in 15s');
          if (!_disposed) await Future.delayed(const Duration(seconds: 15));
          continue;
        }

        dbg.log('IPFS: subscription stream open');
        await for (final line in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (_disposed) return;
          if (line.trim().isEmpty) continue;
          try {
            final json = jsonDecode(line) as Map<String, dynamic>;
            final rawData = json['data'];
            if (rawData == null) continue;
            final data = _decodeData(rawData as String);
            dbg.log('IPFS: ← received ${data.length} bytes on ${ourId.substring(0, 8)}');
            yield IncomingEnvelope(
              data: data,
              transportName: name,
              receivedAt: DateTime.now(),
            );
          } catch (e) {
            dbg.log('IPFS: failed to parse incoming line: $e');
            continue;
          }
        }
        dbg.log('IPFS: subscription stream closed — reconnecting in 5s');
        if (!_disposed) await Future.delayed(const Duration(seconds: 5));
      } catch (e) {
        dbg.log('IPFS: subscription error: $e — retrying in 10s');
        if (!_disposed) await Future.delayed(const Duration(seconds: 10));
      }
    }
  }

  static String _topicForId(String phantomId) => '/phantom/v1/$phantomId';

  /// Kubo >= 0.11 requires pubsub topic args to be multibase-encoded.
  /// We use base64url without padding (multibase prefix 'u').
  static String _encodeTopic(String topic) {
    final bytes = utf8.encode(topic);
    return 'u${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  /// Decodes a multibase-encoded payload from a pubsub response.
  /// Kubo >= 0.11 encodes data with a multibase prefix ('m'=base64, 'u'=base64url).
  /// Falls back to plain base64 for compatibility with older daemons.
  static Uint8List _decodeData(String raw) {
    if (raw.startsWith('m')) return base64.decode(raw.substring(1));
    if (raw.startsWith('u')) {
      final padded = raw.substring(1).padRight(
          (raw.length - 1 + 3) & ~3, '=');
      return base64Url.decode(padded);
    }
    return base64.decode(raw); // old plain-base64 fallback
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
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



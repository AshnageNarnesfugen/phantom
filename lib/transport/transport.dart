import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Abstract transport layer.
///
/// All configured backends run concurrently when available:
///   - Yggdrasil (IPv6 mesh — lower latency, no central server)
///   - I2P (maximum privacy — layered onion routing, slower)
///   - IPFS pubsub (decentralized — works without dedicated nodes)
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
    String? ntfyBaseUrl,
  }) : _transports = [
          if (yggdrasilAddress != null)
            YggdrasilTransport(address: yggdrasilAddress),
          if (i2pSocksHost != null && i2pSocksPort != null)
            I2PTransport(socksHost: i2pSocksHost, socksPort: i2pSocksPort),
          IpfsTransport(apiUrl: ipfsApiUrl ?? 'http://127.0.0.1:5001'),
          NtfyTransport(baseUrl: ntfyBaseUrl ?? 'https://ntfy.sh'),
        ];

  /// Checks all transports in parallel and starts every reachable one.
  /// Throws only when no transport at all is reachable.
  Future<void> initialize({required String ourId}) async {
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
        onError: (_) {}, // individual transport errors are non-fatal
      );
    }

    if (_activeTransports.isEmpty) {
      throw const TransportException(
          'No transport available. Make sure IPFS, I2P, or Yggdrasil is running.');
    }
  }

  /// Publishes to every active transport in parallel.
  /// Succeeds if at least one transport delivers the message.
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    if (_activeTransports.isEmpty) {
      throw const TransportException('TransportManager not initialized.');
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

// ── ntfy.sh Relay Transport ───────────────────────────────────────────────────

/// Relay transport via ntfy.sh — a free, open-source pub/sub service.
///
/// Each recipient has a topic derived from their PhantomID. Messages are
/// published as binary attachments (no practical size limit). ntfy retains
/// messages for 24 hours on the shared instance; self-hosting removes that
/// cap (see https://ntfy.sh/docs/install/).
///
/// Privacy model: the ntfy server sees which topics are active (timing) but
/// cannot read payloads — they are encrypted by Phantom's Double Ratchet.
/// Topic names are derived from PhantomIDs, so anyone with a PhantomID can
/// observe when that user receives messages.
class NtfyTransport implements PhantomTransport {
  final String _baseUrl;
  final http.Client _client = http.Client();

  /// Unix timestamp of the most-recently seen ntfy event.
  /// Passed as `since=` on reconnect to avoid missing messages during gaps.
  int _lastSeenAt = 0;

  @override
  final String name = 'ntfy-relay';

  @override
  bool get isAvailable => true;

  NtfyTransport({String baseUrl = 'https://ntfy.sh'}) : _baseUrl = baseUrl;

  @override
  Future<bool> checkAvailability() async {
    try {
      final resp = await _client
          .get(Uri.parse('$_baseUrl/v1/health'))
          .timeout(const Duration(seconds: 5));
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
    // PUT creates a binary attachment (preserves arbitrary bytes).
    // POST sends body as text and garbles non-UTF-8 bytes.
    final response = await _client
        .put(
          Uri.parse('$_baseUrl/$topic'),
          headers: {
            'Content-Type': 'application/octet-stream',
            'Filename': 'msg.bin',
          },
          body: encryptedEnvelope,
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw TransportException(
          'ntfy publish failed: ${response.statusCode} ${response.body}');
    }
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    final topic = _topicForId(ourId);

    // On first open look back 3 hours — matching ntfy's attachment download
    // window — to recover messages missed while the app was closed.
    // On reconnect, resume from the last acknowledged event.
    if (_lastSeenAt == 0) {
      _lastSeenAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 10800;
    }

    while (true) {
      try {
        final uri = Uri.parse('$_baseUrl/$topic/json?since=$_lastSeenAt');
        final request = http.Request('GET', uri);
        final streamed = await _client.send(request);

        final lines = streamed.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());

        await for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final event = jsonDecode(line) as Map<String, dynamic>;
            if (event['event'] == 'open') continue;
            if (event['event'] != 'message') continue;

            final at = (event['time'] as num?)?.toInt() ?? 0;
            if (at > _lastSeenAt) _lastSeenAt = at;

            final attachment = event['attachment'] as Map<String, dynamic>?;
            final attachUrl = attachment?['url'] as String?;
            if (attachUrl == null) continue;

            final binResp = await _client
                .get(Uri.parse(attachUrl))
                .timeout(const Duration(seconds: 10));
            if (binResp.statusCode != 200) continue;

            yield IncomingEnvelope(
              data: binResp.bodyBytes,
              transportName: name,
              receivedAt: DateTime.now(),
            );
          } catch (_) {
            continue;
          }
        }
      } catch (_) {
        // Pause before reconnecting on network error.
        await Future.delayed(const Duration(seconds: 10));
      }
    }
  }

  /// PhantomIDs are base58-encoded (URL-safe alphanumeric) — safe as topic names.
  static String _topicForId(String phantomId) => 'ph-$phantomId';

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

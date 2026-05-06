import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
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
  final Set<String> _swarmConnected = {};

  /// Active cross-subscriptions keyed by topic string.
  /// When we publish to a recipient, we also subscribe to their topic
  /// so GossipSub can form a mesh (exchange SUBSCRIBE announcements).
  /// Each entry holds a keep-alive timer; when it fires the subscription
  /// is considered stale and removed.
  final Map<String, Timer> _crossSubs = {};

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

    // ── Step 1: Cross-subscribe to recipient's topic ──────────────────────
    // GossipSub only forms a mesh between peers that BOTH subscribe to the
    // same topic. Without this, pubsub/peers returns 0 for the recipient's
    // topic and the published message goes nowhere.
    dbg.log('IPFS: cross-subscribing to $short topic…');
    await _ensureCrossSubscribed(topic, dbg);

    // ── Step 2: DHT discovery + swarm connect ────────────────────────────
    dbg.log('IPFS: trying DHT discovery for $short…');
    final connected = await _dhtDiscoverAndConnect(recipientId, dbg);
    
    if (!connected) {
      throw const TransportException('No verified IPFS swarm connection to peer');
    }

    // ── Step 3: Wait for GossipSub mesh formation ────────────────────────
    // After the swarm connection is up AND we are cross-subscribed, GossipSub
    // needs time to exchange SUBSCRIBE announcements and build the mesh.
    // Poll pubsub/peers instead of a blind wait.
    dbg.log('IPFS: waiting for gossipsub mesh on $short topic…');
    final hasPeers = await _waitForTopicPeers(topic, dbg);
    if (!hasPeers) {
      dbg.log('IPFS: WARNING — no gossipsub peers found for $short, publishing anyway');
    }

    // ── Step 4: Publish ──────────────────────────────────────────────────
    final uri = Uri.parse('$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
    final request = http.MultipartRequest('POST', uri);
    request.files.add(http.MultipartFile.fromBytes('data', encryptedEnvelope));
    
    final streamedResponse = await _client.send(request).timeout(const Duration(seconds: 10));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      dbg.log('IPFS: publish HTTP ${response.statusCode} → ${response.body}');
      throw TransportException(
          'IPFS publish failed: ${response.statusCode} ${response.body}');
    }
    dbg.log('IPFS: published OK to $short');
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

            // Bootstrap gossipsub mesh with the sender so future outbound
            // publishes find peers immediately.
            final rawFrom = json['from'] as String?;
            if (rawFrom != null) unawaited(_trySwarmConnect(rawFrom, dbg));

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

  /// Looks up the recipient's IPFS peer via DHT provider records and connects.
  /// Mirrors the same rendezvous mechanism used by PresenceService so the
  /// message transport can bootstrap independently when presence hasn't run yet.
  Future<bool> _dhtDiscoverAndConnect(String phantomId, TransportDebugger dbg) async {
    try {
      final cid = await _phantomCid(phantomId);
      final uri = Uri.parse(
          '$_apiUrl/api/v0/routing/findprovs?arg=${Uri.encodeComponent(cid)}&num-providers=5');
      final request  = http.Request('POST', uri);
      final response = await _client.send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        dbg.log('IPFS: findprovs HTTP ${response.statusCode}');
        return false;
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (_disposed) return false;
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          // Only process Type 4 — actual provider records.
          // Other types (1=PeerResponse, 2=FinalPeer, etc.) are intermediate
          // DHT routing nodes that happen to be near the CID; connecting to
          // them wastes time and causes log spam.
          final type = json['Type'];
          if (type != null && type != 4) continue;

          final responses = json['Responses'];
          if (responses is! List) continue;
          for (final peer in responses.cast<Map<String, dynamic>>()) {
            final peerId = peer['ID'] as String?;
            final addrs  = (peer['Addrs'] as List?)?.cast<String>() ?? [];
            if (peerId == null || peerId.isEmpty || addrs.isEmpty) continue;
            dbg.log('IPFS: DHT provider ${peerId.substring(0, 12)}… — connecting');
            if (!_swarmConnected.contains(peerId)) {
              final connected = await _connectById(peerId, addrs, dbg);
              if (connected) {
                _swarmConnected.add(peerId);
                return true; // Stop findprovs early if we successfully connected
              }
            } else {
               // We thought we were connected. Double check swarm/peers.
               final isConnected = await _verifySwarmConnection(peerId);
               if (isConnected) {
                  dbg.log('IPFS: peer $peerId already verified in swarm/peers');
                  return true;
               } else {
                  // Connection dropped. Remove from cache and dial again.
                  _swarmConnected.remove(peerId);
                  final connected = await _connectById(peerId, addrs, dbg);
                  if (connected) {
                     _swarmConnected.add(peerId);
                     return true;
                  }
               }
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      dbg.log('IPFS: DHT discover error: $e');
    }
    return false;
  }

  Future<bool> _verifySwarmConnection(String peerId) async {
      try {
        final r = await _client.post(Uri.parse('$_apiUrl/api/v0/swarm/peers'))
            .timeout(const Duration(seconds: 3));
        if (r.statusCode == 200) {
          final json = jsonDecode(r.body) as Map<String, dynamic>;
          final peers = (json['Peers'] as List?) ?? [];
          return peers.any((p) {
             final pId = (p as Map)['Peer'];
             return pId == peerId;
          });
        }
      } catch (_) {}
      return false;
  }

  /// Computes a deterministic CIDv1 (raw, sha2-256) from a Phantom ID.
  /// Shared rendezvous key with PresenceService — must match exactly.
  static Future<String> _phantomCid(String phantomId) async {
    final hash     = await Sha256().hash(utf8.encode('phantom-peer-v1:$phantomId'));
    final cidBytes = Uint8List(36);
    cidBytes[0] = 0x01; cidBytes[1] = 0x55; // CIDv1, raw codec
    cidBytes[2] = 0x12; cidBytes[3] = 0x20; // sha2-256 multihash
    cidBytes.setRange(4, 36, hash.bytes);
    final hex = cidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'f$hex';
  }

  /// Connects to a peer given its already-decoded peer ID and known multiaddrs.
  /// Returns true if at least one address successfully connected.
  Future<bool> _connectById(
      String peerId, List<String> addrs, TransportDebugger dbg) async {
    // Skip loopback and link-local — connecting to them either fails (can't
    // reach a remote peer via 127.0.0.1) or hits our own daemon (HTTP 500).
    final usable = addrs.where((a) =>
        !a.contains('/127.0.0.1/') &&
        !a.contains('/::1/') &&
        !a.contains('/169.254.') &&
        !a.contains('/fe80:')).toList();

    final sorted = [...usable]..sort((a, b) {
        final aR = a.contains('p2p-circuit') ? 0 : 1;
        final bR = b.contains('p2p-circuit') ? 0 : 1;
        if (aR != bR) return aR.compareTo(bR);
        final aL = (a.contains('/192.168.') || a.contains('/10.') || a.contains('/172.')) ? 0 : 1;
        final bL = (b.contains('/192.168.') || b.contains('/10.') || b.contains('/172.')) ? 0 : 1;
        return aL.compareTo(bL);
      });
    final targets = [
      ...sorted.take(8).map((a) => '$a/p2p/$peerId'),
      '/p2p/$peerId',
    ];

    // Dial all addresses in parallel. Don't stop at the first fake 'success'.
    unawaited(Future.wait(targets.map((addr) async {
      if (_disposed) return;
      try {
        final r = await _client
            .post(Uri.parse(
                '$_apiUrl/api/v0/swarm/connect?arg=${Uri.encodeComponent(addr)}'))
            .timeout(const Duration(seconds: 10));
        final body = r.body;
        dbg.log('IPFS: swarm/connect ${r.statusCode} → ${addr.split('/').take(5).join('/')}… [${body.contains("success") ? "OK" : "FAIL"}]');
      } catch (e) {
        dbg.log('IPFS: swarm/connect error: $e');
      }
    })));

    // Verify true connection by polling swarm/peers for up to 10 seconds.
    for (int i = 0; i < 5; i++) {
      if (_disposed) return false;
      await Future.delayed(const Duration(seconds: 2));
      try {
        final r = await _client.post(Uri.parse('$_apiUrl/api/v0/swarm/peers'))
            .timeout(const Duration(seconds: 3));
        if (r.statusCode == 200) {
          final json = jsonDecode(r.body) as Map<String, dynamic>;
          final peers = (json['Peers'] as List?) ?? [];
          final isConnected = peers.any((p) {
             final pId = (p as Map)['Peer'];
             return pId == peerId;
          });
          if (isConnected) {
            dbg.log('IPFS: verified true connection to ${peerId.substring(0, 8)} in swarm/peers');
            return true;
          }
        }
      } catch (_) {}
    }
    
    dbg.log('IPFS: failed to verify connection to ${peerId.substring(0, 8)}');
    return false;
  }

  /// Connects directly to the IPFS peer that sent us a message so future
  /// outbound publishes find them in the gossipsub mesh immediately.
  ///
  /// [rawFrom] is the multibase-encoded peer ID from the pubsub `from` field.
  Future<void> _trySwarmConnect(String rawFrom, TransportDebugger dbg) async {
    String peerId;
    try {
      if (rawFrom.startsWith('u')) {
        final padded = rawFrom.substring(1).padRight(
            (rawFrom.length - 1 + 3) & ~3, '=');
        peerId = utf8.decode(base64Url.decode(padded));
      } else if (rawFrom.startsWith('m')) {
        peerId = utf8.decode(base64.decode(rawFrom.substring(1)));
      } else {
        peerId = rawFrom;
      }
    } catch (_) {
      return;
    }

    if (_swarmConnected.contains(peerId)) return;
    _swarmConnected.add(peerId);
    dbg.log('IPFS: swarm-connect → ${peerId.substring(0, 12)}…');

    try {
      final findUri = Uri.parse(
          '$_apiUrl/api/v0/routing/findpeer?arg=${Uri.encodeComponent(peerId)}');
      final findResp = await _client
          .post(findUri)
          .timeout(const Duration(seconds: 15));
      if (findResp.statusCode != 200) {
        dbg.log('IPFS: findpeer HTTP ${findResp.statusCode}');
        return;
      }

      final json  = jsonDecode(findResp.body) as Map<String, dynamic>;
      final addrs = (json['Addrs'] as List?)?.cast<String>() ?? [];
      dbg.log('IPFS: findpeer found ${addrs.length} addrs for ${peerId.substring(0, 12)}…');

      // Prefer relay addresses (work through NAT) before direct ones.
      final sorted = [...addrs]..sort((a, b) {
          final aR = a.contains('p2p-circuit') ? 0 : 1;
          final bR = b.contains('p2p-circuit') ? 0 : 1;
          if (aR != bR) return aR.compareTo(bR);
          final aL = (a.contains('/192.168.') || a.contains('/10.') || a.contains('/172.')) ? 0 : 1;
          final bL = (b.contains('/192.168.') || b.contains('/10.') || b.contains('/172.')) ? 0 : 1;
          return aL.compareTo(bL);
        });

      for (final addr in sorted.take(8)) {
        if (_disposed) return;
        final full = '$addr/p2p/$peerId';
        try {
          final connectUri = Uri.parse(
              '$_apiUrl/api/v0/swarm/connect?arg=${Uri.encodeComponent(full)}');
          final r = await _client
              .post(connectUri)
              .timeout(const Duration(seconds: 10));
          final body = r.body;
          dbg.log('IPFS: swarm/connect ${r.statusCode} to ${addr.split('/').take(5).join('/')} [${body.contains("success") ? "OK" : "FAIL"}]');
          if (body.contains('success')) return;
        } catch (e) {
          dbg.log('IPFS: swarm/connect error: $e');
        }
      }
      
      // Always try the smart dialer as fallback
      try {
          final r = await _client.post(Uri.parse('$_apiUrl/api/v0/swarm/connect?arg=${Uri.encodeComponent('/p2p/$peerId')}')).timeout(const Duration(seconds: 10));
          dbg.log('IPFS: swarm/connect to /p2p/$peerId [${r.body.contains("success") ? "OK" : "FAIL"}]');
      } catch(_) {}

    } catch (e) {
      dbg.log('IPFS: _trySwarmConnect error: $e');
    }
  }

  // ── Cross-subscription for GossipSub mesh formation ─────────────────────

  /// Opens a subscription to [topic] so that GossipSub announces us as a
  /// peer on that topic. This is the key mechanism that allows pubsub/peers
  /// to return >0 for the recipient's topic. The subscription is kept alive
  /// for 5 minutes and refreshed on each publish to the same recipient.
  Future<void> _ensureCrossSubscribed(String topic, TransportDebugger dbg) async {
    // Refresh the keep-alive timer if already subscribed.
    if (_crossSubs.containsKey(topic)) {
      _crossSubs[topic]!.cancel();
      _crossSubs[topic] = Timer(const Duration(minutes: 5), () {
        _crossSubs.remove(topic);
        dbg.log('IPFS: cross-sub expired for ${topic.split('/').last.substring(0, 8)}');
      });
      return;
    }

    // Open a pubsub/sub stream to the recipient's topic.
    // We don't process messages — the act of subscribing is what makes
    // GossipSub announce us and form the mesh.
    final uri = Uri.parse(
      '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
    try {
      final request = http.Request('POST', uri);
      final response = await _client.send(request)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        // Drain the stream in the background (keeps the subscription alive
        // in the IPFS daemon). The stream closes when the HTTP connection
        // is interrupted or the daemon shuts down.
        unawaited(response.stream.drain<void>().catchError((_) {}));
        dbg.log('IPFS: cross-sub active for ${topic.split('/').last.substring(0, 8)}');
      } else {
        dbg.log('IPFS: cross-sub HTTP ${response.statusCode}');
      }
    } catch (e) {
      dbg.log('IPFS: cross-sub error: $e');
    }

    _crossSubs[topic] = Timer(const Duration(minutes: 5), () {
      _crossSubs.remove(topic);
    });
  }

  /// Polls `pubsub/peers` for up to ~18 seconds until at least one peer
  /// appears on [topic]. Returns true as soon as a peer is found.
  Future<bool> _waitForTopicPeers(String topic, TransportDebugger dbg) async {
    final encodedTopic = _encodeTopic(topic);
    for (int i = 0; i < 6; i++) {
      if (_disposed) return false;
      try {
        final r = await _client.post(Uri.parse(
            '$_apiUrl/api/v0/pubsub/peers?arg=${Uri.encodeComponent(encodedTopic)}'))
            .timeout(const Duration(seconds: 3));
        if (r.statusCode == 200) {
          final json = jsonDecode(r.body) as Map<String, dynamic>;
          final strings = (json['Strings'] as List?) ?? [];
          if (strings.isNotEmpty) {
            dbg.log('IPFS: ${strings.length} gossipsub peer(s) on topic');
            return true;
          }
          dbg.log('IPFS: pubsub/peers poll ${i + 1}/6 — 0 peers');
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final timer in _crossSubs.values) {
      timer.cancel();
    }
    _crossSubs.clear();
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



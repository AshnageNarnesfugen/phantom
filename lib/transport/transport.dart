import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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

  /// All configured transports (active or not). Exposed so callers can reach
  /// transport-specific APIs (e.g. [IpfsTransport.setContactIpfsPeerId]).
  List<PhantomTransport> get transports => _transports;

  /// True once at least one transport is active.
  bool get isActive => _activeTransports.isNotEmpty;

  TransportManager({
    String? ipfsApiUrl,
    String? i2pSamHost,
    int? i2pSamPort,
    String? yggdrasilAddress,
  }) : _transports = [
          YggdrasilTransport(address: yggdrasilAddress),
          I2PTransport(
            host: i2pSamHost ?? '127.0.0.1', 
            samPort: i2pSamPort ?? 7656
          ),
          IpfsTransport(apiUrl: ipfsApiUrl ?? 'http://127.0.0.1:5001'),
        ];

  /// Checks all transports in parallel and starts every reachable one.
  /// Does NOT throw when no transport is reachable — the daemon may still be
  /// starting; [publish] will retry via [_activateLateTransports].
  Future<void> initialize({required String ourId}) async {
    _ourId = ourId;
    final dbg = TransportDebugger.instance;
    dbg.log('TRANSPORT: initializing for ${ourId.substring(0, 8)}...');

    final reachable = await Future.wait(
      _transports.map((t) async {
        try {
          final ok = await t.checkAvailability();
          dbg.log('TRANSPORT: ${t.name} availability = $ok');
          return ok ? t : null;
        } catch (e) {
          dbg.log('TRANSPORT: ${t.name} check failed: $e');
          return null;
        }
      }),
    );

    for (final t in reachable.whereType<PhantomTransport>()) {
      _activeTransports.add(t);
      t.subscribe(ourId: ourId).listen(
        _incomingController.add,
        onError: (e) => dbg.log('TRANSPORT: ${t.name} stream error: $e'),
      );
    }
    
    if (_activeTransports.isEmpty) {
      dbg.log('TRANSPORT: WARNING - no transports active!');
    }
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

  /// Stores transport-specific metadata for contacts (Ygg addresses, I2P destinations, etc.)
  final Map<String, String> _yggAddrs = {};
  final Map<String, String> _i2pDests = {};

  void setContactYggAddress(String contactId, String address) => _yggAddrs[contactId] = address;
  void setContactI2PDestination(String contactId, String dest) => _i2pDests[contactId] = dest;
  void setContactIpfsPeerId(String contactId, String peerId) {
    for (var t in _transports.whereType<IpfsTransport>()) {
      t.setContactIpfsPeerId(contactId, peerId);
    }
  }

  /// Publishes the message over ALL available transports SIMULTANEOUSLY.
  /// Whichever network is fastest will trigger the Double Ratchet decryption first.
  /// Slower networks will deliver a duplicate packet that the MessageStore will safely ignore.
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
    bool isHandshake = false,
  }) async {
    if (_activeTransports.isEmpty) await _activateLateTransports();
    if (_activeTransports.isEmpty) {
      throw const TransportException('No transport available.');
    }

    final dbg = TransportDebugger.instance;
    final futures = <Future<void>>[];

    // 1. I2P
    final i2p = _activeTransports.whereType<I2PTransport>().firstOrNull;
    final dest = _i2pDests[recipientId];
    if (i2p != null && dest != null) {
      futures.add(() async {
        dbg.log('TRANSPORT: firing I2P to ${dest.substring(0, 12)}...');
        try {
          await i2p.publishToDest(dest: dest, data: encryptedEnvelope);
          dbg.log('TRANSPORT: I2P delivery successful');
        } catch (e) {
          dbg.log('TRANSPORT: I2P failed ($e)');
          rethrow;
        }
      }());
    }

    // 2. Yggdrasil
    final ygg = _activeTransports.whereType<YggdrasilTransport>().firstOrNull;
    final yggAddr = _yggAddrs[recipientId];
    if (ygg != null && yggAddr != null) {
      futures.add(() async {
        dbg.log('TRANSPORT: firing Yggdrasil to ${recipientId.substring(0, 8)}...');
        try {
          await ygg.publishToAddr(address: yggAddr, data: encryptedEnvelope);
          dbg.log('TRANSPORT: Yggdrasil delivery successful');
        } catch (e) {
          dbg.log('TRANSPORT: Yggdrasil failed ($e)');
          rethrow;
        }
      }());
    }

    // 3. IPFS
    final ipfsList = _activeTransports.whereType<IpfsTransport>();
    for (final ipfs in ipfsList) {
      // Signal handshake mode so IPFS waits for GossipSub mesh formation
      if (isHandshake) ipfs.markNextPublishAsHandshake();
      futures.add(() async {
        dbg.log('TRANSPORT: firing IPFS PubSub for ${recipientId.substring(0, 8)}...');
        try {
          await ipfs.publish(recipientId: recipientId, encryptedEnvelope: encryptedEnvelope);
          dbg.log('TRANSPORT: IPFS delivery successful');
        } catch (e) {
          dbg.log('TRANSPORT: IPFS failed ($e)');
          rethrow;
        }
      }());
    }

    if (futures.isEmpty) {
      throw const TransportException('No valid transport target for recipient.');
    }

    // Wait for all transports to finish (either success or fail)
    final results = await Future.wait(
      futures.map((f) => f.then((_) => true).catchError((_) => false))
    );

    // If EVERY single transport failed, throw an error to fallback to Bluetooth/Storage.
    if (!results.any((success) => success)) {
      throw const TransportException('All simultaneous transport layers failed.');
    }
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
  /// Holds the StreamSubscription so we can cancel (close) the HTTP stream
  /// on dispose — avoids accumulating zombie connections.
  final Map<String, StreamSubscription<List<int>>> _crossSubs = {};

  /// Known IPFS peer IDs for contacts, populated from the '#<peerId>' suffix
  /// in the contact address. When set, _dhtDiscoverAndConnect skips findprovs
  /// and dials the peer directly via circuit relay.
  final Map<String, String> _contactIpfsPeerIds = {};

  /// Stores the IPFS peer ID for [contactId] so future publishes can connect
  /// directly without a DHT provider record walk.
  void setContactIpfsPeerId(String contactId, String ipfsPeerId) {
    _contactIpfsPeerIds[contactId] = ipfsPeerId;
  }

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

  /// If true, the next publish call will wait for GossipSub mesh formation.
  bool _nextPublishIsHandshake = false;

  /// Mark the next publish as a handshake so it waits for the mesh.
  void markNextPublishAsHandshake() => _nextPublishIsHandshake = true;

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    final dbg   = TransportDebugger.instance;
    final topic = _topicForId(recipientId);
    final short = recipientId.substring(0, 8);
    final isHandshake = _nextPublishIsHandshake;
    _nextPublishIsHandshake = false;

    dbg.log('IPFS: publish → $short (${encryptedEnvelope.length} bytes, handshake=$isHandshake)');

    // ── Step 1: Cross-subscribe to recipient's topic ──────────────────────
    dbg.log('IPFS: cross-subscribing to $short topic…');
    await _ensureCrossSubscribed(topic, dbg);

    // ── Step 2: DHT discovery + swarm connect (best-effort) ──────────────
    // For handshakes, this is critical. For regular messages, this is
    // opportunistic — we ALWAYS publish to the topic regardless.
    dbg.log('IPFS: trying DHT discovery for $short…');
    final connected = await _dhtDiscoverAndConnect(recipientId, dbg);

    if (!connected && isHandshake) {
      // For handshakes, fail hard — no point sending INIT to an empty mesh
      throw const TransportException('No verified IPFS swarm connection to peer');
    }

    // ── Step 3: Wait for GossipSub mesh formation ────────────────────────
    if (connected) {
      final maxWaitSecs = isHandshake ? 15 : 3;
      bool hasPeers = false;
      for (int i = 0; i < maxWaitSecs; i++) {
        hasPeers = await _checkTopicPeers(topic, dbg);
        if (hasPeers) break;
        if (i < maxWaitSecs - 1) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      if (!hasPeers && isHandshake) {
        dbg.log('IPFS: ⚠ gossipsub mesh NOT formed after ${maxWaitSecs}s — throwing to queue INIT');
        throw const TransportException('GossipSub mesh not formed, peer likely offline');
      }
    } else {
      dbg.log('IPFS: peer not verified in swarm, publishing to topic anyway (best-effort)');
    }

    // ── Step 4: Publish — ALWAYS execute for non-handshake messages ──────
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

  static String _topicForId(String phantomId) => 'msg$phantomId';

  static String _encodeTopic(String topic) {
    return 'u${base64Url.encode(utf8.encode(topic)).replaceAll('=', '')}';
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
    final contactTopic = _topicForId(phantomId);

    // Fast path: the contact's IPFS peer ID is known from the contact address.
    // Use routing/findpeer to get current relay addresses and connect directly,
    // bypassing the unreliable DHT provider record walk entirely.
    final knownPeerId = _contactIpfsPeerIds[phantomId];
    if (knownPeerId != null) {
      dbg.log('IPFS: direct connect via stored peer ID $knownPeerId');
      final preExisting = await _verifySwarmConnection(knownPeerId);
      if (preExisting) {
        // Peer is in swarm — check if gossipsub works on this connection.
        final hasMesh = await _checkTopicPeers(contactTopic, dbg);
        if (hasMesh) {
          _swarmConnected.add(knownPeerId);
          dbg.log('IPFS: $knownPeerId in swarm + gossipsub OK — ready');
          return true;
        }
        // Stale or relay connection that doesn't support gossipsub.
        // Disconnect and reconnect with fresh addresses to force
        // libp2p protocol renegotiation.
        dbg.log('IPFS: $knownPeerId in swarm but gossipsub=0 — forcing reconnect');
        try {
          await _client.post(Uri.parse(
              '$_apiUrl/api/v0/swarm/disconnect?arg=/p2p/$knownPeerId'))
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
        await Future.delayed(const Duration(seconds: 1));
      }
      // Fetch current relay addresses via findpeer, then connect.
      final addrs = await _fetchPeerAddrs(knownPeerId, dbg);
      final connected = await _connectById(knownPeerId, addrs, dbg);
      if (connected) {
        _swarmConnected.add(knownPeerId);
        dbg.log('IPFS: connected to known peer $knownPeerId — ready');
        return true;
      }
      dbg.log('IPFS: stored peer ID connect failed, falling back to findprovs');
    }

    try {
      final cid = await _phantomCid(phantomId);
      final uri = Uri.parse(
          '$_apiUrl/api/v0/routing/findprovs?arg=${Uri.encodeComponent(cid)}&num-providers=20');
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
          final type = json['Type'];
          if (type != null && type != 4) continue;

          final responses = json['Responses'];
          if (responses is! List) continue;
          for (final peer in responses.cast<Map<String, dynamic>>()) {
            final peerId = peer['ID'] as String?;
            final addrs  = (peer['Addrs'] as List?)?.cast<String>() ?? [];
            if (peerId == null || peerId.isEmpty) continue;

            dbg.log('IPFS: DHT provider $peerId — connecting');

            final preExisting = await _verifySwarmConnection(peerId);
            if (preExisting) {
              // Peer is in swarm — check if they're also on the gossipsub mesh.
              // Relay connections can take 10-30s for gossipsub to form, so
              // don't skip immediately. Poll for up to 10s.
              bool isRealContact = await _checkTopicPeers(contactTopic, dbg);
              if (!isRealContact) {
                dbg.log('IPFS: $peerId in swarm, waiting for gossipsub mesh…');
                for (int i = 0; i < 5; i++) {
                  await Future.delayed(const Duration(seconds: 2));
                  isRealContact = await _checkTopicPeers(contactTopic, dbg);
                  if (isRealContact) break;
                }
              }
              if (isRealContact) {
                dbg.log('IPFS: $peerId confirmed as contact via gossipsub');
                _swarmConnected.add(peerId);
                return true;
              }
              dbg.log('IPFS: $peerId in swarm but no gossipsub after 10s — continuing search');
              continue;
            }

            // Fresh peer — connect, then verify via gossipsub.
            final connected = await _connectById(peerId, addrs, dbg);
            if (connected) {
              _swarmConnected.add(peerId);
              // Poll pubsub/peers for up to 12s for relay connections.
              bool foundContact = false;
              for (int i = 0; i < 6; i++) {
                await Future.delayed(const Duration(seconds: 2));
                if (await _checkTopicPeers(contactTopic, dbg)) {
                  dbg.log('IPFS: $peerId confirmed as contact via gossipsub');
                  foundContact = true;
                  break;
                }
              }
              if (foundContact) return true;
              _swarmConnected.remove(peerId);
              dbg.log('IPFS: $peerId — no gossipsub after 12s, likely false provider. Skipping.');
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      dbg.log('IPFS: DHT discover error: $e');
    }
    return false;
  }

  /// Fetches current multiaddrs for [peerId] via routing/findpeer.
  /// Returns an empty list on failure. Prioritises relay addresses.
  Future<List<String>> _fetchPeerAddrs(String peerId, TransportDebugger dbg) async {
    try {
      final r = await _client
          .post(Uri.parse(
              '$_apiUrl/api/v0/routing/findpeer?arg=${Uri.encodeComponent(peerId)}'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final addrs = (jsonDecode(r.body)['Addrs'] as List?)?.cast<String>() ?? [];
        dbg.log('IPFS: findpeer got ${addrs.length} addrs for ${peerId.substring(0, 12)}…');
        return addrs;
      }
    } catch (_) {}
    return [];
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

    // Dial all addresses in parallel and AWAIT results so we know when to
    // start verifying. Previous fire-and-forget caused verification to
    // race ahead of the actual connection attempts.
    await Future.wait(targets.map((addr) async {
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
    }));

    // Verify true connection by polling swarm/peers for up to 10 seconds.
    for (int i = 0; i < 5; i++) {
      if (_disposed) return false;
      if (i > 0) await Future.delayed(const Duration(seconds: 2));
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

  /// Opens a subscription to [topic] so GossipSub announces us as a peer on
  /// that topic. Idempotent — subsequent calls for the same topic are no-ops.
  /// The subscription is kept open until [dispose] cancels it.
  Future<void> _ensureCrossSubscribed(String topic, TransportDebugger dbg) async {
    if (_crossSubs.containsKey(topic)) return;

    final uri = Uri.parse(
        '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
    try {
      final request  = http.Request('POST', uri);
      final response = await _client.send(request)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        // Hold the StreamSubscription so dispose() can cancel it, which closes
        // the HTTP connection and drops the IPFS pubsub subscription cleanly.
        final sub = response.stream.listen(null, onError: (_) {}, cancelOnError: false);
        _crossSubs[topic] = sub;
        dbg.log('IPFS: cross-sub active for ${topic.split('/').last.substring(0, 8)}');
      } else {
        dbg.log('IPFS: cross-sub HTTP ${response.statusCode}');
      }
    } catch (e) {
      dbg.log('IPFS: cross-sub error: $e');
    }
  }

  /// Single-shot check for gossipsub peers on [topic]. Does not spin — the
  /// caller publishes regardless of the result.
  Future<bool> _checkTopicPeers(String topic, TransportDebugger dbg) async {
    try {
      final r = await _client.post(Uri.parse(
          '$_apiUrl/api/v0/pubsub/peers?arg=${Uri.encodeComponent(_encodeTopic(topic))}'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        final strings = (jsonDecode(r.body)['Strings'] as List?) ?? [];
        dbg.log('IPFS: gossipsub peers on topic: ${strings.length}');
        return strings.isNotEmpty;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final sub in _crossSubs.values) {
      sub.cancel();
    }
    _crossSubs.clear();
    _client.close();
  }
}

/// Transport over I2P via SAM Bridge (Simple Anonymous Messaging).
///
/// Default for handshakes. Creates a persistent I2P destination.
class I2PTransport implements PhantomTransport {
  String host;
  final int samPort;
  String? _myDest;
  bool _disposed = false;

  @override
  final String name = 'i2p-sam';

  @override
  bool get isAvailable => true;

  I2PTransport({this.host = '127.0.0.1', this.samPort = 7656});

  String? get myDestination => _myDest;

  @override
  Future<bool> checkAvailability() async {
    final dbg = TransportDebugger.instance;
    final hostsToTry = [
      host,
      if (Platform.isAndroid && host == '127.0.0.1') ...[
        '10.0.2.2',      // Emulator host
        '192.168.240.1', // Waydroid host
        '172.17.0.1',    // Docker/Waydroid alternative
        '172.33.0.1',    // Your current Waydroid gateway
        '192.168.1.1',
        '192.168.0.1',
      ],
    ];

    for (final h in hostsToTry) {
      try {
        dbg.log('I2P: checking SAM bridge at $h:$samPort...');
        final s = await Socket.connect(h, samPort, timeout: const Duration(milliseconds: 800));
        await s.close();
        host = h; 
        dbg.log('I2P: SAM bridge found at $h');
        return true;
      } catch (_) {}
    }
    dbg.log('I2P: no SAM bridge reachable');
    return false;
  }

  /// Sends raw data to a specific I2P destination using DATAGRAM.
  Future<void> publishToDest({required String dest, required Uint8List data}) async {
    final dbg = TransportDebugger.instance;
    try {
      dbg.log('I2P: sending datagram to ${dest.substring(0, 12)}...');
      final s = await Socket.connect(host, samPort);
      s.add(utf8.encode('HELLO VERSION MIN=3.3 MAX=3.3\n'));
      s.add(utf8.encode('SESSION CREATE STYLE=DATAGRAM ID=phsend DESTINATION=TRANSIENT\n'));
      s.add(utf8.encode('DATAGRAM SEND DESTINATION=$dest\n'));
      s.add(data);
      await s.flush();
      await s.close();
      dbg.log('I2P: datagram sent');
    } catch (e) {
      dbg.log('I2P: send error: $e');
    }
  }

  @override
  Future<void> publish({required String recipientId, required Uint8List encryptedEnvelope}) async {
    // Fallback if no specific destination is known (requires I2P naming or DHT)
    throw const TransportException('I2P requires a specific destination for handshakes');
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    final dbg = TransportDebugger.instance;
    while (!_disposed) {
      try {
        final dbg = TransportDebugger.instance;
        dbg.log('I2P: connecting to SAM bridge at $host:$samPort...');
        final s = await Socket.connect(host, samPort, timeout: const Duration(seconds: 5));
        s.add(utf8.encode('HELLO VERSION MIN=3.3 MAX=3.3\n'));
        s.add(utf8.encode('SESSION CREATE STYLE=DATAGRAM ID=phantom DESTINATION=TRANSIENT\n'));
        s.add(utf8.encode('NAMING LOOKUP NAME=ME\n'));
        
        dbg.log('I2P: session created, waiting for destination...');
        await for (final data in s) {
          if (_disposed) break;
          
          // Check for SAM control messages (ASCII)
          try {
            final str = utf8.decode(data);
            if (str.contains('NAMING REPLY RESULT=OK NAME=ME VALUE=')) {
              _myDest = str.split('VALUE=').last.trim();
              continue;
            }
            
            // Handle DATAGRAM RECEIVED headers
            if (str.startsWith('DATAGRAM RECEIVED')) {
              // The message data usually follows after the first newline in the same packet
              // or the next one. SAM Datagrams are: "DATAGRAM RECEIVED DEST=... SIZE=...\n<data>"
              final nlIdx = data.indexOf(10); // index of '\n'
              if (nlIdx != -1 && nlIdx < data.length - 1) {
                yield IncomingEnvelope(
                  data: Uint8List.fromList(data.sublist(nlIdx + 1)),
                  transportName: name,
                  receivedAt: DateTime.now(),
                );
              }
              continue;
            }
          } catch (_) {
            // Binary data or malformed UTF8 - yield as is (fallback)
          }
          
          yield IncomingEnvelope(
            data: Uint8List.fromList(data),
            transportName: name,
            receivedAt: DateTime.now(),
          );
        }
      } catch (e) {
        dbg.log('I2P: connection error $e, retrying...');
        await Future.delayed(const Duration(seconds: 10));
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}

/// Transport over the Yggdrasil network (encrypted IPv6 mesh).
///
/// Uses direct TCP/IPv6 with length-prefixed framing:
///   [4-byte big-endian length][payload]
class YggdrasilTransport implements PhantomTransport {
  static const int listenPort = 7331;
  static const int _maxPayloadBytes = 1024 * 1024; // 1 MB safety cap
  ServerSocket? _server;
  bool _disposed = false;

  @override
  final String name = 'yggdrasil-tcp';

  @override
  bool get isAvailable => true;

  String? _address;

  String? get address => _address;

  void setManualAddress(String ip) => _address = ip.isEmpty ? null : ip;

  YggdrasilTransport({String? address}) : _address = address;

  @override
  Future<bool> checkAvailability() async {
    // 1. Auto-detect Yggdrasil IP if not provided
    if (_address == null) {
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv6);
        for (final interface in interfaces) {
          for (final addr in interface.addresses) {
            final bytes = addr.rawAddress;
            // Yggdrasil uses the 0200::/7 subnet.
            // This means the first byte must be exactly 0x02 or 0x03.
            if (bytes.length == 16 && (bytes[0] == 0x02 || bytes[0] == 0x03)) {
              _address = addr.address;
              TransportDebugger.instance.log('Yggdrasil: auto-detected IP $_address on ${interface.name}');
              break;
            }
          }
          if (_address != null) break;
        }
      } catch (e) {
        TransportDebugger.instance.log('Yggdrasil: interface scan failed - $e');
      }

      // Fallback: Aggressive OS-level routing table scan (bypasses Android VPN hiding)
      if (_address == null && (Platform.isAndroid || Platform.isLinux)) {
        try {
          final res = await Process.run('ip', ['-6', 'addr']);
          if (res.exitCode == 0) {
            // Strict match for Yggdrasil 0200::/7 — first byte must be 0x02 or 0x03.
            // In IPv6 text, that's 02xx: or 03xx: (with optional leading-zero omission).
            // We require the full 4-char first group to avoid matching 2001:, 2a02:, etc.
            final regex = RegExp(r'inet6\s+(0[23][0-9a-fA-F]{2}:[0-9a-fA-F:]+)/\d+');
            final match = regex.firstMatch(res.stdout.toString());
            if (match != null && match.groupCount >= 1) {
              _address = match.group(1)!;
              TransportDebugger.instance.log('Yggdrasil: auto-detected IP $_address via native scan');
            }
          }
        } catch (_) {}
      }
    }

    // 2. Check if we can bind to an IPv6 address
    try {
      final s = await ServerSocket.bind(InternetAddress.anyIPv6, 0);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends [data] to [address] with a 4-byte big-endian length prefix.
  /// The receiver reads exactly [length] bytes then closes — no ambiguity.
  Future<void> publishToAddr({required String address, required Uint8List data}) async {
    final dbg = TransportDebugger.instance;
    dbg.log('Yggdrasil: connecting to $address:$listenPort (${data.length} bytes)');
    
    Socket? s;
    try {
      s = await Socket.connect(address, listenPort, timeout: const Duration(seconds: 5));
      // Write 4-byte big-endian length header
      final header = ByteData(4)..setUint32(0, data.length, Endian.big);
      s.add(header.buffer.asUint8List());
      s.add(data);
      await s.flush();
      dbg.log('Yggdrasil: sent ${data.length} bytes to $address');
    } catch (e) {
      dbg.log('Yggdrasil: send failed to $address — $e');
      rethrow;
    } finally {
      try { await s?.close(); } catch (_) {}
    }
  }

  @override
  Future<void> publish({required String recipientId, required Uint8List encryptedEnvelope}) async {
    throw const TransportException('Yggdrasil requires a direct IPv6 address');
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) {
    final dbg = TransportDebugger.instance;
    final controller = StreamController<IncomingEnvelope>();

    () async {
      // Retry bind up to 3 times with delay if the port is busy (e.g. quick restart)
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          _server = await ServerSocket.bind(InternetAddress.anyIPv6, listenPort);
          dbg.log('Yggdrasil: listening on port $listenPort');
          break;
        } catch (e) {
          if (attempt == 3) {
            dbg.log('Yggdrasil: ✗ failed to bind port $listenPort after 3 attempts: $e');
            await controller.close();
            return;
          }
          dbg.log('Yggdrasil: port $listenPort busy, retrying in ${attempt * 2}s (attempt $attempt/3)');
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }

      if (_server == null) {
        await controller.close();
        return;
      }

      await for (final client in _server!) {
        if (_disposed) break;
        // Handle each connection concurrently so a stalled peer doesn't
        // block the server from accepting other connections.
        unawaited(_handleClient(client, dbg).then((envelope) {
          if (envelope != null && !controller.isClosed) {
            controller.add(envelope);
          }
        }).catchError((_) {}));
      }
      await controller.close();
    }();

    return controller.stream;
  }

  /// Read a single length-prefixed message from [client] with a timeout.
  /// Returns null if the read fails or times out.
  Future<IncomingEnvelope?> _handleClient(Socket client, TransportDebugger dbg) async {
    try {
      final data = await _readLengthPrefixed(client)
          .timeout(const Duration(seconds: 30));
      if (data == null || data.isEmpty) return null;
      dbg.log('Yggdrasil: received ${data.length} bytes from ${client.remoteAddress.address}');
      return IncomingEnvelope(
        data: data,
        transportName: name,
        receivedAt: DateTime.now(),
      );
    } catch (e) {
      dbg.log('Yggdrasil: client read error: $e');
      return null;
    } finally {
      try { client.close(); } catch (_) {}
    }
  }

  /// Reads a 4-byte big-endian length header, then exactly that many payload bytes.
  /// Falls back to reading all-until-close for backward compatibility with
  /// senders that don't send a length prefix (pre-fix versions).
  Future<Uint8List?> _readLengthPrefixed(Socket socket) async {
    final allBytes = <int>[];
    await for (final chunk in socket) {
      allBytes.addAll(chunk);
      // Once we have at least the 4-byte header, check payload size
      if (allBytes.length >= 4) {
        final view = ByteData.sublistView(Uint8List.fromList(allBytes.sublist(0, 4)));
        final payloadLen = view.getUint32(0, Endian.big);
        // Sanity check: reject absurdly large payloads
        if (payloadLen > _maxPayloadBytes) {
          return null; // Malformed or attack
        }
        if (allBytes.length >= 4 + payloadLen) {
          return Uint8List.fromList(allBytes.sublist(4, 4 + payloadLen));
        }
      }
    }
    // Socket closed before we got the full payload.
    // Backward compatibility: if there's no valid length prefix,
    // treat the entire buffer as the payload (old-style framing).
    if (allBytes.length > 4) {
      final view = ByteData.sublistView(Uint8List.fromList(allBytes.sublist(0, 4)));
      final maybeLen = view.getUint32(0, Endian.big);
      if (maybeLen == allBytes.length - 4) {
        return Uint8List.fromList(allBytes.sublist(4));
      }
    }
    // Old-style: no length prefix, entire buffer is the message
    return allBytes.isNotEmpty ? Uint8List.fromList(allBytes) : null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _server?.close();
  }
}

class TransportException implements Exception {
  final String message;
  const TransportException(this.message);
  @override
  String toString() => 'TransportException: $message';
}



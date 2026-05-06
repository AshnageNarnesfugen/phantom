import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Lightweight presence layer using the bundled IPFS daemon as a pubsub bus.
///
/// Peer discovery bootstrap (solves gossipsub cold-start):
///   1. On startup each node advertises itself on the IPFS DHT using a CID
///      derived from its own Phantom ID (DHT provider record).
///   2. For each contact, it queries `routing/findprovs` for that CID to
///      learn the contact's IPFS peer ID, then calls `swarm/connect`.
///   3. After a direct swarm connection exists, gossipsub subscription
///      announcements propagate instantly — pubsub works immediately.
///   4. Additionally, when any pubsub message arrives the `from` field gives
///      the sender's peer ID; we swarm/connect there too (covers the case
///      where DHT lookup succeeded from the other side but not ours).
class PresenceService {
  static const _defaultApiUrl        = 'http://127.0.0.1:5001';
  static const _interval             = Duration(minutes: 2);
  static const _threshold            = Duration(minutes: 7);
  static const _dhtAdvertiseInterval = Duration(minutes: 20);
  static const _dhtDiscoverInterval  = Duration(minutes: 2);

  final String _myId;
  final String _apiUrl;
  final http.Client _client = http.Client();

  final Map<String, DateTime> _lastSeen    = {};
  final Set<String>           _subscribed  = {};
  final _changesCtrl = StreamController<String>.broadcast();

  // Peer IDs we attempted swarm/connect to recently.
  final Map<String, DateTime> _connectAttempts = {};
  static const _reconnectCooldown = Duration(minutes: 5);

  Timer? _heartbeatTimer;
  Timer? _dhtAdvertiseTimer;
  Timer? _dhtDiscoverTimer;
  bool _disposed = false;

  /// Always false — IPFS presence has no rate limits.
  bool get isRateLimited => false;

  /// Emits a contactId whenever that contact's online status changes.
  Stream<String> get changes => _changesCtrl.stream;

  PresenceService(this._myId, {String? ipfsApiUrl})
      : _apiUrl = ipfsApiUrl ?? _defaultApiUrl;

  Future<void> start(List<String> contactIds) async {
    _subscribeAll(contactIds);
    // Immediate + burst heartbeats so a contact coming online after us gets
    // a heartbeat quickly rather than waiting for the full periodic interval.
    await _publishHeartbeat();
    Timer(const Duration(seconds: 10), _publishHeartbeat);
    Timer(const Duration(seconds: 30), _publishHeartbeat);
    Timer(const Duration(seconds: 90), _publishHeartbeat);
    _heartbeatTimer = Timer.periodic(_interval, (_) => _publishHeartbeat());

    // DHT rendezvous bootstrap — runs independently of pubsub.
    unawaited(_advertiseOnDht());
    // AutoRelay takes 30-60s to reserve a public relay. If we only advertise at
    // t=0, the DHT will only ever learn our (likely un-dialable) public IP.
    // Burst advertise during startup so the DHT gets our p2p-circuit address.
    Timer(const Duration(seconds: 15), _advertiseOnDht);
    Timer(const Duration(seconds: 45), _advertiseOnDht);
    Timer(const Duration(seconds: 120), _advertiseOnDht);
    
    // Small delay so the daemon is fully up before we query.
    Timer(const Duration(seconds: 5), () => _discoverAll(contactIds));
    _dhtAdvertiseTimer = Timer.periodic(
        _dhtAdvertiseInterval, (_) => _advertiseOnDht());
    _dhtDiscoverTimer = Timer.periodic(
        _dhtDiscoverInterval, (_) => _discoverAll(_subscribed.toList()));
  }

  void addContacts(List<String> contactIds) {
    _subscribeAll(contactIds);
    unawaited(_discoverAll(contactIds));
  }

  bool isOnline(String contactId) {
    final last = _lastSeen[contactId];
    return last != null && DateTime.now().difference(last) < _threshold;
  }

  Future<void> goOffline()     => _publishHeartbeat(online: false);
  Future<void> publishOnline() => _publishHeartbeat(online: true);

  // ── Internal ────────────────────────────────────────────────────────────────

  void _subscribeAll(List<String> ids) {
    for (final id in ids) {
      if (!_subscribed.contains(id)) {
        _subscribed.add(id);
        _streamContact(id);
      }
    }
  }

  void _streamContact(String contactId) {
    _presenceStream(contactId).listen(
      (event) {
        final wasOnline = isOnline(contactId);
        if (event.online) {
          _lastSeen[contactId] = event.at;
          if (!wasOnline) _changesCtrl.add(contactId);
        } else {
          final hadSeen = _lastSeen.remove(contactId) != null;
          if (wasOnline || hadSeen) _changesCtrl.add(contactId);
        }
      },
      onError: (_) {},
    );
  }

  Stream<_PresenceEvent> _presenceStream(String contactId) async* {
    final topic = _topic(contactId);
    final uri = Uri.parse(
        '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');

    while (!_disposed) {
      try {
        final request  = http.Request('POST', uri);
        final response = await _client.send(request);

        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          if (!_disposed) await Future.delayed(const Duration(seconds: 15));
          continue;
        }

        await for (final line in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (_disposed) return;
          if (line.trim().isEmpty) continue;
          try {
            final ev      = jsonDecode(line) as Map<String, dynamic>;
            final rawData = ev['data'];
            if (rawData == null) continue;
            // Decode multibase payload (Kubo >= 0.11 uses prefix 'm'/'u').
            final Uint8List bytes;
            if ((rawData as String).startsWith('m')) {
              bytes = base64.decode(rawData.substring(1));
            } else if (rawData.startsWith('u')) {
              bytes = base64Url.decode(
                  base64Url.normalize(rawData.substring(1)));
            } else {
              bytes = base64.decode(rawData);
            }
            final body = utf8.decode(bytes).trim();

            // The 'from' field carries the sender's IPFS peer ID (multibase).
            // Connect to them directly to reinforce the gossipsub mesh.
            final rawFrom = ev['from'] as String?;
            if (rawFrom != null) unawaited(_connectFromField(rawFrom));

            yield _PresenceEvent(at: DateTime.now(), online: body != '0');
          } catch (_) {}
        }
        if (!_disposed) await Future.delayed(const Duration(seconds: 5));
      } catch (_) {
        if (!_disposed) await Future.delayed(const Duration(seconds: 15));
      }
    }
  }

  // ── DHT rendezvous ───────────────────────────────────────────────────────────

  /// Advertises this node on the IPFS DHT so contacts can discover our peer ID.
  /// Each Phantom node "provides" a CID derived from its Phantom ID; contacts
  /// query that CID with `routing/findprovs` to get our IPFS peer ID + addrs.
  Future<void> _advertiseOnDht() async {
    if (_disposed) return;
    try {
      final cid = await _phantomCid(_myId);
      // First put a small block so Kubo has the CID in its store — some
      // versions of Kubo reject routing/provide for unknown CIDs.
      final putUri = Uri.parse('$_apiUrl/api/v0/block/put?format=raw&mhtype=sha2-256');
      final request = http.MultipartRequest('POST', putUri);
      request.files.add(http.MultipartFile.fromBytes('data', utf8.encode('phantom-peer-v1:$_myId')));
      final streamedResp = await _client.send(request).timeout(const Duration(seconds: 10));
      final resp = await http.Response.fromStream(streamedResp);
      if (resp.statusCode != 200) {
        debugPrint('[Presence] DHT block/put failed: ${resp.statusCode} ${resp.body}');
      }

      final provideUri = Uri.parse(
          '$_apiUrl/api/v0/routing/provide?arg=${Uri.encodeComponent(cid)}&recursive=false');
      final r = await _client.post(provideUri)
          .timeout(const Duration(seconds: 30));
      debugPrint('[Presence] DHT advertise → HTTP ${r.statusCode}');
    } catch (e) {
      debugPrint('[Presence] DHT advertise error: $e');
    }
  }

  /// Queries the DHT for each contact's IPFS peer info and connects to them.
  Future<void> _discoverAll(List<String> contactIds) async {
    for (final id in contactIds) {
      if (_disposed) return;
      await _discoverAndConnect(id);
    }
  }

  /// Finds a contact's IPFS node via DHT provider records and swarm/connect.
  Future<void> _discoverAndConnect(String contactId) async {
    if (_disposed) return;
    try {
      final cid = await _phantomCid(contactId);
      final uri = Uri.parse(
          '$_apiUrl/api/v0/routing/findprovs?arg=${Uri.encodeComponent(cid)}&num-providers=5');

      // findprovs streams NDJSON — use a streaming request so we process
      // results as they arrive rather than waiting for the full response.
      final request  = http.Request('POST', uri);
      final response = await _client.send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        return;
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (_disposed) return;
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          // Only process Type 4 — actual provider records.
          // Other types (1=PeerResponse, 2=FinalPeer, etc.) are intermediate
          // DHT routing nodes; connecting to them wastes time and causes spam.
          final type = json['Type'];
          if (type != null && type != 4) continue;

          final responses = json['Responses'];
          if (responses is! List) continue;
          for (final peer in responses.cast<Map<String, dynamic>>()) {
            final peerId = peer['ID'] as String?;
            final addrs  = (peer['Addrs'] as List?)?.cast<String>() ?? [];
            if (peerId == null || peerId.isEmpty || addrs.isEmpty) continue;
            await _connectToPeer(peerId, addrs);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Decodes the multibase `from` field of a pubsub message and connects.
  Future<void> _connectFromField(String rawFrom) async {
    String peerId;
    try {
      if (rawFrom.startsWith('u')) {
        final b64 = rawFrom.substring(1).padRight(
            (rawFrom.length - 1 + 3) & ~3, '=');
        peerId = utf8.decode(base64Url.decode(b64));
      } else if (rawFrom.startsWith('m')) {
        peerId = utf8.decode(base64.decode(rawFrom.substring(1)));
      } else {
        peerId = rawFrom;
      }
    } catch (_) {
      return;
    }
    await _connectToPeer(peerId, []);
  }

  /// Establishes a direct swarm connection to [peerId].
  ///
  /// If [addrs] is empty (e.g., from the `from` field path), we first call
  /// `routing/findpeer` to obtain multiaddrs. As a last resort we try
  /// `/p2p/<peerId>` which IPFS resolves via its routing table.
  Future<void> _connectToPeer(String peerId, List<String> addrs) async {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _connectAttempts[peerId];
    if (last != null && now.difference(last) < _reconnectCooldown) return;
    _connectAttempts[peerId] = now;

    var addresses = addrs;
    if (addresses.isEmpty) {
      try {
        final findUri = Uri.parse(
            '$_apiUrl/api/v0/routing/findpeer?arg=${Uri.encodeComponent(peerId)}');
        final r = await _client.post(findUri)
            .timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          addresses = (j['Addrs'] as List?)?.cast<String>() ?? [];
        }
      } catch (_) {}
    }

    // Drop loopback/link-local — can't reach a remote peer via 127.0.0.1
    // and connecting to our own daemon returns HTTP 500.
    addresses = addresses.where((a) =>
        !a.contains('/127.0.0.1/') &&
        !a.contains('/::1/') &&
        !a.contains('/169.254.') &&
        !a.contains('/fe80:')).toList();

    // Sort: relay addresses first, then local IPs, then others.
    final sorted = [...addresses]..sort((a, b) {
        final aR = a.contains('p2p-circuit') ? 0 : 1;
        final bR = b.contains('p2p-circuit') ? 0 : 1;
        if (aR != bR) return aR.compareTo(bR);
        final aL = (a.contains('/192.168.') || a.contains('/10.') || a.contains('/172.')) ? 0 : 1;
        final bL = (b.contains('/192.168.') || b.contains('/10.') || b.contains('/172.')) ? 0 : 1;
        return aL.compareTo(bL);
      });

    // Try explicit addresses, then fall back to /p2p/<id> (DHT resolution).
    final targets = [
      ...sorted.take(8).map((a) => '$a/p2p/$peerId'),
      '/p2p/$peerId',
    ];

    unawaited(Future.wait(targets.map((addr) async {
      if (_disposed) return;
      try {
        await _client
            .post(Uri.parse(
                '$_apiUrl/api/v0/swarm/connect?arg=${Uri.encodeComponent(addr)}'))
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
    })));

    for (int i = 0; i < 5; i++) {
      if (_disposed) return;
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
            // Pre-warm GossipSub mesh: cross-subscribe to every contact's
            // message topic so publish() finds peers immediately.
            unawaited(_crossSubscribeContactTopics());
            return;
          }
        }
      } catch (_) {}
    }
  }

  /// Cross-subscribes to the message topic of all known contacts.
  /// This makes our GossipSub announce us as a peer on those topics,
  /// which is required for pubsub to deliver messages.
  /// The subscriptions are fire-and-forget; the HTTP streams are drained
  /// in the background and keep alive until the daemon or client closes.
  final Set<String> _crossSubbed = {};

  Future<void> _crossSubscribeContactTopics() async {
    for (final contactId in _subscribed) {
      if (_disposed) return;
      final msgTopic = '/phantom/v1/$contactId';
      if (_crossSubbed.contains(msgTopic)) continue;
      _crossSubbed.add(msgTopic);
      try {
        final uri = Uri.parse(
          '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(_encodeTopic(msgTopic))}');
        final request = http.Request('POST', uri);
        final response = await _client.send(request)
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          unawaited(response.stream.drain<void>().catchError((_) {}));
          debugPrint('[Presence] cross-sub active for msg topic ${contactId.substring(0, 8)}');
        }
      } catch (_) {}
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Future<void> _publishHeartbeat({bool online = true}) async {
    if (_disposed) return;
    try {
      final topic = _topic(_myId);
      final uri = Uri.parse(
          '$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
      final request = http.MultipartRequest('POST', uri);
      request.files.add(http.MultipartFile.fromBytes('data', utf8.encode(online ? '1' : '0')));
      await _client.send(request).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Computes a deterministic CIDv1 (raw codec, sha2-256) from a Phantom ID.
  /// Used as the rendezvous key on the IPFS DHT.
  ///
  /// Format: multibase hex ('f' prefix) of [version=1, codec=0x55(raw),
  ///   multihash=[0x12(sha2-256), 0x20(32 bytes), sha256("phantom-peer-v1:<id>")]]
  static Future<String> _phantomCid(String phantomId) async {
    final sha256   = Sha256();
    final hash     = await sha256.hash(utf8.encode('phantom-peer-v1:$phantomId'));
    final hashBytes = Uint8List.fromList(hash.bytes);

    final cidBytes = Uint8List(36);
    cidBytes[0] = 0x01; // CIDv1
    cidBytes[1] = 0x55; // raw codec
    cidBytes[2] = 0x12; // sha2-256 multihash code
    cidBytes[3] = 0x20; // 32-byte hash length
    cidBytes.setRange(4, 36, hashBytes);

    // Multibase hex encoding: 'f' prefix + lowercase hex.
    // Kubo accepts any valid multibase-encoded CID string.
    final hex = cidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'f$hex';
  }

  static String _topic(String phantomId) => '/phantom/prs/v1/$phantomId';

  /// Kubo >= 0.11 requires pubsub topic args to be multibase-encoded.
  static String _encodeTopic(String topic) {
    final bytes = utf8.encode(topic);
    return 'u${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  void dispose() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _dhtAdvertiseTimer?.cancel();
    _dhtDiscoverTimer?.cancel();
    _changesCtrl.close();
    _client.close();
  }
}

class _PresenceEvent {
  final DateTime at;
  final bool online;
  const _PresenceEvent({required this.at, required this.online});
}

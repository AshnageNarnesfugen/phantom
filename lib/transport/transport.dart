import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../core/transport_debugger.dart';
import '../core/waku_daemon.dart';

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

/// Classification used by [TransportManager.publish] to choose which backend
/// gets the first attempt. See the doc on `publish` for the policy.
enum TransportPriority {
  /// X3DH INIT, preKeyShare, connectivityInfo — session-establishment frames
  /// where I2P is the preferred backend for sender anonymity. Falls back to
  /// IPFS+Yggdrasil if I2P is unavailable or the contact has no I2P dest.
  control,
  /// Regular text / file payloads. Sent over IPFS (+ Yggdrasil) only.
  data,
  /// Fan-out send: fire on every available backend in parallel. Used for
  /// handshakeAck where we don't yet know if the peer's record of our
  /// addresses is fresh — sending to all of them maximises the chance that
  /// at least one channel actually delivers.
  broadcast,
}

@immutable
class IncomingEnvelope {
  final Uint8List data;
  final String transportName;
  final DateTime receivedAt;
  /// I2P source destination from the SAM v3 forwarded datagram header.
  /// Only populated for envelopes received over I2P — null for other
  /// transports. Lets the upper layer discover a contact's I2P dest the
  /// first time they reach us, fixing the asymmetry where one side knew
  /// the other's dest via QR but the reverse direction never learned it
  /// (forcing all replies through the unreliable IPFS gossipsub path).
  final String? i2pSourceDestination;

  const IncomingEnvelope({
    required this.data,
    required this.transportName,
    required this.receivedAt,
    this.i2pSourceDestination,
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
    Future<String?> Function()? i2pLoadKey,
    Future<void> Function(String)? i2pPersistKey,
    Future<int?> Function()? wakuLoadLastStoreUs,
    Future<void> Function(int)? wakuSaveLastStoreUs,
    /// Replaces the default Waku/Ygg/I2P/IPFS stack entirely. Used by the
    /// local lab / e2e tests to wire an in-memory loopback transport so the
    /// full handshake + messaging flow runs without any daemon or network.
    List<PhantomTransport>? transportsOverride,
  }) : _transports = transportsOverride ?? [
          // Waku: primary messaging transport (text, handshakes, metadata)
          WakuTransport(
            loadLastStoreQueryUs: wakuLoadLastStoreUs,
            saveLastStoreQueryUs: wakuSaveLastStoreUs,
          ),
          YggdrasilTransport(address: yggdrasilAddress),
          I2PTransport(
            host:        i2pSamHost ?? '127.0.0.1',
            samPort:     i2pSamPort ?? 7656,
            loadKey:     i2pLoadKey,
            persistKey:  i2pPersistKey,
          ),
          // IPFS: now relegated to file transfer only (on-demand)
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
  /// Throttled to once per 3 s so a burst of publish() calls right after
  /// app start doesn't all skip the retry — but also doesn't hammer the
  /// daemon either.
  bool _lateRetryInProgress = false;

  Future<void> _activateLateTransports() async {
    if (_ourId.isEmpty || _lateRetryInProgress) return;
    final now = DateTime.now();
    if (_lastRetryAt != null &&
        now.difference(_lastRetryAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastRetryAt = now;
    _lateRetryInProgress = true;

    try {
      for (final t in _transports) {
        if (_activeTransports.contains(t)) { continue; }
        try {
          if (await t.checkAvailability()) {
            _activeTransports.add(t);
            t.subscribe(ourId: _ourId).listen(
              _incomingController.add,
              onError: (_) {},
            );
            TransportDebugger.instance
                .log('TRANSPORT: ${t.name} activated late');
          }
        } catch (_) {}
      }
    } finally {
      _lateRetryInProgress = false;
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

  /// Routes a payload over the network. Behaviour depends on [priority]:
  ///
  ///   * `TransportPriority.control` — used for session-establishment frames
  ///     (X3DH INIT, preKeyShare, connectivityInfo). I2P is the preferred
  ///     backend; we try it first because it gives stronger sender anonymity
  ///     for the key-exchange flow. On failure (or when we don't know the
  ///     contact's I2P destination, or when no SAM bridge is up) we fall
  ///     back to IPFS / Yggdrasil in parallel.
  ///
  ///   * `TransportPriority.data` — used for regular text/file payloads.
  ///     Skips I2P entirely and publishes via IPFS (+ Yggdrasil when an
  ///     address is known) in parallel. Faster, higher bandwidth.
  ///
  ///   * `TransportPriority.broadcast` — used for handshakeAck. Fans out to
  ///     every backend (I2P + IPFS + Yggdrasil) simultaneously without
  ///     fallback semantics. The receiver's record of our addresses can be
  ///     stale (peer reinstalls) so we hedge by sending everywhere; whichever
  ///     channel still works lands the ack.
  ///
  /// Throws [TransportException] only when *every* attempt fails — the caller
  /// then falls back to BLE mesh / persistent store.
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
    bool isHandshake = false,
    TransportPriority priority = TransportPriority.data,
  }) async {
    // Re-probe inactive transports on every publish (throttled to 1/3s).
    // Yggdrasil's availability check passes on virtually every device, so the
    // old `only when nothing is active` gate meant a daemon that finished
    // booting AFTER initialize() (Waku/I2P/IPFS routinely take longer than
    // app startup) was never activated for the rest of the session.
    if (_activeTransports.isEmpty) {
      await _activateLateTransports();
    } else {
      unawaited(_activateLateTransports());
    }
    if (_activeTransports.isEmpty) {
      throw const TransportException('No transport available.');
    }

    final dbg = TransportDebugger.instance;

    // NOTE: control frames used to short-circuit after a single I2P datagram
    // send. That "success" only means the local SAM bridge accepted the UDP
    // packet — I2P datagrams are fire-and-forget with zero delivery feedback,
    // so a handshake INIT could ride one unreliable path and silently vanish
    // (observed in the field: 12 control frames "delivered via I2P", peer
    // never saw any of them). Control now fans out to every backend like
    // broadcast; the receiver dedupes, so redundancy is free reliability.

    final futures = <Future<void>>[];

    // ── Waku: preferred for text messages and handshakes ──────────────────
    final waku = _activeTransports.whereType<WakuTransport>().firstOrNull;
    bool wakuHasPeers = false;
    if (waku != null && waku.isAvailable) {
      // Live peer check: the daemon being up says nothing about gossip
      // reach. With --min-relay-peers-to-publish=0 a relay publish into an
      // empty mesh returns HTTP 200 and goes nowhere.
      wakuHasPeers = await waku.hasRelayPeers();
      futures.add(() async {
        dbg.log('TRANSPORT: firing Waku for ${recipientId.substring(0, 8)}… '
            '(peers=$wakuHasPeers)');
        try {
          await waku.publish(recipientId: recipientId, encryptedEnvelope: encryptedEnvelope);
          dbg.log('TRANSPORT: Waku delivery OK');
        } catch (e) {
          dbg.log('TRANSPORT: Waku failed ($e)');
          rethrow;
        }
      }());
    }

    // ── I2P: always fire when available ─────────────────────────────────────
    // GossipSub mesh formation over IPFS circuit relays is unreliable and
    // often one-directional. I2P has proven reliable in both directions,
    // so we fire it for ALL message types as an additional delivery path.
    // The receiver deduplicates by message ID, so double delivery is safe.
    final i2p = _activeTransports.whereType<I2PTransport>().firstOrNull;
    final dest = _i2pDests[recipientId];
    if (i2p != null && dest != null && i2p.isAvailable) {
      futures.add(() async {
        dbg.log('TRANSPORT: firing I2P → ${dest.substring(0, 12)}…');
        try {
          await i2p
              .publishToDest(dest: dest, data: encryptedEnvelope)
              .timeout(const Duration(seconds: 12));
          dbg.log('TRANSPORT: I2P delivery OK');
        } catch (e) {
          dbg.log('TRANSPORT: I2P failed ($e)');
          rethrow;
        }
      }());
    }

    final ygg = _activeTransports.whereType<YggdrasilTransport>().firstOrNull;
    final yggAddr = _yggAddrs[recipientId];
    if (ygg != null && yggAddr != null) {
      futures.add(() async {
        dbg.log('TRANSPORT: firing Yggdrasil to ${recipientId.substring(0, 8)}…');
        try {
          await ygg.publishToAddr(address: yggAddr, data: encryptedEnvelope);
          dbg.log('TRANSPORT: Yggdrasil delivery OK');
        } catch (e) {
          dbg.log('TRANSPORT: Yggdrasil failed ($e)');
          rethrow;
        }
      }());
    }

    // IPFS: fallback when Waku can't actually gossip (down OR zero peers),
    // and always for handshake / control / broadcast frames — session
    // establishment is too important to trust a single backend.
    final ipfsList = _activeTransports.whereType<IpfsTransport>();
    if (waku == null ||
        !waku.isAvailable ||
        !wakuHasPeers ||
        isHandshake ||
        priority == TransportPriority.control ||
        priority == TransportPriority.broadcast) {
      for (final ipfs in ipfsList) {
        if (isHandshake ||
            priority == TransportPriority.control ||
            priority == TransportPriority.broadcast) {
          ipfs.markNextPublishAsHandshake();
        }
        futures.add(() async {
          dbg.log('TRANSPORT: firing IPFS PubSub for ${recipientId.substring(0, 8)}…');
          try {
            await ipfs.publish(recipientId: recipientId, encryptedEnvelope: encryptedEnvelope);
            dbg.log('TRANSPORT: IPFS delivery OK');
          } catch (e) {
            dbg.log('TRANSPORT: IPFS failed ($e)');
            rethrow;
          }
        }());
      }
    }

    // Generic fan-out for transports outside the four built-in types (e.g.
    // the lab's LoopbackTransport). The branches above are all type-matched,
    // so without this an injected transport would never be fired.
    for (final t in _activeTransports) {
      if (t is WakuTransport || t is I2PTransport ||
          t is YggdrasilTransport || t is IpfsTransport) {
        continue;
      }
      futures.add(() async {
        dbg.log('TRANSPORT: firing ${t.name} for ${recipientId.substring(0, 8)}…');
        try {
          await t.publish(recipientId: recipientId, encryptedEnvelope: encryptedEnvelope);
          dbg.log('TRANSPORT: ${t.name} delivery OK');
        } catch (e) {
          dbg.log('TRANSPORT: ${t.name} failed ($e)');
          rethrow;
        }
      }());
    }

    if (futures.isEmpty) {
      throw const TransportException('No valid transport target for recipient.');
    }

    final results = await Future.wait(
      futures.map((f) => f.then((_) => true).catchError((_) => false)),
    );
    if (!results.any((s) => s)) {
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

  /// Bound on how many contact topics we keep cross-subscribed concurrently.
  /// Each subscription is a long-lived HTTP stream against Kubo; without a
  /// cap an active user with dozens of contacts ends up holding the daemon's
  /// pubsub goroutines hostage. When the bound is reached we evict the
  /// least-recently-touched topic.
  static const int _crossSubMax = 24;
  final List<String> _crossSubLru = [];

  /// Known IPFS peer IDs for contacts, populated from the '#<peerId>' suffix
  /// in the contact address. When set, _dhtDiscoverAndConnect skips findprovs
  /// and dials the peer directly via circuit relay.
  final Map<String, String> _contactIpfsPeerIds = {};

  /// Stores the IPFS peer ID for [contactId] so future publishes can connect
  /// directly without a DHT provider record walk.
  void setContactIpfsPeerId(String contactId, String ipfsPeerId) {
    _contactIpfsPeerIds[contactId] = ipfsPeerId;
  }

  /// Returns the stored IPFS peer ID for [contactId], or null.
  String? getContactIpfsPeerId(String contactId) =>
      _contactIpfsPeerIds[contactId];

  /// Public wrapper for [_forceResubscribe] — used by the "Revive Connection"
  /// feature to kill stale GossipSub state and force a fresh GRAFT.
  Future<void> forceResubscribePublic(String topic) async {
    final dbg = TransportDebugger.instance;
    await _forceResubscribe(topic, dbg);
  }

  // ── Retry queue ─────────────────────────────────────────────────────────
  /// Messages that were published with 0 GossipSub peers (i.e. dropped into
  /// the void). The background retry loop republishes them once the mesh forms.
  final Map<String, List<Uint8List>> _retryQueue = {};

  /// Total messages currently waiting in the IPFS retry queue across all
  /// recipients. Exposed for the transport status sheet — the UI was showing
  /// `queued messages: 0` from the BLE mesh store while IPFS quietly held a
  /// dozen messages waiting for gossipsub mesh to form.
  int get pendingRetryCount =>
      _retryQueue.values.fold<int>(0, (sum, list) => sum + list.length);
  bool _retryLoopRunning = false;

  /// Starts the background retry loop if not already running.
  void _ensureRetryLoop() {
    if (_retryLoopRunning) return;
    _retryLoopRunning = true;
    unawaited(_runRetryLoop());
  }

  /// Background loop: aggressively retries message delivery.
  ///
  /// Strategy:
  ///  - First 60s: check every 2s (fast reconnection window)
  ///  - After 60s: check every 10s (steady state)
  ///  - On each attempt: force re-subscribe → reconnect → check mesh → deliver
  ///
  /// When GossipSub peers > 0, republish all queued messages for that contact.
  Future<void> _runRetryLoop() async {
    final dbg = TransportDebugger.instance;
    int attempt = 0;
    while (!_disposed) {
      // Aggressive timing: 2s for first 30 attempts (60s), then 10s
      final delay = attempt < 30 ? 2 : 10;
      await Future.delayed(Duration(seconds: delay));
      if (_retryQueue.isEmpty) { attempt = 0; continue; }
      attempt++;

      for (final recipientId in List.of(_retryQueue.keys)) {
        final topic = _topicForId(recipientId);
        final short = recipientId.substring(0, 8);

        // Step 1: Force re-subscribe (kill stale GossipSub state, trigger fresh GRAFT)
        if (attempt % 5 == 1) {
          await _forceResubscribe(topic, dbg);
        }

        // Step 2: Check mesh first (cheap)
        bool hasPeers = await _checkTopicPeers(topic, dbg, silent: attempt % 5 != 0);
        if (hasPeers) {
          await _flushRetryQueue(recipientId, topic, dbg);
          continue;
        }

        // Step 3: Force DHT reconnect
        if (attempt % 3 == 1) {
          dbg.log('IPFS: retry #$attempt for $short — forcing reconnect');
          await _dhtDiscoverAndConnect(recipientId, dbg);
          // Re-check immediately after reconnect
          await Future.delayed(const Duration(seconds: 1));
          hasPeers = await _checkTopicPeers(topic, dbg, silent: true);
          if (hasPeers) {
            await _flushRetryQueue(recipientId, topic, dbg);
            continue;
          }
        }

        if (attempt % 10 == 0) {
          dbg.log('IPFS: retry #$attempt — still waiting for gossipsub mesh for $short '
              '(${_retryQueue[recipientId]?.length ?? 0} msg(s) queued)');
        }
      }
    }
    _retryLoopRunning = false;
  }

  /// Flush all queued messages for [recipientId] now that the mesh is alive.
  Future<void> _flushRetryQueue(String recipientId, String topic, TransportDebugger dbg) async {
    final short = recipientId.substring(0, 8);
    final msgs = _retryQueue.remove(recipientId);
    if (msgs == null || msgs.isEmpty) return;
    dbg.log('IPFS: ✓ gossipsub mesh formed for $short — flushing ${msgs.length} queued message(s)');
    for (final envelope in msgs) {
      try {
        await _rawPublish(topic, envelope, dbg);
        dbg.log('IPFS: retry-published ${envelope.length} bytes to $short');
      } catch (e) {
        dbg.log('IPFS: retry-publish failed: $e');
      }
    }
  }

  /// Cancel the existing cross-subscription for [topic] and re-create it.
  /// This forces GossipSub to send a fresh SUBSCRIBE + GRAFT to connected
  /// peers, which can unstick a stale mesh that never formed.
  Future<void> _forceResubscribe(String topic, TransportDebugger dbg) async {
    final existing = _crossSubs.remove(topic);
    _crossSubLru.remove(topic);
    if (existing != null) {
      await existing.cancel();
      dbg.log('IPFS: killed stale cross-sub for ${topic.substring(0, 11)}');
    }
    await _ensureCrossSubscribed(topic, dbg);
  }

  /// Raw HTTP publish — no discovery, no mesh check, just send.
  Future<void> _rawPublish(String topic, Uint8List data, TransportDebugger dbg) async {
    final uri = Uri.parse('$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
    final request = http.MultipartRequest('POST', uri);
    request.files.add(http.MultipartFile.fromBytes('data', data));
    final streamedResponse = await _client.send(request).timeout(const Duration(seconds: 10));
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 200) {
      throw TransportException('IPFS publish failed: ${response.statusCode} ${response.body}');
    }
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
    dbg.log('IPFS: trying DHT discovery for $short…');
    final connected = await _dhtDiscoverAndConnect(recipientId, dbg);

    // ── Step 3: Wait for GossipSub mesh formation ────────────────────────
    bool hasPeers = false;
    if (connected) {
      final maxWaitSecs = isHandshake ? 15 : 5;
      for (int i = 0; i < maxWaitSecs; i++) {
        hasPeers = await _checkTopicPeers(topic, dbg);
        if (hasPeers) break;
        if (i < maxWaitSecs - 1) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      if (!hasPeers) {
        dbg.log('IPFS: ⚠ gossipsub mesh NOT formed after ${maxWaitSecs}s — publishing best-effort + queuing for retry');
      }
    } else {
      dbg.log('IPFS: peer not in swarm — publishing best-effort + queuing for retry');
    }

    // ── Step 4: Publish ──────────────────────────────────────────────────
    await _rawPublish(topic, encryptedEnvelope, dbg);
    dbg.log('IPFS: published OK to $short');

    // ── Step 5: If mesh was empty, queue for automatic retry ─────────────
    // When gossipsub peers=0 the message was accepted by our local Kubo but
    // never actually forwarded to anyone. Queue it so the retry loop can
    // republish once the mesh forms (usually 30-90s after app restart).
    if (!hasPeers) {
      _retryQueue.putIfAbsent(recipientId, () => []).add(Uint8List.fromList(encryptedEnvelope));
      dbg.log('IPFS: queued message for retry (${_retryQueue[recipientId]!.length} pending for $short)');
      _ensureRetryLoop();
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

        // Start the global pulse circuit if not already started
        if (!_pulseCircuitStarted) {
          _pulseCircuitStarted = true;
          unawaited(_runPulseCircuit(dbg));
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

  bool _pulseCircuitStarted = false;

  /// Runs a global heartbeat circuit to keep circuit relay connections and
  /// GossipSub meshes alive across the network (inspired by disco-chat).
  Future<void> _runPulseCircuit(TransportDebugger dbg) async {
    final topic = 'phantom-pulse-circuit';
    final encTopic = _encodeTopic(topic);
    final subUri = Uri.parse('$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(encTopic)}');
    final pubUri = Uri.parse('$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(encTopic)}');

    // Subscribe in the background to receive pulses (keeps the stream open)
    unawaited(() async {
      while (!_disposed) {
        try {
          final req = http.Request('POST', subUri);
          final resp = await _client.send(req);
          if (resp.statusCode == 200) {
            await resp.stream.drain<void>();
          }
        } catch (_) {}
        if (!_disposed) await Future.delayed(const Duration(seconds: 5));
      }
    }());

    // Publish a pulse every 15 seconds
    while (!_disposed) {
      try {
        final payload = utf8.encode(DateTime.now().millisecondsSinceEpoch.toString());
        final req = http.MultipartRequest('POST', pubUri);
        req.files.add(http.MultipartFile.fromBytes('data', payload));
        await _client.send(req).timeout(const Duration(seconds: 5));
      } catch (_) {}
      if (!_disposed) await Future.delayed(const Duration(seconds: 15));
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
        bool hasMesh = await _checkTopicPeers(contactTopic, dbg);
        if (!hasMesh) {
          dbg.log('IPFS: $knownPeerId in swarm, waiting for gossipsub mesh (fast path)…');
          for (int i = 0; i < 4; i++) {
            await Future.delayed(const Duration(seconds: 2));
            hasMesh = await _checkTopicPeers(contactTopic, dbg);
            if (hasMesh) break;
          }
        }

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
        } catch (e) {
          dbg.log('IPFS: swarm disconnect error for $knownPeerId: $e');
        }
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
  /// that topic. Idempotent — calls for the same topic refresh its LRU
  /// position but never open a second stream. The subscription is kept open
  /// until [dispose] cancels it or it is evicted by the LRU cap.
  Future<void> _ensureCrossSubscribed(String topic, TransportDebugger dbg) async {
    if (_crossSubs.containsKey(topic)) {
      _crossSubLru.remove(topic);
      _crossSubLru.add(topic);
      return;
    }

    final uri = Uri.parse(
        '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
    try {
      final request  = http.Request('POST', uri);
      final response = await _client.send(request)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final sub = response.stream.listen(null, onError: (_) {}, cancelOnError: false);
        _crossSubs[topic] = sub;
        _crossSubLru.add(topic);
        while (_crossSubLru.length > _crossSubMax) {
          final evict = _crossSubLru.removeAt(0);
          final old = _crossSubs.remove(evict);
          if (old != null) {
            try { await old.cancel(); } catch (_) {}
            dbg.log('IPFS: cross-sub evicted ${evict.split('/').last.substring(0, 8)}');
          }
        }
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
  /// When [silent] is true, skip the debug log (used by the retry loop to
  /// avoid spamming logs every 5 seconds).
  Future<bool> _checkTopicPeers(String topic, TransportDebugger dbg, {bool silent = false}) async {
    try {
      final r = await _client.post(Uri.parse(
          '$_apiUrl/api/v0/pubsub/peers?arg=${Uri.encodeComponent(_encodeTopic(topic))}'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        final strings = (jsonDecode(r.body)['Strings'] as List?) ?? [];
        if (!silent) dbg.log('IPFS: gossipsub peers on topic: ${strings.length}');
        return strings.isNotEmpty;
      }
    } catch (_) {}
    return false;
  }

  /// Public probe: number of peers in the GossipSub mesh for the topic
  /// associated with [contactId]. Returns 0 when the daemon is unreachable
  /// or the contact's mesh is empty (likely offline).
  Future<int> contactMeshPeerCount(String contactId) async {
    try {
      final topic = _topicForId(contactId);
      final r = await _client.post(Uri.parse(
          '$_apiUrl/api/v0/pubsub/peers?arg=${Uri.encodeComponent(_encodeTopic(topic))}'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        final strings = (jsonDecode(r.body)['Strings'] as List?) ?? [];
        return strings.length;
      }
    } catch (_) {}
    return 0;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final sub in _crossSubs.values) {
      sub.cancel();
    }
    _crossSubs.clear();
    _crossSubLru.clear();
    _client.close();
  }
}

/// Transport over I2P via SAM v3.3 (Simple Anonymous Messaging) bridge.
///
/// This is the **primary** transport for handshake / control-plane frames
/// (INIT, handshakeAck, preKeyShare, connectivityInfo). Bulk message traffic
/// stays on IPFS — see TransportManager.publish.
///
/// Protocol:
///   * TCP control socket to host:samPort (default 7656) — kept open for the
///     lifetime of the session so the SAM bridge keeps our destination alive.
///   * UDP socket bound to an ephemeral local port for incoming datagrams.
///     SAM forwards every datagram addressed to us to that UDP port.
///   * Outgoing datagrams are sent to host:[samPort-1] (the SAM "datagram in"
///     port, default 7655) as `3.0 <session_id> <peer_dest>\n<payload>`.
///
/// The full destination keypair returned by the first `SESSION CREATE
/// DESTINATION=TRANSIENT` call is persisted (via [_persistKey] callback) and
/// reused on subsequent runs so our public destination stays stable.
class I2PTransport implements PhantomTransport {
  String host;
  final int samPort;
  /// UDP port the SAM bridge listens on for outbound datagrams (sender side).
  /// Defaults to samPort - 1 which matches i2pd / Java I2P out of the box.
  final int samUdpPort;
  /// Loader for a previously-persisted base64 SAM private-destination blob.
  /// Returning null causes us to ask SAM for a fresh TRANSIENT one and then
  /// persist it via [_persistKey].
  final Future<String?> Function()? _loadKey;
  final Future<void> Function(String b64)? _persistKey;

  Socket? _control;
  RawDatagramSocket? _udp;
  String? _myDest;
  String? _myPrivKey;
  bool _disposed = false;
  bool _ready = false;
  bool _samReachable = false;
  int _consecutiveFailures = 0;
  DateTime? _lastSessionAttemptAt;

  final _incoming = StreamController<IncomingEnvelope>.broadcast();

  /// SAM session identifier. Regenerated on every connection attempt to
  /// avoid DUPLICATED_ID when a previous SESSION CREATE was accepted by
  /// SAM but its reply timed out on our side (cold-start i2pd can take
  /// 30+ seconds to answer the first command), leaving a zombie session
  /// holding the old name.
  String _sessionId = 'phantom-${DateTime.now().millisecondsSinceEpoch}';

  @override
  final String name = 'i2p-sam';

  /// Implements the abstract contract: "available" means the transport can
  /// be used for outbound publish. That requires both SAM being reachable
  /// AND our SESSION CREATE having completed (so we have a destination key
  /// and an alive control socket).
  @override
  bool get isAvailable => _ready;

  /// True if the SAM bridge TCP port is responding. Doesn't mean i2pd is
  /// done bootstrapping; the SAM bridge accepts HELLO long before tunnels
  /// are built. Surface this separately from [isAvailable] so the UI can
  /// distinguish "bridge running, still bootstrapping" from "bridge down".
  bool get isSamReachable => _samReachable;

  /// True only after we have a working SESSION CREATE and a destination key
  /// — i.e. we can actually send / receive I2P datagrams right now.
  bool get isSessionReady => _ready;

  /// Number of consecutive SESSION CREATE attempts that have failed since
  /// the last success. Useful for the UI to show "still trying" vs "stuck".
  int get sessionAttemptFailures => _consecutiveFailures;

  I2PTransport({
    this.host = '127.0.0.1',
    this.samPort = 7656,
    int? samUdpPort,
    Future<String?> Function()? loadKey,
    Future<void> Function(String)? persistKey,
  })  : samUdpPort = samUdpPort ?? (samPort - 1),
        _loadKey = loadKey,
        _persistKey = persistKey;

  String? get myDestination => _myDest;

  @override
  Future<bool> checkAvailability() async {
    final dbg = TransportDebugger.instance;
    final hostsToTry = [
      host,
      if (Platform.isAndroid && host == '127.0.0.1') ...[
        '10.0.2.2', '192.168.240.1', '172.17.0.1',
        '172.33.0.1', '192.168.1.1', '192.168.0.1',
      ],
    ];

    for (final h in hostsToTry) {
      try {
        dbg.log('I2P: probing SAM at $h:$samPort');
        final probe = await Socket.connect(h, samPort,
            timeout: const Duration(milliseconds: 1500));
        await probe.close();
        host = h;
        _samReachable = true;
        dbg.log('I2P: SAM bridge reachable at $h');
        return true;
      } catch (_) {}
    }
    _samReachable = false;
    dbg.log('I2P: no SAM bridge reachable');
    return false;
  }

  /// Brings up the SAM session: HELLO → SESSION CREATE → NAMING LOOKUP NAME=ME.
  /// Idempotent — returns true if the session is alive after the call.
  Future<bool> _ensureSession() async {
    if (_ready && _control != null && _udp != null) return true;
    final dbg = TransportDebugger.instance;
    _lastSessionAttemptAt = DateTime.now();
    // Fresh session name per attempt so a stalled previous SESSION CREATE
    // doesn't make us collide with our own zombie session on SAM's side.
    _sessionId = 'phantom-${DateTime.now().microsecondsSinceEpoch}';
    try {
      // Bind+listen exactly once per process. RawDatagramSocket is a
      // single-subscription stream; calling listen() twice (on a retry after
      // SAM was down on first attempt) throws StateError. Previously the
      // listen() call lived outside the `if (justBound)` guard, so any TCP
      // reconnect cycle crashed the background maintainer.
      if (_udp == null) {
        _udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        _udp!.listen(_onUdpEvent, onError: (_) {}, cancelOnError: false);
      }

      final s = await Socket.connect(host, samPort,
          timeout: const Duration(seconds: 5));
      _control = s;

      // SAM is line-oriented for control. Pipe replies into a broadcast
      // stream so we can await named responses sequentially.
      final lines = s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();

      Future<String> next(Duration timeout) =>
          lines.first.timeout(timeout, onTimeout: () {
            throw const TransportException('I2P SAM reply timeout');
          });

      s.add(utf8.encode('HELLO VERSION MIN=3.3 MAX=3.3\n'));
      final hello = await next(const Duration(seconds: 5));
      if (!hello.contains('RESULT=OK')) {
        dbg.log('I2P: HELLO rejected: $hello');
        await _teardown();
        return false;
      }

      final restoredKey = _loadKey != null ? await _loadKey() : null;
      final destArg = restoredKey ?? 'TRANSIENT';
      final myUdp = _udp!.port;
      final createCmd =
          'SESSION CREATE STYLE=DATAGRAM ID=$_sessionId DESTINATION=$destArg '
          'PORT=$myUdp HOST=127.0.0.1\n';
      s.add(utf8.encode(createCmd));
      // Shorter timeout per attempt so a stuck SESSION CREATE doesn't
      // block the maintainer for 90 s. The maintainer keeps retrying
      // indefinitely with backoff, so giving each individual attempt 30 s
      // lets i2pd's bootstrap progress get a fresh chance every minute or
      // so without piling up zombie sessions.
      final status = await next(const Duration(seconds: 30));
      if (!status.contains('RESULT=OK')) {
        dbg.log('I2P: SESSION CREATE rejected: $status');
        _consecutiveFailures++;
        await _teardown();
        return false;
      }

      // SESSION STATUS RESULT=OK DESTINATION=<base64 priv keypair>
      final destMatch = RegExp(r'DESTINATION=(\S+)').firstMatch(status);
      if (destMatch != null) {
        _myPrivKey = destMatch.group(1);
        if (restoredKey == null && _persistKey != null && _myPrivKey != null) {
          await _persistKey(_myPrivKey!);
        }
      }

      s.add(utf8.encode('NAMING LOOKUP NAME=ME\n'));
      final lookup = await next(const Duration(seconds: 10));
      final valueMatch = RegExp(r'VALUE=(\S+)').firstMatch(lookup);
      if (valueMatch == null) {
        dbg.log('I2P: NAMING LOOKUP missing VALUE: $lookup');
        _consecutiveFailures++;
        await _teardown();
        return false;
      }
      _myDest = valueMatch.group(1);
      dbg.log('I2P: session ready — dest=${_myDest!.substring(0, 16)}…');

      // Drain remaining control lines silently so the socket doesn't block.
      lines.listen((_) {}, onError: (_) {});

      _ready = true;
      _consecutiveFailures = 0;
      return true;
    } catch (e) {
      dbg.log('I2P: session setup failed: $e');
      _consecutiveFailures++;
      await _teardown();
      return false;
    }
  }

  /// Time elapsed since the maintainer last tried to bring up SAM. UI uses
  /// this to render "bootstrapping…" with a heartbeat.
  Duration? get sinceLastSessionAttempt =>
      _lastSessionAttemptAt == null
          ? null
          : DateTime.now().difference(_lastSessionAttemptAt!);

  void _onUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udp!.receive();
    if (dg == null) return;
    // SAM v3 forwarded datagram format: "<source_destination>\n<payload>".
    final data = dg.data;
    final nl = data.indexOf(10);
    if (nl < 0 || nl >= data.length - 1) return;
    final sourceDest = utf8.decode(data.sublist(0, nl), allowMalformed: true).trim();
    final payload = Uint8List.fromList(data.sublist(nl + 1));
    if (payload.isEmpty) return;
    _incoming.add(IncomingEnvelope(
      data: payload,
      transportName: name,
      receivedAt: DateTime.now(),
      i2pSourceDestination: sourceDest.isEmpty ? null : sourceDest,
    ));
  }

  /// Sends [data] to a known peer destination via the SAM datagram port.
  Future<void> publishToDest({required String dest, required Uint8List data}) async {
    final dbg = TransportDebugger.instance;
    if (!await _ensureSession()) {
      throw const TransportException('I2P session unavailable');
    }
    final header = utf8.encode('3.0 $_sessionId $dest\n');
    final packet = Uint8List(header.length + data.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + data.length, data);
    try {
      final sent = _udp!.send(packet, InternetAddress(host), samUdpPort);
      if (sent <= 0) {
        throw const TransportException('I2P UDP send returned 0 bytes');
      }
      dbg.log('I2P: datagram out (${data.length} B → ${dest.substring(0, 12)}…)');
    } catch (e) {
      dbg.log('I2P: UDP send failed: $e');
      rethrow;
    }
  }

  @override
  Future<void> publish({required String recipientId, required Uint8List encryptedEnvelope}) async {
    throw const TransportException(
        'I2P transport routes by destination; use publishToDest');
  }

  bool _maintainerRunning = false;

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) {
    if (!_maintainerRunning) {
      _maintainerRunning = true;
      unawaited(_runMaintainer());
    }
    return _incoming.stream;
  }

  /// Background session keeper: brings up the SAM session if it's down and
  /// reconnects when the control socket dies. Datagrams arrive independently
  /// via the UDP socket listener and flow straight into _incoming.
  Future<void> _runMaintainer() async {
    while (!_disposed) {
      if (!await _ensureSession()) {
        if (_disposed) return;
        await Future.delayed(const Duration(seconds: 15));
        continue;
      }
      final ctrl = _control;
      if (ctrl == null) {
        if (_disposed) return;
        await Future.delayed(const Duration(seconds: 5));
        continue;
      }
      try {
        await ctrl.done;
      } catch (_) {}
      if (!_disposed) {
        TransportDebugger.instance.log('I2P: control socket closed — reconnecting');
        _ready = false;
        _control = null;
        await Future.delayed(const Duration(seconds: 5));
      }
    }
    _maintainerRunning = false;
  }

  /// Direct hook used by TransportManager to merge our datagrams into the
  /// global incoming stream.
  Stream<IncomingEnvelope> get incoming => _incoming.stream;

  Future<void> _teardown() async {
    _ready = false;
    try { await _control?.close(); } catch (_) {}
    _control = null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _teardown();
    try { _udp?.close(); } catch (_) {}
    _udp = null;
    try { await _incoming.close(); } catch (_) {}
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

// ── Waku Transport ────────────────────────────────────────────────────────────

/// Transport over Waku relay + store protocol.
///
/// Waku is the primary messaging transport for Phantom. Unlike IPFS PubSub,
/// Waku provides:
///   - Store-and-forward: messages persist on relay nodes for offline delivery
///   - Lightweight: designed for mobile, minimal CPU/memory/battery
///   - Content topics: each PhantomID maps to /phantom/1/{phantomId}/proto
///
/// IPFS is relegated to file transfer only (on-demand).
class WakuTransport implements PhantomTransport {
  bool _available = false;
  bool _disposed = false;
  final WakuDaemon _daemon;

  /// Persistence hooks for the last successful store-query wall clock (µs).
  /// Without them every app start re-fetches the full 72h+ store history and
  /// replays frames the ratchet already consumed — each replayed MSG frame
  /// fails to decrypt and used to trigger a spurious auto-revive session
  /// reset on every cold start.
  final Future<int?> Function()? _loadLastStoreQueryUs;
  final Future<void> Function(int)? _saveLastStoreQueryUs;

  WakuTransport({
    Future<int?> Function()? loadLastStoreQueryUs,
    Future<void> Function(int)? saveLastStoreQueryUs,
    WakuDaemon? daemon,
  })  : _loadLastStoreQueryUs = loadLastStoreQueryUs,
        _saveLastStoreQueryUs = saveLastStoreQueryUs,
        _daemon = daemon ?? WakuDaemon.instance;

  /// Content topic format following Waku naming convention.
  /// /phantom/1/{phantomId}/proto
  String _contentTopic(String phantomId) => '/phantom/1/$phantomId/proto';

  @override
  String get name => 'Waku';

  @override
  bool get isAvailable => _available;

  @override
  Future<bool> checkAvailability() async {
    if (_disposed) return false;
    try {
      final status = await _daemon.status();
      _available = status.running;
      return _available;
    } catch (e) {
      debugPrint('[WakuTransport] availability check failed: $e');
      _available = false;
      return false;
    }
  }

  /// Live peer-count probe against the local daemon. The daemon answering
  /// /debug/v1/info (what [checkAvailability] verifies) doesn't mean our
  /// gossip reaches anyone — during the DNS-discovery bootstrap window the
  /// node is "running · 0 peers" and relay publishes die in the empty mesh.
  Future<bool> hasRelayPeers() async {
    try {
      final st = await _daemon.status();
      return st.running && st.peers > 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    if (_disposed) throw const TransportException('WakuTransport disposed');
    final dbg = TransportDebugger.instance;
    final topic  = _contentTopic(recipientId);
    final sentAt = DateTime.now();

    // Publish-and-CONFIRM. The desktop lab proved that every cheaper signal
    // lies: relay returns HTTP 200 into a mesh that hasn't GRAFTed yet (the
    // message evaporates), a nonzero admin peer count says nothing about
    // mesh membership on our shard, and lightpush against status.prod dies
    // with 503 "protocols not supported" (go-waku v0.9.0 only speaks
    // /vac/waku/lightpush/2.0.0-beta1, the fleet moved on). The only signal
    // that equals "a receiver can fetch this later" is our payload showing
    // up in the fleet's own store — so that's what we require, republishing
    // until it does.
    for (int attempt = 1; attempt <= 4; attempt++) {
      if (await hasRelayPeers()) {
        await _daemon.relayPublish(
            contentTopic: topic, payload: encryptedEnvelope);
      }
      // Best-effort — dead against today's status.prod (see above) but
      // harmless, and covers fleets that still mount lightpush beta1.
      await _daemon.lightpush(contentTopic: topic, payload: encryptedEnvelope);

      // Give the gossip time to traverse fleet relay → store node; mesh
      // GRAFT after the first peer connects takes a few heartbeats, hence
      // the growing delay before each verification.
      await Future.delayed(Duration(seconds: 2 * attempt));

      if (await _storeHasPayload(
          topic: topic, payload: encryptedEnvelope, since: sentAt)) {
        if (attempt > 1) {
          dbg.log('Waku: ✓ publish confirmed by fleet store (attempt $attempt)');
        }
        return;
      }
      dbg.log('Waku: publish not in fleet store yet (attempt $attempt/4)');
    }
    throw const TransportException(
        'Waku publish never appeared in the fleet store');
  }

  /// True when [payload] is retrievable from the fleet's store on [topic] —
  /// the strongest delivery confirmation Waku offers.
  Future<bool> _storeHasPayload({
    required String topic,
    required Uint8List payload,
    required DateTime since,
  }) async {
    final msgs = await _daemon.storeQuery(
      contentTopic: topic,
      startTime: since.subtract(const Duration(minutes: 2)),
      pageSize: 100,
    );
    if (msgs == null) return false;
    return msgs.any((m) => _bytesEqual(m.payload, payload));
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) {
    final topic = _contentTopic(ourId);
    final dbg = TransportDebugger.instance;
    dbg.log('Waku: subscribing to $topic');

    final controller = StreamController<IncomingEnvelope>();

    // Set once the offline backlog has been fetched successfully this
    // session. Live messages may only advance the persisted store cursor
    // AFTER that — otherwise a live frame arriving while the store is still
    // unreachable (DNS discovery bootstrapping) would move the cursor past
    // offline messages we never fetched, losing them permanently.
    bool storeCursorReady = false;

    // 1. Offline backlog via Waku Store — with retry. Store-capable peers
    //    come from DNS discovery and routinely take 15-60s to appear after a
    //    cold start; the first query failing is the NORM, not the exception
    //    (observed: HTTP 500 "no suitable peers found" at t+0s). A
    //    single-shot query meant offline messages were never fetched for the
    //    entire session.
    unawaited(() async {
      for (int attempt = 1; attempt <= 40; attempt++) {
        if (_disposed || controller.isClosed) return;
        final ok = await _fetchStoreBacklog(topic, controller, dbg);
        if (ok) {
          storeCursorReady = true;
          return;
        }
        await Future.delayed(const Duration(seconds: 15));
      }
      dbg.log('Waku: ✗ store backlog never fetched (no store peers in 10m)');
    }());

    // 2. Live relay messages, immediately and in parallel with the backlog.
    () async {
      try {
        final stream = _daemon.relaySubscribe(contentTopic: topic);
        await for (final payload in stream) {
          if (_disposed || controller.isClosed) break;
          controller.add(IncomingEnvelope(
            data: payload,
            transportName: name,
            receivedAt: DateTime.now(),
          ));
          // Live delivery advances the store cursor too — anything received
          // here is already consumed, so the next cold-start query can skip it.
          if (storeCursorReady) {
            unawaited(_saveLastStoreQueryUs
                ?.call(DateTime.now().microsecondsSinceEpoch));
          }
        }
      } catch (e) {
        dbg.log('Waku: relay subscription error: $e');
      }
      if (!controller.isClosed) await controller.close();
    }();

    return controller.stream;
  }

  /// One full (paginated) store fetch starting at the persisted cursor minus
  /// a clock-skew overlap. Returns true and persists the new cursor only when
  /// every page query succeeded; a failed query returns false WITHOUT
  /// touching the cursor so the retry loop can try again.
  Future<bool> _fetchStoreBacklog(String topic,
      StreamController<IncomingEnvelope> controller, TransportDebugger dbg) async {
    try {
      final lastUs = await _loadLastStoreQueryUs?.call();
      DateTime? startTime = lastUs != null
          ? DateTime.fromMicrosecondsSinceEpoch(lastUs)
              .subtract(const Duration(minutes: 5))
          : null;
      const pageSize = 100;
      int total = 0;
      for (int page = 0; page < 10; page++) {
        final batch = await _daemon.storeQuery(
          contentTopic: topic,
          startTime: startTime,
          pageSize: pageSize,
        );
        if (batch == null) {
          dbg.log('Waku: store query failed (page $page) — will retry');
          return false;
        }
        for (final entry in batch) {
          if (controller.isClosed) break;
          controller.add(IncomingEnvelope(
            data: entry.payload,
            transportName: 'Waku-Store',
            receivedAt: DateTime.now(),
          ));
        }
        total += batch.length;
        if (batch.length < pageSize) break;
        final maxNs = batch
            .map((e) => e.timestampNs)
            .fold<int>(0, (m, t) => t > m ? t : m);
        if (maxNs <= 0) break;
        startTime = DateTime.fromMicrosecondsSinceEpoch(maxNs ~/ 1000 + 1);
      }
      dbg.log('Waku: ✓ store backlog fetched ($total message(s))');
      await _saveLastStoreQueryUs?.call(DateTime.now().microsecondsSinceEpoch);
      return true;
    } catch (e) {
      dbg.log('Waku: store backlog error: $e');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}

class TransportException implements Exception {
  final String message;
  const TransportException(this.message);
  @override
  String toString() => 'TransportException: $message';
}



import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Lightweight presence layer using the bundled IPFS daemon as a pubsub bus.
///
/// Each user publishes a heartbeat to their own presence topic whenever the
/// app is active. Contacts' topics are subscribed via IPFS pubsub so we learn
/// immediately when they come online. "Online" means a heartbeat was seen
/// within [_threshold].
///
/// No rate limits — entirely P2P, no central relay.
class PresenceService {
  static const _defaultApiUrl = 'http://127.0.0.1:5001';
  static const _interval  = Duration(minutes: 2);
  static const _threshold = Duration(minutes: 7);

  final String _myId;
  final String _apiUrl;
  final http.Client _client = http.Client();

  final Map<String, DateTime> _lastSeen   = {};
  final Set<String>           _subscribed = {};
  final _changesCtrl = StreamController<String>.broadcast();

  // Peer IDs we've already connected to via swarm/connect (avoid spamming).
  final Set<String> _swarmConnected = {};

  Timer? _heartbeatTimer;
  bool _disposed = false;

  /// Always false — IPFS presence has no rate limits.
  bool get isRateLimited => false;

  /// Emits a contactId whenever that contact's online status changes.
  Stream<String> get changes => _changesCtrl.stream;

  PresenceService(this._myId, {String? ipfsApiUrl})
      : _apiUrl = ipfsApiUrl ?? _defaultApiUrl;

  Future<void> start(List<String> contactIds) async {
    _subscribeAll(contactIds);
    // Publish immediately and at short intervals for the first few minutes so
    // that a contact who comes online after us receives a heartbeat quickly
    // rather than waiting for the full periodic interval.
    await _publishHeartbeat();
    Timer(const Duration(seconds: 10), _publishHeartbeat);
    Timer(const Duration(seconds: 30), _publishHeartbeat);
    Timer(const Duration(seconds: 90), _publishHeartbeat);
    _heartbeatTimer = Timer.periodic(_interval, (_) => _publishHeartbeat());
  }

  void addContacts(List<String> contactIds) => _subscribeAll(contactIds);

  bool isOnline(String contactId) {
    final last = _lastSeen[contactId];
    return last != null && DateTime.now().difference(last) < _threshold;
  }

  Future<void> goOffline() => _publishHeartbeat(online: false);
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
        final request = http.Request('POST', uri);
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

            // Bootstrap gossipsub mesh: connect directly to the peer that sent
            // this heartbeat. The 'from' field is a multibase-encoded IPFS peer
            // ID. Doing this once per peer is enough to join their gossipsub mesh.
            final rawFrom = ev['from'] as String?;
            if (rawFrom != null) _trySwarmConnect(rawFrom);

            yield _PresenceEvent(at: DateTime.now(), online: body != '0');
          } catch (_) {}
        }
        if (!_disposed) await Future.delayed(const Duration(seconds: 5));
      } catch (_) {
        if (!_disposed) await Future.delayed(const Duration(seconds: 15));
      }
    }
  }

  /// Connects directly to an IPFS peer to bootstrap gossipsub mesh formation.
  ///
  /// [rawFrom] is the multibase-encoded peer ID from a pubsub message's `from`
  /// field. We decode it to a plain base58 peer ID, look up their multiaddrs
  /// via `routing/findpeer`, then call `swarm/connect` for each address.
  Future<void> _trySwarmConnect(String rawFrom) async {
    // Decode multibase peer ID → plain base58 string for Kubo API calls.
    String peerId;
    try {
      if (rawFrom.startsWith('u')) {
        final padded = rawFrom.substring(1).padRight(
            (rawFrom.length - 1 + 3) & ~3, '=');
        final bytes = base64Url.decode(padded);
        peerId = utf8.decode(bytes);
      } else if (rawFrom.startsWith('m')) {
        final bytes = base64.decode(rawFrom.substring(1));
        peerId = utf8.decode(bytes);
      } else {
        peerId = rawFrom; // already plain
      }
    } catch (_) {
      return;
    }

    if (_swarmConnected.contains(peerId)) return;
    _swarmConnected.add(peerId);

    try {
      // Find peer's multiaddrs via the DHT/routing.
      final findUri = Uri.parse(
          '$_apiUrl/api/v0/routing/findpeer?arg=${Uri.encodeComponent(peerId)}');
      final findResp = await _client
          .post(findUri)
          .timeout(const Duration(seconds: 15));
      if (findResp.statusCode != 200) return;

      final json = jsonDecode(findResp.body) as Map<String, dynamic>;
      final addrs = (json['Addrs'] as List?)?.cast<String>() ?? [];

      // Connect to each address, preferring relay-based ones first so we can
      // reach peers behind NAT even before hole-punch succeeds.
      final sorted = [...addrs]..sort((a, b) {
          final aRelay = a.contains('p2p-circuit') ? 0 : 1;
          final bRelay = b.contains('p2p-circuit') ? 0 : 1;
          return aRelay.compareTo(bRelay);
        });

      for (final addr in sorted.take(3)) {
        if (_disposed) return;
        final fullAddr = '$addr/p2p/$peerId';
        try {
          final connectUri = Uri.parse(
              '$_apiUrl/api/v0/swarm/connect?arg=${Uri.encodeComponent(fullAddr)}');
          await _client
              .post(connectUri)
              .timeout(const Duration(seconds: 10));
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _publishHeartbeat({bool online = true}) async {
    if (_disposed) return;
    try {
      final topic = _topic(_myId);
      final uri = Uri.parse(
          '$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
      await _client.post(
        uri,
        body: Uint8List.fromList(utf8.encode(online ? '1' : '0')),
        headers: {'Content-Type': 'application/octet-stream'},
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  static String _topic(String phantomId) => '/phantom/prs/v1/$phantomId';

  /// Kubo >= 0.11 requires pubsub args to be multibase-encoded (prefix 'u' = base64url).
  static String _encodeTopic(String topic) {
    final bytes = utf8.encode(topic);
    return 'u${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  void dispose() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _changesCtrl.close();
    _client.close();
  }
}

class _PresenceEvent {
  final DateTime at;
  final bool online;
  const _PresenceEvent({required this.at, required this.online});
}

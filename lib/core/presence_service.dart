import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'ipfs_daemon.dart';

/// Lightweight presence layer using the bundled IPFS daemon as a pubsub bus,
/// enriched with implicit signals: any successfully decrypted LIVE frame from
/// a contact proves they're online right now ([noteActivity]), which is far
/// more reliable than pubsub heartbeats riding a gossipsub mesh that takes
/// minutes to form after boot.
class PresenceService {
  /// 30s heartbeat / 90s threshold: three missed beats flip the dot to
  /// offline. The previous 2min/7min meant the green dot could lag reality
  /// by several minutes in both directions (and a task-killed app kept
  /// glowing green for up to 7 minutes).
  static const _interval             = Duration(seconds: 30);
  static const _threshold            = Duration(seconds: 90);
  static const _dhtAdvertiseInterval = Duration(minutes: 20);
  static const _dhtDiscoverInterval  = Duration(minutes: 2);

  final String _myId;
  final String _apiUrl;
  final http.Client _client = http.Client();

  final Map<String, DateTime> _lastSeen    = {};
  final Set<String>           _subscribed  = {};
  final _changesCtrl = StreamController<String>.broadcast();

  final Map<String, DateTime> _connectAttempts = {};
  static const _reconnectCooldown = Duration(minutes: 5);

  final Map<String, String> _contactIpfsPeerIds = {};

  Timer? _heartbeatTimer;
  Timer? _sweepTimer;
  Timer? _dhtAdvertiseTimer;
  Timer? _dhtDiscoverTimer;
  bool _disposed = false;

  /// Tracks whether the user's app is currently in the foreground. When false,
  /// the periodic heartbeat publishes offline so contacts don't see a stale
  /// green dot just because our timer kept firing every 2 minutes regardless
  /// of app state (the previous behaviour overrode goOffline almost immediately).
  bool _isForeground = true;

  bool get isRateLimited => false;
  Stream<String> get changes => _changesCtrl.stream;

  PresenceService(this._myId, {String? ipfsApiUrl})
      : _apiUrl = ipfsApiUrl ?? IpfsDaemon.apiUrl;

  Future<void> start(List<String> contactIds) async {
    _subscribeAll(contactIds);
    // Burst the first heartbeats: the gossipsub mesh for the prs topic takes
    // seconds-to-minutes to form after boot (field logs: prs-topic peers=0
    // for minutes), so the very first publishes usually vanish. Repeating at
    // 5/15/30s covers the formation window instead of waiting a full period.
    await _publishHeartbeat();
    for (final s in const [5, 15, 30]) {
      Timer(Duration(seconds: s), () => _publishHeartbeat(online: _isForeground));
    }
    _heartbeatTimer = Timer.periodic(_interval, (_) => _publishHeartbeat(online: _isForeground));

    // Threshold sweeper: expiry produces no pubsub event, so without this
    // the UI (which repaints on `changes` only) kept a stale green dot
    // forever once a contact vanished silently.
    _sweepTimer = Timer.periodic(const Duration(seconds: 15), (_) => _sweepExpired());

    unawaited(_advertiseOnDht());
    Timer(const Duration(seconds: 15), _advertiseOnDht);

    Timer(const Duration(seconds: 5), () => _discoverAll(contactIds));
    _dhtAdvertiseTimer = Timer.periodic(_dhtAdvertiseInterval, (_) => _advertiseOnDht());
    _dhtDiscoverTimer = Timer.periodic(_dhtDiscoverInterval, (_) => _discoverAll(_subscribed.toList()));
  }

  /// Implicit presence: called by the core whenever a LIVE frame from
  /// [contactId] decrypts successfully — direct proof they're online, no
  /// heartbeat needed. Store replays must NOT feed this (historical frames
  /// say nothing about now); the core filters those out.
  void noteActivity(String contactId) {
    if (_disposed) return;
    final wasOnline = isOnline(contactId);
    _lastSeen[contactId] = DateTime.now();
    if (!wasOnline) {
      _changesCtrl.add(contactId);
      // They just came online — answer with our own heartbeat so THEIR dot
      // for us converges immediately too (throttled).
      unawaited(_answerHeartbeat());
    }
  }

  /// Presence signal from the Bluetooth mesh: a contact was detected in range.
  /// Marks them online WITHOUT the IPFS answer-heartbeat — over the mesh there
  /// may be no internet, and the BLE advertisement itself is the bidirectional
  /// signal (both phones see each other's node hint).
  void noteMeshInRange(String contactId) {
    if (_disposed) return;
    final wasOnline = isOnline(contactId);
    _lastSeen[contactId] = DateTime.now();
    if (!wasOnline) _changesCtrl.add(contactId);
  }

  DateTime? _lastAnswerAt;

  /// Publishes our heartbeat in response to hearing from a contact, at most
  /// once per 20s, only while foregrounded. Makes both sides' dots converge
  /// within seconds of one side coming online instead of waiting out the
  /// other's timer period.
  Future<void> _answerHeartbeat() async {
    if (!_isForeground || _disposed) return;
    final now = DateTime.now();
    if (_lastAnswerAt != null &&
        now.difference(_lastAnswerAt!) < const Duration(seconds: 20)) {
      return;
    }
    _lastAnswerAt = now;
    await _publishHeartbeat();
  }

  void _sweepExpired() {
    if (_disposed) return;
    final now = DateTime.now();
    final expired = _lastSeen.entries
        .where((e) => now.difference(e.value) >= _threshold)
        .map((e) => e.key)
        .toList();
    for (final id in expired) {
      _lastSeen.remove(id);
      _changesCtrl.add(id);
    }
  }

  void addContacts(List<String> contactIds) {
    _subscribeAll(contactIds);
    unawaited(_discoverAll(contactIds));
  }

  void setContactIpfsPeerId(String contactId, String ipfsPeerId) {
    _contactIpfsPeerIds[contactId] = ipfsPeerId;
  }

  bool isOnline(String contactId) {
    final last = _lastSeen[contactId];
    return last != null && DateTime.now().difference(last) < _threshold;
  }

  List<String> _contactIds() =>
      _subscribed.where((id) => id != _myId).toList();

  /// App backgrounded: publish one offline beat and STOP all periodic work.
  /// Previously goOffline() only flipped a flag while the heartbeat (30s),
  /// sweeper (15s) and DHT discover (2m, which fires a swarm/connect storm)
  /// kept firing forever in the background — waking the radio every few
  /// seconds for presence nobody is looking at. Cancelling them is one of
  /// the largest battery wins available. The long-lived pubsub SSE streams
  /// stay up: they're event-driven, not polling, and message receipt rides
  /// the same daemon.
  Future<void> goOffline() async {
    _isForeground = false;
    _heartbeatTimer?.cancel();
    _sweepTimer?.cancel();
    _dhtDiscoverTimer?.cancel();
    _dhtAdvertiseTimer?.cancel();
    await _publishHeartbeat(online: false);
  }

  /// App foregrounded: announce online and restart the periodic work that
  /// goOffline() cancelled, with the same startup burst as a cold start so
  /// the dot converges within seconds.
  Future<void> publishOnline() async {
    if (_isForeground) return; // already active — avoid duplicate timers
    _isForeground = true;
    await _publishHeartbeat(online: true);
    for (final s in const [3, 10, 20]) {
      Timer(Duration(seconds: s), () => _publishHeartbeat(online: _isForeground));
    }
    _heartbeatTimer = Timer.periodic(_interval, (_) => _publishHeartbeat(online: _isForeground));
    _sweepTimer = Timer.periodic(const Duration(seconds: 15), (_) => _sweepExpired());
    _dhtDiscoverTimer = Timer.periodic(_dhtDiscoverInterval, (_) => _discoverAll(_subscribed.toList()));
    _dhtAdvertiseTimer = Timer.periodic(_dhtAdvertiseInterval, (_) => _advertiseOnDht());
    unawaited(_discoverAll(_contactIds()));
  }

  void _subscribeAll(List<String> ids) {
    for (final id in ids) {
      if (!_subscribed.contains(id)) {
        _subscribed.add(id);
        _streamContact(id);
      }
    }
    // Also subscribe to our own presence topic to help GossipSub mesh
    if (!_subscribed.contains(_myId)) {
      _subscribed.add(_myId);
      _streamContact(_myId);
    }
  }

  void _streamContact(String contactId) {
    _presenceStream(contactId).listen(
      (event) {
        final wasOnline = isOnline(contactId);
        if (event.online) {
          _lastSeen[contactId] = event.at;
          if (!wasOnline) {
            _changesCtrl.add(contactId);
            // Answer so their dot for us converges without waiting our
            // timer period (throttled inside).
            unawaited(_answerHeartbeat());
          }
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
    final uri = Uri.parse('$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');

    while (!_disposed) {
      try {
        final request  = http.Request('POST', uri);
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          if (!_disposed) await Future.delayed(const Duration(seconds: 15));
          continue;
        }
        await for (final line in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
          if (_disposed) return;
          if (line.trim().isEmpty) continue;
          try {
            final ev = jsonDecode(line) as Map<String, dynamic>;
            final rawData = ev['data'];
            if (rawData == null) continue;
            final bytes = _decodeData(rawData as String);
            final body = utf8.decode(bytes).trim();
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

  static Uint8List _decodeData(String raw) {
    if (raw.startsWith('m')) return base64.decode(raw.substring(1));
    if (raw.startsWith('u')) {
      final padded = raw.substring(1).padRight((raw.length - 1 + 3) & ~3, '=');
      return base64Url.decode(padded);
    }
    return base64.decode(raw);
  }

  Future<void> _advertiseOnDht() async {
    if (_disposed) return;
    try {
      final cid = await _phantomCid(_myId);
      final blockReq = http.MultipartRequest('POST', Uri.parse('$_apiUrl/api/v0/block/put?mhtype=sha2-256&cid-codec=raw'));
      blockReq.files.add(http.MultipartFile.fromBytes('data', utf8.encode('phantom-peer-v1:$_myId')));
      final blockStream = await _client.send(blockReq).timeout(const Duration(seconds: 10));
      await blockStream.stream.drain<void>();

      final provideUri = Uri.parse('$_apiUrl/api/v0/routing/provide?arg=${Uri.encodeComponent(cid)}&recursive=false');
      await _client.post(provideUri).timeout(const Duration(seconds: 30));
    } catch (_) {}
  }

  Future<void> _discoverAll(List<String> contactIds) async {
    for (final id in contactIds) {
      if (_disposed) return;
      await _discoverAndConnect(id);
    }
  }

  Future<void> _discoverAndConnect(String contactId) async {
    if (_disposed) return;
    final knownPeerId = _contactIpfsPeerIds[contactId];
    if (knownPeerId != null) {
      await _connectToPeer(knownPeerId, []);
      return;
    }
    try {
      final cid = await _phantomCid(contactId);
      final uri = Uri.parse('$_apiUrl/api/v0/routing/findprovs?arg=${Uri.encodeComponent(cid)}&num-providers=5');
      final request  = http.Request('POST', uri);
      final response = await _client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        return;
      }
      await for (final line in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (_disposed) return;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          if (json['Type'] != 4) continue;
          final responses = json['Responses'];
          if (responses is! List) continue;
          for (final peer in responses.cast<Map<String, dynamic>>()) {
            final peerId = peer['ID'] as String?;
            final addrs  = (peer['Addrs'] as List?)?.cast<String>() ?? [];
            if (peerId != null && peerId.isNotEmpty) await _connectToPeer(peerId, addrs);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _connectFromField(String rawFrom) async {
    String peerId;
    try {
      if (rawFrom.startsWith('u')) {
        final b64 = rawFrom.substring(1).padRight((rawFrom.length - 1 + 3) & ~3, '=');
        peerId = utf8.decode(base64Url.decode(b64));
      } else if (rawFrom.startsWith('m')) {
        peerId = utf8.decode(base64.decode(rawFrom.substring(1)));
      } else {
        peerId = rawFrom;
      }
    } catch (_) { return; }
    await _connectToPeer(peerId, []);
  }

  Future<void> _connectToPeer(String peerId, List<String> addrs) async {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _connectAttempts[peerId];
    if (last != null && now.difference(last) < _reconnectCooldown) return;
    _connectAttempts[peerId] = now;

    var addresses = addrs;
    if (addresses.isEmpty) {
      try {
        final findUri = Uri.parse('$_apiUrl/api/v0/routing/findpeer?arg=${Uri.encodeComponent(peerId)}');
        final r = await _client.post(findUri).timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) {
          addresses = (jsonDecode(r.body)['Addrs'] as List?)?.cast<String>() ?? [];
        }
      } catch (_) {}
    }
    addresses = addresses.where((a) => !a.contains('/127.0.0.1/') && !a.contains('/::1/')).toList();
    final targets = [...addresses.take(8).map((a) => '$a/p2p/$peerId'), '/p2p/$peerId'];

    unawaited(Future.wait(targets.map((addr) async {
      try {
        await _client.post(Uri.parse('$_apiUrl/api/v0/swarm/connect?arg=${Uri.encodeComponent(addr)}')).timeout(const Duration(seconds: 10));
      } catch (_) {}
    })));
  }

  static Future<String> _phantomCid(String phantomId) async {
    final sha256   = Sha256();
    final hash     = await sha256.hash(utf8.encode('phantom-peer-v1:$phantomId'));
    final hashBytes = Uint8List.fromList(hash.bytes);
    final cidBytes = Uint8List(36);
    cidBytes[0] = 0x01; cidBytes[1] = 0x55; cidBytes[2] = 0x12; cidBytes[3] = 0x20;
    cidBytes.setRange(4, 36, hashBytes);
    return 'f${cidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static String _topic(String phantomId) => 'prs$phantomId';

  static String _encodeTopic(String topic) {
    return 'u${base64Url.encode(utf8.encode(topic)).replaceAll('=', '')}';
  }

  Future<void> _publishHeartbeat({bool online = true}) async {
    if (_disposed) return;
    try {
      final topic = _topic(_myId);
      final uri = Uri.parse('$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
      final request = http.MultipartRequest('POST', uri);
      request.files.add(http.MultipartFile.fromBytes('data', utf8.encode(online ? '1' : '0')));
      await _client.send(request).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _sweepTimer?.cancel();
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

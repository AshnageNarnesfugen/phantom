import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Lightweight presence layer using the bundled IPFS daemon as a pubsub bus.
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

  final Map<String, DateTime> _connectAttempts = {};
  static const _reconnectCooldown = Duration(minutes: 5);

  final Map<String, String> _contactIpfsPeerIds = {};

  Timer? _heartbeatTimer;
  Timer? _dhtAdvertiseTimer;
  Timer? _dhtDiscoverTimer;
  bool _disposed = false;

  bool get isRateLimited => false;
  Stream<String> get changes => _changesCtrl.stream;

  PresenceService(this._myId, {String? ipfsApiUrl})
      : _apiUrl = ipfsApiUrl ?? _defaultApiUrl;

  Future<void> start(List<String> contactIds) async {
    _subscribeAll(contactIds);
    await _publishHeartbeat();
    Timer(const Duration(seconds: 10), _publishHeartbeat);
    _heartbeatTimer = Timer.periodic(_interval, (_) => _publishHeartbeat());

    unawaited(_advertiseOnDht());
    Timer(const Duration(seconds: 15), _advertiseOnDht);
    
    Timer(const Duration(seconds: 5), () => _discoverAll(contactIds));
    _dhtAdvertiseTimer = Timer.periodic(_dhtAdvertiseInterval, (_) => _advertiseOnDht());
    _dhtDiscoverTimer = Timer.periodic(_dhtDiscoverInterval, (_) => _discoverAll(_subscribed.toList()));
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

  Future<void> goOffline()     => _publishHeartbeat(online: false);
  Future<void> publishOnline() => _publishHeartbeat(online: true);

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

  static String _topic(String phantomId) => '/phantom/prs/v1/$phantomId';
  static String _encodeTopic(String topic) => topic;

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

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
        '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(topic)}');

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
            final body = utf8.decode(base64.decode(rawData as String)).trim();
            yield _PresenceEvent(at: DateTime.now(), online: body != '0');
          } catch (_) {}
        }
        if (!_disposed) await Future.delayed(const Duration(seconds: 5));
      } catch (_) {
        if (!_disposed) await Future.delayed(const Duration(seconds: 15));
      }
    }
  }

  Future<void> _publishHeartbeat({bool online = true}) async {
    if (_disposed) return;
    try {
      final topic = _topic(_myId);
      final uri = Uri.parse(
          '$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(topic)}');
      await _client.post(
        uri,
        body: Uint8List.fromList(utf8.encode(online ? '1' : '0')),
        headers: {'Content-Type': 'application/octet-stream'},
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  static String _topic(String phantomId) => '/phantom/prs/v1/$phantomId';

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

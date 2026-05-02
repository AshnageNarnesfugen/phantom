import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Lightweight presence layer using ntfy.sh as a ping bus.
///
/// Each user publishes a heartbeat to their own presence topic whenever the
/// app is active. Contacts' topics are subscribed via SSE so we learn
/// immediately when they come online. "Online" means a heartbeat was seen
/// within [_threshold].
///
/// Rate budget (ntfy free tier = 250 publishes/day per IP):
///   heartbeat every 15 min → 96/day for heartbeats,
///   leaving ~150/day for actual messages.
class PresenceService {
  static const _base      = 'https://ntfy.sh';
  static const _interval  = Duration(minutes: 15);
  static const _threshold = Duration(minutes: 20);

  final String _myId;
  final http.Client _client = http.Client();

  final Map<String, DateTime>   _lastSeen    = {};
  final Set<String>             _subscribed  = {};
  final _changesCtrl = StreamController<String>.broadcast();

  Timer? _heartbeatTimer;
  bool _disposed = false;

  /// Emits a contactId whenever that contact's online status changes.
  Stream<String> get changes => _changesCtrl.stream;

  PresenceService(this._myId);

  Future<void> start(List<String> contactIds) async {
    await _publishHeartbeat();
    _heartbeatTimer = Timer.periodic(_interval, (_) => _publishHeartbeat());
    _subscribeAll(contactIds);
  }

  void addContacts(List<String> contactIds) => _subscribeAll(contactIds);

  bool isOnline(String contactId) {
    final last = _lastSeen[contactId];
    return last != null && DateTime.now().difference(last) < _threshold;
  }

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
      (at) {
        final wasOnline = isOnline(contactId);
        _lastSeen[contactId] = at;
        if (!wasOnline) _changesCtrl.add(contactId);
      },
      onError: (_) {},
    );
  }

  Stream<DateTime> _presenceStream(String contactId) async* {
    final topic = _topic(contactId);
    int since = DateTime.now().millisecondsSinceEpoch ~/ 1000 - _threshold.inSeconds;

    while (!_disposed) {
      try {
        final uri = Uri.parse('$_base/$topic/json?since=$since');
        final streamed = await _client.send(http.Request('GET', uri));

        await for (final line in streamed.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (_disposed) return;
          if (line.trim().isEmpty) continue;
          try {
            final ev = jsonDecode(line) as Map<String, dynamic>;
            if (ev['event'] != 'message') continue;
            final at = (ev['time'] as num?)?.toInt() ?? 0;
            if (at > since) since = at;
            yield DateTime.fromMillisecondsSinceEpoch(at * 1000);
          } catch (_) {}
        }
      } catch (_) {
        if (!_disposed) await Future.delayed(const Duration(seconds: 30));
      }
    }
  }

  Future<void> _publishHeartbeat() async {
    if (_disposed) return;
    try {
      await _client.post(
        Uri.parse('$_base/${_topic(_myId)}'),
        headers: {
          'Content-Type': 'text/plain',
          'X-TTL': '${_threshold.inSeconds + 120}',
        },
        body: '1',
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  static String _topic(String phantomId) => 'ph-prs-$phantomId';

  void dispose() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _changesCtrl.close();
    _client.close();
  }
}

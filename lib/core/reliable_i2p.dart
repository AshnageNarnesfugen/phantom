import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// Reliable delivery over I2P's fire-and-forget datagrams (a small ARQ layer).
///
/// I2P repliable datagrams have no delivery feedback — a control frame can
/// silently vanish (observed in the field: 12 handshake frames "sent", peer saw
/// none). High-privacy mode routes the key exchange over I2P ONLY, so that loss
/// would strand the handshake. This adds the missing guarantee the cheap way,
/// WITHOUT a SAM STYLE=STREAM rewrite: every reliable frame carries a message id,
/// the receiver ACKs it, and the sender retransmits until the ACK lands (or
/// gives up after [maxRetries]). [sendReliable]'s future completes only on ACK —
/// i.e. real end-to-end confirmation that the peer's transport received it.
///
/// Pure transport plumbing: it doesn't know about encryption. It sits inside the
/// I2P transport, wrapping the already-E2E-encrypted envelope. Fully testable by
/// wiring two instances through a (lossy) in-memory channel.
class ReliableI2p {
  /// 'PRL1' — distinguishes a reliable frame from a plain datagram (whose bytes
  /// are ciphertext). 4 bytes → a plain envelope colliding is ~1/2^32.
  static const List<int> magic = [0x50, 0x52, 0x4C, 0x31];
  static const int _flagData = 0x00;
  static const int _flagAck = 0x01;
  static const int _headerLen = 4 + 1 + 8; // magic + flag + msgId

  /// Sends one raw datagram to [dest]. Returns quickly (fire-and-forget); errors
  /// are swallowed by the layer (a lost send is just another lost datagram).
  final Future<void> Function(String dest, Uint8List frame) _rawSend;
  final Duration retransmit;
  final int maxRetries;
  final Random _rng;

  final Map<String, _Pending> _pending = {}; // our msgId(hex) → completer/timer
  final Map<String, DateTime> _seen = {}; // "srcDest|msgId" → first-seen (dedup)
  static const _seenTtl = Duration(minutes: 10);
  static const _seenMax = 2000;

  ReliableI2p({
    required Future<void> Function(String dest, Uint8List frame) rawSend,
    this.retransmit = const Duration(seconds: 4),
    this.maxRetries = 6,
    Random? rng,
  })  : _rawSend = rawSend,
        _rng = rng ?? Random.secure();

  /// Sends [payload] to [dest] reliably. The returned future completes when the
  /// peer ACKs (delivery confirmed) or errors after [maxRetries] unacked tries.
  Future<void> sendReliable(String dest, Uint8List payload) {
    final id = _newId();
    final frame = _encode(_flagData, id, payload);
    final completer = Completer<void>();
    var attempts = 0;
    Timer? timer;

    void giveUp() {
      timer?.cancel();
      _pending.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(
            StateError('I2P reliable: no ACK after $maxRetries attempts'));
      }
    }

    void fire() {
      if (completer.isCompleted) return;
      if (attempts >= maxRetries) {
        giveUp();
        return;
      }
      attempts++;
      unawaited(_rawSend(dest, frame).catchError((_) {}));
    }

    _pending[id] = _Pending(completer, () => timer?.cancel());
    fire(); // first attempt immediately
    timer = Timer.periodic(retransmit, (_) => fire());
    return completer.future;
  }

  /// Processes an inbound datagram from [srcDest]. Returns the payload to deliver
  /// upward for a NEW reliable message (and auto-ACKs it), null for an ACK or a
  /// duplicate. A datagram without our magic is a plain (non-reliable) frame and
  /// is returned unchanged so the legacy path still works.
  Uint8List? onDatagram(String srcDest, Uint8List frame) {
    if (!_hasMagic(frame)) return frame; // plain datagram — pass through
    final flag = frame[4];
    final id = _idHex(frame, 5);
    if (flag == _flagAck) {
      _pending.remove(id)?.ack();
      return null;
    }
    if (flag == _flagData) {
      // ACK first (idempotent — the sender dedupes on its side too).
      unawaited(_rawSend(srcDest, _encodeAck(id)).catchError((_) {}));
      final key = '$srcDest|$id';
      if (_isDuplicate(key)) return null;
      return Uint8List.sublistView(frame, _headerLen);
    }
    return frame; // unknown flag → treat as plain
  }

  /// Abandons all in-flight reliable sends (call on transport teardown).
  void dispose() {
    for (final p in _pending.values) {
      p.cancelTimer();
      if (!p.completer.isCompleted) {
        p.completer.completeError(StateError('I2P reliable: disposed'));
      }
    }
    _pending.clear();
    _seen.clear();
  }

  // ── internals ──────────────────────────────────────────────────────────────

  bool _isDuplicate(String key) {
    final now = DateTime.now();
    if (_seen.length > _seenMax) {
      _seen.removeWhere((_, t) => now.difference(t) > _seenTtl);
    }
    if (_seen.containsKey(key)) return true;
    _seen[key] = now;
    return false;
  }

  String _newId() {
    final b = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      b[i] = _rng.nextInt(256);
    }
    return _hex(b);
  }

  static bool _hasMagic(Uint8List f) {
    if (f.length < _headerLen) return false;
    for (var i = 0; i < 4; i++) {
      if (f[i] != magic[i]) return false;
    }
    return true;
  }

  static Uint8List _encode(int flag, String idHex, Uint8List payload) {
    final out = Uint8List(_headerLen + payload.length);
    out.setRange(0, 4, magic);
    out[4] = flag;
    out.setRange(5, 13, _unhex(idHex));
    out.setRange(_headerLen, out.length, payload);
    return out;
  }

  static Uint8List _encodeAck(String idHex) =>
      _encode(_flagAck, idHex, Uint8List(0));

  static String _idHex(Uint8List f, int off) =>
      _hex(Uint8List.sublistView(f, off, off + 8));

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _unhex(String h) {
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

class _Pending {
  final Completer<void> completer;
  final void Function() cancelTimer;
  _Pending(this.completer, this.cancelTimer);
  void ack() {
    cancelTimer();
    if (!completer.isCompleted) completer.complete();
  }
}

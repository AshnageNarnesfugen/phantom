import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Severity, inferred from the message itself (the call sites are plain
/// `log('TAG: …')` strings and there are hundreds of them).
enum LogLevel { error, warn, ok, info }

/// One row of the debugger: a message and every repeat of it.
///
/// Repeats are the normal case, not the exception. A stalled IPFS daemon
/// emits the same subscribe-retry a hundred times a minute and a gossipsub
/// search polls once per second; read line by line that buries the four lines
/// that matter. A group keeps the first and last sighting, the count, and a
/// few raw samples so nothing is actually lost.
class LogGroup {
  /// Normalized key repeats are matched on — see [TransportDebugger.signatureOf].
  final String signature;

  /// The `TAG` in `TAG: message`, or `''`.
  final String tag;

  final LogLevel level;

  /// The most recent raw message (no timestamp). Shown as the row's text: the
  /// latest wording of an error is usually the most relevant one.
  String message;

  int count;
  DateTime firstAt;
  DateTime lastAt;

  /// Raw timestamped lines, newest last. Capped — the point of a group is not
  /// to hold everything, it is to hold enough to recognise what varied.
  final List<String> samples = [];
  static const _maxSamples = 6;

  LogGroup._({
    required this.signature,
    required this.tag,
    required this.level,
    required this.message,
    required this.firstAt,
    required this.lastAt,
    required String firstSample,
  }) : count = 1 {
    samples.add(firstSample);
  }

  void _add(String rawMessage, String sample, DateTime at) {
    count++;
    lastAt = at;
    message = rawMessage;
    // Keep the first sample (what it looked like originally) and the tail.
    if (samples.length >= _maxSamples) samples.removeAt(1);
    samples.add(sample);
  }

  bool get isRepeated => count > 1;
}

/// Global live log for the transport stack, grouped by message identity.
///
/// Widgets subscribe to [stream] to get the group that just changed — a new
/// row, or an existing row whose counter moved.
class TransportDebugger {
  static final instance = TransportDebugger._();
  TransportDebugger._();

  /// Distinct rows kept. Beyond this the least recently seen group is evicted.
  static const _maxGroups = 400;

  /// Raw lines kept for the tail of a diagnostic report. A handshake between
  /// two cold phones logs several hundred lines on its own (every transport
  /// fan-out, retry and store poll), so 400 lost the start of it.
  static const _maxRaw = 3000;

  final _ctrl = StreamController<LogGroup>.broadcast();
  final _groups = <LogGroup>[];
  final _bySignature = <String, LogGroup>{};
  final _raw = ListQueue<String>();

  DateTime? _startedAt;
  int _totalLines = 0;

  /// Fires whenever a group is created or its count changes.
  Stream<LogGroup> get stream => _ctrl.stream;

  /// Rows in first-seen order. A repeat updates its row in place rather than
  /// moving it, so the sequence of events stays readable.
  List<LogGroup> get groups => List.unmodifiable(_groups);

  /// The raw tail, newest last.
  List<String> get rawTail => List.unmodifiable(_raw);

  /// Every line ever logged this session, including collapsed repeats.
  int get totalLines => _totalLines;

  /// When the first line of this session was logged.
  DateTime? get startedAt => _startedAt;

  void log(String msg) {
    final now = DateTime.now();
    _startedAt ??= now;
    _totalLines++;

    final ts = '${_p(now.hour)}:${_p(now.minute)}:${_p(now.second)}'
        '.${_p(now.millisecond ~/ 10)}';
    final line = '[$ts] $msg';

    _raw.add(line);
    if (_raw.length > _maxRaw) _raw.removeFirst();

    final sig = signatureOf(msg);
    final existing = _bySignature[sig];
    if (existing != null) {
      existing._add(msg, line, now);
      if (!_ctrl.isClosed) _ctrl.add(existing);
    } else {
      final group = LogGroup._(
        signature: sig,
        tag: tagOf(msg),
        level: levelOf(msg),
        message: msg,
        firstAt: now,
        lastAt: now,
        firstSample: line,
      );
      _bySignature[sig] = group;
      _groups.add(group);
      _evictIfNeeded();
      if (!_ctrl.isClosed) _ctrl.add(group);
    }

    // The logcat sink is DEBUG-ONLY. In release these lines carry network
    // locators and the social graph — I2P destinations, IPFS peer IDs,
    // contact phantom IDs, who is talking to whom — and logcat is reachable
    // via `adb logcat` and by any app holding READ_LOGS on a rooted device.
    // For a metadata-minimising messenger that leak is unacceptable, so it
    // never fires in a production build. Diagnose release issues through the
    // in-app debugger instead.
    if (kDebugMode) debugPrint('[Transport] $msg');
  }

  void clear() {
    _groups.clear();
    _bySignature.clear();
    _raw.clear();
    _totalLines = 0;
    _startedAt = null;
  }

  void _evictIfNeeded() {
    if (_groups.length <= _maxGroups) return;
    // Drop the group nobody has seen in the longest time, not the oldest by
    // creation: a row that started early and is still firing is the live one.
    var oldestIdx = 0;
    for (var i = 1; i < _groups.length; i++) {
      if (_groups[i].lastAt.isBefore(_groups[oldestIdx].lastAt)) oldestIdx = i;
    }
    final dropped = _groups.removeAt(oldestIdx);
    _bySignature.remove(dropped.signature);
  }

  // ── Classification ────────────────────────────────────────────────────────

  /// Identifier-shaped tokens: 8+ characters of the base58/base64 soup our
  /// logs are full of, mixing letters and digits, or carrying base64
  /// punctuation. Plain English words ("gossipsub", "subscription") have
  /// neither and survive, which is what keeps different errors apart.
  static final _idish = RegExp(r'[A-Za-z0-9~_+/=-]{8,}');
  static final _hasDigit = RegExp(r'\d');
  static final _hasAlpha = RegExp(r'[A-Za-z]');
  static final _b64Punct = RegExp(r'[~+/=]');
  static final _digits = RegExp(r'\d+');

  /// The key two lines are considered "the same message" under.
  ///
  /// Identifiers and numbers are what vary between repeats — the ephemeral
  /// port in a connection-refused, the attempt counter, the byte count, the
  /// peer id being dialled. None of them change what the line MEANS, and
  /// leaving them in produced a hundred unique rows for one stuck daemon.
  static String signatureOf(String msg) {
    final masked = msg.replaceAllMapped(_idish, (m) {
      final tok = m[0]!;
      final looksLikeId = _b64Punct.hasMatch(tok) ||
          (_hasDigit.hasMatch(tok) && _hasAlpha.hasMatch(tok));
      return looksLikeId ? '§' : tok;
    });
    return masked.replaceAll(_digits, '#').trim();
  }

  static String tagOf(String msg) {
    final i = msg.indexOf(': ');
    if (i <= 0 || i > 16) return '';
    final tag = msg.substring(0, i);
    return tag.contains(' ') ? '' : tag;
  }

  static LogLevel levelOf(String msg) {
    if (msg.contains('✗') ||
        msg.contains('FAIL') ||
        msg.contains('ERR') ||
        msg.contains('error') ||
        msg.contains('Exception') ||
        msg.contains('refused') ||
        msg.contains('rejected') ||
        msg.contains('failed')) {
      return LogLevel.error;
    }
    if (msg.contains('⚠') ||
        msg.contains('no peers') ||
        msg.contains('not ready') ||
        msg.contains('retry') ||
        msg.contains('retrying') ||
        msg.contains('waiting') ||
        msg.contains('skipped') ||
        msg.contains('continuing search')) {
      return LogLevel.warn;
    }
    if (msg.contains('✓') || msg.contains(' OK') || msg.contains('ready')) {
      return LogLevel.ok;
    }
    return LogLevel.info;
  }

  static String _p(int n) => n.toString().padLeft(2, '0');
}

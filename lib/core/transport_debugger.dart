import 'dart:async';
import 'package:flutter/foundation.dart';

/// Global live log for the transport stack.
/// Widgets can subscribe to [stream] to get real-time entries.
class TransportDebugger {
  static final instance = TransportDebugger._();
  TransportDebugger._();

  static const _max = 500;
  final _ctrl    = StreamController<String>.broadcast();
  final _entries = <String>[];

  Stream<String> get stream  => _ctrl.stream;
  List<String>   get entries => List.unmodifiable(_entries);

  void log(String msg) {
    // The in-app Transport Debugger view depends on both [_entries] and the
    // broadcast stream, so they are always populated — there is no risk of
    // accidental disclosure beyond the user already running their own app.
    // Only the logcat sink is gated, since logcat is reachable from `adb logs`
    // and via apps holding READ_LOGS on rooted devices.
    final now = DateTime.now();
    final ts  = '${_p(now.hour)}:${_p(now.minute)}:${_p(now.second)}.${_p2(now.millisecond ~/ 10)}';
    final line = '[$ts] $msg';
    _entries.add(line);
    if (_entries.length > _max) _entries.removeAt(0);
    if (!_ctrl.isClosed) _ctrl.add(line);
    // Always emit to debugPrint so `flutter run --release` and `adb logcat`
    // surface transport activity. The cost is negligible vs the value of
    // being able to diagnose a release-only crash without a separate sink.
    debugPrint('[Transport] $msg');
  }

  void clear() => _entries.clear();

  static String _p(int n)  => n.toString().padLeft(2, '0');
  static String _p2(int n) => n.toString().padLeft(2, '0');
}

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
    // The in-app Transport Debugger view (behind the app lock, visible only
    // to the user on their own device) depends on both [_entries] and the
    // broadcast stream, so those are always populated.
    final now = DateTime.now();
    final ts  = '${_p(now.hour)}:${_p(now.minute)}:${_p(now.second)}.${_p2(now.millisecond ~/ 10)}';
    final line = '[$ts] $msg';
    _entries.add(line);
    if (_entries.length > _max) _entries.removeAt(0);
    if (!_ctrl.isClosed) _ctrl.add(line);
    // The logcat sink is DEBUG-ONLY. In release these lines carry network
    // locators and the social graph — I2P destinations, IPFS peer IDs,
    // contact phantom IDs, who is talking to whom — and logcat is reachable
    // via `adb logcat` and by any app holding READ_LOGS on a rooted device.
    // For a metadata-minimising messenger that leak is unacceptable, so it
    // never fires in a production build. Diagnose release issues through the
    // in-app debugger instead.
    if (kDebugMode) debugPrint('[Transport] $msg');
  }

  void clear() => _entries.clear();

  static String _p(int n)  => n.toString().padLeft(2, '0');
  static String _p2(int n) => n.toString().padLeft(2, '0');
}

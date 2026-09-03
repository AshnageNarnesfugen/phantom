import 'dart:async';

/// Whether the app has deliberately put its bundled daemons to sleep.
///
/// In power save (backgrounded, off charger) go-waku duty-cycles and IPFS/i2pd
/// are stopped outright. Their local REST ports then refuse every connection —
/// correctly, by design. The reconnect loops did not know that, so for the
/// whole sleep they kept dialling dead ports on a 3s and 10s cadence: one
/// field capture logged 491 Waku and 157 IPFS retries across a 32-minute
/// window, none of which could ever succeed. Every one of them is socket work
/// on a CPU the duty-cycle exists to leave asleep, and it buries the log.
///
/// A loop that consults this sleeps until the daemons are actually back,
/// rather than proving 648 times that they are gone.
class PowerState {
  static final PowerState instance = PowerState._();
  PowerState._();

  bool _saving = false;
  Completer<void>? _resume;

  /// True while the daemons are intentionally down.
  bool get isSaving => _saving;

  void enterPowerSave() {
    if (_saving) return;
    _saving = true;
    _resume = Completer<void>();
  }

  void exitPowerSave() {
    if (!_saving) return;
    _saving = false;
    final c = _resume;
    _resume = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Completes as soon as the daemons are back, or after [timeout] regardless.
  ///
  /// The timeout is a safety net, not the mechanism: power save can also be
  /// entered by the Android service without the Dart side hearing about it, so
  /// a loop that waits forever on the completer could stay parked after the
  /// daemons returned. Waking every couple of minutes to re-check is still two
  /// orders of magnitude cheaper than every three seconds.
  Future<void> awaitAwake(
      {Duration timeout = const Duration(minutes: 2)}) async {
    if (!_saving) return;
    final resume = _resume;
    if (resume == null) return;
    await Future.any([resume.future, Future<void>.delayed(timeout)]);
  }

  /// Test hook.
  void reset() {
    exitPowerSave();
    _saving = false;
    _resume = null;
  }
}

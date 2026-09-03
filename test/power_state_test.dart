import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/power_state.dart';

/// A 32-minute field capture logged 491 Waku and 157 IPFS reconnect attempts
/// against daemons the app had stopped on purpose. None could have succeeded.
/// These pin the contract the reconnect loops now rely on.
void main() {
  late PowerState power;
  setUp(() => power = PowerState.instance..reset());
  tearDown(() => power.reset());

  test('awake by default — a normal retry is never delayed', () async {
    expect(power.isSaving, isFalse);
    await power.awaitAwake().timeout(const Duration(milliseconds: 200));
  });

  test('a parked loop waits, and is released the moment daemons return',
      () async {
    power.enterPowerSave();
    expect(power.isSaving, isTrue);

    var released = false;
    final waiter = power.awaitAwake().then((_) => released = true);

    await Future.delayed(const Duration(milliseconds: 60));
    expect(released, isFalse, reason: 'still asleep — no retry should fire');

    power.exitPowerSave();
    await waiter.timeout(const Duration(seconds: 1));
    expect(released, isTrue);
    expect(power.isSaving, isFalse);
  });

  test('every parked loop is released by one exit', () async {
    power.enterPowerSave();
    final waiters = List.generate(5, (_) => power.awaitAwake());
    power.exitPowerSave();
    await Future.wait(waiters).timeout(const Duration(seconds: 1));
  });

  test('the timeout is a safety net when the exit is never signalled', () async {
    // Power save can also be entered by the Android service without the Dart
    // side hearing the exit; a loop must not park forever.
    power.enterPowerSave();
    final sw = Stopwatch()..start();
    await power
        .awaitAwake(timeout: const Duration(milliseconds: 150))
        .timeout(const Duration(seconds: 2));
    sw.stop();
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(140));
    expect(power.isSaving, isTrue, reason: 'the timeout re-checks, it does not wake');
  });

  test('entering twice does not strand the first waiters', () async {
    power.enterPowerSave();
    final first = power.awaitAwake();
    power.enterPowerSave(); // no-op
    power.exitPowerSave();
    await first.timeout(const Duration(seconds: 1));
  });
}

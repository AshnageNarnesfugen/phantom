import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/waku_daemon.dart';
import 'package:phantom_messenger/transport/transport.dart';

/// Reproduces "communication gets destroyed and never comes back" WITHOUT a
/// device or the live fleet: a fake go-waku daemon drives WakuTransport's
/// store-health state machine deterministically.
///
/// The field failure: Waku's fleet store dropped, the transport nuked + thrashed
/// the daemon, and it never recovered — so all reliable messaging died and
/// stayed dead for the session, even after the trigger (ygg) was removed. These
/// tests pin the correct behaviour: degrade gracefully (best-effort + cooldown
/// so the manager fails over), don't stampede restarts, and RECOVER once the
/// store returns.
class _FakeWaku extends WakuDaemon {
  bool storeAlive;
  bool daemonRunning = true;
  int peers = 3;

  /// Whether a daemon restart re-establishes the store (the intended cure).
  bool restartRestoresStore = false;

  final List<Uint8List> published = []; // relay/lightpush best-effort payloads
  int redialCount = 0;
  int restartCount = 0;

  _FakeWaku._({required this.storeAlive}) : super.forTest();
  factory _FakeWaku.healthy() => _FakeWaku._(storeAlive: true);
  factory _FakeWaku.storeDead() => _FakeWaku._(storeAlive: false);

  @override
  Future<({bool running, int peers})> status() async =>
      (running: daemonRunning, peers: peers);

  @override
  Future<bool> hasConnectedStorePeer() async => storeAlive;

  @override
  Future<void> ensureServicePeers() async => redialCount++;

  @override
  Future<bool> relayPublish(
      {required String contentTopic,
      required Uint8List payload,
      String pubsubTopic = ''}) async {
    published.add(payload);
    return true;
  }

  @override
  Future<bool> lightpush(
      {required String contentTopic,
      required Uint8List payload,
      String pubsubTopic = ''}) async =>
      false;

  @override
  Future<List<({Uint8List payload, int timestampNs})>?> storeQuery({
    required String contentTopic,
    DateTime? startTime,
    int pageSize = 100,
    String pubsubTopic = '',
  }) async {
    if (!storeAlive) return null; // store unreachable → the field's "500"
    return [for (final p in published) (payload: p, timestampNs: 0)];
  }

  @override
  Future<void> restart() async {
    restartCount++;
    if (restartRestoresStore) storeAlive = true;
  }
}

WakuTransport _fast(WakuDaemon d) => WakuTransport(daemon: d)
  ..confirmUnit = Duration.zero
  ..deadCooldown = const Duration(milliseconds: 60);

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('healthy store: publish confirms, no heal, no restart', () async {
    final fake = _FakeWaku.healthy();
    final t = _fast(fake);
    await t.publish(recipientId: 'bob', encryptedEnvelope: _b('hi'));
    expect(fake.restartCount, 0);
    expect(t.storeLikelyDead, isFalse);
    expect(fake.published, isNotEmpty, reason: 'relayed to the mesh');
  });

  test('store dead: degrades (throws best-effort), sets cooldown, re-dials — '
      'does NOT hang', () async {
    final fake = _FakeWaku.storeDead();
    final t = _fast(fake);
    await expectLater(
      t.publish(recipientId: 'bob', encryptedEnvelope: _b('m')),
      throwsA(isA<TransportException>()),
      reason: 'must fail fast so TransportManager fails over to I2P/IPFS',
    );
    expect(t.storeLikelyDead, isTrue, reason: 'entered dead-cooldown');
    expect(fake.redialCount, greaterThan(0), reason: 're-dial attempted');
    expect(fake.published, isNotEmpty, reason: 'still sent best-effort on relay');
    expect(fake.restartCount, 1, reason: 'one restart, then throttled');
  });

  test('no restart stampede: concurrent publishes during an outage restart the '
      'daemon at most once', () async {
    final fake = _FakeWaku.storeDead(); // stays dead (restart does not cure)
    final t = _fast(fake);
    await Future.wait([
      for (var i = 0; i < 8; i++)
        t.publish(recipientId: 'bob', encryptedEnvelope: _b('m$i')).catchError(
            (_) => throw Exception()).then((_) {}, onError: (_) {}),
    ]);
    expect(fake.restartCount, lessThanOrEqualTo(1),
        reason: 'throttle + one-heal-at-a-time prevent the restart storm the '
            'field logs showed');
  });

  test('recovery via restart: a restart that re-establishes the store lets the '
      'same publish confirm', () async {
    final fake = _FakeWaku.storeDead()..restartRestoresStore = true;
    final t = _fast(fake);
    // Should NOT throw: attempt 1 fails, heal restarts → store back, a later
    // attempt confirms.
    await t.publish(recipientId: 'bob', encryptedEnvelope: _b('cured'));
    expect(fake.restartCount, 1);
    expect(t.storeLikelyDead, isFalse, reason: 'confirmed → not dead');
  });

  test('recovery after cooldown: once the store returns, the next publish '
      'confirms and clears the dead flag', () async {
    final fake = _FakeWaku.storeDead();
    final t = _fast(fake);
    await t
        .publish(recipientId: 'bob', encryptedEnvelope: _b('first'))
        .catchError((_) {});
    expect(t.storeLikelyDead, isTrue);

    fake.storeAlive = true; // store recovers on its own (go-waku re-dialed)
    await Future<void>.delayed(const Duration(milliseconds: 80)); // cooldown out

    await t.publish(recipientId: 'bob', encryptedEnvelope: _b('second'));
    expect(t.storeLikelyDead, isFalse,
        reason: 'a confirmed publish must clear the dead-cooldown — messaging '
            'recovers instead of staying dead for the session');
  });
}

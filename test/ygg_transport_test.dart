@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/transport.dart';
import 'package:phantom_messenger/transport/yggdrasil/ygg_packet_channel.dart';

/// YggdrasilTransport verification for the TUN-less design.
///
/// The transport no longer opens OS sockets through a VpnService/TUN (that made
/// ygg a system-wide VPN that black-holed the app's own daemons and every other
/// app). It now crafts/parses IPv6+UDP packets and moves them over a
/// [YggPacketChannel] wired to the in-process router's Send/Recv. These tests
/// drive that path over an in-memory loopback channel — the real bytes, no
/// device, no .aar, no VpnService.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _availabilityTests();
  _wireTests();
  _yggReadyHookTests();
  _clearYggTargetsTests();
}

/// In-memory stand-in for the native packet bridge: [send] delivers the raw
/// IPv6 packet to [peer]'s incoming stream (the "mesh"). Point [peer] at itself
/// for a self-loop.
class LoopbackYggChannel implements YggPacketChannel {
  final _in = StreamController<Uint8List>.broadcast();
  LoopbackYggChannel? peer;

  @override
  Future<void> send(Uint8List ipv6Packet) async {
    peer?._in.add(ipv6Packet);
  }

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> dispose() async {
    if (!_in.isClosed) await _in.close();
  }
}

void _availabilityTests() {
  group('YggdrasilTransport availability (honesty)', () {
    test('no address → not available', () async {
      // On a non-Android test host YggdrasilDaemon.instance.address is null, so
      // a transport with no injected address must report unavailable — the
      // honest "router not provisioned yet" state.
      final t = YggdrasilTransport(channel: LoopbackYggChannel());
      expect(await t.checkAvailability(), isFalse);
      expect(t.address, isNull);
      expect(t.isAvailable, isFalse);
    });

    test('available when an address is set', () async {
      final t = YggdrasilTransport(
          address: '203:0000:0000:0000:0000:0000:0000:0001',
          channel: LoopbackYggChannel());
      expect(await t.checkAvailability(), isTrue);
      expect(t.isAvailable, isTrue);
    });
  });
}

void _wireTests() {
  group('YggdrasilTransport wire (loopback channel)', () {
    const aAddr = '203:0000:0000:0000:0000:0000:0000:0aaa';
    const bAddr = '210:0000:0000:0000:0000:0000:0000:0bbb';

    late LoopbackYggChannel chA, chB;
    late YggdrasilTransport a, b;
    late List<IncomingEnvelope> gotB;
    late StreamSubscription<IncomingEnvelope> subB;

    setUp(() {
      chA = LoopbackYggChannel();
      chB = LoopbackYggChannel();
      chA.peer = chB; // A sends → B receives
      chB.peer = chA;
      a = YggdrasilTransport(address: aAddr, channel: chA);
      b = YggdrasilTransport(address: bAddr, channel: chB);
      gotB = [];
      subB = b.subscribe(ourId: 'ygg-b').listen(gotB.add);
    });

    tearDown(() async {
      await subB.cancel();
      await a.dispose();
      await b.dispose();
    });

    test('a frame sent to B arrives byte-exact', () async {
      final payload =
          Uint8List.fromList(List.generate(1130, (i) => (i * 31) & 0xff));
      await a.publishToAddr(address: bAddr, data: payload);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gotB, hasLength(1));
      expect(gotB.single.data, payload);
      expect(gotB.single.transportName, 'yggdrasil-tcp');
    });

    test('several frames all arrive in order', () async {
      for (var i = 0; i < 5; i++) {
        await a.publishToAddr(
            address: bAddr, data: Uint8List.fromList([i, i + 1, i + 2]));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gotB, hasLength(5));
      expect(gotB.map((e) => e.data[0]).toList(), [0, 1, 2, 3, 4]);
    });

    test('publishToAddr with no local address fails fast', () async {
      final orphan = YggdrasilTransport(channel: LoopbackYggChannel());
      expect(
        () => orphan.publishToAddr(address: bAddr, data: Uint8List(4)),
        throwsA(isA<TransportException>()),
      );
    });

    test('over-MTU frame is rejected (fan-out uses another path)', () async {
      final huge = Uint8List(2000); // > ygg MTU budget
      await expectLater(
        a.publishToAddr(address: bAddr, data: huge),
        throwsA(isA<TransportException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(gotB, isEmpty, reason: 'nothing over-size should reach the peer');
    });
  });
}

/// Fix (B) still holds: the moment ygg has an address, the manager must fire
/// onYggReady so PhantomCore re-broadcasts connectivityInfo (contacts only ever
/// learn our ygg address that way).
void _yggReadyHookTests() {
  group('TransportManager.onYggReady (address re-broadcast trigger)', () {
    test('fires once when ygg activates WITH an address', () async {
      final ygg = YggdrasilTransport(
          address: '203:0000:0000:0000:0000:0000:0000:0001',
          channel: LoopbackYggChannel());
      final mgr = TransportManager(transportsOverride: [ygg]);
      var fired = 0;
      mgr.onYggReady = () => fired++;
      await mgr.initialize(ourId: '3gn2xMzaLABTEST');
      expect(fired, 1, reason: 'ygg-with-address must trigger the re-broadcast');
      await mgr.reprobeInactive(); // idempotent — no duplicate broadcasts
      expect(fired, 1);
      await mgr.dispose();
    });
  });
}

/// clearYggTargets() drops ygg from the fan-out when the user disables it.
/// Proven over the loopback channel: a frame lands via ygg while targeted;
/// after the clear, ygg is the only backend and there's no target, so the send
/// fails fast (→ manager fails over instead of black-holing).
void _clearYggTargetsTests() {
  group('TransportManager.clearYggTargets (obstacle removal)', () {
    test('drops ygg from the fan-out; delivery works before, not after',
        () async {
      const selfAddr = '203:0000:0000:0000:0000:0000:0000:0abc';
      final ch = LoopbackYggChannel()..peer = null;
      ch.peer = ch; // self-loop: send comes back to our own incoming
      final ygg = YggdrasilTransport(address: selfAddr, channel: ch);
      final mgr = TransportManager(transportsOverride: [ygg]);
      final got = <IncomingEnvelope>[];
      final sub = mgr.incoming.listen(got.add);
      await mgr.initialize(ourId: 'clearYggTargetsTest');

      const bob = 'bobLongEnoughId';
      mgr.setContactYggAddress(bob, selfAddr); // route back to our own listener
      await mgr.publish(
          recipientId: bob,
          encryptedEnvelope: Uint8List.fromList([1, 2, 3, 4]));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(got, hasLength(1), reason: 'ygg carried the frame while targeted');

      mgr.clearYggTargets();
      await expectLater(
        mgr.publish(
            recipientId: bob,
            encryptedEnvelope: Uint8List.fromList([5, 6, 7, 8])),
        throwsA(isA<TransportException>()),
        reason: 'no ygg target + no other backend → fail fast for fail-over',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(got, hasLength(1), reason: 'no second frame rode the dead tunnel');

      await sub.cancel();
      await mgr.dispose();
    });
  });
}

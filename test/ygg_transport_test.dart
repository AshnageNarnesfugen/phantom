@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/transport.dart';

/// YggdrasilTransport verification, desktop-runnable.
///
/// Field bug that motivated this file: on devices with NO Yggdrasil TUN the
/// transport logged "availability = true" (it only checked that binding ::
/// worked — which always works), so the logs claimed the transport was fine
/// while it had no address and could reach no one. The status sheet showing
/// "inactive" was correct; the log was the false positive. These tests pin
/// the honest behaviour and exercise the real TCP wire path over ::1.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _realYggTests();
  _yggReadyHookTests();
  _clearYggTargetsTests();

  group('YggdrasilTransport availability (honesty)', () {
    /// True when this host has a REAL Yggdrasil interface (0200::/7) — e.g. a
    /// dev machine running the yggdrasil system service.
    Future<bool> hostHasYgg() async {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv6);
      for (final i in ifs) {
        for (final a in i.addresses) {
          final b = a.rawAddress;
          if (b.length == 16 && (b[0] == 0x02 || b[0] == 0x03)) return true;
        }
      }
      return false;
    }

    test('availability MATCHES the presence of a real ygg interface', () async {
      // The honesty contract, testable on any host:
      //  - host WITHOUT a 0200::/7 interface → available=false, address=null
      //    (before the fix: TRUE merely because :: is bindable — the field
      //    false positive).
      //  - host WITH one (dev machine running yggdrasil) → available=true and
      //    the detected address IS a 0200::/7 one.
      final hasYgg = await hostHasYgg();
      final t = YggdrasilTransport();
      final available = await t.checkAvailability();
      expect(available, hasYgg,
          reason: 'availability must mirror reality (host ygg=$hasYgg)');
      if (hasYgg) {
        expect(t.address, isNotNull);
        final b = InternetAddress(t.address!).rawAddress;
        expect(b[0] == 0x02 || b[0] == 0x03, isTrue,
            reason: 'detected address must be Yggdrasil 0200::/7');
      } else {
        expect(t.address, isNull);
      }
    });

    test('available when an address is set (manual/TUN)', () async {
      final t = YggdrasilTransport(address: '::1');
      expect(await t.checkAvailability(), isTrue);
    });
  });

  group('YggdrasilTransport wire (loopback ::1)', () {
    late YggdrasilTransport rx;
    late StreamSubscription<IncomingEnvelope> sub;
    late List<IncomingEnvelope> got;

    setUp(() async {
      got = [];
      rx = YggdrasilTransport(address: '::1');
      sub = rx.subscribe(ourId: 'test').listen(got.add);
      // Give the ServerSocket time to bind :7331.
      await Future.delayed(const Duration(milliseconds: 300));
    });

    tearDown(() async {
      await sub.cancel();
      await rx.dispose();
      // Free the port for the next test.
      await Future.delayed(const Duration(milliseconds: 200));
    });

    test('length-prefixed envelope round-trips intact', () async {
      final tx = YggdrasilTransport(address: '::1');
      final payload =
          Uint8List.fromList(List.generate(4096, (i) => (i * 37) & 0xff));
      await tx.publishToAddr(address: '::1', data: payload);

      await Future.delayed(const Duration(milliseconds: 400));
      expect(got, hasLength(1));
      expect(got.single.data, payload,
          reason: 'framing must deliver the exact bytes');
      expect(got.single.transportName, 'yggdrasil-tcp');
    });

    test('several sequential envelopes all arrive (one connection each)',
        () async {
      final tx = YggdrasilTransport(address: '::1');
      for (var i = 0; i < 5; i++) {
        await tx.publishToAddr(
            address: '::1',
            data: Uint8List.fromList([i, i + 1, i + 2]));
      }
      await Future.delayed(const Duration(milliseconds: 600));
      expect(got, hasLength(5));
      expect(got.map((e) => e.data[0]).toSet(), {0, 1, 2, 3, 4});
    });

    test('oversized frame (>1 MB cap) is rejected, listener survives',
        () async {
      // Hand-roll a client that CLAIMS a huge length. The reader must refuse
      // it (memory-bomb guard) and keep serving later, honest clients.
      final s = await Socket.connect('::1', YggdrasilTransport.listenPort);
      final header = ByteData(4)..setUint32(0, 5 * 1024 * 1024, Endian.big);
      s.add(header.buffer.asUint8List());
      s.add(Uint8List(1024)); // partial body — reader should bail on length
      await s.flush();
      await s.close();

      await Future.delayed(const Duration(milliseconds: 400));
      expect(got, isEmpty, reason: '>1MB claim must never surface');

      // The listener must still be alive for a well-formed message.
      final tx = YggdrasilTransport(address: '::1');
      await tx.publishToAddr(
          address: '::1', data: Uint8List.fromList([9, 9, 9]));
      await Future.delayed(const Duration(milliseconds: 400));
      expect(got, hasLength(1));
      expect(got.single.data, [9, 9, 9]);
    });
  });
}

/// Real-Yggdrasil path — runs ONLY on a host with an actual 0200::/7 interface
/// (the dev machine runs the yggdrasil system service; CI skips gracefully).
/// Proves the transport can bind on and receive at our real ygg address — the
/// exact socket a remote peer connects to — over the live ygg stack, not ::1.
void _realYggTests() {
  group('YggdrasilTransport over the REAL ygg interface', () {
    late String? yggAddr;

    setUpAll(() async {
      final probe = YggdrasilTransport();
      await probe.checkAvailability(); // auto-detects the host 0200::/7 addr
      yggAddr = probe.address;
    });

    test('binds on and round-trips a frame over our real 0200::/7 address',
        () async {
      final addr = yggAddr;
      if (addr == null) {
        return markTestSkipped('host has no Yggdrasil interface');
      }
      final rx = YggdrasilTransport(address: addr);
      final got = <IncomingEnvelope>[];
      final sub = rx.subscribe(ourId: 'ygg-real').listen(got.add);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final tx = YggdrasilTransport(address: addr);
      final payload =
          Uint8List.fromList(List.generate(2048, (i) => (i * 31) & 0xff));
      // Connect to OUR real ygg address:7331 — the same endpoint a peer hits.
      await tx.publishToAddr(address: addr, data: payload);

      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(got, hasLength(1),
          reason: 'a frame sent to our real ygg address must arrive at the '
              'transport listener bound on that address');
      expect(got.single.data, payload);

      await sub.cancel();
      await rx.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
  });
}

/// Fix (B): the moment ygg gets its address, PhantomCore must be told so it can
/// re-broadcast connectivityInfo (the handshake sent ygg=null, so this is the
/// only way contacts ever learn our ygg address). Here we prove the manager's
/// onYggReady hook fires exactly once when a ygg transport activates with an
/// address, and never for a ygg transport that has none.
void _yggReadyHookTests() {
  group('TransportManager.onYggReady (address re-broadcast trigger)', () {
    test('fires once when ygg activates WITH an address', () async {
      final ygg = YggdrasilTransport(address: '::1'); // has an address → ready
      final mgr = TransportManager(transportsOverride: [ygg]);
      var fired = 0;
      mgr.onYggReady = () => fired++;
      await mgr.initialize(ourId: '3gn2xMzaLABTEST');
      expect(fired, 1, reason: 'ygg-with-address must trigger the re-broadcast');
      await mgr.reprobeInactive(); // idempotent — no duplicate broadcasts
      expect(fired, 1);
      await mgr.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
  });
}

/// The user's ask: when ygg is disabled, stop letting it get in the way and
/// re-drive sends over the other transports. clearYggTargets() is the first
/// half — it forgets every contact's ygg address so the fan-out no longer even
/// attempts ygg. Proven over the real ::1 wire: a send lands via ygg before the
/// clear; after it, ygg is the only backend and there's no target left, so the
/// publish fails fast (which is exactly what makes TransportManagerV2 fall back
/// to the store / other paths instead of silently riding a dead tunnel).
void _clearYggTargetsTests() {
  group('TransportManager.clearYggTargets (obstacle removal)', () {
    test('drops ygg from the fan-out; delivery works before, not after',
        () async {
      final ygg = YggdrasilTransport(address: '::1');
      final mgr = TransportManager(transportsOverride: [ygg]);
      final got = <IncomingEnvelope>[];
      final sub = mgr.incoming.listen(got.add);
      await mgr.initialize(ourId: 'clearYggTargetsTest');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      const bob = 'bobLongEnoughId';
      mgr.setContactYggAddress(bob, '::1');
      await mgr.publish(
          recipientId: bob,
          encryptedEnvelope: Uint8List.fromList([1, 2, 3, 4]));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(got, hasLength(1), reason: 'ygg carried the frame while targeted');

      mgr.clearYggTargets();
      // ygg is now the ONLY transport and has no target → nothing to fire.
      await expectLater(
        mgr.publish(
            recipientId: bob,
            encryptedEnvelope: Uint8List.fromList([5, 6, 7, 8])),
        throwsA(isA<TransportException>()),
        reason: 'with the ygg target cleared and no other backend, the send '
            'fails fast so the manager fails over instead of black-holing it',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(got, hasLength(1), reason: 'no second frame rode the dead tunnel');

      await sub.cancel();
      await mgr.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
  });
}

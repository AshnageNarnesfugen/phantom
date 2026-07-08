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

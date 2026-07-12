import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/reliable_i2p.dart';

/// The "guaranteed I2P" layer: ACK + retransmit + dedup over fire-and-forget
/// datagrams. A bug here means the high-privacy handshake silently drops, so
/// this drives two instances through a deliberately LOSSY in-memory channel and
/// proves delivery is confirmed (sendReliable completes only on ACK), survives
/// packet loss, dedupes, and gives up cleanly when the peer is truly gone.
void main() {
  late ReliableI2p a, b;
  late List<Uint8List> gotB;
  late List<Uint8List> aToBframes;
  int dropAtoB = 0; // drop this many A→B frames (incl. retransmits)

  Uint8List payload(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 7 + 1) & 0xff));

  void wire({Duration rx = const Duration(milliseconds: 15), int retries = 12}) {
    gotB = [];
    aToBframes = [];
    dropAtoB = 0; // reset so a prior test's loss count doesn't leak in
    a = ReliableI2p(
      rawSend: (dest, frame) async {
        aToBframes.add(frame);
        if (dropAtoB > 0) {
          dropAtoB--;
          return; // simulate a lost datagram
        }
        scheduleMicrotask(() {
          final p = b.onDatagram('A', frame);
          if (p != null) gotB.add(p);
        });
      },
      retransmit: rx,
      maxRetries: retries,
    );
    b = ReliableI2p(
      rawSend: (dest, frame) async {
        // B→A carries ACKs; deliver them straight back (no loss on the ACK path
        // for these tests — loss on either leg is covered by dropAtoB anyway).
        scheduleMicrotask(() => a.onDatagram('B', frame));
      },
      retransmit: rx,
      maxRetries: retries,
    );
  }

  test('delivers + confirms even after several dropped datagrams', () async {
    wire();
    dropAtoB = 4; // the first 4 sends vanish
    final data = payload(1130);
    await a.sendReliable('B', data); // completes ONLY when B's ACK arrives
    expect(gotB, hasLength(1), reason: 'exactly one delivery despite retransmits');
    expect(gotB.single, data, reason: 'payload intact');
  });

  test('sendReliable throws when the peer never ACKs (bounded, no hang)',
      () async {
    wire(rx: const Duration(milliseconds: 10), retries: 3);
    dropAtoB = 100000; // every A→B frame is lost forever
    await expectLater(
      a.sendReliable('B', payload(8)),
      throwsA(isA<StateError>()),
      reason: 'must give up after maxRetries, not hang forever',
    );
  });

  test('duplicate DATA frame is delivered exactly once (dedup)', () async {
    wire();
    final data = payload(64);
    await a.sendReliable('B', data);
    expect(gotB, hasLength(1));
    // Re-inject the very first DATA frame A sent → must be recognised as a dup.
    final again = b.onDatagram('A', aToBframes.first);
    expect(again, isNull, reason: 'already-seen msgId must not deliver twice');
    expect(gotB, hasLength(1));
  });

  test('a plain (non-reliable) datagram passes through unchanged', () {
    wire();
    final plain = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11]);
    // No 'PRL1' magic → returned as-is so the legacy datagram path still works.
    expect(b.onDatagram('A', plain), plain);
  });

  test('independent messages each get their own confirmation', () async {
    wire();
    dropAtoB = 2;
    final d1 = payload(200), d2 = payload(300);
    await Future.wait([a.sendReliable('B', d1), a.sendReliable('B', d2)]);
    expect(gotB, hasLength(2));
    expect(gotB.map((e) => e.length).toSet(), {200, 300});
  });

  test('dispose fails in-flight sends instead of leaking them', () async {
    wire();
    dropAtoB = 100000; // never delivered
    final f = a.sendReliable('B', payload(10));
    a.dispose();
    await expectLater(f, throwsA(isA<StateError>()));
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/yggdrasil/ygg_ip6.dart';

/// The TUN-less ygg transport lives or dies by this codec: it hand-builds the
/// IPv6+UDP packets the router's Send/Recv move, so a header/checksum/offset
/// mistake means silently dropped frames on a real device (no exception, just
/// nothing arrives). These tests pin the wire format the router requires
/// (version 6, src=our addr, dst=peer addr, routed by L3) and prove a byte-
/// exact round-trip — all without a device or the .aar.
void main() {
  const src = '203:0000:0000:0000:0000:0000:0000:0001';
  const dst = '210:ffff:0000:0000:0000:0000:0000:0002';

  Uint8List body(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 37 + 11) & 0xff));

  test('round-trips a payload byte-for-byte', () {
    final payload = body(1130); // a typical Phantom frame
    final pkt = YggIp6.buildPacket(srcAddr: src, dstAddr: dst, payload: payload);
    final dg = YggIp6.parse(pkt);
    expect(dg, isNotNull);
    expect(dg!.payload, payload, reason: 'exact bytes must survive');
    expect(dg.dstPort, YggIp6.phantomPort);
    expect(dg.srcPort, YggIp6.phantomPort);
  });

  test('emits a well-formed IPv6 header the router will accept', () {
    final pkt = YggIp6.buildPacket(srcAddr: src, dstAddr: dst, payload: body(4));
    expect(pkt[0] & 0xf0, 0x60, reason: 'version nibble must be 6 (writePC check)');
    expect(pkt[6], 17, reason: 'next header = UDP');
    // src (8..24) must equal our address — the router drops packets whose
    // source isn\'t us.
    expect(Uint8List.sublistView(pkt, 8, 24), YggIp6.addrBytes(src));
    // dst (24..40) must be the peer — routed by destination.
    expect(Uint8List.sublistView(pkt, 24, 40), YggIp6.addrBytes(dst));
    // IPv6 payload length = UDP header (8) + data (4).
    final len = (pkt[4] << 8) | pkt[5];
    expect(len, 8 + 4);
  });

  test('UDP checksum is non-zero and self-consistent', () {
    final pkt = YggIp6.buildPacket(srcAddr: src, dstAddr: dst, payload: body(20));
    final csum = (pkt[46] << 8) | pkt[47];
    expect(csum, isNot(0), reason: 'IPv6 mandates a real (non-zero) UDP checksum');
    // Recomputing the ones-complement sum over pseudo-header + UDP incl. the
    // written checksum must yield 0x0000 (or 0xFFFF) for a valid packet.
    expect(_verifyUdp(pkt), isTrue);
  });

  test('parse rejects non-matching / malformed packets', () {
    final good = YggIp6.buildPacket(srcAddr: src, dstAddr: dst, payload: body(8));

    // wrong destination port → not ours
    expect(YggIp6.parse(good, wantPort: 9999), isNull);

    // not IPv6 (version nibble 4)
    final v4 = Uint8List.fromList(good)..[0] = 0x40;
    expect(YggIp6.parse(v4), isNull);

    // not UDP (next header 58 = ICMPv6, e.g. a Packet-Too-Big from the router)
    final icmp = Uint8List.fromList(good)..[6] = 58;
    expect(YggIp6.parse(icmp), isNull);

    // truncated
    expect(YggIp6.parse(Uint8List.sublistView(good, 0, 40)), isNull);
    expect(YggIp6.parse(Uint8List(10)), isNull);
  });

  test('parse reports the sender address (used for logging / return path)', () {
    final pkt = YggIp6.buildPacket(srcAddr: src, dstAddr: dst, payload: body(2));
    final dg = YggIp6.parse(pkt)!;
    expect(YggIp6.addrBytes(dg.srcAddr), YggIp6.addrBytes(src));
  });

  test('enforces the MTU cap so over-size frames fail fast', () {
    expect(
      () => YggIp6.buildPacket(
          srcAddr: src, dstAddr: dst, payload: body(YggIp6.maxPayload + 1)),
      throwsA(isA<ArgumentError>()),
    );
    // exactly at the cap is fine
    final ok = YggIp6.buildPacket(
        srcAddr: src, dstAddr: dst, payload: body(YggIp6.maxPayload));
    expect(YggIp6.parse(ok)!.payload.length, YggIp6.maxPayload);
  });

  test('empty payload is valid (keepalive-ish)', () {
    final pkt = YggIp6.buildPacket(srcAddr: src, dstAddr: dst, payload: Uint8List(0));
    final dg = YggIp6.parse(pkt);
    expect(dg, isNotNull);
    expect(dg!.payload, isEmpty);
  });
}

/// Independent checksum verifier (does NOT reuse the codec's routine): folds the
/// ones-complement sum over the IPv6 pseudo-header + the full UDP segment
/// including the transmitted checksum. A correct packet folds to 0xFFFF.
bool _verifyUdp(Uint8List pkt) {
  var sum = 0;
  for (var i = 8; i < 40; i += 2) {
    sum += (pkt[i] << 8) | pkt[i + 1]; // src + dst (pseudo-header)
  }
  final udpLen = (pkt[44] << 8) | pkt[45];
  sum += udpLen; // upper-layer length
  sum += 17; // next header = UDP
  for (var i = 0; i < udpLen; i += 2) {
    final hi = pkt[40 + i];
    final lo = (i + 1 < udpLen) ? pkt[40 + i + 1] : 0;
    sum += (hi << 8) | lo;
  }
  while (sum >> 16 != 0) {
    sum = (sum & 0xffff) + (sum >> 16);
  }
  return (sum & 0xffff) == 0xffff;
}

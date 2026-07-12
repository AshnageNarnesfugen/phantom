import 'dart:io';
import 'dart:typed_data';

/// Userspace IPv6 + UDP codec for the TUN-less Yggdrasil transport.
///
/// Yggdrasil's in-process router (the gomobile `mobile.Yggdrasil` binding)
/// exposes `Send([]byte)` / `Recv() []byte` that move **fully-formed IPv6
/// packets** in and out of the mesh — the same packets a TUN would carry.
/// Instead of standing up an Android VpnService/TUN (which becomes a
/// system-wide tunnel and black-holes the app's own daemons and every other
/// app), we craft and parse those IPv6 packets ourselves and pump them through
/// Send/Recv directly. No TUN, no VpnService, no VPN permission.
///
/// The router (`src/ipv6rwc`) only cares about layer-3 on the way out: it
/// checks the packet is IPv6 (version nibble 6), that the **source** address is
/// our own ygg address, and that the **destination** is a valid ygg 0200::/7
/// address — then routes by destination. It never inspects layer-4. On the way
/// in it hands us any IPv6 packet addressed to us, with the source already
/// anti-spoof-verified against the sender's key. So we wrap our frames in a
/// UDP datagram purely to multiplex by port (and to stay a well-formed packet).
class YggIp6 {
  YggIp6._();

  /// UDP, so a stray real TUN would still deliver to a UDP socket.
  static const int udpProtocol = 17;

  /// Phantom's fixed ygg port. Matches the old TCP listener port so nothing
  /// else in the stack has to change conceptually.
  static const int phantomPort = 7331;

  static const int _ipv6HeaderLen = 40;
  static const int _udpHeaderLen = 8;
  static const int headerLen = _ipv6HeaderLen + _udpHeaderLen; // 48

  /// Yggdrasil's minimum MTU is 1280; anything larger than MTU triggers an
  /// ICMPv6 Packet-Too-Big and gets dropped by the router. Cap the frame so
  /// oversized payloads fail fast (the transport fan-out then uses another
  /// backend) instead of silently vanishing.
  static const int maxPayload = 1280 - headerLen; // 1232

  /// Parses an IPv6 address string ("203:…") into its 16 raw bytes.
  /// Throws [FormatException] if it isn't a 16-byte IPv6 address.
  static Uint8List addrBytes(String ip) {
    final b = InternetAddress(ip).rawAddress;
    if (b.length != 16) {
      throw FormatException('not an IPv6 address: $ip');
    }
    return b;
  }

  /// Builds an IPv6+UDP packet from [srcAddr] to [dstAddr] carrying [payload].
  /// Both addresses are ygg IPv6 strings. Throws if [payload] exceeds
  /// [maxPayload] (the router would drop an over-MTU packet anyway).
  static Uint8List buildPacket({
    required String srcAddr,
    required String dstAddr,
    required Uint8List payload,
    int srcPort = phantomPort,
    int dstPort = phantomPort,
  }) {
    if (payload.length > maxPayload) {
      throw ArgumentError('ygg payload ${payload.length}B exceeds cap $maxPayload');
    }
    final src = addrBytes(srcAddr);
    final dst = addrBytes(dstAddr);
    final udpLen = _udpHeaderLen + payload.length;
    final pkt = Uint8List(headerLen + payload.length);
    final bd = ByteData.sublistView(pkt);

    // ── IPv6 header ──
    bd.setUint32(0, 0x60000000, Endian.big); // version 6, TC 0, flow 0
    bd.setUint16(4, udpLen, Endian.big); // payload length (UDP hdr + data)
    pkt[6] = udpProtocol; // next header
    pkt[7] = 64; // hop limit
    pkt.setRange(8, 24, src);
    pkt.setRange(24, 40, dst);

    // ── UDP header ──
    bd.setUint16(40, srcPort, Endian.big);
    bd.setUint16(42, dstPort, Endian.big);
    bd.setUint16(44, udpLen, Endian.big);
    // checksum (46..48) filled in below
    pkt.setRange(headerLen, pkt.length, payload);

    final csum = _udpChecksum(src, dst, pkt, 40, udpLen);
    bd.setUint16(46, csum, Endian.big);
    return pkt;
  }

  /// Parses [packet] as an incoming IPv6 packet. Returns the UDP datagram if it
  /// is a UDP packet destined for [wantPort]; null for anything else (ICMPv6,
  /// other ports, malformed). Never throws.
  static YggDatagram? parse(Uint8List packet, {int wantPort = phantomPort}) {
    if (packet.length < headerLen) return null;
    if (packet[0] & 0xf0 != 0x60) return null; // not IPv6
    if (packet[6] != udpProtocol) return null; // not UDP
    final bd = ByteData.sublistView(packet);
    final payloadLen = bd.getUint16(4, Endian.big); // IPv6 payload = UDP total
    if (payloadLen < _udpHeaderLen) return null;
    if (_ipv6HeaderLen + payloadLen > packet.length) return null; // truncated
    final srcPort = bd.getUint16(40, Endian.big);
    final dstPort = bd.getUint16(42, Endian.big);
    if (dstPort != wantPort) return null;
    final udpLen = bd.getUint16(44, Endian.big);
    if (udpLen < _udpHeaderLen || _ipv6HeaderLen + udpLen > packet.length) {
      return null;
    }
    final payload = Uint8List.sublistView(packet, headerLen, _ipv6HeaderLen + udpLen);
    final src = Uint8List.sublistView(packet, 8, 24);
    return YggDatagram(
      srcAddr: InternetAddress.fromRawAddress(src).address,
      srcPort: srcPort,
      dstPort: dstPort,
      payload: Uint8List.fromList(payload),
    );
  }

  /// UDP checksum over the IPv6 pseudo-header + UDP header + data (RFC 2460 §8.1
  /// — mandatory for IPv6, and a zero result is transmitted as 0xFFFF).
  static int _udpChecksum(
      Uint8List src, Uint8List dst, Uint8List pkt, int udpOffset, int udpLen) {
    var sum = 0;
    // pseudo-header: src(16) + dst(16)
    for (var i = 0; i < 16; i += 2) {
      sum += (src[i] << 8) | src[i + 1];
      sum += (dst[i] << 8) | dst[i + 1];
    }
    // upper-layer length (32-bit) + zeros + next header (UDP)
    sum += udpLen;
    sum += udpProtocol;
    // UDP header + data, with the checksum field (bytes 6..8) read as 0
    for (var i = 0; i < udpLen; i += 2) {
      if (i == 6) continue; // the checksum field itself
      final hi = pkt[udpOffset + i];
      final lo = (i + 1 < udpLen) ? pkt[udpOffset + i + 1] : 0;
      sum += (hi << 8) | lo;
    }
    while (sum >> 16 != 0) {
      sum = (sum & 0xffff) + (sum >> 16);
    }
    final csum = (~sum) & 0xffff;
    return csum == 0 ? 0xffff : csum;
  }
}

/// A UDP datagram parsed out of an inbound ygg IPv6 packet.
class YggDatagram {
  final String srcAddr;
  final int srcPort;
  final int dstPort;
  final Uint8List payload;
  const YggDatagram({
    required this.srcAddr,
    required this.srcPort,
    required this.dstPort,
    required this.payload,
  });
}

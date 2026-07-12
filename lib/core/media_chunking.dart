import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Chunked store-and-forward for media too large for a single inline frame.
///
/// Media ≤ 64 KB already rides inside ONE encrypted message, and Waku's store
/// persists it — so it reaches a receiver who was offline. Larger media used to
/// fall back to an IPFS CID pointer, whose bytes live ONLY on the sender's node:
/// the receiver can only fetch them while the sender is also online (no
/// store-and-forward for the content). That's the "image arrived but won't
/// download" failure.
///
/// This splits the bytes into ≤ [chunkPayload] slices and ships each as its own
/// encrypted message through the SAME transport stack. Every chunk is therefore
/// stored-and-forwarded exactly like a text message, so the receiver reassembles
/// the whole file whenever IT next comes online — no rendezvous, no IPFS. Waku's
/// store is the persistence layer (same as text); a mid-transfer restart re-pulls
/// the missing chunks on the next store sync.
///
/// This module is pure (no I/O) so the framing + reassembly are unit-tested.
class MediaManifest {
  /// 'PMC1' — Phantom Media Chunked v1. Distinguishes a chunked manifest from
  /// inline image bytes / the IPFS-CID pointer, which share the image/file type.
  static const int magic = 0x504D4331;

  final Uint8List transferId; // 16 bytes
  final int total; // chunk count
  final int size; // total byte length
  final Uint8List sha256; // 32 bytes — integrity of the reassembled file
  final String name;
  final bool isImage;

  const MediaManifest({
    required this.transferId,
    required this.total,
    required this.size,
    required this.sha256,
    required this.name,
    required this.isImage,
  });

  String get idHex =>
      transferId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List encode() {
    final nameBytes = Uint8List.fromList(utf8.encode(name));
    final out = Uint8List(63 + nameBytes.length);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, magic, Endian.big);
    out.setRange(4, 20, transferId);
    bd.setUint32(20, total, Endian.big);
    bd.setUint32(24, size, Endian.big);
    out.setRange(28, 60, sha256);
    out[60] = isImage ? 1 : 0;
    bd.setUint16(61, nameBytes.length, Endian.big);
    out.setRange(63, 63 + nameBytes.length, nameBytes);
    return out;
  }

  /// Decodes a manifest, or null if [c] isn't one. [maxSize] rejects an
  /// over-large declared size (anti-DoS: don't trust a peer's length blindly).
  static MediaManifest? decode(Uint8List c, {int maxSize = 1 << 30}) {
    if (c.length < 63) return null;
    final bd = ByteData.sublistView(c);
    if (bd.getUint32(0, Endian.big) != magic) return null;
    final total = bd.getUint32(20, Endian.big);
    final size = bd.getUint32(24, Endian.big);
    final nameLen = bd.getUint16(61, Endian.big);
    if (c.length != 63 + nameLen) return null;
    if (size > maxSize || total > 1 << 20) return null;
    String name;
    try {
      name = utf8.decode(Uint8List.sublistView(c, 63, 63 + nameLen));
    } catch (_) {
      return null;
    }
    return MediaManifest(
      transferId: Uint8List.fromList(Uint8List.sublistView(c, 4, 20)),
      total: total,
      size: size,
      sha256: Uint8List.fromList(Uint8List.sublistView(c, 28, 60)),
      name: name,
      isImage: c[60] == 1,
    );
  }
}

/// One slice of a chunked transfer: `[transferId 16][index 4 BE][bytes…]`.
class MediaChunkFrame {
  final Uint8List transferId;
  final int index;
  final Uint8List bytes;

  const MediaChunkFrame({
    required this.transferId,
    required this.index,
    required this.bytes,
  });

  String get idHex =>
      transferId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List encode() {
    final out = Uint8List(20 + bytes.length);
    out.setRange(0, 16, transferId);
    ByteData.sublistView(out).setUint32(16, index, Endian.big);
    out.setRange(20, 20 + bytes.length, bytes);
    return out;
  }

  static MediaChunkFrame? decode(Uint8List c) {
    if (c.length < 20) return null;
    return MediaChunkFrame(
      transferId: Uint8List.fromList(Uint8List.sublistView(c, 0, 16)),
      index: ByteData.sublistView(c).getUint32(16, Endian.big),
      bytes: Uint8List.fromList(Uint8List.sublistView(c, 20)),
    );
  }
}

class MediaChunker {
  /// Per-chunk payload. Comfortably under the 64 KB single-frame budget once
  /// the 20-byte chunk header and the ratchet/wire overhead are added.
  static const int chunkPayload = 56 * 1024;

  static ({MediaManifest manifest, List<MediaChunkFrame> chunks}) split(
    Uint8List bytes, {
    required String name,
    required bool isImage,
    Random? rng,
  }) {
    final r = rng ?? Random.secure();
    final tid = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
    final total = bytes.isEmpty ? 0 : (bytes.length / chunkPayload).ceil();
    final digest = Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
    final chunks = <MediaChunkFrame>[
      for (var i = 0; i < total; i++)
        MediaChunkFrame(
          transferId: tid,
          index: i,
          bytes: Uint8List.sublistView(
              bytes, i * chunkPayload, min((i + 1) * chunkPayload, bytes.length)),
        ),
    ];
    return (
      manifest: MediaManifest(
          transferId: tid,
          total: total,
          size: bytes.length,
          sha256: digest,
          name: name,
          isImage: isImage),
      chunks: chunks,
    );
  }
}

class _Incoming {
  MediaManifest? manifest;
  final Map<int, Uint8List> chunks = {};
  int buffered = 0;
  DateTime touched = DateTime.now();
}

/// Buffers manifest + chunks (which may arrive in any order, across multiple
/// transports and store replays) and yields the reassembled, integrity-checked
/// bytes the instant a transfer is complete. Bounded so a peer can't exhaust
/// memory by opening many partial transfers.
class MediaReassembler {
  MediaReassembler({
    this.maxConcurrent = 8,
    this.maxTotalBuffered = 24 * 1024 * 1024,
  });

  final int maxConcurrent;
  final int maxTotalBuffered;

  final Map<String, _Incoming> _transfers = {};

  int get _totalBuffered =>
      _transfers.values.fold(0, (a, t) => a + t.buffered);

  _Incoming _entry(String id) {
    final e = _transfers.putIfAbsent(id, () {
      if (_transfers.length >= maxConcurrent) _evictOldest();
      return _Incoming();
    });
    e.touched = DateTime.now();
    return e;
  }

  void _evictOldest() {
    String? oldest;
    DateTime? when;
    _transfers.forEach((k, v) {
      if (when == null || v.touched.isBefore(when!)) {
        when = v.touched;
        oldest = k;
      }
    });
    if (oldest != null) _transfers.remove(oldest);
  }

  /// Fraction 0..1 of a transfer received (0 if unknown / manifest missing).
  double progress(String idHex) {
    final e = _transfers[idHex];
    if (e == null || e.manifest == null || e.manifest!.total == 0) return 0;
    return (e.chunks.length / e.manifest!.total).clamp(0.0, 1.0);
  }

  /// Registers/updates a manifest. Returns the finished bytes if the chunks
  /// were already all buffered (chunks-before-manifest ordering).
  Uint8List? onManifest(MediaManifest m) {
    final e = _entry(m.idHex);
    e.manifest = m;
    return _tryComplete(m.idHex);
  }

  /// Adds a chunk. Returns the finished bytes when this completes the transfer,
  /// else null. Idempotent: duplicate indices are ignored.
  Uint8List? onChunk(MediaChunkFrame f) {
    final e = _entry(f.idHex);
    if (e.chunks.containsKey(f.index)) return _tryComplete(f.idHex);
    // Reject runaway buffering.
    if (_totalBuffered + f.bytes.length > maxTotalBuffered) {
      _evictOldest();
      if (_totalBuffered + f.bytes.length > maxTotalBuffered) return null;
    }
    e.chunks[f.index] = f.bytes;
    e.buffered += f.bytes.length;
    return _tryComplete(f.idHex);
  }

  Uint8List? _tryComplete(String idHex) {
    final e = _transfers[idHex];
    final m = e?.manifest;
    if (e == null || m == null) return null;
    if (e.chunks.length != m.total) return null;
    for (var i = 0; i < m.total; i++) {
      if (!e.chunks.containsKey(i)) return null;
    }
    final out = Uint8List(m.size);
    var off = 0;
    for (var i = 0; i < m.total; i++) {
      final c = e.chunks[i]!;
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    _transfers.remove(idHex);
    if (off != m.size) return null; // length mismatch → corrupt
    final digest = Uint8List.fromList(crypto.sha256.convert(out).bytes);
    if (!_constEq(digest, m.sha256)) return null; // integrity failure → drop
    return out;
  }

  static bool _constEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }
}

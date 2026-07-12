import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/media_chunking.dart';

/// The definitive-media path: an image is split into encrypted store-and-forward
/// frames so it reaches a receiver who was offline, with NO IPFS and NO need for
/// the sender to be online at fetch time. A framing/reassembly/integrity bug
/// here means a corrupt or never-completing image on-device, so this pins the
/// wire format and the reassembler end-to-end — pure, no network.
void main() {
  Uint8List blob(int n, [int seed = 7]) {
    final r = Random(seed);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  /// Feeds manifest+chunks into a reassembler in [order]; returns the assembled
  /// bytes (or null if it never completed).
  Uint8List? drive(MediaManifest m, List<MediaChunkFrame> chunks, List<int> order,
      {MediaReassembler? into}) {
    final ra = into ?? MediaReassembler();
    Uint8List? done;
    for (final step in order) {
      done ??= step < 0 ? ra.onManifest(m) : ra.onChunk(chunks[step]);
    }
    return done;
  }

  test('manifest round-trips through encode/decode', () {
    final s = MediaChunker.split(blob(200 * 1024), name: 'p h.jpg', isImage: true);
    final back = MediaManifest.decode(s.manifest.encode())!;
    expect(back.idHex, s.manifest.idHex);
    expect(back.total, s.manifest.total);
    expect(back.size, 200 * 1024);
    expect(back.name, 'p h.jpg');
    expect(back.isImage, isTrue);
    expect(back.sha256, s.manifest.sha256);
  });

  test('chunk frame round-trips', () {
    final s = MediaChunker.split(blob(130 * 1024), name: 'x', isImage: false);
    final back = MediaChunkFrame.decode(s.chunks[1].encode())!;
    expect(back.idHex, s.chunks[1].idHex);
    expect(back.index, 1);
    expect(back.bytes, s.chunks[1].bytes);
  });

  test('reassembles byte-exact in order', () {
    final data = blob(300 * 1024);
    final s = MediaChunker.split(data, name: 'a.png', isImage: true);
    expect(s.chunks.length, (300 * 1024 / MediaChunker.chunkPayload).ceil());
    final out = drive(s.manifest, s.chunks,
        [-1, ...List.generate(s.chunks.length, (i) => i)]);
    expect(out, isNotNull);
    expect(out, data, reason: 'the exact original bytes must come back out');
  });

  test('reassembles regardless of arrival order (chunks before manifest, '
      'shuffled, duplicated)', () {
    final data = blob(400 * 1024, 42);
    final s = MediaChunker.split(data, name: 'a', isImage: true);
    final n = s.chunks.length;
    final order = <int>[
      ...List.generate(n, (i) => i)..shuffle(Random(1)), // all chunks first…
      -1, // …manifest last
      0, 1, // duplicates after completion are harmless
    ];
    expect(drive(s.manifest, s.chunks, order), data);
  });

  test('incomplete transfer yields nothing', () {
    final s = MediaChunker.split(blob(300 * 1024), name: 'a', isImage: true);
    final ra = MediaReassembler();
    ra.onManifest(s.manifest);
    for (var i = 0; i < s.chunks.length - 1; i++) {
      expect(ra.onChunk(s.chunks[i]), isNull);
    }
    expect(ra.progress(s.manifest.idHex),
        closeTo((s.chunks.length - 1) / s.chunks.length, 1e-9));
  });

  test('a corrupted chunk fails the integrity check (no bad image surfaces)', () {
    final data = blob(200 * 1024);
    final s = MediaChunker.split(data, name: 'a', isImage: true);
    final ra = MediaReassembler();
    ra.onManifest(s.manifest);
    for (var i = 0; i < s.chunks.length; i++) {
      final c = s.chunks[i];
      final frame = i == 0
          ? MediaChunkFrame(
              transferId: c.transferId,
              index: 0,
              bytes: Uint8List.fromList(c.bytes)..[0] ^= 0xFF) // flip one bit
          : c;
      final out = ra.onChunk(frame);
      expect(out, isNull, reason: 'sha256 mismatch must drop, never return bytes');
    }
  });

  test('decode rejects foreign / truncated content', () {
    expect(MediaManifest.decode(Uint8List.fromList([1, 2, 3])), isNull);
    expect(MediaManifest.decode(Uint8List(63)), isNull, reason: 'bad magic');
    expect(MediaChunkFrame.decode(Uint8List(10)), isNull);
    // real image bytes (JPEG SOI) must not be mistaken for a manifest
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...blob(100)]);
    expect(MediaManifest.decode(jpeg), isNull);
  });

  test('decode rejects an over-large declared size (anti-DoS)', () {
    final s = MediaChunker.split(blob(64 * 1024), name: 'a', isImage: true);
    final enc = s.manifest.encode();
    // Stomp the size field (bytes 24..28) to 2 GB.
    ByteData.sublistView(enc).setUint32(24, 2000 * 1024 * 1024, Endian.big);
    expect(MediaManifest.decode(enc, maxSize: 8 * 1024 * 1024), isNull);
  });

  test('two interleaved transfers stay independent', () {
    final d1 = blob(200 * 1024, 1), d2 = blob(180 * 1024, 2);
    final s1 = MediaChunker.split(d1, name: 'one', isImage: true);
    final s2 = MediaChunker.split(d2, name: 'two', isImage: true);
    final ra = MediaReassembler();
    ra.onManifest(s1.manifest);
    ra.onManifest(s2.manifest);
    Uint8List? o1, o2;
    final maxLen = max(s1.chunks.length, s2.chunks.length);
    for (var i = 0; i < maxLen; i++) {
      if (i < s1.chunks.length) o1 ??= ra.onChunk(s1.chunks[i]);
      if (i < s2.chunks.length) o2 ??= ra.onChunk(s2.chunks[i]);
    }
    expect(o1, d1);
    expect(o2, d2);
  });
}

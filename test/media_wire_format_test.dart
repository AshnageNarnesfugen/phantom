import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/phantom_core.dart';

/// Mirrors PhantomCore.sendFile's CID wire encoding:
/// [name_len(1)][name][size(4 BE)][cid].
Uint8List _wireContent(String name, String cid, {int size = 12345}) {
  final nameBytes = utf8.encode(name);
  final cidBytes = utf8.encode(cid);
  return Uint8List(1 + nameBytes.length + 4 + cidBytes.length)
    ..[0] = nameBytes.length
    ..setAll(1, nameBytes)
    ..[1 + nameBytes.length] = (size >> 24) & 0xff
    ..[2 + nameBytes.length] = (size >> 16) & 0xff
    ..[3 + nameBytes.length] = (size >> 8) & 0xff
    ..[4 + nameBytes.length] = size & 0xff
    ..setAll(5 + nameBytes.length, cidBytes);
}

void main() {
  group('Media wire format', () {
    const cidV0 = 'QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG';
    const cidV1 = 'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi';

    test('round-trip: encode wire → parse back name + size + CID', () {
      final content = _wireContent('photo.jpg', cidV0, size: 2500000);
      final parsed = PhantomCore.tryParseFileWireContent(content);
      expect(parsed, isNotNull);
      expect(parsed!.name, 'photo.jpg');
      expect(parsed.size, 2500000);
      expect(parsed.cid, cidV0);
    });

    test('accepts CIDv1 (bafy…)', () {
      final parsed =
          PhantomCore.tryParseFileWireContent(_wireContent('a.bin', cidV1));
      expect(parsed, isNotNull);
      expect(parsed!.cid, cidV1);
    });

    test('rejects resolved image bytes (PNG header)', () {
      final png = Uint8List.fromList(
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]);
      expect(PhantomCore.tryParseFileWireContent(png), isNull);
    });

    test('rejects resolved file display content (name\\0bytes)', () {
      final display = PhantomCore.encodeFileDisplayContent(
          'voice_123.m4a', Uint8List.fromList(List.filled(64, 7)));
      expect(PhantomCore.tryParseFileWireContent(display), isNull);
    });

    test('rejects garbage and short buffers', () {
      expect(PhantomCore.tryParseFileWireContent(Uint8List(0)), isNull);
      expect(PhantomCore.tryParseFileWireContent(Uint8List(1)), isNull);
      expect(
          PhantomCore.tryParseFileWireContent(
              Uint8List.fromList(utf8.encode('hello world'))),
          isNull);
    });

    test('display format parses back as the widgets expect', () {
      final bytes = Uint8List.fromList(List.generate(32, (i) => i));
      final display = PhantomCore.encodeFileDisplayContent('doc.pdf', bytes);
      final nullIdx = display.indexOf(0);
      expect(nullIdx, utf8.encode('doc.pdf').length);
      expect(utf8.decode(display.sublist(0, nullIdx)), 'doc.pdf');
      expect(display.sublist(nullIdx + 1), bytes);
    });
  });
}

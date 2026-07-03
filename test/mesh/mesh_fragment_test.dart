import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/bluetooth/mesh_protocol.dart';

Uint8List _rand(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  group('MeshFragment / MeshReassembler', () {
    test('round-trip de un payload grande (tamaño INIT ~3699 B) con MTU chico', () {
      final full = _rand(3699, 1);
      final frames = MeshFragment.split(full, chunkSize: 180, groupId: 7);
      expect(frames.length, greaterThan(1));

      final re = MeshReassembler();
      Uint8List? out;
      for (final f in frames) {
        expect(MeshFragment.isFragment(f), isTrue);
        out = re.offer(f) ?? out;
      }
      expect(out, isNotNull);
      expect(out, full);
    });

    test('un paquete que cabe en el MTU pasa crudo, sin fragmentar', () {
      // Un MeshPacket real empieza con magic 'PH', no 'PF'.
      final raw = Uint8List.fromList([kMagic0, kMagic1, 1, 2, 3, 4, 5]);
      final re = MeshReassembler();
      // offer() sobre un no-fragmento lo devuelve tal cual.
      expect(re.offer(raw), raw);
    });

    test('reensambla aunque los fragmentos lleguen desordenados', () {
      final full = _rand(1000, 2);
      final frames = MeshFragment.split(full, chunkSize: 64, groupId: 9)..shuffle(Random(3));
      final re = MeshReassembler();
      Uint8List? out;
      for (final f in frames) {
        out = re.offer(f) ?? out;
      }
      expect(out, full);
    });

    test('un fragmento duplicado no rompe el reensamblaje', () {
      final full = _rand(500, 4);
      final frames = MeshFragment.split(full, chunkSize: 100, groupId: 11);
      final re = MeshReassembler();
      Uint8List? out;
      // Inyecta cada fragmento dos veces.
      for (final f in [...frames, ...frames]) {
        out = re.offer(f) ?? out;
      }
      expect(out, full);
    });

    test('grupos concurrentes distintos no se mezclan', () {
      final a = _rand(400, 5);
      final b = _rand(400, 6);
      final fa = MeshFragment.split(a, chunkSize: 90, groupId: 20);
      final fb = MeshFragment.split(b, chunkSize: 90, groupId: 21);
      final re = MeshReassembler();

      Uint8List? outA, outB;
      // Intercala los fragmentos de ambos grupos.
      final maxLen = max(fa.length, fb.length);
      for (var i = 0; i < maxLen; i++) {
        if (i < fa.length) outA = re.offer(fa[i]) ?? outA;
        if (i < fb.length) outB = re.offer(fb[i]) ?? outB;
      }
      expect(outA, a);
      expect(outB, b);
    });

    test('payload de 1 byte produce exactamente 1 fragmento', () {
      final frames = MeshFragment.split(Uint8List.fromList([42]), chunkSize: 20, groupId: 1);
      expect(frames.length, 1);
      expect(MeshReassembler().offer(frames.first), Uint8List.fromList([42]));
    });
  });
}

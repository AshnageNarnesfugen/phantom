import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/bluetooth/mesh_protocol.dart';
import 'package:phantom_messenger/transport/bluetooth/contact_hint_registry.dart';

const _bob   = 'PBobMeshIdBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _carol = 'PCarolMeshIdCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const _mallory = 'PMalloryStrangerXXXXXXXXXXXXXXXXXXXXXXXXX';

void main() {
  group('ContactHintRegistry — rendezvous hint↔contacto', () {
    test('reconoce el hint de un contacto y lo marca en rango', () {
      final r = ContactHintRegistry()..setContacts([_bob, _carol]);

      final id = r.markInRange(MeshPacket.nodeHint(_bob));
      expect(id, _bob);
      expect(r.isInRange(_bob), isTrue);
      expect(r.isInRange(_carol), isFalse);
      expect(r.inRange(), {_bob});
    });

    test('un hint desconocido no marca a nadie', () {
      final r = ContactHintRegistry()..setContacts([_bob]);
      expect(r.markInRange(MeshPacket.nodeHint(_mallory)), isNull);
      expect(r.inRange(), isEmpty);
    });

    test('caduca fuera del TTL', () {
      final r = ContactHintRegistry(inRangeTtl: const Duration(seconds: 90))
        ..setContacts([_bob]);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      r.markInRange(MeshPacket.nodeHint(_bob), now: t0);

      expect(r.isInRange(_bob, now: t0.add(const Duration(seconds: 60))), isTrue);
      expect(r.isInRange(_bob, now: t0.add(const Duration(seconds: 120))), isFalse);
    });

    test('prune devuelve los que salieron de rango', () {
      final r = ContactHintRegistry(inRangeTtl: const Duration(seconds: 90))
        ..setContacts([_bob, _carol]);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      r.markInRange(MeshPacket.nodeHint(_bob), now: t0);
      r.markInRange(MeshPacket.nodeHint(_carol),
          now: t0.add(const Duration(seconds: 80)));

      // A t0+100s: Bob caducó (100 > 90), Carol sigue (20 < 90).
      final gone = r.prune(now: t0.add(const Duration(seconds: 100)));
      expect(gone, {_bob});
      expect(r.inRange(now: t0.add(const Duration(seconds: 100))), {_carol});
    });

    test('re-marcar refresca el TTL (contacto que sigue al lado)', () {
      final r = ContactHintRegistry(inRangeTtl: const Duration(seconds: 90))
        ..setContacts([_bob]);
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      r.markInRange(MeshPacket.nodeHint(_bob), now: t0);
      // Avistamiento nuevo a t0+60s.
      r.markInRange(MeshPacket.nodeHint(_bob), now: t0.add(const Duration(seconds: 60)));
      // A t0+120s seguiría en rango porque el último avistamiento fue a +60.
      expect(r.isInRange(_bob, now: t0.add(const Duration(seconds: 120))), isTrue);
    });

    test('setContacts olvida el en-rango de contactos borrados de la libreta', () {
      final r = ContactHintRegistry()..setContacts([_bob, _carol]);
      r.markInRange(MeshPacket.nodeHint(_bob));
      r.markInRange(MeshPacket.nodeHint(_carol));
      expect(r.inRange(), {_bob, _carol});

      // Bob se elimina de la libreta.
      r.setContacts([_carol]);
      expect(r.inRange(), {_carol});
      expect(r.contactForHint(MeshPacket.nodeHint(_bob)), isNull);
    });

    test('contactForHint hace la búsqueda inversa', () {
      final r = ContactHintRegistry()..setContacts([_bob, _carol]);
      expect(r.contactForHint(MeshPacket.nodeHint(_carol)), _carol);
      expect(r.contactForHint(MeshPacket.nodeHint(_mallory)), isNull);
    });
  });
}

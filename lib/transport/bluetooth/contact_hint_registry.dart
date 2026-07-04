import 'dart:typed_data';
import 'mesh_protocol.dart';

/// Cruza los `nodeHint` que se ven por Bluetooth con la libreta de contactos,
/// y lleva la cuenta de qué contactos están "en rango" ahora.
///
/// Es el eslabón que faltaba para el rendezvous del mesh: un anuncio BLE solo
/// lleva un hash de 4 bytes del phantomId (anónimo, no reversible). Sin cruzarlo
/// con nuestros contactos, el mesh podía enrutar mensajes por hint pero no sabía
/// "este de aquí al lado es Bob" — así que no había forma de mostrar a Bob en
/// línea por Bluetooth ni de preferir el mesh cuando está cerca.
///
/// Puro y sin dependencias de plataforma → totalmente testeable (el
/// BluetoothMeshTransport delega aquí, igual que en MeshFragment).
///
/// Nota: el hint son 4 bytes (FNV-1a truncado), así que hay colisiones posibles
/// pero raras. Para presencia el peor caso es un "cerca" falso ocasional; el
/// contenido sigue protegido por el ratchet (un impostor con hint colisionado
/// no puede descifrar nada).
class ContactHintRegistry {
  /// Cuánto se considera "en rango" un contacto tras el último avistamiento.
  /// Los anuncios BLE se repiten cada pocos segundos; 90 s tolera huecos de
  /// scan sin parpadear el estado.
  final Duration inRangeTtl;

  ContactHintRegistry({this.inRangeTtl = const Duration(seconds: 90)});

  // hintHex → phantomId (un hint podría, en teoría, mapear a varios contactos
  // por colisión; guardamos el último registrado, suficiente para presencia).
  final Map<String, String> _hintToContact = {};
  // phantomId → última vez visto en rango.
  final Map<String, DateTime> _lastSeen = {};

  /// (Re)construye el índice hint→contacto desde la libreta.
  void setContacts(Iterable<String> phantomIds) {
    _hintToContact.clear();
    for (final id in phantomIds) {
      _hintToContact[_hex(MeshPacket.nodeHint(id))] = id;
    }
    // Olvida "en rango" de contactos que ya no están en la libreta.
    _lastSeen.removeWhere((id, _) => !_hintToContact.containsValue(id));
  }

  /// Contacto cuyo hint coincide con [hint], o null si no es un contacto nuestro.
  String? contactForHint(Uint8List hint) => _hintToContact[_hex(hint)];

  /// Registra que se vio [hint] en rango. Devuelve el phantomId del contacto
  /// si el hint es de uno conocido (para disparar presencia / envío por mesh),
  /// o null si el hint no corresponde a ningún contacto.
  String? markInRange(Uint8List hint, {DateTime? now}) {
    final id = _hintToContact[_hex(hint)];
    if (id == null) return null;
    _lastSeen[id] = now ?? DateTime.now();
    return id;
  }

  /// ¿Está este contacto en rango de Bluetooth ahora (dentro del TTL)?
  bool isInRange(String phantomId, {DateTime? now}) {
    final ts = _lastSeen[phantomId];
    if (ts == null) return false;
    return (now ?? DateTime.now()).difference(ts) < inRangeTtl;
  }

  /// Conjunto de contactos en rango ahora mismo.
  Set<String> inRange({DateTime? now}) {
    final t = now ?? DateTime.now();
    return _lastSeen.entries
        .where((e) => t.difference(e.value) < inRangeTtl)
        .map((e) => e.key)
        .toSet();
  }

  /// Elimina las entradas caducadas y devuelve los contactos que acaban de
  /// salir de rango (para emitir "se fue" y refrescar la presencia).
  Set<String> prune({DateTime? now}) {
    final t = now ?? DateTime.now();
    final gone = _lastSeen.entries
        .where((e) => t.difference(e.value) >= inRangeTtl)
        .map((e) => e.key)
        .toSet();
    _lastSeen.removeWhere((_, ts) => t.difference(ts) >= inRangeTtl);
    return gone;
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

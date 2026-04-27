import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Capa de transporte abstracta.
///
/// Soporta múltiples backends con detección automática y fallback:
///   1. Yggdrasil (mesh IPv6 — mejor latencia, sin servidor central)
///   2. I2P (máxima privacidad — routing en capas, más lento)
///   3. IPFS pubsub (descentralizado — funciona sin nodos dedicados)
///
/// La app prueba en ese orden y usa el primero disponible.
/// El usuario puede forzar un transporte específico en settings.

// ── Interfaz abstracta ────────────────────────────────────────────────────────

abstract class PhantomTransport {
  String get name;
  bool get isAvailable;

  /// Publica un mensaje cifrado dirigido a [recipientId].
  /// El transporte NO sabe el contenido — solo maneja bytes.
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  });

  /// Suscribe a mensajes entrantes para [ourId].
  /// Devuelve un stream de envelopes cifrados sin descifrar.
  Stream<IncomingEnvelope> subscribe({required String ourId});

  /// Verifica disponibilidad del transporte.
  Future<bool> checkAvailability();

  Future<void> dispose();
}

@immutable
class IncomingEnvelope {
  final Uint8List data;
  final String transportName;
  final DateTime receivedAt;

  const IncomingEnvelope({
    required this.data,
    required this.transportName,
    required this.receivedAt,
  });
}

// ── Transport Manager ─────────────────────────────────────────────────────────

class TransportManager {
  final List<PhantomTransport> _transports;
  PhantomTransport? _activeTransport;
  final StreamController<IncomingEnvelope> _incomingController =
      StreamController.broadcast();

  Stream<IncomingEnvelope> get incoming => _incomingController.stream;
  String? get activeTransportName => _activeTransport?.name;

  TransportManager({
    String? ipfsApiUrl,
    String? i2pSocksHost,
    int? i2pSocksPort,
    String? yggdrasilAddress,
  }) : _transports = [
          if (yggdrasilAddress != null)
            YggdrasilTransport(address: yggdrasilAddress),
          if (i2pSocksHost != null && i2pSocksPort != null)
            I2PTransport(socksHost: i2pSocksHost, socksPort: i2pSocksPort),
          IpfsTransport(apiUrl: ipfsApiUrl ?? 'http://127.0.0.1:5001'),
        ];

  /// Inicializa y selecciona el mejor transporte disponible.
  Future<void> initialize({required String ourId}) async {
    for (final transport in _transports) {
      final available = await transport.checkAvailability();
      if (available) {
        _activeTransport = transport;
        // Iniciar escucha en background
        transport.subscribe(ourId: ourId).listen(
          _incomingController.add,
          onError: (e) => _handleTransportError(e),
        );
        return;
      }
    }
    throw const TransportException(
        'Ningún transporte disponible. Asegúrate de que IPFS, I2P o Yggdrasil estén corriendo.');
  }

  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    final transport = _activeTransport;
    if (transport == null) {
      throw const TransportException('TransportManager no inicializado.');
    }
    await transport.publish(
      recipientId: recipientId,
      encryptedEnvelope: encryptedEnvelope,
    );
  }

  void _handleTransportError(dynamic error) {
    // En producción: intentar fallback al siguiente transporte
    // Por ahora solo propagamos el error
    _incomingController.addError(error);
  }

  Future<void> dispose() async {
    for (final t in _transports) {
      await t.dispose();
    }
    await _incomingController.close();
  }
}

// ── IPFS Transport ────────────────────────────────────────────────────────────

/// Transporte sobre IPFS pubsub.
///
/// Cada usuario tiene un topic IPFS derivado de su PhantomID.
/// Los mensajes se publican como bytes crudos en el topic del destinatario.
///
/// Requiere nodo IPFS local con:
///   - ipfs config --json Experimental.Pubsub true
///   - ipfs daemon --enable-pubsub-experiment
class IpfsTransport implements PhantomTransport {
  final String _apiUrl;
  final http.Client _client = http.Client();
  StreamSubscription? _sub;

  @override
  final String name = 'ipfs-pubsub';

  @override
  bool get isAvailable => true; // se verifica en checkAvailability()

  IpfsTransport({required String apiUrl}) : _apiUrl = apiUrl;

  @override
  Future<bool> checkAvailability() async {
    try {
      final resp = await _client
          .post(Uri.parse('$_apiUrl/api/v0/id'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    final topic = _topicForId(recipientId);
    // IPFS pubsub publish espera el mensaje como multipart form
    final uri = Uri.parse('$_apiUrl/api/v0/pubsub/pub?arg=${Uri.encodeComponent(topic)}');
    final response = await _client.post(
      uri,
      body: encryptedEnvelope,
      headers: {'Content-Type': 'application/octet-stream'},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw TransportException(
          'IPFS publish falló: ${response.statusCode} ${response.body}');
    }
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    final topic = _topicForId(ourId);
    final uri = Uri.parse(
        '$_apiUrl/api/v0/pubsub/sub?arg=${Uri.encodeComponent(topic)}');

    // IPFS pubsub sub devuelve NDJSON (una línea JSON por mensaje).
    // LineSplitter maneja correctamente chunks parciales y multi-línea.
    final request = http.Request('POST', uri);
    final response = await _client.send(request);

    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final data = base64.decode(json['data'] as String);
        yield IncomingEnvelope(
          data: data,
          transportName: name,
          receivedAt: DateTime.now(),
        );
      } catch (_) {
        continue;
      }
    }
  }

  /// Topic IPFS = '/phantom/v1/{phantomId}'
  static String _topicForId(String phantomId) => '/phantom/v1/$phantomId';

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _client.close();
  }
}

// ── I2P Transport ─────────────────────────────────────────────────────────────

/// Transporte sobre I2P via SOCKS5 proxy local.
///
/// I2P debe estar corriendo localmente como daemon.
/// La app se conecta via SOCKS5 (default: 127.0.0.1:4447).
///
/// Para mensajería sobre I2P, usamos I2P HTTP proxy para comunicarse
/// con un servicio de relay anónimo en I2P (Eepsite).
/// En implementación completa, cada usuario corre su propio eepsite.
class I2PTransport implements PhantomTransport {
  final String socksHost;
  final int socksPort;

  @override
  final String name = 'i2p-socks5';

  @override
  bool get isAvailable => true;

  I2PTransport({required this.socksHost, required this.socksPort});

  @override
  Future<bool> checkAvailability() async {
    try {
      // Intentar conectar al proxy SOCKS5
      // Si I2P no está corriendo, la conexión falla
      // En Flutter, usamos dart:io Socket para verificar
      // (simplificado aquí para claridad)
      return await _checkSocksProxy();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkSocksProxy() async {
    // En implementación real: abrir socket TCP a _socksHost:_socksPort
    // y verificar handshake SOCKS5
    // Placeholder — el código real usa dart:io
    return false; // desactivado hasta que I2P esté corriendo
  }

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    // En I2P, el destinatario tiene una dirección .i2p derivada de su ID
    // Implementación completa: enviar via I2P HTTP API o SAM bridge
    throw UnimplementedError('I2P publish — implementar con SAM bridge o I2P HTTP proxy');
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    // En I2P: escuchar en nuestro destino I2P
    // Implementación completa: I2P SAM (Simple Anonymous Messaging) API
    throw UnimplementedError('I2P subscribe — implementar con SAM bridge');
  }

  @override
  Future<void> dispose() async {}
}

// ── Yggdrasil Transport ───────────────────────────────────────────────────────

/// Transporte sobre red Yggdrasil (mesh IPv6 cifrada).
///
/// Yggdrasil asigna una dirección IPv6 permanente derivada del keypair.
/// Los mensajes se envían directamente peer-to-peer sobre TCP/IPv6.
///
/// Ventajas sobre IPFS/I2P:
///   - Latencia menor (routing directo)
///   - Sin servidor intermediario
///   - Dirección estática derivada de identidad
///
/// Requiere Yggdrasil corriendo como daemon del sistema.
class YggdrasilTransport implements PhantomTransport {
  final String address; // dirección IPv6 Yggdrasil propia
  static const int listenPort = 7331; // puerto Phantom sobre Yggdrasil

  @override
  final String name = 'yggdrasil-direct';

  @override
  bool get isAvailable => true;

  YggdrasilTransport({required this.address});

  @override
  Future<bool> checkAvailability() async {
    // Verificar que Yggdrasil esté activo: ping a la dirección propia
    // En implementación real: dart:io RawServerSocket sobre IPv6
    try {
      return await _checkYggdrasilInterface();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkYggdrasilInterface() async {
    // Placeholder — el código real abre un socket UDP en _ourAddress:_listenPort
    return false;
  }

  @override
  Future<void> publish({
    required String recipientId,
    required Uint8List encryptedEnvelope,
  }) async {
    // En Yggdrasil: la dirección IPv6 del destinatario se deriva de su PhantomID
    // Implementación completa: TCP stream sobre IPv6 Yggdrasil
    throw UnimplementedError('Yggdrasil publish — implementar con dart:io socket IPv6');
  }

  @override
  Stream<IncomingEnvelope> subscribe({required String ourId}) async* {
    // Escuchar en _ourAddress:_listenPort
    throw UnimplementedError('Yggdrasil subscribe — implementar con ServerSocket IPv6');
  }

  @override
  Future<void> dispose() async {}
}

class TransportException implements Exception {
  final String message;
  const TransportException(this.message);
  @override
  String toString() => 'TransportException: $message';
}

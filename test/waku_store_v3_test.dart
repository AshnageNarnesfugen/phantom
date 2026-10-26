import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/waku_daemon.dart';

/// Store v3 contra un REST falso con la forma EXACTA que devolvió el daemon
/// de go-waku master en el teléfono (capturada con `adb forward` el
/// 2026-10-26): sobre snake_case con status_code numérico, pero el
/// WakuMessage anidado en estilo protojson — camelCase y `timestamp` como
/// STRING. Un fixture con timestamp numérico (el primero que escribí) pasaba
/// mientras cada consulta real tronaba con "String is not a subtype of num?".
///
/// Motivo: status.prod dejó de montar el store legacy
/// (/vac/waku/store/2.0.0-beta4) y go-waku v0.9.0 solo habla ese. En campo
/// (2026-10-26) cada consulta respondía "protocols not supported": sin buzón
/// offline y sin confirmación de publish.
///
/// Sin TestWidgetsFlutterBinding a propósito: sustituye HttpClient por un mock
/// que responde 400 a todo (ver LAB.md).
void main() {
  late HttpServer server;
  late List<Uri> requests;
  late Future<void> Function(HttpRequest) handler;

  setUp(() async {
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req.uri);
      await handler(req);
      await req.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  WakuDaemon daemon() =>
      WakuDaemon.forApiUrl('http://127.0.0.1:${server.port}');

  final payloadA = Uint8List.fromList(List.generate(40, (i) => i * 7 & 0xff));
  final payloadB = Uint8List.fromList(List.generate(33, (i) => 255 - i));

  test('v3: pide includeData, nombra un store node y lee el payload anidado',
      () async {
    handler = (req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'request_id': 'x',
        'status_code': 200,
        'status_desc': 'OK',
        'messages': [
          {
            'message_hash': base64Encode(List.filled(32, 1)),
            'message': {
              'payload': base64Encode(payloadA),
              'contentTopic': '/phantom/1/abc/proto',
              'version': 0,
              'timestamp': '1700000000000000000',
              'meta': '',
              'ephemeral': false,
              'rateLimitProof': '',
            },
            'pubsub_topic': '/waku/2/rs/16/32',
          },
          {
            'message_hash': base64Encode(List.filled(32, 2)),
            'message': {
              'payload': base64Encode(payloadB),
              'contentTopic': '/phantom/1/abc/proto',
              'timestamp': '1700000000000000001',
            },
          },
          // Sin data (includeData olvidado o hash-only): se ignora.
          {'message_hash': base64Encode(List.filled(32, 3))},
        ],
      }));
    };
    final out = await daemon().storeQuery(
      contentTopic: '/phantom/1/abc/proto',
      startTime: DateTime.fromMicrosecondsSinceEpoch(1700000000000000),
    );
    expect(out, isNotNull);
    expect(out!.map((m) => m.payload), [payloadA, payloadB]);
    expect(out.first.timestampNs, 1700000000000000000);

    final q = requests.single;
    expect(q.path, '/store/v3/messages');
    expect(q.queryParameters['includeData'], 'true');
    expect(q.queryParameters['pubsubTopic'], WakuDaemon.defaultPubsubTopic);
    expect(q.queryParameters['contentTopics'], '/phantom/1/abc/proto');
    expect(q.queryParameters['startTime'], '1700000000000000000');
    expect(WakuDaemon.pinnedStoreNodes, contains(q.queryParameters['peerAddr']));
  });

  test('v3 con error del nodo: null (no "sin mensajes") y rota de store node',
      () async {
    handler = (req) async {
      req.response.statusCode = 500;
      req.response.write(jsonEncode({
        'messages': null,
        'error_message': 'failed to dial: no route',
      }));
    };
    final d = daemon();
    expect(await d.storeQuery(contentTopic: '/t'), isNull,
        reason: 'un fallo no debe avanzar el cursor como si no hubiera nada');
    expect(await d.storeQuery(contentTopic: '/t'), isNull);
    expect(requests.map((u) => u.path).toSet(), {'/store/v3/messages'},
        reason: 'un 500 con JSON es v3 respondiendo, no un daemon sin v3');
    expect(requests[0].queryParameters['peerAddr'],
        isNot(requests[1].queryParameters['peerAddr']));
  });

  test('daemon v0.9.0 (sin ruta v3): cae a /store/v1 y lo recuerda', () async {
    handler = (req) async {
      if (req.uri.path == '/store/v3/messages') {
        req.response.statusCode = 404;
        req.response.write('404 page not found\n');
        return;
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'messages': [
          {'payload': base64Encode(payloadA), 'timestamp': 42},
        ],
      }));
    };
    final d = daemon();
    final first = await d.storeQuery(contentTopic: '/t');
    expect(first!.single.payload, payloadA);
    await d.storeQuery(contentTopic: '/t');
    expect(requests.map((u) => u.path),
        ['/store/v3/messages', '/store/v1/messages', '/store/v1/messages']);
  });
}

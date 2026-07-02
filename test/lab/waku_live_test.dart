@Timeout(Duration(minutes: 10))
library;

// Lab de red REAL en el escritorio — sin dispositivos, sin APKs.
//
// Levanta dos daemons go-waku locales con EXACTAMENTE los mismos flags que
// usan los teléfonos (WakuDaemon.launchArgs) y ejercita la capa de la app
// (WakuTransport: publish confirmado por store + subscribe con backlog)
// contra el fleet status.prod real:
//
//   1. ambos daemons consiguen peers del fleet (DNS discovery + static),
//   2. el publish de A queda CONFIRMADO en el store del fleet,
//   3. un nodo RECIÉN NACIDO (B) recupera ese mensaje vía el backlog del
//      store — el caso "Alice estaba offline cuando Bob envió",
//   4. un segundo publish llega a B por gossip en vivo.
//
// Requiere el binario go-waku linux: tool/bin/waku (o env PHANTOM_WAKU_BIN).
//   gh release download v0.9.0 -R waku-org/go-waku -p '*x86_64.deb'
//   ar x gowaku-*.deb && tar xf data.tar.gz && cp usr/bin/waku tool/bin/
//
// IMPORTANTE: no usa TestWidgetsFlutterBinding — ese binding sustituye
// HttpClient por un mock que responde 400 a todo, lo que mataría las
// llamadas REST reales al daemon.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/waku_daemon.dart';
import 'package:phantom_messenger/transport/transport.dart';

String? _findBinary() {
  final env = Platform.environment['PHANTOM_WAKU_BIN'];
  if (env != null && File(env).existsSync()) return env;
  final local = '${Directory.current.path}/tool/bin/waku';
  if (File(local).existsSync()) return local;
  return null;
}

class _LabNode {
  final Process process;
  final WakuDaemon client;
  final Directory dataDir;
  final StringBuffer log = StringBuffer();
  _LabNode(this.process, this.client, this.dataDir);

  Future<void> stop() async {
    process.kill();
    try {
      await dataDir.delete(recursive: true);
    } catch (_) {}
  }
}

Future<_LabNode> _spawn(String binary, {required int restPort}) async {
  final dir = await Directory.systemTemp.createTemp('phantom_waku_lab_');
  final proc = await Process.start(
    binary,
    WakuDaemon.launchArgs(dataDir: dir.path, restPort: restPort),
    environment: {...Platform.environment, 'HOME': dir.path},
  );
  final node =
      _LabNode(proc, WakuDaemon.forApiUrl('http://127.0.0.1:$restPort'), dir);
  proc.stdout.transform(utf8.decoder).listen(node.log.write);
  proc.stderr.transform(utf8.decoder).listen(node.log.write);

  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final st = await node.client.status();
    if (st.running) return node;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  proc.kill();
  fail('go-waku no levantó su REST API en :$restPort.\n${node.log}');
}

Future<int> _waitForPeers(_LabNode node,
    {Duration timeout = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final st = await node.client.status();
    if (st.peers > 0) return st.peers;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return 0;
}

void main() {
  final binary = _findBinary();

  test('WakuTransport contra el fleet status.prod: store offline + gossip vivo',
      () async {
    HttpOverrides.global = null;

    final rnd = Random.secure();
    // Juega el papel del phantomId del receptor: define el content topic.
    final labUser =
        'lab${List.generate(12, (_) => rnd.nextInt(36).toRadixString(36)).join()}';
    final payloadStore =
        Uint8List.fromList(utf8.encode('phantom-lab-store-$labUser'));
    final payloadLive =
        Uint8List.fromList(utf8.encode('phantom-lab-live-$labUser'));

    // ── Nodo A ("Bob", el emisor) ─────────────────────────────────────────
    final a = await _spawn(binary!, restPort: 18645);
    try {
      expect(await _waitForPeers(a), greaterThan(0),
          reason: 'A nunca consiguió peers del fleet status.prod — '
              '¿DNS discovery roto? ¿red bloqueando tcp/30303?\n${a.log}');

      final ta = WakuTransport(daemon: a.client);
      expect(await ta.checkAvailability(), isTrue);

      // ── Publish con confirmación, mientras "Alice" (B) aún NO EXISTE ────
      // WakuTransport.publish lanza si el payload nunca aparece en el store
      // del fleet — si esto no lanza, la entrega offline está garantizada.
      await ta.publish(recipientId: labUser, encryptedEnvelope: payloadStore);

      // ── Nodo B ("Alice", nace DESPUÉS del envío) ────────────────────────
      final b = await _spawn(binary, restPort: 18647);
      try {
        expect(await _waitForPeers(b), greaterThan(0),
            reason: 'B nunca consiguió peers del fleet\n${b.log}');

        final tb = WakuTransport(daemon: b.client);
        expect(await tb.checkAvailability(), isTrue);

        // El subscribe de la app: backlog del store (con reintentos) + relay
        // en vivo, todo por el mismo stream.
        final received = <IncomingEnvelope>[];
        final sub = tb.subscribe(ourId: labUser).listen(received.add);

        bool got(Uint8List payload) => received
            .any((e) => utf8.decode(e.data, allowMalformed: true) ==
                utf8.decode(payload));

        // 1) El mensaje enviado antes de que B existiera debe llegar por el
        //    backlog del store.
        final storeDeadline = DateTime.now().add(const Duration(seconds: 150));
        while (!got(payloadStore) && DateTime.now().isBefore(storeDeadline)) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        expect(got(payloadStore), isTrue,
            reason: 'B (recién nacido) no recibió vía store el mensaje que A '
                'publicó antes de que B existiera — la entrega offline NO '
                'funciona.\n--- transportes de B ---\n${b.log}');

        // 2) Gossip en vivo: A publica ahora que B está suscrito.
        await ta.publish(recipientId: labUser, encryptedEnvelope: payloadLive);
        final liveDeadline = DateTime.now().add(const Duration(seconds: 90));
        while (!got(payloadLive) && DateTime.now().isBefore(liveDeadline)) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        expect(got(payloadLive), isTrue,
            reason: 'B nunca recibió por gossip en vivo lo que A publicó — '
                'la mensajería en tiempo real por Waku NO funciona');

        await sub.cancel();
        await tb.dispose();
      } finally {
        await b.stop();
      }
      await ta.dispose();
    } finally {
      await a.stop();
    }
  },
      skip: binary == null
          ? 'go-waku no encontrado: pon el binario en tool/bin/waku o '
              'exporta PHANTOM_WAKU_BIN (ver cabecera de este archivo)'
          : false);
}

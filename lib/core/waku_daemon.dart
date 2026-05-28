import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'transport_debugger.dart';

/// Manages the bundled go-waku daemon on Android for message relay/store.
///
/// Architecture role: Waku handles ALL real-time messaging (text, handshakes,
/// metadata). IPFS is relegated to file transfer only (on-demand).
///
/// Key advantage over IPFS PubSub: Waku has built-in Store-and-Forward,
/// meaning messages persist on relay nodes for up to 30 days. If Alice
/// sends a message while Bob is offline, the message waits in the Waku
/// network until Bob comes back online. This eliminates the "synchronous
/// presence" problem that plagued the IPFS PubSub approach.
///
/// The daemon binary ships as `libgowaku.so` in jniLibs (c-shared build)
/// or alternatively via the `gowaku.aar` gomobile bindings.
class WakuDaemon {
  static const _ch = MethodChannel('phantom/waku_daemon');

  static final instance = WakuDaemon._();
  WakuDaemon._();

  bool _ensured = false;
  bool _binaryMissing = false;
  Process? _directProcess;
  final _logBuf = StringBuffer();

  String? _dynamicApiUrl;
  String get apiUrl => _dynamicApiUrl ?? 'http://127.0.0.1:8645';

  /// True after [ensure] determined that `libgowaku.so` is not bundled.
  /// UI uses this to show "binary not bundled" instead of a generic
  /// "offline", so the user knows Waku is missing for build reasons
  /// rather than a runtime fault.
  bool get binaryMissing => _binaryMissing;

  /// Last captured output from the Waku process.
  String get daemonLog => _logBuf.isEmpty ? '(no output)' : _logBuf.toString();

  /// Idempotent setup: start ForegroundService → fall back to direct spawn.
  /// Never throws — failures are logged and Waku is silently skipped;
  /// the transport manager will fall back to IPFS PubSub for messaging.
  Future<void> ensure() async {
    if (!Platform.isAndroid || _ensured) return;
    _ensured = true;

    try {
      _logBuf.clear();

      // Fast path: daemon already running from persistent service
      final alreadyRunning = await _waitForApi(seconds: 1);
      if (alreadyRunning) {
        _logBuf.writeln('[init] Waku already running — reusing');
        debugPrint('[WakuDaemon] API already up — skipping spawn');
        return;
      }

      final libDir = await _ch.invokeMethod<String>('getNativeLibDir') ?? '';
      final binary = '$libDir/libgowaku.so';

      _logBuf.writeln('[init] nativeLibDir: $libDir');
      _logBuf.writeln('[init] binary path:  $binary');
      _logBuf.writeln('[init] binary exists: ${File(binary).existsSync()}');

      if (!File(binary).existsSync()) {
        _logBuf.writeln('[init] WARNING: libgowaku.so not found — Waku disabled');
        _binaryMissing = true;
        _ensured = false;
        return;
      }
      _binaryMissing = false;

      final dataDir = await _dataDir();
      _logBuf.writeln('[init] data dir: $dataDir');

      // Try the ForegroundService first (survives app backgrounding)
      bool serviceStarted = false;
      try {
        await _ch.invokeMethod<void>('startService', {
          'binaryPath': binary,
          'dataDir':    dataDir,
        });
        serviceStarted = true;
        _logBuf.writeln('[init] WakuForegroundService started');
      } catch (e) {
        _logBuf.writeln('[init] WakuForegroundService error: $e');
      }

      // Give the service time to bring the REST API up
      final apiReady = serviceStarted
          ? await _waitForApi(seconds: 5)
          : false;

      _logBuf.writeln('[init] API ready via service: $apiReady');

      if (!apiReady) {
        _logBuf.writeln('[init] spawning Waku directly...');
        await _spawnDirectly(binary, dataDir);
      } else {
        // Read the dynamic port from the native side
        await _readApiPort();
        _logBuf.writeln('[init] using WakuForegroundService daemon');
      }
    } catch (e, st) {
      _logBuf.writeln('[init] EXCEPTION: $e\n$st');
      _ensured = false;
    }
  }

  /// Reads the dynamically-assigned REST API port from the Kotlin service.
  Future<void> _readApiPort() async {
    try {
      final port = await _ch.invokeMethod<String>('getApiPort');
      if (port != null && port.isNotEmpty) {
        _dynamicApiUrl = 'http://127.0.0.1:$port';
        _logBuf.writeln('[init] Waku REST API on port $port');
      }
    } catch (e) {
      debugPrint('[WakuDaemon] Failed to read API port: $e');
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _directProcess?.kill();
    _directProcess = null;
    try {
      await _ch.invokeMethod<void>('stopService');
    } catch (e) {
      debugPrint('[WakuDaemon] stopService error: $e');
    }
    _ensured = false;
  }

  // ── Waku REST API methods ──────────────────────────────────────────────────

  /// Waku has two layers of topics that we kept conflating:
  ///   - pubsub topic: gossipsub routing layer. The daemon subscribes to ONE
  ///     by default (`/waku/2/default-waku/proto`); that's where peers form
  ///     a mesh and gossip messages.
  ///   - content topic: application-level filter inside each WakuMessage.
  ///     We use `/phantom/1/<phantomId>/proto` so a receiver can pick out
  ///     messages addressed to them from the shared pubsub firehose.
  ///
  /// The go-waku REST API needs the *pubsub* topic in the URL path
  /// (URL-encoded), and the content topic in the message body. Earlier
  /// versions of this file passed the content topic to the URL path and
  /// to /relay/v1/subscriptions, which returned 404 ("relayPublish failed"
  /// with no body) and silently subscribed to nothing.
  static const String defaultPubsubTopic = '/waku/2/default-waku/proto';

  /// Publishes [payload] tagged with [contentTopic] to the Waku relay.
  ///
  /// Uses go-waku's auto-sharded endpoint — `/relay/v1/auto/messages` —
  /// which figures out the pubsub topic from the content topic on the
  /// server side. The non-auto variant requires the pubsub topic in the
  /// URL path, but the `%2F` encoding of the topic's leading slashes hits
  /// router-level routing inconsistencies (chi-mux et al. don't reliably
  /// decode `%2F` inside path params), which manifested as a generic 404
  /// and an opaque "Waku relay publish failed".
  Future<bool> relayPublish({
    required String contentTopic,
    required Uint8List payload,
    String pubsubTopic = defaultPubsubTopic,
  }) async {
    final dbg = TransportDebugger.instance;
    final url = '$apiUrl/relay/v1/auto/messages';
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;

      final body = jsonEncode({
        'payload': base64Encode(payload),
        'contentTopic': contentTopic,
        'timestamp': DateTime.now().microsecondsSinceEpoch * 1000, // nanoseconds
      });
      req.write(body);

      final resp = await req.close();
      final respBody = await resp.transform(utf8.decoder).join();
      client.close(force: true);

      if (resp.statusCode == 200) return true;
      // Surface the actual server response so we can diagnose without
      // shipping another build. Truncate so a verbose HTML error page
      // doesn't blow up the log buffer.
      final preview = respBody.length > 200 ? '${respBody.substring(0, 200)}…' : respBody;
      dbg.log('Waku: publish HTTP ${resp.statusCode} body="$preview" url=$url');
      return false;
    } catch (e) {
      dbg.log('Waku: publish exception $e url=$url');
      return false;
    }
  }

  /// Subscribes to [contentTopic] via the auto-sharded endpoint and yields
  /// payloads as they arrive. REST API uses polling — we GET from
  /// `/relay/v1/auto/messages/{contentTopic}` every [intervalMs]. The server
  /// resolves the underlying pubsub topic from the content topic.
  Stream<Uint8List> relaySubscribe({
    required String contentTopic,
    String pubsubTopic = defaultPubsubTopic, // kept for backward compat, unused
    int intervalMs = 500,
  }) {
    final dbg = TransportDebugger.instance;
    final controller = StreamController<Uint8List>();
    bool running = true;

    () async {
      // Register the content topic with the auto-subscriptions endpoint.
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        final url = '$apiUrl/relay/v1/auto/subscriptions';
        final req = await client.postUrl(Uri.parse(url));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode([contentTopic]));
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        client.close(force: true);
        if (resp.statusCode != 200) {
          final preview = body.length > 200 ? '${body.substring(0, 200)}…' : body;
          dbg.log('Waku: subscribe HTTP ${resp.statusCode} body="$preview"');
        }
      } catch (e) {
        dbg.log('Waku: subscribe exception $e');
      }

      // Poll messages addressed to this content topic.
      final encodedTopic = Uri.encodeComponent(contentTopic);
      final pollUrl = '$apiUrl/relay/v1/auto/messages/$encodedTopic';
      while (running && !controller.isClosed) {
        try {
          final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
          final req = await client.getUrl(Uri.parse(pollUrl));
          final resp = await req.close();
          final body = await resp.transform(utf8.decoder).join();
          client.close(force: true);

          if (resp.statusCode == 200 && body.isNotEmpty) {
            final List<dynamic> messages = jsonDecode(body);
            for (final msg in messages) {
              if (msg is! Map) continue;
              final payload = msg['payload'] as String?;
              if (payload != null && payload.isNotEmpty) {
                controller.add(base64Decode(payload));
              }
            }
          }
        } catch (e) {
          // poll errors are spammy at intervalMs cadence; log to debug only.
          debugPrint('[WakuDaemon] poll error: $e');
        }
        await Future.delayed(Duration(milliseconds: intervalMs));
      }
      await controller.close();
    }();

    controller.onCancel = () => running = false;
    return controller.stream;
  }

  /// Queries the Waku Store protocol for historical messages on a content topic.
  /// This is the key feature that solves the "synchronous presence" problem:
  /// messages sent while we were offline are retrieved from store nodes.
  Future<List<Uint8List>> storeQuery({
    required String contentTopic,
    DateTime? startTime,
    int pageSize = 100,
  }) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

      final params = <String, String>{
        'contentTopics': contentTopic,
        'pageSize': '$pageSize',
        'ascending': 'true',
      };
      if (startTime != null) {
        params['startTime'] = '${startTime.microsecondsSinceEpoch * 1000}';
      }

      final uri = Uri.parse('$apiUrl/store/v1/messages').replace(queryParameters: params);
      final req = await client.getUrl(uri);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);

      if (resp.statusCode != 200) {
        debugPrint('[WakuDaemon] storeQuery failed: HTTP ${resp.statusCode}');
        return [];
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final messages = json['messages'] as List<dynamic>? ?? [];
      return messages
          .map((m) => m['payload'] as String?)
          .where((p) => p != null && p.isNotEmpty)
          .map((p) => base64Decode(p!))
          .toList();
    } catch (e) {
      debugPrint('[WakuDaemon] storeQuery error: $e');
      return [];
    }
  }

  // ── Status ─────────────────────────────────────────────────────────────────

  Future<({bool running, int peers})> status() async {
    if (!Platform.isAndroid) return (running: false, peers: 0);

    // /debug/v1/info is the ground truth for "is the daemon up". If it
    // answers 200, the daemon is running — period. The peer count comes
    // from /admin/v1/peers separately; a failure there must NOT flip
    // running back to false (the old code did exactly that whenever the
    // admin endpoint was disabled, since jsonDecode of the 404 body threw
    // inside the same try block).
    bool running = false;
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final r = await c.getUrl(Uri.parse('$apiUrl/debug/v1/info'));
      final resp = await r.close();
      await resp.drain<void>();
      c.close(force: true);
      running = resp.statusCode == 200;
    } catch (e) {
      debugPrint('[WakuDaemon] /debug/v1/info error: $e');
      return (running: false, peers: 0);
    }
    if (!running) return (running: false, peers: 0);

    int peers = 0;
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final r = await c.getUrl(Uri.parse('$apiUrl/admin/v1/peers'));
      final resp = await r.close();
      final body = await resp.transform(utf8.decoder).join();
      c.close(force: true);
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(body);
        if (decoded is List) peers = decoded.length;
      }
    } catch (e) {
      debugPrint('[WakuDaemon] /admin/v1/peers error: $e');
      // Leave peers at 0 but keep running=true — the daemon is alive.
    }
    return (running: true, peers: peers);
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<String> _dataDir() async {
    final dir = await getApplicationSupportDirectory();
    final wakuDir = Directory('${dir.path}/waku_data');
    if (!await wakuDir.exists()) await wakuDir.create(recursive: true);
    return wakuDir.path;
  }

  Future<bool> _waitForApi({required int seconds}) async {
    for (var i = 0; i < seconds; i++) {
      try {
        await _readApiPort();
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
        final req = await client.getUrl(Uri.parse('$apiUrl/debug/v1/info'));
        final resp = await req.close();
        await resp.drain<void>();
        client.close(force: true);
        if (resp.statusCode == 200) return true;
      } catch (e) {
        debugPrint('[WakuDaemon] wait API error: $e');
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  Future<void> _spawnDirectly(String binary, String dataDir) async {
    final env = Map<String, String>.from(Platform.environment)
      ..['HOME'] = dataDir;

    _logBuf.clear();
    _logBuf.writeln('[spawn] binary: $binary');
    _logBuf.writeln('[spawn] data:   $dataDir');
    _logBuf.writeln('---');

    _directProcess = await Process.start(
      binary,
      [
        '--relay=true',
        '--store=true',
        '--rest=true',
        '--rest-address=127.0.0.1',
        // Pin the REST port so the Dart client can reach it without parsing
        // a dynamic port from stdout. With --rest-port=0 the daemon logs
        // `addr: 127.0.0.1:0` (echoing the config, not the actual bound
        // port) and there's no other place the OS-assigned port surfaces.
        '--rest-port=8645',
        // Real go-waku CLI flag names (verified from the daemon's own --help
        // dump in the transport debugger on first run). The previous
        // `--nodekey-file` / `--db-path` were guesses that panicked the
        // process with "flag provided but not defined".
        '--key-file=$dataDir/nodekey',
        '--store-message-db-url=sqlite3://$dataDir/store.db',
        // Without a discovery mechanism the daemon comes up but never peers,
        // so "running · 0 peers" forever and nothing routes. Use the Status
        // team's public wakuv2 enrtree — the relayed traffic is end-to-end
        // encrypted by our ratchet anyway, so the public relay nodes only
        // see opaque blobs.
        '--dns-discovery=true',
        '--dns-discovery-url=enrtree://AOGECG2SPND25EEFMAJ5WF3KSGJNSGV356DSTL2YVLLZWIV6SAYBM@prod.wakuv2.nodes.status.im',
        // Pin the resolver. Android sandboxes don't expose a local DNS at
        // [::1]:53 (Waydroid logged "connection refused"), so without this
        // the enrtree lookup fails and no peers are ever discovered.
        // 1.1.1.1 is privacy-friendly (Cloudflare's stated no-logs policy).
        '--dns-discovery-name-server=1.1.1.1',
        // Expose /admin/v1/peers — our status() polls it for the peer count.
        // Without this flag the endpoint returns 404 and jsonDecode throws,
        // making status() falsely report running=false.
        '--rest-admin=true',
        // Default 1 rejects publishes with HTTP 400 "not enough peers" during
        // the 5-30s DNS-discovery bootstrap window after launch. Drop to 0 so
        // the daemon accepts the publish and gossips it once peers connect.
        // Worst case (peers never connect): the message goes nowhere on Waku
        // — but the parallel I2P / IPFS / Yggdrasil transports already deliver
        // it, so the user-visible behaviour is unchanged.
        '--min-relay-peers-to-publish=0',
      ],
      environment: env,
    );

    _directProcess!.stdout
        .transform(utf8.decoder)
        .listen((s) {
          _logBuf.write(s);
          debugPrint('[Waku] $s');
          // Parse dynamic port from output
          if (s.contains('rest') && s.contains('listening')) {
            final port = RegExp(r':(\d+)').firstMatch(s)?.group(1);
            if (port != null) {
              _dynamicApiUrl = 'http://127.0.0.1:$port';
              debugPrint('[WakuDaemon] REST API on dynamic port $port');
            }
          }
        });
    _directProcess!.stderr
        .transform(utf8.decoder)
        .listen((s) { _logBuf.write(s); debugPrint('[Waku err] $s'); });

    _directProcess!.exitCode.then((code) {
      final msg = '[exit] Waku exited with code $code';
      _logBuf.writeln(msg);
      debugPrint('[WakuDaemon] $msg');
    });

    // Wait for the API to come up after direct spawn
    await _waitForApi(seconds: 5);

    debugPrint('[WakuDaemon] daemon spawned directly; polling for readiness');
  }
}

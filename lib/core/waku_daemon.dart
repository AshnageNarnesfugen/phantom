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

  /// REST client bound to an arbitrary endpoint. Used by the desktop lab
  /// (test/lab/) to drive go-waku daemons it spawned itself — possibly
  /// several at once on distinct ports — with the exact same REST methods
  /// the app uses. Never used on-device.
  factory WakuDaemon.forApiUrl(String apiUrl) =>
      WakuDaemon._().._dynamicApiUrl = apiUrl;

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

  /// Waku has two layers of topics:
  ///   - pubsub topic: gossipsub routing layer. ALL nodes that want to
  ///     intercommunicate must subscribe to the same pubsub topic.
  ///   - content topic: application-level filter inside each WakuMessage.
  ///
  /// We ride the Status `status.prod` fleet's static shard: cluster 16,
  /// shard 32 — the shard status-go uses for 1:1 chats, so its relay nodes
  /// gossip it and its six dedicated store nodes persist it.
  ///
  /// The previous topic `/waku/2/default-waku/proto` belonged to the legacy
  /// `wakuv2.prod` fleet (cluster 0), which Status retired: it no longer
  /// appears on fleets.status.im, and its last nodes refuse dials ("dial
  /// backoff"), which is why storeQuery failed forever with "no suitable
  /// peers found" and lightpush got HTTP 503.
  ///
  /// Per-user content topic: `/phantom/1/<phantomId>/proto`. The receiver
  /// filters its inbox to messages with its own content topic.
  static const String defaultPubsubTopic = '/waku/2/rs/16/32';

  /// Publishes [payload] tagged with [contentTopic] onto [pubsubTopic].
  /// Uses the non-autosharded endpoint so we publish onto the exact pubsub
  /// topic the Status fleet's relay+store nodes are subscribed to.
  Future<bool> relayPublish({
    required String contentTopic,
    required Uint8List payload,
    String pubsubTopic = defaultPubsubTopic,
  }) async {
    final dbg = TransportDebugger.instance;
    final url = '$apiUrl/relay/v1/messages/${Uri.encodeComponent(pubsubTopic)}';
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
      final preview = respBody.length > 200 ? '${respBody.substring(0, 200)}…' : respBody;
      dbg.log('Waku: publish HTTP ${resp.statusCode} body="$preview" url=$url');
      return false;
    } catch (e) {
      dbg.log('Waku: publish exception $e url=$url');
      return false;
    }
  }

  /// Subscribes to [pubsubTopic] and yields payloads whose `contentTopic`
  /// matches [contentTopic] (our per-user inbox filter on the shared mesh).
  /// REST relay v1 needs the pubsub topic both in the subscriptions body
  /// AND in the poll URL.
  Stream<Uint8List> relaySubscribe({
    required String contentTopic,
    String pubsubTopic = defaultPubsubTopic,
    int intervalMs = 500,
  }) {
    final dbg = TransportDebugger.instance;
    final controller = StreamController<Uint8List>();
    bool running = true;

    // Registers the pubsub-topic subscription with the local daemon. Returns
    // true on HTTP 200. Must succeed before polls return anything; the daemon
    // may not be up yet when the stream is first created (cold start), so the
    // poll loop below re-attempts registration until it sticks.
    Future<bool> register() async {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        final url = '$apiUrl/relay/v1/subscriptions';
        final req = await client.postUrl(Uri.parse(url));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode([pubsubTopic]));
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        client.close(force: true);
        if (resp.statusCode != 200) {
          final preview = body.length > 200 ? '${body.substring(0, 200)}…' : body;
          dbg.log('Waku: subscribe HTTP ${resp.statusCode} body="$preview"');
        }
        return resp.statusCode == 200;
      } catch (e) {
        dbg.log('Waku: subscribe exception $e');
        return false;
      }
    }

    () async {
      bool subscribed = await register();

      // Poll messages on the pubsub topic, filter by content topic locally.
      final encodedPubsub = Uri.encodeComponent(pubsubTopic);
      while (running && !controller.isClosed) {
        if (!subscribed) {
          await Future.delayed(const Duration(seconds: 3));
          if (!running || controller.isClosed) break;
          subscribed = await register();
          continue;
        }
        try {
          // Recompute per iteration: apiUrl can change when the dynamic
          // REST port is discovered after this stream was created.
          final pollUrl = '$apiUrl/relay/v1/messages/$encodedPubsub';
          final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
          final req = await client.getUrl(Uri.parse(pollUrl));
          final resp = await req.close();
          final body = await resp.transform(utf8.decoder).join();
          client.close(force: true);

          if (resp.statusCode == 200 && body.isNotEmpty) {
            final List<dynamic> messages = jsonDecode(body);
            for (final msg in messages) {
              if (msg is! Map) continue;
              final ct = msg['contentTopic'] as String?;
              if (ct != contentTopic) continue; // not for us
              final payload = msg['payload'] as String?;
              if (payload != null && payload.isNotEmpty) {
                controller.add(base64Decode(payload));
              }
            }
          } else if (resp.statusCode != 200) {
            // Daemon restarted or dropped the subscription — re-register.
            subscribed = false;
          }
        } catch (e) {
          debugPrint('[WakuDaemon] poll error: $e');
          subscribed = false;
        }
        await Future.delayed(Duration(milliseconds: intervalMs));
      }
      await controller.close();
    }();

    controller.onCancel = () => running = false;
    return controller.stream;
  }

  /// Cold-start fallback: when we have 0 local Waku peers, regular relay
  /// publish dies in our own empty mesh. Lightpush forwards the message
  /// to a remote relay node that handles the actual gossip. Returns true
  /// when the lightpush server ACKs `relayPeerCount >= 1`.
  ///
  /// REST endpoint: `POST /lightpush/v1/message` (singular, NOT plural).
  /// Body has `pubsubTopic` + `message{payload,contentTopic,timestamp}`.
  Future<bool> lightpush({
    required String contentTopic,
    required Uint8List payload,
    String pubsubTopic = defaultPubsubTopic,
  }) async {
    final dbg = TransportDebugger.instance;
    final url = '$apiUrl/lightpush/v1/message';
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'pubsubTopic': pubsubTopic,
        'message': {
          'payload': base64Encode(payload),
          'contentTopic': contentTopic,
          'timestamp': DateTime.now().microsecondsSinceEpoch * 1000,
        },
      }));
      final resp = await req.close();
      final respBody = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode == 200) return true;
      final preview = respBody.length > 200 ? '${respBody.substring(0, 200)}…' : respBody;
      dbg.log('Waku: lightpush HTTP ${resp.statusCode} body="$preview"');
      return false;
    } catch (e) {
      dbg.log('Waku: lightpush exception $e');
      return false;
    }
  }

  /// Queries the Waku Store protocol for historical messages on a content
  /// topic. This is what enables async delivery — Bob publishes while Alice
  /// is offline, the Status fleet's store nodes persist the message (≤25GB
  /// total, ~days in practice), and Alice's app on next launch fetches it.
  ///
  /// Uses legacy /store/v1/messages — go-waku auto-selects a connected store
  /// peer (no need to pass peerAddr like v3 requires), as long as DNS
  /// discovery has populated our peer store with store-capable nodes.
  /// Returns null on failure (daemon unreachable, no store peers yet, HTTP
  /// error) so the caller can retry later WITHOUT advancing its cursor — a
  /// failed query is not the same as "no offline messages".
  ///
  /// pubsubTopic is REQUIRED in practice: without it go-waku's store client
  /// can't resolve a peer for the query and answers HTTP 500 "no suitable
  /// peers found" — even while a store node is connected and serving. This
  /// single missing parameter produced that error on every device for every
  /// session (verified in the desktop lab: same query, with the parameter,
  /// returns the messages).
  Future<List<({Uint8List payload, int timestampNs})>?> storeQuery({
    required String contentTopic,
    DateTime? startTime,
    int pageSize = 100,
    String pubsubTopic = defaultPubsubTopic,
  }) async {
    final dbg = TransportDebugger.instance;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

      final params = <String, String>{
        'pubsubTopic': pubsubTopic,
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
        final preview = body.length > 200 ? '${body.substring(0, 200)}…' : body;
        dbg.log('Waku: storeQuery HTTP ${resp.statusCode} body="$preview"');
        return null;
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final messages = json['messages'] as List<dynamic>? ?? [];
      final out = <({Uint8List payload, int timestampNs})>[];
      for (final m in messages) {
        if (m is! Map) continue;
        final p = m['payload'] as String?;
        if (p == null || p.isEmpty) continue;
        out.add((
          payload: base64Decode(p),
          timestampNs: (m['timestamp'] as num?)?.toInt() ?? 0,
        ));
      }
      return out;
    } catch (e) {
      dbg.log('Waku: storeQuery exception $e');
      return null;
    }
  }

  // ── Status ─────────────────────────────────────────────────────────────────

  Future<({bool running, int peers})> status() async {
    // No platform gate here: on desktop (the lab) the daemon is spawned
    // manually and this must report it truthfully; on platforms with no
    // daemon the probe fails instantly (connection refused) anyway.

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

  /// The full go-waku CLI invocation, shared by the on-device direct spawn
  /// and the desktop lab (test/lab/), so what the lab exercises is exactly
  /// what phones run. Mirror any change here into
  /// WakuForegroundService.kt's ProcessBuilder args.
  ///
  /// Flag notes:
  /// - Real go-waku CLI flag names (verified from the daemon's own --help);
  ///   `--nodekey-file` / `--db-path` were guesses that panicked the process
  ///   with "flag provided but not defined".
  /// - status.prod is a static-sharding fleet: cluster 16, shard 32 is where
  ///   status-go puts 1:1 traffic. Must agree with [defaultPubsubTopic] or
  ///   relay/store REST calls 404 on the topic.
  /// - 72h retention: keep ingested messages 3 days so a contact's cold-start
  ///   store query can reach back that far (go-waku default is 48h).
  /// - DNS discovery uses status.prod's boot enrtree (from status-go
  ///   params/cluster.go). The old wakuv2.prod enrtrees are dead — that
  ///   fleet was retired, its nodes sit in permanent dial backoff, which is
  ///   why storeQuery said "no suitable peers found" for entire sessions.
  /// - Store nodes (one per region, from fleets.status.im) are pinned as
  ///   staticnode so store/lightpush-capable peers exist even while DNS
  ///   discovery is still warming up; storenode sets the store client's
  ///   default query target.
  /// - Resolver pinned to 1.1.1.1: Android sandboxes don't expose local DNS
  ///   at [::1]:53 (Waydroid logged "connection refused"), which silently
  ///   killed enrtree lookups.
  /// - rest-admin exposes /admin/v1/peers for our status() peer count.
  /// - min-relay-peers-to-publish=0: default 1 rejects publishes with HTTP
  ///   400 during the discovery bootstrap window. The flip side (a 200 into
  ///   an empty mesh means nothing) is handled by WakuTransport.publish's
  ///   live peer check + lightpush.
  /// status.prod store nodes (one per region, from fleets.status.im). Used
  /// as --staticnode at launch AND re-dialed at runtime by
  /// [ensureServicePeers] — mobile NATs silently kill the TCP connections,
  /// after which go-waku's peer manager never re-dials staticnodes on its
  /// own and every store query / lightpush fails with "no suitable peers".
  static const pinnedStoreNodes = [
    '/dns4/store-01.do-ams3.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmAUdrQ3uwzuE4Gy4D56hX6uLKEeerJAnhKEHZ3DxF1EfT',
    '/dns4/store-01.gc-us-central1-a.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmMELCo218hncCtTvC2Dwbej3rbyHQcR8erXNnKGei7WPZ',
    '/dns4/store-01.ac-cn-hongkong-c.status.prod.status.im/tcp/30303/p2p/16Uiu2HAm2M7xs7cLPc3jamawkEqbr7cUJX11uvY7LxQ6WFUdUKUT',
  ];

  static List<String> launchArgs({
    required String dataDir,
    int restPort = 8645,
  }) =>
      [
        '--relay=true',
        '--store=true',
        '--rest=true',
        '--rest-address=127.0.0.1',
        // Pinned so the Dart client can reach it without parsing a dynamic
        // port from stdout (--rest-port=0 logs the config value, not the
        // actual bound port).
        '--rest-port=$restPort',
        '--key-file=$dataDir/nodekey',
        '--store-message-db-url=sqlite3://$dataDir/store.db',
        '--cluster-id=16',
        '--pubsub-topic=/waku/2/rs/16/32',
        '--store-message-retention-time=72h',
        '--dns-discovery=true',
        '--dns-discovery-url=enrtree://AMOJVZX4V6EXP7NTJPMAYJYST2QP6AJXYW76IU6VGJS7UVSNDYZG4@boot.prod.status.nodes.status.im',
        for (final node in pinnedStoreNodes) '--staticnode=$node',
        '--storenode=${pinnedStoreNodes.first}',
        '--dns-discovery-name-server=1.1.1.1',
        '--rest-admin=true',
        '--min-relay-peers-to-publish=0',
        // Default keep-alive is 5m — mobile NAT mappings die well before
        // that, taking the store/lightpush connections with them (observed
        // in the field: store worked at boot, then "no suitable peers
        // found" for the rest of the session).
        '--keep-alive=30s',
      ];

  DateTime? _lastPeerHeal;

  /// Re-dials the pinned store nodes through the REST admin API. go-waku
  /// only dials --staticnode at startup; once NAT/radio churn drops those
  /// TCP connections the store client is dead for the rest of the session.
  /// Called whenever a store query fails or a publish can't be confirmed.
  /// Throttled to once per 30s. Verified against rest/admin.go v0.9.0: the
  /// body is a single {"multiaddr","shards","protocols"} object per call.
  Future<void> ensureServicePeers() async {
    final now = DateTime.now();
    if (_lastPeerHeal != null &&
        now.difference(_lastPeerHeal!) < const Duration(seconds: 30)) {
      return;
    }
    _lastPeerHeal = now;
    final dbg = TransportDebugger.instance;
    for (final node in pinnedStoreNodes) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);
        final req = await client.postUrl(Uri.parse('$apiUrl/admin/v1/peers'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'multiaddr': node,
          'shards': [32],
          'protocols': [
            '/vac/waku/store/2.0.0-beta4',
            '/vac/waku/lightpush/2.0.0-beta1',
          ],
        }));
        final resp = await req.close();
        await resp.drain<void>();
        client.close(force: true);
        if (resp.statusCode == 200) {
          dbg.log('Waku: ✓ re-dialed store node ${node.split('/p2p/').last.substring(0, 12)}…');
        }
      } catch (e) {
        dbg.log('Waku: store-node re-dial failed: $e');
      }
    }
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
      launchArgs(dataDir: dataDir),
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

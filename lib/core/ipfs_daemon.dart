import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the bundled Kubo (go-ipfs) daemon on Android.
///
/// The daemon binary ships as `jniLibs/{abi}/libkubo.so`. Android extracts it
/// to the app's native library directory on install, so no asset copying is
/// needed. This class handles first-run repo init and lifecycle.
///
/// Startup order:
///   1. Try the Android ForegroundService (survives app backgrounding).
///   2. If the API is not up after [_serviceWaitSeconds], spawn the daemon
///      directly via Process.start() as a fallback — this covers environments
///      like Waydroid where foreground services may not work.
///
/// On non-Android platforms this is a no-op — the transport manager falls
/// back to BLE mesh automatically when IPFS is unavailable.
class IpfsDaemon {
  static const _ch     = MethodChannel('phantom/ipfs_daemon');
  static String? _dynamicApiUrl;
  static String get apiUrl => _dynamicApiUrl ?? 'http://127.0.0.1:5001';

  // How long to wait for the foreground service to bring the API up before
  // falling back to a direct Dart process spawn.
  static const _serviceWaitSeconds = 3;

  static final instance = IpfsDaemon._();
  IpfsDaemon._();

  bool _ensured = false;
  Process? _directProcess;
  final _logBuf = StringBuffer();

  /// Last captured stderr output from the daemon process.
  /// Exposed for diagnostic display in the settings screen.
  String get daemonLog => _logBuf.isEmpty ? '(no output)' : _logBuf.toString();

  /// Idempotent setup: init repo (first run) → start ForegroundService →
  /// fall back to direct spawn if the API doesn't come up in time.
  /// Never throws — failures are logged and IPFS is silently skipped.
  Future<void> ensure() async {
    if (!Platform.isAndroid || _ensured) return;
    _ensured = true;

    try {
      _logBuf.clear();

      // ── Fast path: daemon already alive from persistent service ─────────
      // If the user swiped the app away but the foreground service kept Kubo
      // running, the API will respond immediately.  Skip all init work.
      final alreadyRunning = await _waitForApi(seconds: 1);
      if (alreadyRunning) {
        _logBuf.writeln('[init] daemon already running (persistent service) — reusing');
        debugPrint('[IpfsDaemon] API already up — skipping spawn');
        return;
      }

      final libDir = await _ch.invokeMethod<String>('getNativeLibDir') ?? '';
      final binary = '$libDir/libkubo.so';

      _logBuf.writeln('[init] nativeLibDir: $libDir');
      _logBuf.writeln('[init] binary path:  $binary');
      _logBuf.writeln('[init] binary exists: ${File(binary).existsSync()}');

      if (!File(binary).existsSync()) {
        _logBuf.writeln('[init] ERROR: libkubo.so not found — listing dir contents:');
        try {
          final dir = Directory(libDir);
          if (dir.existsSync()) {
            for (final f in dir.listSync()) {
              _logBuf.writeln('  ${f.path}');
            }
          } else {
            _logBuf.writeln('  (directory does not exist)');
          }
        } catch (e) {
          _logBuf.writeln('  (could not list: $e)');
        }
        _ensured = false;
        return;
      }

      final repoPath = await _repoPath();
      _logBuf.writeln('[init] repo path: $repoPath');

      await _initRepoIfNeeded(binary, repoPath);
      _logBuf.writeln('[init] repo ready');

      // Attempt to start the foreground service (preferred — survives app kill).
      bool serviceStarted = false;
      try {
        await _ch.invokeMethod<void>('startService', {
          'binaryPath': binary,
          'repoPath':   repoPath,
        });
        serviceStarted = true;
        _logBuf.writeln('[init] ForegroundService started');
      } catch (e) {
        _logBuf.writeln('[init] ForegroundService error: $e');
      }

      // Give the service time to bring the daemon up.  Skip the wait entirely
      // if the service call already threw — in that case spawn directly now.
      final apiReady = serviceStarted
          ? await _waitForApi(seconds: _serviceWaitSeconds)
          : false;

      _logBuf.writeln('[init] API ready via service: $apiReady');

      if (!apiReady) {
        _logBuf.writeln('[init] spawning daemon directly...');
        await _spawnDaemonDirectly(binary, repoPath);
      } else {
        _logBuf.writeln('[init] using ForegroundService daemon');
      }
    } catch (e, st) {
      _logBuf.writeln('[init] EXCEPTION: $e\n$st');
      _ensured = false;
    }
  }

  /// Stops both the ForegroundService and any directly-spawned daemon process.
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _directProcess?.kill();
    _directProcess = null;
    try {
      await _ch.invokeMethod<void>('stopService');
    } catch (e) {
      debugPrint('[IpfsDaemon] stopService error: $e');
    }
    _ensured = false;
  }

  // ── On-Demand File Management ──────────────────────────────────────────────

  Timer? _idleTimer;

  void scheduleIdleShutdown() {
    _idleTimer?.cancel();
    // Apagar IPFS automáticamente después de 5 minutos sin uso
    _idleTimer = Timer(const Duration(minutes: 5), () {
      debugPrint('[IpfsDaemon] Idle timeout reached, shutting down...');
      stop();
    });
  }

  Future<String> uploadFile(Uint8List bytes, String fileName) async {
    _idleTimer?.cancel(); 
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    
    final req = await client.postUrl(Uri.parse('$apiUrl/api/v0/add?pin=true'));
    final boundary = '----PhantomBoundary${DateTime.now().millisecondsSinceEpoch}';
    req.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
    
    final header = '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$fileName"\r\nContent-Type: application/octet-stream\r\n\r\n';
    req.write(header);
    req.add(bytes);
    req.write('\r\n--$boundary--\r\n');
    
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    client.close(force: true);
    
    if (resp.statusCode != 200) {
      throw Exception('IPFS upload failed: HTTP ${resp.statusCode}\n$body');
    }
    
    final json = jsonDecode(body);
    return json['Hash'] as String;
  }

  Future<Uint8List> downloadFile(String cid) async {
    _idleTimer?.cancel();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    final req = await client.postUrl(Uri.parse('$apiUrl/api/v0/cat?arg=$cid'));
    final resp = await req.close();
    
    if (resp.statusCode != 200) {
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      throw Exception('IPFS download failed: HTTP ${resp.statusCode}\n$body');
    }
    
    final builder = BytesBuilder();
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    client.close(force: true);
    return builder.toBytes();
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<String> _repoPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/ipfs_repo';
  }

  Future<void> _initRepoIfNeeded(String binary, String repoPath) async {
    final env = {'IPFS_PATH': repoPath};

    if (!File('$repoPath/config').existsSync()) {
      debugPrint('[IpfsDaemon] first run — initialising repo at $repoPath');

      final init = await Process.run(
        binary, ['init', '--profile=lowpower'],
        environment: env,
      );
      if (init.exitCode != 0) {
        throw Exception('ipfs init failed (exit ${init.exitCode}):\n${init.stderr}');
      }

      debugPrint('[IpfsDaemon] repo initialised');
    }

    // Apply connectivity config every launch so fixes propagate to existing
    // repos. The lowpower profile disables relay + hole-punching + mDNS, which
    // prevents two Android devices from ever finding each other in the swarm.
    await _applyConfig(binary, env);
  }

  Future<void> _applyConfig(String binary, Map<String, String> env) async {
    final configs = <List<String>>[
      // Pubsub — Kubo ≥ 0.11 uses Pubsub.Enabled; the old Experimental.Pubsub
      // key is silently ignored in v0.41.0, which caused HTTP 500 on all
      // pubsub endpoints.
      ['config', '--json', 'Pubsub.Enabled', 'true'],
      // Gossipsub: efficient topic-based routing (default in Kubo ≥ 0.11)
      ['config', 'Pubsub.Router', 'gossipsub'],
      // Relay client: lets us connect through public relay nodes (NAT traversal)
      ['config', '--json', 'Swarm.RelayClient.Enabled', 'true'],
      // Hole punching: direct peer-to-peer once a relay bridges the initial handshake
      ['config', '--json', 'Swarm.EnableHolePunching', 'true'],
      // mDNS: lets devices on the same local network find each other instantly
      ['config', '--json', 'Discovery.MDNS.Enabled', 'true'],
      // Disable resource manager — saves ~30 MB RSS on mobile
      ['config', '--json', 'Swarm.ResourceMgr.Enabled', 'false'],
      // Security: use dynamic port for API to prevent other apps on localhost from accessing it
      ['config', 'Addresses.API', '/ip4/127.0.0.1/tcp/0'],
    ];
    for (final args in configs) {
      await Process.run(binary, args, environment: env);
    }
    debugPrint('[IpfsDaemon] connectivity config applied');
  }

  /// Polls the IPFS HTTP API once per second for up to [seconds] seconds.
  /// Returns true as soon as the API responds with HTTP 200.
  Future<bool> _waitForApi({required int seconds}) async {
    final repo = await _repoPath();
    final apiFile = File('$repo/api');

    for (var i = 0; i < seconds; i++) {
      try {
        if (apiFile.existsSync()) {
          final maddr = await apiFile.readAsString();
          final parts = maddr.trim().split('/');
          if (parts.length >= 5 && parts[1] == 'ip4' && parts[3] == 'tcp') {
            _dynamicApiUrl = 'http://${parts[2]}:${parts[4]}';
          }
        }
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        final req  = await client.postUrl(Uri.parse('$apiUrl/api/v0/id'));
        final resp = await req.close();
        await resp.drain<void>();
        client.close(force: true);
        if (resp.statusCode == 200) return true;
      } catch (e) {
        debugPrint('[IpfsDaemon] wait API error: $e');
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  /// Spawns the IPFS daemon directly as a Dart [Process].
  /// Used as a fallback when the Android ForegroundService is unavailable
  /// (e.g. Waydroid, rooted devices with restricted service managers).
  /// Returns immediately — the transport's retry mechanism polls for readiness.
  /// The process is killed when [stop] is called.
  Future<void> _spawnDaemonDirectly(String binary, String repoPath) async {
    // Merge the inherited process environment so the Go runtime has HOME,
    // TMPDIR, and any other variables it may need.
    final env = Map<String, String>.from(Platform.environment)
      ..['IPFS_PATH'] = repoPath;

    _logBuf.clear();
    _logBuf.writeln('[spawn] binary: $binary');
    _logBuf.writeln('[spawn] repo:   $repoPath');
    _logBuf.writeln('[spawn] HOME:   ${env['HOME'] ?? '(unset)'}');
    _logBuf.writeln('[spawn] TMPDIR: ${env['TMPDIR'] ?? '(unset)'}');
    _logBuf.writeln('---');

    _directProcess = await Process.start(
      binary,
      // --enable-pubsub-experiment was removed in Kubo ≥ 0.11; pubsub is now
      // controlled via config (Pubsub.Enabled).  Passing the old flag causes
      // "flag provided but not defined" in newer builds.
      ['daemon', '--routing=dhtclient', '--migrate=true'],
      environment: env,
    );

    // Capture stdout + stderr so we know WHY the daemon fails.
    _directProcess!.stdout
        .transform(utf8.decoder)
        .listen((s) { _logBuf.write(s); debugPrint('[IPFS] $s'); });
    _directProcess!.stderr
        .transform(utf8.decoder)
        .listen((s) { _logBuf.write(s); debugPrint('[IPFS err] $s'); });

    // Log the exit code when the process dies.
    _directProcess!.exitCode.then((code) {
      final msg = '[exit] daemon exited with code $code';
      _logBuf.writeln(msg);
      debugPrint('[IpfsDaemon] $msg');
    });

    debugPrint('[IpfsDaemon] daemon spawned directly; transport will poll for readiness');
  }

  /// Returns the current IPFS node status.
  /// Call this from the settings UI to show the user what is happening.
  Future<({bool running, int peers})> status() async {
    if (!Platform.isAndroid) return (running: false, peers: 0);
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);

      final idReq  = await client.postUrl(Uri.parse('$apiUrl/api/v0/id'));
      final idResp = await idReq.close();
      if (idResp.statusCode != 200) {
        await idResp.drain<void>();
        client.close(force: true);
        return (running: false, peers: 0);
      }
      await idResp.drain<void>();

      final peersReq  = await client.postUrl(Uri.parse('$apiUrl/api/v0/swarm/peers'));
      final peersResp = await peersReq.close();
      final body      = await peersResp.transform(utf8.decoder).join();
      client.close(force: true);
      final count = ((jsonDecode(body) as Map<String, dynamic>)['Peers'] as List?)?.length ?? 0;
      return (running: true, peers: count);
    } catch (e) {
      debugPrint('[IpfsDaemon] status error: $e');
      return (running: false, peers: 0);
    }
  }
}

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
  static const apiUrl  = 'http://127.0.0.1:5001';

  // How long to wait for the foreground service to bring the API up before
  // falling back to a direct Dart process spawn.
  static const _serviceWaitSeconds = 6;

  static final instance = IpfsDaemon._();
  IpfsDaemon._();

  bool _ensured = false;
  Process? _directProcess;

  /// Idempotent setup: init repo (first run) → start ForegroundService →
  /// fall back to direct spawn if the API doesn't come up in time.
  /// Never throws — failures are logged and IPFS is silently skipped.
  Future<void> ensure() async {
    if (!Platform.isAndroid || _ensured) return;
    _ensured = true;

    try {
      final libDir = await _ch.invokeMethod<String>('getNativeLibDir') ?? '';
      final binary = '$libDir/libkubo.so';

      if (!File(binary).existsSync()) {
        debugPrint('[IpfsDaemon] libkubo.so not found '
            '(run scripts/download_kubo.sh then rebuild) — IPFS skipped');
        _ensured = false;
        return;
      }

      final repoPath = await _repoPath();
      await _initRepoIfNeeded(binary, repoPath);

      // Attempt to start the foreground service (preferred — survives backgrounding).
      bool serviceStarted = false;
      try {
        await _ch.invokeMethod<void>('startService', {
          'binaryPath': binary,
          'repoPath':   repoPath,
        });
        serviceStarted = true;
        debugPrint('[IpfsDaemon] ForegroundService started');
      } catch (e) {
        debugPrint('[IpfsDaemon] ForegroundService unavailable: $e');
      }

      // Give the service time to bring the daemon up.  Skip the wait entirely
      // if the service call already threw — in that case spawn directly now.
      // This keeps startup fast in environments like Waydroid where the service
      // always fails immediately.
      final apiReady = serviceStarted
          ? await _waitForApi(seconds: _serviceWaitSeconds)
          : false;

      if (!apiReady) {
        debugPrint('[IpfsDaemon] API not up — spawning daemon directly');
        await _spawnDaemonDirectly(binary, repoPath);
      } else {
        debugPrint('[IpfsDaemon] API ready via ForegroundService at $apiUrl');
      }
    } catch (e, st) {
      _ensured = false;
      debugPrint('[IpfsDaemon] startup error: $e\n$st');
    }
  }

  /// Stops both the ForegroundService and any directly-spawned daemon process.
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _directProcess?.kill();
    _directProcess = null;
    try {
      await _ch.invokeMethod<void>('stopService');
    } catch (_) {}
    _ensured = false;
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
      // Pubsub (required for messaging and presence)
      ['config', '--json', 'Experimental.Pubsub', 'true'],
      // Relay client: lets us connect through public relay nodes (NAT traversal)
      ['config', '--json', 'Swarm.RelayClient.Enabled', 'true'],
      // Hole punching: direct peer-to-peer once a relay bridges the initial handshake
      ['config', '--json', 'Swarm.EnableHolePunching', 'true'],
      // mDNS: lets devices on the same local network find each other instantly
      ['config', '--json', 'Discovery.MDNS.Enabled', 'true'],
      // Gossipsub: efficient topic-based routing (default in Kubo ≥ 0.11)
      ['config', 'Pubsub.Router', 'gossipsub'],
      // Disable resource manager — saves ~30 MB RSS on mobile
      ['config', '--json', 'Swarm.ResourceMgr.Enabled', 'false'],
    ];
    for (final args in configs) {
      await Process.run(binary, args, environment: env);
    }
    debugPrint('[IpfsDaemon] connectivity config applied');
  }

  /// Polls the IPFS HTTP API once per second for up to [seconds] seconds.
  /// Returns true as soon as the API responds with HTTP 200.
  Future<bool> _waitForApi({required int seconds}) async {
    for (var i = 0; i < seconds; i++) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        final req  = await client.postUrl(Uri.parse('$apiUrl/api/v0/id'));
        final resp = await req.close();
        await resp.drain<void>();
        client.close(force: true);
        if (resp.statusCode == 200) return true;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  /// Spawns the IPFS daemon directly as a Dart [Process].
  /// Used as a fallback when the Android ForegroundService is unavailable
  /// (e.g. Waydroid, rooted devices with restricted service managers).
  /// The process is killed when [stop] is called.
  Future<void> _spawnDaemonDirectly(String binary, String repoPath) async {
    _directProcess = await Process.start(
      binary,
      ['daemon', '--enable-pubsub-experiment', '--routing=dhtclient', '--migrate=true'],
      environment: {'IPFS_PATH': repoPath},
    );
    // Drain stdout/stderr so the pipe buffer never blocks the daemon.
    _directProcess!.stdout.drain<void>();
    _directProcess!.stderr.drain<void>();
    // Wait for the API to become ready (up to 10 s).
    final ready = await _waitForApi(seconds: 10);
    if (ready) {
      debugPrint('[IpfsDaemon] daemon spawned directly, API ready at $apiUrl');
    } else {
      debugPrint('[IpfsDaemon] daemon spawned directly but API not yet ready — '
          'transport will retry');
    }
  }
}

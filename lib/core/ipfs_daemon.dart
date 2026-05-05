import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the bundled Kubo (go-ipfs) daemon on Android.
///
/// The daemon binary ships as `jniLibs/{abi}/libkubo.so`. Android extracts it
/// to the app's native library directory on install, so no asset copying is
/// needed. This class handles first-run repo init and lifecycle (via a
/// ForegroundService so the daemon survives app backgrounding).
///
/// On non-Android platforms this is a no-op — the transport manager falls
/// back to BLE mesh automatically when IPFS is unavailable.
class IpfsDaemon {
  static const _ch     = MethodChannel('phantom/ipfs_daemon');
  static const apiUrl  = 'http://127.0.0.1:5001';

  static final instance = IpfsDaemon._();
  IpfsDaemon._();

  bool _ensured = false;

  /// Idempotent setup: init repo (first run) + start ForegroundService.
  /// Safe to call multiple times and from any isolate.
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

      await _ch.invokeMethod<void>('startService', {
        'binaryPath': binary,
        'repoPath':   repoPath,
      });

      debugPrint('[IpfsDaemon] ForegroundService started, API at $apiUrl');
    } catch (e, st) {
      _ensured = false;
      debugPrint('[IpfsDaemon] startup error: $e\n$st');
    }
  }

  /// Stops the ForegroundService (and the daemon process inside it).
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
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
}

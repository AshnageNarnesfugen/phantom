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
    // Repo already exists — nothing to do.
    if (File('$repoPath/config').existsSync()) return;

    debugPrint('[IpfsDaemon] first run — initialising repo at $repoPath');

    final env = {'IPFS_PATH': repoPath};

    // Init with the lowpower profile (no NAT, minimal connections) for mobile.
    final init = await Process.run(
      binary, ['init', '--profile=lowpower'],
      environment: env,
    );
    if (init.exitCode != 0) {
      throw Exception('ipfs init failed (exit ${init.exitCode}):\n${init.stderr}');
    }

    // Enable pubsub experiment required by IpfsTransport.
    await Process.run(
      binary, ['config', '--json', 'Experimental.Pubsub', 'true'],
      environment: env,
    );

    // Disable the resource manager — saves ~30 MB RSS on mobile.
    await Process.run(
      binary, ['config', '--json', 'Swarm.ResourceMgr.Enabled', 'false'],
      environment: env,
    );

    debugPrint('[IpfsDaemon] repo initialised');
  }
}

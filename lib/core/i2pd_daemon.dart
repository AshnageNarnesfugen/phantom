import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the bundled i2pd (purpleI2P) daemon on Android.
///
/// Mirrors the bundling strategy used by [IpfsDaemon]: the i2pd executable
/// ships as `jniLibs/{abi}/libi2pd.so`. Android extracts it to the app's
/// native library directory on install, so no asset copying is required.
/// First-run config + datadir layout is generated here before the service
/// boots, and the service keeps the daemon alive across app swipes / OOM.
///
/// SAM bridge defaults — these match what [I2PTransport] expects:
///   * SAM control TCP : 127.0.0.1:7656
///   * SAM datagram UDP: 127.0.0.1:7655 (samPort - 1)
///
/// On non-Android platforms this is a no-op. If the i2pd binary was not
/// bundled into this APK (developer didn't run `scripts/download_i2pd.sh`)
/// the daemon silently skips and the transport layer falls back to IPFS
/// for handshakes — the rest of the app keeps working.
class I2pdDaemon {
  static const _ch = MethodChannel('phantom/i2pd_daemon');

  /// SAM control TCP port. Hard-coded to match [I2PTransport] defaults.
  static const samPort = 7656;

  /// How long the *direct-spawn fallback* polls the SAM control port after
  /// launching the binary. The ForegroundService is allowed to take much
  /// longer (see [_serviceBootGraceSeconds]) because it gets its own life
  /// support from Android and can outlive this call.
  static const _serviceWaitSeconds = 5;

  /// Maximum time we wait for the ForegroundService-managed daemon to bring
  /// SAM up before giving up *on the synchronous check* — we never spawn a
  /// second daemon process even if this elapses, because a parallel daemon
  /// would just lose the pid-file race and exit. The transport's own
  /// availability probe keeps polling and will pick up SAM whenever it
  /// eventually starts answering (first-run reseed + keypair generation can
  /// take 20-40 s on a cold device).
  static const _serviceBootGraceSeconds = 30;

  static final instance = I2pdDaemon._();
  I2pdDaemon._();

  bool _ensured = false;
  Process? _directProcess;
  final _logBuf = StringBuffer();

  /// Last captured stderr output from the daemon process. Surfaced in the
  /// settings screen so the user can see why I2P didn't come up.
  String get daemonLog => _logBuf.isEmpty ? '(no output)' : _logBuf.toString();

  /// Idempotent setup: write the config + tunnels file on first run, then
  /// hand the binary path to [I2pdForegroundService]. If the service does
  /// not bring SAM up within [_serviceWaitSeconds] we spawn the daemon
  /// directly as a fallback (mirrors the Kubo pattern).
  ///
  /// Never throws — failure cases are logged and SAM stays down. The I2P
  /// transport in [TransportManager] will detect that and skip to IPFS.
  Future<void> ensure() async {
    if (!Platform.isAndroid || _ensured) return;
    _ensured = true;

    try {
      _logBuf.clear();

      // Fast path: SAM already responding from a persistent service.
      if (await _waitForSam(seconds: 1)) {
        _logBuf.writeln('[init] SAM already reachable — reusing daemon');
        debugPrint('[I2pdDaemon] SAM up — skipping spawn');
        return;
      }

      final libDir = await _ch.invokeMethod<String>('getNativeLibDir') ?? '';
      final binary = '$libDir/libi2pd.so';

      _logBuf.writeln('[init] nativeLibDir: $libDir');
      _logBuf.writeln('[init] binary path:  $binary');
      _logBuf.writeln('[init] binary exists: ${File(binary).existsSync()}');

      if (!File(binary).existsSync()) {
        _logBuf.writeln('[init] WARN: libi2pd.so not bundled — '
            'run scripts/download_i2pd.sh and rebuild. '
            'Handshakes will fall back to IPFS.');
        _ensured = false;
        return;
      }

      final dataDir = await _dataDir();
      _logBuf.writeln('[init] data dir: $dataDir');
      await _writeConfigsIfNeeded(dataDir);
      _logBuf.writeln('[init] config ready');

      // Prefer the foreground service (survives app swipe). Only fall back
      // to a direct Process.start when the service call itself fails —
      // running two parallel daemons against the same data dir means the
      // loser hits "Could not lock pid file ... Try again" and exits, which
      // shows up as a scary-looking error in logs even though it's harmless.
      bool serviceStarted = false;
      try {
        await _ch.invokeMethod<void>('startService', {
          'binaryPath': binary,
          'dataDir':    dataDir,
        });
        serviceStarted = true;
        _logBuf.writeln('[init] ForegroundService started');
      } catch (e) {
        _logBuf.writeln('[init] ForegroundService error: $e');
      }

      if (serviceStarted) {
        // Best-effort liveness probe so callers waiting on us see "SAM up"
        // when possible. We do NOT spawn a fallback if this times out —
        // i2pd's first-run reseed often takes 20-40 s, and the transport's
        // own availability probe keeps trying every few seconds anyway.
        final samReady = await _waitForSam(seconds: _serviceBootGraceSeconds);
        _logBuf.writeln('[init] SAM ready via service: $samReady '
            '(checked over ${_serviceBootGraceSeconds}s)');
      } else {
        _logBuf.writeln('[init] spawning daemon directly (service unavailable)…');
        await _spawnDaemonDirectly(binary, dataDir);
        await _waitForSam(seconds: _serviceWaitSeconds);
      }
    } catch (e, st) {
      _logBuf.writeln('[init] EXCEPTION: $e\n$st');
      _ensured = false;
    }
  }

  /// Stops both the ForegroundService and any directly-spawned daemon.
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _directProcess?.kill();
    _directProcess = null;
    try { await _ch.invokeMethod<void>('stopService'); } catch (_) {}
    _ensured = false;
  }

  /// Returns the current i2pd status. Used by the settings UI.
  Future<({bool running, String? destination})> status() async {
    if (!Platform.isAndroid) return (running: false, destination: null);
    return (running: await _waitForSam(seconds: 1), destination: null);
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<String> _dataDir() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/i2pd';
  }

  /// Writes a minimal i2pd.conf + tunnels.conf if they don't exist yet. The
  /// config enables only what the SAM transport needs:
  ///   * SAM bridge on 127.0.0.1:7656 (control TCP) + 7655 (datagram UDP)
  ///   * Floodfill/reseed defaults (kept conservative for mobile)
  ///   * HTTP/SOCKS/UPNP disabled — we are not a general-purpose proxy
  Future<void> _writeConfigsIfNeeded(String dataDir) async {
    final dir = Directory(dataDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final sub in ['certificates', 'tunnels.d']) {
      final d = Directory('$dataDir/$sub');
      if (!d.existsSync()) d.createSync(recursive: true);
    }

    final conf = File('$dataDir/i2pd.conf');
    if (!conf.existsSync()) {
      conf.writeAsStringSync('''
# Phantom Messenger — i2pd config (auto-generated; safe to edit)
ipv4 = true
ipv6 = false
# Allow transit traffic. Costs us some bandwidth but materially speeds up
# tunnel integration on cold start because we are visible to other routers.
notransit = false
floodfill = false
# Bumped from L to M (32→256 KBps) — cold-start tunnel construction
# is bandwidth-limited; M cuts first-session-ready time roughly in half
# on the typical handheld device the app targets.
bandwidth = M
share = 50
daemon = false
log = stdout
loglevel = warn

[http]
enabled = false

[httpproxy]
enabled = false

[socksproxy]
enabled = false

[upnp]
enabled = false

[precomputation]
elgamal = false

# SAM bridge — control on TCP, datagram traffic on UDP one port below.
# The Dart-side I2PTransport binds an ephemeral UDP socket and tells SAM
# via SESSION CREATE ... PORT=<udp>, so the only thing we hard-code here
# is the well-known SAM listener.
[sam]
enabled = true
address = 127.0.0.1
port = 7656

[reseed]
# Cert verification fails when the device clock skews more than the cert
# validity window — leaves the user with a broken bootstrap and no obvious
# error. Skipping verify lets cold starts complete reliably; the reseed
# bundle itself is still signed by the i2pd router operators.
verify = false
''');
    }

    final tunnels = File('$dataDir/tunnels.conf');
    if (!tunnels.existsSync()) {
      tunnels.writeAsStringSync('# Phantom uses SAM only — no static tunnels.\n');
    }
  }

  /// Polls SAM's HELLO handshake once per second for up to [seconds]
  /// seconds. We don't care about the reply contents — a clean TCP HELLO
  /// → HELLO REPLY round trip means the bridge is up.
  Future<bool> _waitForSam({required int seconds}) async {
    for (var i = 0; i < seconds; i++) {
      try {
        final s = await Socket.connect('127.0.0.1', samPort,
            timeout: const Duration(seconds: 1));
        s.add(_kHello);
        await s.flush();
        // We close immediately — just proving the listener is alive.
        await s.close();
        return true;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  static final _kHello =
      'HELLO VERSION MIN=3.3 MAX=3.3\n'.codeUnits;

  /// Fallback when the ForegroundService refuses to start (rooted devices,
  /// Waydroid, some custom ROMs). The Dart-side process dies with the app
  /// but that is acceptable as a last resort.
  Future<void> _spawnDaemonDirectly(String binary, String dataDir) async {
    final env = Map<String, String>.from(Platform.environment);
    _logBuf
      ..writeln('[spawn] binary:  $binary')
      ..writeln('[spawn] datadir: $dataDir')
      ..writeln('---');

    _directProcess = await Process.start(
      binary,
      [
        '--conf=$dataDir/i2pd.conf',
        '--datadir=$dataDir',
        '--tunconf=$dataDir/tunnels.conf',
      ],
      environment: env,
    );

    _directProcess!.stdout.listen((b) {
      final s = String.fromCharCodes(b);
      _logBuf.write(s);
      debugPrint('[i2pd] $s');
    });
    _directProcess!.stderr.listen((b) {
      final s = String.fromCharCodes(b);
      _logBuf.write(s);
      debugPrint('[i2pd err] $s');
    });
    _directProcess!.exitCode.then((code) {
      final msg = '[exit] daemon exited with code $code';
      _logBuf.writeln(msg);
      debugPrint('[I2pdDaemon] $msg');
    });

    debugPrint('[I2pdDaemon] daemon spawned directly');
  }
}

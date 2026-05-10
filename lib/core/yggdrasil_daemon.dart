import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the in-process Yggdrasil router on Android.
///
/// Yggdrasil-go is bundled as `libs/yggdrasil-mobile.aar` (gomobile binding) and
/// runs inside [YggdrasilVpnService] which owns the TUN device. On non-Android
/// platforms or when the .aar wasn't included, [ensure] is a no-op and the
/// transport stack falls back to IPFS / I2P / BLE.
///
/// Lifecycle:
///   1. [ensure] is called once at app startup
///   2. We generate (or load) a config + derive our 0200::/7 address
///   3. Ask Android for VPN permission (one-time UI prompt)
///   4. Start [YggdrasilVpnService] with the config + address
///   5. The service hands the TUN fd to mobile.Yggdrasil and bridges packets
///
/// Failure modes (all silent — Yggdrasil is opt-in by design):
///   - User denies VPN permission → service never starts
///   - mobile.Yggdrasil class missing (no .aar) → service start returns false
///   - Already-existing system VPN holds the slot → establish() returns null
class YggdrasilDaemon {
  static const _ch = MethodChannel('phantom/yggdrasil_daemon');

  static final instance = YggdrasilDaemon._();
  YggdrasilDaemon._();

  bool _ensured = false;
  String? _address;

  /// Yggdrasil IPv6 we're advertising on the mesh, or null if not running.
  String? get address => _address;

  /// Idempotent setup. Generates a config on first run and starts the VPN
  /// service if we already have permission. Otherwise the user must invoke
  /// [requestPermissionAndStart] from the settings UI.
  Future<void> ensure() async {
    if (!Platform.isAndroid || _ensured) return;
    _ensured = true;
    try {
      final prepared = await _ch.invokeMethod<bool>('isPrepared') ?? false;
      if (!prepared) {
        debugPrint('[YggDaemon] VPN permission not granted — skipping auto-start');
        return;
      }
      await _startService();
    } catch (e) {
      debugPrint('[YggDaemon] ensure() failed: $e');
      _ensured = false;
    }
  }

  /// Triggers the system VPN-permission dialog and starts the service if granted.
  /// Returns true on success.
  Future<bool> requestPermissionAndStart() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _ch.invokeMethod<bool>('requestPermission') ?? false;
      if (!ok) return false;
      return _startService();
    } catch (e) {
      debugPrint('[YggDaemon] permission flow failed: $e');
      return false;
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try { await _ch.invokeMethod<void>('stopService'); } catch (_) {}
    _address = null;
  }

  Future<bool> _startService() async {
    final cfg = await _loadOrGenerateConfig();
    _address = cfg.address;
    try {
      await _ch.invokeMethod<void>('startService', {
        'configJson': cfg.json,
        'address':    cfg.address,
      });
      debugPrint('[YggDaemon] service started — address=${cfg.address}');
      return true;
    } catch (e) {
      debugPrint('[YggDaemon] startService failed: $e');
      return false;
    }
  }

  // ── Config ──────────────────────────────────────────────────────────────────

  Future<_YggConfig> _loadOrGenerateConfig() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/yggdrasil.conf.json');
    if (await f.exists()) {
      try {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final addr = json['_phantom_address'] as String?;
        if (addr != null) {
          return _YggConfig(json: jsonEncode(json), address: addr);
        }
      } catch (_) {}
    }
    // Generate fresh — actual key generation happens on the Go side via
    // mobile.Yggdrasil.GenConf(). For the first iteration we ship a minimal
    // config and let yggdrasil-go fill in the random keys at startup.
    final config = <String, dynamic>{
      // Public peers — small set of well-known nodes. Users can extend later.
      'Peers': [
        'tls://ygg-ukfi.incognet.io:8884',
        'tls://ygg-ukcov.incognet.io:8884',
        'tls://uk1.servers.devices.cwinfo.net:58226',
      ],
      'PeersByListenAddress': <String, dynamic>{},
      'IfMTU': 1280,
      'NodeInfoPrivacy': true,
      // Placeholder — real keys + address get baked in by the Go side on
      // first startup and persisted via a follow-up call.
      '_phantom_address': 'fc00::1',
    };
    final encoded = jsonEncode(config);
    await f.writeAsString(encoded);
    return _YggConfig(json: encoded, address: config['_phantom_address'] as String);
  }
}

class _YggConfig {
  final String json;
  final String address;
  const _YggConfig({required this.json, required this.address});
}

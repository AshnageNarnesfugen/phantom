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

  /// Peers (multiaddr-style strings) that override the in-file defaults.
  /// Caller is expected to compute these from user prefs + fetched dynamic
  /// list before invoking [ensure]. When empty / null the daemon uses the
  /// hard-coded fallback set baked into [_loadOrGenerateConfig].
  List<String>? _pendingPeers;

  /// Replaces the peer list used by the next [ensure] / re-launch. Pass
  /// null to clear the override and fall back to the file's existing
  /// peer list (or hard-coded fallback if there's no file yet).
  void setPeerOverride(List<String>? peers) {
    _pendingPeers = peers;
  }

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
    // Empty cfg.address means we don't yet have a real 0200::/7 from the Go
    // side. The Kotlin VpnService.Builder.addAddress() rejects an empty
    // string with IllegalArgumentException, so skip the start entirely in
    // that case — the user can bring Yggdrasil up later from settings once
    // the in-process router has produced an address.
    _address = cfg.address.isEmpty ? null : cfg.address;
    if (_address == null) {
      debugPrint('[YggDaemon] no persisted address yet — skipping VPN start; '
          'Yggdrasil dormant until address is provisioned');
      return false;
    }
    try {
      await _ch.invokeMethod<void>('startService', {
        'configJson': cfg.json,
        'address':    cfg.address,
      });
      debugPrint('[YggDaemon] service started — address=$_address');
      return true;
    } catch (e) {
      debugPrint('[YggDaemon] startService failed: $e');
      return false;
    }
  }

  // ── Config ──────────────────────────────────────────────────────────────────

  /// Peer set used when the caller hasn't set an override yet AND no
  /// previous config file exists. Same stable community peers that have
  /// been online for years. The runtime catalog
  /// ([YggdrasilPeerCatalog.fallback]) keeps a copy of this list — they
  /// should stay in sync.
  static const List<String> _bootstrapPeers = [
    'tls://ygg-ukfi.incognet.io:8884',
    'tls://ygg-ukcov.incognet.io:8884',
    'tls://uk1.servers.devices.cwinfo.net:58226',
  ];

  Future<_YggConfig> _loadOrGenerateConfig() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/yggdrasil.conf.json');
    Map<String, dynamic>? existing;
    if (await f.exists()) {
      try {
        existing = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      } catch (_) {}
    }

    // If a peer override was supplied (from settings UI / startup wiring),
    // it always wins over whatever is currently on disk. That way changes
    // to the user's custom peer list or to the dynamic public-peer cache
    // take effect on the next launch without manual config editing.
    final peers = _pendingPeers != null && _pendingPeers!.isNotEmpty
        ? _pendingPeers!
        : (existing?['Peers'] as List?)?.cast<String>() ?? _bootstrapPeers;

    if (existing != null) {
      final addr = existing['_phantom_address'] as String?;
      // Refresh the peer list in the file so it survives across runs.
      existing['Peers'] = peers;
      await f.writeAsString(jsonEncode(existing));
      if (addr != null && addr.isNotEmpty && _isYggAddress(addr)) {
        return _YggConfig(json: jsonEncode(existing), address: addr);
      }
    }

    // First run / corrupt config: ship a minimal config and let mobile.Yggdrasil
    // fill in the real keypair + 0200::/7 address on its first startJSON call.
    final config = <String, dynamic>{
      'Peers': peers,
      'PeersByListenAddress': <String, dynamic>{},
      'IfMTU': 1280,
      'NodeInfoPrivacy': true,
      '_phantom_address': '',
    };
    final encoded = jsonEncode(config);
    await f.writeAsString(encoded);
    return _YggConfig(json: encoded, address: '');
  }

  /// True if [s] is a valid Yggdrasil 0200::/7 IPv6 address. The Go side never
  /// returns anything outside that range when running, so this is a cheap way
  /// to reject the legacy `fc00::1` placeholder we used to write.
  static bool _isYggAddress(String s) {
    if (s.isEmpty) return false;
    try {
      final addr = InternetAddress(s);
      if (addr.type != InternetAddressType.IPv6) return false;
      final b = addr.rawAddress;
      return b.length == 16 && (b[0] == 0x02 || b[0] == 0x03);
    } catch (_) {
      return false;
    }
  }
}

class _YggConfig {
  final String json;
  final String address;
  const _YggConfig({required this.json, required this.address});
}

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

  /// True when the gomobile router (.aar) is inside this APK. When false the
  /// service can never run — surfaced in the transport status UI so the user
  /// sees "missing binary" instead of a misleading "inactive".
  Future<bool> isRouterBundled() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('isRouterBundled') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _startService() async {
    final cfg = await _loadOrGenerateConfig();
    // Empty address = first run. The service now bootstraps router-FIRST:
    // it starts the router (generating a persistent identity if the config
    // has no PrivateKey), reads the real 0200::/7 address from it, builds
    // the TUN with that, and persists both to SharedPreferences. We poll
    // those back and pin them into our config file so the identity stays
    // stable across runs.
    _address = cfg.address.isEmpty ? null : cfg.address;
    try {
      await _ch.invokeMethod<void>('startService', {
        'configJson': cfg.json,
        'address':    cfg.address,
      });
    } catch (e) {
      debugPrint('[YggDaemon] startService failed: $e');
      return false;
    }

    // Wait for the router to provision (first run) or confirm (later runs).
    for (var i = 0; i < 40; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      try {
        final prov =
            await _ch.invokeMethod<Map<Object?, Object?>>('getProvisioned');
        if (prov != null) {
          final addr = prov['address'] as String?;
          final json = prov['config'] as String?;
          if (addr != null && addr.isNotEmpty && _isYggAddress(addr)) {
            _address = addr;
            if (json != null) await _persistProvisioned(addr, json);
            debugPrint('[YggDaemon] service started — address=$_address');
            return true;
          }
        }
      } catch (_) {}
    }
    // No provisioning seen (router missing / start failed). Whatever address
    // we had from the config file may still be valid if the service is up.
    debugPrint('[YggDaemon] no provisioned address after start '
        '(router missing or failed) — address=$_address');
    return _address != null;
  }

  /// Pin the router-provisioned identity (address + full config with
  /// PrivateKey) into our config file so every later run reuses it.
  Future<void> _persistProvisioned(String address, String configJson) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/yggdrasil.conf.json');
      final map = jsonDecode(configJson) as Map<String, dynamic>;
      map['_phantom_address'] = address;
      await f.writeAsString(jsonEncode(map));
    } catch (e) {
      debugPrint('[YggDaemon] could not persist provisioned config: $e');
    }
  }

  // ── Config ──────────────────────────────────────────────────────────────────

  /// Peer set used when the caller hasn't set an override yet AND no
  /// previous config file exists. The runtime catalog
  /// ([YggdrasilPeerCatalog.fallback]) keeps a copy of this list — they
  /// MUST stay in sync.
  ///
  /// Verified reachable 2026-07-11. The previous defaults (incognet.io /
  /// cwinfo.net) had gone dead — their hostnames stopped resolving in DNS
  /// entirely — so a fresh device (or any device whose upstream peer fetch
  /// failed) connected to ZERO peers: Yggdrasil still self-assigned a 0200::/7
  /// address (derived from the node key, no peer needed) but could not route a
  /// single packet, which is exactly why ygg never carried a message. A
  /// geographically diverse set, :443-heavy so restrictive firewalls let it
  /// through.
  static const List<String> _bootstrapPeers = [
    'tls://ygg.mkg20001.io:443',
    'tls://b.ygg.yt:443',
    'tls://g.ygg.yt:443',
    'tls://ca.us.ygg.informatics.coop:443',
    'tls://44.234.134.124:443',
    'tls://asia.deinfra.org:15015',
    'tls://193.93.119.42:443',
    'tls://cirno.nadeko.net:44442',
  ];

  /// Hosts we know are dead (DNS no longer resolves). A device that ran an
  /// older build persisted these into its on-disk config, and
  /// [_loadOrGenerateConfig] reuses the persisted `Peers` verbatim — so without
  /// this purge, upgrading the app would NOT fix a stuck node. We strip any URI
  /// pointing at one of these on load.
  static const Set<String> _deadPeerHosts = {
    'ygg-ukfi.incognet.io',
    'ygg-ukcov.incognet.io',
    'uk1.servers.devices.cwinfo.net',
  };

  /// Drops known-dead peers from [peers]; falls back to [_bootstrapPeers] if
  /// that would leave the node with nothing to dial. Pure + null-safe so it can
  /// be unit-tested without a device.
  static List<String> sanitizePeers(List<String>? peers) {
    final cleaned = <String>[
      for (final p in peers ?? const <String>[])
        if (p.trim().isNotEmpty && !_deadPeerHosts.any(p.contains)) p.trim(),
    ];
    return cleaned.isEmpty ? List<String>.from(_bootstrapPeers) : cleaned;
  }

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
    // sanitizePeers strips known-dead hosts an older build may have persisted
    // and guarantees a non-empty result, so a stale config can't strand the
    // node with only unreachable peers.
    final peers = sanitizePeers(
      _pendingPeers != null && _pendingPeers!.isNotEmpty
          ? _pendingPeers
          : (existing?['Peers'] as List?)?.cast<String>(),
    );

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

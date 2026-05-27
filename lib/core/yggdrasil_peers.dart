import 'dart:async';
import 'package:http/http.dart' as http;

/// Fetches and curates the upstream list of public Yggdrasil peers.
///
/// Source: https://publicpeers.neilalexander.dev/ — the canonical
/// community-maintained list. The page is HTML so we scrape inline peer
/// URIs (`tls://host:port`, `tcp://…`, `quic://…`, `ws://…`, `wss://…`)
/// with a regex. The set is large (~300 peers worldwide); we trim and
/// shuffle so each launch tries a different small subset for fairness.
///
/// The result is cached in [PhantomStorage] so we don't refetch every
/// launch — see `getYggCachedPeers` / `setYggCachedPeers`.
class YggdrasilPeerCatalog {
  /// How many peers we pick from the dynamic list. Yggdrasil only needs a
  /// handful of live peers to bootstrap, and trying every one of 300 on
  /// every start would create unnecessary load.
  static const int defaultPickCount = 6;

  static final RegExp _peerRe =
      RegExp(r'(tls|tcp|ws|wss|quic)://[a-zA-Z0-9.\-\[\]:]+:[0-9]+');

  /// Default fallback peers, used when the network is unreachable and the
  /// cache is empty. These are stable Yggdrasil community peers that have
  /// been online for years — safe to hard-code.
  static const List<String> fallback = [
    'tls://ygg-ukfi.incognet.io:8884',
    'tls://ygg-ukcov.incognet.io:8884',
    'tls://uk1.servers.devices.cwinfo.net:58226',
    'tls://ygg.mkg20001.io:443',
  ];

  final http.Client _client;
  YggdrasilPeerCatalog({http.Client? client})
      : _client = client ?? http.Client();

  /// Scrapes the publicpeers page. Returns deduped peer URIs. Throws if
  /// the network fetch fails — caller falls back to cache or [fallback].
  ///
  /// The upstream is HTTPS but we don't pin its certificate (the cert
  /// rotates and a wrong pin would brick everyone). Instead we validate
  /// every URI returned and drop anything that doesn't look like a
  /// public-internet peer — defending against a MITM that swaps the
  /// upstream with something like `tls://10.0.0.1:9999` aiming to route
  /// our VPN tunnel through their box.
  Future<List<String>> fetchUpstream() async {
    final resp = await _client
        .get(Uri.parse('https://publicpeers.neilalexander.dev/'))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw HttpException('publicpeers HTTP ${resp.statusCode}');
    }
    final matches = _peerRe.allMatches(resp.body).map((m) => m.group(0)!).toSet();
    return matches.where(_isPublicPeer).toList();
  }

  /// Returns true iff [peerUri] looks like a public-internet Yggdrasil peer.
  /// Filters: localhost, RFC1918 private ranges, link-local, loopback IPv6,
  /// CGNAT, multicast, and reserved ranges. We can't fully validate without
  /// DNS lookup of hostnames, but blocking obvious bogons cuts the MITM
  /// surface significantly.
  static bool _isPublicPeer(String peerUri) {
    final m = RegExp(r'^([a-z]+)://([^:/]+|\[[^\]]+\]):(\d+)$').firstMatch(peerUri);
    if (m == null) return false;
    final scheme = m.group(1)!;
    if (!const {'tls', 'tcp', 'ws', 'wss', 'quic'}.contains(scheme)) return false;

    final port = int.tryParse(m.group(3)!);
    if (port == null || port <= 0 || port > 65535) return false;

    var host = m.group(2)!;
    // Strip brackets from IPv6 literal
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }

    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower.endsWith('.localhost')) return false;
    if (lower.endsWith('.local') || lower.endsWith('.internal')) return false;

    // IPv4 dotted-quad checks
    final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(host);
    if (v4 != null) {
      final octets = List<int>.generate(4, (i) => int.parse(v4.group(i + 1)!));
      if (octets.any((o) => o > 255)) return false;
      if (octets[0] == 0) return false;                       // 0.0.0.0/8
      if (octets[0] == 10) return false;                      // RFC1918
      if (octets[0] == 127) return false;                     // loopback
      if (octets[0] == 169 && octets[1] == 254) return false; // link-local
      if (octets[0] == 172 && (octets[1] >= 16 && octets[1] <= 31)) return false; // RFC1918
      if (octets[0] == 192 && octets[1] == 168) return false; // RFC1918
      if (octets[0] == 100 && (octets[1] >= 64 && octets[1] <= 127)) return false; // CGNAT
      if (octets[0] >= 224) return false;                     // multicast + reserved
      return true;
    }

    // IPv6 — block loopback, link-local, ULA
    if (host.contains(':')) {
      if (host == '::1' || host == '::') return false;
      if (lower.startsWith('fe80:') || lower.startsWith('fec0:')) return false;
      if (lower.startsWith('fc') || lower.startsWith('fd')) return false; // ULA fc00::/7
      if (lower.startsWith('ff')) return false; // multicast
      return true;
    }

    // Hostname — must have at least one dot (no bare names like "router")
    if (!host.contains('.')) return false;
    return true;
  }

  /// Picks [n] random peers from [list]. Used to rotate which peers we
  /// hand to yggdrasil-go on each launch — avoids hammering the same
  /// nodes from every Phantom install in a given week.
  static List<String> pickRandom(List<String> list, int n) {
    if (list.length <= n) return List.of(list);
    final copy = List.of(list)..shuffle();
    return copy.sublist(0, n);
  }

  void dispose() {
    _client.close();
  }
}

class HttpException implements Exception {
  final String message;
  const HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}

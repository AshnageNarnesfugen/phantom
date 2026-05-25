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
  Future<List<String>> fetchUpstream() async {
    final resp = await _client
        .get(Uri.parse('https://publicpeers.neilalexander.dev/'))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw HttpException('publicpeers HTTP ${resp.statusCode}');
    }
    final matches = _peerRe.allMatches(resp.body).map((m) => m.group(0)!).toSet();
    return matches.toList();
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

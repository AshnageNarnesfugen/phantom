import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/yggdrasil_daemon.dart';
import 'package:phantom_messenger/core/yggdrasil_peers.dart';

/// Root cause of "ygg comes up but never carries a message": the hard-coded
/// default peers had gone dead — their hostnames stopped resolving in DNS — so
/// a fresh device (or one whose upstream peer fetch failed) dialled ZERO
/// reachable peers. Yggdrasil still self-assigns a 0200::/7 address from the
/// node key without any peer, so the logs looked healthy while the node could
/// not route a single packet.
///
/// Existing installs are worse: an older build persisted the dead peers into
/// the on-disk config, and the daemon reuses that list verbatim across
/// upgrades — so shipping new defaults alone wouldn't rescue a stuck node.
/// [YggdrasilDaemon.sanitizePeers] purges the known-dead hosts on load and
/// guarantees a non-empty result. These tests pin that behaviour without a
/// device or the network.
void main() {
  const deadHosts = [
    'ygg-ukfi.incognet.io',
    'ygg-ukcov.incognet.io',
    'uk1.servers.devices.cwinfo.net',
  ];

  test('the shipped defaults no longer contain any known-dead host', () {
    for (final list in [YggdrasilPeerCatalog.fallback]) {
      for (final dead in deadHosts) {
        expect(list.any((p) => p.contains(dead)), isFalse,
            reason: '$dead is dead (DNS gone) — must not ship as a default');
      }
      expect(list, isNotEmpty);
    }
  });

  test('sanitizePeers strips a config that persisted the dead peers', () {
    final stale = [
      'tls://ygg-ukfi.incognet.io:8884',
      'tls://ygg-ukcov.incognet.io:8884',
      'tls://uk1.servers.devices.cwinfo.net:58226',
    ];
    final cleaned = YggdrasilDaemon.sanitizePeers(stale);
    for (final dead in deadHosts) {
      expect(cleaned.any((p) => p.contains(dead)), isFalse);
    }
    // All three were dead → nothing survives → falls back to live bootstrap.
    expect(cleaned, isNotEmpty,
        reason: 'a node must never be left with zero peers to dial');
  });

  test('sanitizePeers keeps live peers and drops only the dead ones', () {
    final mixed = [
      'tls://ygg-ukfi.incognet.io:8884', // dead
      'tls://ygg.mkg20001.io:443', // live
      'tls://b.ygg.yt:443', // live
    ];
    final cleaned = YggdrasilDaemon.sanitizePeers(mixed);
    expect(cleaned, containsAll(['tls://ygg.mkg20001.io:443', 'tls://b.ygg.yt:443']));
    expect(cleaned.any((p) => p.contains('incognet.io')), isFalse);
  });

  test('sanitizePeers(null) / empty falls back to the live bootstrap set', () {
    expect(YggdrasilDaemon.sanitizePeers(null), isNotEmpty);
    expect(YggdrasilDaemon.sanitizePeers(const []), isNotEmpty);
    expect(YggdrasilDaemon.sanitizePeers(const ['   ']), isNotEmpty,
        reason: 'blank entries are not real peers');
  });

  test('custom (non-dead) peers are preserved verbatim, order intact', () {
    final custom = ['tls://my.box.example:12345', 'tcp://10.9.8.7:9001'];
    // (These are private/unknown but NOT on the dead list — sanitize only
    // removes hosts we have positively confirmed dead.)
    expect(YggdrasilDaemon.sanitizePeers(custom), custom);
  });

  test('applyPeers records the override so it applies on the next start', () async {
    // Off-device (no Android VpnService) applyPeers can't bounce a router, so
    // it returns null — but it MUST still store the override, which is the
    // "saved — applies when you enable ygg" path the settings button relies on.
    // (On-device the same call also restarts the running node; that half is
    // MethodChannel-only and verified on the phone.)
    final custom = ['tls://my.box.example:9001'];
    addTearDown(() => YggdrasilDaemon.instance.setPeerOverride(null));

    final addr = await YggdrasilDaemon.instance.applyPeers(custom);
    expect(addr, isNull, reason: 'no VpnService in a unit test host');
    expect(YggdrasilDaemon.instance.pendingPeersForTest, custom,
        reason: 'the new peers must be queued for the next (re)start');
  });
}

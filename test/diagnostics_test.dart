import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/transport_debugger.dart';
import 'package:phantom_messenger/core/diagnostic_report.dart';

/// Real lines from a field capture. The device log is ~90% repeats of a
/// handful of messages, which is why reading it line by line finds nothing.
const _ipfsRetryA =
    'IPFS: subscription error: ClientException with SocketException: '
    'Connection refused (OS Error: Connection refused, errno = 111), '
    'address = 127.0.0.1, port = 48868, uri=http://127.0.0.1:34763/api/v0/'
    'pubsub/sub?arg=ubXNnM2hSR21GdGdNV2hwWkY0UlZmQUx3QWNaWEszNVNWM2NCWHA1ZDU0'
    ' — retrying in 10s';
const _ipfsRetryB =
    'IPFS: subscription error: ClientException with SocketException: '
    'Connection refused (OS Error: Connection refused, errno = 111), '
    'address = 127.0.0.1, port = 57636, uri=http://127.0.0.1:34763/api/v0/'
    'pubsub/sub?arg=ubXNnM2hSR21GdGdNV2hwWkY0UlZmQUx3QWNaWEszNVNWM2NCWHA1ZDU0'
    ' — retrying in 10s';
const _wakuStore =
    'Waku: storeQuery HTTP 500 body="{"messages":null,'
    '"error_message":"no suitable peers found"}"';
const _i2pDest =
    'YWGAMfdXOcu7m80fQwertyuiopASDFGHJKLzxcvbnm1234567890QWERTYUIOPasdfghjklZ'
    'XCVBNM1234567890qwertyuiopasdfghjklzxcvbnmQWERTYUIOP1234567890abcdefghij'
    'klmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789~-abcdefghijklmnopqr'
    'stuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzAB'
    'CDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL'
    'MNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRAAAA';

void main() {
  group('signature — what counts as the same message', () {
    test('an ephemeral port and a topic arg do not make a new message', () {
      expect(TransportDebugger.signatureOf(_ipfsRetryA),
          TransportDebugger.signatureOf(_ipfsRetryB));
    });

    test('a changing count does not either', () {
      expect(
        TransportDebugger.signatureOf('IPFS: gossipsub peers on topic: 0'),
        TransportDebugger.signatureOf('IPFS: gossipsub peers on topic: 12'),
      );
      expect(
        TransportDebugger.signatureOf('Waku: publish not in fleet store yet (attempt 1/4)'),
        TransportDebugger.signatureOf('Waku: publish not in fleet store yet (attempt 4/4)'),
      );
    });

    test('genuinely different failures stay apart', () {
      final sigs = {
        TransportDebugger.signatureOf(_ipfsRetryA),
        TransportDebugger.signatureOf(_wakuStore),
        TransportDebugger.signatureOf('MSG: ✗ no session could decrypt this MSG frame'),
        TransportDebugger.signatureOf('IPFS: gossipsub peers on topic: 0'),
      };
      expect(sigs.length, 4);
    });

    test('English words survive — only identifiers are masked', () {
      // "gossipsub" and "subscribed" are both 9+ chars; masking them would
      // merge two unrelated rows into one useless one.
      expect(
        TransportDebugger.signatureOf('IPFS: gossipsub peers on topic: 0'),
        isNot(TransportDebugger.signatureOf('IPFS: subscribed peers on topic: 0')),
      );
      expect(TransportDebugger.signatureOf('IPFS: gossipsub peers on topic: 0'),
          contains('gossipsub'));
    });
  });

  group('grouping', () {
    late TransportDebugger dbg;
    setUp(() {
      dbg = TransportDebugger.instance..clear();
    });

    test('a spin loop is one row with a counter, not fifty rows', () {
      for (var i = 0; i < 50; i++) {
        dbg.log('IPFS: gossipsub peers on topic: ${i % 3}');
      }
      expect(dbg.groups.length, 1);
      expect(dbg.groups.single.count, 50);
      expect(dbg.totalLines, 50);
    });

    test('rows keep first-seen order so the sequence stays readable', () {
      dbg.log('TRANSPORT: initializing for 3hRGmFtg...');
      dbg.log(_ipfsRetryA);
      dbg.log('I2P: session ready — dest=YWGAMfdXOcu7m80f…');
      dbg.log(_ipfsRetryB);

      expect(dbg.groups.length, 3);
      expect(dbg.groups.first.message, contains('initializing'));
      expect(dbg.groups.last.message, contains('session ready'));
      expect(dbg.groups[1].count, 2, reason: 'the two retries are one row');
    });

    test('samples keep the first sighting and the tail', () {
      for (var i = 0; i < 20; i++) {
        dbg.log('Waku: subscribe exception port = ${1000 + i}');
      }
      final g = dbg.groups.single;
      expect(g.count, 20);
      expect(g.samples.length, lessThanOrEqualTo(6));
      expect(g.samples.first, contains('1000'),
          reason: 'the original sighting is never evicted');
      expect(g.samples.last, contains('1019'));
    });

    test('levels are inferred from the line', () {
      dbg.log(_wakuStore);
      dbg.log('IPFS: 12D3KooWRhPD in swarm but no gossipsub after 10s — continuing search');
      dbg.log('I2P: session ready — dest=abc');
      dbg.log('TRANSPORT: initializing for x');
      expect(dbg.groups.map((g) => g.level).toList(), [
        LogLevel.error,
        LogLevel.warn,
        LogLevel.ok,
        LogLevel.info,
      ]);
    });

    test('tags come off the prefix', () {
      dbg.log('IPFS: something');
      dbg.log('MSG: ← MSG frame (1130 bytes)');
      expect(dbg.groups.map((g) => g.tag), ['IPFS', 'MSG']);
    });
  });

  group('redaction — nothing identifying leaves the device', () {
    test('an I2P destination never survives', () {
      final line = 'TRANSPORT: firing I2P → $_i2pDest';
      final out = DiagnosticReport.redact(line);
      expect(out, contains('<i2p-dest>'));
      expect(out, isNot(contains(_i2pDest.substring(0, 40))));
    });

    test('libp2p peer ids never survive', () {
      final out = DiagnosticReport.redact(
          'IPFS: direct connect via stored peer ID '
          '12D3KooWJf9fcQegRq5gKgukV6TPjfYF29Ac8viwxh9sBqUfZ4qV');
      expect(out, contains('<peer-id>'));
      expect(out, isNot(contains('12D3KooWJf9')));
    });

    test('phantom ids and their truncated forms never survive', () {
      final out = DiagnosticReport.redact(
          'Waku: subscribing to /phantom/1/'
          '3h3E19U8e12HKHEByyniwzeEGaDSJHMCskkcSRqePymE4CeaEEj/proto');
      expect(out, isNot(contains('3h3E19U8')));
      final elided = DiagnosticReport.redact('TRANSPORT: firing I2P → rwv2~DAm3bAI…');
      expect(elided, isNot(contains('rwv2~DAm3bAI')));
    });

    test('the multibase topic arg never survives', () {
      final out = DiagnosticReport.redact(_ipfsRetryA);
      expect(out, isNot(contains('ubXNnM2hSR21GdGdNV2hw')));
    });

    test('a pubsub topic name carries a contact id — and did leak one', () {
      // Straight out of a field report: the debugger's own /pubsub/ls dump.
      // \b does not anchor between the "g" of msg and the "3" of the id, so
      // the phantom-id rule never fired on these.
      for (final line in const [
        'DBG:   msg3hRGmFtgMWhpZF4RVfALwAcZXK35SV3cBXp5d54mgtG5MphekUf',
        'DBG:   prs3h3E19U8e12HKHEByyniwzeEGaDSJHMCskkcSRqePymE4CeaEEj',
      ]) {
        final out = DiagnosticReport.redact(line);
        expect(out, isNot(contains('3hRGmFtg')));
        expect(out, isNot(contains('3h3E19U8')));
        expect(out, contains('<id>'));
      }
    });

    test('a truncated id shown at both ends does not slip through', () {
      final out =
          DiagnosticReport.redact('DBG: checking peers for 3hRGmF…ekUf (x)');
      expect(out, isNot(contains('3hRGmF')));
      expect(out, isNot(contains('ekUf')));
    });

    test('the relay a device sits behind is not part of the report', () {
      // The IPNS name and the relay IPv4 dash-encoded into the domain — the
      // dotted-quad rule cannot see the latter.
      final out = DiagnosticReport.redact(
          'DBG: addrs = /dns4/157-90-32-77.k51qzi5uqu5dimlh6bxx6ohmko3j7l885'
          'gxstto4dtlr0esy1fvhf36cs85wga.libp2p.direct/tcp/4001/tls/ws');
      expect(out, isNot(contains('157-90-32-77')));
      expect(out, isNot(contains('k51qzi5uqu5')));
    });

    test('loopback stays — it is the meaning of the error, and names nobody', () {
      final out = DiagnosticReport.redact(_ipfsRetryA);
      expect(out, contains('127.0.0.1'));
      expect(out, contains('Connection refused'));
    });

    test('a routable address does not stay', () {
      final out = DiagnosticReport.redact(
          'IPFS: swarm/connect 200 → /ip4/84.46.247.80/udp/4001');
      expect(out, isNot(contains('84.46.247.80')));
      expect(out, contains('<ip>'));
    });
  });

  group('report', () {
    late TransportDebugger dbg;
    setUp(() => dbg = TransportDebugger.instance..clear());

    test('errors rank above noise no matter how loud the noise is', () {
      for (var i = 0; i < 200; i++) {
        dbg.log('IPFS: gossipsub peers on topic: ${i % 2}');
      }
      dbg.log(_wakuStore);

      final report = DiagnosticReport.fromDebugger(dbg,
          environment: {'app': '1.0.0', 'platform': 'android'});
      final text = report.build();

      final errIdx = text.indexOf('storeQuery');
      final noiseIdx = text.indexOf('gossipsub');
      expect(errIdx, greaterThan(-1));
      expect(errIdx, lessThan(noiseIdx),
          reason: 'the failure belongs above the 200 polling lines');
      expect(text, contains('x200'), reason: 'the noise still shows its size');
    });

    test('the whole point: a small report instead of a huge log', () {
      for (var i = 0; i < 500; i++) {
        dbg.log('IPFS: gossipsub peers on topic: ${i % 4}');
        dbg.log('Waku: subscribe exception port = $i');
      }
      final report = DiagnosticReport.fromDebugger(dbg);
      expect(report.totalLines, 1000);
      expect(report.groups.length, 2);
      expect(report.collapsedLines, 998);
      // A thousand lines of log, a report that fits on a screen.
      expect(report.build(tailLines: 0).split('\n').length, lessThan(20));
    });

    test('environment values are redacted too', () {
      dbg.log('TRANSPORT: initializing');
      final text = DiagnosticReport.fromDebugger(dbg, environment: {
        'i2p dest': _i2pDest,
      }).build();
      expect(text, isNot(contains(_i2pDest.substring(0, 40))));
      expect(text, contains('<i2p-dest>'));
    });
  });
}

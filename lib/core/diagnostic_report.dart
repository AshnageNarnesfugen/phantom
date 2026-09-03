import 'transport_debugger.dart';

/// A short, shareable summary of what the transport stack has been doing.
///
/// It exists to replace the ritual of pasting a thousand log lines into a
/// chat. The grouped log is already the useful shape — "this failed 47 times
/// between 18:25 and 18:27" is the finding; the 47 lines are not — so a report
/// is the groups, sorted by how much they matter, plus the environment they
/// happened in.
///
/// Everything that leaves the device goes through [redact]. Phantom's own
/// logcat sink is disabled in release builds precisely because these lines
/// carry I2P destinations, libp2p peer IDs and contact IDs; a report the user
/// is invited to send somewhere must not quietly reintroduce that leak.
class DiagnosticReport {
  /// One line per environment fact — app version, platform, transport state.
  /// The caller assembles it because the debugger has no business reaching
  /// into daemons.
  final Map<String, String> environment;
  final List<LogGroup> groups;
  final List<String> rawTail;
  final int totalLines;
  final DateTime? sessionStart;
  final DateTime generatedAt;

  const DiagnosticReport({
    required this.environment,
    required this.groups,
    required this.totalLines,
    required this.generatedAt,
    this.rawTail = const [],
    this.sessionStart,
  });

  factory DiagnosticReport.fromDebugger(
    TransportDebugger dbg, {
    Map<String, String> environment = const {},
    bool includeTail = true,
  }) {
    return DiagnosticReport(
      environment: environment,
      groups: dbg.groups,
      rawTail: includeTail ? dbg.rawTail : const [],
      totalLines: dbg.totalLines,
      sessionStart: dbg.startedAt,
      generatedAt: DateTime.now(),
    );
  }

  /// Errors first, then warnings, then whatever repeated most. What you want
  /// at the top of a bug report is the thing that broke, not the thing that
  /// happened first.
  List<LogGroup> get ranked {
    final out = List.of(groups);
    out.sort((a, b) {
      final byLevel = a.level.index.compareTo(b.level.index);
      if (byLevel != 0) return byLevel;
      return b.count.compareTo(a.count);
    });
    return out;
  }

  int get errorCount =>
      groups.where((g) => g.level == LogLevel.error).length;
  int get warnCount => groups.where((g) => g.level == LogLevel.warn).length;

  /// How many raw lines the grouping absorbed — the number that makes the case
  /// for reading the report instead of the log.
  int get collapsedLines => totalLines - groups.length;

  String build({int maxGroups = 60, int tailLines = 40}) {
    final b = StringBuffer();
    b.writeln('PHANTOM DIAGNOSTIC REPORT');
    b.writeln('generated ${_stamp(generatedAt)}');
    if (sessionStart != null) {
      b.writeln('window    ${_stamp(sessionStart!)} → ${_stamp(generatedAt)} '
          '(${_duration(generatedAt.difference(sessionStart!))})');
    }
    b.writeln('log       $totalLines lines → ${groups.length} distinct '
        '($errorCount error, $warnCount warn)');

    if (environment.isNotEmpty) {
      b.writeln();
      b.writeln('── environment ──');
      final width = environment.keys
          .fold<int>(0, (m, k) => k.length > m ? k.length : m);
      for (final e in environment.entries) {
        b.writeln('${e.key.padRight(width)}  ${redact(e.value)}');
      }
    }

    b.writeln();
    b.writeln('── what happened ──');
    if (groups.isEmpty) {
      b.writeln('(nothing logged)');
    } else {
      final shown = ranked.take(maxGroups);
      // Fixed-width severity block so the messages line up in a paste.
      final head = <LogGroup, String>{
        for (final g in shown)
          g: '[${_lvl(g.level)}${g.count > 1 ? " x${g.count}" : ""}]'
      };
      final pad =
          head.values.fold<int>(0, (m, h) => h.length > m ? h.length : m);
      for (final g in shown) {
        b.writeln('${head[g]!.padRight(pad)} ${redact(g.message)}');
        b.writeln('${" " * pad} ${_hms(g.firstAt)}'
            '${g.count > 1 ? " → ${_hms(g.lastAt)}" : ""}');
      }
      final hidden = groups.length - shown.length;
      if (hidden > 0) b.writeln('… and $hidden more distinct messages');
    }

    if (rawTail.isNotEmpty && tailLines > 0) {
      final tail = rawTail.length > tailLines
          ? rawTail.sublist(rawTail.length - tailLines)
          : rawTail;
      b.writeln();
      b.writeln('── last ${tail.length} lines, verbatim ──');
      for (final line in tail) {
        b.writeln(redact(line));
      }
    }
    return b.toString();
  }

  // ── Redaction ─────────────────────────────────────────────────────────────

  // Order matters: the longest, most specific shapes are consumed first so a
  // later, broader rule cannot chew a destination into fragments it no longer
  // recognises.
  static final _i2pDest = RegExp(r'[A-Za-z0-9~-]{80,}={0,2}');
  static final _peerId = RegExp(r'\b(?:12D3Koo|16Uiu2|Qm)[A-Za-z0-9]{20,}');
  // An IPNS name in a libp2p.direct relay domain, and the relay's own IPv4
  // dash-encoded into that domain — both say which relay this device sits
  // behind, which the dotted-quad rule below never sees.
  static final _ipnsName = RegExp(r'\bk51[a-z0-9]{20,}');
  static final _dashedIp = RegExp(r'(?<![\d-])\d{1,3}-\d{1,3}-\d{1,3}-\d{1,3}(?![\d-])');
  static final _multibaseTopic = RegExp(r'\bu[A-Za-z0-9_-]{24,}');
  // The optional lowercase prefix is the whole point: pubsub topics are
  // `msg<phantomId>` / `prs<phantomId>`, and \b does not anchor between the
  // `g` of "msg" and the `3` that starts the id — so every /pubsub/ls dump the
  // debugger printed carried a full contact id straight through redaction.
  static final _phantomId =
      RegExp(r'(?<![A-Za-z0-9])[a-z]{0,4}3[A-HJ-NP-Za-km-z1-9]{7,}');
  // Truncated display forms: `3hRGmF…ekUf` is short at both ends and slipped
  // under both the id rule's length floor and the generic elision rule's.
  static final _elidedShort =
      RegExp(r'(?<![A-Za-z0-9])3[A-HJ-NP-Za-km-z1-9]{3,}…(?:[A-Za-z0-9]{2,8})?');
  static final _elided = RegExp(r'[A-Za-z0-9~+/_-]{8,}…');
  static final _ipv4 = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');

  /// Strips the network locators and social graph out of a log line, leaving
  /// the part that describes the failure.
  ///
  /// Loopback addresses survive deliberately: `127.0.0.1` says "our own
  /// bundled daemon", which is the whole meaning of a connection-refused here,
  /// and it identifies nobody.
  static String redact(String s) {
    var out = s;
    out = out.replaceAll(_i2pDest, '<i2p-dest>');
    out = out.replaceAll(_peerId, '<peer-id>');
    out = out.replaceAll(_ipnsName, '<peer-id>');
    out = out.replaceAll(_dashedIp, '<ip>');
    out = out.replaceAll(_multibaseTopic, '<topic>');
    out = out.replaceAll(_elidedShort, '<id>');
    out = out.replaceAll(_phantomId, '<id>');
    out = out.replaceAll(_elided, '<id>…');
    out = out.replaceAllMapped(
        _ipv4, (m) => m[0]!.startsWith('127.') ? m[0]! : '<ip>');
    return out;
  }

  // ── formatting ────────────────────────────────────────────────────────────

  static String _lvl(LogLevel l) => switch (l) {
        LogLevel.error => 'ERR',
        LogLevel.warn => 'WRN',
        LogLevel.ok => ' OK',
        LogLevel.info => 'INF',
      };

  static String _p(int n) => n.toString().padLeft(2, '0');

  static String _hms(DateTime d) =>
      '${_p(d.hour)}:${_p(d.minute)}:${_p(d.second)}';

  static String _stamp(DateTime d) =>
      '${d.year}-${_p(d.month)}-${_p(d.day)} ${_hms(d)}';

  static String _duration(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}m';
    return '${d.inHours}h${_p(d.inMinutes % 60)}m';
  }
}

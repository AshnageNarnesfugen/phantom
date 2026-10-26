part of 'screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TRANSPORT DEBUGGER SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class _TransportDebugScreen extends StatefulWidget {
  final PhantomCore? core;
  const _TransportDebugScreen({required this.core});

  @override
  State<_TransportDebugScreen> createState() => _TransportDebugScreenState();
}

class _TransportDebugScreenState extends State<_TransportDebugScreen> {
  String get _apiBase => '${IpfsDaemon.apiUrl}/api/v0';
  final _client         = http.Client();
  final _logScroll      = ScrollController();
  StreamSubscription<LogGroup>? _logSub;
  // Batch log updates to prevent setState storms (e.g. reconnect spin-loops).
  Timer? _logFlushTimer;
  bool   _logDirty = false;

  /// Grouped rows, newest-changed counts included. Read straight from the
  /// debugger on each flush — it owns the grouping, this only paints it.
  List<LogGroup> _log = [];
  /// Signatures whose sample list is expanded (the dropdown).
  final Set<String> _expanded = {};
  /// null = everything; otherwise only rows at or above this severity.
  LogLevel? _filter;
  bool _autoScroll = true;
  bool _loading = false;

  // Status
  String? _peerId;
  int     _swarmPeers   = 0;
  List<String> _topics  = [];
  Map<String, int> _contactPeers = {};
  bool _wakuRunning = false;
  int  _wakuPeers   = 0;
  bool _wakuBinaryMissing = false;

  @override
  void initState() {
    super.initState();
    _log = TransportDebugger.instance.groups;
    _logSub = TransportDebugger.instance.stream.listen(_onLogEvent);
    _runAutoStatus();
  }

  void _onLogEvent(LogGroup _) {
    _logDirty = true;
    if (_logFlushTimer != null) return;
    // Flush at most ~10 times/s regardless of log volume. A repeat only moves
    // a counter, so this is now a repaint of one row's badge rather than a
    // list that grows without bound.
    _logFlushTimer = Timer(const Duration(milliseconds: 100), () {
      _logFlushTimer = null;
      if (!mounted || !_logDirty) return;
      _logDirty = false;
      setState(() => _log = TransportDebugger.instance.groups);
      if (!_autoScroll) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });
  }

  List<LogGroup> get _visibleLog {
    if (_filter == null) return _log;
    return _log.where((g) => g.level.index <= _filter!.index).toList();
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _logFlushTimer?.cancel();
    _client.close();
    _logScroll.dispose();
    super.dispose();
  }

  // ── Multibase helpers (Kubo >= 0.11 requires encoded pubsub topic args) ──

  static String _encodeTopic(String topic) {
    final bytes = utf8.encode(topic);
    return 'u${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  static String _decodeTopic(String encoded) {
    try {
      if (encoded.startsWith('u')) {
        return utf8.decode(base64Url.decode(
            base64Url.normalize(encoded.substring(1))));
      }
      if (encoded.startsWith('m')) {
        return utf8.decode(base64.decode(encoded.substring(1)));
      }
    } catch (_) {}
    return encoded;
  }

  // ── HTTP helpers ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _post(String path, {String? arg, bool encodeTopic = false}) async {
    try {
      final encodedArg = (arg != null && encodeTopic) ? _encodeTopic(arg) : arg;
      final uri = encodedArg != null
          ? Uri.parse('$_apiBase$path?arg=${Uri.encodeComponent(encodedArg)}')
          : Uri.parse('$_apiBase$path');
      final resp = await _client.post(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _runAutoStatus() async {
    await _fetchIpfsId();
    await _fetchSwarmPeers();
    await _fetchTopics();
    await _fetchContactPeers();
    await _fetchWakuStatusQuiet();
  }

  /// Updates the Waku status chip without spamming the live log. Use this
  /// from the auto-status loop; the verbose [_fetchWakuStatus] action dumps
  /// the daemon's stdout/stderr buffer into the log instead.
  Future<void> _fetchWakuStatusQuiet() async {
    try {
      final s = await WakuDaemon.instance.status();
      if (!mounted) return;
      setState(() {
        _wakuRunning = s.running;
        _wakuPeers   = s.peers;
        _wakuBinaryMissing = WakuDaemon.instance.binaryMissing;
      });
    } catch (_) {}
  }

  Future<void> _fetchWakuStatus() async {
    final dbg = TransportDebugger.instance;
    dbg.log('DBG: ── Waku status ──');
    if (WakuDaemon.instance.binaryMissing) {
      dbg.log('DBG: ⚠ libgowaku.so NOT bundled in jniLibs — daemon never spawned');
      dbg.log('DBG:   add the .so to android/app/src/main/jniLibs/<arch>/ and rebuild');
    } else {
      try {
        final s = await WakuDaemon.instance.status();
        dbg.log('DBG: Waku running: ${s.running}');
        dbg.log('DBG: Waku peers:   ${s.peers}');
        dbg.log('DBG: Waku REST:    ${WakuDaemon.instance.apiUrl}');
      } catch (e) {
        dbg.log('DBG: Waku status FAILED: $e');
      }
    }
    // Replay the captured daemon stdout/stderr so the user can see whether
    // libgowaku is bootstrapping, listening on a port, peering, or crashing.
    // The Waku daemon's own logs are otherwise invisible — they're only
    // surfaced via the WakuDaemon._logBuf StringBuffer.
    final daemonLog = WakuDaemon.instance.daemonLog;
    dbg.log('DBG: Waku daemon log:');
    for (final line in daemonLog.split('\n')) {
      if (line.trim().isEmpty) continue;
      dbg.log('DBG:   $line');
    }
    dbg.log('DBG: ── end Waku status ──');
    await _fetchWakuStatusQuiet();
  }

  Future<void> _fetchIpfsId() async {
    TransportDebugger.instance.log('DBG: GET /id');
    final r = await _post('/id');
    if (!mounted) return;
    setState(() => _peerId = r?['ID'] as String? ?? '(error)');
    if (r != null) {
      final addrs = (r['Addresses'] as List?)?.cast<String>() ?? [];
      TransportDebugger.instance.log('DBG: peer ID = ${r['ID']}');
      TransportDebugger.instance.log('DBG: addrs = ${addrs.join(', ')}');
    } else {
      TransportDebugger.instance.log('DBG: /id FAILED — IPFS API not reachable');
    }
  }

  Future<void> _fetchSwarmPeers() async {
    TransportDebugger.instance.log('DBG: GET /swarm/peers');
    final r = await _post('/swarm/peers');
    if (!mounted) return;
    final peers = (r?['Peers'] as List?) ?? [];
    setState(() => _swarmPeers = peers.length);
    TransportDebugger.instance.log('DBG: swarm peers = ${peers.length}');
    for (final p in peers.take(5)) {
      final addr = (p as Map)['Addr'] ?? (p)['Peer'] ?? '?';
      TransportDebugger.instance.log('DBG:   peer $addr');
    }
    if (peers.length > 5) {
      TransportDebugger.instance.log('DBG:   … and ${peers.length - 5} more');
    }
  }

  Future<void> _fetchTopics() async {
    TransportDebugger.instance.log('DBG: GET /pubsub/ls');
    final r = await _post('/pubsub/ls');
    if (!mounted) return;
    final raw    = (r?['Strings'] as List?)?.cast<String>() ?? [];
    final topics = raw.map(_decodeTopic).toList();
    setState(() => _topics = topics);
    TransportDebugger.instance.log('DBG: subscribed topics (${topics.length}):');
    for (final t in topics) {
      TransportDebugger.instance.log('DBG:   $t');
    }
    if (topics.isEmpty) {
      TransportDebugger.instance.log('DBG: ⚠ NO subscribed topics — pubsub subscription may not be active');
    }
  }

  Future<void> _fetchContactPeers() async {
    final core = widget.core;
    if (core == null) return;
    final contacts = await core.getContacts();
    final results  = <String, int>{};
    for (final c in contacts) {
      final msgTopic = '/phantom/v1/${c.phantomId}';
      final prsTopic = '/phantom/prs/v1/${c.phantomId}';
      TransportDebugger.instance.log('DBG: checking peers for ${c.displayName} (${c.phantomId.substring(0, 8)}…)');
      final msgR = await _post('/pubsub/peers', arg: msgTopic, encodeTopic: true);
      final prsR = await _post('/pubsub/peers', arg: prsTopic, encodeTopic: true);
      final msgPeers = (msgR?['Strings'] as List?)?.length ?? 0;
      final prsPeers = (prsR?['Strings'] as List?)?.length ?? 0;
      TransportDebugger.instance.log(
        'DBG:   msg-topic peers=$msgPeers  prs-topic peers=$prsPeers');
      results[c.phantomId] = msgPeers;
    }
    if (mounted) setState(() => _contactPeers = results);
  }

  Future<void> _forcePingContact(ContactRecord contact) async {
    setState(() => _loading = true);
    final topic = '/phantom/v1/${contact.phantomId}';
    TransportDebugger.instance.log('DBG: force-ping ${contact.displayName} on $topic');
    try {
      final uri = Uri.parse(
          '$_apiBase/pubsub/pub?arg=${Uri.encodeComponent(_encodeTopic(topic))}');
      final request = http.MultipartRequest('POST', uri);
      request.files.add(http.MultipartFile.fromBytes('data', [0xDE, 0xAD]));
      final streamedResp = await _client.send(request).timeout(const Duration(seconds: 5));
      final resp = await http.Response.fromStream(streamedResp);
      final msg = 'force-ping HTTP ${resp.statusCode}: ${resp.body.isEmpty ? "OK" : resp.body}';
      TransportDebugger.instance.log('DBG: $msg');
    } catch (e) {
      TransportDebugger.instance.log('DBG: force-ping FAILED: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _flushQueue() async {
    TransportDebugger.instance.log('DBG: flushing message queue');
    await widget.core?.onAppResumed();
    TransportDebugger.instance.log('DBG: flush triggered');
  }

  Future<void> _checkMySubTopic() async {
    final core = widget.core;
    if (core == null) return;
    final myTopic = '/phantom/v1/${core.myId}';
    TransportDebugger.instance.log('DBG: checking MY own subscription on $myTopic');
    final r = await _post('/pubsub/peers', arg: myTopic, encodeTopic: true);
    final peers = (r?['Strings'] as List?)?.cast<String>() ?? [];
    TransportDebugger.instance.log('DBG: peers on MY msg topic: ${peers.length}');
    for (final p in peers) {
      TransportDebugger.instance.log('DBG:   $p');
    }
    if (peers.isEmpty) {
      TransportDebugger.instance.log('DBG: ⚠ nobody is subscribed to MY topic yet');
    }
  }

  void _copyLog() {
    final dbg = TransportDebugger.instance;
    final text = dbg.groups
        .map((g) => '${g.count > 1 ? "x${g.count} " : ""}${g.message}')
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${dbg.groups.length} rows copied '
          '(${dbg.totalLines} lines collapsed)'),
      duration: const Duration(seconds: 2),
    ));
  }

  void _clearLog() {
    TransportDebugger.instance.clear();
    setState(() {
      _log = const [];
      _expanded.clear();
    });
  }

  /// Facts about the device and the stack that a log line alone never carries,
  /// and that are the first thing anyone reading a report asks for.
  Future<Map<String, String>> _environment() async {
    final env = <String, String>{};
    try {
      final info = await PackageInfo.fromPlatform();
      env['app'] = '${info.version} (build ${info.buildNumber})';
    } catch (_) {}
    env['platform'] = Platform.operatingSystemVersion;

    final core = widget.core;
    if (core != null) {
      final i2p = core.transport.transports.whereType<I2PTransport>().firstOrNull;
      env['i2p'] = i2p == null
          ? 'not instantiated'
          : i2p.isSessionReady
              ? 'session ready'
              : i2p.isSamReachable
                  ? 'SAM up, session not ready '
                      '(${i2p.sessionAttemptFailures} failed attempts)'
                  : 'SAM unreachable';
      final ygg = core.transport.transports.whereType<YggdrasilTransport>().firstOrNull;
      env['ygg'] = ygg?.address == null ? 'off' : 'up';
      env['transports'] = core.transport.activeTransportNames.join(', ');
      env['contacts'] = '${(await core.getContacts()).length}';
    }
    env['ipfs'] = _peerId == null || _peerId == '(error)'
        ? 'API unreachable'
        : 'API ok, swarm $_swarmPeers, ${_topics.length} topics';
    env['waku'] = _wakuBinaryMissing
        ? 'libgowaku.so missing'
        : _wakuRunning
            ? 'running, $_wakuPeers peers'
            : 'stopped';
    return env;
  }

  Future<void> _openReport() async {
    final env = await _environment();
    if (!mounted) return;
    final report = DiagnosticReport.fromDebugger(
      TransportDebugger.instance,
      environment: env,
    );
    await Navigator.push(context,
        _AppRoute(builder: (_) => _DiagnosticReportScreen(report: report)));
  }

  Future<void> _restartDaemon() async {
    TransportDebugger.instance.log('DBG: stopping IPFS daemon…');
    await IpfsDaemon.instance.stop();
    TransportDebugger.instance.log('DBG: restarting IPFS daemon…');
    await IpfsDaemon.instance.ensure();
    TransportDebugger.instance.log('DBG: daemon restart complete — refreshing status');
    await _runAutoStatus();
  }

  Future<void> _fetchYggStatus() async {
    final dbg = TransportDebugger.instance;
    final core = widget.core;
    dbg.log('DBG: ── Yggdrasil status ──');

    if (core == null) {
      dbg.log('DBG: core not available');
      return;
    }

    final ygg = core.transport.transports.whereType<YggdrasilTransport>().firstOrNull;
    if (ygg == null) {
      dbg.log('DBG: Yggdrasil transport not instantiated');
      return;
    }

    dbg.log('DBG: Yggdrasil address: ${ygg.address ?? "(none — auto-detect pending)"}');
    dbg.log('DBG: Yggdrasil available: ${ygg.isAvailable}');

    // Check if it's in the active transports
    final isActive = core.transport.transports.contains(ygg);
    dbg.log('DBG: Yggdrasil in transport list: $isActive');

    // Check contacts with Ygg addresses
    final contacts = await core.getContacts();
    final withYgg = contacts.where((c) => c.yggdrasilAddress != null);
    if (withYgg.isEmpty) {
      dbg.log('DBG: no contacts have Yggdrasil addresses');
    } else {
      for (final c in withYgg) {
        dbg.log('DBG: ${c.displayName} → ygg ${c.yggdrasilAddress}');
      }
    }

    // Test IPv6 binding
    try {
      final testSock = await ServerSocket.bind(InternetAddress.anyIPv6, 0);
      dbg.log('DBG: IPv6 bind test OK (port ${testSock.port})');
      await testSock.close();
    } catch (e) {
      dbg.log('DBG: ⚠ IPv6 bind test FAILED: $e');
    }

    dbg.log('DBG: ── end Yggdrasil status ──');
    if (mounted) setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgBase,
        foregroundColor: t.textPrimary,
        title: Text('transport debugger',
            style: TextStyle(fontFamily: 'monospace', fontSize: 14, color: t.textPrimary)),
        actions: [
          IconButton(
            icon: Icon(Icons.summarize_outlined, size: 18, color: t.accentLight),
            tooltip: 'diagnostic report',
            onPressed: _openReport,
          ),
          IconButton(
            icon: Icon(Icons.copy_outlined, size: 18, color: t.textSecondary),
            tooltip: 'copy log',
            onPressed: _copyLog,
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, size: 18, color: t.textSecondary),
            tooltip: 'clear log',
            onPressed: _clearLog,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Status cards ──────────────────────────────────────────────────
          _buildStatusRow(t),
          const Divider(height: 1),
          // ── Action buttons ────────────────────────────────────────────────
          _buildActions(t),
          const Divider(height: 1),
          // ── Live log (grouped: one row per distinct message) ───────────────
          _buildLogBar(t),
          const Divider(height: 1),
          Expanded(child: _buildLog(t)),
        ],
      ),
    );
  }

  Widget _buildStatusRow(PhantomTokens t) {
    return Container(
      color: t.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _StatusChip(
              label: 'API',
              value: _peerId != null ? (_peerId == '(error)' ? 'ERR' : 'OK') : '?',
              ok: _peerId != null && _peerId != '(error)',
              tokens: t,
            ),
            const SizedBox(width: 8),
            _StatusChip(
              label: 'swarm',
              value: '$_swarmPeers peers',
              ok: _swarmPeers > 0,
              tokens: t,
            ),
            const SizedBox(width: 8),
            _StatusChip(
              label: 'topics',
              value: '${_topics.length} subs',
              ok: _topics.isNotEmpty,
              tokens: t,
            ),
            const SizedBox(width: 8),
            _StatusChip(
              label: 'waku',
              value: _wakuBinaryMissing
                  ? 'no.so'
                  : _wakuRunning ? '$_wakuPeers peers' : 'off',
              ok: _wakuRunning,
              tokens: t,
            ),
            const SizedBox(width: 8),
            if (widget.core != null) ...[
              _StatusChip(
                label: 'ygg',
                value: widget.core!.transport.transports
                    .whereType<YggdrasilTransport>()
                    .firstOrNull?.address?.substring(0, 8) ?? 'off',
                ok: widget.core!.transport.transports
                    .whereType<YggdrasilTransport>()
                    .firstOrNull?.address != null,
                tokens: t,
              ),
              const SizedBox(width: 8),
              for (final e in _contactPeers.entries) ...[
                _StatusChip(
                  label: e.key.substring(0, 6),
                  value: '${e.value}p',
                  ok: e.value > 0,
                  tokens: t,
                ),
                const SizedBox(width: 8),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActions(PhantomTokens t) {
    return Container(
      color: t.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _DbgButton(label: 'refresh all', tokens: t, onTap: _runAutoStatus),
            _DbgButton(label: 'my ID', tokens: t, onTap: _fetchIpfsId),
            _DbgButton(label: 'swarm peers', tokens: t, onTap: _fetchSwarmPeers),
            _DbgButton(label: 'topics', tokens: t, onTap: _fetchTopics),
            _DbgButton(label: 'contact peers', tokens: t, onTap: _fetchContactPeers),
            _DbgButton(label: 'my sub?', tokens: t, onTap: _checkMySubTopic),
            _DbgButton(label: 'ygg status', tokens: t, onTap: _fetchYggStatus),
            _DbgButton(label: 'waku status', tokens: t, onTap: _fetchWakuStatus),
            _DbgButton(label: 'restart daemon', tokens: t, danger: true, onTap: _restartDaemon),
            _DbgButton(label: 'flush queue', tokens: t, accent: true, onTap: _flushQueue),
            if (widget.core != null)
              FutureBuilder<List<ContactRecord>>(
                future: widget.core!.getContacts(),
                builder: (ctx, snap) {
                  final contacts = snap.data ?? [];
                  return Row(
                    children: contacts.map((c) => _DbgButton(
                      label: 'ping ${c.displayName.substring(0, c.displayName.length.clamp(0, 8))}',
                      tokens: t,
                      danger: true,
                      onTap: _loading ? null : () => _forcePingContact(c),
                    )).toList(),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLog(PhantomTokens t) {
    final rows = _visibleLog;
    if (rows.isEmpty) {
      return Center(
        child: Text(
            _log.isEmpty ? 'no log entries yet' : 'nothing at this level',
            style: TextStyle(
                color: t.textDisabled, fontFamily: 'monospace', fontSize: 12)),
      );
    }
    return Scrollbar(
      controller: _logScroll,
      child: ListView.builder(
        controller: _logScroll,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: rows.length,
        itemBuilder: (_, i) => _LogRow(
          group: rows[i],
          tokens: t,
          expanded: _expanded.contains(rows[i].signature),
          onTap: () {
            final sig = rows[i].signature;
            setState(() {
              if (!_expanded.remove(sig)) _expanded.add(sig);
              // Reading a specific row means you no longer want the list
              // yanked to the bottom every 100ms.
              _autoScroll = false;
            });
          },
        ),
      ),
    );
  }

  /// Severity filter + the "N lines collapsed into M rows" counter, which is
  /// the number that tells you whether the log is busy or actually broken.
  Widget _buildLogBar(PhantomTokens t) {
    final dbg = TransportDebugger.instance;
    final errs = _log.where((g) => g.level == LogLevel.error).length;
    final warns = _log.where((g) => g.level == LogLevel.warn).length;
    return Container(
      color: t.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _FilterChip(
              label: 'all ${_log.length}',
              selected: _filter == null,
              tokens: t,
              onTap: () => setState(() => _filter = null)),
          _FilterChip(
              label: 'err $errs',
              color: _levelColor(LogLevel.error),
              selected: _filter == LogLevel.error,
              tokens: t,
              onTap: () => setState(() => _filter = LogLevel.error)),
          _FilterChip(
              label: 'warn ${errs + warns}',
              color: _levelColor(LogLevel.warn),
              selected: _filter == LogLevel.warn,
              tokens: t,
              onTap: () => setState(() => _filter = LogLevel.warn)),
          const Spacer(),
          Text('${dbg.totalLines} lines',
              style: TextStyle(
                  color: t.textDisabled, fontFamily: 'monospace', fontSize: 10)),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => setState(() => _autoScroll = !_autoScroll),
            child: Icon(
                _autoScroll
                    ? Icons.vertical_align_bottom
                    : Icons.pause_circle_outline,
                size: 16,
                color: _autoScroll ? t.accentLight : t.textDisabled),
          ),
        ],
      ),
    );
  }
}

Color _levelColor(LogLevel l) => switch (l) {
      LogLevel.error => const Color(0xFFCF6679),
      LogLevel.warn => const Color(0xFFFFB74D),
      LogLevel.ok => const Color(0xFF4CAF50),
      LogLevel.info => const Color(0xFF90A4AE),
    };

/// One collapsed message: a severity dot, the text, and a repeat counter that
/// opens the raw samples. Modelled on a browser console — the counter is the
/// whole point, because the same line firing 200 times is one fact, not 200.
class _LogRow extends StatelessWidget {
  final LogGroup group;
  final PhantomTokens tokens;
  final bool expanded;
  final VoidCallback onTap;
  const _LogRow({
    required this.group,
    required this.tokens,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = _levelColor(group.level);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 6),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                ),
                Expanded(
                  child: Text(
                    group.message,
                    maxLines: expanded ? null : 3,
                    overflow: expanded ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        height: 1.45,
                        color: color),
                  ),
                ),
                if (group.isRepeated) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('x${group.count}',
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: color)),
                  ),
                ],
                Icon(
                    expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 13,
                    color: tokens.textDisabled),
              ],
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.only(left: 11, top: 4, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.isRepeated
                          ? '${group.count}x  ${_hms(group.firstAt)} → '
                              '${_hms(group.lastAt)}'
                          : _hms(group.firstAt),
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 9,
                          color: tokens.textDisabled),
                    ),
                    const SizedBox(height: 3),
                    for (final sample in group.samples)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(sample,
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 9,
                                height: 1.4,
                                color: tokens.textDisabled)),
                      ),
                    if (group.count > group.samples.length)
                      Text(
                          '(${group.count - group.samples.length} more '
                          'occurrences not kept)',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              fontStyle: FontStyle.italic,
                              color: tokens.textDisabled)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _hms(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final PhantomTokens tokens;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.tokens,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? tokens.textSecondary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: selected ? 0.20 : 0.06),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: c.withValues(alpha: selected ? 0.6 : 0.2), width: 0.5),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? c : c.withValues(alpha: 0.6),
                fontFamily: 'monospace',
                fontSize: 10)),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String       label;
  final String       value;
  final bool         ok;
  final PhantomTokens tokens;
  const _StatusChip({required this.label, required this.value, required this.ok, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF4CAF50) : const Color(0xFFCF6679);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: tokens.textDisabled, fontFamily: 'monospace', fontSize: 9)),
          Text(value, style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 11)),
        ],
      ),
    );
  }
}

class _DbgButton extends StatelessWidget {
  final String        label;
  final VoidCallback? onTap;
  final PhantomTokens tokens;
  final bool          accent;
  final bool          danger;
  const _DbgButton({
    required this.label,
    required this.tokens,
    this.onTap,
    this.accent = false,
    this.danger  = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger  ? const Color(0xFFCF6679)
                : accent  ? const Color(0xFF4CAF50)
                : tokens.textSecondary;
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: enabled ? 0.12 : 0.05),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: color.withValues(alpha: enabled ? 0.4 : 0.15), width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? color : color.withValues(alpha: 0.4),
            fontFamily: 'monospace',
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DIAGNOSTIC REPORT
// ─────────────────────────────────────────────────────────────────────────────

/// The report as a screen: read it, copy it, or drop it in a file to attach.
///
/// There is deliberately no "upload" button. These logs are the reason the
/// logcat sink is compiled out of release builds; shipping them to a server by
/// default would hand a third party the metadata the whole app exists to
/// withhold. The report is redacted and small enough to paste by hand, and
/// where it goes stays the user's decision.
class _DiagnosticReportScreen extends StatefulWidget {
  final DiagnosticReport report;
  const _DiagnosticReportScreen({required this.report});

  @override
  State<_DiagnosticReportScreen> createState() =>
      _DiagnosticReportScreenState();
}

class _DiagnosticReportScreenState extends State<_DiagnosticReportScreen> {
  bool _includeTail = true;
  String? _savedPath;

  String get _text =>
      widget.report.build(tailLines: _includeTail ? 40 : 0);

  void _copy() {
    Clipboard.setData(ClipboardData(text: _text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('report copied (${_text.length} chars)'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _save() async {
    try {
      Directory dir;
      try {
        dir = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
      } catch (_) {
        dir = await getApplicationDocumentsDirectory();
      }
      final now = widget.report.generatedAt;
      String p(int n) => n.toString().padLeft(2, '0');
      final name = 'phantom-diagnostic-${now.year}${p(now.month)}${p(now.day)}'
          '-${p(now.hour)}${p(now.minute)}${p(now.second)}.txt';
      final file = File('${dir.path}/$name');
      // The file carries the whole raw timeline, not the 40-line tail the
      // on-screen copy shows: correlating two phones means lining up exact
      // timestamps of every frame in and out, and the 40 lines on either side
      // rarely overlap.
      await file.writeAsString(widget.report.build(
          tailLines: _includeTail ? widget.report.rawTail.length : 0));
      if (!mounted) return;
      setState(() => _savedPath = file.path);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('saved to ${file.path}'),
        duration: const Duration(seconds: 4),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    final r = widget.report;
    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgBase,
        foregroundColor: t.textPrimary,
        title: Text('diagnostic report',
            style: TextStyle(
                fontFamily: 'monospace', fontSize: 14, color: t.textPrimary)),
        actions: [
          IconButton(
            icon: Icon(Icons.copy_outlined, size: 18, color: t.accentLight),
            tooltip: 'copy',
            onPressed: _copy,
          ),
          IconButton(
            icon: Icon(Icons.save_alt_outlined, size: 18, color: t.textSecondary),
            tooltip: 'save to file',
            onPressed: _save,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: t.bgSurface,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.totalLines} log lines → ${r.groups.length} distinct '
                  '(${r.errorCount} error, ${r.warnCount} warn)',
                  style: TextStyle(
                      color: t.textSecondary,
                      fontFamily: 'monospace',
                      fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  'IDs, I2P destinations and public addresses are stripped.',
                  style: TextStyle(
                      color: t.textDisabled,
                      fontFamily: 'monospace',
                      fontSize: 10),
                ),
                if (_savedPath != null) ...[
                  const SizedBox(height: 4),
                  SelectableText(_savedPath!,
                      style: TextStyle(
                          color: t.accentLight,
                          fontFamily: 'monospace',
                          fontSize: 9)),
                ],
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () => setState(() => _includeTail = !_includeTail),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                          _includeTail
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          size: 15,
                          color: t.textSecondary),
                      const SizedBox(width: 6),
                      Text('include the last 40 lines verbatim',
                          style: TextStyle(
                              color: t.textSecondary,
                              fontFamily: 'monospace',
                              fontSize: 10)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                _text,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    height: 1.45,
                    color: t.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

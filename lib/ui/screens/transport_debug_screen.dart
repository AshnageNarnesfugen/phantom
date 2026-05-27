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
  StreamSubscription<String>? _logSub;
  // Batch log updates to prevent setState storms (e.g. reconnect spin-loops).
  Timer?       _logFlushTimer;
  List<String> _pendingLines = [];

  List<String> _log     = [];
  bool         _loading = false;

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
    _log = List.of(TransportDebugger.instance.entries);
    _logSub = TransportDebugger.instance.stream.listen(_onLogLine);
    _runAutoStatus();
  }

  void _onLogLine(String line) {
    _pendingLines.add(line);
    if (_logFlushTimer != null) return;
    // Flush at most ~10 times/s regardless of log volume.
    _logFlushTimer = Timer(const Duration(milliseconds: 100), () {
      _logFlushTimer = null;
      if (!mounted) return;
      setState(() => _log.addAll(_pendingLines));
      _pendingLines = [];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });
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
    Clipboard.setData(ClipboardData(text: _log.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Log copied to clipboard'), duration: Duration(seconds: 2)),
    );
  }

  void _clearLog() {
    TransportDebugger.instance.clear();
    setState(() => _log.clear());
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
          // ── Live log ──────────────────────────────────────────────────────
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
    if (_log.isEmpty) {
      return Center(
        child: Text('no log entries yet',
            style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 12)),
      );
    }
    return Scrollbar(
      controller: _logScroll,
      child: ListView.builder(
        controller: _logScroll,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        itemCount: _log.length,
        itemBuilder: (_, i) {
          final line = _log[i];
          final isErr  = line.contains('FAIL') || line.contains('ERR') || line.contains('✗');
          final isWarn = line.contains('⚠') || line.contains('no peers');
          final isOk   = line.contains('✓') || line.contains('OK') || line.contains('ready');
          final isHandshake = line.contains('handshake') || line.contains('PREWARM');
          final isMesh = line.contains('gossipsub mesh') || line.contains('waiting for');
          final color  = isErr  ? const Color(0xFFCF6679)
                       : isWarn ? const Color(0xFFFFB74D)
                       : isOk   ? const Color(0xFF4CAF50)
                       : isHandshake ? const Color(0xFF81D4FA)
                       : isMesh ? const Color(0xFFCE93D8)
                       : t.textSecondary;
          return Text(
            line,
            style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: color, height: 1.5),
          );
        },
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

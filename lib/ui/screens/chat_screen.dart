part of 'screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CHAT SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  final String contactName;
  final String contactId;

  const ChatScreen({super.key, required this.contactName, required this.contactId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollCtrl = ScrollController();
  List<StoredMessage>? _messages;
  StreamSubscription<StoredMessage>? _sub;
  StreamSubscription<String>? _presenceSub;
  StreamSubscription<String>? _handshakeSub;
  StreamSubscription<String>? _contactSub;
  // Live display name. Starts with widget.contactName but tracks subsequent
  // edits via the contactChanges stream so the AppBar refreshes the moment
  // the user saves a new nickname instead of waiting for the next entry.
  String? _displayName;
  bool _isVerified = false;
  StoredMessage? _replyTo;

  /// The already-read receipt re-fire (see _loadMessages) may run only once
  /// per screen lifetime. _loadMessages re-runs on EVERY incoming event —
  /// including the peer's own readReceipt events — so re-firing on each
  /// reload created a receipt ping-pong storm: receipt in → reload →
  /// receipts out → peer's screen reloads → receipts back, ~2 msg/s forever
  /// (observed in the field, both devices, sustained).
  bool _receiptsRefired = false;
  String?   _wallpaperPath;
  BoxFit    _bgFit       = BoxFit.cover;
  Alignment _bgAlignment = Alignment.center;
  ui.Image? _blurredBg;
  PhantomCore? _core; // cached — safe to use in dispose()

  // Glass effect state
  bool   _glassEnabled       = false;
  double _glassOpacity       = 0.12;
  double _glassBlur          = 10.0;
  bool   _glassBgBlur        = false;
  bool   _glassNoise         = false;
  double _glassNoiseStrength = 0.15;
  ui.Image? _noiseImage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    _core = core;
    if (core != null && _sub == null) {
      core.setActiveChat(widget.contactId);
      _sub = core.incomingMessages.listen((msg) {
        if (msg.conversationId == widget.contactId) _loadMessages(core);
      });
      _presenceSub = core.presenceChanges.listen((id) {
        if (id == widget.contactId && mounted) setState(() {});
      });
      // Re-render when the handshake-ack state flips so the "waiting for
      // first response" banner appears / disappears in real time.
      _handshakeSub = core.handshakeStateChanges.listen((id) {
        if (id == widget.contactId && mounted) setState(() {});
      });
      // Reload contact-derived display name when nickname/alias change so
      // the AppBar updates without a screen pop/push. The same stream fires
      // when a media message finishes downloading from IPFS, so reload the
      // message list too — that's how a "[image]" placeholder becomes the
      // actual picture without leaving the chat.
      _contactSub = core.contactChanges.listen((id) {
        if (id == widget.contactId) {
          _refreshDisplayName(core);
          _loadMessages(core);
        }
      });
      _refreshDisplayName(core);
      _loadMessages(core);
      _loadWallpaper(core);
      _loadGlass(core);
    }
  }

  Future<void> _refreshDisplayName(PhantomCore core) async {
    final c = await core.storage.getContact(widget.contactId);
    if (!mounted) return;
    final newName = c?.displayName ?? widget.contactName;
    final newVerified = c?.isVerified ?? false;
    if (newName != _displayName || newVerified != _isVerified) {
      setState(() {
        _displayName = newName;
        _isVerified  = newVerified;
      });
    }
  }

  Future<void> _loadWallpaper(PhantomCore core) async {
    final path = await core.storage.getWallpaper(widget.contactId)
              ?? await core.storage.getWallpaper(null);
    final fitStr   = await core.storage.getWallpaperFit(widget.contactId);
    final alignStr = await core.storage.getWallpaperAlignment(widget.contactId);
    if (path != null && mounted) {
      final f = File(path);
      if (await f.exists()) {
        setState(() {
          _wallpaperPath = path;
          _bgFit       = _parseFit(fitStr);
          _bgAlignment = _parseAlignment(alignStr);
        });
        _refreshBlurredBg();
      }
    }
  }

  static BoxFit _parseFit(String v) => switch (v) {
    'contain' => BoxFit.contain,
    'fill'    => BoxFit.fill,
    'fitW'    => BoxFit.fitWidth,
    'fitH'    => BoxFit.fitHeight,
    _         => BoxFit.cover,
  };

  static String _fitName(BoxFit f) => switch (f) {
    BoxFit.contain   => 'contain',
    BoxFit.fill      => 'fill',
    BoxFit.fitWidth  => 'fitW',
    BoxFit.fitHeight => 'fitH',
    _                => 'cover',
  };

  static Alignment _parseAlignment(String v) {
    final p = v.split(',');
    if (p.length < 2) return Alignment.center;
    return Alignment(double.tryParse(p[0]) ?? 0, double.tryParse(p[1]) ?? 0);
  }

  static String _alignName(Alignment a) => '${a.x},${a.y}';

  Future<void> _loadGlass(PhantomCore core) async {
    final enabled  = await core.storage.getGlassEnabled();
    final opacity  = await core.storage.getGlassOpacity();
    final blur     = await core.storage.getGlassBlur();
    final bgBlur   = await core.storage.getGlassBgBlur();
    final noise    = await core.storage.getGlassNoise();
    final noiseSt  = await core.storage.getGlassNoiseStrength();
    if (!mounted) return;
    setState(() {
      _glassEnabled       = enabled;
      _glassOpacity       = opacity;
      _glassBlur          = blur;
      _glassBgBlur        = bgBlur;
      _glassNoise         = noise;
      _glassNoiseStrength = noiseSt;
    });
    _refreshBlurredBg();
    if (noise && _noiseImage == null) _fetchNoise();
  }

  void _fetchNoise() {
    NoiseImageCache.get().then((img) {
      if (mounted) setState(() => _noiseImage = img);
    });
  }

  Future<void> _refreshBlurredBg() async {
    final path = _wallpaperPath;
    if (!_glassEnabled || path == null) return;
    final sigma = _glassBlur;
    try {
      final bytes = await File(path).readAsBytes();
      // Decode at reduced size — heavy blur makes full resolution unnecessary.
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 720);
      final frame = await codec.getNextFrame();
      final src   = frame.image;
      final w = src.width;
      final h = src.height;

      final recorder = ui.PictureRecorder();
      final canvas   = Canvas(recorder,
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
              sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
      );
      canvas.drawImage(src, Offset.zero, Paint());
      canvas.restore();

      final picture = recorder.endRecording();
      final img     = await picture.toImage(w, h);
      picture.dispose();
      src.dispose();

      if (!mounted) { img.dispose(); return; }
      _blurredBg?.dispose();
      setState(() => _blurredBg = img);
    } catch (_) {
      // Wallpaper unreadable — stay with semi-transparent fallback.
    }
  }

  Future<void> _loadMessages(PhantomCore core) async {
    final msgs = await core.getMessages(widget.contactId, limit: 100);
    if (!mounted) return;
    setState(() => _messages = msgs);
    // Retry any media whose IPFS download failed earlier (daemon still
    // bootstrapping, sender briefly offline). No-op when all are resolved.
    unawaited(core.resolvePendingMedia(widget.contactId));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    // Mark all unread incoming messages as read and notify the sender.
    final unread = msgs
        .where((m) =>
            m.direction == MessageDirection.incoming &&
            m.status == MessageStatus.delivered)
        .map((m) => m.id)
        .toList();
    for (final id in unread) {
      await core.storage.updateMessageStatus(widget.contactId, id, MessageStatus.read);
    }

    // Re-fire receipts for recent incoming messages even if already marked
    // read locally — ONCE per screen open. The first batch can get lost when
    // the initial handshake is still churning; the sender treats duplicate
    // receipts as no-ops, so one re-fire is cheap insurance. It must NOT run
    // on every reload: reloads are triggered by incoming events including
    // the peer's readReceipts, so re-firing each time bounced receipts back
    // and forth in an endless storm (see _receiptsRefired).
    final recentRead = _receiptsRefired
        ? const <String>[]
        : msgs
            .where((m) =>
                m.direction == MessageDirection.incoming &&
                m.status == MessageStatus.read &&
                !unread.contains(m.id))
            .map((m) => m.id)
            .toList()
            .reversed
            .take(10)
            .toList();
    _receiptsRefired = true;

    final toAck = <String>{...unread, ...recentRead}.toList();
    if (toAck.isNotEmpty) {
      core.sendReadReceipts(widget.contactId, toAck); // fire-and-forget
    }
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _send(String text) async {
    final core = CoreProvider.of(context).core;
    if (core == null) return;
    final replyId = _replyTo?.id;
    if (mounted) setState(() => _replyTo = null);
    await core.sendMessage(
      recipientId: widget.contactId,
      text: text,
      replyToId: replyId,
    );
    // Reload from storage so messages are always shown in timestamp order,
    // even when multiple sends complete out of order (e.g. large file + text).
    if (mounted) _loadMessages(core);
  }

  Future<void> _sendFile(Uint8List bytes, String fileName) async {
    final core = CoreProvider.of(context).core;
    if (core == null) return;
    try {
      await core.sendFile(
        recipientId: widget.contactId,
        bytes: bytes,
        fileName: fileName,
      );
    } on PhantomCoreException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return;
    }
    if (mounted) _loadMessages(core);
  }

  void _showMsgMenu(BuildContext ctx, PhantomTokens t, PhantomCore? core, StoredMessage msg) {
    final isOut = msg.direction == MessageDirection.outgoing;
    showModalBottomSheet(
      context: ctx,
      backgroundColor: t.bgSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(width: 36, height: 3, decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          _MenuItem(icon: Icons.reply_outlined, label: 'reply', tokens: t,
            onTap: () { Navigator.pop(ctx); if (mounted) setState(() => _replyTo = msg); }),
          if (msg.type == MessageType.text)
            _MenuItem(icon: Icons.copy_outlined, label: 'copy', tokens: t,
              onTap: () { Navigator.pop(ctx); Clipboard.setData(ClipboardData(text: msg.textContent)); }),
          _MenuItem(icon: Icons.forward_outlined, label: 'forward', tokens: t,
            onTap: () { Navigator.pop(ctx); _showForwardStub(ctx, t); }),
          if (isOut)
            _MenuItem(icon: Icons.delete_outline, label: 'delete', tokens: t, danger: true,
              onTap: () async {
                Navigator.pop(ctx);
                await core?.deleteMessage(widget.contactId, msg.id);
                if (mounted) setState(() => _messages?.removeWhere((m) => m.id == msg.id));
              }),
          if (isOut && msg.status == MessageStatus.failed)
            _MenuItem(icon: Icons.refresh_outlined, label: 'retry', tokens: t,
              onTap: () async {
                Navigator.pop(ctx);
                if (core == null) return;
                final text = msg.type == MessageType.text ? msg.textContent : null;
                if (text == null) return;
                // Delete the failed message and resend as new
                await core.deleteMessage(widget.contactId, msg.id);
                if (!mounted) return;
                setState(() => _messages?.removeWhere((m) => m.id == msg.id));
                await core.sendMessage(
                  recipientId: widget.contactId,
                  text: text,
                  replyToId: msg.replyToId,
                );
                if (mounted) _loadMessages(core);
              }),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _showForwardStub(BuildContext ctx, PhantomTokens t) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      backgroundColor: t.bgSurface,
      content: Text('forward — coming soon', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 13)),
      duration: const Duration(seconds: 2),
    ));
  }

  void _openImageViewer(
      BuildContext context, PhantomTokens t, PhantomCore? core, Uint8List imageBytes) {
    Navigator.push(
      context,
      _AppRoute(
        builder: (_) => _ImageViewer(
          imageBytes:  imageBytes,
          tokens:      t,
          core:        core,
          contactId:   widget.contactId,
          contactName: widget.contactName,
        ),
      ),
    );
  }

  String? _replyPreviewFor(StoredMessage msg) {
    if (msg.replyToId == null) return null;
    final origin = _messages?.cast<StoredMessage?>().firstWhere(
      (m) => m?.id == msg.replyToId, orElse: () => null);
    if (origin == null) return null;
    final text = origin.type == MessageType.text ? origin.textContent : '[file]';
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }

  @override
  void dispose() {
    _core?.setActiveChat(null);
    _sub?.cancel();
    _presenceSub?.cancel();
    _handshakeSub?.cancel();
    _contactSub?.cancel();
    _scrollCtrl.dispose();
    _blurredBg?.dispose();
    // _noiseImage is shared via NoiseImageCache — do not dispose it here.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t    = PhantomTheme.tokensOf(context);
    final core = CoreProvider.of(context).core;
    final g    = _glassEnabled;

    final bgPath = g ? _wallpaperPath : null;

    final appBar = AppBar(
      backgroundColor: g ? Colors.transparent : t.bgSurface,
      flexibleSpace: g
          ? ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(
                    sigmaX: _glassBlur, sigmaY: _glassBlur,
                    tileMode: TileMode.clamp),
                child: Stack(children: [
                  Positioned.fill(child: Container(
                    color: t.bgSurface
                        .withValues(alpha: (_glassOpacity * 2.0).clamp(0.08, 0.80)),
                  )),
                  if (_glassNoise && _glassNoiseStrength > 0)
                    Positioned.fill(child: IgnorePointer(
                      child: NoiseLayer(strength: _glassNoiseStrength),
                    )),
                ]),
              ),
            )
          : null,
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back, color: t.textSecondary, size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(_displayName ?? widget.contactName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: t.textPrimary,
                              fontFamily: 'monospace',
                              fontSize: 15)),
                    ),
                    if (_isVerified) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.verified, color: t.accentLight, size: 14),
                    ],
                  ],
                ),
                PhantomIdDisplay(phantomId: widget.contactId, compact: true),
              ],
            ),
          ),
          if (core?.isContactOnline(widget.contactId) == true)
            Container(
              width: 9, height: 9,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50),
                shape: BoxShape.circle,
                border: Border.all(color: t.bgSurface, width: 1.5),
              ),
            ),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.more_vert, color: t.iconDefault, size: 20),
          onPressed: () => _showContactMenu(context, t, core),
        ),
      ],
      bottom: g
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(0.5),
              child: Divider(height: 0.5, color: t.divider),
            ),
    );

    final messageList = _buildMessageList(context, t, core);
    final inputBar = MessageInput(
      onSend:        _send,
      onSendFile:    _sendFile,
      onEditImage:   _openPhotoEditor,
      glassEnabled:  g,
      glassOpacity:  _glassOpacity,
      glassBlur:     _glassBlur,
      replyPreview: _replyTo != null
          ? (_replyTo!.type == MessageType.text
              ? _replyTo!.textContent
              : '[${_replyTo!.type.name}]')
          : null,
      onCancelReply: _replyTo != null
          ? () { if (mounted) setState(() => _replyTo = null); }
          : null,
    );

    final awaitingAck =
        core?.isAwaitingHandshakeAck(widget.contactId) ?? false;
    final retryAttempt = core?.handshakeRetryAttempt(widget.contactId) ?? 0;
    final handshakeBanner = awaitingAck
        ? _HandshakeWaitingBanner(tokens: t, retryAttempt: retryAttempt)
        : null;

    final scaffold = Scaffold(
      backgroundColor: g ? Colors.transparent : t.bgBase,
      appBar: appBar,
      body: Column(
        children: [
          Expanded(child: messageList),
          if (handshakeBanner != null) handshakeBanner,
          inputBar,
        ],
      ),
    );

    if (!g) return scaffold;

    return Stack(children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: bgPath != null
              ? _glassBgBlur
                  ? ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: _glassBlur,
                        sigmaY: _glassBlur,
                        tileMode: TileMode.clamp,
                      ),
                      child: Image.file(File(bgPath), fit: _bgFit, alignment: _bgAlignment),
                    )
                  : Image.file(File(bgPath), fit: _bgFit, alignment: _bgAlignment)
              : _GlassFallback(accent: t.accentLight),
        ),
      ),
      if (g && _glassNoise && _glassNoiseStrength > 0)
        Positioned.fill(child: IgnorePointer(
          child: NoiseLayer(strength: _glassNoiseStrength),
        )),
      scaffold,
    ]);
  }

  Widget _buildMessageList(
      BuildContext context, PhantomTokens t, PhantomCore? core) {
    if (_messages == null) {
      return Center(
          child: CircularProgressIndicator(
              color: t.accentLight, strokeWidth: 1));
    }
    if (_messages!.isEmpty) {
      return Center(
        child: Text('no messages yet',
            style: TextStyle(
                color: t.textDisabled,
                fontFamily: 'monospace',
                fontSize: 13)),
      );
    }
    // Non-glass: wrap list in dimmed wallpaper decoration.
    Widget list = ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: _messages!.length,
      itemBuilder: (ctx, i) {
        final msg     = _messages![i];
        final isOut   = msg.direction == MessageDirection.outgoing;
        final nextSame = i < _messages!.length - 1 &&
            (_messages![i + 1].direction == MessageDirection.outgoing) ==
                isOut;
        return Padding(
          padding: EdgeInsets.only(bottom: nextSame ? 2 : 10),
          child: GestureDetector(
            onLongPress: () => _showMsgMenu(context, t, core, msg),
            onTap: msg.type == MessageType.image
                ? () => _openImageViewer(context, t, core, msg.content)
                : null,
            child: ChatBubble(
              text:         msg.type == MessageType.text
                  ? msg.textContent
                  : '[${msg.type.name}]',
              isOutgoing:   isOut,
              timeLabel:    _formatTime(msg.timestamp),
              showTail:     !nextSame,
              status:       msg.status,
              replyPreview: _replyPreviewFor(msg),
              mediaContent: msg.type != MessageType.text ? msg.content : null,
              messageType:  msg.type,
              glassEnabled:    _glassEnabled,
              glassOpacity:    _glassOpacity,
              glassBlur:       _glassBlur,
              blurredBg:       _blurredBg,
              scrollNotifier:  _scrollCtrl,
              noiseEnabled:    _glassNoise,
              noiseStrength:   _glassNoiseStrength,
              noiseImage:      _noiseImage,
            ),
          ),
        );
      },
    );

    if (!_glassEnabled && _wallpaperPath != null) {
      list = Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: FileImage(File(_wallpaperPath!)),
            fit: _bgFit,
            alignment: _bgAlignment,
            opacity: 0.25,
          ),
        ),
        child: list,
      );
    }
    return list;
  }

  void _showContactMenu(BuildContext context, PhantomTokens t, PhantomCore? core) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSurface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36, height: 3,
                decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 16),
              _MenuItem(icon: Icons.fingerprint, label: 'verify safety number', tokens: t,
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, _AppRoute(
                    builder: (_) => VerifyContactScreen(
                      contactId:   widget.contactId,
                      contactName: _displayName ?? widget.contactName,
                    ),
                  ));
                }),
              _MenuItem(icon: Icons.wallpaper_outlined, label: 'set chat wallpaper', tokens: t,
                onTap: () async {
                  Navigator.pop(context);
                  final picked = await ImagePicker().pickImage(
                      source: ImageSource.gallery, imageQuality: 80);
                  if (picked == null || core == null || !mounted) return;
                  final raw    = await picked.readAsBytes();
                  final edited = await _openPhotoEditor(raw);
                  if (!mounted) return;
                  final path = await _saveTempImage(edited ?? raw, picked.name);
                  await core.storage.setWallpaper(widget.contactId, path);
                  if (mounted) setState(() => _wallpaperPath = path);
                }),
              _MenuItem(icon: Icons.wallpaper_outlined, label: 'set global wallpaper', tokens: t,
                onTap: () async {
                  Navigator.pop(context);
                  final picked = await ImagePicker().pickImage(
                      source: ImageSource.gallery, imageQuality: 80);
                  if (picked == null || core == null || !mounted) return;
                  final raw    = await picked.readAsBytes();
                  final edited = await _openPhotoEditor(raw);
                  if (!mounted) return;
                  final path = await _saveTempImage(edited ?? raw, picked.name);
                  await core.storage.setWallpaper(null, path);
                  if (mounted && _wallpaperPath == null) setState(() => _wallpaperPath = path);
                }),
              if (_wallpaperPath != null) ...[
                _MenuItem(icon: Icons.tune_outlined, label: 'adjust background', tokens: t,
                  onTap: () {
                    Navigator.pop(context);
                    _showWallpaperPositionSheet(context, t, core);
                  }),
                _MenuItem(icon: Icons.hide_image_outlined, label: 'remove wallpaper', tokens: t,
                  onTap: () async {
                    Navigator.pop(context);
                    if (core != null) {
                      await core.storage.clearWallpaper(widget.contactId);
                      if (mounted) setState(() => _wallpaperPath = null);
                    }
                  }),
              ],
              _MenuItem(icon: Icons.account_circle_outlined, label: 'share my avatar', tokens: t,
                onTap: () async {
                  Navigator.pop(context);
                  await core?.sendAvatarToContact(widget.contactId);
                }),
              _MenuItem(icon: Icons.badge_outlined, label: 'share my alias', tokens: t,
                onTap: () async {
                  Navigator.pop(context);
                  await core?.sendAliasToContact(widget.contactId);
                }),
              _MenuItem(icon: Icons.edit_outlined, label: 'edit contact nickname', tokens: t,
                onTap: () {
                  Navigator.pop(context);
                  _showEditContact(t, core);
                }),
              _MenuItem(icon: Icons.blur_on_outlined, label: 'glass effect', tokens: t,
                onTap: () {
                  Navigator.pop(context);
                  _showGlassSettings(context, t, core);
                }),
              // Single reconnect entry — reviveConnection already does the
              // full sequence (disconnect → re-subscribe → DHT discovery →
              // wait for gossipsub mesh → reset session → fresh INIT), so
              // the old separate 'reset session' button was a strict subset.
              // Auto-retry handles the silent case in the background; this
              // button forces an immediate kick.
              _MenuItem(icon: Icons.sync_outlined, label: 'reconnect', tokens: t,
                onTap: () async {
                  Navigator.pop(context);
                  if (core == null) return;
                  _showReviveDialog(context, t, core, widget.contactId);
                }),
              _MenuItem(icon: Icons.delete_outline, label: 'clear history', tokens: t,
                onTap: () async {
                  Navigator.pop(context);
                  if (core != null) {
                    await core.clearHistory(widget.contactId);
                    if (mounted) _loadMessages(core);
                  }
                }),
              _MenuItem(icon: Icons.block, label: 'block', tokens: t, danger: true,
                onTap: () => Navigator.pop(context)),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
  void _showReviveDialog(
      BuildContext context, PhantomTokens t, PhantomCore core, String contactId) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ReviveDialog(
        contactId: contactId,
        core: core,
        t: t,
      ),
    );
  }

  void _showGlassSettings(
      BuildContext context, PhantomTokens t, PhantomCore? core) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSurface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 3,
                  decoration: BoxDecoration(
                      color: t.divider,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              Text('// glass effect',
                  style: TextStyle(
                      color: t.accentLight.withValues(alpha: 0.7),
                      fontFamily: 'monospace',
                      fontSize: 12)),
              const SizedBox(height: 4),
              Text(
                'blurs the background through bubbles, bars, and app bar.\n'
                'uses the chat or global wallpaper as background.',
                style: TextStyle(
                    color: t.textDisabled,
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.6),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('enabled',
                      style: TextStyle(
                          color: t.textPrimary,
                          fontFamily: 'monospace',
                          fontSize: 14)),
                  Switch(
                    value: _glassEnabled,
                    activeThumbColor: t.accentLight,
                    onChanged: (val) async {
                      setS(() {});
                      if (mounted) setState(() => _glassEnabled = val);
                      await core?.storage.setGlassEnabled(val);
                    },
                  ),
                ],
              ),
              if (_glassEnabled) ...[
                const SizedBox(height: 8),
                _GlassSlider(
                  label: 'opacity',
                  value: _glassOpacity,
                  min: 0.05,
                  max: 0.40,
                  tokens: t,
                  onChanged: (v) {
                    setS(() {});
                    if (mounted) setState(() => _glassOpacity = v);
                    core?.storage.setGlassOpacity(v);
                  },
                ),
                const SizedBox(height: 4),
                _GlassSlider(
                  label: 'blur',
                  value: _glassBlur,
                  min: 2.0,
                  max: 25.0,
                  tokens: t,
                  onChanged: (v) {
                    setS(() {});
                    if (mounted) setState(() => _glassBlur = v);
                    core?.storage.setGlassBlur(v);
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('noise',
                          style: TextStyle(color: t.textPrimary,
                              fontFamily: 'monospace', fontSize: 14)),
                      Text('grain texture on glass',
                          style: TextStyle(color: t.textDisabled,
                              fontFamily: 'monospace', fontSize: 11)),
                    ]),
                    Switch(
                      value: _glassNoise,
                      activeThumbColor: t.accentLight,
                      onChanged: (val) async {
                        setS(() {});
                        if (mounted) setState(() => _glassNoise = val);
                        await core?.storage.setGlassNoise(val);
                        if (val && _noiseImage == null) _fetchNoise();
                      },
                    ),
                  ],
                ),
                if (_glassNoise) ...[
                  const SizedBox(height: 4),
                  _GlassSlider(
                    label: 'noise',
                    value: _glassNoiseStrength,
                    min: 0.0,
                    max: 1.0,
                    tokens: t,
                    onChanged: (v) {
                      setS(() {});
                      if (mounted) setState(() => _glassNoiseStrength = v);
                      core?.storage.setGlassNoiseStrength(v);
                    },
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('blur background',
                            style: TextStyle(color: t.textPrimary,
                                fontFamily: 'monospace', fontSize: 14)),
                        Text('apply blur to the wallpaper image',
                            style: TextStyle(color: t.textDisabled,
                                fontFamily: 'monospace', fontSize: 11)),
                      ],
                    ),
                    Switch(
                      value: _glassBgBlur,
                      activeThumbColor: t.accentLight,
                      onChanged: (val) {
                        setS(() {});
                        if (mounted) setState(() => _glassBgBlur = val);
                        core?.storage.setGlassBgBlur(val);
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showEditContact(PhantomTokens t, PhantomCore? core) async {
    final contact = await core?.storage.getContact(widget.contactId);
    final nickCtrl = TextEditingController(text: contact?.nickname ?? '');

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgSurface,
        title: Text('edit contact info',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('nickname (private)',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            _PhantomField(controller: nickCtrl, hint: 'contact nickname...'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('cancel',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace')),
          ),
          TextButton(
            onPressed: () async {
              final nick = nickCtrl.text.trim();
              if (core != null) {
                final current = await core.storage.getContact(widget.contactId);
                if (current != null) {
                  await core.storage.saveContact(
                    current.copyWith(
                      nickname: nick.isEmpty ? null : nick,
                    ),
                  );
                  core.notifyContactChanged(widget.contactId);
                }
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text('save',
                style: TextStyle(color: t.accentLight, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  /// Opens the photo editor and returns the (possibly modified) bytes,
  /// or the original bytes if the user taps send without editing.
  /// Returns null if the user cancels (presses X).
  Future<Uint8List?> _openPhotoEditor(Uint8List bytes) {
    return Navigator.push<Uint8List>(
      context,
      _AppRoute(builder: (_) => PhotoEditorScreen(bytes: bytes)),
    );
  }

  /// Saves [bytes] to the app's temp directory and returns the path.
  /// Used when a file-path-based store (wallpaper, avatar) needs edited bytes.
  Future<String> _saveTempImage(Uint8List bytes, String baseName) async {
    final dir  = await getTemporaryDirectory();
    final ts   = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/ph_edit_${ts}_$baseName');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  void _showWallpaperPositionSheet(BuildContext ctx, PhantomTokens t, PhantomCore? core) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: t.bgSurface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard))),
      builder: (_) => _WallpaperPositionSheet(
        wallpaperPath: _wallpaperPath!,
        currentFit:       _bgFit,
        currentAlignment: _bgAlignment,
        tokens: t,
        onChanged: (fit, alignment) async {
          await core?.storage.setWallpaperFit(widget.contactId, _fitName(fit));
          await core?.storage.setWallpaperAlignment(widget.contactId, _alignName(alignment));
          if (mounted) setState(() { _bgFit = fit; _bgAlignment = alignment; });
        },
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ── Wallpaper position sheet ─────────────────────────────────────────────────

class _WallpaperPositionSheet extends StatefulWidget {
  final String wallpaperPath;
  final BoxFit currentFit;
  final Alignment currentAlignment;
  final PhantomTokens tokens;
  final void Function(BoxFit, Alignment) onChanged;

  const _WallpaperPositionSheet({
    required this.wallpaperPath,
    required this.currentFit,
    required this.currentAlignment,
    required this.tokens,
    required this.onChanged,
  });

  @override
  State<_WallpaperPositionSheet> createState() => _WallpaperPositionSheetState();
}

class _WallpaperPositionSheetState extends State<_WallpaperPositionSheet> {
  late BoxFit _fit;
  late Alignment _alignment;

  static const _fits = [BoxFit.cover, BoxFit.contain, BoxFit.fill];
  static const _fitLabels = ['cover', 'contain', 'fill'];

  static const _alignments = [
    [Alignment.topLeft,    Alignment.topCenter,    Alignment.topRight],
    [Alignment.centerLeft, Alignment.center,       Alignment.centerRight],
    [Alignment.bottomLeft, Alignment.bottomCenter, Alignment.bottomRight],
  ];

  @override
  void initState() {
    super.initState();
    _fit       = widget.currentFit;
    _alignment = widget.currentAlignment;
  }

  void _apply(BoxFit fit, Alignment alignment) {
    setState(() { _fit = fit; _alignment = alignment; });
    widget.onChanged(fit, alignment);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(
            width: 36, height: 3,
            decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2)),
          )),
          const SizedBox(height: 16),

          // ── Preview ───────────────────────────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(t.radiusCard),
            child: SizedBox(
              height: 140,
              width: double.infinity,
              child: Image.file(
                File(widget.wallpaperPath),
                fit:       _fit,
                alignment: _alignment,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Fit ───────────────────────────────────────────────────────────
          Text('fit', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            children: List.generate(_fits.length, (i) {
              final selected = _fit == _fits[i];
              return Expanded(
                child: GestureDetector(
                  onTap: () => _apply(_fits[i], _alignment),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: EdgeInsets.only(right: i < _fits.length - 1 ? 8 : 0),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: selected ? t.accentLight.withValues(alpha: 0.15) : t.bgSubtle,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected ? t.accentLight : t.inputBorder,
                        width: selected ? 1.5 : 0.8,
                      ),
                    ),
                    child: Text(
                      _fitLabels[i],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected ? t.accentLight : t.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 16),

          // ── Alignment ─────────────────────────────────────────────────────
          Text('position', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
          const SizedBox(height: 8),
          Column(
            children: List.generate(3, (row) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: List.generate(3, (col) {
                  final a = _alignments[row][col];
                  final selected = _alignment == a;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => _apply(_fit, a),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: EdgeInsets.only(right: col < 2 ? 6 : 0),
                        height: 36,
                        decoration: BoxDecoration(
                          color: selected ? t.accentLight.withValues(alpha: 0.15) : t.bgSubtle,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: selected ? t.accentLight : t.inputBorder,
                            width: selected ? 1.5 : 0.8,
                          ),
                        ),
                        child: Center(
                          child: Container(
                            width: 6, height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected ? t.accentLight : t.textDisabled,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            )),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final PhantomTokens tokens;
  final VoidCallback onTap;
  final bool danger;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.tokens,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFCF6679) : tokens.textPrimary;
    return ListTile(
      leading: Icon(icon, color: color, size: 20),
      title: Text(label, style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 14)),
      dense: true,
      onTap: onTap,
    );
  }
}

/// Thin notice bar shown above the input when we are waiting for the
/// peer's handshakeAck. PhantomCore retries the INIT on a backoff in the
/// background; this just tells the user it's happening so they don't
/// wonder why their first message hasn't gone through.
class _HandshakeWaitingBanner extends StatelessWidget {
  final PhantomTokens tokens;
  final int retryAttempt;
  const _HandshakeWaitingBanner({
    required this.tokens,
    required this.retryAttempt,
  });

  @override
  Widget build(BuildContext context) {
    final detail = retryAttempt > 0
        ? 'waiting for first response · retry $retryAttempt'
        : 'waiting for first response…';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.bgBase.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(
              color: tokens.accentLight,
              strokeWidth: 1.2,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              detail,
              style: TextStyle(
                color: tokens.textSecondary,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


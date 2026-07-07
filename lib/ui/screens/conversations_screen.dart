part of 'screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONVERSATIONS LIST
// ─────────────────────────────────────────────────────────────────────────────

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  List<ContactRecord>? _contacts;
  final Map<String, StoredMessage?> _lastMessages = {};
  final Map<String, Uint8List?> _avatars = {};
  StreamSubscription<StoredMessage>? _msgSub;
  StreamSubscription<String>? _presenceSub;
  StreamSubscription<String>? _contactSub;
  bool _showArchived = false;
  UpdateInfo? _updateInfo;
  bool _updateChecked = false;

  // App-level glass state (independent from chat glass)
  bool    _glassEnabled      = false;
  double  _glassOpacity      = 0.15;
  bool    _glassBgBlur       = false;
  double  _glassBlur         = 10.0;
  bool    _useWallpaper      = false;
  String? _appWallpaperPath;
  bool    _glassNoise        = false;
  double  _glassNoiseStrength = 0.15;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    if (core != null && _msgSub == null) {
      _msgSub = core.incomingMessages.listen((_) => _loadData(core));
      _presenceSub = core.presenceChanges.listen((_) { if (mounted) setState(() {}); });
      _contactSub = core.contactChanges.listen((_) => _loadData(core));
      _loadData(core);
      _loadGlass(core);
    }
    if (!_updateChecked) {
      _updateChecked = true;
      UpdateService.checkForUpdate().then((info) {
        if (info != null && mounted) { setState(() => _updateInfo = info); }
      });
    }
  }

  Future<void> _loadGlass(PhantomCore core) async {
    final enabled  = await core.storage.getAppGlassEnabled();
    final opacity  = await core.storage.getAppGlassOpacity();
    final bgBlur   = await core.storage.getAppGlassBgBlur();
    final blur     = await core.storage.getAppGlassBlur();
    final useWp    = await core.storage.getAppGlassUseWallpaper();
    final wp       = useWp ? await core.storage.getAppWallpaper() : null;
    final noise    = await core.storage.getAppGlassNoise();
    final noiseSt  = await core.storage.getAppGlassNoiseStrength();
    if (!mounted) return;
    setState(() {
      _glassEnabled       = enabled;
      _glassOpacity       = opacity;
      _glassBgBlur        = bgBlur;
      _glassBlur          = blur;
      _useWallpaper       = useWp;
      _appWallpaperPath   = wp;
      _glassNoise         = noise;
      _glassNoiseStrength = noiseSt;
    });
  }

  Future<void> _loadData(PhantomCore core) async {
    final contacts = await core.getContacts();
    final lastMsgs = <String, StoredMessage?>{};
    final avatars  = <String, Uint8List?>{};
    for (final c in contacts) {
      lastMsgs[c.phantomId] = await core.getLastMessage(c.phantomId);
      avatars[c.phantomId]  = await core.getContactAvatar(c.phantomId);
    }
    if (mounted) {
      setState(() {
        _contacts = contacts;
        _lastMessages.addAll(lastMsgs);
        _avatars.addAll(avatars);
      });
    }
  }

  List<ContactRecord> get _visible {
    if (_contacts == null) return [];
    return _contacts!.where((c) => c.isArchived == _showArchived).toList();
  }

  bool get _hasArchived => _contacts?.any((c) => c.isArchived) ?? false;

  void _showConvMenu(BuildContext ctx, PhantomTokens t, PhantomCore core, ContactRecord c) {
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(c.displayName, style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 13)),
          ),
          _MenuItem(icon: Icons.archive_outlined, label: c.isArchived ? 'unarchive' : 'archive', tokens: t,
            onTap: () async {
              Navigator.pop(ctx);
              await core.setConversationArchived(c.phantomId, archived: !c.isArchived);
              _loadData(core);
            }),
          _MenuItem(icon: Icons.delete_sweep_outlined, label: 'clear history', tokens: t,
            onTap: () async {
              Navigator.pop(ctx);
              await core.deleteConversation(c.phantomId);
              _loadData(core);
            }),
          _MenuItem(icon: Icons.person_remove_outlined, label: 'delete contact', tokens: t, danger: true,
            onTap: () async {
              Navigator.pop(ctx);
              await core.deleteContact(c.phantomId);
              _loadData(core);
            }),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _presenceSub?.cancel();
    _contactSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t    = PhantomTheme.tokensOf(context);
    final core = CoreProvider.of(context).core;

    if (core == null) {
      return Scaffold(
        backgroundColor: t.bgBase,
        body: Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1)),
      );
    }

    final visible = _visible;

    final g      = _glassEnabled;
    final bgPath = g && _useWallpaper ? _appWallpaperPath : null;

    Widget buildBody() => Column(
      children: [
        if (_updateInfo != null)
          _UpdateBanner(
            info: _updateInfo!,
            tokens: t,
            onDismiss: () => setState(() => _updateInfo = null),
          ),
        Expanded(
          child: _contacts == null
              ? Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
              : visible.isEmpty
                  ? _EmptyContacts(tokens: t, archived: _showArchived)
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final c    = visible[i];
                        final last = _lastMessages[c.phantomId];
                        return ConversationTile(
                          displayName: c.displayName,
                          phantomId:   c.phantomId,
                          lastMessage: last?.type == MessageType.text ? last?.textContent : null,
                          timeLabel:   last != null ? _formatTime(last.timestamp) : null,
                          unreadCount: 0,
                          isOnline:    core.isContactOnline(c.phantomId),
                          avatarBytes: _avatars[c.phantomId],
                          onTap: () => Navigator.push(context,
                            _AppRoute(builder: (_) => ChatScreen(
                              contactName: c.displayName, contactId: c.phantomId)))
                            .then((_) => _loadData(core)),
                          onLongPress: () => _showConvMenu(context, t, core, c),
                        );
                      },
                    ),
        ),
      ],
    );

    final scaffold = Scaffold(
      backgroundColor: g ? Colors.transparent : t.bgBase,
      appBar: AppBar(
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
        title: Text(
          _showArchived ? 'archived' : 'phantom',
          style: TextStyle(color: _showArchived ? t.textSecondary : t.accentLight,
              fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w300, letterSpacing: 4),
        ),
        actions: [
          if (_hasArchived || _showArchived)
            IconButton(
              icon: Icon(_showArchived ? Icons.inbox_outlined : Icons.archive_outlined,
                  color: g ? Colors.white70 : t.iconDefault, size: 20),
              tooltip: _showArchived ? 'back' : 'archived',
              onPressed: () => setState(() => _showArchived = !_showArchived),
            ),
          IconButton(
            icon: Icon(Icons.settings_outlined,
                color: g ? Colors.white70 : t.iconDefault, size: 20),
            onPressed: () => Navigator.push(context,
                _AppRoute(builder: (_) => const SettingsScreen()))
                .then((_) => _loadGlass(core)),
          ),
        ],
        bottom: g ? null : PreferredSize(
            preferredSize: const Size.fromHeight(0.5),
            child: Divider(height: 0.5, color: t.divider)),
      ),
      body: buildBody(),
      floatingActionButton: _showArchived ? null : FloatingActionButton(
        backgroundColor: g
            ? t.bgSurface.withValues(alpha: (_glassOpacity * 2.5).clamp(0.18, 0.88))
            : t.bgSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusCard),
          side: BorderSide(color: t.inputBorder, width: 0.5),
        ),
        child: Icon(Icons.edit_outlined, color: t.accentLight, size: 20),
        onPressed: () => Navigator.push(context,
            _AppRoute(builder: (_) => const AddContactScreen()))
            .then((_) => _loadData(core)),
      ),
    );

    if (!g) return scaffold;

    return Stack(children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: bgPath != null
              ? Builder(builder: (context) {
                  // Decode at screen size — the blur cost also scales with
                  // the decoded bitmap, so this halves glass cost on 4K photos.
                  final cacheW = (MediaQuery.sizeOf(context).width *
                          MediaQuery.of(context).devicePixelRatio)
                      .round();
                  final img = Image.file(File(bgPath),
                      fit: BoxFit.cover, cacheWidth: cacheW);
                  return _glassBgBlur
                      ? ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                              sigmaX: _glassBlur, sigmaY: _glassBlur,
                              tileMode: TileMode.clamp),
                          child: img)
                      : img;
                })
              : Container(color: t.bgBase),
        ),
      ),
      if (g && _glassNoise && _glassNoiseStrength > 0)
        Positioned.fill(child: IgnorePointer(
          child: NoiseLayer(strength: _glassNoiseStrength),
        )),
      Positioned.fill(
        child: ColoredBox(
          color: Color.lerp(t.bgBase, t.accentLight, 0.06)!
              .withValues(alpha: (0.55 - _glassOpacity).clamp(0.22, 0.72)),
        ),
      ),
      scaffold,
    ]);
  }

  static String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}';
  }
}

// ── Update banner ─────────────────────────────────────────────────────────────

class _UpdateBanner extends StatefulWidget {
  final UpdateInfo info;
  final PhantomTokens tokens;
  final VoidCallback onDismiss;
  const _UpdateBanner({required this.info, required this.tokens, required this.onDismiss});

  @override
  State<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<_UpdateBanner> {
  double _progress = 0;
  bool _downloading = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: t.bgSurface,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(color: t.accentLight.withValues(alpha: 0.4), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.system_update_outlined, size: 16, color: t.accentLight),
              const SizedBox(width: 8),
              Expanded(
                child: Text('update available — v${widget.info.version}',
                    style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 13)),
              ),
              GestureDetector(
                onTap: widget.onDismiss,
                child: Icon(Icons.close, size: 16, color: t.textDisabled),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_downloading)
            Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: t.divider,
                    color: t.accentLight,
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 6),
                Text('${(_progress * 100).toInt()}%',
                    style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () async {
                    setState(() { _downloading = true; _progress = 0; });
                    await UpdateService.downloadAndInstall(
                      widget.info.downloadUrl,
                      (p) { if (mounted) setState(() => _progress = p); },
                    );
                    if (mounted) setState(() => _downloading = false);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: t.accentLight.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(t.radiusCard),
                    ),
                    child: Text('download & install',
                        style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 12)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EmptyContacts extends StatelessWidget {
  final PhantomTokens tokens;
  final bool archived;
  const _EmptyContacts({required this.tokens, this.archived = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(archived ? Icons.archive_outlined : Icons.people_outline,
              color: tokens.textDisabled, size: 48),
          const SizedBox(height: 16),
          Text(archived ? 'no archived chats' : 'no contacts yet',
              style: TextStyle(color: tokens.textSecondary, fontFamily: 'monospace', fontSize: 14)),
          const SizedBox(height: 6),
          if (!archived)
            Text('tap + to add someone',
                style: TextStyle(color: tokens.textDisabled, fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }
}


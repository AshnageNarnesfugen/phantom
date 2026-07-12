part of 'screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS
// ─────────────────────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _contactAddress;
  String? _ownAvatarPath;
  final _myAliasCtrl = TextEditingController();
  // Match main.dart's _kSecure so the seed-export flow reads from the same
  // Keystore/Keychain entry. iOS entries are device-bound (no iCloud-backup
  // leakage); Android stays on the default hardware-backed scheme to avoid
  // the cipher-migration hang.
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  // App-level glass state (independent from chat glass)
  bool    _glassEnabled       = false;
  double  _glassOpacity       = 0.15;
  bool    _glassBgBlur        = false;
  double  _glassBlur          = 10.0;
  bool    _useWallpaper       = false;
  String? _appWallpaperPath;
  bool    _glassNoise         = false;
  double  _glassNoiseStrength = 0.15;

  // Manual update check
  bool _checkingUpdate = false;

  // IPFS node status (null = not yet checked)
  bool? _ipfsRunning;
  int   _ipfsPeers = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    if (core != null && _contactAddress == null) {
      core.getMyContactAddress().then((addr) {
        if (mounted) setState(() => _contactAddress = addr);
      });
      core.storage.getOwnAvatarPath().then((p) {
        if (mounted) setState(() => _ownAvatarPath = p);
      });
      core.storage.getSetting<String>('my_alias').then((alias) {
        if (mounted && alias != null) _myAliasCtrl.text = alias;
      });
      core.storage.getSetting<String>('media_autodownload').then((m) {
        if (mounted && m != null) setState(() => _mediaMode = m);
      });
      core.storage.getSetting<bool>('link_previews_enabled').then((v) {
        if (mounted && v != null) setState(() => _linkPreviews = v);
      });
      _loadGlass(core);
      _refreshStatus();
      _refreshTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
    }
  }

  Timer? _refreshTimer;

  /// Media auto-download policy: 'always' | 'wifi' | 'never' (default manual).
  String _mediaMode = 'never';

  /// Sender-generated link previews (Signal-style). OFF by default: generating
  /// one means the sender's device fetches the URL (IP visible to the site).
  bool _linkPreviews = false;

  static const _mediaModeLabels = {
    'always': 'always',
    'wifi': 'wi-fi only',
    'never': 'manual',
  };

  void _showMediaModeSheet(PhantomTokens t, PhantomCore? core) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSurface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('auto-download media',
                    style: TextStyle(
                        color: t.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 15)),
              ),
            ),
            for (final e in const [
              ('always', 'always', 'download on any network'),
              ('wifi', 'wi-fi only', 'manual button on mobile data'),
              ('never', 'manual', 'always ask — tap to download'),
            ])
              ListTile(
                title: Text(e.$2,
                    style: TextStyle(
                        color: t.textPrimary, fontFamily: 'monospace', fontSize: 14)),
                subtitle: Text(e.$3,
                    style: TextStyle(
                        color: t.textSecondary, fontFamily: 'monospace', fontSize: 11)),
                trailing: _mediaMode == e.$1
                    ? Icon(Icons.check, color: t.accentLight, size: 18)
                    : null,
                onTap: () {
                  setState(() => _mediaMode = e.$1);
                  core?.storage.setSetting('media_autodownload', e.$1);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _refreshStatus() {
    final core = CoreProvider.of(context).core;
    if (core == null || !mounted) return;

    IpfsDaemon.instance.status().then((s) {
      if (mounted) setState(() { _ipfsRunning = s.running; _ipfsPeers = s.peers; });
    });

    core.getMyContactAddress().then((addr) {
      if (mounted && _contactAddress != addr) setState(() => _contactAddress = addr);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _myAliasCtrl.dispose();
    super.dispose();
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

  UpdateInfo? _updateFromCheck;

  Future<void> _checkUpdate(PhantomTokens t) async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    // Capture messenger before the async gap.
    final messenger = ScaffoldMessenger.of(context);
    final info = await UpdateService.checkForUpdate();
    if (!mounted) return;
    setState(() {
      _checkingUpdate   = false;
      _updateFromCheck  = info;
    });
    if (info == null) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: t.bgSurface,
        content: Text('you are on the latest version',
            style: TextStyle(color: t.textSecondary,
                fontFamily: 'monospace', fontSize: 13)),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = CoreProvider.of(context);
    final theme    = PhantomTheme.of(context);
    final t        = theme.tokens;
    final core     = provider.core;

    final g      = _glassEnabled;
    final bgPath = g && _useWallpaper ? _appWallpaperPath : null;

    Widget buildList() => ListView(
      children: [
        if (_updateFromCheck != null)
          _UpdateBanner(
            info: _updateFromCheck!,
            tokens: t,
            onDismiss: () => setState(() => _updateFromCheck = null),
          ),
          // ── Profile ───────────────────────────────────────────
          _SectionHeader('profile', t),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () async {
                    final picked = await ImagePicker().pickImage(
                        source: ImageSource.gallery, imageQuality: 85, maxWidth: 512, maxHeight: 512);
                    if (picked == null || core == null || !mounted) return;
                    final raw    = await picked.readAsBytes();
                    if (!context.mounted) return;
                    final edited = await Navigator.push<Uint8List>(
                      context,
                      _AppRoute(builder: (_) => PhotoEditorScreen(bytes: raw)),
                    );
                    if (!mounted) return;
                    final dir  = await getTemporaryDirectory();
                    final path = '${dir.path}/ph_avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
                    await File(path).writeAsBytes(edited ?? raw);
                    await core.storage.setOwnAvatarPath(path);
                    if (mounted) setState(() => _ownAvatarPath = path);
                  },
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: t.bgSubtle,
                      borderRadius: BorderRadius.circular(t.radiusCard),
                      border: Border.all(color: t.inputBorder, width: 0.8),
                      image: _ownAvatarPath != null && File(_ownAvatarPath!).existsSync()
                          ? DecorationImage(
                              image: FileImage(File(_ownAvatarPath!)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: _ownAvatarPath == null
                        ? Icon(Icons.add_a_photo_outlined, color: t.textDisabled, size: 24)
                        : null,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('profile picture',
                          style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 13)),
                      const SizedBox(height: 4),
                      Text('tap to change · shared only when you choose',
                          style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
                      if (_ownAvatarPath != null) ...[
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: () async {
                            if (core != null) {
                              await core.storage.setOwnAvatarPath(null);
                              if (mounted) setState(() => _ownAvatarPath = null);
                            }
                          },
                          child: Text('remove',
                              style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11,
                                  decoration: TextDecoration.underline)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── My alias ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('my alias',
                    style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
                const SizedBox(height: 3),
                Text('sent to contacts when you tap "share my alias"',
                    style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
                const SizedBox(height: 8),
                _PhantomField(
                  controller: _myAliasCtrl,
                  hint: 'your name or alias...',
                  onChanged: (v) => core?.storage.setSetting('my_alias', v.trim()),
                ),
              ],
            ),
          ),

          // ── Identity ─────────────────────────────────────────
          _SectionHeader('identity', t),
          if (core != null) ...[
            // The phantom id is backend addressing (routing topics, storage
            // keys) — not something the user acts on. What's actually
            // shareable is the contact address below, so we don't surface the
            // raw id here.
            if (_contactAddress != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('your contact address',
                        style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
                    const SizedBox(height: 4),
                    Text('share this with contacts so they can add you',
                        style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => Clipboard.setData(ClipboardData(text: _contactAddress!)),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: t.bgSubtle,
                          borderRadius: BorderRadius.circular(t.radiusCard),
                          border: Border.all(color: t.inputBorder, width: 0.5),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _contactAddress!,
                                style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 10),
                                maxLines: 5,
                                softWrap: true,
                                overflow: TextOverflow.visible,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.copy_outlined, size: 14, color: t.iconDefault),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _PhantomButton(
                      label: 'show QR',
                      onTap: () => Navigator.of(context).push(_AppRoute(
                          builder: (_) => _MyQrScreen(
                              contactAddress: _contactAddress!))),
                    ),
                  ],
                ),
              ),
          ],
          _SettingTile(
            icon: Icons.backup_outlined,
            label: 'export backup',
            tokens: t,
            onTap: () => _exportBackup(t, core),
          ),
          _SettingTile(
            icon: Icons.key_outlined,
            label: 'show seed phrase',
            tokens: t,
            onTap: () => _showSeedWarning(t),
          ),
          // ── Media ────────────────────────────────────────────
          _SectionHeader('media', t),
          _SettingTile(
            icon: Icons.download_outlined,
            label: 'auto-download',
            value: _mediaModeLabels[_mediaMode],
            tokens: t,
            onTap: () => _showMediaModeSheet(t, core),
          ),
          _SettingTile(
            icon: Icons.link_outlined,
            label: 'link previews',
            value: _linkPreviews ? 'on' : 'off',
            tokens: t,
            onTap: () {
              final next = !_linkPreviews;
              setState(() => _linkPreviews = next);
              core?.storage.setSetting('link_previews_enabled', next);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(
                  next
                      ? 'previews on — when YOU send a link, your device '
                        'fetches the page and embeds the card (the site sees '
                        'your IP, receivers fetch nothing)'
                      : 'previews off — links send as plain text',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                duration: const Duration(seconds: 4),
              ));
            },
          ),
          // ── Appearance ───────────────────────────────────────
          _SectionHeader('appearance', t),
          _SettingTile(
            icon: theme.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            label: theme.isDark ? 'switch to light mode' : 'switch to dark mode',
            tokens: t,
            onTap: () => provider.themeCtrl.toggleDarkMode(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('accent color',
                    style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: PhantomAccent.values.map((accent) {
                    final isActive = theme.accent == accent;
                    return GestureDetector(
                      onTap: () => provider.themeCtrl.setAccent(accent),
                      child: Column(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: accent.light.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isActive ? accent.light : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            child: isActive
                                ? Icon(Icons.check, size: 16, color: accent.light)
                                : Center(
                                    child: Container(
                                      width: 16,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: accent.light,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            accent.label.toLowerCase(),
                            style: TextStyle(
                              color: isActive ? t.accentLight : t.textDisabled,
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                _IntensitySlider(
                  value:    provider.themeCtrl.intensity,
                  accent:   t.accentLight,
                  tokens:   t,
                  onChange: provider.themeCtrl.setIntensity,
                ),
              ],
            ),
          ),
          // ── Background (app-level glass, independent from chat) ──
          _SectionHeader('background', t),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('glass effect',
                          style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 14)),
                      Text('transparent bars · tinted background',
                          style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
                    ]),
                    Switch(
                      value: _glassEnabled,
                      activeThumbColor: t.accentLight,
                      onChanged: (val) async {
                        setState(() => _glassEnabled = val);
                        await core?.storage.setAppGlassEnabled(val);
                      },
                    ),
                  ],
                ),
                if (_glassEnabled) ...[
                  const SizedBox(height: 8),
                  _GlassSlider(
                    label: 'opacity',
                    value: _glassOpacity,
                    min: 0.05, max: 0.40,
                    tokens: t,
                    onChanged: (v) {
                      setState(() => _glassOpacity = v);
                      core?.storage.setAppGlassOpacity(v);
                    },
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('custom wallpaper',
                            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 14)),
                        Text('gallery image instead of solid color',
                            style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
                      ]),
                      Switch(
                        value: _useWallpaper,
                        activeThumbColor: t.accentLight,
                        onChanged: (val) async {
                          setState(() => _useWallpaper = val);
                          await core?.storage.setAppGlassUseWallpaper(val);
                          if (val) {
                            final wp = await core?.storage.getAppWallpaper();
                            if (mounted) setState(() => _appWallpaperPath = wp);
                          }
                        },
                      ),
                    ],
                  ),
                  if (_useWallpaper) ...[
                    const SizedBox(height: 4),
                    _GlassSlider(
                      label: 'blur',
                      value: _glassBlur,
                      min: 2.0, max: 25.0,
                      tokens: t,
                      onChanged: (v) {
                        setState(() => _glassBlur = v);
                        core?.storage.setAppGlassBlur(v);
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('blur image',
                            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 14)),
                        Switch(
                          value: _glassBgBlur,
                          activeThumbColor: t.accentLight,
                          onChanged: (val) async {
                            setState(() => _glassBgBlur = val);
                            await core?.storage.setAppGlassBgBlur(val);
                          },
                        ),
                      ],
                    ),
                  ],
                ],
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
                        setState(() => _glassNoise = val);
                        await core?.storage.setAppGlassNoise(val);
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
                      setState(() => _glassNoiseStrength = v);
                      core?.storage.setAppGlassNoiseStrength(v);
                    },
                  ),
                ],
              ],
            ),
          ),
          if (_glassEnabled && _useWallpaper) ...[
            _SettingTile(
              icon: Icons.image_outlined,
              label: _appWallpaperPath != null ? 'change wallpaper' : 'set wallpaper',
              tokens: t,
              onTap: () async {
                final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
                if (picked != null && core != null) {
                  await core.storage.setAppWallpaper(picked.path);
                  if (mounted) setState(() => _appWallpaperPath = picked.path);
                }
              },
            ),
            if (_appWallpaperPath != null)
              _SettingTile(
                icon: Icons.hide_image_outlined,
                label: 'remove wallpaper',
                tokens: t,
                onTap: () async {
                  if (core != null) {
                    await core.storage.clearAppWallpaper();
                    if (mounted) setState(() => _appWallpaperPath = null);
                  }
                },
              ),
          ],

          // ── Network ───────────────────────────────────────────
          // The detailed per-transport status (waku/ipfs/yggdrasil/i2p/BT)
          // lives in the modal opened by 'transport status' below — keeping
          // it in one place stops it from drifting out of sync as new
          // transports get added (Waku missed both sites before this).
          _SectionHeader('network', t),
          _SettingTile(
            icon: Icons.wifi,
            label: 'transport status',
            value: core?.isTransportAvailable == true ? 'connected' : 'offline',
            tokens: t,
            onTap: () => _showTransportSheet(context, t, core),
          ),
          _SettingTile(
            icon: _ipfsRunning == true ? Icons.hub : Icons.hub_outlined,
            label: 'ipfs diagnostics',
            value: _ipfsRunning == null
                ? 'checking...'
                : _ipfsRunning!
                    ? 'running · $_ipfsPeers peer${_ipfsPeers == 1 ? '' : 's'}'
                    : 'offline',
            tokens: t,
            onTap: () => _showIpfsDiagnostics(context, t),
          ),
          _SettingTile(
            icon: Icons.hub_outlined,
            label: 'yggdrasil peers',
            tokens: t,
            onTap: () => _showYggdrasilPeersSheet(context, t),
          ),
          _SettingTile(
            icon: Icons.bug_report_outlined,
            label: 'transport debugger',
            tokens: t,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => _TransportDebugScreen(core: core)),
            ),
          ),

          // ── About ─────────────────────────────────────────────
          _SectionHeader('about', t),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'phantom v0.1.0-alpha\nX3DH + Double Ratchet\nno servers — no metadata\nAGPL-3.0',
              style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11, height: 1.7),
            ),
          ),
          _SettingTile(
            icon: _checkingUpdate
                ? Icons.hourglass_top_outlined
                : Icons.system_update_outlined,
            label: _checkingUpdate ? 'checking...' : 'check for updates',
            tokens: t,
            onTap: () => _checkUpdate(t),
          ),
          const SizedBox(height: 32),
        ],
      );  // closes ListView / buildList

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
        leading: IconButton(
          icon: Icon(Icons.arrow_back,
              color: g ? Colors.white70 : t.textSecondary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('settings',
            style: TextStyle(
                color: g ? Colors.white.withValues(alpha: 0.9) : t.textPrimary,
                fontFamily: 'monospace', fontSize: 16)),
        bottom: g
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(0.5),
                child: Divider(height: 0.5, color: t.divider)),
      ),
      body: buildList(),
    );

    if (!g) return scaffold;

    return Stack(children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: bgPath != null
              ? Builder(builder: (context) {
                  // Decode at screen size — blur cost scales with the bitmap.
                  final cacheW = (MediaQuery.sizeOf(context).width *
                          MediaQuery.of(context).devicePixelRatio)
                      .round();
                  final img = Image.file(File(bgPath),
                      fit: BoxFit.cover, cacheWidth: cacheW);
                  return _glassBgBlur
                      ? ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: _glassBlur,
                            sigmaY: _glassBlur,
                            tileMode: TileMode.clamp,
                          ),
                          child: img)
                      : img;
                })
              : Container(color: t.bgBase),
        ),
      ),
      if (_glassNoise && _glassNoiseStrength > 0)
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

  void _showIpfsDiagnostics(BuildContext context, PhantomTokens t) {
    _refreshStatus();
    final log = IpfsDaemon.instance.daemonLog;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: t.bgSurface,
        title: Text('ipfs node diagnostics',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 14)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _ipfsRunning == true
                    ? 'status: running ($_ipfsPeers peers)'
                    : 'status: offline',
                style: TextStyle(
                  color: _ipfsRunning == true ? const Color(0xFF4CAF50) : t.textSecondary,
                  fontFamily: 'monospace', fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              Text('daemon log:', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 11)),
              const SizedBox(height: 4),
              SelectableText(
                log,
                style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 10, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () { Navigator.pop(ctx); _refreshStatus(); },
            child: Text('refresh', style: TextStyle(color: t.accentLight, fontFamily: 'monospace')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('close', style: TextStyle(color: t.textDisabled, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  void _showYggdrasilPeersSheet(BuildContext context, PhantomTokens t) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard)),
      ),
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: _YggdrasilPeersSheet(tokens: t),
        ),
      ),
    );
  }

  void _showTransportSheet(BuildContext context, PhantomTokens t, PhantomCore? core) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard)),
      ),
      // isScrollControlled lets the sheet grow past the default half-screen
      // cap — in landscape that cap was clipping our content. The maxWidth
      // constraint keeps it readable on wide tablets / unfolded foldables.
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: _TransportStatusSheet(tokens: t, core: core),
        ),
      ),
    );
  }

  void _showSeedWarning(PhantomTokens t) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: t.bgSurface,
        title: Text('show seed phrase?',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
        content: Text(
          'never share your seed phrase with anyone.\nmake sure no one can see your screen.',
          style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('cancel', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final seed = await _secure.read(key: _seedKey);
              if (!mounted || seed == null) return;
              _showSeedPhrase(t, seed);
            },
            child: const Text('show anyway',
                style: TextStyle(color: Color(0xFFCF6679), fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  Future<void> _exportBackup(PhantomTokens t, PhantomCore? core) async {
    if (core == null) return;
    final seed = await _secure.read(key: _seedKey);
    if (seed == null || !mounted) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: t.bgSurface,
        title: Text('export backup',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
        content: Text(
          'your backup will be encrypted with your seed phrase and saved to device storage.\n\ntransfer the file to your new device, then use "restore from backup file" during setup.',
          style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('cancel', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                final path = await core.exportBackup(seed);
                if (!mounted) return;
                _showBackupSuccess(t, path);
              } catch (e) {
                if (!mounted) return;
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: t.bgSurface,
                    title: const Text('export failed',
                        style: TextStyle(color: Color(0xFFCF6679), fontFamily: 'monospace', fontSize: 16)),
                    content: Text(e.toString(),
                        style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text('ok', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace')),
                      ),
                    ],
                  ),
                );
              }
            },
            child: Text('export', style: TextStyle(color: t.accentLight, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  void _showBackupSuccess(PhantomTokens t, String path) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: t.bgSurface,
        title: Text('backup saved',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('file written to:',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => Clipboard.setData(ClipboardData(text: path)),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.bgSubtle,
                  borderRadius: BorderRadius.circular(t.radiusCard),
                  border: Border.all(color: t.inputBorder, width: 0.5),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(path,
                          style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 10),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.copy_outlined, size: 14, color: t.iconDefault),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'transfer this file to your new device, then choose "restore from backup file" during setup.',
              style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('done', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  void _showSeedPhrase(PhantomTokens t, String seed) {
    bool obscured = true;
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: t.bgSurface,
          title: Text('seed phrase',
              style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: seed));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'seed phrase copied — paste it into your password manager NOW and clear the clipboard',
                              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                            ),
                            duration: Duration(seconds: 4),
                          ),
                        );
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.copy_outlined, size: 12, color: t.accentLight),
                          const SizedBox(width: 4),
                          Text(
                            'copy',
                            style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: () => setS(() => obscured = !obscured),
                      child: Text(
                        obscured ? 'show' : 'hide',
                        style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SeedPhraseGrid(seedPhrase: seed, obscured: obscured),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('close', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace')),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final PhantomTokens t;
  const _SectionHeader(this.label, this.t);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        '// $label',
        style: TextStyle(color: t.accentLight.withValues(alpha: 0.6), fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final PhantomTokens tokens;
  final VoidCallback onTap;

  const _SettingTile({
    required this.icon,
    required this.label,
    this.value,
    required this.tokens,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: tokens.iconDefault),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: TextStyle(color: tokens.textPrimary, fontFamily: 'monospace', fontSize: 14)),
            ),
            if (value != null)
              Text(value!,
                  style: TextStyle(color: tokens.textDisabled, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 16, color: tokens.textDisabled),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS (local to screens)
// ─────────────────────────────────────────────────────────────────────────────

class _PhantomButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool outlined;

  const _PhantomButton({required this.label, this.onTap, this.outlined = false});

  @override
  Widget build(BuildContext context) {
    final t       = PhantomTheme.tokensOf(context);
    final enabled = onTap != null;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: outlined
              ? Colors.transparent
              : enabled ? t.accentLight.withValues(alpha: 0.15) : t.bgSubtle,
          borderRadius: BorderRadius.circular(t.radiusInput),
          border: Border.all(
            color: outlined
                ? t.inputBorder
                : enabled ? t.accentLight.withValues(alpha: 0.4) : t.divider,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: enabled
                ? (outlined ? t.textSecondary : t.accentLight)
                : t.textDisabled,
            fontFamily: 'monospace',
            fontSize: 14,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

class _PhantomField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String? error;
  final int maxLines;
  final void Function(String)? onChanged;

  const _PhantomField({
    required this.controller,
    required this.hint,
    this.error,
    this.maxLines = 1,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: t.bgSubtle,
            borderRadius: BorderRadius.circular(t.radiusInput),
            border: Border.all(
              color: error != null ? const Color(0xFFCF6679) : t.inputBorder,
              width: 0.5,
            ),
          ),
          child: TextField(
            controller: controller,
            maxLines: maxLines,
            onChanged: onChanged,
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 14),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 13),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(error!, style: const TextStyle(color: Color(0xFFCF6679), fontSize: 11, fontFamily: 'monospace')),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TRANSPORT STATUS SHEET
// ─────────────────────────────────────────────────────────────────────────────

class _TransportStatusSheet extends StatefulWidget {
  final PhantomTokens tokens;
  final PhantomCore? core;

  const _TransportStatusSheet({required this.tokens, required this.core});

  @override
  State<_TransportStatusSheet> createState() => _TransportStatusSheetState();
}

class _TransportStatusSheetState extends State<_TransportStatusSheet> {
  StreamSubscription<TransportMode>? _sub;
  TransportStatus? _status;
  int _ipfsSwarmPeers = 0;
  bool _ipfsRunning = false;
  bool _wakuRunning = false;
  int _wakuPeers = 0;
  bool _wakuBinaryMissing = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _status = widget.core?.transportStatus;
    _sub = widget.core?.transportModeChanges.listen((_) {
      if (mounted) setState(() => _status = widget.core?.transportStatus);
    });
    _fetchIpfsStatus();
    // I2P bootstrap can take 1-5 min after first launch; refresh while the
    // sheet is open so the user actually sees the status flip from
    // "bootstrapping" to "ready" without closing and re-opening.
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        _fetchIpfsStatus();
        // Re-probe transports that weren't up at app start (Yggdrasil's TUN
        // finishing bootstrap, I2P tunnels converging). Without this the
        // sheet only showed the availability snapshot taken at initialize —
        // a transport that came up later read "inactive" until the next
        // outgoing message triggered the lazy re-probe.
        widget.core?.transport.reprobeInactive();
      }
    });
  }

  Future<void> _fetchIpfsStatus() async {
    try {
      final s = await IpfsDaemon.instance.status();
      if (mounted) {
        setState(() {
          _ipfsRunning = s.running;
          _ipfsSwarmPeers = s.peers;
        });
      }
    } catch (_) {}

    // Waku status: peers + running. Also surface whether the libgowaku.so
    // binary is actually bundled — without it the daemon will never start
    // regardless of platform support, so the user shouldn't see a generic
    // "offline" that suggests a runtime/connectivity issue.
    try {
      final ws = await WakuDaemon.instance.status();
      if (mounted) {
        setState(() {
          _wakuRunning = ws.running;
          _wakuPeers   = ws.peers;
          _wakuBinaryMissing = WakuDaemon.instance.binaryMissing;
        });
      }
    } catch (_) {}

    // Also probe Yggdrasil and I2P from the transport manager
    final core = widget.core;
    if (core != null && mounted) {
      final ygg = core.transport.transports.whereType<YggdrasilTransport>().firstOrNull;
      final i2p = core.transport.transports.whereType<I2PTransport>().firstOrNull;
      final ipfs = core.transport.transports.whereType<IpfsTransport>().firstOrNull;
      final yggBundled = await YggdrasilDaemon.instance.isRouterBundled();
      if (!mounted) return;
      setState(() {
        _yggRouterMissing = Platform.isAndroid && !yggBundled;
        _yggAddress = ygg?.address;
        _i2pSamReachable    = i2p?.isSamReachable    ?? false;
        _i2pSessionReady    = i2p?.isSessionReady    ?? false;
        _i2pFailureCount    = i2p?.sessionAttemptFailures ?? 0;
        _i2pDestPreview     = i2p?.myDestination?.substring(0, 16);
        _ipfsRetryQueue     = ipfs?.pendingRetryCount ?? 0;
      });
    }
  }

  String? _yggAddress;
  bool _yggRouterMissing = false;
  bool _i2pSamReachable = false;
  bool _i2pSessionReady = false;
  int _i2pFailureCount = 0;
  String? _i2pDestPreview;
  int _ipfsRetryQueue = 0;

  /// Three-state label for the I2P transport row. "active" alone hid the
  /// fact that the SAM bridge can be alive while i2pd is still building
  /// tunnels — the user sees "active" but messages mysteriously fall back
  /// to IPFS because no session is actually established yet.
  String _i2pStatusLabel() {
    if (!_i2pSamReachable) return 'inactive';
    if (_i2pSessionReady) {
      final dest = _i2pDestPreview;
      return dest != null ? 'ready · ${dest.substring(0, 8)}…' : 'ready';
    }
    return _i2pFailureCount > 0
        ? 'bootstrapping (retry $_i2pFailureCount)'
        : 'bootstrapping…';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final s = _status;

    final (modeIcon, modeColor, modeLabel) = switch (s?.mode) {
      TransportMode.internet      => (Icons.wifi,              const Color(0xFF4CAF50), 'internet'),
      TransportMode.bluetoothMesh => (Icons.bluetooth,         const Color(0xFF64B5F6), 'bluetooth mesh'),
      TransportMode.offline       => (Icons.wifi_off_outlined, const Color(0xFFCF6679), 'offline'),
      null                        => (Icons.wifi_off_outlined, const Color(0xFFCF6679), 'offline'),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 3,
              decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Icon(modeIcon, color: modeColor, size: 18),
              const SizedBox(width: 10),
              Text(
                'transport',
                style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: modeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: modeColor.withValues(alpha: 0.4), width: 0.5),
                ),
                child: Text(
                  modeLabel,
                  style: TextStyle(color: modeColor, fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _TransportRow(
            label: 'waku',
            value: _wakuBinaryMissing
                ? 'binary not bundled'
                : _wakuRunning
                    ? 'running · $_wakuPeers peer${_wakuPeers == 1 ? '' : 's'}'
                    : 'offline',
            tokens: t,
          ),
          _TransportRow(
            label: 'ipfs node',
            value: _ipfsRunning ? 'running' : 'offline',
            tokens: t,
          ),
          _TransportRow(
            label: 'swarm peers',
            value: '$_ipfsSwarmPeers',
            tokens: t,
          ),
          _TransportRow(
            label: 'yggdrasil',
            value: _yggRouterMissing
                ? 'missing binary'
                : _yggAddress != null
                    ? _yggAddress!.substring(0, _yggAddress!.length.clamp(0, 16))
                    : 'inactive',
            tokens: t,
          ),
          _TransportRow(
            label: 'i2p',
            value: _i2pStatusLabel(),
            tokens: t,
          ),
          _TransportRow(label: 'bluetooth mesh', value: s?.btMeshState == true ? 'active' : 'inactive', tokens: t),
          _TransportRow(label: 'bt peers nearby', value: '${s?.btPeerCount ?? 0}', tokens: t),
          // The BLE store and the IPFS retry queue are independent backlogs;
          // both block message delivery and the user should see the combined
          // total so they know how much is waiting on the network coming back.
          _TransportRow(
            label: 'queued messages',
            value: _ipfsRetryQueue > 0
                ? '${(s?.pendingMessages ?? 0) + _ipfsRetryQueue} '
                    '(ipfs retry $_ipfsRetryQueue)'
                : '${s?.pendingMessages ?? 0}',
            tokens: t,
          ),
          const SizedBox(height: 4),
          Text(
            s?.mode == TransportMode.offline
                ? '// no transport available — messages will be queued and delivered when a connection is established'
                : _ipfsSwarmPeers > 0
                    ? '// messages are being routed via $modeLabel · ipfs mesh ready'
                    : '// messages are being routed via $modeLabel · ipfs mesh warming up',
            style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 10, height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _TransportRow extends StatelessWidget {
  final String label;
  final String value;
  final PhantomTokens tokens;

  const _TransportRow({required this.label, required this.value, required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: tokens.textSecondary, fontFamily: 'monospace', fontSize: 13)),
          const Spacer(),
          Text(value,  style: TextStyle(color: tokens.textPrimary,   fontFamily: 'monospace', fontSize: 13)),
        ],
      ),
    );
  }
}

// ── Yggdrasil peers configuration sheet ─────────────────────────────────────

/// Bottom-sheet UI that exposes the Yggdrasil controls: a master enable
/// switch, a use-custom-peers switch, and an editable list of slots.
///
/// All writes go through PhantomStorage; changes only take effect on the
/// next app launch because the yggdrasil-go router has already grabbed
/// the TUN device and re-reading peers mid-run is not supported by
/// mobile.Yggdrasil. The sheet shows that warning inline.
class _YggdrasilPeersSheet extends StatefulWidget {
  final PhantomTokens tokens;
  const _YggdrasilPeersSheet({required this.tokens});

  @override
  State<_YggdrasilPeersSheet> createState() => _YggdrasilPeersSheetState();
}

class _YggdrasilPeersSheetState extends State<_YggdrasilPeersSheet> {
  static const int _defaultSlots = 4;

  bool _loaded = false;
  bool _enabled = false;
  bool _useCustom = false;
  /// One TextEditingController per slot — owned by this state so they get
  /// disposed cleanly and don't lose cursor position on each setState.
  final List<TextEditingController> _slots = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _slots) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final storage = PhantomStorage.instance;
    final enabled   = await storage.getYggEnabled();
    final useCustom = await storage.getYggUseCustomPeers();
    final peers     = await storage.getYggCustomPeers();
    final padded = List<String>.from(peers);
    while (padded.length < _defaultSlots) {
      padded.add('');
    }
    if (!mounted) return;
    setState(() {
      _enabled   = enabled;
      _useCustom = useCustom;
      _slots
        ..clear()
        ..addAll(padded.map((p) => TextEditingController(text: p)));
      _loaded = true;
    });
  }

  Future<void> _persistPeers() async {
    final list = _slots
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    await PhantomStorage.instance.setYggCustomPeers(list);
  }

  void _addSlot() {
    setState(() => _slots.add(TextEditingController()));
  }

  void _removeSlot(int i) {
    _slots[i].dispose();
    setState(() => _slots.removeAt(i));
    unawaited(_persistPeers());
  }

  bool _applyingPeers = false;

  /// The peer list to hand the daemon right now: the user's non-empty custom
  /// slots in custom mode, otherwise a freshly-pulled public set (cached /
  /// hard-coded fallback if the fetch fails). Never empty.
  Future<List<String>> _resolveEffectivePeers() async {
    if (_useCustom) {
      final custom = _slots
          .map((c) => c.text.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return custom.isNotEmpty ? custom : YggdrasilPeerCatalog.fallback;
    }
    final storage = PhantomStorage.instance;
    try {
      final fresh = await YggdrasilPeerCatalog().fetchUpstream();
      if (fresh.isNotEmpty) {
        await storage.setYggCachedPeers(fresh).catchError((_) {});
        return YggdrasilPeerCatalog.pickRandom(
            fresh, YggdrasilPeerCatalog.defaultPickCount);
      }
    } catch (_) {}
    final cached = await storage.getYggCachedPeers().catchError((_) => null);
    if (cached != null && cached.peers.isNotEmpty) {
      return YggdrasilPeerCatalog.pickRandom(
          cached.peers, YggdrasilPeerCatalog.defaultPickCount);
    }
    return YggdrasilPeerCatalog.fallback;
  }

  /// "update peers" action: persist the slots, resolve the effective list, and
  /// hand it to the running router so it re-dials NOW instead of on next
  /// launch. The ygg address is preserved across the bounce.
  Future<void> _updatePeers() async {
    if (_applyingPeers) return;
    final messenger = ScaffoldMessenger.of(context);
    await _persistPeers();
    setState(() => _applyingPeers = true);
    try {
      final peers = await _resolveEffectivePeers();
      messenger.showSnackBar(SnackBar(
        content: Text('applying ${peers.length} peers — bouncing ygg…',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        duration: const Duration(seconds: 2),
      ));
      final addr = await YggdrasilDaemon.instance.applyPeers(peers);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(
          addr != null
              ? 'ygg re-dialed ${peers.length} peers · $addr'
              : 'saved ${peers.length} peers — they apply when you enable ygg',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        duration: const Duration(seconds: 4),
      ));
    } finally {
      if (mounted) setState(() => _applyingPeers = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    if (!_loaded) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 3,
              decoration: BoxDecoration(
                color: t.divider, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Icon(Icons.hub_outlined, color: t.accentLight, size: 18),
              const SizedBox(width: 10),
              Text('yggdrasil peers',
                  style: TextStyle(
                      color: t.textPrimary,
                      fontFamily: 'monospace',
                      fontSize: 16)),
            ],
          ),
          const SizedBox(height: 16),
          _YggSwitchRow(
            label: 'enable yggdrasil',
            value: _enabled,
            tokens: t,
            onChanged: (v) async {
              setState(() => _enabled = v);
              unawaited(PhantomStorage.instance.setYggEnabled(v));
              // Enabling starts the headless router service right now. No VPN
              // permission dialog anymore — the router runs without a TUN, so
              // it can never hijack the device's routing or the app's daemons.
              final messenger = ScaffoldMessenger.of(context);
              final core = CoreProvider.of(context).core; // capture pre-async
              if (v) {
                final bundled =
                    await YggdrasilDaemon.instance.isRouterBundled();
                if (!bundled) {
                  messenger.showSnackBar(const SnackBar(
                    content: Text(
                        'yggdrasil router not bundled in this APK — rebuild '
                        'with scripts/build_yggdrasil_mobile.sh',
                        style: TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                    duration: Duration(seconds: 4),
                  ));
                  return;
                }
                final ok = await YggdrasilDaemon.instance
                    .requestPermissionAndStart();
                messenger.showSnackBar(SnackBar(
                  content: Text(
                      ok
                          ? 'yggdrasil up (headless) — address '
                            '${YggdrasilDaemon.instance.address ?? "?"}'
                          : 'yggdrasil could not start (router binary missing?)',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  duration: const Duration(seconds: 4),
                ));
                // Safety net: if enabling ygg collapses the reliable transports
                // (in-package daemons losing their fleet connections), back it
                // out automatically. Runs in the background for ~90 s.
                if (ok && core != null) {
                  unawaited(core.guardYggAfterEnable().then((_) {
                    if (mounted) {
                      core.storage
                          .getYggEnabled()
                          .then((v) => setState(() => _enabled = v));
                    }
                  }));
                }
              } else {
                await YggdrasilDaemon.instance.stop();
                // Obstacle removed: re-drive any messages that got stuck in
                // limbo while ygg was up, through the other transports.
                await core?.onYggDisabled();
              }
            },
          ),
          _YggSwitchRow(
            label: 'use custom peers',
            value: _useCustom,
            enabled: _enabled,
            tokens: t,
            onChanged: (v) {
              setState(() => _useCustom = v);
              unawaited(PhantomStorage.instance.setYggUseCustomPeers(v));
            },
          ),
          const SizedBox(height: 8),
          Text(
            _useCustom
                ? '// using your slots below'
                : '// auto-pulling fresh peers from publicpeers.neilalexander.dev (cached 6h)',
            style: TextStyle(
                color: t.textDisabled, fontFamily: 'monospace', fontSize: 10),
          ),
          const SizedBox(height: 16),
          IgnorePointer(
            ignoring: !_useCustom,
            child: Opacity(
              opacity: _useCustom ? 1.0 : 0.4,
              child: Column(
                children: [
                  for (int i = 0; i < _slots.length; i++)
                    _PeerSlotRow(
                      controller: _slots[i],
                      index: i,
                      tokens: t,
                      onChanged: (_) => unawaited(_persistPeers()),
                      onRemove: _slots.length > 1 ? () => _removeSlot(i) : null,
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _addSlot,
                      icon: Icon(Icons.add, color: t.accentLight, size: 16),
                      label: Text(
                        'add slot',
                        style: TextStyle(
                            color: t.accentLight,
                            fontFamily: 'monospace',
                            fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _enabled && !_applyingPeers ? _updatePeers : null,
              icon: _applyingPeers
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: t.accentLight))
                  : Icon(Icons.sync, color: t.accentLight, size: 16),
              label: Text(
                _applyingPeers ? 'updating…' : 'update peers (apply now)',
                style: TextStyle(
                    color: _enabled ? t.accentLight : t.textDisabled,
                    fontFamily: 'monospace',
                    fontSize: 13),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                    color: t.accentLight
                        .withValues(alpha: _enabled ? 0.5 : 0.15)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '// peer format: tls://host:port  (also tcp:// quic:// ws:// wss://)\n'
            '// "update peers" re-dials the running router now (ygg address stays)',
            style: TextStyle(
                color: t.textDisabled,
                fontFamily: 'monospace',
                fontSize: 10,
                height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _YggSwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final bool enabled;
  final PhantomTokens tokens;
  final ValueChanged<bool> onChanged;
  const _YggSwitchRow({
    required this.label,
    required this.value,
    required this.tokens,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: enabled ? tokens.textPrimary : tokens.textDisabled,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeThumbColor: tokens.accentLight,
          ),
        ],
      ),
    );
  }
}

class _PeerSlotRow extends StatelessWidget {
  final TextEditingController controller;
  final int index;
  final PhantomTokens tokens;
  final ValueChanged<String> onChanged;
  final VoidCallback? onRemove;
  const _PeerSlotRow({
    required this.controller,
    required this.index,
    required this.tokens,
    required this.onChanged,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${index + 1}.',
                style: TextStyle(
                    color: tokens.textDisabled,
                    fontFamily: 'monospace',
                    fontSize: 12)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: TextStyle(
                  color: tokens.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 12),
              decoration: InputDecoration(
                hintText: 'tls://host:port',
                hintStyle: TextStyle(
                    color: tokens.textDisabled,
                    fontFamily: 'monospace',
                    fontSize: 12),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: tokens.inputBorder),
                  borderRadius: BorderRadius.circular(4),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: tokens.accentLight),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          if (onRemove != null)
            IconButton(
              icon: Icon(Icons.close, color: tokens.textDisabled, size: 16),
              onPressed: onRemove,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
        ],
      ),
    );
  }
}


part of 'screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ADD CONTACT
// ─────────────────────────────────────────────────────────────────────────────

class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _addressCtrl = TextEditingController();
  final _nickCtrl    = TextEditingController();
  String? _error;
  bool _loading = false;

  bool    _glassEnabled       = false;
  double  _glassOpacity       = 0.15;
  double  _glassBlur          = 10.0;
  bool    _glassBgBlur        = false;
  bool    _useWallpaper       = false;
  String? _appWallpaperPath;
  bool    _glassNoise         = false;
  double  _glassNoiseStrength = 0.15;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    if (core != null && !_glassEnabled) _loadGlass(core);
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

  @override
  void dispose() {
    _addressCtrl.dispose();
    _nickCtrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final address = _addressCtrl.text.trim();
    if (address.length < 20) {
      setState(() => _error = 'paste the full contact address');
      return;
    }
    final core = CoreProvider.of(context).core!;
    setState(() { _loading = true; _error = null; });
    try {
      final nick = _nickCtrl.text.trim();
      await core.addContact(
        contactAddress: address,
        nickname: nick.isEmpty ? null : nick,
      );
      if (mounted) {
        // Show warming-up feedback before popping
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: PhantomTheme.tokensOf(context).bgSurface,
          content: Row(
            children: [
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: PhantomTheme.tokensOf(context).accentLight,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'warming up connection…',
                style: TextStyle(
                  color: PhantomTheme.tokensOf(context).textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 3),
        ));
        Navigator.pop(context);
      }
    } on InvalidPhantomIdException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'invalid contact address'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t      = PhantomTheme.tokensOf(context);
    final g      = _glassEnabled;
    final bgPath = g && _useWallpaper ? _appWallpaperPath : null;

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
          icon: Icon(Icons.close,
              color: g ? Colors.white70 : t.textSecondary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('add contact',
            style: TextStyle(
                color: g ? Colors.white.withValues(alpha: 0.9) : t.textPrimary,
                fontFamily: 'monospace', fontSize: 16)),
        bottom: g
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(0.5),
                child: Divider(height: 0.5, color: t.divider)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text('contact address',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 4),
            Text('paste the full address your contact shared with you',
                style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
            const SizedBox(height: 8),
            _PhantomField(
              controller: _addressCtrl,
              hint: 'base64url contact address...',
              error: _error,
              maxLines: 3,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 20),
            Text('nickname (optional)',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            _PhantomField(controller: _nickCtrl, hint: 'alice'),

            const SizedBox(height: 32),
            _loading
                ? Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
                : _PhantomButton(label: 'add contact', onTap: _add),
          ],
        ),
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
                        sigmaX: _glassBlur, sigmaY: _glassBlur,
                        tileMode: TileMode.clamp,
                      ),
                      child: Image.file(File(bgPath), fit: BoxFit.cover))
                  : Image.file(File(bgPath), fit: BoxFit.cover)
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
}


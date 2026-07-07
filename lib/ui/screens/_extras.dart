part of 'screens.dart';


// ── Navigation ────────────────────────────────────────────────────────────────
// Fade transition — lighter than the default slide, avoids re-painting the
// outgoing route during the animation which reduces GPU pressure.

class _AppRoute<T> extends PageRouteBuilder<T> {
  _AppRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (ctx, _, __) => builder(ctx),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 160),
        );
}

// ── Glass helper widgets ──────────────────────────────────────────────────────

class _GlassFallback extends StatelessWidget {
  final Color accent;
  const _GlassFallback({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.55),
            accent.withValues(alpha: 0.15),
            Colors.black87,
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
    );
  }
}

// Inline intensity slider — StatefulWidget so the thumb animates smoothly
// during drag without waiting for the global theme rebuild.
class _IntensitySlider extends StatefulWidget {
  final double value;
  final Color accent;
  final PhantomTokens tokens;
  final ValueChanged<double> onChange;

  const _IntensitySlider({
    required this.value,
    required this.accent,
    required this.tokens,
    required this.onChange,
  });

  @override
  State<_IntensitySlider> createState() => _IntensitySliderState();
}

class _IntensitySliderState extends State<_IntensitySlider> {
  late double _local;

  @override
  void initState() {
    super.initState();
    _local = widget.value;
  }

  @override
  void didUpdateWidget(_IntensitySlider old) {
    super.didUpdateWidget(old);
    // Sync local value when the external source changes (e.g. accent switch).
    if ((old.value - widget.value).abs() > 0.001) {
      _local = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final accent = widget.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('color intensity',
                style: TextStyle(
                    color: t.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: 12)),
            const Spacer(),
            Text(
              '${(_local * 100).round()}%',
              style: TextStyle(
                  color: accent,
                  fontFamily: 'monospace',
                  fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor:   accent,
            inactiveTrackColor: t.divider,
            thumbColor:         accent,
            overlayColor:       accent.withValues(alpha: 0.12),
            trackHeight:        2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: _local.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            divisions: 20,
            onChanged: (v) {
              setState(() => _local = v);
              widget.onChange(v);
            },
          ),
        ),
      ],
    );
  }
}

class _GlassSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final PhantomTokens tokens;
  final ValueChanged<double> onChanged;

  const _GlassSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.tokens,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(label,
              style: TextStyle(
                  color: t.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 12)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: t.accentLight,
              inactiveTrackColor: t.divider,
              thumbColor: t.accentLight,
              overlayColor: t.accentLight.withValues(alpha: 0.12),
              trackHeight: 2,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.toStringAsFixed(2),
            style: TextStyle(
                color: t.textDisabled,
                fontFamily: 'monospace',
                fontSize: 10),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

// ── Image viewer ──────────────────────────────────────────────────────────────

class _ImageViewer extends StatelessWidget {
  final Uint8List   imageBytes;
  final PhantomTokens tokens;
  final PhantomCore?  core;
  final String        contactId;
  final String        contactName;

  const _ImageViewer({
    required this.imageBytes,
    required this.tokens,
    required this.contactId,
    required this.contactName,
    this.core,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black45,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white, size: 22),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          // Zoomable image
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 6.0,
              child: Center(
                child: Image.memory(imageBytes, fit: BoxFit.contain),
              ),
            ),
          ),
          // Bottom action bar
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                color: Colors.black54,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _ViewerAction(
                      icon: Icons.download_outlined,
                      label: 'save',
                      onTap: () => _save(context),
                    ),
                    _ViewerAction(
                      icon: Icons.forward_outlined,
                      label: 'forward',
                      onTap: () => _showForwardSheet(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    try {
      await Gal.putImageBytes(imageBytes, album: 'Phantom');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFF1E1E1E),
          content: Text('saved to gallery',
              style: TextStyle(color: tokens.textPrimary,
                  fontFamily: 'monospace', fontSize: 13)),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: Color(0xFF1E1E1E),
          content: Text('failed to save',
              style: TextStyle(color: Color(0xFFCF6679),
                  fontFamily: 'monospace', fontSize: 13)),
          duration: Duration(seconds: 2),
        ));
      }
    }
  }

  void _showForwardSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: tokens.bgSurface,
      shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(tokens.radiusCard))),
      builder: (_) => _ForwardSheet(
        bytes:              imageBytes,
        fileName:           'shared_${DateTime.now().millisecondsSinceEpoch}.jpg',
        tokens:             tokens,
        core:               core,
        currentContactId:   contactId,
        currentContactName: contactName,
      ),
    );
  }
}

// ── Forward sheet ─────────────────────────────────────────────────────────────

class _ForwardSheet extends StatefulWidget {
  final Uint8List     bytes;
  final String        fileName;
  final PhantomTokens tokens;
  final PhantomCore?  core;
  final String        currentContactId;
  final String        currentContactName;

  const _ForwardSheet({
    required this.bytes,
    required this.fileName,
    required this.tokens,
    required this.core,
    required this.currentContactId,
    required this.currentContactName,
  });

  @override
  State<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<_ForwardSheet> {
  List<ContactRecord>? _contacts;
  final _sending = <String>{};

  @override
  void initState() {
    super.initState();
    widget.core?.getContacts().then((list) {
      if (mounted) setState(() => _contacts = list);
    });
  }

  Future<void> _forward(String contactId) async {
    if (_sending.contains(contactId) || widget.core == null) return;
    setState(() => _sending.add(contactId));
    try {
      await widget.core!.sendFile(
        recipientId: contactId,
        bytes:       widget.bytes,
        fileName:    widget.fileName,
      );
    } on PhantomCoreException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _sending.remove(contactId));
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Container(
          width: 36, height: 3,
          decoration: BoxDecoration(
              color: t.divider, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('forward to',
              style: TextStyle(
                  color: t.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 12)),
        ),
        const SizedBox(height: 8),
        if (_contacts == null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: CircularProgressIndicator(
                color: t.accentLight, strokeWidth: 1),
          )
        else if (_contacts!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('no contacts',
                style: TextStyle(
                    color: t.textDisabled,
                    fontFamily: 'monospace',
                    fontSize: 13)),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _contacts!.length,
              itemBuilder: (_, i) {
                final c       = _contacts![i];
                final name    = c.nickname?.isNotEmpty == true
                    ? c.nickname!
                    : c.phantomId.substring(0, 8);
                final sending = _sending.contains(c.phantomId);
                return ListTile(
                  dense: true,
                  leading: Icon(Icons.account_circle_outlined,
                      color: t.iconDefault, size: 22),
                  title: Text(name,
                      style: TextStyle(
                          color: t.textPrimary,
                          fontFamily: 'monospace',
                          fontSize: 14)),
                  subtitle: Text(
                      c.phantomId.length > 16
                          ? '${c.phantomId.substring(0, 8)}…'
                          : c.phantomId,
                      style: TextStyle(
                          color: t.textDisabled,
                          fontFamily: 'monospace',
                          fontSize: 10)),
                  trailing: sending
                      ? SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                              color: t.accentLight,
                              strokeWidth: 1.5))
                      : Icon(Icons.send_outlined,
                          color: t.accentLight, size: 18),
                  onTap: sending ? null : () => _forward(c.phantomId),
                );
              },
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}

// ── Viewer action button ──────────────────────────────────────────────────────

class _ViewerAction extends StatelessWidget {
  final IconData   icon;
  final String     label;
  final VoidCallback onTap;

  const _ViewerAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24, width: 0.5),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'monospace',
                  fontSize: 11)),
        ],
      ),
    );
  }
}

// ── Revive Connection Dialog ──────────────────────────────────────────────────

class _ReviveDialog extends StatefulWidget {
  final String contactId;
  final PhantomCore core;
  final PhantomTokens t;

  const _ReviveDialog({
    required this.contactId,
    required this.core,
    required this.t,
  });

  @override
  _ReviveDialogState createState() => _ReviveDialogState();
}

class _ReviveDialogState extends State<_ReviveDialog> with SingleTickerProviderStateMixin {
  String _status = 'starting…';
  bool _finished = false;
  bool _success = false;
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _startRevive();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _startRevive() async {
    final stream = widget.core.reviveConnection(widget.contactId);
    await for (final status in stream) {
      if (!mounted) break;
      if (status == 'success') {
        setState(() {
          _status = 'connection revived!';
          _finished = true;
          _success = true;
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
        break;
      } else if (status == 'failed') {
        setState(() {
          _status = 'revive failed';
          _finished = true;
          _success = false;
        });
        break;
      } else if (status == 'offline') {
        setState(() {
          _status = 'contact appears offline — open Phantom on their device';
          _finished = true;
          _success = false;
        });
        break;
      } else {
        setState(() {
          _status = status;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: t.bgSurface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: t.divider, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_finished)
              _OnionRouteAnimation(controller: _controller, tokens: t)
            else
              Container(
                width: 60, height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _success ? const Color(0xFF4CAF50).withValues(alpha: 0.1) : const Color(0xFFCF6679).withValues(alpha: 0.1),
                ),
                child: Icon(
                  _success ? Icons.check_circle_outline : Icons.error_outline,
                  color: _success ? const Color(0xFF4CAF50) : const Color(0xFFCF6679),
                  size: 40,
                ),
              ),
            const SizedBox(height: 24),
            Text(
              'Reconnecting',
              style: TextStyle(
                color: t.textPrimary,
                fontFamily: 'monospace',
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: t.textDisabled,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
            if (_finished && !_success) ...[
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    backgroundColor: t.bgBase,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'close',
                    style: TextStyle(
                      color: t.textPrimary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Onion route animation ────────────────────────────────────────────────────

/// Symbolic visualisation of a message hopping through the privacy network.
/// Renders 4 nodes in a row with a moving packet that lights each node as
/// it passes. Purely cosmetic — does not reflect real tunnel state (i2pd
/// doesn't expose hop info via SAM), but gives the user a sense that work
/// is happening during the otherwise opaque reconnect flow.
class _OnionRouteAnimation extends StatelessWidget {
  final AnimationController controller;
  final PhantomTokens tokens;
  static const int _nodeCount = 4;
  static const double _nodeSize = 14;
  static const double _gap = 20;
  static const double _packetSize = 8;

  const _OnionRouteAnimation({required this.controller, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final width = _nodeCount * _nodeSize + (_nodeCount - 1) * _gap;
    return SizedBox(
      width: width,
      height: 36,
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          final t = controller.value;
          final activeF = t * (_nodeCount - 1);
          final activeIdx = activeF.floor();
          final activeFrac = activeF - activeIdx;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: width - _nodeSize,
                height: 1,
                color: tokens.divider,
              ),
              for (int i = 0; i < _nodeCount; i++)
                Positioned(
                  left: i * (_nodeSize + _gap),
                  child: _OnionNode(
                    size: _nodeSize,
                    glow: _glowFor(i, activeIdx, activeFrac),
                    tokens: tokens,
                  ),
                ),
              Positioned(
                left: _packetXFor(t, width),
                child: Container(
                  width: _packetSize,
                  height: _packetSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tokens.accentLight,
                    boxShadow: [
                      BoxShadow(
                        color: tokens.accentLight.withValues(alpha: 0.6),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Glow strength 0..1 for a node given the packet's current position.
  static double _glowFor(int nodeIdx, int activeIdx, double activeFrac) {
    if (nodeIdx == activeIdx) return 1.0 - activeFrac * 0.5;
    if (nodeIdx == activeIdx + 1) return activeFrac;
    return 0.0;
  }

  /// X offset of the packet's top-left corner so its centre slides linearly
  /// from the first node's centre to the last node's centre across [width].
  static double _packetXFor(double t, double width) {
    final centerSpan = width - _nodeSize;
    final centerX = (_nodeSize / 2) + centerSpan * t;
    return centerX - _packetSize / 2;
  }
}

class _OnionNode extends StatelessWidget {
  final double size;
  final double glow;
  final PhantomTokens tokens;
  const _OnionNode({
    required this.size,
    required this.glow,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    final ringColor = Color.lerp(tokens.divider, tokens.accentLight, glow)!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tokens.bgSurface,
        border: Border.all(color: ringColor, width: 1.5),
        boxShadow: glow > 0.1
            ? [
                BoxShadow(
                  color: tokens.accentLight.withValues(alpha: 0.4 * glow),
                  blurRadius: 8 * glow,
                ),
              ]
            : null,
      ),
    );
  }
}

// ── QR: show my contact address / scan a contact's ───────────────────────────
// The CA (v3 ≈ 1.4 KB → ~1.9 K base64url chars) fits in a dense-but-scannable
// QR. Rendering forces a white card so the code has contrast in both themes.

class _MyQrScreen extends StatelessWidget {
  final String contactAddress;
  const _MyQrScreen({required this.contactAddress});

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgSurface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: t.textSecondary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('my contact address',
            style: TextStyle(
                color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: contactAddress,
                  version: QrVersions.auto,
                  size: 300,
                  gapless: true,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'have your contact scan this from\n"add contact → scan QR"',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: t.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.5),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: contactAddress)),
                icon: Icon(Icons.copy_outlined, size: 14, color: t.accentLight),
                label: Text('copy as text',
                    style: TextStyle(
                        color: t.accentLight,
                        fontFamily: 'monospace',
                        fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QrScanScreen extends StatefulWidget {
  const _QrScanScreen();

  @override
  State<_QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<_QrScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('scan contact QR',
            style: TextStyle(
                color: Colors.white, fontFamily: 'monospace', fontSize: 16)),
      ),
      body: Stack(children: [
        ReaderWidget(
          showFlashlight: true,
          showGallery: false,
          tryInverted: true,
          onScan: (Code code) async {
            final text = code.text;
            if (_done || text == null || text.isEmpty) return;
            _done = true; // ReaderWidget keeps scanning; pop exactly once
            Navigator.of(context).pop(text);
          },
        ),
        Positioned(
          left: 0, right: 0, bottom: 32,
          child: Text(
            'point at your contact\'s QR',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontFamily: 'monospace',
                fontSize: 12,
                shadows: const [Shadow(color: Colors.black, blurRadius: 6)]),
          ),
        ),
      ]),
    );
  }
}

// ── Create Group ──────────────────────────────────────────────────────────────

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameCtrl = TextEditingController();
  final Set<String> _selected = {};
  List<ContactRecord>? _contacts;
  String? _error;
  bool _creating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_contacts == null) {
      final core = CoreProvider.of(context).core;
      core?.getContacts().then((cs) {
        if (mounted) {
          setState(() =>
              _contacts = cs.where((c) => !c.isArchived).toList());
        }
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'give the group a name');
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = 'pick at least one member');
      return;
    }
    final core = CoreProvider.of(context).core;
    if (core == null) return;
    setState(() { _creating = true; _error = null; });
    try {
      final g = await core.createGroup(
          name: name, memberIds: _selected.toList());
      if (!mounted) return;
      Navigator.of(context).pushReplacement(_AppRoute(
          builder: (_) => ChatScreen(
              contactName: g.name,
              contactId: groupConversationId(g.gid),
              isGroup: true)));
    } catch (_) {
      if (mounted) {
        setState(() { _creating = false; _error = 'could not create group'; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgSurface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: t.textSecondary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('new group',
            style: TextStyle(
                color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('group name',
                style: TextStyle(
                    color: t.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: 12)),
            const SizedBox(height: 8),
            _PhantomField(
              controller: _nameCtrl,
              hint: 'the crew',
              error: _error,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 16),
            Text('members (${_selected.length} selected)',
                style: TextStyle(
                    color: t.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: 12)),
          ]),
        ),
        Expanded(
          child: _contacts == null
              ? Center(
                  child: CircularProgressIndicator(
                      color: t.accentLight, strokeWidth: 1))
              : _contacts!.isEmpty
                  ? Center(
                      child: Text('add contacts first',
                          style: TextStyle(
                              color: t.textDisabled,
                              fontFamily: 'monospace',
                              fontSize: 13)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _contacts!.length,
                      itemBuilder: (ctx, i) {
                        final c = _contacts![i];
                        final on = _selected.contains(c.phantomId);
                        return CheckboxListTile(
                          value: on,
                          activeColor: t.accentLight,
                          checkColor: t.bgBase,
                          title: Text(c.displayName,
                              style: TextStyle(
                                  color: t.textPrimary,
                                  fontFamily: 'monospace',
                                  fontSize: 14)),
                          onChanged: (v) => setState(() => v == true
                              ? _selected.add(c.phantomId)
                              : _selected.remove(c.phantomId)),
                        );
                      },
                    ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _creating
                ? Center(
                    child: CircularProgressIndicator(
                        color: t.accentLight, strokeWidth: 1))
                : _PhantomButton(label: 'create group', onTap: _create),
          ),
        ),
      ]),
    );
  }
}

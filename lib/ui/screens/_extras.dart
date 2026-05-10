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
        imageBytes:         imageBytes,
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
  final Uint8List     imageBytes;
  final PhantomTokens tokens;
  final PhantomCore?  core;
  final String        currentContactId;
  final String        currentContactName;

  const _ForwardSheet({
    required this.imageBytes,
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
        bytes:       widget.imageBytes,
        fileName:    'shared_${DateTime.now().millisecondsSinceEpoch}.jpg',
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
  /// Title rendered in the dialog. Defaults to the revive flow.
  final String title;
  /// Final-success message shown for 2s before auto-dismiss.
  final String successMessage;
  /// Final-failure message.
  final String failureMessage;
  /// Stream factory: builds the progress stream when the dialog mounts.
  /// Defaults to [PhantomCore.reviveConnection].
  final Stream<String> Function(PhantomCore core, String contactId)? streamBuilder;

  const _ReviveDialog({
    required this.contactId,
    required this.core,
    required this.t,
    this.title = 'Reviving Connection',
    this.successMessage = 'connection revived!',
    this.failureMessage = 'revive failed',
    this.streamBuilder,
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
    final stream = widget.streamBuilder != null
        ? widget.streamBuilder!(widget.core, widget.contactId)
        : widget.core.reviveConnection(widget.contactId);
    await for (final status in stream) {
      if (!mounted) break;
      if (status == 'success') {
        setState(() {
          _status = widget.successMessage;
          _finished = true;
          _success = true;
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
        break;
      } else if (status == 'failed') {
        setState(() {
          _status = widget.failureMessage;
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
              RotationTransition(
                turns: _controller,
                child: Container(
                  width: 60, height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [t.accentLight, t.accentLight.withValues(alpha: 0)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Container(
                      decoration: BoxDecoration(
                        color: t.bgSurface,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.electrical_services_outlined,
                          color: t.accentLight, size: 28),
                    ),
                  ),
                ),
              )
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
              widget.title,
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

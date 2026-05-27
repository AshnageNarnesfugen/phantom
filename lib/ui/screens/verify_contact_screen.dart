part of 'screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VERIFY CONTACT SCREEN
// Side-by-side display of the safety number so both peers can read it out and
// confirm the IK exchange wasn't tampered with by a MITM during the QR step.
// ─────────────────────────────────────────────────────────────────────────────

class VerifyContactScreen extends StatefulWidget {
  final String contactId;
  final String contactName;

  const VerifyContactScreen({
    super.key,
    required this.contactId,
    required this.contactName,
  });

  @override
  State<VerifyContactScreen> createState() => _VerifyContactScreenState();
}

class _VerifyContactScreenState extends State<VerifyContactScreen> {
  String? _safetyNumber;
  bool _isVerified = false;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    if (core != null && _loading) {
      _load(core);
    }
  }

  Future<void> _load(PhantomCore core) async {
    String? num;
    try { num = await core.safetyNumber(widget.contactId); } catch (_) {}
    final c = await core.storage.getContact(widget.contactId);
    if (!mounted) return;
    setState(() {
      _safetyNumber = num;
      _isVerified   = c?.isVerified ?? false;
      _loading      = false;
    });
  }

  Future<void> _toggle(PhantomCore core) async {
    final newState = !_isVerified;
    await core.setContactVerified(widget.contactId, verified: newState);
    if (!mounted) return;
    setState(() => _isVerified = newState);
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    final core = CoreProvider.of(context).core;

    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgSurface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: t.textSecondary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('verify ${widget.contactName}',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 15)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('safety number',
                      style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: t.bgSurface,
                      borderRadius: BorderRadius.circular(t.radiusCard),
                      border: Border.all(color: t.inputBorder, width: 0.8),
                    ),
                    child: SelectableText(
                      _safetyNumber ?? '—',
                      style: TextStyle(
                        color: t.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 18,
                        letterSpacing: 1.5,
                        height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Compara este número con ${widget.contactName} por un canal '
                    'separado (llamada, en persona, etc). Si coinciden en ambos '
                    'lados, nadie sustituyó la clave en el QR.',
                    style: TextStyle(
                      color: t.textSecondary,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      Icon(
                        _isVerified ? Icons.verified : Icons.shield_outlined,
                        color: _isVerified ? t.accentLight : t.textSecondary,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _isVerified
                              ? 'contacto verificado'
                              : 'no verificado',
                          style: TextStyle(
                            color: t.textPrimary,
                            fontFamily: 'monospace',
                            fontSize: 14,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: core == null ? null : () => _toggle(core),
                        child: Text(
                          _isVerified ? 'unmark' : 'mark as verified',
                          style: TextStyle(
                            color: t.accentLight,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}

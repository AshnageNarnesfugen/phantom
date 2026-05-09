part of 'screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ONBOARDING
// ─────────────────────────────────────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0; // 0=welcome 1=choice 2=new_seed 3=restore_seed 4=restore_backup

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return Scaffold(
      backgroundColor: t.bgBase,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (_step) {
            0 => _WelcomeStep(onNext: () => setState(() => _step = 1)),
            1 => _ChoiceStep(
                onNew:           () => setState(() => _step = 2),
                onRestore:       () => setState(() => _step = 3),
                onRestoreBackup: () => setState(() => _step = 4),
              ),
            2 => _NewAccountStep(onBack: () => setState(() => _step = 1)),
            3 => _RestoreStep(onBack: () => setState(() => _step = 1)),
            4 => _RestoreFromBackupStep(onBack: () => setState(() => _step = 1)),
            _ => const SizedBox.shrink(),
          },
        ),
      ),
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  final VoidCallback onNext;
  const _WelcomeStep({required this.onNext});

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 3),
          Text(
            'phantom',
            style: TextStyle(
              color: t.accentLight,
              fontSize: 38,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w300,
              letterSpacing: 8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '// private messenger',
            style: TextStyle(color: t.textDisabled, fontSize: 13, fontFamily: 'monospace'),
          ),
          const Spacer(flex: 2),
          ...[
            ('no phone number',   'your id is a cryptographic key'),
            ('no servers',        'messages travel peer-to-peer'),
            ('no metadata',       'timestamps and sizes are noise'),
            ('no trust required', 'math guarantees privacy'),
          ].map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('> ', style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 13)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.$1, style: TextStyle(color: t.textPrimary,  fontFamily: 'monospace', fontSize: 13)),
                      Text(e.$2, style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
          )),
          const Spacer(flex: 3),
          _PhantomButton(label: 'get started', onTap: onNext),
        ],
      ),
    );
  }
}

class _ChoiceStep extends StatelessWidget {
  final VoidCallback onNew;
  final VoidCallback onRestore;
  final VoidCallback onRestoreBackup;
  const _ChoiceStep({
    required this.onNew,
    required this.onRestore,
    required this.onRestoreBackup,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 2),
          Text('identity',
              style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 24, fontWeight: FontWeight.w300)),
          const SizedBox(height: 8),
          Text(
            'your account is a seed phrase.\nno email. no number. no server.',
            style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 13, height: 1.7),
          ),
          const Spacer(flex: 3),
          _PhantomButton(label: 'create new account', onTap: onNew),
          const SizedBox(height: 12),
          _PhantomButton(label: 'restore from seed phrase', onTap: onRestore, outlined: true),
          const SizedBox(height: 12),
          _PhantomButton(label: 'restore from backup file', onTap: onRestoreBackup, outlined: true),
          const Spacer(),
        ],
      ),
    );
  }
}

class _NewAccountStep extends StatefulWidget {
  final VoidCallback onBack;
  const _NewAccountStep({required this.onBack});

  @override
  State<_NewAccountStep> createState() => _NewAccountStepState();
}

class _NewAccountStepState extends State<_NewAccountStep> {
  String? _seedPhrase;
  String? _phantomId;
  PhantomCore? _core;
  bool _generating = true;
  bool _confirmed = false;
  bool _obscured = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generateAccount();
  }

  Future<void> _generateAccount() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final result = await PhantomCore.createAccount(storagePath: dir.path);
      if (mounted) {
        setState(() {
          _core      = result.core;
          _seedPhrase = result.seedPhrase;
          _phantomId  = result.core.myId;
          _generating = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'failed to generate identity'; _generating = false; });
    }
  }

  Future<void> _enterPhantom() async {
    final core = _core;
    final seed = _seedPhrase;
    if (!_confirmed || core == null || seed == null) return;
    await CoreProvider.of(context).onAccountReady(core, seed);
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        _AppRoute(builder: (_) => const ConversationsScreen()),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Row(
            children: [
              GestureDetector(
                onTap: widget.onBack,
                child: Icon(Icons.arrow_back, color: t.textSecondary, size: 20),
              ),
              const SizedBox(width: 12),
              Text('your seed phrase',
                  style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 18)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'write these 24 words in order and store them safely.\nthis is your only way to access your account.',
            style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 24),

          if (_generating)
            Center(child: Padding(
              padding: const EdgeInsets.all(32),
              child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1),
            ))
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: Color(0xFFCF6679), fontFamily: 'monospace', fontSize: 12))
          else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('seed phrase', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
                GestureDetector(
                  onTap: () => setState(() => _obscured = !_obscured),
                  child: Text(
                    _obscured ? 'show' : 'hide',
                    style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SeedPhraseGrid(seedPhrase: _seedPhrase!, obscured: _obscured),

            const SizedBox(height: 24),
            Text('your phantom id',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            PhantomIdDisplay(phantomId: _phantomId!),

            const SizedBox(height: 32),
            GestureDetector(
              onTap: () => setState(() => _confirmed = !_confirmed),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: _confirmed ? t.accentLight.withValues(alpha: 0.2) : Colors.transparent,
                      border: Border.all(
                        color: _confirmed ? t.accentLight : t.inputBorder,
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: _confirmed ? Icon(Icons.check, size: 12, color: t.accentLight) : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'i have written down my seed phrase',
                      style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _PhantomButton(
              label: 'enter phantom',
              onTap: _confirmed ? _enterPhantom : null,
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _RestoreStep extends StatefulWidget {
  final VoidCallback onBack;
  const _RestoreStep({required this.onBack});

  @override
  State<_RestoreStep> createState() => _RestoreStepState();
}

class _RestoreStepState extends State<_RestoreStep> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final words = _ctrl.text.trim().split(RegExp(r'\s+'));
    if (words.length != 12 && words.length != 24) {
      setState(() => _error = 'seed phrase must be 12 or 24 words');
      return;
    }
    final onReady = CoreProvider.of(context).onAccountReady;
    setState(() { _loading = true; _error = null; });
    try {
      final dir       = await getApplicationDocumentsDirectory();
      final seedPhrase = words.join(' ');
      final core      = await PhantomCore.restoreAccount(
        seedPhrase: seedPhrase,
        storagePath: dir.path,
      );
      await onReady(core, seedPhrase);
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          _AppRoute(builder: (_) => const ConversationsScreen()),
          (_) => false,
        );
      }
    } on InvalidSeedPhraseException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'could not restore account'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Row(
            children: [
              GestureDetector(
                onTap: widget.onBack,
                child: Icon(Icons.arrow_back, color: t.textSecondary, size: 20),
              ),
              const SizedBox(width: 12),
              Text('restore account',
                  style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 18)),
            ],
          ),
          const SizedBox(height: 24),
          Text('enter your 12 or 24-word seed phrase',
              style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: t.bgSubtle,
              borderRadius: BorderRadius.circular(t.radiusInput),
              border: Border.all(
                color: _error != null ? const Color(0xFFCF6679) : t.inputBorder,
                width: 0.5,
              ),
            ),
            child: TextField(
              controller: _ctrl,
              maxLines: 6,
              style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 14, height: 1.7),
              decoration: InputDecoration(
                hintText: 'word1 word2 word3 ...',
                hintStyle: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 13),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(14),
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: const TextStyle(color: Color(0xFFCF6679), fontSize: 12, fontFamily: 'monospace')),
          ],
          const SizedBox(height: 24),
          _loading
              ? Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
              : _PhantomButton(label: 'restore', onTap: _restore),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESTORE FROM BACKUP FILE
// ─────────────────────────────────────────────────────────────────────────────

class _RestoreFromBackupStep extends StatefulWidget {
  final VoidCallback onBack;
  const _RestoreFromBackupStep({required this.onBack});

  @override
  State<_RestoreFromBackupStep> createState() => _RestoreFromBackupStepState();
}

class _RestoreFromBackupStepState extends State<_RestoreFromBackupStep> {
  final _seedCtrl = TextEditingController();
  bool _searching = true;
  File? _backupFile;
  String _expectedPath = '';
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _findBackup();
  }

  @override
  void dispose() {
    _seedCtrl.dispose();
    super.dispose();
  }

  Future<void> _findBackup() async {
    if (mounted) setState(() => _searching = true);
    final path = await BackupManager.backupFilePath();
    final file = await BackupManager.findBackupFile();
    if (mounted) {
      setState(() {
        _backupFile   = file;
        _expectedPath = path;
        _searching    = false;
      });
    }
  }

  Future<void> _restore() async {
    final file = _backupFile;
    if (file == null) {
      setState(() => _error = 'no backup file found');
      return;
    }
    final words = _seedCtrl.text.trim().split(RegExp(r'\s+'));
    if (words.length != 12 && words.length != 24) {
      setState(() => _error = 'seed phrase must be 12 or 24 words');
      return;
    }

    final onReady = CoreProvider.of(context).onAccountReady;
    setState(() { _loading = true; _error = null; });

    try {
      final seedPhrase = words.join(' ');
      final dir  = await getApplicationDocumentsDirectory();
      final core = await PhantomCore.restoreAccount(
        seedPhrase: seedPhrase,
        storagePath: dir.path,
      );

      final Uint8List data = await file.readAsBytes();
      await BackupManager.importBackup(
        storage:    core.storage,
        seedPhrase: seedPhrase,
        data:       data,
      );

      await onReady(core, seedPhrase);
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          _AppRoute(builder: (_) => const ConversationsScreen()),
          (_) => false,
        );
      }
    } on BackupException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'could not restore from backup'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Row(
            children: [
              GestureDetector(
                onTap: widget.onBack,
                child: Icon(Icons.arrow_back, color: t.textSecondary, size: 20),
              ),
              const SizedBox(width: 12),
              Text('restore from backup',
                  style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 18)),
            ],
          ),
          const SizedBox(height: 24),

          if (_searching)
            Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
          else if (_backupFile != null) ...[
            Text('backup file found',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 6),
            _BackupPathBox(path: _backupFile!.path, tokens: t),
            const SizedBox(height: 20),
            Text('enter your seed phrase to decrypt',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            _PhantomField(
              controller: _seedCtrl,
              hint: 'word1 word2 word3 ...',
              maxLines: 4,
              error: _error,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 24),
            _loading
                ? Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
                : _PhantomButton(label: 'restore', onTap: _restore),
          ] else ...[
            Text('no backup file found',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 6),
            Text('place your backup file at this path, then tap check again:',
                style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11, height: 1.6)),
            const SizedBox(height: 8),
            _BackupPathBox(path: _expectedPath, tokens: t),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Text(_error!,
                  style: const TextStyle(color: Color(0xFFCF6679), fontSize: 12, fontFamily: 'monospace')),
              const SizedBox(height: 12),
            ],
            _PhantomButton(
              label: 'check again',
              onTap: _findBackup,
              outlined: true,
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _BackupPathBox extends StatelessWidget {
  final String path;
  final PhantomTokens tokens;
  const _BackupPathBox({required this.path, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return GestureDetector(
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
              child: Text(
                path,
                style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 10),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.copy_outlined, size: 14, color: t.iconDefault),
          ],
        ),
      ),
    );
  }
}


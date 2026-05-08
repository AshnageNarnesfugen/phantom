import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../core_provider.dart';
import '../../core/ipfs_daemon.dart';
import '../../core/phantom_core.dart';
import '../../core/transport_debugger.dart';
import '../../core/update_service.dart';
import '../theme/phantom_theme.dart';
import '../widgets/widgets.dart';

const _seedKey = 'phantom_seed_v1';

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
              ? _glassBgBlur
                  ? ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                          sigmaX: _glassBlur, sigmaY: _glassBlur,
                          tileMode: TileMode.clamp),
                      child: Image.file(File(bgPath), fit: BoxFit.cover))
                  : Image.file(File(bgPath), fit: BoxFit.cover)
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
  StoredMessage? _replyTo;
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
      _loadMessages(core);
      _loadWallpaper(core);
      _loadGlass(core);
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
    if (unread.isNotEmpty) {
      core.sendReadReceipts(widget.contactId, unread); // fire-and-forget
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
                Text(widget.contactName,
                    style: TextStyle(
                        color: t.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 15)),
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

    final scaffold = Scaffold(
      backgroundColor: g ? Colors.transparent : t.bgBase,
      appBar: appBar,
      body: Column(
        children: [
          Expanded(child: messageList),
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
                  if (core != null) _showSafetyNumber(t, core);
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

  void _showSafetyNumber(PhantomTokens t, PhantomCore core) {
    core.safetyNumber(widget.contactId).then((number) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: t.bgSurface,
          title: Text('safety number',
              style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'compare this with your contact in person to verify no one is intercepting your messages.',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 20),
              Text(
                number,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 18,
                    letterSpacing: 2, height: 1.8),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('close', style: TextStyle(color: t.textSecondary, fontFamily: 'monospace')),
            ),
          ],
        ),
      );
    });
  }

  void _showEditContact(PhantomTokens t, PhantomCore? core) async {
    final contact = await core?.storage.getContact(widget.contactId);
    final nickCtrl = TextEditingController(text: contact?.nickname ?? '');
    final ipfsCtrl = TextEditingController(text: contact?.ipfsPeerId ?? '');

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
            const SizedBox(height: 20),
            Text('ipfs peer id',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 4),
            Text('allows direct connection via relay',
                style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
            const SizedBox(height: 8),
            _PhantomField(controller: ipfsCtrl, hint: '12D3Koo... or Qm...'),
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
              final ipfs = ipfsCtrl.text.trim();
              if (core != null) {
                final current = await core.storage.getContact(widget.contactId);
                if (current != null) {
                  await core.storage.saveContact(
                    current.copyWith(
                      nickname: nick.isEmpty ? null : nick,
                      ipfsPeerId: ipfs.isEmpty ? null : ipfs,
                    ),
                  );
                  // Notify core/presence about the updated peer ID
                  if (ipfs.isNotEmpty) {
                    core.setContactIpfsPeerId(widget.contactId, ipfs);
                  }
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
  final _ipfsCtrl    = TextEditingController();
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
    _addressCtrl.addListener(_onAddressChanged);
  }

  void _onAddressChanged() {
    final text = _addressCtrl.text.trim();
    final hashIdx = text.lastIndexOf('#');
    if (hashIdx > 0) {
      final candidate = text.substring(hashIdx + 1).trim();
      if ((candidate.startsWith('12D3Koo') || candidate.startsWith('Qm')) && _ipfsCtrl.text.isEmpty) {
        _ipfsCtrl.text = candidate;
      }
    }
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
    _ipfsCtrl.dispose();
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
      final ipfs = _ipfsCtrl.text.trim();
      await core.addContact(
        contactAddress: address,
        nickname: nick.isEmpty ? null : nick,
        ipfsPeerId: ipfs.isEmpty ? null : ipfs,
      );
      if (mounted) Navigator.pop(context);
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
      body: Padding(
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
            const SizedBox(height: 20),
            Text('ipfs peer id (optional)',
                style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 4),
            Text('allows direct connection via circuit relay',
                style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
            const SizedBox(height: 8),
            _PhantomField(controller: _ipfsCtrl, hint: '12D3Koo... or Qm...'),
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
  String? _myIpfsPeerId;
  String? _ownAvatarPath;
  final _myAliasCtrl = TextEditingController();
  final _yggdrasilCtrl = TextEditingController();
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions());

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
      core.getMyIpfsPeerId().then((id) {
        if (mounted) setState(() => _myIpfsPeerId = id);
      });
      core.storage.getOwnAvatarPath().then((p) {
        if (mounted) setState(() => _ownAvatarPath = p);
      });
      core.storage.getSetting<String>('my_alias').then((alias) {
        if (mounted && alias != null) _myAliasCtrl.text = alias;
      });
      core.storage.getSetting<String>('yggdrasil_address').then((ygg) {
        if (mounted && ygg != null) _yggdrasilCtrl.text = ygg;
      });
      _loadGlass(core);
      _refreshStatus();
      _refreshTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
    }
  }

  Timer? _refreshTimer;

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
    _yggdrasilCtrl.dispose();
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('your phantom id',
                      style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 6),
                  PhantomIdDisplay(phantomId: core.myId),
                  if (_myIpfsPeerId != null) ...[
                    const SizedBox(height: 16),
                    Text('your ipfs peer id',
                        style: TextStyle(color: t.textSecondary, fontFamily: 'monospace', fontSize: 12)),
                    const SizedBox(height: 6),
                    _PeerIdDisplay(peerId: _myIpfsPeerId!, tokens: t),
                  ],
                ],
              ),
            ),
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
          _SettingTile(
            icon: Icons.wifi,
            label: 'transport',
            value: core?.isTransportAvailable == true ? 'connected' : 'offline',
            tokens: t,
            onTap: () => _showTransportSheet(context, t, core),
          ),
          _SettingTile(
            icon: _ipfsRunning == true ? Icons.hub : Icons.hub_outlined,
            label: 'ipfs node',
            value: _ipfsRunning == null
                ? 'checking...'
                : _ipfsRunning!
                    ? 'running · $_ipfsPeers peer${_ipfsPeers == 1 ? '' : 's'}'
                    : 'offline',
            tokens: t,
            onTap: () => _showIpfsDiagnostics(context, t),
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
          _SectionHeader('network', t),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('yggdrasil ipv6 (override)',
                    style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 14)),
                const SizedBox(height: 4),
                Text('leave empty to auto-detect. manually enter if android hides vpn interfaces.',
                    style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11)),
                const SizedBox(height: 8),
                TextField(
                  controller: _yggdrasilCtrl,
                  style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'e.g. 02xx:...',
                    hintStyle: TextStyle(color: t.textDisabled),
                    filled: true,
                    fillColor: t.bgSubtle,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(t.radiusCard),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(Icons.save, color: t.accentLight, size: 16),
                      onPressed: () {
                        core?.setMyYggdrasilAddress(_yggdrasilCtrl.text.trim());
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('yggdrasil address updated', style: TextStyle(fontFamily: 'monospace', fontSize: 12)),
                            backgroundColor: t.bgSubtle,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
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
              ? _glassBgBlur
                  ? ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: _glassBlur,
                        sigmaY: _glassBlur,
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

  void _showTransportSheet(BuildContext context, PhantomTokens t, PhantomCore? core) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard)),
      ),
      builder: (_) => _TransportStatusSheet(tokens: t, core: core),
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

class _PeerIdDisplay extends StatefulWidget {
  final String peerId;
  final PhantomTokens tokens;
  const _PeerIdDisplay({required this.peerId, required this.tokens});
  @override State<_PeerIdDisplay> createState() => _PeerIdDisplayState();
}

class _PeerIdDisplayState extends State<_PeerIdDisplay> {
  bool _copied = false;
  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.peerId));
        setState(() => _copied = true);
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _copied = false);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: t.bgSubtle,
          borderRadius: BorderRadius.circular(t.radiusCard),
          border: Border.all(color: t.inputBorder, width: 0.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.peerId,
                style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(_copied ? Icons.check : Icons.copy_outlined,
                size: 14, color: _copied ? t.accentLight : t.iconDefault),
          ],
        ),
      ),
    );
  }
}

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

  @override
  void initState() {
    super.initState();
    _status = widget.core?.transportStatus;
    _sub = widget.core?.transportModeChanges.listen((_) {
      if (mounted) setState(() => _status = widget.core?.transportStatus);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
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
          _TransportRow(label: 'bluetooth mesh', value: s?.btMeshState == true ? 'active' : 'inactive', tokens: t),
          _TransportRow(label: 'bt peers nearby', value: '${s?.btPeerCount ?? 0}', tokens: t),
          _TransportRow(label: 'queued messages', value: '${s?.pendingMessages ?? 0}', tokens: t),
          const SizedBox(height: 4),
          Text(
            s?.mode == TransportMode.offline
                ? '// no transport available — messages will be queued and delivered when a connection is established'
                : '// messages are being routed via $modeLabel',
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
  static const _apiBase = 'http://127.0.0.1:5001/api/v0';
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
            if (widget.core != null) ...[
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
          final isOk   = line.contains('✓') || line.contains('OK');
          final color  = isErr  ? const Color(0xFFCF6679)
                       : isWarn ? const Color(0xFFFFB74D)
                       : isOk   ? const Color(0xFF4CAF50)
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

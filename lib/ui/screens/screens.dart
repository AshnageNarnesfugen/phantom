import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../core_provider.dart';
import '../../core/phantom_core.dart';
import '../../core/update_service.dart';
import '../../core/device_wallpaper_service.dart';
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
        MaterialPageRoute(builder: (_) => const ConversationsScreen()),
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
          MaterialPageRoute(builder: (_) => const ConversationsScreen()),
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
          MaterialPageRoute(builder: (_) => const ConversationsScreen()),
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    if (core != null && _msgSub == null) {
      _msgSub = core.incomingMessages.listen((_) => _loadData(core));
      _presenceSub = core.presenceChanges.listen((_) { if (mounted) setState(() {}); });
      _loadData(core);
    }
    if (!_updateChecked) {
      _updateChecked = true;
      UpdateService.checkForUpdate().then((info) {
        if (info != null && mounted) { setState(() => _updateInfo = info); }
      });
    }
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

    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgSurface,
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
                  color: t.iconDefault, size: 20),
              tooltip: _showArchived ? 'back' : 'archived',
              onPressed: () => setState(() => _showArchived = !_showArchived),
            ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: t.iconDefault, size: 20),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
        bottom: PreferredSize(preferredSize: const Size.fromHeight(0.5),
            child: Divider(height: 0.5, color: t.divider)),
      ),
      body: Column(
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
                              MaterialPageRoute(builder: (_) => ChatScreen(
                                contactName: c.displayName, contactId: c.phantomId))).then((_) => _loadData(core)),
                            onLongPress: () => _showConvMenu(context, t, core, c),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: _showArchived ? null : FloatingActionButton(
        backgroundColor: t.bgSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusCard),
          side: BorderSide(color: t.inputBorder, width: 0.5),
        ),
        child: Icon(Icons.edit_outlined, color: t.accentLight, size: 20),
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AddContactScreen())).then((_) => _loadData(core)),
      ),
    );
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
  String? _wallpaperPath;
  PhantomCore? _core; // cached — safe to use in dispose()

  // Glass effect state
  bool   _glassEnabled = false;
  double _glassOpacity = 0.12;
  double _glassBlur    = 10.0;
  String? _deviceWallpaperPath;

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
    if (path != null && mounted) {
      final f = File(path);
      if (await f.exists()) setState(() => _wallpaperPath = path);
    }
  }

  Future<void> _loadGlass(PhantomCore core) async {
    final enabled = await core.storage.getGlassEnabled();
    final opacity = await core.storage.getGlassOpacity();
    final blur    = await core.storage.getGlassBlur();
    if (!mounted) return;
    setState(() {
      _glassEnabled = enabled;
      _glassOpacity = opacity;
      _glassBlur    = blur;
    });
    if (enabled) await _fetchDeviceWallpaper();
  }

  Future<void> _fetchDeviceWallpaper() async {
    final path = await DeviceWallpaperService.getWallpaperPath();
    if (mounted && path != null) setState(() => _deviceWallpaperPath = path);
  }

  Future<void> _loadMessages(PhantomCore core) async {
    final msgs = await core.getMessages(widget.contactId, limit: 100);
    if (mounted) {
      setState(() => _messages = msgs);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
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
    final stored = await core.sendMessage(
      recipientId: widget.contactId,
      text: text,
      replyToId: replyId,
    );
    if (mounted) {
      setState(() => _messages = [...(_messages ?? []), stored]);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Future<void> _sendFile(Uint8List bytes, String fileName) async {
    final core = CoreProvider.of(context).core;
    if (core == null) return;
    final stored = await core.sendFile(
      recipientId: widget.contactId,
      bytes: bytes,
      fileName: fileName,
    );
    if (mounted) {
      setState(() => _messages = [...(_messages ?? []), stored]);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
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
      MaterialPageRoute(
        fullscreenDialog: true,
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t    = PhantomTheme.tokensOf(context);
    final core = CoreProvider.of(context).core;
    final g    = _glassEnabled;

    // Background image for glass mode: device wallpaper > chat wallpaper > gradient.
    final bgPath = g ? (_deviceWallpaperPath ?? _wallpaperPath) : null;

    final appBar = AppBar(
      backgroundColor: g
          ? t.bgSurface.withValues(alpha: (_glassOpacity * 2.2).clamp(0.12, 0.88))
          : t.bgSurface,
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

    Widget body;
    if (g) {
      body = Stack(
        children: [
          // Full-screen background layer — wallpaper is blurred once here so
          // per-bubble BackdropFilter is not needed (avoids scroll artifacts).
          Positioned.fill(
            child: bgPath != null
                ? ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: _glassBlur,
                      sigmaY: _glassBlur,
                      tileMode: TileMode.clamp,
                    ),
                    child: Image.file(File(bgPath), fit: BoxFit.cover),
                  )
                : _GlassFallback(accent: t.accentLight),
          ),
          // Content (offset for AppBar via extendBodyBehindAppBar)
          Column(
            children: [
              SizedBox(
                height: MediaQuery.of(context).padding.top + kToolbarHeight,
              ),
              Expanded(child: messageList),
              inputBar,
            ],
          ),
        ],
      );
    } else {
      body = Column(
        children: [
          Expanded(child: messageList),
          inputBar,
        ],
      );
    }

    return Scaffold(
      extendBodyBehindAppBar: g,
      backgroundColor: t.bgBase,
      appBar: appBar,
      body: body,
    );
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
              glassEnabled: _glassEnabled,
              glassOpacity: _glassOpacity,
              glassBlur:    _glassBlur,
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
            fit: BoxFit.cover,
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(width: 36, height: 3,
              decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2))),
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
              if (picked != null && core != null && mounted) {
                await core.storage.setWallpaper(widget.contactId, picked.path);
                setState(() => _wallpaperPath = picked.path);
              }
            }),
          _MenuItem(icon: Icons.wallpaper_outlined, label: 'set global wallpaper', tokens: t,
            onTap: () async {
              Navigator.pop(context);
              final picked = await ImagePicker().pickImage(
                  source: ImageSource.gallery, imageQuality: 80);
              if (picked != null && core != null && mounted) {
                await core.storage.setWallpaper(null, picked.path);
                if (_wallpaperPath == null) setState(() => _wallpaperPath = picked.path);
              }
            }),
          if (_wallpaperPath != null)
            _MenuItem(icon: Icons.hide_image_outlined, label: 'remove wallpaper', tokens: t,
              onTap: () async {
                Navigator.pop(context);
                if (core != null) {
                  await core.storage.clearWallpaper(widget.contactId);
                  if (mounted) setState(() => _wallpaperPath = null);
                }
              }),
          _MenuItem(icon: Icons.account_circle_outlined, label: 'share my avatar', tokens: t,
            onTap: () async {
              Navigator.pop(context);
              await core?.sendAvatarToContact(widget.contactId);
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
                'uses device wallpaper when available, otherwise the chat wallpaper.',
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
                      if (val) await _fetchDeviceWallpaper();
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

  static String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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
  String? _error;
  bool _loading = false;

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
      if (mounted) Navigator.pop(context);
    } on InvalidPhantomIdException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'invalid contact address'; _loading = false; });
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
        title: Text('add contact',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(height: 0.5, color: t.divider),
        ),
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
            const SizedBox(height: 32),
            _loading
                ? Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
                : _PhantomButton(label: 'add contact', onTap: _add),
          ],
        ),
      ),
    );
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
  String? _ownAvatarPath;
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

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
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = CoreProvider.of(context);
    final theme    = PhantomTheme.of(context);
    final t        = theme.tokens;
    final core     = provider.core;

    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgSurface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: t.textSecondary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('settings',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 16)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(height: 0.5, color: t.divider),
        ),
      ),
      body: ListView(
        children: [
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
                    if (picked != null && core != null) {
                      await core.storage.setOwnAvatarPath(picked.path);
                      if (mounted) setState(() => _ownAvatarPath = picked.path);
                    }
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
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
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

          // ── About ─────────────────────────────────────────────
          _SectionHeader('about', t),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'phantom v0.1.0-alpha\nX3DH + Double Ratchet\nno servers — no metadata\nAGPL-3.0',
              style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 11, height: 1.7),
            ),
          ),
          const SizedBox(height: 32),
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

// Inline intensity slider used directly inside the appearance section.
class _IntensitySlider extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = tokens;
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
              '${(value * 100).round()}%',
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
            value: value.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            divisions: 20,
            onChanged: onChange,
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

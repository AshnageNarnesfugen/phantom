import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import '../../core_provider.dart';
import '../../core/phantom_core.dart';
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
  StreamSubscription<StoredMessage>? _sub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    if (core != null && _sub == null) {
      _sub = core.incomingMessages.listen((_) => _loadData(core));
      _loadData(core);
    }
  }

  Future<void> _loadData(PhantomCore core) async {
    final contacts = await core.getContacts();
    final lastMsgs = <String, StoredMessage?>{};
    for (final c in contacts) {
      lastMsgs[c.phantomId] = await core.getLastMessage(c.phantomId);
    }
    if (mounted) {
      setState(() {
        _contacts = contacts;
        _lastMessages.addAll(lastMsgs);
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
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

    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgSurface,
        elevation: 0,
        title: Text(
          'phantom',
          style: TextStyle(color: t.accentLight, fontFamily: 'monospace', fontSize: 18,
              fontWeight: FontWeight.w300, letterSpacing: 4),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_outlined, color: t.iconDefault, size: 20),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(height: 0.5, color: t.divider),
        ),
      ),
      body: _contacts == null
          ? Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
          : _contacts!.isEmpty
              ? _EmptyContacts(tokens: t)
              : ListView.builder(
                  itemCount: _contacts!.length,
                  itemBuilder: (context, i) {
                    final c    = _contacts![i];
                    final last = _lastMessages[c.phantomId];
                    return ConversationTile(
                      displayName: c.displayName,
                      phantomId:   c.phantomId,
                      lastMessage: last?.type == MessageType.text ? last?.textContent : null,
                      timeLabel:   last != null ? _formatTime(last.timestamp) : null,
                      unreadCount: 0,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(
                            contactName: c.displayName,
                            contactId:   c.phantomId,
                          ),
                        ),
                      ).then((_) => _loadData(core)),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: t.bgSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusCard),
          side: BorderSide(color: t.inputBorder, width: 0.5),
        ),
        child: Icon(Icons.edit_outlined, color: t.accentLight, size: 20),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddContactScreen()),
        ).then((_) => _loadData(core)),
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

class _EmptyContacts extends StatelessWidget {
  final PhantomTokens tokens;
  const _EmptyContacts({required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.people_outline, color: tokens.textDisabled, size: 48),
          const SizedBox(height: 16),
          Text('no contacts yet',
              style: TextStyle(color: tokens.textSecondary, fontFamily: 'monospace', fontSize: 14)),
          const SizedBox(height: 6),
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    if (core != null && _sub == null) {
      _sub = core.incomingMessages.listen((msg) {
        if (msg.conversationId == widget.contactId) _loadMessages(core);
      });
      _loadMessages(core);
    }
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
    final stored = await core.sendMessage(recipientId: widget.contactId, text: text);
    if (mounted) {
      setState(() => _messages = [...(_messages ?? []), stored]);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t    = PhantomTheme.tokensOf(context);
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.contactName,
                style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 15)),
            PhantomIdDisplay(phantomId: widget.contactId, compact: true),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.more_vert, color: t.iconDefault, size: 20),
            onPressed: () => _showContactMenu(context, t, core),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(height: 0.5, color: t.divider),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages == null
                ? Center(child: CircularProgressIndicator(color: t.accentLight, strokeWidth: 1))
                : _messages!.isEmpty
                    ? Center(
                        child: Text('no messages yet',
                            style: TextStyle(color: t.textDisabled, fontFamily: 'monospace', fontSize: 13)),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                        itemCount: _messages!.length,
                        itemBuilder: (context, i) {
                          final msg      = _messages![i];
                          final isOut    = msg.direction == MessageDirection.outgoing;
                          final nextSame = i < _messages!.length - 1 &&
                              (_messages![i + 1].direction == MessageDirection.outgoing) == isOut;

                          return Padding(
                            padding: EdgeInsets.only(bottom: nextSame ? 2 : 10),
                            child: ChatBubble(
                              text:      msg.type == MessageType.text ? msg.textContent : '[file]',
                              isOutgoing: isOut,
                              timeLabel: _formatTime(msg.timestamp),
                              showTail:  !nextSame,
                              status:    msg.status,
                            ),
                          );
                        },
                      ),
          ),
          MessageInput(onSend: _send),
        ],
      ),
    );
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

part of 'screens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONTACTS — every saved contact, independent of whether a conversation exists.
// Start (or resume) a chat with anyone here without re-adding them, and remove
// contacts from your address book.
// ─────────────────────────────────────────────────────────────────────────────

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<ContactRecord>? _contacts;
  final Map<String, Uint8List?> _avatars = {};
  StreamSubscription<String>? _contactSub;
  StreamSubscription<String>? _presenceSub;
  PhantomCore? _core;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = CoreProvider.of(context).core;
    if (core != null && _core == null) {
      _core = core;
      _load(core);
      _contactSub = core.contactChanges.listen((_) => _load(core));
      _presenceSub = core.presenceChanges.listen((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _contactSub?.cancel();
    _presenceSub?.cancel();
    super.dispose();
  }

  Future<void> _load(PhantomCore core) async {
    final contacts = await core.getContacts();
    contacts.sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    for (final c in contacts) {
      _avatars[c.phantomId] ??= await core.getContactAvatar(c.phantomId);
    }
    if (mounted) setState(() => _contacts = contacts);
  }

  void _openChat(ContactRecord c, {bool secret = false}) {
    Navigator.push(
      context,
      _AppRoute(
        builder: (_) => ChatScreen(
          contactName: c.displayName,
          contactId: secret ? secretConversationId(c.phantomId) : c.phantomId,
          isSecret: secret,
        ),
      ),
    );
  }

  void _showContactActions(PhantomTokens t, PhantomCore core, ContactRecord c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSurface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                    color: t.divider, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(c.displayName,
                  style: TextStyle(
                      color: t.textSecondary,
                      fontFamily: 'monospace',
                      fontSize: 13)),
            ),
            _MenuItem(
                icon: Icons.chat_bubble_outline,
                label: 'message',
                tokens: t,
                onTap: () {
                  Navigator.pop(ctx);
                  _openChat(c);
                }),
            _MenuItem(
                icon: Icons.lock_outline,
                label: 'secret chat',
                tokens: t,
                onTap: () {
                  Navigator.pop(ctx);
                  _openChat(c, secret: true);
                }),
            _MenuItem(
                icon: Icons.person_remove_outlined,
                label: 'delete contact',
                tokens: t,
                danger: true,
                onTap: () async {
                  Navigator.pop(ctx);
                  await core.deleteContact(c.phantomId);
                  await _load(core);
                }),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    final core = CoreProvider.of(context).core;
    final contacts = _contacts;

    return Scaffold(
      backgroundColor: t.bgBase,
      appBar: AppBar(
        backgroundColor: t.bgSurface,
        elevation: 0,
        title: Text('contacts',
            style: TextStyle(
                color: t.accentLight,
                fontFamily: 'monospace',
                fontSize: 18,
                fontWeight: FontWeight.w300,
                letterSpacing: 4)),
        actions: [
          IconButton(
            icon: Icon(Icons.person_add_outlined, color: t.iconDefault, size: 20),
            tooltip: 'add contact',
            onPressed: () => Navigator.push(context,
                    _AppRoute(builder: (_) => const AddContactScreen()))
                .then((_) => core != null ? _load(core) : null),
          ),
        ],
        bottom: PreferredSize(
            preferredSize: const Size.fromHeight(0.5),
            child: Divider(height: 0.5, color: t.divider)),
      ),
      body: contacts == null
          ? const Center(child: CircularProgressIndicator())
          : contacts.isEmpty
              ? Center(
                  child: Text('no contacts yet',
                      style: TextStyle(
                          color: t.textSecondary,
                          fontFamily: 'monospace',
                          fontSize: 13)))
              : ListView.builder(
                  itemCount: contacts.length,
                  itemBuilder: (context, i) {
                    final c = contacts[i];
                    return ConversationTile(
                      displayName: c.displayName,
                      phantomId: c.phantomId,
                      lastMessage: null,
                      timeLabel: null,
                      unreadCount: 0,
                      isOnline: core?.isContactOnline(c.phantomId) ?? false,
                      avatarBytes: _avatars[c.phantomId],
                      onTap: () => _openChat(c),
                      onLongPress: () =>
                          core != null ? _showContactActions(t, core, c) : null,
                    );
                  },
                ),
    );
  }
}

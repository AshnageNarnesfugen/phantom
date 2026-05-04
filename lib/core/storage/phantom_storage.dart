import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:cryptography/cryptography.dart';
import '../protocol/message.dart';

/// Encrypted local storage via Hive.
///
/// All data is encrypted with AES-GCM using a key derived from the seed phrase.
///
/// Boxes:
///   contacts  → ContactRecord per phantomId
///   sessions  → serialized RatchetSession state per phantomId
///   messages_{id} → StoredMessage per conversation
///   prekeys   → PreKeyStore (our own signed/one-time prekeys)
///   own_bundle → our own public PreKeyBundle (JSON)
///   settings  → arbitrary key-value

class PhantomStorage {
  static const _boxContacts   = 'contacts';
  static const _boxSessions   = 'sessions';
  static const _boxPrekeys    = 'prekeys';
  static const _boxOwnBundle  = 'own_bundle';
  static const _boxSettings   = 'settings';
  static const _boxMeshStore  = 'mesh_store';

  static PhantomStorage? _instance;
  HiveAesCipher? _cipher;
  bool _initialized = false;

  PhantomStorage._();

  static PhantomStorage get instance {
    _instance ??= PhantomStorage._();
    return _instance!;
  }

  Future<void> initialize({
    required String seedPhrase,
    required String storagePath,
  }) async {
    if (_initialized) return;
    Hive.init(storagePath);
    final aesKey = await _deriveStorageKey(seedPhrase);
    _cipher = HiveAesCipher(aesKey);
    _initialized = true;
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw const StorageException('PhantomStorage not initialized. Call initialize() first.');
    }
  }

  // ── Contacts ────────────────────────────────────────────────────────────────

  Future<void> saveContact(ContactRecord contact) async {
    _assertInitialized();
    final box = await _openBox(_boxContacts);
    await box.put(contact.phantomId, contact.toJson());
  }

  Future<ContactRecord?> getContact(String phantomId) async {
    _assertInitialized();
    final box  = await _openBox(_boxContacts);
    final data = box.get(phantomId);
    if (data == null) return null;
    return ContactRecord.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<List<ContactRecord>> getAllContacts() async {
    _assertInitialized();
    final box = await _openBox(_boxContacts);
    return box.values
        .map((v) => ContactRecord.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort((a, b) => b.addedAtUs.compareTo(a.addedAtUs));
  }

  Future<void> deleteContact(String phantomId) async {
    _assertInitialized();
    final box = await _openBox(_boxContacts);
    await box.delete(phantomId);
  }

  // ── Messages ─────────────────────────────────────────────────────────────────

  String _messagesBoxName(String conversationId) {
    final safe = conversationId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    return 'msg_$safe';
  }

  Future<void> saveMessage(StoredMessage message) async {
    _assertInitialized();
    final box = await _openBox(_messagesBoxName(message.conversationId));
    await box.put(message.id, message.toJson());
  }

  Future<List<StoredMessage>> getMessages(
    String conversationId, {
    int limit = 50,
    String? beforeId,
  }) async {
    _assertInitialized();
    final box = await _openBox(_messagesBoxName(conversationId));

    var messages = box.values
        .map((v) => StoredMessageJson.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort((a, b) => a.timestampUs.compareTo(b.timestampUs));

    if (beforeId != null) {
      final idx = messages.indexWhere((m) => m.id == beforeId);
      if (idx > 0) messages = messages.sublist(0, idx);
    }

    if (messages.length > limit) {
      messages = messages.sublist(messages.length - limit);
    }

    return messages;
  }

  Future<StoredMessage?> getLastMessage(String conversationId) async {
    final msgs = await getMessages(conversationId, limit: 1);
    return msgs.isEmpty ? null : msgs.last;
  }

  Future<void> updateMessageStatus(
      String conversationId, String messageId, MessageStatus status) async {
    _assertInitialized();
    final box  = await _openBox(_messagesBoxName(conversationId));
    final data = box.get(messageId);
    if (data == null) return;
    final msg = StoredMessageJson.fromJson(Map<String, dynamic>.from(data as Map));
    await box.put(messageId, msg.copyWith(status: status).toJson());
  }

  Future<void> deleteMessage(String conversationId, String messageId) async {
    _assertInitialized();
    final box = await _openBox(_messagesBoxName(conversationId));
    await box.delete(messageId);
  }

  Future<void> clearMessages(String conversationId) async {
    _assertInitialized();
    final box = await _openBox(_messagesBoxName(conversationId));
    await box.clear();
  }

  // ── Session state (Double Ratchet) ──────────────────────────────────────────

  Future<void> saveSessionState(String phantomId, Map<String, dynamic> state) async {
    _assertInitialized();
    final box = await _openBox(_boxSessions);
    await box.put(phantomId, state);
  }

  Future<Map<String, dynamic>?> getSessionState(String phantomId) async {
    _assertInitialized();
    final box  = await _openBox(_boxSessions);
    final data = box.get(phantomId);
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
  }

  Future<void> deleteSessionState(String phantomId) async {
    _assertInitialized();
    final box = await _openBox(_boxSessions);
    await box.delete(phantomId);
  }

  // ── PreKeys ─────────────────────────────────────────────────────────────────

  Future<void> savePreKeyStore(PreKeyStore store) async {
    _assertInitialized();
    final box = await _openBox(_boxPrekeys);
    await box.put('store', store.toJson());
  }

  Future<PreKeyStore?> getPreKeyStore() async {
    _assertInitialized();
    final box  = await _openBox(_boxPrekeys);
    final data = box.get('store');
    if (data == null) return null;
    return PreKeyStore.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<void> consumeOneTimePreKey(int id) async {
    final store = await getPreKeyStore();
    if (store == null) return;
    await savePreKeyStore(store.withoutOneTimePreKey(id));
  }

  // ── Own public bundle ────────────────────────────────────────────────────────

  Future<void> saveOwnBundle(Map<String, dynamic> bundleJson) async {
    _assertInitialized();
    final box = await _openBox(_boxOwnBundle);
    await box.put('bundle', bundleJson);
  }

  Future<Map<String, dynamic>?> getOwnBundle() async {
    _assertInitialized();
    final box  = await _openBox(_boxOwnBundle);
    final data = box.get('bundle');
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
  }

  // ── Settings ─────────────────────────────────────────────────────────────────

  Future<void> setSetting(String key, dynamic value) async {
    _assertInitialized();
    final box = await _openBox(_boxSettings);
    await box.put(key, value);
  }

  Future<T?> getSetting<T>(String key) async {
    _assertInitialized();
    final box = await _openBox(_boxSettings);
    return box.get(key) as T?;
  }

  // ── Mesh store (store-and-forward persistence) ────────────────────────────────

  Future<void> saveMessageStore(Map<String, dynamic> json) async {
    _assertInitialized();
    final box = await _openBox(_boxMeshStore);
    await box.put('store', json);
  }

  Future<Map<String, dynamic>?> getMessageStore() async {
    _assertInitialized();
    final box  = await _openBox(_boxMeshStore);
    final data = box.get('store');
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
  }

  // ── Wallpapers ────────────────────────────────────────────────────────────────

  static const _boxAvatars = 'avatars';

  Future<void> setWallpaper(String? contactId, String path) async {
    final key = contactId == null ? 'wallpaper_global' : 'wallpaper_$contactId';
    await setSetting(key, path);
  }

  Future<String?> getWallpaper(String? contactId) async {
    final key = contactId == null ? 'wallpaper_global' : 'wallpaper_$contactId';
    return getSetting<String>(key);
  }

  Future<void> clearWallpaper(String? contactId) async {
    _assertInitialized();
    final key = contactId == null ? 'wallpaper_global' : 'wallpaper_$contactId';
    final box = await _openBox(_boxSettings);
    await box.delete(key);
  }

  Future<String?> getAppWallpaper() async {
    final path = await getSetting<String>('wallpaper_app');
    if (path == null) return null;
    if (!await File(path).exists()) return null;
    return path;
  }

  Future<void> setAppWallpaper(String path) => setSetting('wallpaper_app', path);

  Future<void> clearAppWallpaper() async {
    _assertInitialized();
    final box = await _openBox(_boxSettings);
    await box.delete('wallpaper_app');
  }

  // ── Avatars ───────────────────────────────────────────────────────────────────

  Future<void> saveContactAvatar(String contactId, Uint8List bytes) async {
    _assertInitialized();
    final box = await _openBox(_boxAvatars);
    await box.put(contactId, base64.encode(bytes));
  }

  Future<Uint8List?> getContactAvatar(String contactId) async {
    _assertInitialized();
    final box  = await _openBox(_boxAvatars);
    final data = box.get(contactId) as String?;
    if (data == null) return null;
    return base64.decode(data);
  }

  Future<void> setOwnAvatarPath(String? path) async {
    if (path == null) {
      _assertInitialized();
      final box = await _openBox(_boxSettings);
      await box.delete('own_avatar_path');
    } else {
      await setSetting('own_avatar_path', path);
    }
  }

  Future<String?> getOwnAvatarPath() => getSetting<String>('own_avatar_path');

  // ── Glass effect settings ────────────────────────────────────────────────────

  Future<bool>   getGlassEnabled()  async => (await getSetting<bool>('glass_enabled'))    ?? false;
  Future<double> getGlassOpacity()  async => (await getSetting<double>('glass_opacity'))  ?? 0.12;
  Future<double> getGlassBlur()     async => (await getSetting<double>('glass_blur'))     ?? 10.0;
  // When true the wallpaper image is blurred at scene level (pre-blur).
  Future<bool>   getGlassBgBlur()   async => (await getSetting<bool>('glass_bg_blur'))    ?? false;

  Future<void> setGlassEnabled(bool v)   => setSetting('glass_enabled', v);
  Future<void> setGlassOpacity(double v) => setSetting('glass_opacity', v);
  Future<void> setGlassBlur(double v)    => setSetting('glass_blur', v);
  Future<void> setGlassBgBlur(bool v)    => setSetting('glass_bg_blur', v);

  // ── App-level glass (conversations + settings — independent from chat) ────────

  Future<bool>   getAppGlassEnabled()      async => (await getSetting<bool>('app_glass_enabled'))       ?? false;
  Future<double> getAppGlassOpacity()      async => (await getSetting<double>('app_glass_opacity'))     ?? 0.15;
  Future<double> getAppGlassBlur()         async => (await getSetting<double>('app_glass_blur'))        ?? 10.0;
  Future<bool>   getAppGlassBgBlur()       async => (await getSetting<bool>('app_glass_bg_blur'))       ?? false;
  Future<bool>   getAppGlassUseWallpaper() async => (await getSetting<bool>('app_glass_use_wallpaper')) ?? false;

  Future<void> setAppGlassEnabled(bool v)      => setSetting('app_glass_enabled', v);
  Future<void> setAppGlassOpacity(double v)    => setSetting('app_glass_opacity', v);
  Future<void> setAppGlassBlur(double v)       => setSetting('app_glass_blur', v);
  Future<void> setAppGlassBgBlur(bool v)       => setSetting('app_glass_bg_blur', v);
  Future<void> setAppGlassUseWallpaper(bool v) => setSetting('app_glass_use_wallpaper', v);

  // ── Internals ─────────────────────────────────────────────────────────────────

  Future<Box> _openBox(String name) async {
    if (Hive.isBoxOpen(name)) return Hive.box(name);
    return Hive.openBox(name, encryptionCipher: _cipher);
  }

  static Future<Uint8List> _deriveStorageKey(String seedPhrase) async {
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
    final out  = await hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(seedPhrase)),
      nonce: Uint8List.fromList(utf8.encode('phantom-storage-v1')),
      info: Uint8List.fromList(utf8.encode('phantom-hive-encryption-key')),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  Future<void> close() async {
    await Hive.close();
    _initialized = false;
  }

  Future<void> purgeAll() async {
    _assertInitialized();
    await Hive.deleteFromDisk();
    _initialized = false;
  }
}

// ── ContactRecord ─────────────────────────────────────────────────────────────

class ContactRecord {
  final String phantomId;
  final String? nickname;

  /// X25519 identity public key (from PhantomID).
  final Uint8List encryptionPublicKeyBytes;

  /// Ed25519 signing public key (from ContactAddress — for SPK verification).
  final Uint8List signingPublicKeyBytes;

  /// Signed PreKey public bytes (X25519) — for X3DH initiation.
  final Uint8List signedPreKeyBytes;
  final int signedPreKeyId;

  /// Ed25519 signature of signedPreKeyBytes.
  final Uint8List signedPreKeySignature;

  /// Kyber-768 public key (1184 bytes). Non-null when the contact supports
  /// quantum-resistant session establishment (ContactAddress v2).
  final Uint8List? kyber768PublicKeyBytes;

  final int addedAtUs;
  final bool isVerified;
  final bool isArchived;

  ContactRecord({
    required this.phantomId,
    this.nickname,
    required this.encryptionPublicKeyBytes,
    required this.signingPublicKeyBytes,
    required this.signedPreKeyBytes,
    required this.signedPreKeyId,
    required this.signedPreKeySignature,
    this.kyber768PublicKeyBytes,
    int? addedAtUs,
    this.isVerified = false,
    this.isArchived = false,
  }) : addedAtUs = addedAtUs ?? DateTime.now().microsecondsSinceEpoch;

  String get displayName => nickname ?? _shortId;
  String get _shortId => phantomId.length > 12
      ? '${phantomId.substring(0, 6)}…${phantomId.substring(phantomId.length - 4)}'
      : phantomId;

  Map<String, dynamic> toJson() => {
        'id':     phantomId,
        'nick':   nickname,
        'pk':     base64.encode(encryptionPublicKeyBytes),
        'sk':     base64.encode(signingPublicKeyBytes),
        'spk':    base64.encode(signedPreKeyBytes),
        'spk_id': signedPreKeyId,
        'sig':    base64.encode(signedPreKeySignature),
        'added':  addedAtUs,
        'ver':    isVerified,
        'arch':   isArchived,
        if (kyber768PublicKeyBytes != null)
          'kyber768_pk': base64.encode(kyber768PublicKeyBytes!),
      };

  static ContactRecord fromJson(Map<String, dynamic> j) => ContactRecord(
        phantomId:                j['id']    as String,
        nickname:                 j['nick']   as String?,
        encryptionPublicKeyBytes: base64.decode(j['pk']  as String),
        signingPublicKeyBytes:    base64.decode((j['sk']  as String?) ?? base64.encode(Uint8List(32))),
        signedPreKeyBytes:        base64.decode((j['spk'] as String?) ?? base64.encode(Uint8List(32))),
        signedPreKeyId:           (j['spk_id'] as int?) ?? 0,
        signedPreKeySignature:    base64.decode((j['sig'] as String?) ?? base64.encode(Uint8List(64))),
        kyber768PublicKeyBytes:   j['kyber768_pk'] != null
            ? base64.decode(j['kyber768_pk'] as String)
            : null,
        addedAtUs:                j['added']  as int,
        isVerified:               j['ver']    as bool? ?? false,
        isArchived:               j['arch']   as bool? ?? false,
      );

  ContactRecord copyWith({String? nickname, bool? isVerified, bool? isArchived}) => ContactRecord(
        phantomId:                phantomId,
        nickname:                 nickname   ?? this.nickname,
        encryptionPublicKeyBytes: encryptionPublicKeyBytes,
        signingPublicKeyBytes:    signingPublicKeyBytes,
        signedPreKeyBytes:        signedPreKeyBytes,
        signedPreKeyId:           signedPreKeyId,
        signedPreKeySignature:    signedPreKeySignature,
        kyber768PublicKeyBytes:   kyber768PublicKeyBytes,
        addedAtUs:                addedAtUs,
        isVerified:               isVerified ?? this.isVerified,
        isArchived:               isArchived ?? this.isArchived,
      );
}

// ── PreKeyStore ───────────────────────────────────────────────────────────────

class PreKeyStore {
  final Uint8List signedPreKeyPrivate;
  final Uint8List signedPreKeyPublic;
  final int signedPreKeyId;
  final Map<int, Uint8List> oneTimePreKeyPrivates;

  const PreKeyStore({
    required this.signedPreKeyPrivate,
    required this.signedPreKeyPublic,
    required this.signedPreKeyId,
    required this.oneTimePreKeyPrivates,
  });

  PreKeyStore withoutOneTimePreKey(int id) {
    final updated = Map<int, Uint8List>.from(oneTimePreKeyPrivates)..remove(id);
    return PreKeyStore(
      signedPreKeyPrivate:  signedPreKeyPrivate,
      signedPreKeyPublic:   signedPreKeyPublic,
      signedPreKeyId:       signedPreKeyId,
      oneTimePreKeyPrivates: updated,
    );
  }

  bool get isLowOnOneTimePreKeys => oneTimePreKeyPrivates.length < 5;

  Map<String, dynamic> toJson() => {
        'spk_priv': base64.encode(signedPreKeyPrivate),
        'spk_pub':  base64.encode(signedPreKeyPublic),
        'spk_id':   signedPreKeyId,
        'opks':     oneTimePreKeyPrivates.map(
          (id, priv) => MapEntry(id.toString(), base64.encode(priv)),
        ),
      };

  static PreKeyStore fromJson(Map<String, dynamic> j) {
    final opksRaw = j['opks'] as Map;
    return PreKeyStore(
      signedPreKeyPrivate:  base64.decode(j['spk_priv'] as String),
      signedPreKeyPublic:   base64.decode((j['spk_pub'] as String?) ?? base64.encode(Uint8List(32))),
      signedPreKeyId:       j['spk_id'] as int,
      oneTimePreKeyPrivates: opksRaw.map(
        (k, v) => MapEntry(int.parse(k as String), base64.decode(v as String)),
      ),
    );
  }
}

// ── StoredMessage JSON extension ──────────────────────────────────────────────

extension StoredMessageJson on StoredMessage {
  Map<String, dynamic> toJson() => {
        'id':      id,
        'conv':    conversationId,
        'type':    type.code,
        'content': base64.encode(content),
        'ts':      timestampUs,
        'dir':     direction.index,
        'status':  status.index,
        'reply':   replyToId,
      };

  static StoredMessage fromJson(Map<String, dynamic> j) => StoredMessage(
        id:             j['id']   as String,
        conversationId: j['conv'] as String,
        type:           MessageType.fromCode(j['type'] as int),
        content:        base64.decode(j['content'] as String),
        timestampUs:    j['ts']   as int,
        direction:      MessageDirection.values[j['dir']    as int],
        status:         MessageStatus.values[j['status'] as int],
        replyToId:      j['reply'] as String?,
      );
}

class StorageException implements Exception {
  final String message;
  const StorageException(this.message);
  @override
  String toString() => 'StorageException: $message';
}

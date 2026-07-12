import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:cryptography/cryptography.dart';
import '../crypto/native/phantom_crypto_native.dart';
import '../groups.dart';
import '../protocol/message.dart';

/// Per-key async lock. Serializes read-modify-write sequences that the storage
/// layer otherwise cannot guarantee atomic (OPK consumption, remote OPK pool,
/// prekey top-up) when called concurrently from different transports.
class _AsyncLock {
  Future<void> _tail = Future.value();
  Future<T> guard<T>(Future<T> Function() fn) {
    final completer = Completer<void>();
    final prev = _tail;
    _tail = completer.future;
    return prev.then((_) async {
      try {
        return await fn();
      } finally {
        completer.complete();
      }
    });
  }
}

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
  static const _boxGroups     = 'groups';
  static const _boxSessions   = 'sessions';
  static const _boxPrekeys    = 'prekeys';
  static const _boxOwnBundle  = 'own_bundle';
  static const _boxSettings   = 'settings';
  static const _boxMeshStore  = 'mesh_store';

  static PhantomStorage? _instance;
  HiveAesCipher? _cipher;
  bool _initialized = false;

  /// Prepended to every Hive box name. Hive's box registry is global and
  /// keyed by NAME only (the path is ignored for lookup), so two storage
  /// instances in one process — e.g. Alice and Bob in the loopback lab —
  /// need distinct prefixes or they'd silently share boxes.
  String _boxPrefix = '';

  /// Where this instance's boxes live on disk. Passed explicitly to every
  /// openBox so multiple instances don't depend on the global Hive.init
  /// home (last init call would win otherwise).
  String? _storagePath;

  final _preKeyLock = _AsyncLock();
  final Map<String, _AsyncLock> _opkLocks = {};
  _AsyncLock _opkLock(String contactId) =>
      _opkLocks.putIfAbsent(contactId, () => _AsyncLock());

  PhantomStorage._();

  static PhantomStorage get instance {
    _instance ??= PhantomStorage._();
    return _instance!;
  }

  /// A storage instance independent of the app-wide singleton. Used by the
  /// local lab / e2e tests to run several identities in one process. Pass a
  /// unique [boxNamespace] to initialize for each one.
  factory PhantomStorage.isolated() => PhantomStorage._();

  Future<void> initialize({
    required String seedPhrase,
    required String storagePath,
    String boxNamespace = '',
  }) async {
    if (_initialized) return;
    Hive.init(storagePath);
    _storagePath = storagePath;
    _boxPrefix   = boxNamespace.isEmpty ? '' : '${boxNamespace}_';
    final aesKey = await _deriveStorageKey(seedPhrase);
    _cipher = HiveAesCipher(aesKey);
    // Derive the key that seals ratchet session state as an opaque blob, so the
    // native ratchet can persist root/chain keys without them ever appearing as
    // plaintext hex in Dart memory. Distinct label from the Hive key.
    NativeCryptoGate.instance.sessionBlobKey =
        await _deriveSessionBlobKey(seedPhrase);
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

  // ── Groups (serverless, pairwise fanout — see core/groups.dart) ────────────

  Future<void> saveGroup(GroupRecord group) async {
    _assertInitialized();
    final box = await _openBox(_boxGroups);
    await box.put(group.gid, group.toJson());
  }

  Future<GroupRecord?> getGroup(String gid) async {
    _assertInitialized();
    final box  = await _openBox(_boxGroups);
    final data = box.get(gid);
    if (data == null) return null;
    return GroupRecord.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<List<GroupRecord>> getGroups() async {
    _assertInitialized();
    final box = await _openBox(_boxGroups);
    return box.values
        .map((v) => GroupRecord.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort((a, b) => b.updatedAtUs.compareTo(a.updatedAtUs));
  }

  Future<void> deleteGroup(String gid) async {
    _assertInitialized();
    final box = await _openBox(_boxGroups);
    await box.delete(gid);
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

  Future<void> consumeOneTimePreKey(int id) {
    return _preKeyLock.guard(() async {
      final store = await getPreKeyStore();
      if (store == null) return;
      await savePreKeyStore(store.withoutOneTimePreKey(id));
    });
  }

  /// Read-modify-write the prekey store under the global lock. The caller
  /// returns the updated store; null means "do nothing". Use this for OPK
  /// pool top-ups so two concurrent calls cannot allocate the same id.
  Future<PreKeyStore?> updatePreKeyStore(
      Future<PreKeyStore?> Function(PreKeyStore current) mutate) {
    return _preKeyLock.guard(() async {
      final current = await getPreKeyStore();
      if (current == null) return null;
      final next = await mutate(current);
      if (next == null) return current;
      await savePreKeyStore(next);
      return next;
    });
  }

  // ── Remote OPK pool (per-contact, piggy-backed via preKeyShare) ──────────────
  // Caches recent X25519 public OPKs advertised by [contactId]. The initiator
  // pops one when starting a fresh session and embeds its id in the INIT_OPK
  // frame; the responder looks the id up in its local OPK private pool.
  // Bounded so a misbehaving contact cannot grow storage indefinitely.

  static const _remoteOpkCacheSize = 5;

  Future<List<({int id, Uint8List pub, int rxAtUs})>> getRemoteOpks(String contactId) async {
    final raw = await getSetting<List<dynamic>>('opks_$contactId');
    if (raw == null) return const [];
    return raw.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return (
        id: m['id'] as int,
        pub: base64.decode(m['pub'] as String),
        rxAtUs: m['rx'] as int,
      );
    }).toList();
  }

  Future<void> _saveRemoteOpks(
      String contactId, List<({int id, Uint8List pub, int rxAtUs})> list) async {
    final encoded = list
        .map((e) => {
              'id':  e.id,
              'pub': base64.encode(e.pub),
              'rx':  e.rxAtUs,
            })
        .toList();
    await setSetting('opks_$contactId', encoded);
  }

  Future<void> addRemoteOpk(String contactId, int id, Uint8List pub) {
    return _opkLock(contactId).guard(() async {
      final list = await getRemoteOpks(contactId);
      list.removeWhere((e) => e.id == id);
      list.add((id: id, pub: pub, rxAtUs: DateTime.now().microsecondsSinceEpoch));
      while (list.length > _remoteOpkCacheSize) {
        list.removeAt(0);
      }
      await _saveRemoteOpks(contactId, list);
    });
  }

  /// Returns and removes the newest cached OPK for [contactId], or null.
  Future<({int id, Uint8List pub})?> popRemoteOpk(String contactId) {
    return _opkLock(contactId).guard(() async {
      final list = await getRemoteOpks(contactId);
      if (list.isEmpty) return null;
      final picked = list.removeLast();
      await _saveRemoteOpks(contactId, list);
      return (id: picked.id, pub: picked.pub);
    });
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

  // ── Yggdrasil preferences ─────────────────────────────────────────────────
  // Settings tied to the optional Yggdrasil VPN transport. Toggled from the
  // network section of the settings screen; the actual restart of the
  // bundled router happens on the next app launch (changing peer lists
  // mid-session would require tearing down the active TUN device).

  Future<bool> getYggEnabled() async =>
      (await getSetting<bool>('ygg_enabled')) ?? false;
  Future<void> setYggEnabled(bool v) => setSetting('ygg_enabled', v);

  /// High-privacy mode: route the key-exchange / control plane over I2P only
  /// (never fanned out), so session setup doesn't reveal our IP. Default off.
  Future<bool> getHighPrivacyMode() async =>
      (await getSetting<bool>('high_privacy_mode')) ?? false;
  Future<void> setHighPrivacyMode(bool v) => setSetting('high_privacy_mode', v);

  /// When true, only the custom peers list is used. When false (default),
  /// the daemon picks from the cached dynamic list fetched at startup.
  Future<bool> getYggUseCustomPeers() async =>
      (await getSetting<bool>('ygg_use_custom_peers')) ?? false;
  Future<void> setYggUseCustomPeers(bool v) =>
      setSetting('ygg_use_custom_peers', v);

  Future<List<String>> getYggCustomPeers() async {
    final raw = await getSetting<List<dynamic>>('ygg_custom_peers');
    if (raw == null) return const [];
    return raw.map((e) => e as String).toList();
  }
  Future<void> setYggCustomPeers(List<String> peers) =>
      setSetting('ygg_custom_peers', peers);

  /// Cached dynamic peer list with the wall-clock time we last fetched.
  /// We refresh from the upstream once every [_yggPeerCacheTtl]; otherwise
  /// reuse the cache so cold starts are still fast when the network is
  /// flaky.
  static const _yggPeerCacheTtl = Duration(hours: 6);

  Future<({List<String> peers, DateTime fetchedAt})?> getYggCachedPeers() async {
    final raw = await getSetting<Map<dynamic, dynamic>>('ygg_cached_peers');
    if (raw == null) return null;
    final tsUs = raw['ts'] as int?;
    final list = (raw['list'] as List?)?.cast<String>();
    if (tsUs == null || list == null) return null;
    return (
      peers: list,
      fetchedAt: DateTime.fromMicrosecondsSinceEpoch(tsUs),
    );
  }
  Future<void> setYggCachedPeers(List<String> peers) =>
      setSetting('ygg_cached_peers', {
        'ts': DateTime.now().microsecondsSinceEpoch,
        'list': peers,
      });

  /// True when the cached list is older than [_yggPeerCacheTtl] or missing.
  Future<bool> isYggPeerCacheStale() async {
    final cached = await getYggCachedPeers();
    if (cached == null) return true;
    return DateTime.now().difference(cached.fetchedAt) > _yggPeerCacheTtl;
  }

  // ── I2P persistent destination keypair ───────────────────────────────────────
  // The SAM bridge returns a base64-encoded full destination (private+public)
  // when SESSION CREATE uses DESTINATION=TRANSIENT. Persisting it here means
  // our public I2P destination remains stable across app restarts, so
  // ContactAddress strings shared with other users never go stale.

  Future<String?> getI2PPrivateDestination() async {
    return getSetting<String>('i2p_priv_dest_v1');
  }

  Future<void> setI2PPrivateDestination(String b64) async {
    await setSetting('i2p_priv_dest_v1', b64);
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

  // ── INIT replay detection ─────────────────────────────────────────────────────
  // Stores the hex of recent X3DH ephemeral keys we have accepted for each
  // contact (bounded LRU, newest last). When an INIT arrives with an EK in
  // the cache it is treated as a replay and the existing session is preserved.
  // Bounded so a malicious sender cannot grow storage indefinitely.

  static const _initEkCacheSize = 16;

  /// Returns the most recent EK hex (or null). Kept for backwards compatibility.
  Future<String?> getLastInitEkHex(String contactId) async {
    final list = await _getInitEkList(contactId);
    return list.isEmpty ? null : list.last;
  }

  /// True if [ekHex] has been observed in the recent INIT cache for [contactId].
  Future<bool> isKnownInitEk(String contactId, String ekHex) async {
    final list = await _getInitEkList(contactId);
    return list.contains(ekHex);
  }

  /// Records an accepted INIT EK in the bounded LRU cache.
  Future<void> setLastInitEkHex(String contactId, String ekHex) async {
    final list = await _getInitEkList(contactId);
    list.remove(ekHex); // dedupe + move to end (most recent)
    list.add(ekHex);
    while (list.length > _initEkCacheSize) {
      list.removeAt(0);
    }
    await setSetting('init_ek_list_$contactId', list);
  }

  Future<List<String>> _getInitEkList(String contactId) async {
    final raw = await getSetting<List<dynamic>>('init_ek_list_$contactId');
    if (raw != null) return raw.map((e) => e as String).toList();
    // Migrate legacy single-value 'init_ek_<id>' setting if present.
    final legacy = await getSetting<String>('init_ek_$contactId');
    if (legacy != null) return [legacy];
    return [];
  }

  Future<String> getWallpaperFit(String? contactId) async {
    final key = contactId == null ? 'wp_fit_global' : 'wp_fit_$contactId';
    return (await getSetting<String>(key)) ?? 'cover';
  }

  Future<void> setWallpaperFit(String? contactId, String fit) {
    final key = contactId == null ? 'wp_fit_global' : 'wp_fit_$contactId';
    return setSetting(key, fit);
  }

  Future<String> getWallpaperAlignment(String? contactId) async {
    final key = contactId == null ? 'wp_align_global' : 'wp_align_$contactId';
    return (await getSetting<String>(key)) ?? '0.0,0.0';
  }

  Future<void> setWallpaperAlignment(String? contactId, String alignment) {
    final key = contactId == null ? 'wp_align_global' : 'wp_align_$contactId';
    return setSetting(key, alignment);
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

  Future<bool>   getGlassNoise()          async => (await getSetting<bool>('glass_noise'))           ?? false;
  Future<double> getGlassNoiseStrength()  async => (await getSetting<double>('glass_noise_strength')) ?? 0.15;

  Future<void> setGlassEnabled(bool v)       => setSetting('glass_enabled', v);
  Future<void> setGlassOpacity(double v)     => setSetting('glass_opacity', v);
  Future<void> setGlassBlur(double v)        => setSetting('glass_blur', v);
  Future<void> setGlassBgBlur(bool v)        => setSetting('glass_bg_blur', v);
  Future<void> setGlassNoise(bool v)         => setSetting('glass_noise', v);
  Future<void> setGlassNoiseStrength(double v) => setSetting('glass_noise_strength', v);

  // ── App-level glass (conversations + settings — independent from chat) ────────

  Future<bool>   getAppGlassEnabled()      async => (await getSetting<bool>('app_glass_enabled'))       ?? false;
  Future<double> getAppGlassOpacity()      async => (await getSetting<double>('app_glass_opacity'))     ?? 0.15;
  Future<double> getAppGlassBlur()         async => (await getSetting<double>('app_glass_blur'))        ?? 10.0;
  Future<bool>   getAppGlassBgBlur()       async => (await getSetting<bool>('app_glass_bg_blur'))       ?? false;
  Future<bool>   getAppGlassUseWallpaper() async => (await getSetting<bool>('app_glass_use_wallpaper')) ?? false;

  Future<bool>   getAppGlassNoise()          async => (await getSetting<bool>('app_glass_noise'))           ?? false;
  Future<double> getAppGlassNoiseStrength()  async => (await getSetting<double>('app_glass_noise_strength')) ?? 0.15;

  Future<void> setAppGlassEnabled(bool v)          => setSetting('app_glass_enabled', v);
  Future<void> setAppGlassOpacity(double v)        => setSetting('app_glass_opacity', v);
  Future<void> setAppGlassBlur(double v)           => setSetting('app_glass_blur', v);
  Future<void> setAppGlassBgBlur(bool v)           => setSetting('app_glass_bg_blur', v);
  Future<void> setAppGlassUseWallpaper(bool v)     => setSetting('app_glass_use_wallpaper', v);
  Future<void> setAppGlassNoise(bool v)            => setSetting('app_glass_noise', v);
  Future<void> setAppGlassNoiseStrength(double v)  => setSetting('app_glass_noise_strength', v);

  // ── Internals ─────────────────────────────────────────────────────────────────

  Future<Box> _openBox(String name) async {
    final fullName = '$_boxPrefix$name';
    if (Hive.isBoxOpen(fullName)) return Hive.box(fullName);
    return Hive.openBox(fullName, encryptionCipher: _cipher, path: _storagePath);
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

  static Future<Uint8List> _deriveSessionBlobKey(String seedPhrase) async {
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
    final out  = await hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(seedPhrase)),
      nonce: Uint8List.fromList(utf8.encode('phantom-storage-v1')),
      info: Uint8List.fromList(utf8.encode('phantom-ratchet-blob-v1')),
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
  /// Private alias — set locally by this user, never transmitted.
  final String? nickname;
  /// Alias received from the contact themselves via an aliasData message.
  final String? sharedAlias;

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

  /// Ed25519 signature over [encryptionPublicKeyBytes] using
  /// [signingPublicKeyBytes]. Present only when the contact was added via a
  /// CA v3 address (or an INIT carrying one).
  final Uint8List? identityKeySignature;

  final int addedAtUs;
  final bool isVerified;
  final bool isArchived;

  /// Cached IPFS peer ID for direct circuit-relay connection.
  /// Populated from the '#<peerId>' suffix in the contact address string.
  /// Stable across restarts (tied to the IPFS repo identity key).
  final String? ipfsPeerId;
  final String? yggdrasilAddress;
  final String? i2pDestination;

  ContactRecord({
    required this.phantomId,
    this.nickname,
    this.sharedAlias,
    required this.encryptionPublicKeyBytes,
    required this.signingPublicKeyBytes,
    required this.signedPreKeyBytes,
    required this.signedPreKeyId,
    required this.signedPreKeySignature,
    this.kyber768PublicKeyBytes,
    this.identityKeySignature,
    int? addedAtUs,
    this.isVerified = false,
    this.isArchived = false,
    this.ipfsPeerId,
    this.yggdrasilAddress,
    this.i2pDestination,
  }) : addedAtUs = addedAtUs ?? DateTime.now().microsecondsSinceEpoch;

  /// Private nickname takes priority, then the alias the contact shared, then the short ID.
  String get displayName => nickname ?? sharedAlias ?? _shortId;
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
        if (identityKeySignature != null)
          'ik_sig': base64.encode(identityKeySignature!),
        if (sharedAlias != null) 'shared_alias': sharedAlias,
        if (ipfsPeerId != null) 'ipfs_peer_id': ipfsPeerId,
        if (yggdrasilAddress != null) 'ygg_addr': yggdrasilAddress,
        if (i2pDestination != null) 'i2p_dest': i2pDestination,
      };

  static ContactRecord fromJson(Map<String, dynamic> j) => ContactRecord(
        phantomId:                j['id']    as String,
        nickname:                 j['nick']   as String?,
        sharedAlias:              j['shared_alias'] as String?,
        encryptionPublicKeyBytes: base64.decode(j['pk']  as String),
        signingPublicKeyBytes:    base64.decode((j['sk']  as String?) ?? base64.encode(Uint8List(32))),
        signedPreKeyBytes:        base64.decode((j['spk'] as String?) ?? base64.encode(Uint8List(32))),
        signedPreKeyId:           (j['spk_id'] as int?) ?? 0,
        signedPreKeySignature:    base64.decode((j['sig'] as String?) ?? base64.encode(Uint8List(64))),
        kyber768PublicKeyBytes:   j['kyber768_pk'] != null
            ? base64.decode(j['kyber768_pk'] as String)
            : null,
        identityKeySignature:     j['ik_sig'] != null
            ? base64.decode(j['ik_sig'] as String)
            : null,
        addedAtUs:                j['added']  as int,
        isVerified:               j['ver']    as bool? ?? false,
        isArchived:               j['arch']   as bool? ?? false,
        ipfsPeerId:               j['ipfs_peer_id'] as String?,
        yggdrasilAddress:         j['ygg_addr'] as String?,
        i2pDestination:           j['i2p_dest'] as String?,
      );

  ContactRecord copyWith({
    String? nickname,
    String? sharedAlias,
    bool? isVerified,
    bool? isArchived,
    String? ipfsPeerId,
    String? yggdrasilAddress,
    String? i2pDestination,
  }) => ContactRecord(
        phantomId:                phantomId,
        nickname:                 nickname    ?? this.nickname,
        sharedAlias:              sharedAlias ?? this.sharedAlias,
        encryptionPublicKeyBytes: encryptionPublicKeyBytes,
        signingPublicKeyBytes:    signingPublicKeyBytes,
        signedPreKeyBytes:        signedPreKeyBytes,
        signedPreKeyId:           signedPreKeyId,
        signedPreKeySignature:    signedPreKeySignature,
        kyber768PublicKeyBytes:   kyber768PublicKeyBytes,
        identityKeySignature:     identityKeySignature,
        addedAtUs:                addedAtUs,
        isVerified:               isVerified  ?? this.isVerified,
        isArchived:               isArchived  ?? this.isArchived,
        ipfsPeerId:               ipfsPeerId  ?? this.ipfsPeerId,
        yggdrasilAddress:         yggdrasilAddress ?? this.yggdrasilAddress,
        i2pDestination:           i2pDestination   ?? this.i2pDestination,
      );
}

// ── PreKeyStore ───────────────────────────────────────────────────────────────

class PreKeyStore {
  final Uint8List signedPreKeyPrivate;
  final Uint8List signedPreKeyPublic;
  final int signedPreKeyId;
  final Map<int, Uint8List> oneTimePreKeyPrivates;

  /// Microseconds-since-epoch the active SPK was generated. Used by the rotation
  /// scheduler in `PhantomCore._maybeRotateSignedPreKey`.
  final int signedPreKeyCreatedAtUs;

  /// Previous SPK kept around for a grace period so INITs encrypted to the old
  /// SPK still decrypt after rotation. All four fields are non-null together.
  final Uint8List? previousSignedPreKeyPrivate;
  final Uint8List? previousSignedPreKeyPublic;
  final int? previousSignedPreKeyId;
  final int? previousSignedPreKeyRetiredAtUs;

  const PreKeyStore({
    required this.signedPreKeyPrivate,
    required this.signedPreKeyPublic,
    required this.signedPreKeyId,
    required this.oneTimePreKeyPrivates,
    int? signedPreKeyCreatedAtUs,
    this.previousSignedPreKeyPrivate,
    this.previousSignedPreKeyPublic,
    this.previousSignedPreKeyId,
    this.previousSignedPreKeyRetiredAtUs,
  }) : signedPreKeyCreatedAtUs = signedPreKeyCreatedAtUs ?? 0;

  PreKeyStore withoutOneTimePreKey(int id) {
    final updated = Map<int, Uint8List>.from(oneTimePreKeyPrivates)..remove(id);
    return PreKeyStore(
      signedPreKeyPrivate:  signedPreKeyPrivate,
      signedPreKeyPublic:   signedPreKeyPublic,
      signedPreKeyId:       signedPreKeyId,
      oneTimePreKeyPrivates: updated,
      signedPreKeyCreatedAtUs:        signedPreKeyCreatedAtUs,
      previousSignedPreKeyPrivate:    previousSignedPreKeyPrivate,
      previousSignedPreKeyPublic:     previousSignedPreKeyPublic,
      previousSignedPreKeyId:         previousSignedPreKeyId,
      previousSignedPreKeyRetiredAtUs: previousSignedPreKeyRetiredAtUs,
    );
  }

  bool get isLowOnOneTimePreKeys => oneTimePreKeyPrivates.length < 5;

  Map<String, dynamic> toJson() => {
        'spk_priv': base64.encode(signedPreKeyPrivate),
        'spk_pub':  base64.encode(signedPreKeyPublic),
        'spk_id':   signedPreKeyId,
        'spk_created_us': signedPreKeyCreatedAtUs,
        if (previousSignedPreKeyPrivate != null)
          'prev_spk_priv': base64.encode(previousSignedPreKeyPrivate!),
        if (previousSignedPreKeyPublic != null)
          'prev_spk_pub': base64.encode(previousSignedPreKeyPublic!),
        if (previousSignedPreKeyId != null)
          'prev_spk_id': previousSignedPreKeyId,
        if (previousSignedPreKeyRetiredAtUs != null)
          'prev_spk_retired_us': previousSignedPreKeyRetiredAtUs,
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
      signedPreKeyCreatedAtUs: (j['spk_created_us'] as int?) ?? 0,
      previousSignedPreKeyPrivate: j['prev_spk_priv'] != null
          ? base64.decode(j['prev_spk_priv'] as String)
          : null,
      previousSignedPreKeyPublic: j['prev_spk_pub'] != null
          ? base64.decode(j['prev_spk_pub'] as String)
          : null,
      previousSignedPreKeyId: j['prev_spk_id'] as int?,
      previousSignedPreKeyRetiredAtUs: j['prev_spk_retired_us'] as int?,
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
        if (senderId != null) 'sender': senderId,
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
        senderId:       j['sender'] as String?,
      );
}

class StorageException implements Exception {
  final String message;
  const StorageException(this.message);
  @override
  String toString() => 'StorageException: $message';
}

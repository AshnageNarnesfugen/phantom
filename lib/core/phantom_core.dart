import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto_lib;
import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'identity/identity.dart';
import 'crypto/double_ratchet.dart';
import 'crypto/hybrid_kem.dart';
import 'crypto/native/phantom_crypto_native.dart';
import 'crypto/safety_number.dart';
import 'crypto/x3dh.dart';
import 'protocol/message.dart';
import 'protocol/frame.dart';
import 'storage/phantom_storage.dart';
import 'storage/backup_manager.dart';
import 'presence_service.dart';
import 'notification_service.dart';
import 'ipfs_daemon.dart';
import 'i2pd_daemon.dart';
import 'waku_daemon.dart';
import 'transport_debugger.dart';
import '../transport/transport.dart';
import '../transport/transport_manager_v2.dart' hide IncomingEnvelope;
import '../transport/bluetooth/bluetooth_mesh_transport.dart';
import '../transport/bluetooth/mesh_router.dart';
import '../transport/bluetooth/message_store.dart';

export 'identity/identity.dart';
export 'crypto/double_ratchet.dart';
export 'crypto/x3dh.dart' hide InvalidPhantomIdException;
export 'protocol/message.dart';
export 'protocol/frame.dart';
export 'storage/phantom_storage.dart';
export 'storage/backup_manager.dart' show BackupManager, BackupException;
export '../transport/transport.dart';
export '../transport/transport_manager_v2.dart' show TransportMode, TransportStatus, TransportSource;

/// Main facade for Phantom core.
///
/// Orchestrates: identity → X3DH → Double Ratchet → protocol → transport → storage.
class PhantomCore {
  final PhantomIdentity identity;
  final PhantomStorage  storage;
  final TransportManager transport;

  final Map<String, RatchetSession> _sessions = {};

  // Tracks contacts to whom we just sent an INIT frame in this session.
  // Used as a tiebreaker when both sides re-init simultaneously (simultaneous
  // clear-history): the side with the larger phantom ID keeps its sender session.


  /// Kyber-768 key pair held in memory for quantum-resistant session setup.
  /// Derived deterministically from the seed phrase — not persisted to disk.
  Uint8List? _kyberPrivateKeyBytes;
  Uint8List? _kyberPublicKeyBytes;

  final _incomingController = StreamController<StoredMessage>.broadcast();
  Stream<StoredMessage> get incomingMessages => _incomingController.stream;

  /// Fires the [phantomId] of a contact whenever any of its stored fields
  /// (nickname, alias, avatar, transport endpoints, ...) changes. Screens
  /// that mirror contact data subscribe so edits land in the UI immediately
  /// instead of waiting for the user to back out and re-enter.
  final _contactChangesController = StreamController<String>.broadcast();
  Stream<String> get contactChanges => _contactChangesController.stream;
  void notifyContactChanged(String contactId) {
    if (!_contactChangesController.isClosed) {
      _contactChangesController.add(contactId);
    }
  }

  StreamSubscription? _transportSub;
  TransportManagerV2? _transportV2;
  StreamSubscription? _transportV2Sub;
  StreamSubscription? _meshStoreSub;
  StreamSubscription? _meshRangeSub;
  bool _transportAvailable = false;
  bool get isTransportAvailable => _transportAvailable;

  PresenceService? _presence;
  String? _ipfsApiUrl;
  bool isContactOnline(String contactId) => _presence?.isOnline(contactId) ?? false;
  Stream<String> get presenceChanges => _presence?.changes ?? const Stream.empty();

  String? _activeChatId;
  void setActiveChat(String? contactId) => _activeChatId = contactId;

  bool _disposed = false;

  // ── INIT rate limit ──────────────────────────────────────────────────────────
  // Sliding-window counter of fresh INITs per sender. Caps the cost of X3DH
  // respond + Kyber decapsulation an attacker can force on us by spamming
  // valid-format INIT frames with random ephemeral keys. Replays (known EK) and
  // hybrid INITs that reuse the same EK don't count — they short-circuit before
  // hitting this guard.
  static const _initRateMax = 8;
  static const _initRateWindow = Duration(seconds: 60);
  final Map<String, List<DateTime>> _initTimestamps = {};

  bool _shouldAcceptInit(String senderId) {
    final now = DateTime.now();
    final windowStart = now.subtract(_initRateWindow);
    final list = _initTimestamps.putIfAbsent(senderId, () => <DateTime>[]);
    list.removeWhere((t) => t.isBefore(windowStart));
    if (list.length >= _initRateMax) return false;
    list.add(now);
    return true;
  }

  // ── OPK consumption rate limit ────────────────────────────────────────────
  // Caps how many one-time pre-keys a single sender (identified by their
  // phantomId, which is derived from IK_pub so it's authenticated by X3DH)
  // can burn through within a rolling window. An attacker who controls one
  // IK could otherwise drain our entire OPK pool by initiating many fresh
  // handshakes — once exhausted, all future X3DH respond falls back to the
  // 3-DH variant which loses the forward-secrecy guarantee of DH4 against a
  // combined IK_priv + SPK_priv compromise. With the cap, an abusive sender
  // can degrade their OWN sessions but not ours with other peers.
  static const _opkConsumeMax    = 20;
  static const _opkConsumeWindow = Duration(hours: 6);
  final Map<String, List<DateTime>> _opkConsumeTimestamps = {};

  bool _shouldConsumeOpk(String senderId) {
    final now = DateTime.now();
    final windowStart = now.subtract(_opkConsumeWindow);
    final list = _opkConsumeTimestamps.putIfAbsent(senderId, () => <DateTime>[]);
    list.removeWhere((t) => t.isBefore(windowStart));
    if (list.length >= _opkConsumeMax) return false;
    list.add(now);
    return true;
  }

  // Tracks the wall-clock time we last sent an INIT to each contact. The
  // simultaneous re-init tiebreaker uses this to keep our established session
  // when a peer's INIT races against our own ack — the original guard only
  // checked pendingX3dhEphemeralKey, which gets cleared by the first DH ratchet
  // (i.e. the moment the ack lands), creating a window where a stale incoming
  // INIT would replace a freshly-established session and desync both sides.
  static const _initRecentWindow = Duration(seconds: 60);
  final Map<String, DateTime> _lastInitSentAt = {};

  // ── Auto-revive on ratchet desync ─────────────────────────────────────────
  // When an incoming MSG frame can't be decrypted by any session, the ratchet
  // has drifted. We auto-reset the session and re-handshake, but limit this
  // to once every 2 minutes per contact to avoid infinite loops.
  final Map<String, DateTime> _autoReviveCooldowns = {};

  // Tracks the last successful MSG decrypt per contact. When a fresh handshake
  // completes (e.g. after auto-revive) the peer may still emit stale frames
  // encrypted with the previous session; those will fail to decrypt here but
  // they are NOT desync — just stragglers from before the new ratchet locked
  // in. Triggering another auto-revive on them produces churn. If we see a
  // successful decrypt within [_recentDecryptWindow], we drop subsequent
  // failures silently for the same contact.
  static const _recentDecryptWindow = Duration(seconds: 30);
  final Map<String, DateTime> _lastSuccessfulDecryptAt = {};

  // Counts consecutive auto-revives per contact that haven't produced a good
  // decrypt yet. Each repeated revive doubles the next cooldown, capped at
  // [_autoReviveCooldownMax]. The previous fixed 2-minute cooldown let an
  // attacker who could inject corrupt MSG frames keep us in an endless
  // re-handshake loop by sending one bad frame every 2:01 — burning CPU,
  // network, and ratchet state. With exponential backoff a sustained attack
  // is throttled to once every 32 minutes after a handful of failures.
  static const _autoReviveCooldownBase = Duration(minutes: 2);
  static const _autoReviveCooldownMax  = Duration(minutes: 32);
  final Map<String, int> _autoReviveStreak = {};

  // ── Per-sender INIT processing lock ────────────────────────────────────────
  // Prevents concurrent X3DH respond for the same sender when multiple INIT
  // frames arrive simultaneously (e.g. text + connectivity info in the same
  // burst). Without this, both INITs pass the isKnownEk check before either
  // stores the EK, creating two incompatible sessions.
  final Map<String, Future<void>> _initProcessingLocks = {};

  // ── Per-recipient session-creation lock ───────────────────────────────────
  // Outgoing counterpart to [_initProcessingLocks]. When the user types a
  // message and we fire connectivityInfo + preKeyShare advertisements right
  // after, multiple _sendPhantomMessage calls race through _getOrCreateSession
  // before any of them has stored a session in [_sessions]. Each call then
  // runs X3DH initiate with a different ephemeral key, producing several
  // sessions with mismatched EKs — the peer receives the first INIT, builds
  // a receiver session for EK_A, but a later INIT with EK_B overwrites it,
  // leaving the two sides on incompatible ratchets.
  final Map<String, Future<void>> _sessionCreationLocks = {};

  // ── Handshake auto-retry ──────────────────────────────────────────────────
  // After sending an INIT we sit waiting for the peer's handshakeAck. If
  // tunnels haven't converged or the peer is briefly offline, the ack never
  // arrives and the user has to manually tap "reset session" to retry.
  // Auto-retry schedules a fresh INIT with exponential backoff until the
  // session's pendingX3dhEphemeralKey flips to null (which only happens
  // when the DH ratchet fires — i.e. the ack landed and we decrypted it).
  static const _handshakeRetryBase = Duration(seconds: 60);
  static const _handshakeRetryCap  = Duration(minutes: 8);
  final Map<String, Timer> _handshakeRetryTimers = {};
  final Map<String, int>   _handshakeRetryAttempts = {};
  /// Emits a contactId whenever its handshake-ack state changes (start
  /// awaiting, ack received, retry attempted). The chat screen listens to
  /// re-render the "waiting for first response" banner.
  final _handshakeStateController = StreamController<String>.broadcast();
  Stream<String> get handshakeStateChanges => _handshakeStateController.stream;

  /// True when we have sent an INIT to [contactId] and have not yet
  /// received the handshakeAck (i.e. the Double Ratchet's pendingX3dhEk
  /// hasn't been cleared by a successful inbound MSG decrypt).
  bool isAwaitingHandshakeAck(String contactId) {
    final session = _sessions[contactId];
    return session != null && session.pendingX3dhEphemeralKey != null;
  }

  /// Current retry attempt count for [contactId]. 0 means no retry pending.
  int handshakeRetryAttempt(String contactId) =>
      _handshakeRetryAttempts[contactId] ?? 0;

  void _scheduleHandshakeRetry(String contactId) {
    _handshakeRetryTimers[contactId]?.cancel();
    final attempt = (_handshakeRetryAttempts[contactId] ?? 0) + 1;
    _handshakeRetryAttempts[contactId] = attempt;
    final shift = (attempt - 1).clamp(0, 6);
    final delaySecs =
        (_handshakeRetryBase.inSeconds * (1 << shift)).clamp(
            _handshakeRetryBase.inSeconds, _handshakeRetryCap.inSeconds);
    _handshakeRetryTimers[contactId] = Timer(Duration(seconds: delaySecs), () {
      unawaited(_runHandshakeRetry(contactId));
    });
    if (!_handshakeStateController.isClosed) {
      _handshakeStateController.add(contactId);
    }
  }

  Future<void> _runHandshakeRetry(String contactId) async {
    if (_disposed) return;
    if (!isAwaitingHandshakeAck(contactId)) {
      _cancelHandshakeRetry(contactId);
      return;
    }
    final dbg = TransportDebugger.instance;
    dbg.log('HANDSHAKE: auto-retry #${_handshakeRetryAttempts[contactId]} for ${contactId.substring(0, 8)}');
    try {
      // Crucially do NOT call resendHandshake here — that would resetSession
      // and produce a brand-new X3DH ephemeral key. When the transport queue
      // is backed up (gossipsub mesh slow to form), each auto-retry was
      // generating a new EK while older INITs with the OLD EK sat queued.
      // When the mesh finally formed, several different EKs flushed to the
      // peer; the last one wins and the previous sessions become unsendable.
      //
      // Instead we re-send a no-op message through the existing session. As
      // long as the DH ratchet hasn't run (no ack received), the session
      // still has pendingX3dhEphemeralKey set, so _sendPhantomMessage will
      // wrap it as another INIT carrying the SAME EK — just nudging the
      // transport to publish without disturbing the X3DH state on either
      // side. The receiver's known-EK path (see _handleInitFrame) will
      // recognise it as a replay/follow-up of the original handshake.
      await _sendPhantomMessage(
        recipientId: contactId,
        message: PhantomMessage(
          type: MessageType.handshakeAck,
          content: utf8.encode('auto-retry'),
        ),
      );
    } catch (e) {
      dbg.log('HANDSHAKE: auto-retry send failed: $e');
    }
    if (!_disposed && isAwaitingHandshakeAck(contactId)) {
      _scheduleHandshakeRetry(contactId);
    } else {
      _cancelHandshakeRetry(contactId);
    }
  }

  void _cancelHandshakeRetry(String contactId) {
    _handshakeRetryTimers.remove(contactId)?.cancel();
    _handshakeRetryAttempts.remove(contactId);
    if (!_handshakeStateController.isClosed) {
      _handshakeStateController.add(contactId);
    }
  }

  TransportStatus? get transportStatus => _transportV2?.status;
  Stream<TransportMode> get transportModeChanges =>
      _transportV2?.modeChanges ?? const Stream.empty();

  String get myId => identity.phantomId;

  PhantomCore._({
    required this.identity,
    required this.storage,
    required this.transport,
  });

  // ── Factory constructors ───────────────────────────────────────────────────

  /// [storage], [transports], [enablePresence] and [enableBleMesh] exist for
  /// the local lab / e2e tests: an isolated storage plus a loopback transport
  /// let several identities run in one process with no daemons, no platform
  /// channels and no network. The app itself never passes them.
  static Future<({PhantomCore core, String seedPhrase})> createAccount({
    required String storagePath,
    TransportConfig? transportConfig,
    PhantomStorage? storage,
    List<PhantomTransport>? transports,
    bool enablePresence = true,
    bool enableBleMesh = true,
  }) async {
    final result = await PhantomIdentity.generateNew();
    final store  = storage ?? PhantomStorage.instance;

    await store.initialize(
      seedPhrase: result.seedPhrase,
      storagePath: storagePath,
      boxNamespace: storage == null
          ? ''
          // Derived from the path (unique per lab identity, stable across
          // restores) — identityHashCode collided between tests: Hive's
          // global registry then served a PREVIOUS test's open box, whose
          // old cipher turned every read into garbage.
          : 'lab${storagePath.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}',
    );

    final transport = _buildTransport(transportConfig, store, transports);
    final core = PhantomCore._(
      identity: result.identity,
      storage:  store,
      transport: transport,
    );
    core._ipfsApiUrl  = IpfsDaemon.apiUrl;
    if (enableBleMesh) {
      core._transportV2 = _buildTransportV2(transport, core.myId);
    }

    // Derive Kyber-768 keypair deterministically from the seed phrase.
    await core._initKyberKeys(result.seedPhrase);
    await core._initializePreKeys();
    await core._maybeRotateSignedPreKey();
    await core._startTransport();
    if (enablePresence) await core._startPresence();

    return (core: core, seedPhrase: result.seedPhrase);
  }

  static Future<PhantomCore> restoreAccount({
    required String seedPhrase,
    required String storagePath,
    TransportConfig? transportConfig,
    PhantomStorage? storage,
    List<PhantomTransport>? transports,
    bool enablePresence = true,
    bool enableBleMesh = true,
  }) async {
    final identity = await PhantomIdentity.fromSeedPhrase(seedPhrase);
    final store    = storage ?? PhantomStorage.instance;

    await store.initialize(
      seedPhrase: seedPhrase,
      storagePath: storagePath,
      boxNamespace: storage == null
          ? ''
          // Derived from the path (unique per lab identity, stable across
          // restores) — identityHashCode collided between tests: Hive's
          // global registry then served a PREVIOUS test's open box, whose
          // old cipher turned every read into garbage.
          : 'lab${storagePath.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}',
    );

    final transport = _buildTransport(transportConfig, store, transports);
    final core = PhantomCore._(
      identity: identity,
      storage:  store,
      transport: transport,
    );
    core._ipfsApiUrl  = IpfsDaemon.apiUrl;
    if (enableBleMesh) {
      core._transportV2 = _buildTransportV2(transport, core.myId);
    }

    await core._initKyberKeys(seedPhrase);
    await core._syncTransportMetadata();

    final savedYgg = await store.getSetting<String>('yggdrasil_address');
    if (savedYgg != null) {
      core.setMyYggdrasilAddress(savedYgg);
    }

    // Re-initialize prekeys if they don't exist yet (e.g. first restore on new device)
    final existing = await store.getPreKeyStore();
    if (existing == null) {
      await core._initializePreKeys();
    }
    await core._maybeRotateSignedPreKey();

    // Load all known sessions into memory BEFORE the transport starts so that
    // any queued or in-flight MSG frames are decryptable immediately.
    await core._preloadSessions();

    await core._startTransport();
    if (enablePresence) await core._startPresence();
    return core;
  }

  Future<void> _syncTransportMetadata() async {
    final contacts = await storage.getAllContacts();
    for (final c in contacts) {
      if (c.yggdrasilAddress != null) transport.setContactYggAddress(c.phantomId, c.yggdrasilAddress!);
      if (c.i2pDestination != null) transport.setContactI2PDestination(c.phantomId, c.i2pDestination!);
      if (c.ipfsPeerId != null) transport.setContactIpfsPeerId(c.phantomId, c.ipfsPeerId!);
    }
  }

  static TransportManager _buildTransport(TransportConfig? config,
      PhantomStorage store, List<PhantomTransport>? transportsOverride) {
    // Use the dynamic IPFS API URL discovered by IpfsDaemon.ensure() (which
    // reads the actual port from the repo/api file after the daemon binds to
    // tcp/0). Fall back to the config value or 5001 only if the daemon hasn't
    // resolved a port yet.
    final ipfsUrl = IpfsDaemon.apiUrl != 'http://127.0.0.1:5001'
        ? IpfsDaemon.apiUrl
        : (config?.ipfsApiUrl ?? 'http://127.0.0.1:5001');

    return TransportManager(
      ipfsApiUrl:       ipfsUrl,
      i2pSamHost:       config?.i2pSamHost,
      i2pSamPort:       config?.i2pSamPort,
      yggdrasilAddress: config?.yggdrasilAddress,
      i2pLoadKey:       () => store.getI2PPrivateDestination(),
      i2pPersistKey:    (b64) => store.setI2PPrivateDestination(b64),
      wakuLoadLastStoreUs: () =>
          store.getSetting<int>('waku_last_store_query_us'),
      wakuSaveLastStoreUs: (us) =>
          store.setSetting('waku_last_store_query_us', us),
      transportsOverride: transportsOverride,
    );
  }

  /// Builds a [TransportManagerV2] that wraps [v1]'s publish for internet
  /// and adds a BLE mesh layer with store-and-forward.
  static TransportManagerV2 _buildTransportV2(
      TransportManager v1, String myPhantomId) {
    final store  = MessageStore();
    final router = MeshRouter(myPhantomId: myPhantomId, store: store);
    final btMesh = BluetoothMeshTransport(
      myPhantomId: myPhantomId,
      router: router,
      store: store,
    );
    return TransportManagerV2(
      btMesh: btMesh,
      store:  store,
      internetPublish: ({
        required String recipientId,
        required Uint8List encryptedEnvelope,
        bool isHandshake = false,
        TransportPriority priority = TransportPriority.data,
      }) =>
          v1.publish(
            recipientId:       recipientId,
            encryptedEnvelope: encryptedEnvelope,
            isHandshake:       isHandshake,
            priority:          priority,
          ),
    );
  }

  // ── Contact address ────────────────────────────────────────────────────────

  /// Returns the omnichannel ContactAddress string to share with others.
  ///
  /// Format: `<base64url_ca>[#<ipfs_id>][@<ygg_addr>][$<i2p_dest>]`
  Future<String?> getMyContactAddress() async {
    final bundleJson = await storage.getOwnBundle();
    if (bundleJson == null) return null;
    final bundle = PreKeyBundle.fromJson(bundleJson);
    final ca = ContactAddress(
      x25519IdentityKey:      bundle.identityKeyBytes,
      ed25519SigningKey:       bundle.signingKeyBytes,
      signedPreKeyBytes:       bundle.signedPreKeyBytes,
      signedPreKeyId:          bundle.signedPreKeyId,
      signature:               bundle.signedPreKeySignature,
      kyber768PublicKeyBytes:  bundle.kyber768PublicKeyBytes,
      identityKeySignature:    bundle.identityKeySignature,
    );
    String res = ca.encode();

    // Endpoint suffix: format is `ID#IPFS@YGG$I2P|<ed25519_sig_base64>`.
    // Each endpoint slot is optional; the signature covers everything between
    // the encoded CA and the `|` separator so a MITM cannot swap the IPFS
    // peer ID / I2P dest / Yggdrasil address mid-flight (which would let
    // them silently relay all transport traffic through their own boxes
    // until the first encrypted connectivityInfo arrives, by which point
    // the handshake has already been observed).
    final suffixBuf = StringBuffer();
    final ipfsId = await getMyIpfsPeerId();
    if (ipfsId != null) suffixBuf.write('#$ipfsId');
    final ygg = transport.transports.whereType<YggdrasilTransport>().firstOrNull;
    if (ygg != null && ygg.address != null && ygg.address!.isNotEmpty) {
      suffixBuf.write('@${ygg.address}');
    }
    final i2p = transport.transports.whereType<I2PTransport>().firstOrNull;
    if (i2p != null && i2p.myDestination != null) {
      suffixBuf.write('\$${i2p.myDestination}');
    }
    final suffix = suffixBuf.toString();
    if (suffix.isEmpty) return res;

    // Sign `<ca_encoded><suffix>` with the SK (Ed25519). Receivers verify
    // against the SK that's already bound to the CA's IK via identityKeySignature.
    final sig = await Ed25519().sign(
      utf8.encode('$res$suffix'),
      keyPair: identity.signingKeyPair,
    );
    final sigB64 = base64Url.encode(sig.bytes).replaceAll('=', '');
    return '$res$suffix|$sigB64';
  }

  /// Manually override the Yggdrasil address if auto-detection fails.
  Future<void> setMyYggdrasilAddress(String ip) async {
    await storage.setSetting('yggdrasil_address', ip);
    final ygg = transport.transports.whereType<YggdrasilTransport>().firstOrNull;
    if (ygg != null) {
      ygg.setManualAddress(ip);
    }
  }

  String? _cachedIpfsPeerId;
  DateTime? _cachedIpfsPeerIdAt;
  static const _ipfsPeerIdCacheTtl = Duration(minutes: 5);

  /// Returns our IPFS peer ID if the daemon is reachable.
  /// Cached for [_ipfsPeerIdCacheTtl] so a daemon restart (which produces a new
  /// session-scoped peer ID) is detected within a few minutes.
  Future<String?> getMyIpfsPeerId() async {
    final now = DateTime.now();
    if (_cachedIpfsPeerId != null &&
        _cachedIpfsPeerIdAt != null &&
        now.difference(_cachedIpfsPeerIdAt!) < _ipfsPeerIdCacheTtl) {
      return _cachedIpfsPeerId;
    }
    if (_ipfsApiUrl == null) return null;
    try {
      final resp = await http
          .post(Uri.parse('$_ipfsApiUrl/api/v0/id'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        _cachedIpfsPeerId = jsonDecode(resp.body)['ID'] as String?;
        _cachedIpfsPeerIdAt = now;
        return _cachedIpfsPeerId;
      }
    } catch (_) {}
    return null;
  }

  // ── Backup ────────────────────────────────────────────────────────────────

  /// Export all account data to an encrypted `.phantombak` file.
  /// [seedPhrase] is required to derive the backup encryption key.
  /// Returns the file path on disk.
  Future<String> exportBackup(String seedPhrase) => BackupManager.exportBackup(
        storage:    storage,
        seedPhrase: seedPhrase,
        phantomId:  myId,
      );

  // ── Messaging ──────────────────────────────────────────────────────────────

  Future<StoredMessage> sendMessage({
    required String recipientId,
    required String text,
    String? replyToId,
  }) async {
    return _sendPhantomMessage(
      recipientId: recipientId,
      message: PhantomMessage.text(text, replyToId: replyToId),
    );
  }

  /// Media up to this size travels INLINE through the normal encrypted
  /// message path instead of as an IPFS CID pointer. Inline media rides the
  /// Waku fleet store like text does — loss-free async delivery with the
  /// sender free to go offline immediately. The CID path requires the
  /// SENDER's IPFS node to stay reachable until every recipient fetches,
  /// which the duty-cycled background mode reduced to a narrow window
  /// (field bug: receiver stuck on "[image]" forever because the sender's
  /// daemon slept before the DHT fetch began). 64 KiB + 1 KiB padding +
  /// frame overhead stays comfortably under the fleet's ~150 KiB relay
  /// message cap.
  static const int inlineMediaMax = 64 * 1024;

  Future<StoredMessage> sendFile({
    required String recipientId,
    required Uint8List bytes,
    required String fileName,
  }) async {
    // The wire format reserves a single byte for the name length, so the
    // name must fit in 255 UTF-8 bytes. Trim from the front to preserve the
    // extension (the receiver uses it to pick image/audio rendering).
    var safeName = fileName;
    while (utf8.encode(safeName).length > 255 && safeName.isNotEmpty) {
      safeName = safeName.substring(1);
    }

    final lower = safeName.toLowerCase();
    final isImage = lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
        lower.endsWith('.png') || lower.endsWith('.gif') || lower.endsWith('.webp');

    final type = isImage ? MessageType.image : MessageType.file;

    // ── Inline path: small media needs no IPFS at all ─────────────────────
    // The content sent IS the display form (raw bytes for images,
    // name\0bytes for files/audio), which the receiver renders directly:
    // tryParseFileWireContent returns null for it, so no resolution step,
    // no dependency on anyone's IPFS daemon, store-and-forward included.
    if (bytes.length <= inlineMediaMax) {
      return _sendPhantomMessage(
        recipientId: recipientId,
        message: PhantomMessage(
          type: type,
          content:
              isImage ? bytes : encodeFileDisplayContent(safeName, bytes),
        ),
      );
    }

    // ── CID path: large media via IPFS ────────────────────────────────────
    // 1. IPFS On-Demand: Ensure the daemon is running only when needed
    await IpfsDaemon.instance.ensure();

    // 2. Upload file to IPFS and pin it locally
    final cid = await IpfsDaemon.instance.uploadFile(bytes, safeName);

    // 3. Wire format for files: [name_len(1)][fileName][size(4 BE)][CID].
    // The size lets the receiver show "Download · N MB" before fetching.
    final nameBytes = utf8.encode(safeName);
    final cidBytes = utf8.encode(cid);
    final sz = bytes.length;
    final content = Uint8List(1 + nameBytes.length + 4 + cidBytes.length)
      ..[0] = nameBytes.length
      ..setAll(1, nameBytes)
      ..[1 + nameBytes.length] = (sz >> 24) & 0xff
      ..[2 + nameBytes.length] = (sz >> 16) & 0xff
      ..[3 + nameBytes.length] = (sz >> 8) & 0xff
      ..[4 + nameBytes.length] = sz & 0xff
      ..setAll(5 + nameBytes.length, cidBytes);

    // 4. Send CID via Waku (WakuTransport will handle this in _sendPhantomMessage)
    final stored = await _sendPhantomMessage(
      recipientId: recipientId,
      message: PhantomMessage(type: type, content: content),
    );

    // 5. The wire payload (name+CID) is what got persisted by
    //    _sendPhantomMessage, but the UI renders messages straight from
    //    storage — images expect raw bytes and files expect `name\0bytes`.
    //    We already hold the original bytes, so persist the displayable
    //    form locally instead of forcing our own chat to download the CID.
    final display = stored.copyWith(
      content: isImage ? bytes : encodeFileDisplayContent(safeName, bytes),
    );
    await storage.saveMessage(display);

    // NOTE: no idle shutdown here. The IPFS daemon also carries presence
    // heartbeats and the pubsub fallback channel; killing it 5 minutes after
    // a file send silently disabled both for the rest of the session (and a
    // later restart binds a NEW dynamic API port that the already-constructed
    // transports would never learn about).

    return display;
  }

  /// Local display format for file/audio messages: `name\0bytes`.
  /// This is the layout `ChatBubble._buildContent` parses.
  static Uint8List encodeFileDisplayContent(String name, Uint8List bytes) {
    final nameBytes = utf8.encode(name);
    final out = Uint8List(nameBytes.length + 1 + bytes.length);
    out.setAll(0, nameBytes);
    out[nameBytes.length] = 0;
    out.setAll(nameBytes.length + 1, bytes);
    return out;
  }

  /// On-wire CID pointer for large media:
  /// `[name_len(1)][fileName][size(4, big-endian)][CID]`. The size lets the
  /// receiver show "Download · 2.3 MB" WITHOUT fetching anything — the whole
  /// point of manual/metered download control. Returns null when the bytes
  /// don't match (already-resolved media is raw image bytes or `name\0bytes`,
  /// neither of which passes the strict CID check).
  static ({String name, int size, String cid})? tryParseFileWireContent(
      Uint8List content) {
    if (content.length < 2) return null;
    final nameLen = content[0];
    // 1 (len) + name + 4 (size) + at least a few CID bytes.
    if (nameLen == 0 || content.length < 1 + nameLen + 4 + 4) return null;
    String name;
    int size;
    String cid;
    try {
      name = utf8.decode(content.sublist(1, 1 + nameLen));
      final sizeOff = 1 + nameLen;
      size = (content[sizeOff] << 24) |
          (content[sizeOff + 1] << 16) |
          (content[sizeOff + 2] << 8) |
          content[sizeOff + 3];
      cid = ascii.decode(content.sublist(sizeOff + 4));
    } catch (_) {
      return null;
    }
    final cidOk = RegExp(r'^(Qm[1-9A-HJ-NP-Za-km-z]{44}|baf[a-zA-Z0-9]{20,})$')
        .hasMatch(cid);
    return cidOk ? (name: name, size: size, cid: cid) : null;
  }

  // Media messages travel as a tiny CID pointer; the actual bytes live on
  // IPFS. Resolution downloads the CID and rewrites the stored message into
  // the displayable form. Keyed set prevents duplicate concurrent downloads.
  final Set<String> _mediaResolutionInFlight = {};

  /// Re-attempts resolution of any unresolved media in [conversationId] —
  /// but only when the auto-download policy allows it on the current network
  /// (Always / WiFi-only / Manual, see [_shouldAutoDownloadMedia]). In manual
  /// mode or on metered data this is a no-op; the UI shows a download button
  /// and the user pulls each file explicitly via [downloadMedia].
  Future<void> resolvePendingMedia(String conversationId) async {
    if (!await _shouldAutoDownloadMedia()) return;
    final msgs = await storage.getMessages(conversationId, limit: 100);
    for (final m in msgs) {
      if (m.type != MessageType.image && m.type != MessageType.file) continue;
      final parsed = tryParseFileWireContent(m.content);
      if (parsed == null) continue;
      unawaited(_resolveMediaMessage(m, parsed));
    }
  }

  /// Explicit, user-initiated download of one media message — bypasses the
  /// auto-download policy (the user tapped the button). Returns true on
  /// success. No-op (true) if already resolved.
  Future<bool> downloadMedia(String conversationId, String messageId) async {
    final msgs = await storage.getMessages(conversationId, limit: 500);
    final m = msgs.where((x) => x.id == messageId).firstOrNull;
    if (m == null) return false;
    final parsed = tryParseFileWireContent(m.content);
    if (parsed == null) return true; // already resolved
    return _resolveMediaMessage(m, parsed);
  }

  /// Auto-download policy: 'always' | 'wifi' | 'never' (default), gated by
  /// the live connection type for 'wifi'. Default is manual so no large
  /// file downloads without an explicit tap — nothing saturates data or
  /// storage silently. Unknown network → conservative (don't auto-download).
  Future<bool> _shouldAutoDownloadMedia() async {
    final mode = await storage.getSetting<String>('media_autodownload') ?? 'never';
    if (mode == 'always') return true;
    if (mode == 'never') return false;
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((r) =>
          r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _resolveMediaMessage(
      StoredMessage m, ({String name, int size, String cid}) file) async {
    final key = '${m.conversationId}:${m.id}';
    if (!_mediaResolutionInFlight.add(key)) return false;
    final dbg = TransportDebugger.instance;
    try {
      await IpfsDaemon.instance.ensure();
      final bytes = await IpfsDaemon.instance.downloadFile(file.cid);
      final display = m.type == MessageType.image
          ? bytes
          : encodeFileDisplayContent(file.name, bytes);
      await storage.saveMessage(m.copyWith(content: display));
      dbg.log('MEDIA: ✓ resolved ${file.name} (${bytes.length} B) from IPFS');
      // contactChanges (not incomingMessages) so a pending resendHandshake
      // ack-wait isn't falsely completed by a media refresh.
      notifyContactChanged(m.conversationId);
      return true;
    } catch (e) {
      dbg.log('MEDIA: ✗ download failed for ${file.name} (${file.cid}): $e');
      return false;
    } finally {
      _mediaResolutionInFlight.remove(key);
    }
  }

  /// Per-recipient send locks. Encrypting mutates the ratchet session and
  /// persists it — two concurrent sends to the same contact (e.g. a text
  /// racing the automatic connectivityInfo/preKeyShare after a handshake)
  /// would both advance the chain from the same snapshot and emit frames
  /// the receiver can only partially decrypt.
  final Map<String, _SerialLock> _sendLocks = {};

  Future<StoredMessage> _sendPhantomMessage({
    required String recipientId,
    required PhantomMessage message,
  }) {
    final lock = _sendLocks.putIfAbsent(recipientId, () => _SerialLock());
    return lock.guard(() => _sendPhantomMessageInner(
        recipientId: recipientId, message: message));
  }

  /// Ratchet-mutating phase of a send: encrypt, wrap (INIT on first message)
  /// and persist the advanced session. MUST run inside [_sessionLock] — the
  /// caller guards it. Everything network-related stays outside the lock.
  Future<({Uint8List wire, bool isHandshake, RatchetSession session})>
      _encryptAndPersist({
    required String recipientId,
    required PhantomMessage message,
  }) async {
    final session  = await _getOrCreateSession(recipientId);
    final protocol = PhantomProtocol(session);

    // Check if this is a new session (handshake) by seeing if we still need
    // to embed our ephemeral keys.
    final bool isHandshake = session.pendingX3dhEphemeralKey != null;

    // Capture BEFORE encode() calls session.encrypt(), which clears these.
    final x3dhEk      = session.pendingX3dhEphemeralKey;
    final kyberCipher = session.pendingKyberCipherBytes;
    final opkId       = session.pendingOpkId;
    final envelopeBytes = await protocol.encode(message);

    // Wrap in INIT frame on the first message (includes our full ContactAddress
    // so the receiver can persist our bundle and re-initiate sessions later).
    final Uint8List wire;
    if (x3dhEk != null) {
      if (kyberCipher != null && opkId != null) {
        // Embed our current transport endpoints — but seal them with an
        // AES-GCM key derived from the X3DH shared secret so a passive
        // observer of the IPFS pubsub topic can't link the sender's
        // phantomId to their IPFS peer id / I2P dest / Yggdrasil addr.
        // The receiver re-derives the same key in initAsReceiver and
        // decrypts in _handleInitFrameInner before refreshing endpoints.
        final endpoints = <String, String>{
          if ((_myI2pDest() ?? '').isNotEmpty)        'i2p':  _myI2pDest()!,
          if ((await getMyIpfsPeerId() ?? '').isNotEmpty) 'ipfs': (await getMyIpfsPeerId())!,
          if ((_myYggAddr() ?? '').isNotEmpty)        'ygg':  _myYggAddr()!,
        };
        final sealed = session.endpointKey != null
            ? await _sealEndpoints(session.endpointKey!, endpoints)
            : Uint8List(0);
        wire = WireFrame.wrapHybridInitFullSealed(
          senderIdentityKeyBytes:    identity.encryptionPublicKeyBytes,
          senderEphemeralKeyBytes:   x3dhEk,
          kyberCipherBytes:          kyberCipher,
          senderContactAddressBytes: await _getMyContactAddressBytes(),
          opkId:                     opkId,
          sealedEndpoints:           sealed,
          envelopeBytes:             envelopeBytes,
        );
      } else if (kyberCipher != null) {
        wire = WireFrame.wrapHybridInit(
          senderIdentityKeyBytes:    identity.encryptionPublicKeyBytes,
          senderEphemeralKeyBytes:   x3dhEk,
          kyberCipherBytes:          kyberCipher,
          senderContactAddressBytes: await _getMyContactAddressBytes(),
          envelopeBytes:             envelopeBytes,
        );
      } else {
        // Classical INIT (0x49) — wire layout reserves a fixed 165-byte CA
        // slot, so the address MUST be v1 to round-trip cleanly.
        wire = WireFrame.wrapInit(
          senderIdentityKeyBytes:    identity.encryptionPublicKeyBytes,
          senderEphemeralKeyBytes:   x3dhEk,
          senderContactAddressBytes: await _getMyContactAddressBytes(forceV1: true),
          envelopeBytes:             envelopeBytes,
        );
      }
    } else {
      wire = WireFrame.wrapMsg(envelopeBytes: envelopeBytes);
    }

    // Persist updated session state
    await _saveSession(recipientId, session);

    return (wire: wire, isHandshake: isHandshake, session: session);
  }

  Future<StoredMessage> _sendPhantomMessageInner({
    required String recipientId,
    required PhantomMessage message,
  }) async {
    // Queued (unawaited) sends may reach here after dispose(); writing to
    // storage at that point races teardown. No-op instead of throwing — the
    // callers are fire-and-forget system sends.
    if (_disposed) {
      return StoredMessage.fromPhantomMessage(
        msg: message,
        conversationId: recipientId,
        direction: MessageDirection.outgoing,
        status: MessageStatus.failed,
      );
    }

    // Ratchet mutation (encrypt + persist) runs under the SAME lock as
    // inbound processing — see _sessionLock. The network publish below runs
    // OUTSIDE it so a slow transport (Waku store confirmation) can't stall
    // frame decryption or other sends' encrypts. Lock order is always
    // sendLock(recipient) → _sessionLock; inbound takes _sessionLock only,
    // and sends triggered from inbound handlers are unawaited, so they only
    // queue — no deadlock.
    final prep = await _sessionLock.guard(() => _encryptAndPersist(
        recipientId: recipientId, message: message));
    final wire        = prep.wire;
    final isHandshake = prep.isHandshake;
    final session     = prep.session;

    final stored = StoredMessage.fromPhantomMessage(
      msg:            message,
      conversationId: recipientId,
      direction:      MessageDirection.outgoing,
      status:         MessageStatus.sending,
    );
    // System/protocol messages are not part of the chat history.
    const systemTypes = {
      MessageType.avatarData,
      MessageType.aliasData,
      MessageType.readReceipt,
      MessageType.connectivityInfo,
      MessageType.preKeyShare,
      MessageType.handshakeAck,
    };
    if (!systemTypes.contains(message.type)) {
      await storage.saveMessage(stored);
    }

    // Classify the outbound frame so the transport layer can pick the right
    // backend. handshakeAck is special: when we're about to send it, the
    // *peer's* record of our addresses may be stale (they imported our
    // ContactAddress with a previous I2P destination, etc), so the ack
    // hedges by going out on every backend in parallel. Everything else
    // splits cleanly into control (I2P preferred) and data (IPFS only).
    final TransportPriority priority;
    if (message.type == MessageType.handshakeAck) {
      priority = TransportPriority.broadcast;
    } else if (isHandshake ||
        message.type == MessageType.preKeyShare ||
        message.type == MessageType.connectivityInfo) {
      priority = TransportPriority.control;
    } else {
      priority = TransportPriority.data;
    }

    // For handshake INIT frames, retry up to 3 times with exponential backoff.
    final maxAttempts = isHandshake ? 3 : 1;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (_transportV2 != null) {
          final result = await _transportV2!.publish(
            recipientId:        recipientId,
            fullMessageId:      message.id,
            encryptedEnvelope:  wire,
            isHandshake:        isHandshake,
            priority:           priority,
          );
          final status = (result.success || result.queued)
              ? MessageStatus.sent
              : MessageStatus.failed;
          await storage.updateMessageStatus(recipientId, message.id, status);

          if (isHandshake && status == MessageStatus.sent &&
              message.type != MessageType.connectivityInfo &&
              message.type != MessageType.preKeyShare &&
              message.type != MessageType.handshakeAck) {
            final dbg = TransportDebugger.instance;
            dbg.log('DBG: before _sendConnectivityInfo, session.pendingX3dhEk is null? ${session.pendingX3dhEphemeralKey == null}');
            unawaited(_sendConnectivityInfo(recipientId));
            // Arm the auto-retry: if the peer's handshakeAck never arrives
            // (tunnels not converged, peer offline, etc) we resend the INIT
            // on a backoff so the user doesn't have to hit "reset session".
            _scheduleHandshakeRetry(recipientId);
          }

          return stored.copyWith(status: status);
        } else if (_transportAvailable) {
          await transport.publish(
            recipientId: recipientId,
            encryptedEnvelope: wire,
            isHandshake: isHandshake,
            priority:    priority,
          );
          await storage.updateMessageStatus(recipientId, message.id, MessageStatus.sent);

          if (isHandshake &&
              message.type != MessageType.connectivityInfo &&
              message.type != MessageType.preKeyShare &&
              message.type != MessageType.handshakeAck) {
            final dbg = TransportDebugger.instance;
            dbg.log('DBG: before _sendConnectivityInfo, session.pendingX3dhEk is null? ${session.pendingX3dhEphemeralKey == null}');
            unawaited(_sendConnectivityInfo(recipientId));
            _scheduleHandshakeRetry(recipientId);
            dbg.log('DBG: after unawaited, session.pendingX3dhEk is null? ${session.pendingX3dhEphemeralKey == null}');
          }

          return stored.copyWith(status: MessageStatus.sent);
        } else {
          await storage.updateMessageStatus(recipientId, message.id, MessageStatus.failed);
          return stored.copyWith(status: MessageStatus.failed);
        }
      } catch (e) {
        final dbg = TransportDebugger.instance;
        if (isHandshake && attempt < maxAttempts) {
          final delaySecs = 3 * attempt; // 3s, 6s, 9s
          dbg.log('MSG: handshake attempt $attempt/$maxAttempts failed, retrying in ${delaySecs}s…');
          await Future.delayed(Duration(seconds: delaySecs));
          continue;
        }
        dbg.log('MSG: send failed after $attempt attempt(s): $e');
      }
    }

    // All attempts exhausted
    await storage.updateMessageStatus(recipientId, message.id, MessageStatus.failed);
    return stored.copyWith(status: MessageStatus.failed);
  }

  /// Current I2P destination as advertised by our local SAM session, or
  /// null if I2P isn't initialised / session not ready. Used to embed our
  /// live endpoint in HYBRID_INIT_FULL frames.
  String? _myI2pDest() {
    final i2p = transport.transports.whereType<I2PTransport>().firstOrNull;
    return i2p?.myDestination;
  }

  /// Current Yggdrasil IPv6, or null when the VPN service isn't up.
  String? _myYggAddr() {
    final ygg = transport.transports.whereType<YggdrasilTransport>().firstOrNull;
    return ygg?.address;
  }

  /// Builds the raw ContactAddress bytes to embed in an INIT frame.
  ///
  /// [forceV1] is set by the classical-INIT (0x49) branch: that wire format
  /// reserves a fixed 165-byte CA slot, so emitting v2/v3 here would silently
  /// truncate the CA on the wire and the receiver would persist a contact with
  /// no SPK. The hybrid INIT frames (0x48 / 0x47) use length-prefixed CAs and
  /// can carry v3 freely.
  Future<Uint8List> _getMyContactAddressBytes({bool forceV1 = false}) async {
    final bundleJson = await storage.getOwnBundle();
    if (bundleJson == null) return Uint8List(165);
    final bundle = PreKeyBundle.fromJson(bundleJson);

    if (!forceV1 && _kyberPublicKeyBytes != null && bundle.identityKeySignature != null) {
      const len = 1413;
      final buf = ByteData(len);
      buf.setUint8(0, 0x03);
      _setBytesInBuf(buf, 1,    bundle.identityKeyBytes,      32);
      _setBytesInBuf(buf, 33,   bundle.signingKeyBytes,        32);
      _setBytesInBuf(buf, 65,   bundle.signedPreKeyBytes,      32);
      buf.setUint32(97, bundle.signedPreKeyId, Endian.big);
      _setBytesInBuf(buf, 101,  bundle.signedPreKeySignature,  64);
      _setBytesInBuf(buf, 165,  _kyberPublicKeyBytes!,       1184);
      _setBytesInBuf(buf, 1349, bundle.identityKeySignature!,  64);
      return buf.buffer.asUint8List();
    } else if (!forceV1 && _kyberPublicKeyBytes != null) {
      const len = 1349;
      final buf = ByteData(len);
      buf.setUint8(0, 0x02);
      _setBytesInBuf(buf, 1,   bundle.identityKeyBytes,     32);
      _setBytesInBuf(buf, 33,  bundle.signingKeyBytes,       32);
      _setBytesInBuf(buf, 65,  bundle.signedPreKeyBytes,     32);
      buf.setUint32(97, bundle.signedPreKeyId, Endian.big);
      _setBytesInBuf(buf, 101, bundle.signedPreKeySignature, 64);
      _setBytesInBuf(buf, 165, _kyberPublicKeyBytes!,      1184);
      return buf.buffer.asUint8List();
    } else {
      final buf = ByteData(165);
      buf.setUint8(0, 0x01);
      _setBytesInBuf(buf, 1,   bundle.identityKeyBytes,     32);
      _setBytesInBuf(buf, 33,  bundle.signingKeyBytes,       32);
      _setBytesInBuf(buf, 65,  bundle.signedPreKeyBytes,     32);
      buf.setUint32(97, bundle.signedPreKeyId, Endian.big);
      _setBytesInBuf(buf, 101, bundle.signedPreKeySignature, 64);
      return buf.buffer.asUint8List();
    }
  }

  static void _setBytesInBuf(ByteData buf, int offset, Uint8List src, int len) {
    final count = src.length < len ? src.length : len;
    for (int i = 0; i < count; i++) {
      buf.setUint8(offset + i, src[i]);
    }
  }

  // ── Contacts ───────────────────────────────────────────────────────────────

  /// Add a contact from their ContactAddress string.
  ///
  /// Supports omnichannel addresses: `<base64_ca>[#<ipfs_id>][@<ygg_addr>][$<i2p_dest>][|<sig>]`
  /// The trailing `|<ed25519_sig_base64>` covers `<ca><suffix>` and is verified
  /// against the SK embedded in the CA; addresses without a signature are
  /// accepted for backwards-compatibility but their endpoint suffix is
  /// dropped (so a MITM-tampered suffix can't silently relay traffic — we
  /// fall back to learning endpoints from the authenticated connectivityInfo
  /// channel after handshake).
  Future<ContactRecord> addContact({
    required String contactAddress,
    String? nickname,
  }) async {
    String caStr = contactAddress.trim();
    String? finalIpfsPeerId;
    String? yggAddr;
    String? i2pDest;

    // 1. Split off the endpoint-signature first (if present).
    String? endpointSig;
    final sigIdx = caStr.lastIndexOf('|');
    if (sigIdx > 0) {
      endpointSig = caStr.substring(sigIdx + 1).trim();
      caStr = caStr.substring(0, sigIdx);
    }
    final signedBase = caStr; // <ca><suffix> — exactly what was signed

    // 2. Parser for omnichannel address: ID#IPFS@YGG$I2P
    final i2pIdx = caStr.lastIndexOf('\$');
    if (i2pIdx > 0) {
      i2pDest = caStr.substring(i2pIdx + 1).trim();
      caStr = caStr.substring(0, i2pIdx);
    }
    final yggIdx = caStr.lastIndexOf('@');
    if (yggIdx > 0) {
      yggAddr = caStr.substring(yggIdx + 1).trim();
      caStr = caStr.substring(0, yggIdx);
    }
    final ipfsIdx = caStr.lastIndexOf('#');
    if (ipfsIdx > 0) {
      final candidate = caStr.substring(ipfsIdx + 1).trim();
      if (candidate.startsWith('12D3Koo') || candidate.startsWith('Qm')) {
        finalIpfsPeerId = candidate;
        caStr = caStr.substring(0, ipfsIdx);
      }
    }

    final ca = ContactAddress.decode(caStr);
    if (!await ca.verifyIdentityBinding()) {
      throw const PhantomCoreException(
        'Invalid contact address: identity key signature does not match.',
      );
    }

    // 3. Verify the endpoint signature (if any). If the address claims
    // endpoints but the signature is missing or invalid, drop the endpoints
    // — we still accept the contact since the CA itself is authenticated.
    final hadEndpoints = finalIpfsPeerId != null || yggAddr != null || i2pDest != null;
    if (hadEndpoints) {
      bool sigOk = false;
      if (endpointSig != null && endpointSig.isNotEmpty) {
        try {
          final sigBytes = base64Url.decode(
              endpointSig.padRight((endpointSig.length + 3) & ~3, '='));
          sigOk = await NativeCryptoGate.instance.ed25519Verify(
              ca.ed25519SigningKey,
              Uint8List.fromList(utf8.encode(signedBase)),
              sigBytes);
        } catch (_) { sigOk = false; }
      }
      if (!sigOk) {
        TransportDebugger.instance.log(
            'ADD_CONTACT: ✗ endpoint signature missing/invalid — dropping endpoints, '
            'will rely on authenticated connectivityInfo after handshake');
        finalIpfsPeerId = null;
        yggAddr = null;
        i2pDest = null;
      }
    }
    final contact = ContactRecord(
      phantomId:                ca.phantomId,
      nickname:                 nickname,
      encryptionPublicKeyBytes: ca.x25519IdentityKey,
      signingPublicKeyBytes:    ca.ed25519SigningKey,
      signedPreKeyBytes:        ca.signedPreKeyBytes,
      signedPreKeyId:          ca.signedPreKeyId,
      signedPreKeySignature:    ca.signature,
      kyber768PublicKeyBytes:   ca.kyber768PublicKeyBytes,
      identityKeySignature:     ca.identityKeySignature,
      ipfsPeerId:               finalIpfsPeerId,
      yggdrasilAddress:         yggAddr,
      i2pDestination:           i2pDest,
    );
    await storage.saveContact(contact);
    
    // Propagate transport metadata immediately
    if (contact.yggdrasilAddress != null) transport.setContactYggAddress(contact.phantomId, contact.yggdrasilAddress!);
    if (contact.i2pDestination != null)   transport.setContactI2PDestination(contact.phantomId, contact.i2pDestination!);
    if (contact.ipfsPeerId != null)       transport.setContactIpfsPeerId(contact.phantomId, contact.ipfsPeerId!);

    _presence?.addContacts([contact.phantomId]);

    // Share the updated address book with the BLE mesh so it can recognise
    // this contact by their node hint (rendezvous / presence-in-range).
    unawaited(_shareContactsWithMesh());

    // Pre-warm: trigger DHT discovery + cross-subscription in the background
    // so the GossipSub mesh starts forming BEFORE the user sends their first
    // message. This dramatically improves handshake success rate.
    unawaited(_prewarmContactTransport(contact.phantomId));

    return contact;
  }

  /// Manually set or update a contact's IPFS peer ID.
  void setContactIpfsPeerId(String contactId, String ipfsPeerId) {
    _presence?.setContactIpfsPeerId(contactId, ipfsPeerId);
    _notifyTransportIpfsPeerId(contactId, ipfsPeerId);
  }

  /// Forwards a known IPFS peer ID to the IpfsTransport layer so it can
  /// bypass DHT provider records and connect directly via circuit relay.
  void _notifyTransportIpfsPeerId(String contactId, String ipfsPeerId) {
    for (final t in transport.transports) {
      if (t is IpfsTransport) {
        t.setContactIpfsPeerId(contactId, ipfsPeerId);
      }
    }
  }

  /// Delete the existing session with [contactId] and force a fresh X3DH
  /// handshake on the next message. Use this when the remote side never
  /// received our INIT and the session is stuck.
  Future<void> resetSession(String contactId) async {
    _sessions.remove(contactId);
    _cancelHandshakeRetry(contactId);
    await storage.deleteSessionState(contactId);
    TransportDebugger.instance.log('SESSION: reset for ${contactId.substring(0, 8)} — next message will re-handshake');
  }

  /// Reset the session AND immediately send a fresh INIT handshake.
  /// Yields progress strings; the final value is 'success' or 'failed'.
  ///
  /// Success means the remote peer actually received the INIT, processed it,
  /// and sent back an automatic handshakeAck within 30 seconds. A successful
  /// IPFS publish that never reaches the peer reports 'failed'.
  Stream<String> resendHandshake(String contactId) async* {
    final dbg = TransportDebugger.instance;
    final short = contactId.substring(0, 8);

    yield 'resetting session…';
    await resetSession(contactId);

    yield 'sending handshake…';
    try {
      await _sendPhantomMessage(
        recipientId: contactId,
        message: PhantomMessage(
          type: MessageType.handshakeAck,
          content: utf8.encode('session-reset'),
        ),
      );
      dbg.log('SESSION: INIT re-sent to $short — waiting for ack…');
    } catch (e) {
      dbg.log('SESSION: INIT re-send failed: $e');
      yield 'failed';
      return;
    }

    yield 'waiting for ack…';
    final completer = Completer<({bool acked, bool offline})>();
    final sub = incomingMessages
        .where((m) => m.conversationId == contactId)
        .listen((_) {
      if (!completer.isCompleted) {
        completer.complete((acked: true, offline: false));
      }
    });

    // Hard timeout — give the peer the benefit of slow networks.
    Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.complete((acked: false, offline: false));
      }
    });

    // Fail-fast probe — if 10 s after sending the INIT we still see zero
    // peers in the contact's GossipSub mesh, the peer almost certainly
    // isn't subscribed (app closed, daemon down). Skip the full 30 s wait.
    Timer(const Duration(seconds: 10), () async {
      if (completer.isCompleted) return;
      final ipfs = transport.transports.whereType<IpfsTransport>().firstOrNull;
      if (ipfs == null) return;
      final peers = await ipfs.contactMeshPeerCount(contactId);
      if (peers == 0 && !completer.isCompleted) {
        dbg.log('SESSION: ✗ early offline detection — gossipsub mesh empty');
        completer.complete((acked: false, offline: true));
      }
    });

    final result = await completer.future;
    await sub.cancel();

    if (result.acked) {
      dbg.log('SESSION: ✓ ack received from $short — handshake complete');
      yield 'success';
    } else if (result.offline) {
      yield 'offline';
    } else {
      dbg.log('SESSION: ✗ no ack from $short within 30s');
      yield 'failed';
    }
  }

  /// Aggressively revive the connection to [contactId].
  ///
  /// This method performs a deep reconnection sequence:
  ///   1. Disconnect from the peer's IPFS node
  ///   2. Re-subscribe to their topic (fresh GossipSub GRAFT)
  ///   3. Reconnect via DHT + circuit relay
  ///   4. Poll for GossipSub mesh formation (up to 90 seconds)
  ///   5. Once mesh is alive, reset session and send fresh handshake
  ///
  /// Yields status strings so the UI can show a loading animation.
  /// The last yielded value is either 'success' or 'failed'.
  Stream<String> reviveConnection(String contactId) async* {
    final dbg = TransportDebugger.instance;
    final short = contactId.substring(0, 8);
    final ipfsApiUrl = _ipfsApiUrl ?? IpfsDaemon.apiUrl;
    final client = http.Client();

    try {
      dbg.log('REVIVE: starting for $short');
      yield 'Disconnecting from peer…';

      // Step 1: Force disconnect from the peer
      try {
        final knownPeerId = _getContactIpfsPeerId(contactId);
        if (knownPeerId != null) {
          await client.post(Uri.parse(
              '$ipfsApiUrl/api/v0/swarm/disconnect?arg=/p2p/$knownPeerId'))
              .timeout(const Duration(seconds: 5));
          dbg.log('REVIVE: disconnected from $knownPeerId');
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));

      // Step 2: Kill all existing cross-subscriptions and re-subscribe
      yield 'Re-subscribing to topic…';
      for (final t in transport.transports) {
        if (t is IpfsTransport) {
          final topic = 'msg$contactId';
          await t.forceResubscribePublic(topic);
        }
      }
      await Future.delayed(const Duration(seconds: 1));

      // Step 3: Force reconnect via swarm/connect
      yield 'Reconnecting to peer…';
      try {
        final knownPeerId = _getContactIpfsPeerId(contactId);
        if (knownPeerId != null) {
          await client.post(Uri.parse(
              '$ipfsApiUrl/api/v0/swarm/connect?arg=/p2p/$knownPeerId'))
              .timeout(const Duration(seconds: 10));
          dbg.log('REVIVE: reconnected to $knownPeerId');
        }
      } catch (_) {}

      // Step 4: Poll for GossipSub mesh formation — up to 90 seconds
      yield 'Waiting for GossipSub mesh…';
      final topic = 'msg$contactId';
      final encodedTopic = 'u${base64Url.encode(utf8.encode(topic)).replaceAll('=', '')}';
      bool meshFormed = false;

      for (int i = 0; i < 45; i++) {
        await Future.delayed(const Duration(seconds: 2));
        try {
          final r = await client.post(Uri.parse(
              '$ipfsApiUrl/api/v0/pubsub/peers?arg=${Uri.encodeComponent(encodedTopic)}'))
              .timeout(const Duration(seconds: 3));
          if (r.statusCode == 200) {
            final strings = (jsonDecode(r.body)['Strings'] as List?) ?? [];
            if (strings.isNotEmpty) {
              meshFormed = true;
              dbg.log('REVIVE: ✓ gossipsub mesh formed! (${strings.length} peer(s))');
              break;
            }
          }
        } catch (_) {}

        // Every 10 seconds, force re-subscribe + reconnect
        if (i % 5 == 4) {
          yield 'Retrying connection (${i * 2}s)…';
          for (final t in transport.transports) {
            if (t is IpfsTransport) {
              await t.forceResubscribePublic(topic);
            }
          }
          try {
            final knownPeerId = _getContactIpfsPeerId(contactId);
            if (knownPeerId != null) {
              await client.post(Uri.parse(
                  '$ipfsApiUrl/api/v0/swarm/connect?arg=/p2p/$knownPeerId'))
                  .timeout(const Duration(seconds: 10));
            }
          } catch (_) {}
        }
      }

      if (!meshFormed) {
        dbg.log('REVIVE: ✗ failed — gossipsub mesh never formed after 90s');
        yield 'failed';
        return;
      }

      // Step 5: Mesh is alive. Decide whether to also reset the ratchet
      // session. If we decrypted a real message from this contact within
      // the last [_recentDecryptWindow], the session is healthy — resetting
      // it would destroy a working ratchet, force both sides into a fresh
      // X3DH, and burn ~50s of tiebreaker / auto-revive churn before they
      // reconverge. During that window the user can't actually send (any
      // typed message rides the half-built session and tiebreaker-drops on
      // the peer). Skip the reset and just announce the new transport is
      // ready.
      final lastOk = _lastSuccessfulDecryptAt[contactId];
      final sessionHealthy = lastOk != null &&
          DateTime.now().difference(lastOk) < _recentDecryptWindow;
      if (sessionHealthy) {
        dbg.log('REVIVE: ✓ network refreshed; session healthy '
            '(last decrypt ${DateTime.now().difference(lastOk).inSeconds}s ago)'
            ' — skipping handshake reset');
        yield 'success';
        return;
      }

      yield 'Sending handshake…';
      await resetSession(contactId);
      try {
        await _sendPhantomMessage(
          recipientId: contactId,
          message: PhantomMessage(type: MessageType.text, content: utf8.encode('[connection revived]')),
        );
        dbg.log('REVIVE: ✓ handshake sent successfully');
        yield 'success';
      } catch (e) {
        dbg.log('REVIVE: handshake send failed: $e');
        yield 'failed';
      }
    } finally {
      client.close();
    }
  }

  /// Get the known IPFS peer ID for a contact, or null.
  String? _getContactIpfsPeerId(String contactId) {
    for (final t in transport.transports) {
      if (t is IpfsTransport) {
        return t.getContactIpfsPeerId(contactId);
      }
    }
    return null;
  }

  /// Pre-warm the transport layer for a newly added contact:
  /// 1. Cross-subscribe to their message topic (GossipSub mesh formation)
  /// 2. Trigger DHT discovery + swarm connect
  /// 3. Re-advertise ourselves on the DHT so they can find us
  /// All operations are fire-and-forget — failures are silently logged.
  Future<void> _prewarmContactTransport(String contactId) async {
    final dbg = TransportDebugger.instance;
    dbg.log('PREWARM: starting for ${contactId.substring(0, 8)}…');
    try {
      for (final t in transport.transports) {
        if (t is IpfsTransport) {
          // Cross-subscribe to their message topic so GossipSub mesh
          // starts forming before the first message is sent.
          final topic = 'msg$contactId';
          final encodedTopic = 'u${base64Url.encode(utf8.encode(topic)).replaceAll('=', '')}';
          try {
            final uri = Uri.parse('${_ipfsApiUrl ?? IpfsDaemon.apiUrl}/api/v0/pubsub/sub?arg=${Uri.encodeComponent(encodedTopic)}');
            final request = http.Request('POST', uri);
            final response = await http.Client().send(request)
                .timeout(const Duration(seconds: 5));
            if (response.statusCode == 200) {
              // Keep the subscription open in background (auto-closed on dispose)
              response.stream.listen(null, onError: (_) {}, cancelOnError: false);
              dbg.log('PREWARM: cross-subscribed to ${contactId.substring(0, 8)} topic');
            }
          } catch (e) {
            dbg.log('PREWARM: cross-sub error: $e');
          }
        }
      }

      // Trigger DHT re-advertisement so the contact can find us via findprovs
      _presence?.publishOnline();
      dbg.log('PREWARM: done for ${contactId.substring(0, 8)}');
    } catch (e) {
      dbg.log('PREWARM: error: $e');
    }
  }

  Future<List<ContactRecord>> getContacts() => storage.getAllContacts();

  Future<List<StoredMessage>> getMessages(
    String conversationId, {
    int limit = 50,
    String? beforeId,
  }) => storage.getMessages(conversationId, limit: limit, beforeId: beforeId);

  Future<StoredMessage?> getLastMessage(String conversationId) =>
      storage.getLastMessage(conversationId);

  Future<void> clearHistory(String conversationId) async {
    await storage.clearMessages(conversationId);
    _sessions.remove(conversationId);
    await storage.deleteSessionState(conversationId);
  }

  // ── Safety number ──────────────────────────────────────────────────────────

  Future<String> safetyNumber(String theirPhantomId) async {
    final contact = await storage.getContact(theirPhantomId);
    if (contact == null) {
      throw PhantomCoreException('Contact not found: $theirPhantomId');
    }
    return SafetyNumber.compute(
      ourIk:   identity.encryptionPublicKeyBytes,
      theirIk: contact.encryptionPublicKeyBytes,
    );
  }

  // ── Kyber-768 initialisation ───────────────────────────────────────────────

  /// Derive the Kyber-768 keypair from [seedPhrase] and hold it in memory.
  Future<void> _initKyberKeys(String seedPhrase) async {
    final seed = await HybridKEM.deriveKyberSeed(seedPhrase);
    final (pk, sk) = HybridKEM.generateKeys(seed);
    _kyberPublicKeyBytes  = pk;
    _kyberPrivateKeyBytes = sk;
  }

  // ── PreKeys ────────────────────────────────────────────────────────────────

  static const _opkPoolTarget = 10;

  Future<void> _initializePreKeys() async {
    // OPKs are generated as a local pool here. Their public halves are not
    // embedded in the ContactAddress (a long-lived advertisement would defeat
    // their one-time property); instead they are piggy-backed via preKeyShare
    // messages once a session is established (see _sendPreKeyShares).
    final result = await X3DHHandshake.generateBundle(
      identityKP: identity.encryptionKeyPair,
      signingKP:  identity.signingKeyPair,
      numOneTimePreKeys: _opkPoolTarget,
    );
    final opks = <int, Uint8List>{
      for (final kp in result.oneTimePreKeyPairs.asMap().entries)
        kp.key + 1: Uint8List.fromList(kp.value.bytes),
    };

    await storage.savePreKeyStore(PreKeyStore(
      signedPreKeyPrivate:    Uint8List.fromList(result.signedPreKeyPair.bytes),
      signedPreKeyPublic:     result.signedPreKeyPublicBytes,
      signedPreKeyId:         1,
      oneTimePreKeyPrivates:  opks,
      signedPreKeyCreatedAtUs: DateTime.now().microsecondsSinceEpoch,
    ));

    // Persist own bundle, including the Kyber public key and the IK↔SK
    // cross-signature when available.
    final bundleJson = result.bundle.toJson();
    if (_kyberPublicKeyBytes != null) {
      bundleJson['kyber768_pk'] =
          List<int>.from(_kyberPublicKeyBytes!).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
    final ikSig = await _signIdentityKeyWithSigningKey();
    bundleJson['ik_sig'] =
        List<int>.from(ikSig).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await storage.saveOwnBundle(bundleJson);
  }

  /// Ed25519 signature over our X25519 identity public key. Lets remote peers
  /// verify that whoever advertised this bundle controls both keys.
  Future<Uint8List> _signIdentityKeyWithSigningKey() async {
    final sig = await Ed25519().sign(
      identity.encryptionPublicKeyBytes,
      keyPair: identity.signingKeyPair,
    );
    return Uint8List.fromList(sig.bytes);
  }

  // ── OPK pool helpers ─────────────────────────────────────────────────────────

  /// Refills our local OPK pool to [_opkPoolTarget] entries when consumed.
  /// Returns the freshly added entries (id → private bytes) so the caller can
  /// derive their public keys and broadcast preKeyShare messages.
  Future<Map<int, Uint8List>> _topUpOneTimePreKeys() async {
    final added = <int, Uint8List>{};
    await storage.updatePreKeyStore((store) async {
      final missing = _opkPoolTarget - store.oneTimePreKeyPrivates.length;
      if (missing <= 0) return null;

      final nextId = store.oneTimePreKeyPrivates.keys.fold<int>(
          0, (m, id) => id > m ? id : m) + 1;
      final updated = Map<int, Uint8List>.from(store.oneTimePreKeyPrivates);
      final x25519 = X25519();
      for (int i = 0; i < missing; i++) {
        final kp = await x25519.newKeyPair();
        final priv = Uint8List.fromList((await kp.extract()).bytes);
        final id = nextId + i;
        updated[id] = priv;
        added[id]   = priv;
      }

      return PreKeyStore(
        signedPreKeyPrivate:    store.signedPreKeyPrivate,
        signedPreKeyPublic:     store.signedPreKeyPublic,
        signedPreKeyId:         store.signedPreKeyId,
        oneTimePreKeyPrivates:  updated,
        signedPreKeyCreatedAtUs:           store.signedPreKeyCreatedAtUs,
        previousSignedPreKeyPrivate:       store.previousSignedPreKeyPrivate,
        previousSignedPreKeyPublic:        store.previousSignedPreKeyPublic,
        previousSignedPreKeyId:            store.previousSignedPreKeyId,
        previousSignedPreKeyRetiredAtUs:   store.previousSignedPreKeyRetiredAtUs,
      );
    });
    return added;
  }

  /// Derives the X25519 public key for an OPK private byte string.
  Future<Uint8List> _opkPublicOf(Uint8List priv) async {
    final kp = await X25519().newKeyPairFromSeed(priv);
    final pub = await (await kp.extract()).extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// Sends a preKeyShare message advertising one of our OPKs to [contactId].
  /// The receiver pops it from the cache when they next initiate a session.
  Future<void> _sendPreKeyShare(String contactId, int id, Uint8List pub) async {
    final payload = Uint8List(36);
    final view = ByteData.sublistView(payload);
    view.setUint32(0, id, Endian.big);
    payload.setRange(4, 36, pub);
    await _sendPhantomMessage(
      recipientId: contactId,
      message: PhantomMessage(type: MessageType.preKeyShare, content: payload),
    );
  }

  /// Tops up the local OPK pool and pushes the freshly added OPKs to [contactId]
  /// as a sequence of preKeyShare messages.
  Future<void> _replenishAndAdvertiseOpks(String contactId) async {
    final added = await _topUpOneTimePreKeys();
    for (final entry in added.entries) {
      try {
        final pub = await _opkPublicOf(entry.value);
        await _sendPreKeyShare(contactId, entry.key, pub);
      } catch (_) {}
    }
  }

  // ── SPK rotation ──────────────────────────────────────────────────────────────
  // Rotate the Signed PreKey periodically so that compromise of a single SPK
  // private key only exposes a bounded window of new sessions.
  // Signal rotates weekly; we use a 7-day cadence with a 7-day grace period.

  static const _spkRotationInterval = Duration(days: 7);
  static const _spkPreviousGrace = Duration(days: 7);

  /// Rotates the active Signed PreKey if it has aged past [_spkRotationInterval].
  /// The previous SPK is retained for [_spkPreviousGrace] so in-flight INITs
  /// encrypted to the old SPK can still be processed.
  Future<void> _maybeRotateSignedPreKey() async {
    final dbg = TransportDebugger.instance;
    final store = await storage.getPreKeyStore();
    if (store == null) return;

    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final ageUs = nowUs - store.signedPreKeyCreatedAtUs;
    final mustRotate = store.signedPreKeyCreatedAtUs == 0 ||
        ageUs >= _spkRotationInterval.inMicroseconds;

    // If a previous SPK is past its grace period, drop it.
    final prevRetiredUs = store.previousSignedPreKeyRetiredAtUs;
    final graceExpired = prevRetiredUs != null &&
        nowUs - prevRetiredUs >= _spkPreviousGrace.inMicroseconds;

    if (!mustRotate) {
      // Persist any grace-period cleanup even when we don't rotate.
      if (graceExpired) {
        await storage.savePreKeyStore(PreKeyStore(
          signedPreKeyPrivate:    store.signedPreKeyPrivate,
          signedPreKeyPublic:     store.signedPreKeyPublic,
          signedPreKeyId:         store.signedPreKeyId,
          oneTimePreKeyPrivates:  store.oneTimePreKeyPrivates,
          signedPreKeyCreatedAtUs: store.signedPreKeyCreatedAtUs,
        ));
      }
      return;
    }

    final result = await X3DHHandshake.generateBundle(
      identityKP: identity.encryptionKeyPair,
      signingKP:  identity.signingKeyPair,
      numOneTimePreKeys: 0,
    );
    final newId = store.signedPreKeyId + 1;

    await storage.savePreKeyStore(PreKeyStore(
      signedPreKeyPrivate:    Uint8List.fromList(result.signedPreKeyPair.bytes),
      signedPreKeyPublic:     result.signedPreKeyPublicBytes,
      signedPreKeyId:         newId,
      oneTimePreKeyPrivates:  store.oneTimePreKeyPrivates,
      signedPreKeyCreatedAtUs: nowUs,
      // Demote the just-rotated SPK to "previous" with a fresh retire time.
      previousSignedPreKeyPrivate:    store.signedPreKeyPrivate,
      previousSignedPreKeyPublic:     store.signedPreKeyPublic,
      previousSignedPreKeyId:         store.signedPreKeyId,
      previousSignedPreKeyRetiredAtUs: nowUs,
    ));

    // Update own bundle so the latest SPK is what we advertise to new contacts.
    final bundleJson = result.bundle.toJson();
    bundleJson['spk_id'] = newId;
    if (_kyberPublicKeyBytes != null) {
      bundleJson['kyber768_pk'] = List<int>.from(_kyberPublicKeyBytes!)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    }
    final ikSig = await _signIdentityKeyWithSigningKey();
    bundleJson['ik_sig'] =
        List<int>.from(ikSig).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await storage.saveOwnBundle(bundleJson);

    dbg.log('SPK: rotated to id=$newId (previous id=${store.signedPreKeyId} kept for grace)');
  }

  // ── Session management ─────────────────────────────────────────────────────

  /// Loads every contact's persisted RatchetSession into [_sessions] so that
  /// incoming MSG frames can be decrypted immediately on transport connect.
  Future<void> _preloadSessions() async {
    final contacts = await storage.getAllContacts();
    for (final contact in contacts) {
      if (_sessions.containsKey(contact.phantomId)) continue;
      final saved = await storage.getSessionState(contact.phantomId);
      if (saved == null) continue;
      try {
        _sessions[contact.phantomId] = await RatchetSession.fromJson(saved);
      } catch (_) {}
    }
  }

  Future<RatchetSession> _getOrCreateSession(String recipientId) async {
    // Wait for any in-flight creation for this recipient to complete first.
    // Without this serialization, a burst of outbound messages (text +
    // connectivityInfo + preKeyShare advertisements) can race here and each
    // run their own X3DH initiate, producing multiple sessions with different
    // ephemeral keys that desync the peer.
    while (_sessionCreationLocks.containsKey(recipientId)) {
      try { await _sessionCreationLocks[recipientId]; } catch (_) {}
    }

    // Re-check cache after waiting — a prior holder may have just populated it.
    if (_sessions.containsKey(recipientId)) {
      return _sessions[recipientId]!;
    }

    final completer = Completer<void>();
    _sessionCreationLocks[recipientId] = completer.future;
    try {
      return await _getOrCreateSessionInner(recipientId);
    } finally {
      _sessionCreationLocks.remove(recipientId);
      completer.complete();
    }
  }

  Future<RatchetSession> _getOrCreateSessionInner(String recipientId) async {
    // Try to restore from persistent storage
    final savedState = await storage.getSessionState(recipientId);
    if (savedState != null) {
      final session = await RatchetSession.fromJson(savedState);
      if (session.hasSendingChain) {
        _sessions[recipientId] = session;
        return session;
      }
      // Stuck receiver session (sendingChain == null): the contact sent the only
      // INIT and we've never replied yet, or we ended up in a broken simultaneous
      // re-init state.  Delete it and fall through to create a fresh sender session
      // so the ratchet can re-synchronise.
      await storage.deleteSessionState(recipientId);
    }

    // Create a new session via X3DH
    final contact = await storage.getContact(recipientId);
    if (contact == null) {
      throw PhantomCoreException('Contact not found: $recipientId. Add them first.');
    }

    // Pop one OPK from the contact's piggy-backed pool, if any. Adds DH4 to
    // X3DH and gives forward secrecy of the first message even under combined
    // IK_priv + SPK_priv compromise.
    final remoteOpk = await storage.popRemoteOpk(recipientId);

    final bundle = PreKeyBundle(
      identityKeyBytes:      contact.encryptionPublicKeyBytes,
      signingKeyBytes:       contact.signingPublicKeyBytes,
      signedPreKeyBytes:     contact.signedPreKeyBytes,
      signedPreKeyId:        contact.signedPreKeyId,
      signedPreKeySignature: contact.signedPreKeySignature,
      oneTimePreKeys: remoteOpk == null
          ? const []
          : [(id: remoteOpk.id, keyBytes: remoteOpk.pub)],
      kyber768PublicKeyBytes: contact.kyber768PublicKeyBytes,
    );

    final x3dhResult = await X3DHHandshake.initiate(
      ourIdentityKP: identity.encryptionKeyPair,
      theirBundle:   bundle,
    );

    final session = await RatchetSession.initAsSender(
      sharedSecret:          x3dhResult.sessionKey,
      remotePublicKey:       contact.encryptionPublicKeyBytes,
      x3dhEphemeralKeyBytes: x3dhResult.ephemeralPublicKeyBytes,
      kyberCipherBytes:      x3dhResult.kyberCipherBytes,
      opkId:                 x3dhResult.usedOneTimePreKeyId,
    );

    _sessions[recipientId] = session;
    _lastInitSentAt[recipientId] = DateTime.now();
    await _saveSession(recipientId, session);
    return session;
  }

  Future<void> _saveSession(String id, RatchetSession session) async {
    final json = await session.toJson();
    await storage.saveSessionState(id, json);
  }

  // ── Transport listener ─────────────────────────────────────────────────────

  Future<void> _startTransport() async {
    try {
      await transport.initialize(ourId: myId);
      _transportAvailable = true;
    } catch (_) {
      // No transport available — messages will be stored locally as failed.
      _transportAvailable = false;
    }

    _startResyncSentinel();

    // v1 internet transport
    _transportSub = transport.incoming.listen(
      (envelope) => _handleIncomingBytes(
        envelope.data,
        i2pSourceDest: envelope.i2pSourceDestination,
        // Store frames are historical replays by definition — they must
        // never trigger auto-revive (see _handleMsgFrame).
        fromStore: envelope.transportName == 'Waku-Store',
      ),
      onError: (_) {},
    );

    // v2 BLE mesh transport (optional, wired in createAccount/restoreAccount)
    if (_transportV2 != null) {
      try {
        await _transportV2!.initialize(ourId: myId);
        // Restore persisted store-and-forward messages from previous session.
        final storedJson = await storage.getMessageStore();
        if (storedJson != null) {
          _transportV2!.messageStore.loadFromJson(storedJson);
        }
        // Persist the store to Hive whenever its contents change.
        _meshStoreSub = _transportV2!.messageStore.pendingCountStream.listen((_) {
          storage.saveMessageStore(_transportV2!.messageStore.toJson());
        });
      } catch (_) {}
      _transportV2Sub = _transportV2!.incoming.listen(
        (env) => _handleIncomingBytes(env.data),
        onError: (_) {},
      );

      // Rendezvous: share the address book so the mesh can recognise contacts
      // by their node hint, and mark them online when they're detected in
      // Bluetooth range (presence works with zero internet). Contacts added
      // later are re-shared by addContact.
      unawaited(_shareContactsWithMesh());
      _meshRangeSub = _transportV2!.contactInRange.listen((contactId) {
        _presence?.noteMeshInRange(contactId);
      });
    }
  }

  Future<void> _shareContactsWithMesh() async {
    final contacts = await storage.getAllContacts();
    _transportV2?.setKnownContacts(contacts.map((c) => c.phantomId));
  }

  // ── Presence ───────────────────────────────────────────────────────────────

  Future<void> _startPresence() async {
    final contacts = await storage.getAllContacts();
    _presence = PresenceService(myId, ipfsApiUrl: _ipfsApiUrl);
    await _presence!.start(contacts.map((c) => c.phantomId).toList());
    // Propagate stored IPFS peer IDs so both layers can connect directly.
    for (final c in contacts) {
      if (c.ipfsPeerId != null) {
        _presence!.setContactIpfsPeerId(c.phantomId, c.ipfsPeerId!);
        _notifyTransportIpfsPeerId(c.phantomId, c.ipfsPeerId!);
      }
    }
  }

  // ── Contacts / conversation management ────────────────────────────────────

  /// Permanently deletes a single message from local storage.
  Future<void> deleteMessage(String conversationId, String messageId) =>
      storage.deleteMessage(conversationId, messageId);

  /// Archives or unarchives a conversation (contact stays, just hidden).
  Future<void> setConversationArchived(String contactId, {required bool archived}) async {
    final c = await storage.getContact(contactId);
    if (c == null) return;
    await storage.saveContact(c.copyWith(isArchived: archived));
  }

  /// Marks (or unmarks) a contact as verified. Should be called after the
  /// user confirms the safety number matches via an out-of-band channel.
  Future<void> setContactVerified(String contactId, {required bool verified}) async {
    final c = await storage.getContact(contactId);
    if (c == null) return;
    await storage.saveContact(c.copyWith(isVerified: verified));
    _notifyContactUpdated(contactId);
  }

  Future<void> _handleIncomingAlias(String contactId, String alias) async {
    final contact = await storage.getContact(contactId);
    if (contact == null) return;
    await storage.saveContact(contact.copyWith(sharedAlias: alias));
    _notifyContactUpdated(contactId);
  }

  /// Handles a `preKeyShare` message: stores the advertised OPK in the
  /// per-contact remote pool. Subsequent session initiations to this contact
  /// will pop one from the pool to add DH4 to X3DH.
  Future<void> _handleIncomingPreKeyShare(String contactId, Uint8List payload) async {
    if (payload.length != 36) {
      TransportDebugger.instance.log('OPK: ✗ malformed preKeyShare (len=${payload.length})');
      return;
    }
    final id  = ByteData.sublistView(payload).getUint32(0, Endian.big);
    final pub = Uint8List.fromList(payload.sublist(4, 36));
    await storage.addRemoteOpk(contactId, id, pub);
    TransportDebugger.instance.log('OPK: cached id=$id from ${contactId.substring(0, 8)}');
  }

  Future<void> _handleIncomingConnectivity(String contactId, String json) async {
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      final contact = await storage.getContact(contactId);
      if (contact == null) return;

      final updated = contact.copyWith(
        ipfsPeerId:       data['ipfs'] as String?,
        yggdrasilAddress: data['ygg']  as String?,
        i2pDestination:   data['i2p']  as String?,
      );

      await storage.saveContact(updated);
      
      // Update active transport metadata
      if (updated.yggdrasilAddress != null) transport.setContactYggAddress(contactId, updated.yggdrasilAddress!);
      if (updated.i2pDestination != null) transport.setContactI2PDestination(contactId, updated.i2pDestination!);
      if (updated.ipfsPeerId != null) transport.setContactIpfsPeerId(contactId, updated.ipfsPeerId!);
      
      _notifyContactUpdated(contactId);
    } catch (_) {}
  }

  void _notifyContactUpdated(String contactId) {
    notifyContactChanged(contactId);
  }

  /// Pulls the sender's endpoint metadata out of an INIT frame and updates
  /// the contact record so the immediately-following handshakeAck hits
  /// fresh addresses. Handles both:
  ///   - HYBRID_INIT_FULL (0x46): cleartext trailer (legacy)
  ///   - HYBRID_INIT_FULL_SEALED (0x45): AEAD trailer decrypted with the
  ///     X3DH-derived endpoint key on the receiver's freshly-built session.
  /// No-ops silently when the frame format doesn't carry endpoints.
  Future<void> _refreshContactEndpointsFromInit(
      String contactId, ParsedFrame frame) async {
    String? i2p  = frame.senderI2pDest;
    String? ipfs = frame.senderIpfsPeerId;
    String? ygg  = frame.senderYggAddr;

    // SEALED variant: decrypt with the session's endpointKey, which both
    // sides derived identically from the X3DH shared secret. A failed open
    // (forged frame, wrong key) is silently ignored — we still have a valid
    // session at this point, just no endpoint refresh.
    if (frame.sealedEndpoints != null) {
      final session = _sessions[contactId];
      if (session?.endpointKey != null) {
        final opened = await _openSealedEndpoints(
            session!.endpointKey!, frame.sealedEndpoints!);
        if (opened != null) {
          i2p  ??= opened['i2p'];
          ipfs ??= opened['ipfs'];
          ygg  ??= opened['ygg'];
        }
      }
    }

    if ((i2p == null || i2p.isEmpty) &&
        (ipfs == null || ipfs.isEmpty) &&
        (ygg == null || ygg.isEmpty)) {
      return;
    }
    try {
      final contact = await storage.getContact(contactId);
      if (contact == null) return;
      final updated = contact.copyWith(
        i2pDestination:   (i2p  != null && i2p.isNotEmpty)  ? i2p  : null,
        ipfsPeerId:       (ipfs != null && ipfs.isNotEmpty) ? ipfs : null,
        yggdrasilAddress: (ygg  != null && ygg.isNotEmpty)  ? ygg  : null,
      );
      await storage.saveContact(updated);
      if (updated.i2pDestination != null) {
        transport.setContactI2PDestination(contactId, updated.i2pDestination!);
      }
      if (updated.ipfsPeerId != null) {
        transport.setContactIpfsPeerId(contactId, updated.ipfsPeerId!);
      }
      if (updated.yggdrasilAddress != null) {
        transport.setContactYggAddress(contactId, updated.yggdrasilAddress!);
      }
      TransportDebugger.instance.log(
          'INIT: refreshed contact endpoints for ${contactId.substring(0, 8)} '
          '(i2p=${i2p?.isNotEmpty == true} ipfs=${ipfs?.isNotEmpty == true} '
          'ygg=${ygg?.isNotEmpty == true})');
    } catch (_) {}
  }

  /// Clears all messages and the session for a contact, but keeps the contact.
  Future<void> deleteConversation(String contactId) async {
    await storage.clearMessages(contactId);
    _sessions.remove(contactId);
    await storage.deleteSessionState(contactId);
  }

  /// Removes the contact and all associated data (messages, session).
  Future<void> deleteContact(String contactId) async {
    await deleteConversation(contactId);
    await storage.deleteContact(contactId);
  }

  // ── Incoming bytes ─────────────────────────────────────────────────────────

  Future<void> _sendConnectivityInfo(String recipientId) async {
    final ipfsId = await getMyIpfsPeerId();

    // Try to get our Yggdrasil address if active
    String? myYgg;
    final ygg = transport.transports.whereType<YggdrasilTransport>().firstOrNull;
    if (ygg != null) myYgg = ygg.address;

    // Try to get our I2P destination if active
    String? myI2p;
    final i2p = transport.transports.whereType<I2PTransport>().firstOrNull;
    if (i2p != null) myI2p = i2p.myDestination;

    final msg = PhantomMessage.connectivity(
      ipfsPeerId: ipfsId,
      yggAddr:    myYgg,
      i2pDest:    myI2p,
    );

    await _sendPhantomMessage(
      recipientId: recipientId,
      message: msg,
    );

    // Piggy-back the OPK pool: ensures the contact has fresh OPKs to spend on
    // their next session start. Cheap (each share is 36 bytes inside a Double
    // Ratchet message) and keeps the pool topped up across both sides.
    unawaited(_advertiseExistingOpks(recipientId));
  }

  /// Sends preKeyShare messages for every OPK currently in our local pool.
  /// Used right after a handshake so the contact has material to spend on the
  /// next session, even when no OPKs were consumed this round.
  Future<void> _advertiseExistingOpks(String recipientId) async {
    final store = await storage.getPreKeyStore();
    if (store == null) return;
    for (final entry in store.oneTimePreKeyPrivates.entries) {
      try {
        final pub = await _opkPublicOf(entry.value);
        await _sendPreKeyShare(recipientId, entry.key, pub);
      } catch (_) {}
    }
  }

  // ── Frame deduplication ──────────────────────────────────────────────────
  // Multiple transports (I2P + IPFS + Yggdrasil) often deliver the same frame
  // multiple times. Each redundant copy triggers a snapshot/restore cycle on
  // the Double Ratchet session, which corrupts internal state via unmodifiable
  // list references. Dedup by SHA-256 of the full payload with a 60s TTL.
  // The previous fingerprint (first 16 + last 16 + length) was trivially
  // collidable — an attacker who could observe a legitimate frame could craft
  // a different-content frame with the same fingerprint and suppress delivery.
  // SHA-256 over the whole frame removes that surface.
  // TTL covers the Waku store-query overlap window (5 min) plus margin, so a
  // frame that arrives both live and via the cold-start store fetch is still
  // recognised as a duplicate instead of hitting the ratchet twice.
  static const _dedupeMaxSize = 500;
  static const _dedupeTtl = Duration(minutes: 10);
  final Map<String, DateTime> _recentFrameHashes = {};

  bool _isDuplicateFrame(Uint8List data) {
    final hash = crypto_lib.sha256.convert(data).toString();

    final now = DateTime.now();

    // Evict expired entries
    if (_recentFrameHashes.length > _dedupeMaxSize) {
      _recentFrameHashes.removeWhere((_, t) => now.difference(t) > _dedupeTtl);
    }

    if (_recentFrameHashes.containsKey(hash)) return true;
    _recentFrameHashes[hash] = now;
    return false;
  }

  /// Serializes EVERY ratchet session read-modify-write: all inbound frame
  /// processing AND the encrypt+persist phase of every send. Both paths
  /// mutate the same live RatchetSession objects; worse, a failed inbound
  /// decrypt restores the session from a pre-attempt snapshot
  /// (_tryDecryptAsMsg), which — interleaved with a concurrent send — wiped
  /// out the send's chain advance, so the NEXT send reused a spent chain
  /// index and the peer could never decrypt again ("no session could
  /// decrypt" cascade → mutual auto-revive resets, seen in the field and
  /// reproduced deterministically by the lab's burst test).
  final _sessionLock = _SerialLock();

  Future<void> _handleIncomingBytes(Uint8List data,
      {String? i2pSourceDest, bool fromStore = false}) {
    // Dedupe outside the lock: duplicates are the common case under
    // multi-transport fan-out and shouldn't queue behind decrypts.
    if (_disposed || _isDuplicateFrame(data)) return Future.value();
    return _sessionLock.guard(() => _handleIncomingBytesInner(data,
        i2pSourceDest: i2pSourceDest, fromStore: fromStore));
  }

  Future<void> _handleIncomingBytesInner(Uint8List data,
      {String? i2pSourceDest, bool fromStore = false}) async {
    if (_disposed) return;
    final dbg = TransportDebugger.instance;

    try {
      final frame = WireFrame.parse(data);
      if (frame.isInit) {
        dbg.log('MSG: ← INIT frame (${data.length} bytes, hybrid=${frame.isHybrid})');
        dbg.log('MSG:   sender = ${frame.senderPhantomId.substring(0, 8)}…');
        // Do NOT learn the I2P dest here: the cleartext senderPhantomId in
        // the INIT header isn't authenticated yet (anyone can craft a frame
        // claiming Alice's IK). Saving the dest before X3DH respond verifies
        // the sender would let an attacker poison Alice's stored I2P dest by
        // sending a bogus INIT from their own dest, redirecting Bob's future
        // replies to a void. Pinning happens inside _handleInitFrameInner
        // only after the X3DH respond + decrypt succeeds.
        await _handleInitFrame(frame,
            i2pSourceDest: i2pSourceDest, fromStore: fromStore);
      } else {
        dbg.log('MSG: ← MSG frame (${data.length} bytes)');
        // MSG frames don't carry sender identity in cleartext, so we can't
        // attribute the I2P source dest until after decrypt. _handleMsgFrame
        // takes the dest and pins it to whichever session successfully
        // decodes the frame.
        await _handleMsgFrame(frame,
            i2pSourceDest: i2pSourceDest, fromStore: fromStore);
      }
    } catch (e) {
      dbg.log('MSG: ✗ frame parse/handle error: $e');
    }
  }

  /// AES-GCM-256 encrypts the JSON of [endpoints] under [key]. Output is
  /// `nonce(12) || ciphertext+tag`. Used to seal the endpoint trailer in
  /// HYBRID_INIT_FULL_SEALED so the IPFS pubsub topic observer can't link
  /// our phantomId to our transport endpoints.
  Future<Uint8List> _sealEndpoints(Uint8List key, Map<String, String> endpoints) async {
    final aead = AesGcm.with256bits();
    final nonce = aead.newNonce();
    final pt    = utf8.encode(jsonEncode(endpoints));
    final box   = await aead.encrypt(
      pt,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    final out = Uint8List(nonce.length + box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, nonce.length, nonce);
    out.setRange(nonce.length, nonce.length + box.cipherText.length, box.cipherText);
    out.setRange(nonce.length + box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Inverse of [_sealEndpoints]. Returns the parsed endpoint map or null
  /// when decryption fails (forged / wrong key / corrupted blob).
  Future<Map<String, String>?> _openSealedEndpoints(
      Uint8List key, Uint8List sealed) async {
    if (sealed.length < 12 + 16) return null; // nonce + MAC minimum
    try {
      final aead   = AesGcm.with256bits();
      final nonce  = sealed.sublist(0, 12);
      final macBytes = sealed.sublist(sealed.length - 16);
      final ct       = sealed.sublist(12, sealed.length - 16);
      final pt = await aead.decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(macBytes)),
        secretKey: SecretKey(key),
      );
      final decoded = jsonDecode(utf8.decode(pt));
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return null;
    }
  }

  /// Saves [i2pDest] as [contactId]'s I2P destination if we don't already
  /// have one (or it changed), and propagates to the transport map so
  /// outbound replies can use I2P from now on. Fixes the asymmetric case
  /// where the peer learned our dest via QR / cleartext INIT_FULL but we
  /// never learned theirs because their connectivityInfo got lost in
  /// gossipsub mesh failures.
  Future<void> _learnI2pDestFromIncoming(String contactId, String i2pDest) async {
    if (i2pDest.isEmpty) return;
    final contact = await storage.getContact(contactId);
    if (contact == null) return;
    if (contact.i2pDestination == i2pDest) return;
    try {
      await storage.saveContact(contact.copyWith(i2pDestination: i2pDest));
      transport.setContactI2PDestination(contactId, i2pDest);
      _notifyContactUpdated(contactId);
      TransportDebugger.instance.log(
          'I2P: learned dest for ${contactId.substring(0, 8)} from incoming frame');
    } catch (_) {}
  }

  /// Handle an INIT frame: run X3DH respond, create receiver session, decrypt.
  Future<void> _handleInitFrame(ParsedFrame frame,
      {String? i2pSourceDest, bool fromStore = false}) async {
    final senderPhantomId = frame.senderPhantomId;

    // Serialize INIT processing per sender to prevent the concurrent-session
    // creation race. Wait for any in-flight INIT processing to complete first.
    while (_initProcessingLocks.containsKey(senderPhantomId)) {
      try { await _initProcessingLocks[senderPhantomId]; } catch (_) {}
    }

    final completer = Completer<void>();
    _initProcessingLocks[senderPhantomId] = completer.future;
    try {
      await _handleInitFrameInner(frame,
          i2pSourceDest: i2pSourceDest, fromStore: fromStore);
    } finally {
      _initProcessingLocks.remove(senderPhantomId);
      completer.complete();
    }
  }

  Future<void> _handleInitFrameInner(ParsedFrame frame,
      {String? i2pSourceDest, bool fromStore = false}) async {
    final dbg = TransportDebugger.instance;
    final senderIkBytes   = frame.senderIdentityKeyBytes!;
    final senderEkBytes   = frame.senderEphemeralKeyBytes!;
    final senderCaBytes   = frame.senderContactAddressBytes;
    final senderPhantomId = frame.senderPhantomId;

    // Replay detection: compare the incoming X3DH ephemeral key against the
    // one we stored when we last processed a valid INIT from this sender.
    // A transport may re-deliver an INIT frame (e.g. IPFS re-subscribe after
    // daemon restart); without this check the replayed INIT would overwrite
    // the current ratchet with a stale one.
    //
    // A re-INIT after clear-history produces a brand-new ephemeral key, so it
    // passes this guard and correctly replaces the old session.
    final incomingEkHex = senderEkBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final isKnownEk = await storage.isKnownInitEk(senderPhantomId, incomingEkHex);

    // Known EK → same handshake we already processed. The peer's session is
    // still embedding the pending X3DH EK on every outbound frame until the
    // first DH ratchet step lands (see _maxInitResends in double_ratchet.dart),
    // so subsequent messages (connectivityInfo, preKeyShare, plain text typed
    // while the ack is in flight) all arrive wrapped as INIT with the original
    // EK. The X3DH respond path would create a brand-new receiver session and
    // wipe out the live ratchet state, so route the inner payload through the
    // existing session via the MSG path instead. If decrypt fails it's a true
    // transport replay of a frame we already consumed — drop silently without
    // arming auto-revive.
    if (isKnownEk) {
      final ok = await _tryDecryptAsMsg(frame, fromStore: fromStore);
      dbg.log(ok
          ? 'MSG: known-EK INIT payload decrypted via existing session'
          : 'MSG: replay (known EK) — dropping duplicate');
      return;
    }

    // No EK on record yet (cold-start after upgrade) but an active session
    // already exists.  We can't tell if this is a replay or a re-INIT; protect
    // the live session rather than overwriting it with a reset receiver state.
    final storedEkHex = await storage.getLastInitEkHex(senderPhantomId);
    final hasMemSession    = _sessions.containsKey(senderPhantomId);
    final hasStoredSession = await storage.getSessionState(senderPhantomId) != null;
    if (storedEkHex == null && (hasMemSession || hasStoredSession)) {
      dbg.log('MSG: no stored EK but session exists (mem=$hasMemSession, '
          'disk=$hasStoredSession) → trying as MSG');
      final success = await _handleMsgFrame(frame, fromStore: fromStore);
      if (success) return;
      dbg.log('MSG: ✗ decryption as MSG failed, falling back to process as fresh INIT');
    }

    if (!_shouldAcceptInit(senderPhantomId)) {
      dbg.log('MSG: ✗ rate-limited fresh INIT from ${senderPhantomId.substring(0, 8)}');
      return;
    }

    // Simultaneous re-init tiebreaker — broader version. Catches the race
    // window where our pendingX3dhEphemeralKey was already cleared by the
    // arrival of the peer's ack, but a stale INIT from the peer (issued before
    // the ack landed) is still about to overwrite our just-established session.
    final lastSent = _lastInitSentAt[senderPhantomId];
    final recentlyInitiated = lastSent != null &&
        DateTime.now().difference(lastSent) < _initRecentWindow;
    final pendingInit =
        _sessions[senderPhantomId]?.pendingX3dhEphemeralKey != null;
    if (myId.compareTo(senderPhantomId) > 0 &&
        (recentlyInitiated || pendingInit)) {
      dbg.log('MSG: tiebreaker — dropping incoming INIT (we win, '
          'recentInit=$recentlyInitiated pending=$pendingInit)');
      return;
    }

    dbg.log('MSG: fresh INIT — running X3DH respond…');

    final preKeyStore = await storage.getPreKeyStore();
    if (preKeyStore == null) {
      dbg.log('MSG: ✗ preKeyStore is null — cannot respond to INIT');
      return;
    }

    // Try the active SPK first; on failure fall through to the previous SPK
    // (still within its grace period) so INITs encrypted to the just-rotated
    // key still establish a session.
    final spkCandidates = <({Uint8List priv, Uint8List pub, int id})>[
      (
        priv: preKeyStore.signedPreKeyPrivate,
        pub:  preKeyStore.signedPreKeyPublic,
        id:   preKeyStore.signedPreKeyId,
      ),
      if (preKeyStore.previousSignedPreKeyPrivate != null &&
          preKeyStore.previousSignedPreKeyPublic != null &&
          preKeyStore.previousSignedPreKeyId != null)
        (
          priv: preKeyStore.previousSignedPreKeyPrivate!,
          pub:  preKeyStore.previousSignedPreKeyPublic!,
          id:   preKeyStore.previousSignedPreKeyId!,
        ),
    ];

    // If the frame asks us to consume one of our OPKs, look up its private
    // bytes now so X3DH respond can include DH4. Missing OPK → silent fallback
    // to no-OPK respond (the sender's SK won't match → caller drops + retries).
    //
    // Rate-limit OPK consumption per sender: an attacker controlling one IK
    // could otherwise drain the entire pool with rapid fresh handshakes,
    // forcing every future session (with anyone) into the 3-DH variant that
    // loses DH4's forward-secrecy property. When over the cap we still try
    // to respond — just without DH4 — so the rate-limited sender degrades
    // their own session security but ours with other peers is preserved.
    SimpleKeyPairData? opkKP;
    if (frame.opkId != null) {
      if (!_shouldConsumeOpk(senderPhantomId)) {
        dbg.log('MSG: ✗ OPK rate-limited for ${senderPhantomId.substring(0, 8)} '
            '— responding without DH4');
      } else {
        final opkPriv = preKeyStore.oneTimePreKeyPrivates[frame.opkId!];
        if (opkPriv != null) {
          try {
            final opkKpFull = await X25519().newKeyPairFromSeed(opkPriv);
            opkKP = await opkKpFull.extract();
          } catch (e) {
            dbg.log('MSG: ✗ OPK ${frame.opkId} key reconstruction failed: $e');
          }
        } else {
          dbg.log('MSG: requested OPK id=${frame.opkId} not in pool — proceeding without DH4');
        }
      }
    }

    RatchetSession? session;
    PhantomMessage? message;
    Object? lastError;
    for (final spk in spkCandidates) {
      final spkPub = SimplePublicKey(spk.pub, type: KeyPairType.x25519);
      final spkKP = SimpleKeyPairData(spk.priv, publicKey: spkPub, type: KeyPairType.x25519);

      Uint8List sharedSecret;
      try {
        sharedSecret = await X3DHHandshake.respond(
          ourIdentityKP:          identity.encryptionKeyPair,
          ourSignedPreKP:         spkKP,
          ourOneTimePreKP:        opkKP,
          theirIdentityKeyBytes:  senderIkBytes,
          theirEphemeralKeyBytes: senderEkBytes,
        );
      } catch (e) {
        lastError = e;
        continue;
      }

      if (frame.isHybrid &&
          frame.kyberCipherBytes != null &&
          _kyberPrivateKeyBytes != null) {
        try {
          final kyberSecret = HybridKEM.decapsulate(
            frame.kyberCipherBytes!,
            _kyberPrivateKeyBytes!,
          );
          sharedSecret = await HybridKEM.combineSecrets(sharedSecret, kyberSecret);
        } catch (e) {
          lastError = e;
          continue;
        }
      }

      final candidate = await RatchetSession.initAsReceiver(
        sharedSecret:    sharedSecret,
        ourEncryptionKP: identity.encryptionKeyPair,
      );

      try {
        final protocol = PhantomProtocol(candidate);
        message = await protocol.decode(frame.payload);
        session = candidate;
        dbg.log('MSG: X3DH respond OK (spk_id=${spk.id})');
        break;
      } catch (e) {
        lastError = e;
        continue;
      }
    }

    if (session == null || message == null) {
      dbg.log('MSG: ✗ X3DH respond/decrypt failed across all SPKs: $lastError');
      // Last resort: maybe a duplicate INIT raced an existing session.
      if (_sessions.containsKey(senderPhantomId) ||
          await storage.getSessionState(senderPhantomId) != null) {
        await _handleMsgFrame(frame, fromStore: fromStore);
      }
      return;
    }

    dbg.log('MSG: ✓ INIT decrypted OK — type=${message.type.name}');
    // A live INIT that just passed X3DH is direct proof the sender is online.
    if (!fromStore) _presence?.noteActivity(senderPhantomId);

    // Build a full ContactRecord from the embedded ContactAddress when possible,
    // so we can re-initiate sessions later without the sender needing to resend.
    // For CA v3 we verify the IK↔SK binding signature first; on failure we
    // skip the auto-save (X3DH already validated the sender owns IK_priv,
    // but we won't trust the embedded SK without proof).
    if (await storage.getContact(senderPhantomId) == null) {
      final caBindingOk = await _verifyInitCaBinding(senderCaBytes);
      if (caBindingOk) {
        await storage.saveContact(
          _buildContactFromInit(senderPhantomId, senderIkBytes, senderCaBytes),
        );
        dbg.log('MSG: auto-saved contact from INIT CA');
      } else {
        dbg.log('MSG: ✗ CA v3 ik_sig failed — not auto-saving contact');
      }
    }

    // Persist the ephemeral key so future replays of this INIT are detected.
    await storage.setLastInitEkHex(senderPhantomId, incomingEkHex);
    _sessions[senderPhantomId] = session;
    await _saveSession(senderPhantomId, session);

    // X3DH respond + decrypt succeeded, so the sender genuinely controls the
    // IK_priv that derives senderPhantomId. Only now is it safe to attribute
    // the I2P source dest to this contact — saving it earlier (in
    // _handleIncomingBytes) would let any unauthenticated attacker poison
    // Alice's saved dest by sending a bogus INIT claiming her phantomId.
    if (i2pSourceDest != null) {
      await _learnI2pDestFromIncoming(senderPhantomId, i2pSourceDest);
    }

    await _dispatchIncoming(message, senderPhantomId);
    dbg.log('MSG: ✓ dispatched to UI');

    // If we burned an OPK on this INIT, retire it locally and push a fresh
    // batch back so the contact has material for the next session.
    if (frame.opkId != null && opkKP != null) {
      await storage.consumeOneTimePreKey(frame.opkId!);
      unawaited(_replenishAndAdvertiseOpks(senderPhantomId));
    }

    // Refresh the contact's transport endpoints from the cleartext header
    // the sender embedded in the HYBRID_INIT_FULL frame. This is the fix
    // for the dead-letter case: when the sender has reinstalled and we
    // hold a stale I2P destination / IPFS peer id from their old install,
    // the ack we're about to send would otherwise go into the void on
    // every channel. Updating BEFORE the ack lets the very first round
    // trip complete cleanly.
    await _refreshContactEndpointsFromInit(senderPhantomId, frame);

    // Auto-acknowledge so the sender's resendHandshake stream knows the INIT
    // landed and a session was actually established. Hedged across every
    // backend in parallel (TransportPriority.broadcast) so even if one
    // endpoint is stale the ack still lands via the others.
    //
    // Piggy-back our own connectivityInfo on the same wake-up so the sender
    // learns our I2P / IPFS / Ygg endpoints in one round trip instead of
    // waiting for the next outbound MSG.
    unawaited(_sendPhantomMessage(
      recipientId: senderPhantomId,
      message: PhantomMessage(type: MessageType.handshakeAck, content: Uint8List(0)),
    ));
    unawaited(_sendConnectivityInfo(senderPhantomId));
  }

  /// Builds a [ContactRecord] from data available in an INIT frame.
  /// Uses the embedded ContactAddress bytes for a full record; falls back to a
  /// minimal record (no SPK) when the CA is absent or malformed.
  ///
  /// Note: this is a sync helper — IK↔SK signature verification on CA v3
  /// happens in [_handleInitFrame] before calling, so we trust the bytes here.
  static ContactRecord _buildContactFromInit(
    String phantomId,
    Uint8List senderIkBytes,
    Uint8List? caBytes,
  ) {
    if (caBytes != null && caBytes.isNotEmpty) {
      try {
        final view    = ByteData.sublistView(Uint8List.fromList(caBytes));
        final version = caBytes[0];

        if (version == 0x01 && caBytes.length == 165) {
          return ContactRecord(
            phantomId:               phantomId,
            encryptionPublicKeyBytes: Uint8List.fromList(caBytes.sublist(1,   33)),
            signingPublicKeyBytes:    Uint8List.fromList(caBytes.sublist(33,  65)),
            signedPreKeyBytes:        Uint8List.fromList(caBytes.sublist(65,  97)),
            signedPreKeyId:           view.getUint32(97, Endian.big),
            signedPreKeySignature:    Uint8List.fromList(caBytes.sublist(101, 165)),
          );
        } else if (version == 0x02 && caBytes.length == 1349) {
          return ContactRecord(
            phantomId:               phantomId,
            encryptionPublicKeyBytes: Uint8List.fromList(caBytes.sublist(1,   33)),
            signingPublicKeyBytes:    Uint8List.fromList(caBytes.sublist(33,  65)),
            signedPreKeyBytes:        Uint8List.fromList(caBytes.sublist(65,  97)),
            signedPreKeyId:           view.getUint32(97, Endian.big),
            signedPreKeySignature:    Uint8List.fromList(caBytes.sublist(101, 165)),
            kyber768PublicKeyBytes:   Uint8List.fromList(caBytes.sublist(165, 1349)),
          );
        } else if (version == 0x03 && caBytes.length == 1413) {
          return ContactRecord(
            phantomId:               phantomId,
            encryptionPublicKeyBytes: Uint8List.fromList(caBytes.sublist(1,   33)),
            signingPublicKeyBytes:    Uint8List.fromList(caBytes.sublist(33,  65)),
            signedPreKeyBytes:        Uint8List.fromList(caBytes.sublist(65,  97)),
            signedPreKeyId:           view.getUint32(97, Endian.big),
            signedPreKeySignature:    Uint8List.fromList(caBytes.sublist(101, 165)),
            kyber768PublicKeyBytes:   Uint8List.fromList(caBytes.sublist(165, 1349)),
            identityKeySignature:     Uint8List.fromList(caBytes.sublist(1349, 1413)),
          );
        }
      } catch (_) {
        // Malformed CA — fall through to minimal record
      }
    }
    // Minimal fallback: enough to receive messages, but can't re-initiate.
    return ContactRecord(
      phantomId:               phantomId,
      encryptionPublicKeyBytes: senderIkBytes,
      signingPublicKeyBytes:    Uint8List(32),
      signedPreKeyBytes:        Uint8List(32),
      signedPreKeyId:           0,
      signedPreKeySignature:    Uint8List(64),
    );
  }

  /// True if the embedded CA v3 in [caBytes] passes IK↔SK signature verification.
  /// Returns true for v1/v2 (no signature to check) so older clients still work.
  static Future<bool> _verifyInitCaBinding(Uint8List? caBytes) async {
    if (caBytes == null || caBytes.isEmpty) return true;
    if (caBytes[0] != 0x03 || caBytes.length != 1413) return true;
    final ikBytes  = Uint8List.fromList(caBytes.sublist(1,    33));
    final skBytes  = Uint8List.fromList(caBytes.sublist(33,   65));
    final ikSigBytes = Uint8List.fromList(caBytes.sublist(1349, 1413));
    return NativeCryptoGate.instance.ed25519Verify(skBytes, ikBytes, ikSigBytes);
  }

  /// Handle a regular MSG frame: try each active session until one decrypts.
  /// Each attempt snapshots the session state before trying and restores it on
  /// failure, preventing ratchet state corruption if header decryption succeeds
  /// on the wrong session before the body MAC fails.
  /// Tries to decrypt [frame] with every loaded session, restoring snapshot
  /// state on failure so a wrong-session attempt can't corrupt the ratchet.
  /// Returns true on the first successful decrypt. Does NOT trigger auto-revive
  /// on failure — caller decides whether to escalate (used by the known-EK
  /// INIT path where a failure is a legit transport replay, not desync).
  Future<bool> _tryDecryptAsMsg(ParsedFrame frame,
      {String? i2pSourceDest, bool fromStore = false}) async {
    final dbg = TransportDebugger.instance;
    for (final entry in List.of(_sessions.entries)) {
      // A wrong-session attempt can partially mutate a Dart-backed ratchet
      // before the body MAC fails, so snapshot it and restore on failure. A
      // native-backed session decrypts atomically (the Rust core commits only
      // on success), so it needs neither — and skipping the snapshot keeps its
      // secret state from being serialized to hex on every probe.
      final nativeBacked = entry.value.isNativeBacked;
      final snapshot = nativeBacked ? null : entry.value.takeSnapshot();
      try {
        final protocol = PhantomProtocol(entry.value);
        final message  = await protocol.decode(frame.payload);

        await _saveSession(entry.key, entry.value);
        await _dispatchIncoming(message, entry.key);
        dbg.log('MSG: ✓ MSG decrypted via session ${entry.key.substring(0, 8)}');
        // Implicit presence: a live frame that decrypts is direct proof the
        // contact is online right now. Store replays are historical and say
        // nothing about the present, so they don't count.
        if (!fromStore) _presence?.noteActivity(entry.key);
        _lastSuccessfulDecryptAt[entry.key] = DateTime.now();
        _autoReviveStreak.remove(entry.key);
        _cancelHandshakeRetry(entry.key);
        if (i2pSourceDest != null) {
          await _learnI2pDestFromIncoming(entry.key, i2pSourceDest);
        }
        return true;
      } catch (e) {
        // Native-backed sessions weren't mutated (atomic decrypt) and have no
        // snapshot to restore; Dart-backed ones roll back to the pre-attempt state.
        if (snapshot != null) {
          _sessions[entry.key] = await RatchetSession.fromJson(snapshot);
        }
        continue;
      }
    }
    return false;
  }

  Future<bool> _handleMsgFrame(ParsedFrame frame,
      {String? i2pSourceDest, bool fromStore = false}) async {
    final dbg = TransportDebugger.instance;
    dbg.log('MSG: trying ${_sessions.length} session(s) for MSG decrypt');
    if (await _tryDecryptAsMsg(frame,
        i2pSourceDest: i2pSourceDest, fromStore: fromStore)) {
      return true;
    }
    dbg.log('MSG: ✗ no session could decrypt this MSG frame');

    // Waku Store frames are historical replays by definition: any frame the
    // ratchet already consumed is legitimately undecryptable (its message
    // keys are gone — that's forward secrecy working). On a cold start with
    // a stale store cursor the ENTIRE previous session can replay, and there
    // is no recent "good decrypt" yet to trip the straggler guard below —
    // observed in the field: boot → 20 replayed frames → auto-revive reset a
    // healthy session within the first second. Store frames therefore never
    // escalate to auto-revive; live transports are the only desync signal.
    if (fromStore) {
      dbg.log('MSG: undecryptable store replay — dropped (no revive)');
      return false;
    }

    // ── Auto-revive: detect ratchet desync and re-handshake ──────────────
    // If we have a session for the sender but decryption fails, the ratchet
    // has drifted (e.g. one side sent messages the other never received).
    // Instead of silently discarding the message, we reset the session and
    // send a fresh X3DH INIT so both sides can re-sync automatically.
    // An undecryptable MSG frame carries no sender identity, so with more
    // than one live session we cannot attribute it — resetting a session
    // picked by map-iteration order used to nuke a HEALTHY ratchet with an
    // unrelated contact whenever any frame failed to decrypt. Only when a
    // single session exists is the attribution unambiguous enough to revive.
    if (_sessions.length > 1) {
      dbg.log('MSG: undecryptable frame with ${_sessions.length} sessions — '
          'cannot attribute sender, skipping auto-revive (use manual '
          'reconnect if a chat is stuck)');
    }
    if (_sessions.length == 1) {
      for (final contactId in _sessions.keys) {
        final now = DateTime.now();

        // Straggler guard: if we successfully decrypted a frame from this
        // contact recently, this failed frame is almost certainly a leftover
        // from a previous session that the peer encrypted before our newer
        // handshake locked in. Reviving here would only undo the freshly
        // established ratchet. Drop it silently — the sender will resend
        // anything important via the new session.
        final lastOk = _lastSuccessfulDecryptAt[contactId];
        if (lastOk != null && now.difference(lastOk) < _recentDecryptWindow) {
          dbg.log('MSG: auto-revive skipped for ${contactId.substring(0, 8)} '
              '— stale-session straggler (${now.difference(lastOk).inSeconds}s '
              'since last good decrypt)');
          continue;
        }

        final lastRevive = _autoReviveCooldowns[contactId];
        final streak = _autoReviveStreak[contactId] ?? 0;
        // Exponential backoff: 2m, 4m, 8m, 16m, 32m (capped).
        final shift = streak.clamp(0, 4);
        final cooldown = Duration(
          seconds: (_autoReviveCooldownBase.inSeconds * (1 << shift))
              .clamp(_autoReviveCooldownBase.inSeconds,
                     _autoReviveCooldownMax.inSeconds),
        );
        if (lastRevive != null && now.difference(lastRevive) < cooldown) {
          final remaining =
              cooldown.inSeconds - now.difference(lastRevive).inSeconds;
          dbg.log('MSG: auto-revive skipped for ${contactId.substring(0, 8)} '
              '(cooldown ${remaining}s, streak=$streak)');
          continue;
        }

        _autoReviveCooldowns[contactId] = now;
        _autoReviveStreak[contactId] = streak + 1;
        dbg.log('MSG: ⚡ auto-revive #${streak + 1} for ${contactId.substring(0, 8)} '
            '— resetting session and re-handshaking');

        // Fire-and-forget: reset + re-handshake in background
        unawaited(() async {
          try {
            await resendHandshake(contactId).drain<void>();
            dbg.log('MSG: auto-revive handshake sent for ${contactId.substring(0, 8)}');
          } catch (e) {
            dbg.log('MSG: auto-revive failed for ${contactId.substring(0, 8)}: $e');
          }
        }());
        break; // Only revive one session per failed frame
      }
    }

    return false;
  }

  // ── Incoming dispatch ──────────────────────────────────────────────────────

  /// Handles a decrypted incoming message: saves system payloads (avatar/alias)
  /// or stores regular messages and fires notifications.
  Future<void> _dispatchIncoming(PhantomMessage message, String senderId) async {
    if (message.type == MessageType.avatarData) {
      await storage.saveContactAvatar(senderId, message.content);
      _notifyContactUpdated(senderId);
      _incomingController.add(StoredMessage.fromPhantomMessage(
        msg: message, conversationId: senderId,
        direction: MessageDirection.incoming, status: MessageStatus.delivered,
      ));
      return;
    }

    if (message.type == MessageType.aliasData) {
      await _handleIncomingAlias(senderId, utf8.decode(message.content));
      _incomingController.add(StoredMessage.fromPhantomMessage(
        msg: message, conversationId: senderId,
        direction: MessageDirection.incoming, status: MessageStatus.delivered,
      ));
      return;
    }

    if (message.type == MessageType.connectivityInfo) {
      await _handleIncomingConnectivity(senderId, utf8.decode(message.content));
      // Connectivity info doesn't need to be visible in the UI
      return;
    }

    if (message.type == MessageType.preKeyShare) {
      await _handleIncomingPreKeyShare(senderId, message.content);
      return;
    }

    if (message.type == MessageType.handshakeAck) {
      // Receipt is implicit — the message arriving on incomingMessages is the
      // confirmation. Don't surface in chat history; just emit so resendHandshake
      // streams unblock.
      _incomingController.add(StoredMessage.fromPhantomMessage(
        msg: message, conversationId: senderId,
        direction: MessageDirection.incoming, status: MessageStatus.delivered,
      ));
      return;
    }

    if (message.type == MessageType.readReceipt) {
      final ids = utf8.decode(message.content)
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList();
      for (final id in ids) {
        await storage.updateMessageStatus(senderId, id, MessageStatus.read);
      }
      // Emit so the sender's chat screen reloads and shows blue double ticks.
      _incomingController.add(StoredMessage.fromPhantomMessage(
        msg: message, conversationId: senderId,
        direction: MessageDirection.incoming, status: MessageStatus.delivered,
      ));
      return;
    }

    final stored = StoredMessage.fromPhantomMessage(
      msg:            message,
      conversationId: senderId,
      direction:      MessageDirection.incoming,
      status:         MessageStatus.delivered,
    );
    await storage.saveMessage(stored);
    _incomingController.add(stored);

    // Media arrives as a CID pointer. Auto-fetch only when the download
    // policy allows it on the current network (Always / WiFi-only / Manual);
    // otherwise the message stays a pointer and the chat renders a download
    // button. Inline media never reaches here as a pointer (its bytes ARE
    // the content), so it always shows immediately.
    if (stored.type == MessageType.image || stored.type == MessageType.file) {
      final parsed = tryParseFileWireContent(stored.content);
      if (parsed != null && await _shouldAutoDownloadMedia()) {
        unawaited(_resolveMediaMessage(stored, parsed));
      }
    }

    if (_activeChatId != senderId) {
      final contact = await storage.getContact(senderId);
      final name    = contact?.displayName ?? senderId.substring(0, 6);
      final preview = message.type == MessageType.text
          ? message.textContent
          : '[file]';
      NotificationService.showMessage(
        contactName: name,
        preview:     preview,
        contactId:   senderId,
      );
    }
  }

  // ── Avatar / Alias ─────────────────────────────────────────────────────────

  Future<Uint8List?> getContactAvatar(String contactId) =>
      storage.getContactAvatar(contactId);

  Future<void> sendAvatarToContact(String contactId) async {
    final path = await storage.getOwnAvatarPath();
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    await _sendPhantomMessage(
      recipientId: contactId,
      message: PhantomMessage(
        type:    MessageType.avatarData,
        content: Uint8List.fromList(bytes),
      ),
    );
  }

  // ── App lifecycle ──────────────────────────────────────────────────────────

  // ── Power save (duty-cycled background) ────────────────────────────────────
  //
  // Backgrounded, the three daemons' wakelocks kept the CPU awake 24/7 — the
  // dominant battery drain. The Waku fleet store already guarantees loss-free
  // delivery (cursor + dedupe + no-revive-on-replay), so the app can truly
  // sleep and drain the store in short windows instead:
  //   pause → grace period (quick app switches don't churn daemons) →
  //   Waku service to duty-cycle mode + IPFS/i2pd fully stopped.
  //   Every ~15 min the service opens a 2-min window with the daemon up; the
  //   sentinel below notices ("daemon reachable + resync overdue") and drains
  //   the store, which decrypts + notifies as usual.
  //   resume → hot mode + daemons back + immediate resync to close any gap.

  static const _powerSaveGrace = Duration(minutes: 3);
  static const _resyncMinGap   = Duration(minutes: 4);

  Timer? _powerSaveGraceTimer;
  Timer? _resyncSentinel;
  bool _powerSaveActive = false;
  bool _appInBackground = false;
  DateTime? _lastWakuResyncAt;

  /// Call when the app goes to background / is closed.
  Future<void> onAppPaused() async {
    _appInBackground = true;
    await _presence?.goOffline();
    _powerSaveGraceTimer?.cancel();
    _powerSaveGraceTimer = Timer(_powerSaveGrace, () {
      if (_appInBackground && !_disposed) unawaited(_enterPowerSave());
    });
  }

  /// Call when the app returns to foreground.
  Future<void> onAppResumed() async {
    _appInBackground = false;
    _powerSaveGraceTimer?.cancel();
    if (_powerSaveActive) await _exitPowerSave();
    await _presence?.publishOnline();
    // Retry any messages that were queued while the transport was offline.
    _transportV2?.flushStore();
    // Close any delivery gap from the sleep period right away.
    unawaited(resyncWaku());
  }

  Future<void> _enterPowerSave() async {
    _powerSaveActive = true;
    TransportDebugger.instance.log('POWER: entering power save '
        '(Waku duty-cycle, IPFS/i2pd stopped)');
    await WakuDaemon.instance.enterBackgroundMode();
    try { await IpfsDaemon.instance.stop(); } catch (_) {}
    try { await I2pdDaemon.instance.stop(); } catch (_) {}
  }

  Future<void> _exitPowerSave() async {
    _powerSaveActive = false;
    TransportDebugger.instance.log('POWER: exiting power save — hot mode');
    await WakuDaemon.instance.enterForegroundMode();
    unawaited(IpfsDaemon.instance.ensure());
    unawaited(I2pdDaemon.instance.ensure());
  }

  /// Re-drains the Waku fleet store since the persisted cursor. Cheap and
  /// idempotent (dedupe + cursor overlap absorb repeats).
  Future<void> resyncWaku() async {
    final waku = transport.transports.whereType<WakuTransport>().firstOrNull;
    if (waku == null) return;
    final ok = await waku.resyncStore();
    if (ok) _lastWakuResyncAt = DateTime.now();
  }

  /// Runs every minute. Outside power save it's a no-op. Inside it, the
  /// timer only actually fires while the CPU is awake — i.e. exactly during
  /// the service's sync windows — where it finds the daemon reachable and
  /// drains the store. No MethodChannel round-trip from the service needed:
  /// the wake window itself is the signal.
  void _startResyncSentinel() {
    _resyncSentinel = Timer.periodic(const Duration(minutes: 1), (_) async {
      if (!_powerSaveActive || _disposed) return;
      final last = _lastWakuResyncAt;
      if (last != null && DateTime.now().difference(last) < _resyncMinGap) {
        return;
      }
      final st = await WakuDaemon.instance.status();
      if (st.running) {
        TransportDebugger.instance.log('POWER: sync window detected — draining store');
        await resyncWaku();
      }
    });
  }

  // ── Read receipts ──────────────────────────────────────────────────────────

  /// Sends read receipts to [contactId] for the given [messageIds].
  Future<void> sendReadReceipts(String contactId, List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    await _sendPhantomMessage(
      recipientId: contactId,
      message: PhantomMessage(
        type:    MessageType.readReceipt,
        content: Uint8List.fromList(utf8.encode(messageIds.join('\n'))),
      ),
    );
  }

  /// Sends the user's own alias to [contactId] so they can see a name for you.
  /// No-op if no alias has been configured via the `my_alias` setting.
  Future<void> sendAliasToContact(String contactId) async {
    final alias = await storage.getSetting<String>('my_alias');
    if (alias == null || alias.trim().isEmpty) return;
    await _sendPhantomMessage(
      recipientId: contactId,
      message: PhantomMessage(
        type:    MessageType.aliasData,
        content: Uint8List.fromList(utf8.encode(alias.trim())),
      ),
    );
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    // Set the flag first so any in-flight _handleIncomingBytes returns before
    // we tear down storage / transports underneath them.
    _disposed = true;
    _powerSaveGraceTimer?.cancel();
    _resyncSentinel?.cancel();
    // Drain barriers: guard() chains are FIFO, so awaiting an empty guarded
    // block guarantees every already-queued handler (inbound decrypts,
    // outbound encrypts) finished — whatever was mid-write completes BEFORE
    // the caller tears down the storage directory underneath it. The lab's
    // temp-dir cleanup used to race a straggler saveSession and blow up
    // with PathNotFoundException attributed to a passing test.
    await _sessionLock.guard(() async {});
    for (final lock in _sendLocks.values.toList()) {
      await lock.guard(() async {});
    }
    for (final t in _handshakeRetryTimers.values) {
      t.cancel();
    }
    _handshakeRetryTimers.clear();
    _handshakeRetryAttempts.clear();
    await _handshakeStateController.close();
    await _transportSub?.cancel();
    await _transportV2Sub?.cancel();
    await _meshStoreSub?.cancel();
    await _meshRangeSub?.cancel();
    await transport.dispose();
    await _transportV2?.dispose();
    _presence?.dispose();
    await storage.close();
    await _incomingController.close();
    await _contactChangesController.close();
  }
}

// ── TransportConfig ────────────────────────────────────────────────────────────

@immutable
class TransportConfig {
  final String? ipfsApiUrl;
  final String? i2pSamHost;
  final int?    i2pSamPort;
  final String? yggdrasilAddress;

  const TransportConfig({
    this.ipfsApiUrl,
    this.i2pSamHost,
    this.i2pSamPort,
    this.yggdrasilAddress,
  });
}

class PhantomCoreException implements Exception {
  final String message;
  const PhantomCoreException(this.message);
  @override
  String toString() => 'PhantomCoreException: $message';
}

/// FIFO async mutex: `guard` runs [fn] after every previously guarded call
/// has finished, propagating its result/error to the caller. Ratchet
/// sessions are read-modify-write state, so both send and receive paths
/// must be serialized (see [_inboundLock] / [_sendLocks]).
class _SerialLock {
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

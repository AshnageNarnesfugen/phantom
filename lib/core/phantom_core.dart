import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import 'identity/identity.dart';
import 'crypto/double_ratchet.dart';
import 'crypto/hybrid_kem.dart';
import 'crypto/x3dh.dart';
import 'protocol/message.dart';
import 'protocol/frame.dart';
import 'storage/phantom_storage.dart';
import 'storage/backup_manager.dart';
import 'presence_service.dart';
import 'notification_service.dart';
import 'ipfs_daemon.dart';
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

  StreamSubscription? _transportSub;
  TransportManagerV2? _transportV2;
  StreamSubscription? _transportV2Sub;
  StreamSubscription? _meshStoreSub;
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

  static Future<({PhantomCore core, String seedPhrase})> createAccount({
    required String storagePath,
    TransportConfig? transportConfig,
  }) async {
    final result = await PhantomIdentity.generateNew();

    await PhantomStorage.instance.initialize(
      seedPhrase: result.seedPhrase,
      storagePath: storagePath,
    );

    final transport = _buildTransport(transportConfig);
    final core = PhantomCore._(
      identity: result.identity,
      storage:  PhantomStorage.instance,
      transport: transport,
    );
    core._ipfsApiUrl  = IpfsDaemon.apiUrl;
    core._transportV2 = _buildTransportV2(transport, core.myId);

    // Derive Kyber-768 keypair deterministically from the seed phrase.
    await core._initKyberKeys(result.seedPhrase);
    await core._initializePreKeys();
    await core._maybeRotateSignedPreKey();
    await core._startTransport();
    await core._startPresence();

    return (core: core, seedPhrase: result.seedPhrase);
  }

  static Future<PhantomCore> restoreAccount({
    required String seedPhrase,
    required String storagePath,
    TransportConfig? transportConfig,
  }) async {
    final identity = await PhantomIdentity.fromSeedPhrase(seedPhrase);

    await PhantomStorage.instance.initialize(
      seedPhrase: seedPhrase,
      storagePath: storagePath,
    );

    final transport = _buildTransport(transportConfig);
    final core = PhantomCore._(
      identity: identity,
      storage:  PhantomStorage.instance,
      transport: transport,
    );
    core._ipfsApiUrl  = IpfsDaemon.apiUrl;
    core._transportV2 = _buildTransportV2(transport, core.myId);

    await core._initKyberKeys(seedPhrase);
    await core._syncTransportMetadata();

    final savedYgg = await PhantomStorage.instance.getSetting<String>('yggdrasil_address');
    if (savedYgg != null) {
      core.setMyYggdrasilAddress(savedYgg);
    }

    // Re-initialize prekeys if they don't exist yet (e.g. first restore on new device)
    final existing = await PhantomStorage.instance.getPreKeyStore();
    if (existing == null) {
      await core._initializePreKeys();
    }
    await core._maybeRotateSignedPreKey();

    // Load all known sessions into memory BEFORE the transport starts so that
    // any queued or in-flight MSG frames are decryptable immediately.
    await core._preloadSessions();

    await core._startTransport();
    await core._startPresence();
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

  static TransportManager _buildTransport(TransportConfig? config) {
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
      i2pLoadKey:       () => PhantomStorage.instance.getI2PPrivateDestination(),
      i2pPersistKey:    (b64) =>
          PhantomStorage.instance.setI2PPrivateDestination(b64),
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

    // 1. Append IPFS Peer ID
    final ipfsId = await getMyIpfsPeerId();
    if (ipfsId != null) res += '#$ipfsId';

    // 2. Append Yggdrasil IPv6
    final ygg = transport.transports.whereType<YggdrasilTransport>().firstOrNull;
    if (ygg != null && ygg.address != null && ygg.address!.isNotEmpty) res += '@${ygg.address}';

    // 3. Append I2P Destination
    final i2p = transport.transports.whereType<I2PTransport>().firstOrNull;
    if (i2p != null && i2p.myDestination != null) res += '\$${i2p.myDestination}';

    return res;
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

  Future<StoredMessage> sendFile({
    required String recipientId,
    required Uint8List bytes,
    required String fileName,
  }) async {
    // 1. IPFS On-Demand: Ensure the daemon is running only when needed
    await IpfsDaemon.instance.ensure();

    // 2. Upload file to IPFS and pin it locally
    final cid = await IpfsDaemon.instance.uploadFile(bytes, fileName);

    // 3. Prepare the Waku message containing only the CID + filename
    final lower = fileName.toLowerCase();
    final isImage = lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
        lower.endsWith('.png') || lower.endsWith('.gif') || lower.endsWith('.webp');

    final type = isImage ? MessageType.image : MessageType.file;
    
    // Wire format for files: [name_len(1)][fileName][CID]
    // (CID is small enough that Waku easily handles it)
    final nameBytes = utf8.encode(fileName);
    final cidBytes = utf8.encode(cid);
    final content = Uint8List(1 + nameBytes.length + cidBytes.length)
      ..[0] = nameBytes.length
      ..setAll(1, nameBytes)
      ..setAll(1 + nameBytes.length, cidBytes);

    // 4. Send CID via Waku (WakuTransport will handle this in _sendPhantomMessage)
    final stored = await _sendPhantomMessage(
      recipientId: recipientId,
      message: PhantomMessage(type: type, content: content),
    );

    // 5. Schedule IPFS shutdown (5 minutes idle)
    IpfsDaemon.instance.scheduleIdleShutdown();

    return stored;
  }

  Future<StoredMessage> _sendPhantomMessage({
    required String recipientId,
    required PhantomMessage message,
  }) async {
    final session  = await _getOrCreateSession(recipientId);
    final protocol = PhantomProtocol(session);
    
    // Check if this is a new session (handshake) by seeing if we still need
    // to embed our ephemeral keys.
    bool isHandshake = session.pendingX3dhEphemeralKey != null;

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
        // Embed our current transport endpoints in cleartext so the receiver
        // can refresh their saved contact record BEFORE they send the
        // handshakeAck — fixes the dead-letter case where the receiver
        // imported our ContactAddress with previous-install endpoints.
        wire = WireFrame.wrapHybridInitFull(
          senderIdentityKeyBytes:    identity.encryptionPublicKeyBytes,
          senderEphemeralKeyBytes:   x3dhEk,
          kyberCipherBytes:          kyberCipher,
          senderContactAddressBytes: await _getMyContactAddressBytes(),
          opkId:                     opkId,
          senderI2pDest:             _myI2pDest() ?? '',
          senderIpfsPeerId:          await getMyIpfsPeerId() ?? '',
          senderYggAddr:             _myYggAddr() ?? '',
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
  /// Supports omnichannel addresses: `<base64_ca>[#<ipfs_id>][@<ygg_addr>][$<i2p_dest>]`
  Future<ContactRecord> addContact({
    required String contactAddress,
    String? nickname,
  }) async {
    String caStr = contactAddress.trim();
    String? finalIpfsPeerId;
    String? yggAddr;
    String? i2pDest;

    // Parser for omnichannel address: ID#IPFS@YGG$I2P
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

      // Step 5: Mesh is alive! Reset session and send handshake
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
    final ids   = [myId, theirPhantomId]..sort();
    final input = utf8.encode('${ids[0]}\x00${ids[1]}');
    final hash  = await Sha256().hash(input);
    final hex   = hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return List.generate(8, (i) => hex.substring(i * 8, i * 8 + 8)).join(' ');
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

    // v1 internet transport
    _transportSub = transport.incoming.listen(
      (envelope) => _handleIncomingBytes(envelope.data),
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
    }
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
    // Notify UI/Streams if necessary
  }

  /// Pulls the sender's cleartext endpoint metadata out of a HYBRID_INIT_FULL
  /// frame and updates the contact record so the immediately-following
  /// handshakeAck (and any subsequent control frames) hit fresh addresses
  /// instead of the stale ones we may have imported originally. No-ops
  /// silently when [frame] is an older format that doesn't carry endpoints.
  Future<void> _refreshContactEndpointsFromInit(
      String contactId, ParsedFrame frame) async {
    final i2p  = frame.senderI2pDest;
    final ipfs = frame.senderIpfsPeerId;
    final ygg  = frame.senderYggAddr;
    // None set → older frame format or sender had no endpoints to share.
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
  // list references. Dedup by payload hash with a 60s TTL.
  static const _dedupeMaxSize = 100;
  static const _dedupeTtl = Duration(seconds: 60);
  final Map<String, DateTime> _recentFrameHashes = {};

  bool _isDuplicateFrame(Uint8List data) {
    // Fast hash: use first 16 + last 16 bytes + length as fingerprint
    final len = data.length;
    final buf = StringBuffer();
    buf.write(len);
    buf.write(':');
    for (int i = 0; i < 16 && i < len; i++) {
      buf.write(data[i].toRadixString(16).padLeft(2, '0'));
    }
    buf.write(':');
    for (int i = (len - 16).clamp(0, len); i < len; i++) {
      buf.write(data[i].toRadixString(16).padLeft(2, '0'));
    }
    final hash = buf.toString();

    final now = DateTime.now();

    // Evict expired entries
    if (_recentFrameHashes.length > _dedupeMaxSize) {
      _recentFrameHashes.removeWhere((_, t) => now.difference(t) > _dedupeTtl);
    }

    if (_recentFrameHashes.containsKey(hash)) return true;
    _recentFrameHashes[hash] = now;
    return false;
  }

  Future<void> _handleIncomingBytes(Uint8List data) async {
    if (_disposed) return;
    final dbg = TransportDebugger.instance;

    // Deduplicate: same frame arriving via multiple transports
    if (_isDuplicateFrame(data)) return;

    try {
      final frame = WireFrame.parse(data);
      if (frame.isInit) {
        dbg.log('MSG: ← INIT frame (${data.length} bytes, hybrid=${frame.isHybrid})');
        dbg.log('MSG:   sender = ${frame.senderPhantomId.substring(0, 8)}…');
        await _handleInitFrame(frame);
      } else {
        dbg.log('MSG: ← MSG frame (${data.length} bytes)');
        await _handleMsgFrame(frame);
      }
    } catch (e) {
      dbg.log('MSG: ✗ frame parse/handle error: $e');
    }
  }

  /// Handle an INIT frame: run X3DH respond, create receiver session, decrypt.
  Future<void> _handleInitFrame(ParsedFrame frame) async {
    final senderPhantomId = frame.senderPhantomId;

    // Serialize INIT processing per sender to prevent the concurrent-session
    // creation race. Wait for any in-flight INIT processing to complete first.
    while (_initProcessingLocks.containsKey(senderPhantomId)) {
      try { await _initProcessingLocks[senderPhantomId]; } catch (_) {}
    }

    final completer = Completer<void>();
    _initProcessingLocks[senderPhantomId] = completer.future;
    try {
      await _handleInitFrameInner(frame);
    } finally {
      _initProcessingLocks.remove(senderPhantomId);
      completer.complete();
    }
  }

  Future<void> _handleInitFrameInner(ParsedFrame frame) async {
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
      final ok = await _tryDecryptAsMsg(frame);
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
      final success = await _handleMsgFrame(frame);
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
    SimpleKeyPairData? opkKP;
    if (frame.opkId != null) {
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
        await _handleMsgFrame(frame);
      }
      return;
    }

    dbg.log('MSG: ✓ INIT decrypted OK — type=${message.type.name}');

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
    try {
      final pub = SimplePublicKey(skBytes, type: KeyPairType.ed25519);
      return await Ed25519().verify(
        ikBytes,
        signature: Signature(ikSigBytes, publicKey: pub),
      );
    } catch (_) {
      return false;
    }
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
  Future<bool> _tryDecryptAsMsg(ParsedFrame frame) async {
    final dbg = TransportDebugger.instance;
    for (final entry in List.of(_sessions.entries)) {
      final snapshot = entry.value.takeSnapshot();
      try {
        final protocol = PhantomProtocol(entry.value);
        final message  = await protocol.decode(frame.payload);

        await _saveSession(entry.key, entry.value);
        await _dispatchIncoming(message, entry.key);
        dbg.log('MSG: ✓ MSG decrypted via session ${entry.key.substring(0, 8)}');
        _lastSuccessfulDecryptAt[entry.key] = DateTime.now();
        _cancelHandshakeRetry(entry.key);
        return true;
      } catch (e) {
        _sessions[entry.key] = await RatchetSession.fromJson(snapshot);
        continue;
      }
    }
    return false;
  }

  Future<bool> _handleMsgFrame(ParsedFrame frame) async {
    final dbg = TransportDebugger.instance;
    dbg.log('MSG: trying ${_sessions.length} session(s) for MSG decrypt');
    if (await _tryDecryptAsMsg(frame)) return true;
    dbg.log('MSG: ✗ no session could decrypt this MSG frame');

    // ── Auto-revive: detect ratchet desync and re-handshake ──────────────
    // If we have a session for the sender but decryption fails, the ratchet
    // has drifted (e.g. one side sent messages the other never received).
    // Instead of silently discarding the message, we reset the session and
    // send a fresh X3DH INIT so both sides can re-sync automatically.
    if (_sessions.isNotEmpty) {
      // Pick the session that most likely sent this frame — the one we
      // have an active ratchet for. In 1:1 chat there's typically one.
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

        // Rate limit: at most 1 auto-revive per contact per 2 minutes
        if (lastRevive != null &&
            now.difference(lastRevive) < const Duration(minutes: 2)) {
          dbg.log('MSG: auto-revive skipped for ${contactId.substring(0, 8)} '
              '(cooldown ${120 - now.difference(lastRevive).inSeconds}s)');
          continue;
        }

        _autoReviveCooldowns[contactId] = now;
        dbg.log('MSG: ⚡ auto-revive triggered for ${contactId.substring(0, 8)} '
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

  /// Call when the app goes to background / is closed.
  Future<void> onAppPaused() async {
    await _presence?.goOffline();
  }

  /// Call when the app returns to foreground.
  Future<void> onAppResumed() async {
    await _presence?.publishOnline();
    // Retry any messages that were queued while the transport was offline.
    _transportV2?.flushStore();
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
    for (final t in _handshakeRetryTimers.values) {
      t.cancel();
    }
    _handshakeRetryTimers.clear();
    _handshakeRetryAttempts.clear();
    await _handshakeStateController.close();
    await _transportSub?.cancel();
    await _transportV2Sub?.cancel();
    await _meshStoreSub?.cancel();
    await transport.dispose();
    await _transportV2?.dispose();
    _presence?.dispose();
    await storage.close();
    await _incomingController.close();
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

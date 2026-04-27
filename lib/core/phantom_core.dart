import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
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
    core._transportV2 = _buildTransportV2(transport, core.myId);

    // Derive Kyber-768 keypair deterministically from the seed phrase.
    await core._initKyberKeys(result.seedPhrase);
    await core._initializePreKeys();
    await core._startTransport();

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
    core._transportV2 = _buildTransportV2(transport, core.myId);

    await core._initKyberKeys(seedPhrase);

    // Re-initialize prekeys if they don't exist yet (e.g. first restore on new device)
    final existing = await PhantomStorage.instance.getPreKeyStore();
    if (existing == null) {
      await core._initializePreKeys();
    }

    await core._startTransport();
    return core;
  }

  static TransportManager _buildTransport(TransportConfig? config) {
    return TransportManager(
      ipfsApiUrl:       config?.ipfsApiUrl,
      i2pSocksHost:    config?.i2pSocksHost,
      i2pSocksPort:    config?.i2pSocksPort,
      yggdrasilAddress: config?.yggdrasilAddress,
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
      }) =>
          v1.publish(
            recipientId:       recipientId,
            encryptedEnvelope: encryptedEnvelope,
          ),
    );
  }

  // ── Contact address ────────────────────────────────────────────────────────

  /// Returns the ContactAddress string to share with others so they can add us.
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
    );
    return ca.encode();
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

  Future<StoredMessage> _sendPhantomMessage({
    required String recipientId,
    required PhantomMessage message,
  }) async {
    final session  = await _getOrCreateSession(recipientId);
    final protocol = PhantomProtocol(session);

    // Capture BEFORE encode() calls session.encrypt(), which clears both fields.
    final x3dhEk      = session.pendingX3dhEphemeralKey;
    final kyberCipher = session.pendingKyberCipherBytes;
    final envelopeBytes = await protocol.encode(message);

    // Wrap in INIT frame on the first message (includes our full ContactAddress
    // so the receiver can persist our bundle and re-initiate sessions later).
    final Uint8List wire;
    if (x3dhEk != null) {
      final caBytes = await _getMyContactAddressBytes();
      if (kyberCipher != null) {
        wire = WireFrame.wrapHybridInit(
          senderIdentityKeyBytes:    identity.encryptionPublicKeyBytes,
          senderEphemeralKeyBytes:   x3dhEk,
          kyberCipherBytes:          kyberCipher,
          senderContactAddressBytes: caBytes,
          envelopeBytes:             envelopeBytes,
        );
      } else {
        wire = WireFrame.wrapInit(
          senderIdentityKeyBytes:    identity.encryptionPublicKeyBytes,
          senderEphemeralKeyBytes:   x3dhEk,
          senderContactAddressBytes: caBytes,
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
    await storage.saveMessage(stored);

    // Try v2 transport first (BLE mesh + internet with fallback + store-and-forward).
    // Fall back to v1 (internet-only) if v2 is not wired.
    try {
      if (_transportV2 != null) {
        final result = await _transportV2!.publish(
          recipientId:        recipientId,
          fullMessageId:      message.id,
          encryptedEnvelope:  wire,
        );
        final status = (result.success || result.queued)
            ? MessageStatus.sent
            : MessageStatus.failed;
        await storage.updateMessageStatus(recipientId, message.id, status);
        return stored.copyWith(status: status);
      } else if (_transportAvailable) {
        await transport.publish(recipientId: recipientId, encryptedEnvelope: wire);
        await storage.updateMessageStatus(recipientId, message.id, MessageStatus.sent);
        return stored.copyWith(status: MessageStatus.sent);
      } else {
        await storage.updateMessageStatus(recipientId, message.id, MessageStatus.failed);
        return stored.copyWith(status: MessageStatus.failed);
      }
    } catch (_) {
      await storage.updateMessageStatus(recipientId, message.id, MessageStatus.failed);
      return stored.copyWith(status: MessageStatus.failed);
    }
  }

  /// Builds the raw ContactAddress bytes for inclusion in INIT frames.
  /// Returns v2 (1349 bytes) when Kyber-768 keys are available, v1 (165 bytes) otherwise.
  Future<Uint8List> _getMyContactAddressBytes() async {
    final bundleJson = await storage.getOwnBundle();
    if (bundleJson == null) return Uint8List(165);
    final bundle = PreKeyBundle.fromJson(bundleJson);

    if (_kyberPublicKeyBytes != null) {
      // v2: [1=0x02][32 ik][32 sk][32 spk][4 spk_id][64 sig][1184 kyber_pk]
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
      // v1: [1=0x01][32 ik][32 sk][32 spk][4 spk_id][64 sig]
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
  Future<ContactRecord> addContact({
    required String contactAddress,
    String? nickname,
  }) async {
    final ca     = ContactAddress.decode(contactAddress);
    final contact = ContactRecord(
      phantomId:               ca.phantomId,
      nickname:                nickname,
      encryptionPublicKeyBytes: ca.x25519IdentityKey,
      signingPublicKeyBytes:    ca.ed25519SigningKey,
      signedPreKeyBytes:        ca.signedPreKeyBytes,
      signedPreKeyId:           ca.signedPreKeyId,
      signedPreKeySignature:    ca.signature,
      kyber768PublicKeyBytes:   ca.kyber768PublicKeyBytes,
    );
    await storage.saveContact(contact);
    return contact;
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

  Future<void> _initializePreKeys() async {
    // OPKs require server-mediated exchange so they are not generated here.
    final result = await X3DHHandshake.generateBundle(
      identityKP: identity.encryptionKeyPair,
      signingKP:  identity.signingKeyPair,
      numOneTimePreKeys: 0,
    );

    await storage.savePreKeyStore(PreKeyStore(
      signedPreKeyPrivate:   Uint8List.fromList(result.signedPreKeyPair.bytes),
      signedPreKeyPublic:    result.signedPreKeyPublicBytes,
      signedPreKeyId:        1,
      oneTimePreKeyPrivates: const {},
    ));

    // Persist own bundle, including the Kyber public key when available.
    final bundleJson = result.bundle.toJson();
    if (_kyberPublicKeyBytes != null) {
      bundleJson['kyber768_pk'] =
          List<int>.from(_kyberPublicKeyBytes!).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
    await storage.saveOwnBundle(bundleJson);
  }

  // ── Session management ─────────────────────────────────────────────────────

  Future<RatchetSession> _getOrCreateSession(String recipientId) async {
    // In-memory cache
    if (_sessions.containsKey(recipientId)) {
      return _sessions[recipientId]!;
    }

    // Try to restore from persistent storage
    final savedState = await storage.getSessionState(recipientId);
    if (savedState != null) {
      final session = await RatchetSession.fromJson(savedState);
      _sessions[recipientId] = session;
      return session;
    }

    // Create a new session via X3DH
    final contact = await storage.getContact(recipientId);
    if (contact == null) {
      throw PhantomCoreException('Contact not found: $recipientId. Add them first.');
    }

    final bundle = PreKeyBundle(
      identityKeyBytes:      contact.encryptionPublicKeyBytes,
      signingKeyBytes:       contact.signingPublicKeyBytes,
      signedPreKeyBytes:     contact.signedPreKeyBytes,
      signedPreKeyId:        contact.signedPreKeyId,
      signedPreKeySignature: contact.signedPreKeySignature,
      oneTimePreKeys:        const [],
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
    );

    _sessions[recipientId] = session;
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

  Future<void> _handleIncomingBytes(Uint8List data) async {
    try {
      final frame = WireFrame.parse(data);
      if (frame.isInit) {
        await _handleInitFrame(frame);
      } else {
        await _handleMsgFrame(frame);
      }
    } catch (_) {
      // Malformed frame — discard silently
    }
  }

  /// Handle an INIT frame: run X3DH respond, create receiver session, decrypt.
  Future<void> _handleInitFrame(ParsedFrame frame) async {
    final senderIkBytes   = frame.senderIdentityKeyBytes!;
    final senderEkBytes   = frame.senderEphemeralKeyBytes!;
    final senderCaBytes   = frame.senderContactAddressBytes;
    final senderPhantomId = frame.senderPhantomId;

    final preKeyStore = await storage.getPreKeyStore();
    if (preKeyStore == null) return;

    // Reconstruct our signed prekey keypair from stored private + public bytes
    final spkPub = SimplePublicKey(
      preKeyStore.signedPreKeyPublic,
      type: KeyPairType.x25519,
    );
    final spkKP = SimpleKeyPairData(
      preKeyStore.signedPreKeyPrivate,
      publicKey: spkPub,
      type: KeyPairType.x25519,
    );

    Uint8List sharedSecret;
    try {
      sharedSecret = await X3DHHandshake.respond(
        ourIdentityKP:          identity.encryptionKeyPair,
        ourSignedPreKP:         spkKP,
        theirIdentityKeyBytes:  senderIkBytes,
        theirEphemeralKeyBytes: senderEkBytes,
      );
    } catch (_) {
      return; // Bad handshake — discard
    }

    // If this is a hybrid frame and we have our Kyber private key, decapsulate
    // and combine with the X3DH secret to get the session key.
    if (frame.isHybrid &&
        frame.kyberCipherBytes != null &&
        _kyberPrivateKeyBytes != null) {
      try {
        final kyberSecret = HybridKEM.decapsulate(
          frame.kyberCipherBytes!,
          _kyberPrivateKeyBytes!,
        );
        sharedSecret = await HybridKEM.combineSecrets(sharedSecret, kyberSecret);
      } catch (_) {
        return; // Kyber decapsulation failed — discard
      }
    }

    final session = await RatchetSession.initAsReceiver(
      sharedSecret:    sharedSecret,
      ourEncryptionKP: identity.encryptionKeyPair,
    );

    try {
      final protocol = PhantomProtocol(session);
      final message  = await protocol.decode(frame.payload);

      // Build a full ContactRecord from the embedded ContactAddress when possible,
      // so we can re-initiate sessions later without the sender needing to resend.
      if (await storage.getContact(senderPhantomId) == null) {
        await storage.saveContact(
          _buildContactFromInit(senderPhantomId, senderIkBytes, senderCaBytes),
        );
      }

      _sessions[senderPhantomId] = session;
      await _saveSession(senderPhantomId, session);

      final stored = StoredMessage.fromPhantomMessage(
        msg:            message,
        conversationId: senderPhantomId,
        direction:      MessageDirection.incoming,
        status:         MessageStatus.delivered,
      );
      await storage.saveMessage(stored);
      _incomingController.add(stored);
    } catch (_) {
      // Decryption failed — discard
    }
  }

  /// Builds a [ContactRecord] from data available in an INIT frame.
  /// Uses the embedded ContactAddress bytes for a full record; falls back to a
  /// minimal record (no SPK) when the CA is absent or malformed.
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

  /// Handle a regular MSG frame: try each active session until one decrypts.
  /// Each attempt snapshots the session state before trying and restores it on
  /// failure, preventing ratchet state corruption if header decryption succeeds
  /// on the wrong session before the body MAC fails.
  Future<void> _handleMsgFrame(ParsedFrame frame) async {
    for (final entry in List.of(_sessions.entries)) {
      final snapshot = entry.value.takeSnapshot();
      try {
        final protocol = PhantomProtocol(entry.value);
        final message  = await protocol.decode(frame.payload);

        await _saveSession(entry.key, entry.value);

        final stored = StoredMessage.fromPhantomMessage(
          msg:            message,
          conversationId: entry.key,
          direction:      MessageDirection.incoming,
          status:         MessageStatus.delivered,
        );
        await storage.saveMessage(stored);
        _incomingController.add(stored);
        return;
      } catch (_) {
        // Restore session to pre-attempt state before trying the next one.
        _sessions[entry.key] = await RatchetSession.fromJson(snapshot);
        continue;
      }
    }
    // Unknown session — could be a resumed session from a previous install; discard.
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await _transportSub?.cancel();
    await _transportV2Sub?.cancel();
    await _meshStoreSub?.cancel();
    await transport.dispose();
    await _transportV2?.dispose();
    await storage.close();
    await _incomingController.close();
  }
}

// ── TransportConfig ────────────────────────────────────────────────────────────

@immutable
class TransportConfig {
  final String? ipfsApiUrl;
  final String? i2pSocksHost;
  final int?    i2pSocksPort;
  final String? yggdrasilAddress;

  const TransportConfig({
    this.ipfsApiUrl,
    this.i2pSocksHost,
    this.i2pSocksPort,
    this.yggdrasilAddress,
  });

  const TransportConfig.ipfsOnly({String? apiUrl})
      : ipfsApiUrl = apiUrl ?? 'http://127.0.0.1:5001',
        i2pSocksHost = null,
        i2pSocksPort = null,
        yggdrasilAddress = null;
}

class PhantomCoreException implements Exception {
  final String message;
  const PhantomCoreException(this.message);
  @override
  String toString() => 'PhantomCoreException: $message';
}

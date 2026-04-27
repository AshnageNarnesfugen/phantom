import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

/// Double Ratchet Algorithm (Signal Protocol).
///
/// Guarantees:
///   - Forward secrecy: compromising a key does not expose past messages.
///   - Break-in recovery: each DH ratchet step creates new independent keys.
///
/// Protocol fix vs original:
///   - Initial header keys are derived from the X3DH shared secret alone
///     (via _kdfInitialHeaderKey), so both sides can decrypt each other's
///     first message without a circular dependency.
///   - _kdfRootKey now produces 3 outputs (removed the redundant 4th).

const int _maxSkip = 1000;

const _kdfRkInfo  = 'phantom-ratchet-root-key';
const _kdfCkInfo  = 'phantom-ratchet-chain-key';
const _kdfMkInfo  = 'phantom-ratchet-message-key';
const _kdfHkAtoB  = 'phantom-ratchet-hk-atob';
const _kdfHkBtoA  = 'phantom-ratchet-hk-btoa';

// ── Auxiliary types ───────────────────────────────────────────────────────────

@immutable
class MessageKey {
  final Uint8List encKey;
  final Uint8List headerKey;

  const MessageKey({
    required this.encKey,
    required this.headerKey,
  });
}

@immutable
class RatchetHeader {
  final Uint8List dhPublicKey;
  final int previousChainLen;
  final int messageNumber;

  const RatchetHeader({
    required this.dhPublicKey,
    required this.previousChainLen,
    required this.messageNumber,
  });

  Uint8List encode() {
    final out = Uint8List(40);
    final view = ByteData.sublistView(out);
    view.setUint32(0, previousChainLen, Endian.big);
    view.setUint32(4, messageNumber, Endian.big);
    out.setRange(8, 40, dhPublicKey);
    return out;
  }

  static RatchetHeader decode(Uint8List bytes) {
    if (bytes.length < 40) {
      throw RatchetException('Header too short: ${bytes.length}');
    }
    final view = ByteData.sublistView(bytes, 0, 8);
    return RatchetHeader(
      previousChainLen: view.getUint32(0, Endian.big),
      messageNumber:    view.getUint32(4, Endian.big),
      dhPublicKey:      Uint8List.fromList(bytes.sublist(8, 40)),
    );
  }
}

@immutable
class EncryptedMessage {
  final Uint8List encryptedHeader;
  final Uint8List ciphertext;
  final Uint8List nonce;

  const EncryptedMessage({
    required this.encryptedHeader,
    required this.ciphertext,
    required this.nonce,
  });
}

// ── Ratchet Session ───────────────────────────────────────────────────────────

class RatchetSession {
  Uint8List _rootKey;

  Uint8List? _sendingChainKey;
  Uint8List? _receivingChainKey;

  SimpleKeyPairData _dhSendingKP;
  Uint8List? _dhRemotePublicKey;

  int _sendingN = 0;
  int _receivingN = 0;
  int _previousSendingN = 0;

  final Map<String, MessageKey> _skippedKeys = {};

  Uint8List? _sendingHeaderKey;
  Uint8List? _receivingHeaderKey;
  Uint8List? _nextSendingHeaderKey;
  Uint8List? _nextReceivingHeaderKey;

  /// Non-null only before the first INIT frame is sent (sender side).
  /// Cleared after first encrypt().
  Uint8List? pendingX3dhEphemeralKey;

  /// Kyber-768 ciphertext for the hybrid INIT frame (sender side only).
  /// Null when the session was established without quantum-resistant KEM.
  /// Cleared after first encrypt().
  Uint8List? pendingKyberCipherBytes;

  RatchetSession._({
    required Uint8List rootKey,
    required SimpleKeyPairData dhSendingKP,
    Uint8List? dhRemotePublicKey,
    Uint8List? sendingChainKey,
    Uint8List? receivingChainKey,
  })  : _rootKey = rootKey,
        _dhSendingKP = dhSendingKP,
        _dhRemotePublicKey = dhRemotePublicKey,
        _sendingChainKey = sendingChainKey,
        _receivingChainKey = receivingChainKey;

  // ── Factory constructors ───────────────────────────────────────────────────

  /// Alice (initiator) side.
  static Future<RatchetSession> initAsSender({
    required Uint8List sharedSecret,
    required Uint8List remotePublicKey,
    Uint8List? x3dhEphemeralKeyBytes,
    Uint8List? kyberCipherBytes,
  }) async {
    final dhKP     = await X25519().newKeyPair();
    final dhKPData = await dhKP.extract();

    final dhOutput = await _dh(dhKPData, remotePublicKey);

    // Derive sending and receiving initial header keys from shared secret only,
    // so the receiver can decrypt without knowing our ratchet DH key.
    final hkAtoB = await _kdfInitialHeaderKey(sharedSecret, _kdfHkAtoB);
    final hkBtoA = await _kdfInitialHeaderKey(sharedSecret, _kdfHkBtoA);

    // First ratchet KDF
    final (newRootKey, sendingCK, nextSendHK) =
        await _kdfRootKey(sharedSecret, dhOutput);

    final session = RatchetSession._(
      rootKey: newRootKey,
      dhSendingKP: dhKPData,
      dhRemotePublicKey: remotePublicKey,
      sendingChainKey: sendingCK,
    )
      .._sendingHeaderKey       = hkAtoB        // first send uses shared-secret HK
      .._nextSendingHeaderKey   = nextSendHK    // after first DH ratchet response
      .._nextReceivingHeaderKey = hkBtoA        // to decrypt Bob's first reply
      ..pendingX3dhEphemeralKey  = x3dhEphemeralKeyBytes
      ..pendingKyberCipherBytes  = kyberCipherBytes;

    return session;
  }

  /// Bob (receiver) side.
  static Future<RatchetSession> initAsReceiver({
    required Uint8List sharedSecret,
    required SimpleKeyPairData ourEncryptionKP,
  }) async {
    final hkAtoB = await _kdfInitialHeaderKey(sharedSecret, _kdfHkAtoB);
    final hkBtoA = await _kdfInitialHeaderKey(sharedSecret, _kdfHkBtoA);

    return RatchetSession._(
      rootKey: sharedSecret,
      dhSendingKP: ourEncryptionKP,
      dhRemotePublicKey: null,
      sendingChainKey: null,
      receivingChainKey: null,
    )
      .._nextReceivingHeaderKey = hkAtoB   // decrypt Alice's first messages
      .._nextSendingHeaderKey   = hkBtoA;  // used as Bob's first sending HK after DH ratchet
  }

  // ── Encrypt ────────────────────────────────────────────────────────────────

  Future<EncryptedMessage> encrypt(Uint8List plaintext) async {
    if (_sendingChainKey == null) {
      throw const RatchetException(
        'Cannot send yet: waiting for the first incoming message to initialize the sending chain.',
      );
    }
    final (newCK, mk) = await _kdfChainKey(_sendingChainKey!);
    _sendingChainKey = newCK;

    final dhPub = await _dhSendingKP.extractPublicKey();
    final header = RatchetHeader(
      dhPublicKey: Uint8List.fromList(dhPub.bytes),
      previousChainLen: _previousSendingN,
      messageNumber: _sendingN,
    );
    _sendingN++;

    // Clear pending INIT-frame fields after first encrypt
    pendingX3dhEphemeralKey = null;
    pendingKyberCipherBytes = null;

    final encHeader = await _encryptHeader(header.encode(), _sendingHeaderKey!);
    final nonce     = await _randomNonce();
    final ciphertext = await _encryptMessage(plaintext, mk, nonce, encHeader);

    return EncryptedMessage(
      encryptedHeader: encHeader,
      ciphertext: ciphertext,
      nonce: nonce,
    );
  }

  // ── Decrypt ────────────────────────────────────────────────────────────────

  Future<Uint8List> decrypt(EncryptedMessage msg) async {
    RatchetHeader? header;
    bool isSkipped = false;

    // 1. Try current receiving header key
    if (_receivingHeaderKey != null) {
      try {
        final hBytes = await _decryptHeader(msg.encryptedHeader, _receivingHeaderKey!);
        header = RatchetHeader.decode(hBytes);
        final skippedKey = _trySkippedKey(header);
        if (skippedKey != null) {
          isSkipped = true;
          return _decryptMessage(msg.ciphertext, skippedKey, msg.nonce, msg.encryptedHeader);
        }
      } catch (_) {}
    }

    // 2. Try next receiving header key (triggers DH ratchet)
    if (_nextReceivingHeaderKey != null && header == null) {
      try {
        final hBytes = await _decryptHeader(msg.encryptedHeader, _nextReceivingHeaderKey!);
        header = RatchetHeader.decode(hBytes);
      } catch (_) {
        throw const RatchetException('Could not decrypt message header.');
      }
    }

    if (header == null) {
      throw const RatchetException('Undecipherable header — unknown session or corrupt message.');
    }

    if (!isSkipped) {
      final needsDhRatchet = _dhRemotePublicKey == null ||
          !_bytesEqual(header.dhPublicKey, _dhRemotePublicKey!);

      if (needsDhRatchet) {
        await _skipMessageKeys(header.previousChainLen);
        await _dhRatchet(header.dhPublicKey);
      }

      await _skipMessageKeys(header.messageNumber);

      final (newCK, mk) = await _kdfChainKey(_receivingChainKey!);
      _receivingChainKey = newCK;
      _receivingN++;

      return _decryptMessage(msg.ciphertext, mk, msg.nonce, msg.encryptedHeader);
    }

    throw const RatchetException('Inconsistent decryption state.');
  }

  // ── DH Ratchet ─────────────────────────────────────────────────────────────

  Future<void> _dhRatchet(Uint8List theirNewDhPublicKey) async {
    _previousSendingN = _sendingN;
    _sendingN = 0;
    _receivingN = 0;
    _dhRemotePublicKey = theirNewDhPublicKey;

    // Receiving ratchet step
    final dhOutputReceive = await _dh(_dhSendingKP, theirNewDhPublicKey);
    final (rootKey1, recvCK, nextRecvHK) =
        await _kdfRootKey(_rootKey, dhOutputReceive);
    _rootKey = rootKey1;
    _receivingChainKey = recvCK;
    _receivingHeaderKey     = _nextReceivingHeaderKey;
    _nextReceivingHeaderKey = nextRecvHK;

    // Generate new DH sending keypair
    final newDhKP = await X25519().newKeyPair();
    _dhSendingKP = await newDhKP.extract();

    // Sending ratchet step
    final dhOutputSend = await _dh(_dhSendingKP, theirNewDhPublicKey);
    final (rootKey2, sendCK, nextSendHK) =
        await _kdfRootKey(rootKey1, dhOutputSend);
    _rootKey = rootKey2;
    _sendingChainKey = sendCK;
    _sendingHeaderKey     = _nextSendingHeaderKey;
    _nextSendingHeaderKey = nextSendHK;
    _sendingN = 0;
  }

  Future<void> _skipMessageKeys(int until) async {
    if (_receivingN + _maxSkip < until) {
      throw RatchetException('Too many skipped messages: $until');
    }
    if (_receivingChainKey == null) return;

    while (_receivingN < until) {
      final (newCK, mk) = await _kdfChainKey(_receivingChainKey!);
      _receivingChainKey = newCK;
      final key = _skippedKeyId(_dhRemotePublicKey!, _receivingN);
      _skippedKeys[key] = mk;
      _receivingN++;
    }
  }

  MessageKey? _trySkippedKey(RatchetHeader header) {
    final key = _skippedKeyId(header.dhPublicKey, header.messageNumber);
    return _skippedKeys.remove(key);
  }

  // ── KDFs ───────────────────────────────────────────────────────────────────

  static Future<Uint8List> _kdfInitialHeaderKey(
      Uint8List sharedSecret, String direction) async {
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
    final out = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: Uint8List(0),
      info: Uint8List.fromList(direction.codeUnits),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  /// Returns (newRootKey, chainKey, nextHeaderKey).
  static Future<(Uint8List, Uint8List, Uint8List)> _kdfRootKey(
      Uint8List rootKey, Uint8List dhOutput) async {
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 96);
    final out = await hkdf.deriveKey(
      secretKey: SecretKey(dhOutput),
      nonce: rootKey,
      info: Uint8List.fromList(_kdfRkInfo.codeUnits),
    );
    final bytes = Uint8List.fromList(await out.extractBytes());
    return (
      bytes.sublist(0, 32),  // new root key
      bytes.sublist(32, 64), // chain key
      bytes.sublist(64, 96), // next header key
    );
  }

  static Future<(Uint8List, MessageKey)> _kdfChainKey(Uint8List chainKey) async {
    final hmac = Hmac(Sha512());

    final newCKMac = await hmac.calculateMac(
      Uint8List.fromList([0x01]),
      secretKey: SecretKey(chainKey),
    );

    final mkMac = await hmac.calculateMac(
      Uint8List.fromList(_kdfCkInfo.codeUnits),
      secretKey: SecretKey(chainKey),
    );

    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 64);
    final mkExpanded = await hkdf.deriveKey(
      secretKey: SecretKey(mkMac.bytes),
      nonce: Uint8List(0),
      info: Uint8List.fromList(_kdfMkInfo.codeUnits),
    );
    final mkBytes = Uint8List.fromList(await mkExpanded.extractBytes());

    return (
      Uint8List.fromList(newCKMac.bytes.sublist(0, 32)),
      MessageKey(
        encKey:    mkBytes.sublist(0, 32),
        headerKey: mkBytes.sublist(32, 64),
      ),
    );
  }

  // ── DH ─────────────────────────────────────────────────────────────────────

  static Future<Uint8List> _dh(
      SimpleKeyPairData ourKP, Uint8List theirPublicKeyBytes) async {
    final theirPub = SimplePublicKey(theirPublicKeyBytes, type: KeyPairType.x25519);
    final shared = await X25519().sharedSecretKey(
      keyPair: ourKP,
      remotePublicKey: theirPub,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  // ── Symmetric encryption ───────────────────────────────────────────────────

  Future<Uint8List> _encryptMessage(
    Uint8List plaintext,
    MessageKey mk,
    Uint8List nonce,
    Uint8List associatedData,
  ) async {
    final box = await Chacha20.poly1305Aead().encrypt(
      plaintext,
      secretKey: SecretKey(mk.encKey),
      nonce: nonce,
      aad: associatedData,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> _decryptMessage(
    Uint8List cipherAndMac,
    MessageKey mk,
    Uint8List nonce,
    Uint8List associatedData,
  ) async {
    if (cipherAndMac.length < 16) {
      throw const RatchetException('Ciphertext too short.');
    }
    final cipher = cipherAndMac.sublist(0, cipherAndMac.length - 16);
    final mac    = cipherAndMac.sublist(cipherAndMac.length - 16);
    try {
      final plain = await Chacha20.poly1305Aead().decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(mk.encKey),
        aad: associatedData,
      );
      return Uint8List.fromList(plain);
    } catch (_) {
      throw const RatchetException('Authentication failed — corrupt or tampered message.');
    }
  }

  Future<Uint8List> _encryptHeader(Uint8List headerBytes, Uint8List headerKey) async {
    final nonce = await _randomNonce();
    final box = await Chacha20.poly1305Aead().encrypt(
      headerBytes,
      secretKey: SecretKey(headerKey),
      nonce: nonce,
    );
    // [12 nonce][ciphertext][16 mac]
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> _decryptHeader(Uint8List encHeader, Uint8List headerKey) async {
    if (encHeader.length < 28) {
      throw const RatchetException('Encrypted header too short.');
    }
    final nonce  = encHeader.sublist(0, 12);
    final rest   = encHeader.sublist(12);
    final cipher = rest.sublist(0, rest.length - 16);
    final mac    = rest.sublist(rest.length - 16);
    try {
      final plain = await Chacha20.poly1305Aead().decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(headerKey),
      );
      return Uint8List.fromList(plain);
    } catch (_) {
      throw const RatchetException('Could not decrypt header.');
    }
  }

  // ── Utilities ──────────────────────────────────────────────────────────────

  static Future<Uint8List> _randomNonce() async {
    return Uint8List.fromList(
      await SecretKeyData.random(length: 12).extractBytes(),
    );
  }

  static String _skippedKeyId(Uint8List dhPubKey, int n) {
    final hex = dhPubKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$hex:$n';
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ── Snapshot (synchronous) ────────────────────────────────────────────────

  /// Returns a synchronous snapshot of all mutable session state.
  /// Used by [PhantomCore._handleMsgFrame] to restore state if decryption fails
  /// on the wrong session, preventing ratchet state corruption.
  Map<String, dynamic> takeSnapshot() {
    final dhPub = Uint8List.fromList(_dhSendingKP.publicKey.bytes);
    return {
      'rk':        _hexOf(_rootKey),
      'sck':       _sendingChainKey   != null ? _hexOf(_sendingChainKey!)   : null,
      'rck':       _receivingChainKey != null ? _hexOf(_receivingChainKey!) : null,
      'dhsk_priv': _hexOf(Uint8List.fromList(_dhSendingKP.bytes)),
      'dhsk_pub':  _hexOf(dhPub),
      'dhrpk':     _dhRemotePublicKey != null ? _hexOf(_dhRemotePublicKey!) : null,
      'sn':        _sendingN,
      'rn':        _receivingN,
      'psn':       _previousSendingN,
      'shk':       _sendingHeaderKey       != null ? _hexOf(_sendingHeaderKey!)       : null,
      'rhk':       _receivingHeaderKey     != null ? _hexOf(_receivingHeaderKey!)     : null,
      'nshk':      _nextSendingHeaderKey   != null ? _hexOf(_nextSendingHeaderKey!)   : null,
      'nrhk':      _nextReceivingHeaderKey != null ? _hexOf(_nextReceivingHeaderKey!) : null,
      'x3dh_ek':    pendingX3dhEphemeralKey != null ? _hexOf(pendingX3dhEphemeralKey!) : null,
      'kyber_cipher': pendingKyberCipherBytes != null ? _hexOf(pendingKyberCipherBytes!) : null,
      'sk': Map.fromEntries(_skippedKeys.entries.map((e) => MapEntry(e.key, {
        'ek': _hexOf(e.value.encKey),
        'hk': _hexOf(e.value.headerKey),
      }))),
    };
  }

  // ── Serialization ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> toJson() async {
    final dhPub = await _dhSendingKP.extractPublicKey();
    return {
      'rk':   _hexOf(_rootKey),
      'sck':  _sendingChainKey   != null ? _hexOf(_sendingChainKey!)   : null,
      'rck':  _receivingChainKey != null ? _hexOf(_receivingChainKey!) : null,
      'dhsk_priv': _hexOf(Uint8List.fromList(_dhSendingKP.bytes)),
      'dhsk_pub':  _hexOf(Uint8List.fromList(dhPub.bytes)),
      'dhrpk': _dhRemotePublicKey != null ? _hexOf(_dhRemotePublicKey!) : null,
      'sn':  _sendingN,
      'rn':  _receivingN,
      'psn': _previousSendingN,
      'shk':  _sendingHeaderKey       != null ? _hexOf(_sendingHeaderKey!)       : null,
      'rhk':  _receivingHeaderKey     != null ? _hexOf(_receivingHeaderKey!)     : null,
      'nshk': _nextSendingHeaderKey   != null ? _hexOf(_nextSendingHeaderKey!)   : null,
      'nrhk': _nextReceivingHeaderKey != null ? _hexOf(_nextReceivingHeaderKey!) : null,
      'x3dh_ek':      pendingX3dhEphemeralKey  != null ? _hexOf(pendingX3dhEphemeralKey!)  : null,
      'kyber_cipher': pendingKyberCipherBytes   != null ? _hexOf(pendingKyberCipherBytes!)   : null,
      'sk': _skippedKeys.map((k, v) => MapEntry(k, {
        'ek': _hexOf(v.encKey),
        'hk': _hexOf(v.headerKey),
      })),
    };
  }

  static Future<RatchetSession> fromJson(Map<String, dynamic> j) async {
    final privBytes = _unhexOf(j['dhsk_priv'] as String);
    final pubBytes  = _unhexOf(j['dhsk_pub']  as String);
    final pub = SimplePublicKey(pubBytes, type: KeyPairType.x25519);
    final kp  = SimpleKeyPairData(privBytes, publicKey: pub, type: KeyPairType.x25519);

    final session = RatchetSession._(
      rootKey:           _unhexOf(j['rk'] as String),
      dhSendingKP:       kp,
      dhRemotePublicKey: j['dhrpk'] != null ? _unhexOf(j['dhrpk'] as String) : null,
      sendingChainKey:   j['sck']  != null ? _unhexOf(j['sck']  as String) : null,
      receivingChainKey: j['rck']  != null ? _unhexOf(j['rck']  as String) : null,
    );

    session._sendingN          = j['sn']  as int;
    session._receivingN        = j['rn']  as int;
    session._previousSendingN  = j['psn'] as int;

    session._sendingHeaderKey       = j['shk']  != null ? _unhexOf(j['shk']  as String) : null;
    session._receivingHeaderKey     = j['rhk']  != null ? _unhexOf(j['rhk']  as String) : null;
    session._nextSendingHeaderKey   = j['nshk'] != null ? _unhexOf(j['nshk'] as String) : null;
    session._nextReceivingHeaderKey = j['nrhk'] != null ? _unhexOf(j['nrhk'] as String) : null;
    session.pendingX3dhEphemeralKey = j['x3dh_ek']      != null ? _unhexOf(j['x3dh_ek']      as String) : null;
    session.pendingKyberCipherBytes = j['kyber_cipher'] != null ? _unhexOf(j['kyber_cipher'] as String) : null;

    final skMap = j['sk'] as Map? ?? {};
    for (final entry in skMap.entries) {
      final v = Map<String, dynamic>.from(entry.value as Map);
      session._skippedKeys[entry.key as String] = MessageKey(
        encKey:    _unhexOf(v['ek'] as String),
        headerKey: _unhexOf(v['hk'] as String),
      );
    }

    return session;
  }

  static String _hexOf(Uint8List b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _unhexOf(String hex) {
    final r = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < r.length; i++) {
      r[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return r;
  }
}

class RatchetException implements Exception {
  final String message;
  const RatchetException(this.message);
  @override
  String toString() => 'RatchetException: $message';
}

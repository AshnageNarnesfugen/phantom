import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'phantom_storage.dart';

/// Exports and imports encrypted device-transferable backups.
///
/// Format: [4-byte version][12-byte AES-GCM nonce][ciphertext][16-byte MAC]
/// Key: HKDF-SHA512 from seed phrase, distinct from the storage key.
class BackupManager {
  BackupManager._();

  static const _version  = 1;
  static const _fileName = 'phantom_backup.phantombak';

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Serialize and encrypt all account data to a transferable backup blob.
  ///
  /// Returns the path of the written file.
  static Future<String> exportBackup({
    required PhantomStorage storage,
    required String seedPhrase,
    required String phantomId,
  }) async {
    final contacts = await storage.getAllContacts();

    final sessions = <String, dynamic>{};
    for (final c in contacts) {
      final state = await storage.getSessionState(c.phantomId);
      if (state != null) sessions[c.phantomId] = state;
    }

    final messages = <String, dynamic>{};
    for (final c in contacts) {
      final msgs = await storage.getMessages(c.phantomId, limit: 50000);
      if (msgs.isNotEmpty) {
        messages[c.phantomId] = msgs.map((m) => m.toJson()).toList();
      }
    }

    final prekeys = await storage.getPreKeyStore();
    final bundle  = await storage.getOwnBundle();

    final payload = <String, dynamic>{
      'version':    _version,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'phantom_id': phantomId,
      'contacts':   contacts.map((c) => c.toJson()).toList(),
      'sessions':   sessions,
      'messages':   messages,
      'prekeys':    prekeys?.toJson(),
      'own_bundle': bundle,
    };

    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final encrypted = await _encrypt(plaintext, seedPhrase);

    final dir  = await _backupDir();
    final file = File('${dir.path}/$_fileName');
    await file.writeAsBytes(encrypted, flush: true);
    return file.path;
  }

  /// Decrypt and restore account data from a backup blob into initialized storage.
  ///
  /// Call [PhantomCore.restoreAccount] first so storage is open and keyed.
  static Future<void> importBackup({
    required PhantomStorage storage,
    required String seedPhrase,
    required Uint8List data,
  }) async {
    final plaintext = await _decrypt(data, seedPhrase);
    final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;

    final version = json['version'] as int?;
    if (version != _version) {
      throw BackupException('unsupported backup version: $version');
    }

    for (final raw in (json['contacts'] as List? ?? [])) {
      await storage.saveContact(
        ContactRecord.fromJson(Map<String, dynamic>.from(raw as Map)),
      );
    }

    for (final entry in ((json['sessions'] as Map?) ?? {}).entries) {
      await storage.saveSessionState(
        entry.key as String,
        Map<String, dynamic>.from(entry.value as Map),
      );
    }

    for (final entry in ((json['messages'] as Map?) ?? {}).entries) {
      for (final raw in entry.value as List) {
        final msg = StoredMessageJson.fromJson(
            Map<String, dynamic>.from(raw as Map));
        await storage.saveMessage(msg);
      }
    }

    if (json['prekeys'] != null) {
      await storage.savePreKeyStore(
        PreKeyStore.fromJson(Map<String, dynamic>.from(json['prekeys'] as Map)),
      );
    }

    if (json['own_bundle'] != null) {
      await storage.saveOwnBundle(
        Map<String, dynamic>.from(json['own_bundle'] as Map),
      );
    }
  }

  /// Returns the backup file if it exists in the expected location, else null.
  static Future<File?> findBackupFile() async {
    try {
      final path = await backupFilePath();
      final file = File(path);
      if (await file.exists()) return file;
    } catch (_) {}
    return null;
  }

  /// Full path where the backup file will be written / looked for.
  static Future<String> backupFilePath() async {
    final dir = await _backupDir();
    return '${dir.path}/$_fileName';
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  static Future<Directory> _backupDir() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    } catch (_) {}
    return getApplicationDocumentsDirectory();
  }

  static Future<Uint8List> _encrypt(Uint8List plaintext, String seedPhrase) async {
    final key       = await _deriveKey(seedPhrase);
    final algorithm = AesGcm.with256bits();
    final secretKey = await algorithm.newSecretKeyFromBytes(key);
    final box       = await algorithm.encrypt(plaintext, secretKey: secretKey);

    final hdr = Uint8List(4);
    hdr.buffer.asByteData().setUint32(0, _version, Endian.big);

    final buf = BytesBuilder();
    buf.add(hdr);
    buf.add(box.nonce);
    buf.add(box.cipherText);
    buf.add(box.mac.bytes);
    return buf.toBytes();
  }

  static Future<Uint8List> _decrypt(Uint8List data, String seedPhrase) async {
    const hdrLen   = 4;
    const nonceLen = 12;
    const macLen   = 16;

    if (data.length < hdrLen + nonceLen + macLen + 1) {
      throw const BackupException('backup file too small or corrupted');
    }

    final version = ByteData.sublistView(data).getUint32(0, Endian.big);
    if (version != _version) {
      throw BackupException('unsupported backup version: $version');
    }

    final nonce      = data.sublist(hdrLen, hdrLen + nonceLen);
    final macBytes   = data.sublist(data.length - macLen);
    final cipherText = data.sublist(hdrLen + nonceLen, data.length - macLen);

    final key       = await _deriveKey(seedPhrase);
    final algorithm = AesGcm.with256bits();
    final secretKey = await algorithm.newSecretKeyFromBytes(key);
    final box       = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));

    try {
      return Uint8List.fromList(
          await algorithm.decrypt(box, secretKey: secretKey));
    } catch (_) {
      throw const BackupException('wrong seed phrase or corrupted backup');
    }
  }

  static Future<Uint8List> _deriveKey(String seedPhrase) async {
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
    final out  = await hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(seedPhrase)),
      nonce: Uint8List.fromList(utf8.encode('phantom-backup-v1')),
      info:  Uint8List.fromList(utf8.encode('phantom-backup-encryption-key')),
    );
    return Uint8List.fromList(await out.extractBytes());
  }
}

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => 'BackupException: $message';
}

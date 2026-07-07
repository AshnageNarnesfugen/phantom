import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'protocol/message.dart';

/// Serverless group chat, v1 — pairwise fanout.
///
/// A group is a LOCAL construct kept in sync by encrypted control messages:
/// there is no group key and no server. Sending to a group encrypts one copy
/// per member through the existing 1:1 Double-Ratchet sessions, so groups
/// inherit every transport/session property (store-and-forward, handshake
/// auto-init, forward secrecy) for free. Sender-keys (Signal's large-group
/// optimization) can replace the fanout later without changing this model.
///
/// Wire:
///  - [MessageType.groupEnvelope]: `[16B gid][1B innerType][innerContent]`
///    — an inner chat message (text / linkPreview / inline image / file)
///    re-homed to the group conversation on receipt.
///  - [MessageType.groupControl]: UTF-8 JSON, always a FULL snapshot so
///    receivers upsert idempotently and ordering never matters:
///    `{v:1, gid, action: 'sync'|'leave', name, creator, members:[{id,ca?}], ts}`
///    Members carry their ContactAddress when the sender has it, so receivers
///    can auto-add group members they don't know yet.

/// Conversation-id prefix for group chats in message storage — distinct from
/// any phantomId (those are base58, no underscore).
const String groupConvPrefix = 'grp_';

String groupConversationId(String gid) => '$groupConvPrefix$gid';

bool isGroupConversation(String conversationId) =>
    conversationId.startsWith(groupConvPrefix);

String gidOfConversation(String conversationId) =>
    conversationId.substring(groupConvPrefix.length);

// ── Group record (Hive) ───────────────────────────────────────────────────────

class GroupRecord {
  final String gid; // 32 hex chars (16 random bytes)
  final String name;
  final String creatorId;
  final List<String> memberIds; // includes the creator; excludes nobody
  final int createdAtUs;
  final int updatedAtUs;

  const GroupRecord({
    required this.gid,
    required this.name,
    required this.creatorId,
    required this.memberIds,
    required this.createdAtUs,
    required this.updatedAtUs,
  });

  static String newGid() {
    final rng = Random.secure();
    return List.generate(16, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  GroupRecord copyWith({
    String? name,
    List<String>? memberIds,
    int? updatedAtUs,
  }) =>
      GroupRecord(
        gid: gid,
        name: name ?? this.name,
        creatorId: creatorId,
        memberIds: memberIds ?? this.memberIds,
        createdAtUs: createdAtUs,
        updatedAtUs: updatedAtUs ?? this.updatedAtUs,
      );

  Map<String, dynamic> toJson() => {
        'gid': gid,
        'name': name,
        'creator': creatorId,
        'members': memberIds,
        'created': createdAtUs,
        'updated': updatedAtUs,
      };

  static GroupRecord fromJson(Map<String, dynamic> j) => GroupRecord(
        gid: j['gid'] as String,
        name: j['name'] as String,
        creatorId: j['creator'] as String,
        memberIds: List<String>.from(j['members'] as List),
        createdAtUs: j['created'] as int,
        updatedAtUs: j['updated'] as int,
      );
}

// ── Control messages ──────────────────────────────────────────────────────────

class GroupControl {
  final String gid;
  final String action; // 'sync' | 'leave'
  final String name;
  final String creatorId;
  /// member id → ContactAddress string (null when the sender doesn't have it).
  final Map<String, String?> members;
  final int tsUs;

  const GroupControl({
    required this.gid,
    required this.action,
    required this.name,
    required this.creatorId,
    required this.members,
    required this.tsUs,
  });

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 1,
        'gid': gid,
        'action': action,
        'name': name,
        'creator': creatorId,
        'members': [
          for (final e in members.entries)
            {'id': e.key, if (e.value != null) 'ca': e.value},
        ],
        'ts': tsUs,
      })));

  /// Null on malformed input (never throws — this parses remote data).
  static GroupControl? decode(Uint8List content) {
    try {
      final j = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
      if ((j['v'] as num).toInt() != 1) return null;
      final members = <String, String?>{};
      for (final m in (j['members'] as List)) {
        final mm = Map<String, dynamic>.from(m as Map);
        members[mm['id'] as String] = mm['ca'] as String?;
      }
      return GroupControl(
        gid: j['gid'] as String,
        action: j['action'] as String,
        name: j['name'] as String,
        creatorId: j['creator'] as String,
        members: members,
        tsUs: (j['ts'] as num).toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

// ── Envelope ──────────────────────────────────────────────────────────────────

/// `[16B gid][1B innerType][innerContent]`
Uint8List packGroupEnvelope(String gid, MessageType innerType, Uint8List content) {
  final gidBytes = _unhex(gid);
  assert(gidBytes.length == 16, 'gid must be 16 bytes of hex');
  final out = Uint8List(16 + 1 + content.length)
    ..setAll(0, gidBytes)
    ..[16] = innerType.code
    ..setAll(17, content);
  return out;
}

({String gid, MessageType innerType, Uint8List content})? unpackGroupEnvelope(
    Uint8List envelope) {
  if (envelope.length < 17) return null;
  try {
    final gid = envelope
        .sublist(0, 16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final innerType = MessageType.fromCode(envelope[16]);
    return (
      gid: gid,
      innerType: innerType,
      content: Uint8List.sublistView(envelope, 17),
    );
  } catch (_) {
    return null;
  }
}

Uint8List _unhex(String hex) {
  final r = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < r.length; i++) {
    r[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return r;
}

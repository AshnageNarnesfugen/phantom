@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/groups.dart';
import 'package:phantom_messenger/phantom_messenger.dart';

import 'support/loopback_transport.dart';

/// Groups v1 (pairwise fanout): wire-codec unit tests + a real E2E over the
/// loopback lab — two PhantomCore instances exercising create → control sync →
/// group message fanout → attribution → leave, with zero network.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('group wire codec', () {
    test('GroupControl encode/decode round-trips', () {
      final ctrl = GroupControl(
        gid: 'aa' * 16,
        action: 'sync',
        name: 'the crew',
        creatorId: 'PHalice',
        members: {'PHalice': 'CA_ALICE', 'PHbob': null},
        tsUs: 123456789,
      );
      final decoded = GroupControl.decode(ctrl.encode())!;
      expect(decoded.gid, ctrl.gid);
      expect(decoded.action, 'sync');
      expect(decoded.name, 'the crew');
      expect(decoded.creatorId, 'PHalice');
      expect(decoded.members, {'PHalice': 'CA_ALICE', 'PHbob': null});
      expect(decoded.tsUs, 123456789);
    });

    test('GroupControl.decode rejects garbage without throwing', () {
      expect(GroupControl.decode(Uint8List.fromList([1, 2, 3])), isNull);
      expect(
          GroupControl.decode(
              Uint8List.fromList(utf8.encode('{"v":9,"x":1}'))),
          isNull);
    });

    test('group envelope packs and unpacks any inner type', () {
      final gid = GroupRecord.newGid();
      final content = Uint8List.fromList(utf8.encode('hola grupo'));
      final env = packGroupEnvelope(gid, MessageType.text, content);
      final out = unpackGroupEnvelope(env)!;
      expect(out.gid, gid);
      expect(out.innerType, MessageType.text);
      expect(utf8.decode(out.content), 'hola grupo');
      // Too short → null, not a crash.
      expect(unpackGroupEnvelope(Uint8List(5)), isNull);
    });

    test('GroupRecord JSON round-trips', () {
      final g = GroupRecord(
        gid: GroupRecord.newGid(),
        name: 'x',
        creatorId: 'c',
        memberIds: ['c', 'm1'],
        createdAtUs: 1,
        updatedAtUs: 2,
      );
      final back = GroupRecord.fromJson(g.toJson());
      expect(back.gid, g.gid);
      expect(back.memberIds, g.memberIds);
      expect(back.updatedAtUs, 2);
    });

    test('conversation-id helpers', () {
      final gid = GroupRecord.newGid();
      final conv = groupConversationId(gid);
      expect(isGroupConversation(conv), isTrue);
      expect(isGroupConversation('PHsomeContact'), isFalse);
      expect(gidOfConversation(conv), gid);
    });
  });

  group('groups E2E (loopback)', () {
    late LoopbackHub hub;
    late Directory aliceDir;
    late Directory bobDir;
    late PhantomCore alice;
    late PhantomCore bob;

    setUp(() async {
      hub = LoopbackHub();
      aliceDir = await Directory.systemTemp.createTemp('phantom_grp_alice_');
      bobDir = await Directory.systemTemp.createTemp('phantom_grp_bob_');
      alice = (await PhantomCore.createAccount(
        storagePath: aliceDir.path,
        storage: PhantomStorage.isolated(),
        transports: [LoopbackTransport(hub)],
        enablePresence: false,
        enableBleMesh: false,
      ))
          .core;
      bob = (await PhantomCore.createAccount(
        storagePath: bobDir.path,
        storage: PhantomStorage.isolated(),
        transports: [LoopbackTransport(hub)],
        enablePresence: false,
        enableBleMesh: false,
      ))
          .core;
    });

    tearDown(() async {
      await alice.dispose();
      await bob.dispose();
      await hub.dispose();
      try { await aliceDir.delete(recursive: true); } catch (_) {}
      try { await bobDir.delete(recursive: true); } catch (_) {}
    });

    test('create → sync → fanout → attribution → leave', () async {
      // Alice knows Bob (as if she scanned his QR).
      final bobAddress = await bob.getMyContactAddress();
      await alice.addContact(contactAddress: bobAddress!, nickname: 'Bob');

      // Create the group: Bob must receive the control snapshot and persist
      // the group locally.
      final bobSynced = bob.incomingMessages
          .firstWhere((m) => isGroupConversation(m.conversationId))
          .timeout(const Duration(seconds: 20));
      final g = await alice.createGroup(name: 'the crew', memberIds: [bob.myId]);
      await bobSynced;

      final bobGroup = await bob.getGroup(g.gid);
      expect(bobGroup, isNotNull, reason: 'control sync must persist the group');
      expect(bobGroup!.name, 'the crew');
      expect(bobGroup.memberIds.toSet(), {alice.myId, bob.myId});
      expect(bobGroup.creatorId, alice.myId);

      // Group message Alice → Bob: lands in the GROUP conversation, carries
      // the author for attribution, and never pollutes the 1:1 chat.
      final bobGets = bob.incomingMessages
          .firstWhere((m) =>
              m.conversationId == groupConversationId(g.gid) &&
              m.type == MessageType.text)
          .timeout(const Duration(seconds: 20));
      await alice.sendGroupMessage(gid: g.gid, text: 'hola crew');
      final got = await bobGets;
      expect(utf8.decode(got.content), 'hola crew');
      expect(got.senderId, alice.myId);

      final bobGroupMsgs =
          await bob.storage.getMessages(groupConversationId(g.gid));
      expect(bobGroupMsgs.any((m) => m.type == MessageType.text), isTrue);
      final bob1to1 = await bob.storage.getMessages(alice.myId);
      expect(bob1to1.where((m) => m.type == MessageType.text), isEmpty,
          reason: 'group traffic must not appear in the 1:1 conversation');

      // Reply Bob → Alice through the group.
      final aliceGets = alice.incomingMessages
          .firstWhere((m) =>
              m.conversationId == groupConversationId(g.gid) &&
              m.type == MessageType.text)
          .timeout(const Duration(seconds: 20));
      await bob.sendGroupMessage(gid: g.gid, text: 'presente');
      expect(utf8.decode((await aliceGets).content), 'presente');
      expect((await alice.storage.getMessages(groupConversationId(g.gid)))
          .length, greaterThanOrEqualTo(2));

      // Bob leaves: Alice's member list shrinks; Bob's group is gone.
      final aliceSeesLeave = alice.incomingMessages
          .firstWhere((m) => isGroupConversation(m.conversationId))
          .timeout(const Duration(seconds: 20));
      await bob.leaveGroup(g.gid);
      await aliceSeesLeave;
      expect(await bob.getGroup(g.gid), isNull);
      final afterLeave = await alice.getGroup(g.gid);
      expect(afterLeave!.memberIds, [alice.myId]);
    });
  });
}

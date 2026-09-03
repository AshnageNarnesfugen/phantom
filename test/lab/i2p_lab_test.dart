@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/phantom_messenger.dart';
import 'package:phantom_messenger/core/secret_chat.dart';

import '../support/fake_sam_bridge.dart';

/// Two "phones" messaging over the REAL I2P stack, on one machine, in seconds.
///
/// Both sides run the production [I2PTransport] against a [FakeSamBridge]
/// instead of i2pd: the same SAM handshake, the same UDP datagram forwarding,
/// the same ACK/retransmit layer, the same destination learning. Only the I2P
/// network itself is absent — and it was never where the bugs were.
///
/// The bridge runs in its STRICT mode here, meaning it will not parse options
/// off a datagram send header: the destination must be a bare destination or
/// the datagram is dropped, silently, exactly as SAM drops one it cannot
/// resolve. That is the whole point. A destination is written blind from three
/// places, a bad one is invisible from the app's side (the UDP write still
/// succeeds, the log still says "delivery OK"), and the symptom is a one-way
/// conversation two days later on someone else's phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSamBridge bridge;
  late Directory aliceDir;
  late Directory bobDir;
  late PhantomCore alice;
  late PhantomCore bob;

  I2PTransport i2pOf(PhantomCore core) =>
      core.transport.transports.whereType<I2PTransport>().first;

  Future<void> waitForSession(PhantomCore core) async {
    final i2p = i2pOf(core);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!i2p.isSessionReady) {
      if (DateTime.now().isAfter(deadline)) {
        fail('I2P session never came up against the fake bridge');
      }
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<StoredMessage> nextMessage(PhantomCore core,
      {Duration timeout = const Duration(seconds: 30)}) {
    return core.incomingMessages
        .firstWhere((m) =>
            m.type == MessageType.text ||
            m.type == MessageType.image ||
            m.type == MessageType.file)
        .timeout(timeout);
  }

  Future<PhantomCore> spawn(Directory dir) async {
    final r = await PhantomCore.createAccount(
      storagePath: dir.path,
      storage: PhantomStorage.isolated(),
      transports: [
        I2PTransport(
          host: '127.0.0.1',
          samPort: bridge.samPort,
          samUdpPort: bridge.samUdpPort,
        ),
      ],
      enablePresence: false,
      enableBleMesh: false,
    );
    return r.core;
  }

  /// Brings both sides up and walks them through the X3DH handshake, leaving a
  /// live session in both directions. Every test starts from here because it
  /// is where a real pair of phones starts.
  Future<void> introduce() async {
    final bobAddress = await bob.getMyContactAddress();
    expect(bobAddress, isNotNull,
        reason: 'the contact address must carry Bob I2P destination');
    expect(bobAddress, contains(i2pOf(bob).myDestination!),
        reason: 'the \$-suffix of the CA is how Alice learns where to send');
    await alice.addContact(contactAddress: bobAddress!, nickname: 'Bob');

    final bobGets = nextMessage(bob);
    await alice.sendMessage(
        recipientId: await _idOf(bob), text: 'first contact');
    final got = await bobGets;
    expect(got.textContent, 'first contact');
  }

  setUp(() async {
    bridge = FakeSamBridge(strictSendHeader: true);
    await bridge.start();
    aliceDir = await Directory.systemTemp.createTemp('phantom_i2plab_alice_');
    bobDir = await Directory.systemTemp.createTemp('phantom_i2plab_bob_');
    alice = await spawn(aliceDir);
    bob = await spawn(bobDir);
    await waitForSession(alice);
    await waitForSession(bob);
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    await bridge.dispose();
    try { await aliceDir.delete(recursive: true); } catch (_) {}
    try { await bobDir.delete(recursive: true); } catch (_) {}
  });

  test('two devices: handshake and messaging both ways over I2P', () async {
    await introduce();

    // And back — the direction that breaks in the field, because Bob never
    // scanned anything and only knows Alice from what arrived.
    final aliceGets = nextMessage(alice);
    await bob.sendMessage(recipientId: await _idOf(alice), text: 'got it');
    expect((await aliceGets).textContent, 'got it');

    expect(bridge.droppedSends, isEmpty,
        reason: 'every datagram must be addressed to a resolvable destination');
    expect(bridge.deliveredCount, greaterThan(0));
  });

  test('destinations learned from the datagram header stay clean', () async {
    await introduce();
    final aliceGets = nextMessage(alice);
    await bob.sendMessage(recipientId: await _idOf(alice), text: 'reply');
    await aliceGets;

    // We negotiate SAM 3.3, so every inbound datagram's header line is
    // "<dest> FROM_PORT=0 TO_PORT=0". Whatever the receiver takes from that
    // line is PERSISTED as the peer's address and used for every later reply.
    final aliceOnBob = await bob.storage.getContact(await _idOf(alice));
    expect(aliceOnBob?.i2pDestination, isNotNull,
        reason: 'Bob must have learned where to reach Alice');
    expect(aliceOnBob!.i2pDestination, i2pOf(alice).myDestination,
        reason: 'a destination with the header options glued on is not an '
            'address — SAM drops the send and the chat goes one-way');
    expect(looksLikeI2pDestination(aliceOnBob.i2pDestination!), isTrue);

    final bobOnAlice = await alice.storage.getContact(await _idOf(bob));
    expect(bobOnAlice!.i2pDestination, i2pOf(bob).myDestination,
        reason: 'learning must never overwrite the QR-scanned address with a '
            'worse one');
  });

  test('secret chat: delivered live, I2P-only, filed under its own history',
      () async {
    await introduce();
    final aliceId = await _idOf(alice);
    final bobId = await _idOf(bob);

    final aliceGets = alice.incomingMessages
        .firstWhere((m) => m.conversationId == secretConversationId(bobId))
        .timeout(const Duration(seconds: 60));

    final sent = await bob.sendSecretText(aliceId, 'this one is off the record');
    expect(sent.status, MessageStatus.sent,
        reason: 'a secret send is only "sent" once the peer I2P layer ACKs it');

    final got = await aliceGets;
    expect(got.textContent, 'this one is off the record');
    expect(got.conversationId, secretConversationId(bobId),
        reason: 'the secret chat is a separate history, not the normal chat');

    // The sender files its own copy under the same conversation.
    final mine = await bob.storage.getMessages(secretConversationId(aliceId));
    expect(mine.map((m) => m.textContent), contains('this one is off the record'));

    // And it never appears in the ordinary conversation with that contact.
    final normal = await alice.storage.getMessages(bobId);
    expect(normal.map((m) => m.textContent),
        isNot(contains('this one is off the record')));

    // Every DATA frame and every ACK was addressed to something SAM could
    // route. A polluted destination still "works" here — the ARQ hides it by
    // retransmitting — so without this the only symptom is a send that takes
    // 37 seconds instead of one, which no one notices until it is a field bug.
    expect(bridge.droppedSends, isEmpty,
        reason: 'the ACK travels to the source dest read off the datagram '
            'header — if that is not a bare destination, it goes nowhere');
  });

  test('the ACK layer rides out datagram loss', () async {
    await introduce();
    final aliceId = await _idOf(alice);
    final bobId = await _idOf(bob);

    // I2P datagrams are fire-and-forget. Drop two in five, both directions —
    // so DATA frames AND their ACKs go missing — and the send must still
    // confirm, because ReliableI2p retransmits until it hears back.
    bridge.lossRate = 0.4;

    final aliceGets = alice.incomingMessages
        .firstWhere((m) => m.conversationId == secretConversationId(bobId))
        .timeout(const Duration(seconds: 90));

    final sent = await bob.sendSecretText(aliceId, 'through the noise');
    expect(sent.status, MessageStatus.sent);
    expect((await aliceGets).textContent, 'through the noise');
    expect(bridge.lostCount, greaterThan(0),
        reason: 'the run is only meaningful if loss actually happened');
  });

  group('secret-path probe — the gate on the secret chat', () {
    test('says ready when the peer is actually there', () async {
      await introduce();
      expect(await bob.probeSecretChannel(await _idOf(alice)),
          SecretPathStatus.ready);
    });

    test('is invisible to the peer — no message, no bubble, no event',
        () async {
      await introduce();
      final aliceId = await _idOf(alice);
      final bobId = await _idOf(bob);

      // Let the handshake tail (ack, preKeyShare, connectivityInfo) finish, or
      // we would be measuring that traffic instead of the probe.
      await Future.delayed(const Duration(seconds: 2));
      final normalBefore = (await alice.storage.getMessages(bobId)).length;

      var sawSomething = false;
      final sub = alice.incomingMessages.listen((_) => sawSomething = true);

      expect(await bob.probeSecretChannel(aliceId), SecretPathStatus.ready);
      await Future.delayed(const Duration(milliseconds: 500));
      await sub.cancel();

      expect(sawSomething, isFalse,
          reason: 'an empty reliable datagram is ACKed by the transport and '
              'dropped before anything reaches the app');
      expect(await alice.storage.getMessages(secretConversationId(bobId)),
          isEmpty,
          reason: 'probing must not create the secret conversation');
      expect((await alice.storage.getMessages(bobId)).length, normalBefore,
          reason: 'nor add anything to the ordinary one');
    });

    test('says peerUnreachable when nothing gets through', () async {
      await introduce();
      // The peer is up but the path is not: every datagram dies in transit,
      // which is what an I2P chat looks like when tunnels are gone.
      bridge.lossRate = 1.0;
      expect(
        await bob.probeSecretChannel(await _idOf(alice),
            timeout: const Duration(seconds: 2)),
        SecretPathStatus.peerUnreachable,
      );
    });

    test('recovers on its own once the path is back', () async {
      await introduce();
      final aliceId = await _idOf(alice);
      bridge.lossRate = 1.0;
      expect(
          await bob.probeSecretChannel(aliceId,
              timeout: const Duration(seconds: 2)),
          SecretPathStatus.peerUnreachable);
      // This is what the 30s re-probe behind the locked composer is for.
      bridge.lossRate = 0.0;
      expect(await bob.probeSecretChannel(aliceId), SecretPathStatus.ready);
    });

    test('a cold local router is not blamed on the peer', () async {
      // Nothing has ever come back over I2P and the session is seconds old:
      // an unanswered probe is evidence about our own router, not about them.
      // Reporting peerUnreachable here sends the user to check the wrong phone.
      bridge.lossRate = 1.0;
      final bobAddress = await bob.getMyContactAddress();
      await alice.addContact(contactAddress: bobAddress!, nickname: 'Bob');

      expect(
        await alice.probeSecretChannel(await _idOf(bob),
            timeout: const Duration(seconds: 2)),
        SecretPathStatus.i2pWarmingUp,
      );
    });

    test('once I2P has proven itself, silence IS about the peer', () async {
      // introduce() puts real datagrams through in both directions, so our
      // tunnels are known good. Now the same total loss means something else.
      await introduce();
      bridge.lossRate = 1.0;
      expect(
        await bob.probeSecretChannel(await _idOf(alice),
            timeout: const Duration(seconds: 2)),
        SecretPathStatus.peerUnreachable,
      );
    });

    test('says noDestination for a contact we have no I2P address for',
        () async {
      await introduce();
      expect(await bob.probeSecretChannel('3zzzNoSuchContactId'),
          SecretPathStatus.noDestination);
    });
  });

  test('a datagram to an unknown destination vanishes without a word',
      () async {
    await introduce();
    final i2p = i2pOf(bob);

    // This is the failure mode the bridge exists to make visible: the send
    // "succeeds" from the app's side and nothing arrives, forever. The await
    // below completing IS the finding — publishToDest only checks that the
    // local UDP socket took the packet, so an unroutable address is reported
    // to the caller as a successful send.
    await i2p.publishToDest(
        dest: 'NOT-A-REAL-DESTINATION', data: Uint8List.fromList([1, 2, 3]));
    await Future.delayed(const Duration(milliseconds: 100));

    expect(bridge.destinations, isNot(contains('NOT-A-REAL-DESTINATION')),
        reason: 'no session owns that address, so nothing could receive it');
    expect(bridge.droppedSends, contains('NOT-A-REAL-DESTINATION'),
        reason: 'the bridge saw it and dropped it — only the lab can tell');
  });
}

Future<String> _idOf(PhantomCore core) async => core.myId;

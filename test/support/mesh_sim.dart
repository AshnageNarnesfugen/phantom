import 'dart:collection';
import 'dart:typed_data';

import 'package:phantom_messenger/transport/bluetooth/mesh_protocol.dart';
import 'package:phantom_messenger/transport/bluetooth/mesh_router.dart';
import 'package:phantom_messenger/transport/bluetooth/message_store.dart';

/// In-memory multi-node BLE mesh simulator.
///
/// Wires REAL [MeshRouter] + [MessageStore] instances (the platform-agnostic
/// routing core) through a fake radio with an arbitrary, mutable topology, so
/// the flood/relay/dedup/TTL/store-and-forward/ACK logic can be exercised
/// end-to-end without any Bluetooth stack — the same trick the loopback lab
/// uses for the internet transports.
///
/// It mirrors exactly what [BluetoothMeshTransport] does with a RouterResult:
///   - packets the router decides to relay (its `packetsToRelay` stream) are
///     re-broadcast to every current neighbour;
///   - `ackToSend` / `pendingToSend` are unicast back to the source peer;
///   - `deliveredEnvelopes` are collected per node (delivery to the app).
/// Connecting two nodes exchanges ANNOUNCE both ways (both sides scan+connect
/// in the field), which is what drives store-and-forward.
class MeshSim {
  /// When set, every radio transmission is split into [chunkSize]-byte
  /// MeshFragment frames and reassembled by the receiver, faithfully
  /// reproducing the BLE MTU limit — the condition under which the missing
  /// reassembly layer silently dropped every large packet. null = no MTU
  /// limit (whole frames), the default for routing-only tests.
  final int? chunkSize;

  MeshSim({this.chunkSize});

  final Map<String, SimNode> _nodes = {};
  // Undirected adjacency: id → set of neighbour ids currently "in range".
  final Map<String, Set<String>> _adj = {};
  int _fragGroup = 0;

  // Pending radio transmissions (fromId, toId, bytes), drained by [pump].
  final Queue<_Tx> _tx = Queue<_Tx>();

  // Every packet that crossed the radio, for assertions / debugging.
  final List<({String from, String to, MeshPacket packet})> trace = [];

  /// Safety valve: a routing loop that dedup fails to bound would otherwise
  /// hang the test. Generous vs any legitimate flood in these topologies.
  int _steps = 0;
  static const _maxSteps = 100000;

  SimNode addNode(String phantomId) {
    final store = MessageStore();
    final router = MeshRouter(myPhantomId: phantomId, store: store);
    final node = SimNode._(phantomId, router, store);
    _nodes[phantomId] = node;
    _adj[phantomId] = {};

    // Relay: whatever this node's router floods goes to every neighbour.
    node._relaySub = router.packetsToRelay.listen((packet) {
      _broadcast(phantomId, packet.serialize());
    });
    // Delivery to app.
    node._delivSub = router.deliveredEnvelopes.listen(node.received.add);
    return node;
  }

  /// Enqueues [bytes] from [fromId] to every current neighbour, applying MTU
  /// fragmentation when [chunkSize] is set — using the SAME production
  /// MeshFragment code the transport uses.
  void _broadcast(String fromId, Uint8List bytes) {
    for (final n in _adj[fromId]!) {
      _unicast(fromId, n, bytes);
    }
  }

  void _unicast(String fromId, String toId, Uint8List bytes) {
    if (chunkSize == null) {
      _tx.add(_Tx(fromId, toId, bytes));
      return;
    }
    final frames = MeshFragment.split(
      bytes,
      chunkSize: chunkSize! - kFragHeaderSize > 0 ? chunkSize! - kFragHeaderSize : 1,
      groupId: _fragGroup = (_fragGroup + 1) & 0xFFFF,
    );
    for (final f in frames) {
      _tx.add(_Tx(fromId, toId, f));
    }
  }

  /// Brings two nodes into range and performs the ANNOUNCE handshake both
  /// ways (each side learns the other + flushes store-and-forward for it).
  Future<void> connect(String a, String b) async {
    _adj[a]!.add(b);
    _adj[b]!.add(a);
    _unicast(a, b, _nodes[a]!.router.buildAnnounce().serialize());
    _unicast(b, a, _nodes[b]!.router.buildAnnounce().serialize());
    await pump();
  }

  /// Takes two nodes out of range.
  void disconnect(String a, String b) {
    _adj[a]?.remove(b);
    _adj[b]?.remove(a);
  }

  /// App-level send from [fromId] to recipient [toId]. Mirrors
  /// BluetoothMeshTransport.sendEncrypted: prepareOutgoing + broadcast.
  Future<void> send(String fromId, String toId, Uint8List envelope,
      {String? messageId}) async {
    final node = _nodes[fromId]!;
    final packet = node.router.prepareOutgoing(
      fullMessageId: messageId ?? _uuid(fromId, toId, envelope),
      recipientPhantomId: toId,
      encryptedEnvelope: envelope,
    );
    _broadcast(fromId, packet.serialize());
    await pump();
  }

  /// Drains the radio until quiescent (dedup guarantees termination).
  Future<void> pump() async {
    while (_tx.isNotEmpty) {
      if (++_steps > _maxSteps) {
        throw StateError('MeshSim: routing did not settle — likely a relay '
            'loop dedup failed to bound');
      }
      final t = _tx.removeFirst();
      await _deliver(t);
      // Let the router's stream listeners (relay/delivery) run before we
      // continue draining, so their enqueues are interleaved in order.
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _deliver(_Tx t) async {
    // Node out of range now (edge removed mid-flight) → packet lost, as a
    // real radio would.
    if (!_adj[t.to]!.contains(t.from)) return;
    final node = _nodes[t.to]!;

    // Reassemble MTU fragments with the production reassembler; incomplete
    // groups yield null until the last fragment arrives.
    final assembled = node.reassembler.offer(t.bytes);
    if (assembled == null) return;

    final MeshPacket packet;
    try {
      packet = MeshPacket.deserialize(assembled);
    } catch (_) {
      return; // corrupt frame dropped
    }
    trace.add((from: t.from, to: t.to, packet: packet));

    final fromHint = _nodes[t.from]!.hintHex;
    final result = await node.router.process(packet, fromPeerHint: fromHint);

    // Unicast the relay-ACK back to whoever sent us the packet.
    if (result.ackToSend != null) {
      _unicast(t.to, t.from, result.ackToSend!);
    }
    // Store-and-forward: hand queued packets to the peer that just announced.
    for (final p in result.pendingToSend) {
      _unicast(t.to, t.from, p.serialize());
    }
  }

  SimNode node(String id) => _nodes[id]!;

  static String _uuid(String a, String b, Uint8List env) {
    // Deterministic-ish 32 hex chars from inputs (first 4 bytes = mesh msgId).
    final h = MeshPacket.nodeHint('$a>$b:${env.length}:${env.isEmpty ? 0 : env.first}');
    final head = h.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '$head${'0' * 24}';
  }

  Future<void> dispose() async {
    for (final n in _nodes.values) {
      await n._relaySub?.cancel();
      await n._delivSub?.cancel();
      await n.router.dispose();
      await n.store.dispose();
    }
  }
}

class SimNode {
  final String id;
  final MeshRouter router;
  final MessageStore store;
  final List<Uint8List> received = [];
  // Production reassembler — the same one the transport uses on receive.
  final MeshReassembler reassembler = MeshReassembler();
  dynamic _relaySub;
  dynamic _delivSub;

  SimNode._(this.id, this.router, this.store);

  String get hintHex => MeshPacket.nodeHint(id)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  /// Convenience: did this node deliver [envelope] to its app exactly once?
  int timesReceived(Uint8List envelope) =>
      received.where((r) => _eq(r, envelope)).length;

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Tx {
  final String from;
  final String to;
  final Uint8List bytes;
  _Tx(this.from, this.to, this.bytes);
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/transport.dart'
    show TransportException;
import 'package:phantom_messenger/transport/transport_manager_v2.dart';
import 'package:phantom_messenger/transport/bluetooth/bluetooth_mesh_transport.dart';
import 'package:phantom_messenger/transport/bluetooth/mesh_router.dart';
import 'package:phantom_messenger/transport/bluetooth/message_store.dart';

/// A secret chat's whole point is that the frame rides I2P or nothing. The
/// internet branch already refused to fall back to BLE; the OTHER two modes
/// did not — with no internet the frame went out over the BLE mesh, and with
/// nothing at all it was parked in the 72h store, which flushes over Waku/IPFS
/// the moment connectivity returns. Both leak the IP the mode exists to hide.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessageStore store;
  late TransportManagerV2 mgr;

  const bob = 'bob-phantom-id';

  setUp(() {
    store = MessageStore();
    final router = MeshRouter(myPhantomId: 'alice', store: store);
    mgr = TransportManagerV2(
      btMesh: BluetoothMeshTransport(
          myPhantomId: 'alice', router: router, store: store),
      store: store,
      // No internet publish wired: the manager stays in its default offline
      // mode, which is exactly the branch under test.
      internetPublish: null,
    );
  });

  test('offline: a secret frame is refused, never queued in the store',
      () async {
    await expectLater(
      mgr.publish(
        recipientId: bob,
        fullMessageId: 'a1b2c3d4e5f60718',
        encryptedEnvelope: Uint8List.fromList([1, 2, 3, 4]),
        secret: true,
      ),
      throwsA(isA<TransportException>()),
      reason: 'no transport → a secret send fails closed',
    );
    expect(store.pendingCount, 0,
        reason: 'a queued secret frame would later flush over Waku/IPFS');
  });

  test('offline: an ordinary frame still queues normally', () async {
    final result = await mgr.publish(
      recipientId: bob,
      fullMessageId: '00112233445566ff',
      encryptedEnvelope: Uint8List.fromList([5, 6, 7, 8]),
    );
    expect(result.queued, isTrue);
    expect(store.pendingCount, 1);
  });
}

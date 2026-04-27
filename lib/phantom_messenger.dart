/// Phantom Messenger — Public API
///
/// Import this file to access the full core:
///
/// ```dart
/// import 'package:phantom_messenger/phantom_messenger.dart';
/// ```
library;

export 'core/phantom_core.dart';
export 'core/identity/identity.dart';
export 'core/crypto/x3dh.dart' hide InvalidPhantomIdException;
export 'core/crypto/double_ratchet.dart';
export 'core/protocol/message.dart';
export 'core/storage/phantom_storage.dart';
export 'transport/transport.dart';
export 'transport/transport_manager_v2.dart' hide IncomingEnvelope;
export 'transport/bluetooth/mesh_protocol.dart';
export 'transport/bluetooth/mesh_router.dart';
export 'transport/bluetooth/message_store.dart';
export 'transport/bluetooth/bluetooth_mesh_transport.dart';

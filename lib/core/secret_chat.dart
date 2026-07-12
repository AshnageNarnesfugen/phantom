import 'dart:typed_data';

import 'protocol/message.dart';

/// Secret chats — a Telegram-style dedicated end-to-end conversation whose
/// traffic rides I2P ONLY (the peer never sees your IP) and only works while
/// both sides are online (no store-and-forward, so no metadata sits anywhere).
///
/// A secret conversation is a distinct conversation id (`sec_<phantomId>`) so it
/// has its own separate history, apart from the normal chat with that contact.
/// It reuses the existing Double Ratchet session — the "secret" is the routing
/// (I2P-only), the gating (both-online), and the separate space; the crypto is
/// the same forward-secret ratchet everything else uses.

const String secretConvPrefix = 'sec_';

String secretConversationId(String phantomId) => '$secretConvPrefix$phantomId';

bool isSecretConversation(String conversationId) =>
    conversationId.startsWith(secretConvPrefix);

/// The underlying contact phantomId behind a secret conversation id (or the
/// id unchanged if it isn't a secret conversation).
String secretContactId(String conversationId) => isSecretConversation(conversationId)
    ? conversationId.substring(secretConvPrefix.length)
    : conversationId;

/// `[1B innerType][innerContent]` — a secret message wraps an ordinary message
/// (text/image/…) so the receiver files it under the secret conversation.
Uint8List packSecretEnvelope(MessageType innerType, Uint8List content) {
  final out = Uint8List(1 + content.length)
    ..[0] = innerType.code
    ..setAll(1, content);
  return out;
}

({MessageType innerType, Uint8List content})? unpackSecretEnvelope(
    Uint8List envelope) {
  if (envelope.isEmpty) return null;
  try {
    return (
      innerType: MessageType.fromCode(envelope[0]),
      content: Uint8List.sublistView(envelope, 1),
    );
  } catch (_) {
    return null;
  }
}

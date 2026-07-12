import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/core/protocol/message.dart';
import 'package:phantom_messenger/core/secret_chat.dart';

/// Secret chats live in their own conversation space and wrap an inner message
/// so the receiver files it apart from the normal chat. These pin the id scheme
/// and the envelope round-trip (a bug here would cross-file secret and normal
/// messages, or corrupt the inner content).
void main() {
  test('conversation id scheme is reversible and distinct from the normal one',
      () {
    const phantom = '3gfTRPXBzRvAVMwPsqzwof41TEkUp4fLH9hbFPSZgURhq48UHNq';
    final sec = secretConversationId(phantom);
    expect(sec, 'sec_$phantom');
    expect(sec, isNot(phantom), reason: 'secret history is separate');
    expect(isSecretConversation(sec), isTrue);
    expect(isSecretConversation(phantom), isFalse);
    expect(secretContactId(sec), phantom);
    expect(secretContactId(phantom), phantom, reason: 'passthrough for non-secret');
  });

  test('envelope round-trips inner type + content', () {
    final content = Uint8List.fromList(List.generate(300, (i) => (i * 5) & 0xff));
    final packed = packSecretEnvelope(MessageType.image, content);
    final back = unpackSecretEnvelope(packed);
    expect(back, isNotNull);
    expect(back!.innerType, MessageType.image);
    expect(back.content, content);
  });

  test('text envelope round-trips', () {
    final packed = packSecretEnvelope(
        MessageType.text, Uint8List.fromList('hola en secreto'.codeUnits));
    final back = unpackSecretEnvelope(packed)!;
    expect(back.innerType, MessageType.text);
    expect(String.fromCharCodes(back.content), 'hola en secreto');
  });

  test('unpack rejects empty', () {
    expect(unpackSecretEnvelope(Uint8List(0)), isNull);
  });

  test('empty inner content is valid (e.g. a marker message)', () {
    final packed = packSecretEnvelope(MessageType.text, Uint8List(0));
    final back = unpackSecretEnvelope(packed)!;
    expect(back.innerType, MessageType.text);
    expect(back.content, isEmpty);
  });
}

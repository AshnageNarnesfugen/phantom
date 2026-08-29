import 'package:flutter_test/flutter_test.dart';
import 'package:phantom_messenger/transport/transport.dart'
    show looksLikeI2pDestination;

/// A destination reaches us from a scanned QR, a peer's connectivityInfo, or
/// the source line of an inbound SAM datagram. Only the first two are
/// structured. We negotiate SAM 3.3, whose forwarded-datagram header is
/// "<dest> FROM_PORT=n TO_PORT=n" — parsing that whole line as the destination
/// wrote a broken address into the contact record, and every later reply was
/// addressed to it. SAM drops such a send silently, so the symptom is a
/// one-way conversation with a clean log.
void main() {
  // 516 chars is the length of a bare (certificate-less) I2P destination.
  final dest = '${'aB3~z-Qx' * 64}AAAA';

  test('a bare destination validates', () {
    expect(dest.length, 516);
    expect(looksLikeI2pDestination(dest), isTrue);
  });

  test('a SAM 3.2+ header line does NOT validate as a destination', () {
    expect(looksLikeI2pDestination('$dest FROM_PORT=0 TO_PORT=0'), isFalse);
  });

  test('the destination is the first token of the header line', () {
    expect('$dest FROM_PORT=0 TO_PORT=0'.split(' ').first, dest);
    // SAM 3.0/3.1 sends the bare dest — same parse, no-op.
    expect(dest.split(' ').first, dest);
  });

  test('short, empty and b32 forms are rejected', () {
    expect(looksLikeI2pDestination(''), isFalse);
    expect(looksLikeI2pDestination('abcd.b32.i2p'), isFalse);
    expect(looksLikeI2pDestination(dest.substring(0, 515)), isFalse);
  });
}

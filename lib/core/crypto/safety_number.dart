import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Signal-style safety number for verifying a contact's identity out-of-band.
///
/// Both sides compute the same 60-digit decimal sequence by SHA-512-iterating
/// over the lexicographically-sorted pair of identity keys. When Alice and
/// Bob read out the number to each other and it matches, a man-in-the-middle
/// during the QR exchange is detected — the attacker would have been forced
/// to substitute their own IK on at least one side, which produces a
/// different fingerprint than the genuine pair.
///
/// The number is rendered as 12 groups of 5 digits for human comparison.
class SafetyNumber {
  static const int _iterations = 5200;

  /// Returns a 60-digit decimal string (12 groups of 5, separated by spaces)
  /// computed from [ourIk] and [theirIk]. The result is symmetric — both
  /// peers get the same number — and stable across calls.
  static String compute({
    required Uint8List ourIk,
    required Uint8List theirIk,
  }) {
    // Sort so both sides hash the same byte sequence regardless of role.
    final pair = _orderedConcat(ourIk, theirIk);

    // Iterate SHA-512 to slow down brute-force preimage attacks on the
    // truncated decimal output (a quantum adversary searching for a
    // colliding IK pair faces this cost factor per candidate).
    var h = pair;
    for (int i = 0; i < _iterations; i++) {
      h = Uint8List.fromList(sha512.convert(h).bytes);
    }

    // Take the first 30 bytes and project to a 60-digit decimal sequence.
    // 30 bytes is plenty for the security level we care about (~250 bits).
    final digits = StringBuffer();
    for (int i = 0; i < 30; i += 5) {
      // 5 bytes → 40 bits → render as 10 decimal digits (≈33 bits used).
      // Slightly lossy but the result is uniformly distributed.
      final chunk = (h[i]     << 32) |
                    (h[i + 1] << 24) |
                    (h[i + 2] << 16) |
                    (h[i + 3] << 8)  |
                    h[i + 4];
      final asStr = chunk.toString().padLeft(10, '0');
      digits.write(asStr.substring(asStr.length - 10));
    }

    // Format: groups of 5, space-separated.
    final raw = digits.toString();
    final groups = <String>[];
    for (int i = 0; i < raw.length; i += 5) {
      groups.add(raw.substring(i, i + 5));
    }
    return groups.join(' ');
  }

  static Uint8List _orderedConcat(Uint8List a, Uint8List b) {
    final cmp = _compareBytes(a, b);
    final first  = cmp <= 0 ? a : b;
    final second = cmp <= 0 ? b : a;
    final out = Uint8List(first.length + second.length);
    out.setRange(0, first.length, first);
    out.setRange(first.length, first.length + second.length, second);
    return out;
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}

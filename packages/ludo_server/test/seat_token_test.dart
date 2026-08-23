// Conformance tests for the seat token half of docs/PROTOCOL.md section 2:
// "Long, opaque, never shown to a human... 32 bytes from a CSPRNG,
// base64url. Issued once when a seat is taken, and it is the only thing
// that reclaims that seat after a disconnect."
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

final RegExp _base64Url = RegExp(r'^[A-Za-z0-9_-]+$');

void main() {
  group('generateSeatToken', () {
    test('produces a 43 character base64url string', () {
      final Random secure = Random.secure();
      for (int i = 0; i < 200; i++) {
        final String token = generateSeatToken(secure);
        expect(token.length, 43,
            reason: 'token "$token" (draw $i) is the '
                'wrong length for 32 CSPRNG bytes of unpadded base64url');
        expect(_base64Url.hasMatch(token), isTrue,
            reason: 'token "$token" '
                '(draw $i) contains a character outside [A-Za-z0-9_-]');
      }
    });

    test('does not repeat across many draws', () {
      // 32 bytes of entropy makes a collision astronomically unlikely; a
      // repeat here means the generator is not drawing fresh randomness,
      // not bad luck.
      final Random secure = Random.secure();
      final Set<String> seen = <String>{};
      const int sampleSize = 1000;
      for (int i = 0; i < sampleSize; i++) {
        seen.add(generateSeatToken(secure));
      }
      expect(seen.length, sampleSize,
          reason: 'expected $sampleSize distinct '
              'tokens over $sampleSize draws, got ${seen.length} distinct '
              'values');
    });
  });

  group('isWellFormedSeatToken', () {
    test('accepts a generated token', () {
      final String token = generateSeatToken(Random.secure());
      expect(isWellFormedSeatToken(token), isTrue,
          reason: 'generated token '
              '"$token" was rejected as malformed');
    });

    test('rejects the empty string', () {
      expect(isWellFormedSeatToken(''), isFalse);
    });

    test('rejects a short token', () {
      const String short = 'AbCdEfGhIj';
      expect(isWellFormedSeatToken(short), isFalse,
          reason: '"$short" is '
              '${short.length} characters, well under the 43 a real token has, '
              'and must be rejected');
    });

    test('rejects a token containing a character outside [A-Za-z0-9_-]', () {
      final String token = generateSeatToken(Random.secure());
      final String withPlus = '+${token.substring(1)}';
      expect(isWellFormedSeatToken(withPlus), isFalse,
          reason: '"$withPlus" '
              "contains '+', a standard base64 character that base64url "
              'replaces with "-"');
    });
  });
}

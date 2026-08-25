// Conformance tests for the room code half of docs/PROTOCOL.md section 2:
// "Short, human-readable, dictatable over a phone call... 6 characters from
// the alphabet ABCDEFGHJKLMNPQRSTUVWXYZ23456789 -- 32 symbols, no 0/O, no
// 1/I/L. Generated from a CSPRNG, never sequential."
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

void main() {
  group('roomCodeAlphabet', () {
    test('is exactly 32 distinct symbols', () {
      expect(roomCodeAlphabet.length, 32);
      expect(roomCodeAlphabet.split('').toSet().length, 32);
    });

    test('excludes 0, O, 1 and I', () {
      expect(roomCodeAlphabet.contains('0'), isFalse);
      expect(roomCodeAlphabet.contains('O'), isFalse);
      expect(roomCodeAlphabet.contains('1'), isFalse);
      expect(roomCodeAlphabet.contains('I'), isFalse);
    });

    test(
        'includes L, because with 1 absent there is nothing for it to be '
        'confused with', () {
      expect(roomCodeAlphabet.contains('L'), isTrue);
    });
  });

  test('roomCodeLength is 6', () {
    expect(roomCodeLength, 6);
  });

  group('generateRoomCode', () {
    test(
        'produces a code of roomCodeLength characters, all in the '
        'alphabet', () {
      final Random secure = Random.secure();
      for (int i = 0; i < 200; i++) {
        final String code = generateRoomCode(secure);
        expect(code.length, roomCodeLength,
            reason: 'code "$code" (draw $i) '
                'is the wrong length');
        for (final String char in code.split('')) {
          expect(roomCodeAlphabet.contains(char), isTrue,
              reason: 'code '
                  '"$code" (draw $i) contains "$char", which is outside '
                  'roomCodeAlphabet');
        }
      }
    });

    test('does not repeat over a large sample', () {
      // Sample size chosen from the birthday bound: with n draws over a
      // space of N = 32^6 codes, collision probability is roughly
      // n^2 / (2N). At n = 2000 and N = 32^6 (~1.07e9) that is about
      // 0.19%, low enough that this test does not flake in practice while
      // still being large enough to actually exercise the generator.
      final Random secure = Random.secure();
      final Set<String> seen = <String>{};
      const int sampleSize = 2000;
      for (int i = 0; i < sampleSize; i++) {
        seen.add(generateRoomCode(secure));
      }
      expect(seen.length, sampleSize,
          reason: 'expected $sampleSize distinct '
              'codes over $sampleSize draws, got ${seen.length} distinct values '
              '-- rerun to confirm this is not a one in ~500 birthday '
              'collision before treating it as a defect');
    });
  });

  group('isWellFormedRoomCode', () {
    late String goodCode;

    setUp(() {
      goodCode = generateRoomCode(Random.secure());
    });

    test('accepts a well-formed code', () {
      expect(isWellFormedRoomCode(goodCode), isTrue,
          reason: 'generated '
              'code "$goodCode" was rejected as malformed');
    });

    test('rejects the empty string', () {
      expect(isWellFormedRoomCode(''), isFalse);
    });

    test('rejects a 5 character string', () {
      final String short = goodCode.substring(0, 5);
      expect(isWellFormedRoomCode(short), isFalse,
          reason: '"$short" is 5 '
              'characters and must be rejected');
    });

    test('rejects a 7 character string', () {
      final String long = '${goodCode}A';
      expect(isWellFormedRoomCode(long), isFalse,
          reason: '"$long" is 7 '
              'characters and must be rejected');
    });

    test('rejects a lowercase code', () {
      final String lower = goodCode.toLowerCase();
      expect(isWellFormedRoomCode(lower), isFalse,
          reason: '"$lower" is '
              'lowercase and must be rejected even though its uppercase form '
              'is well formed');
    });

    test('rejects a code containing a character outside the alphabet', () {
      final String withZero = '0${goodCode.substring(1)}';
      expect(isWellFormedRoomCode(withZero), isFalse,
          reason: '"$withZero" '
              "contains '0', which is not in roomCodeAlphabet");
    });
  });
}

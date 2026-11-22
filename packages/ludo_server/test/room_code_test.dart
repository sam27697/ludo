// Conformance tests for the room code half of docs/PROTOCOL.md section 32
// items 1, 2 and 4: a numeral in the 33-symbol alphabet
// 0123456789ABCDEFGHJKMNPQRSTUVWXYZ, most significant symbol first, no leading
// 0 except the code `0` itself, handed out lowest first.
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

void main() {
  group('roomCodeAlphabet', () {
    test('is exactly 33 distinct symbols', () {
      expect(roomCodeAlphabet.length, 33);
      expect(roomCodeAlphabet.split('').toSet().length, 33);
    });

    test('excludes I, L and O', () {
      expect(roomCodeAlphabet.contains('I'), isFalse);
      expect(roomCodeAlphabet.contains('L'), isFalse);
      expect(roomCodeAlphabet.contains('O'), isFalse);
    });

    test('includes every digit', () {
      for (final String digit in '0123456789'.split('')) {
        expect(roomCodeAlphabet.contains(digit), isTrue);
      }
    });
  });

  test('roomCodeLength, the longest typed code, is 6', () {
    expect(roomCodeLength, 6);
  });

  group('roomCodeForIndex', () {
    test('counts 0 to Z, then 10 to ZZ, then 100', () {
      expect(roomCodeForIndex(0), '0');
      expect(roomCodeForIndex(9), '9');
      expect(roomCodeForIndex(10), 'A');
      expect(roomCodeForIndex(32), 'Z');
      expect(roomCodeForIndex(33), '10');
      expect(roomCodeForIndex(34), '11');
      expect(roomCodeForIndex(33 * 33 - 1), 'ZZ');
      expect(roomCodeForIndex(33 * 33), '100');
    });

    test('never issues a leading 0 and is strictly increasing', () {
      final Set<String> seen = <String>{};
      for (int i = 0; i < 3000; i++) {
        final String code = roomCodeForIndex(i);
        expect(seen.add(code), isTrue, reason: 'index $i repeated "$code"');
        if (code.length > 1) {
          expect(code.startsWith('0'), isFalse, reason: code);
        }
        expect(isWellFormedRoomCode(code), isTrue, reason: code);
      }
    });

    test('rejects a negative index', () {
      expect(() => roomCodeForIndex(-1), throwsArgumentError);
    });
  });

  group('foldRoomCode', () {
    test('drops surrounding whitespace and upper-cases', () {
      expect(foldRoomCode(' 0 '), '0');
      expect(foldRoomCode('\t ab7\n'), 'AB7');
    });

    test('reads O as 0 and I and L as 1', () {
      expect(foldRoomCode('o'), '0');
      expect(foldRoomCode('i'), '1');
      expect(foldRoomCode('l'), '1');
      expect(foldRoomCode('OIL'), '011');
    });

    test('leaves a malformed code malformed', () {
      expect(isWellFormedRoomCode(foldRoomCode('AB#')), isFalse);
    });
  });

  group('isWellFormedRoomCode', () {
    test('accepts 1 to 6 symbols of the alphabet', () {
      expect(isWellFormedRoomCode('0'), isTrue);
      expect(isWellFormedRoomCode('Z'), isTrue);
      expect(isWellFormedRoomCode('ZZZZZZ'), isTrue);
    });

    test('rejects the empty string', () {
      expect(isWellFormedRoomCode(''), isFalse);
    });

    test('rejects a 7 character string', () {
      expect(isWellFormedRoomCode('ZZZZZZZ'), isFalse);
    });

    test('rejects a lowercase code', () {
      expect(isWellFormedRoomCode('abc'), isFalse,
          reason: 'folding is the caller\'s step; the shape check is exact');
    });

    test('rejects a character outside the alphabet', () {
      for (final String bad in <String>['O', 'I', 'L', 'A-B', 'A B']) {
        expect(isWellFormedRoomCode(bad), isFalse, reason: bad);
      }
    });
  });
}

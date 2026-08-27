import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/room_code.dart';

void main() {
  group('normalizeRoomCode', () {
    test('upper-cases lower case input', () {
      expect(normalizeRoomCode('ab23cd'), 'AB23CD');
    });

    test('strips a dash dictated over a phone call', () {
      expect(normalizeRoomCode('AB2-3CD'), 'AB23CD');
    });

    test('strips spaces', () {
      expect(normalizeRoomCode('AB 23 CD'), 'AB23CD');
    });

    test('combines case, spaces and dashes', () {
      expect(normalizeRoomCode('ab2-3 cd'), 'AB23CD');
    });
  });

  group('isValidRoomCode', () {
    test('accepts a code drawn entirely from the alphabet', () {
      expect(isValidRoomCode('AB23CD'), isTrue);
    });

    test('accepts a code containing L', () {
      // L is deliberately kept in the alphabet: with 1 gone there is nothing
      // left for it to be confused with. A code containing L must validate.
      expect(isValidRoomCode('ABLCDE'), isTrue);
    });

    test('rejects a code containing 0', () {
      expect(isValidRoomCode('AB023C'), isFalse);
    });

    test('rejects a code containing O', () {
      expect(isValidRoomCode('ABOZ3C'), isFalse);
    });

    test('rejects a code containing 1', () {
      expect(isValidRoomCode('AB1Z3C'), isFalse);
    });

    test('rejects a code containing I', () {
      expect(isValidRoomCode('ABIZ3C'), isFalse);
    });

    test('rejects a code that is too short', () {
      expect(isValidRoomCode('AB23C'), isFalse);
    });

    test('rejects a code that is too long', () {
      expect(isValidRoomCode('AB23CDE'), isFalse);
    });

    test('rejects an empty string', () {
      expect(isValidRoomCode(''), isFalse);
    });

    test(
      'normalize then validate accepts a dictated, dashed, lower case code',
      () {
        expect(isValidRoomCode(normalizeRoomCode('ab2-3cd')), isTrue);
      },
    );
  });
}

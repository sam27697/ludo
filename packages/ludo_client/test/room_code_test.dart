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

    test('a code containing L is valid only once L is folded to 1', () {
      // Section 32 item 1: the alphabet has no I, L or O. A typed L is read
      // as 1 (item 4), so the normalised code is valid and the raw one is not.
      expect(isValidRoomCode('ABLCDE'), isFalse);
      expect(isValidRoomCode(normalizeRoomCode('ABLCDE')), isTrue);
    });

    test('accepts a code containing 0', () {
      // Section 32 item 1: 0 is a symbol now.
      expect(isValidRoomCode('AB023C'), isTrue);
    });

    test('rejects a code containing O', () {
      expect(isValidRoomCode('ABOZ3C'), isFalse);
    });

    test('accepts a code containing 1', () {
      // Section 32 item 1: 1 is a symbol now.
      expect(isValidRoomCode('AB1Z3C'), isTrue);
    });

    test('rejects a code containing I', () {
      expect(isValidRoomCode('ABIZ3C'), isFalse);
    });

    test('accepts a code shorter than six symbols', () {
      // Section 32 item 1: codes are 1 to 6 symbols.
      expect(isValidRoomCode('AB23C'), isTrue);
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

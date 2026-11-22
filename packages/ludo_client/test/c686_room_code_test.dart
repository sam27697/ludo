// C-686t: the room code shape of docs/PROTOCOL.md section 32 items 1 and 4,
// as the client reads and stores it.
//
// Written from the order and the contract. The alphabet has 33 symbols,
// `0123456789ABCDEFGHJKMNPQRSTUVWXYZ`; a code is 1 to 6 of them; typed text
// is folded (spaces and dashes dropped, upper case, `O` to `0`, `I` and `L`
// to `1`) before it is checked.
//
// Pure functions and stores only: nothing here pumps a widget.
//
// Replay: flutter test test/c686_room_code_test.dart --plain-name '<row id>'
// Every table row names itself in its failure message.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/room_code.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTUVWXYZ';

String _again(String id) =>
    "reproduce: flutter test test/c686_room_code_test.dart --plain-name '$id'";

void main() {
  group('alphabet', () {
    test('alphabet is exactly the 33 symbols of section 32 item 1', () {
      expect(
        roomCodeAlphabet,
        _alphabet,
        reason: 'expected the section 32 alphabet; ${_again('alphabet')}',
      );
      expect(roomCodeAlphabet.length, 33);
      expect(roomCodeAlphabet.split('').toSet().length, 33);
    });

    test('the maximum length is 6', () {
      expect(roomCodeLength, 6, reason: 'section 32: 1 to 6 symbols');
    });

    test('every alphabet symbol is a valid one-symbol code', () {
      for (final String symbol in _alphabet.split('')) {
        expect(
          isValidRoomCode(symbol),
          isTrue,
          reason:
              'expected "$symbol" to be a valid code of 1 symbol, saw '
              'invalid. ${_again('every alphabet symbol')}',
        );
      }
    });

    test('I, L and O are not symbols of a canonical code', () {
      for (final String letter in <String>['I', 'L', 'O']) {
        expect(
          isValidRoomCode(letter),
          isFalse,
          reason:
              'expected raw "$letter" invalid (it is folded before the '
              'check, never a symbol). ${_again('I, L and O')}',
        );
        expect(
          isValidRoomCode('K7${letter}2QP'),
          isFalse,
          reason: 'expected raw K7${letter}2QP invalid. ${_again('I, L, O')}',
        );
      }
    });
  });

  group('folding', () {
    // (raw, canonical)
    const List<(String, String)> table = <(String, String)>[
      ('o', '0'),
      ('O', '0'),
      ('i', '1'),
      ('I', '1'),
      ('l', '1'),
      ('L', '1'),
      ('k7m2qp', 'K7M2QP'),
      (' k7 m2 qp ', 'K7M2QP'),
      ('K7-M2-QP', 'K7M2QP'),
      ('k7 - m2', 'K7M2'),
      ('o0', '00'),
      ('Il', '11'),
      ('  ', ''),
      ('--', ''),
      ('', ''),
      ('LOL', '101'),
      ('abc-i l o', 'ABC110'),
    ];

    for (final (String raw, String canonical) in table) {
      test('"$raw" folds to "$canonical"', () {
        expect(
          normalizeRoomCode(raw),
          canonical,
          reason:
              'expected normalizeRoomCode("$raw") == "$canonical". '
              '${_again('"$raw" folds')}',
        );
      });
    }

    test('folding is idempotent on every one-symbol code', () {
      for (final String symbol in _alphabet.split('')) {
        expect(
          normalizeRoomCode(symbol),
          symbol,
          reason: 'expected "$symbol" unchanged. ${_again('idempotent')}',
        );
      }
    });

    test('folded typed text is valid when it is 1 to 6 symbols', () {
      for (final String raw in <String>['l', 'o', 'i', 'LOL', 'il-ol0']) {
        expect(
          isValidRoomCode(normalizeRoomCode(raw)),
          isTrue,
          reason:
              'expected "$raw" to fold to a valid code, got '
              '"${normalizeRoomCode(raw)}". ${_again('folded valid')}',
        );
      }
    });
  });

  group('lengths', () {
    const List<(String, bool)> rows = <(String, bool)>[
      ('', false),
      ('0', true),
      ('Z', true),
      ('ZZ', true),
      ('100', true),
      ('K7M2', true),
      ('K7M2Q', true),
      ('K7M2QP', true),
      ('K7M2QP0', false),
      ('K7M2QPZZ', false),
    ];
    for (final (String code, bool valid) in rows) {
      test('"$code" (${code.length} symbols) valid is $valid', () {
        expect(
          isValidRoomCode(code),
          valid,
          reason:
              'expected isValidRoomCode("$code") == $valid for length '
              '${code.length}. ${_again('"$code" (${code.length}')}',
        );
      });
    }

    test('a symbol outside the alphabet is invalid at any length', () {
      for (final String bad in <String>['#', '_', 'K7#', 'AB_234', 'ab', ' ']) {
        expect(
          isValidRoomCode(bad),
          isFalse,
          reason: 'expected "$bad" invalid. ${_again('outside the alphabet')}',
        );
      }
    });

    test('seven symbols typed fold to seven and stay invalid', () {
      expect(
        isValidRoomCode(normalizeRoomCode('abc-2 345')),
        isFalse,
        reason: 'expected 7 symbols invalid. ${_again('seven symbols')}',
      );
    });
  });

  group('deep link /r/<code>', () {
    Uri link(String segment) => Uri.parse('https://$kAppLinkHost/r/$segment');

    test('a one-symbol code in a link is a code', () {
      expect(
        roomCodeFromUri(link('7')),
        '7',
        reason: 'expected /r/7 to give "7". ${_again('deep link 1')}',
      );
      expect(roomCodeFromUri(link('z')), 'Z');
    });

    test('a link code is folded', () {
      expect(
        roomCodeFromUri(link('k7l2qo')),
        'K712Q0',
        reason: 'expected k7l2qo folded. ${_again('deep link fold')}',
      );
    });

    test('a seven-symbol link code is not a code', () {
      expect(
        roomCodeFromUri(link('K7M2QPZ')),
        isNull,
        reason: 'expected 7 symbols refused. ${_again('deep link 7')}',
      );
    });

    test('a symbol outside the alphabet is not a code', () {
      expect(roomCodeFromUri(link('K7_2QP')), isNull);
    });
  });

  group('session memory', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    for (final String code in <String>['0', 'Z', '10', 'K7M', 'K7M2QP']) {
      test('a seat held in room "$code" is stored and read back', () async {
        final SeatRecord record = SeatRecord(
          code: code,
          seat: 1,
          seatToken: 'tok-c686',
        );
        await SessionMemory.recordSeat(record);
        final SessionMemory memory = await SessionMemory.load();
        expect(
          memory.seatRecord,
          record,
          reason:
              'expected the seat record for code "$code" to load back, saw '
              '${memory.seatRecord}. ${_again('a seat held in room "$code"')}',
        );
      });
    }

    for (final String code in <String>['', 'K7M2QPZ', 'K7#', 'ABLCDE']) {
      test('a stored seat with the code "$code" is not trusted', () async {
        await SessionMemory.recordSeat(
          SeatRecord(code: code, seat: 1, seatToken: 'tok-c686'),
        );
        final SessionMemory memory = await SessionMemory.load();
        expect(
          memory.seatRecord,
          isNull,
          reason:
              'expected a record with the non-canonical code "$code" '
              'to load as null, saw ${memory.seatRecord}. '
              '${_again('a stored seat with the code "$code"')}',
        );
      });
    }
  });
}

// Store tests for contract C-322 rule 1: SessionMemory's single record of
// the last finished game. A fresh SessionMemory.load() after
// recordLastGame must return the equal LastGame; the raw prefs key holds
// exactly the four-string shape the contract names, in the contract's own
// order; a malformed shape loads as null without throwing; clearSeat()
// never touches this record, and recordLastGame never touches the seat
// record, recent codes or last-create defaults.
//
// LastGame, SessionMemory.recordLastGame and the lastGame field on
// SessionMemory do not exist on this tree: contract C-322's own
// implementation (order 322) lands in lib/ in parallel, in a tree this
// file's author has not opened. Every case below is red on those missing
// names alone, not on a mistake in this file's own code.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _lastGameKey = 'session.lastGame';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final DateTime finishedAt = DateTime.fromMillisecondsSinceEpoch(
    1700000000000,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'no stored session.lastGame: a fresh load has a null lastGame',
    () async {
      final SessionMemory loaded = await SessionMemory.load();
      // Mutation this catches: lastGame defaulting to anything other than
      // null (a sentinel LastGame, an empty-string record) when nothing has
      // ever been written.
      expect(
        loaded.lastGame,
        isNull,
        reason:
            'lastGame must be null when session.lastGame was never '
            'written; got ${loaded.lastGame}',
      );
    },
  );

  test('recordLastGame then a fresh load returns an equal LastGame', () async {
    final LastGame written = LastGame(
      gameId: 'g-0001',
      verifyUrl: 'https://provefair.app/v/g-0001',
      finishedAt: finishedAt,
      won: true,
    );
    await SessionMemory.recordLastGame(written);

    final SessionMemory relaunched = await SessionMemory.load();
    // Mutation this catches: load() reading the stored fields back into
    // a LastGame with two of the four swapped (for example gameId and
    // verifyUrl, or finishedAt and won) -- equality on all four fields
    // catches a swap a single-field check would miss.
    expect(
      relaunched.lastGame,
      written,
      reason:
          'a later load must return the LastGame recordLastGame wrote; '
          'got ${relaunched.lastGame}',
    );
  });

  test('two LastGame instances with the same four fields are equal', () {
    final LastGame a = LastGame(
      gameId: 'g-eq',
      verifyUrl: 'https://provefair.app/v/g-eq',
      finishedAt: finishedAt,
      won: false,
    );
    final LastGame b = LastGame(
      gameId: 'g-eq',
      verifyUrl: 'https://provefair.app/v/g-eq',
      finishedAt: finishedAt,
      won: false,
    );
    // Mutation this catches: LastGame built with the default Object
    // identity equality instead of the value equality on all four fields
    // rule 1 names, which would make this a == this only.
    expect(
      a,
      b,
      reason: 'two LastGame built from the same four values must be ==',
    );
    expect(
      a.hashCode,
      b.hashCode,
      reason: 'equal LastGame values must share a hashCode',
    );
  });

  test('a LastGame differing only in won is not equal', () {
    final LastGame won = LastGame(
      gameId: 'g-won-flag',
      verifyUrl: 'https://provefair.app/v/g-won-flag',
      finishedAt: finishedAt,
      won: true,
    );
    final LastGame lost = LastGame(
      gameId: 'g-won-flag',
      verifyUrl: 'https://provefair.app/v/g-won-flag',
      finishedAt: finishedAt,
      won: false,
    );
    // Mutation this catches: operator== that only compares gameId (the
    // field most likely to be checked first and then short-circuited on),
    // silently ignoring won.
    expect(
      won == lost,
      isFalse,
      reason: 'won must be part of LastGame equality, not just gameId/url/time',
    );
  });

  test(
    "the raw prefs StringList holds exactly the four entries in the "
    "contract's order: [gameId, verifyUrl, finishedAt millis, won/lost]",
    () async {
      final DateTime at = DateTime.fromMillisecondsSinceEpoch(1700000012345);
      await SessionMemory.recordLastGame(
        LastGame(
          gameId: 'g-raw',
          verifyUrl: 'https://provefair.app/v/g-raw',
          finishedAt: at,
          won: true,
        ),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String>? raw = prefs.getStringList(_lastGameKey);
      // Mutation this catches: writing under a different key, as a
      // different shape (a joined single string, a map), or with the
      // outcome word and the millis field transposed.
      expect(raw, <String>[
        'g-raw',
        'https://provefair.app/v/g-raw',
        '1700000012345',
        'won',
      ], reason: 'raw prefs for $_lastGameKey was $raw');
    },
  );

  test('a losing game is stored with the literal word "lost"', () async {
    await SessionMemory.recordLastGame(
      LastGame(
        gameId: 'g-lost',
        verifyUrl: 'https://provefair.app/v/g-lost',
        finishedAt: finishedAt,
        won: false,
      ),
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String>? raw = prefs.getStringList(_lastGameKey);
    // Mutation this catches: won: false being written as '', 'false' or
    // 'won' (the same word regardless of the flag), any of which this
    // exact-string check catches but a mere non-null check would not.
    expect(
      raw?[3],
      'lost',
      reason:
          'the fourth entry for a lost game must read exactly "lost"; '
          'raw was $raw',
    );
  });

  test('a second recordLastGame overwrites the first, not appends', () async {
    final LastGame first = LastGame(
      gameId: 'g-first',
      verifyUrl: 'https://provefair.app/v/g-first',
      finishedAt: finishedAt,
      won: true,
    );
    final LastGame second = LastGame(
      gameId: 'g-second',
      verifyUrl: 'https://provefair.app/v/g-second',
      finishedAt: finishedAt.add(const Duration(minutes: 5)),
      won: false,
    );
    await SessionMemory.recordLastGame(first);
    await SessionMemory.recordLastGame(second);

    final SessionMemory relaunched = await SessionMemory.load();
    // Mutation this catches: recordLastGame appending to a list of
    // records under the same or a new key instead of replacing the single
    // session.lastGame entry, so the first game is still reachable.
    expect(
      relaunched.lastGame,
      second,
      reason:
          'only one record must be kept; load() after two records must '
          'return the second, not the first; got ${relaunched.lastGame}',
    );
  });

  test('recordLastGame does not touch the seat record, recent codes or '
      'last-create defaults', () async {
    await SessionMemory.recordSuccessfulCreate(name: 'Priya', seats: 3);
    await SessionMemory.recordSuccessfulJoin('AB23CD');
    const SeatRecord seat = SeatRecord(
      code: 'AB23CD',
      seat: 1,
      seatToken: 'tok-isolated',
    );
    await SessionMemory.recordSeat(seat);

    await SessionMemory.recordLastGame(
      LastGame(
        gameId: 'g-isolated',
        verifyUrl: 'https://provefair.app/v/g-isolated',
        finishedAt: finishedAt,
        won: true,
      ),
    );

    final SessionMemory relaunched = await SessionMemory.load();
    // Mutation this catches: recordLastGame routed through a helper
    // that rewrites or clears the seat/recent-codes/last-create keys as
    // a side effect, instead of touching only session.lastGame.
    expect(relaunched.lastName, 'Priya');
    expect(relaunched.lastSeats, 3);
    expect(relaunched.recentCodes, <String>['AB23CD']);
    expect(relaunched.seatRecord, seat);
  });

  group('a malformed stored shape loads as null, never throws', () {
    Future<void> expectNullLastGame(List<String> raw, String why) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _lastGameKey: raw,
      });
      Object? thrown;
      SessionMemory? loaded;
      try {
        loaded = await SessionMemory.load();
      } catch (error) {
        thrown = error;
      }
      // Mutation this catches: a parser that throws (a FormatException
      // from int.parse, a RangeError from indexing) on a malformed shape
      // instead of returning null, which would crash Home's startup load
      // instead of just hiding the card.
      expect(thrown, isNull, reason: '$why must not throw; threw $thrown');
      expect(
        loaded!.lastGame,
        isNull,
        reason: '$why must load as null; raw was $raw',
      );
    }

    test('three entries (missing the outcome)', () async {
      await expectNullLastGame(<String>[
        'g-1',
        'https://provefair.app/v/g-1',
        '1700000000000',
      ], 'a 3-entry list');
    });

    test('five entries (one too many)', () async {
      await expectNullLastGame(<String>[
        'g-1',
        'https://provefair.app/v/g-1',
        '1700000000000',
        'won',
        'extra',
      ], 'a 5-entry list');
    });

    test("'x' as the time", () async {
      await expectNullLastGame(<String>[
        'g-1',
        'https://provefair.app/v/g-1',
        'x',
        'won',
      ], 'a non-integer time');
    });

    test("'draw' as the outcome", () async {
      await expectNullLastGame(<String>[
        'g-1',
        'https://provefair.app/v/g-1',
        '1700000000000',
        'draw',
      ], 'an outcome word other than won/lost');
    });

    test('empty id', () async {
      await expectNullLastGame(<String>[
        '',
        'https://provefair.app/v/g-1',
        '1700000000000',
        'won',
      ], 'an empty gameId');
    });

    test('empty url', () async {
      await expectNullLastGame(<String>[
        'g-1',
        '',
        '1700000000000',
        'won',
      ], 'an empty verifyUrl');
    });
  });

  test('clearSeat() leaves lastGame in place', () async {
    final LastGame written = LastGame(
      gameId: 'g-seat',
      verifyUrl: 'https://provefair.app/v/g-seat',
      finishedAt: finishedAt,
      won: true,
    );
    await SessionMemory.recordLastGame(written);
    await SessionMemory.recordSeat(
      const SeatRecord(code: 'AB23CD', seat: 0, seatToken: 'tok-seat'),
    );

    await SessionMemory.clearSeat();

    final SessionMemory relaunched = await SessionMemory.load();
    // Mutation this catches: clearSeat() removing session.lastGame
    // alongside session.seat (for example by calling prefs.clear()
    // instead of prefs.remove(_seatKey)).
    expect(
      relaunched.lastGame,
      written,
      reason:
          'clearSeat() must not remove session.lastGame; got '
          '${relaunched.lastGame}',
    );
    expect(
      relaunched.seatRecord,
      isNull,
      reason: 'fixture: clearSeat() must still clear the seat record itself',
    );
  });
}

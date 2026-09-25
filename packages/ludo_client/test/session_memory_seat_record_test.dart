// Proof for order 172's SeatRecord / SessionMemory.recordSeat / clearSeat /
// load().seatRecord, written from S1..S6 in
// work/ludo/orders/172-seat-record-storage.md and from the RETURN 1 defect
// note in that same file (the wrong-type case was a real defect once; this
// file proves it stays fixed), and from nothing else.
//
// Built the way test/session_memory_test.dart is built: the platform store
// is faked with SharedPreferences.setMockInitialValues, and every claim
// about what got written is made by reading SharedPreferences back, never by
// trusting that a write "must have happened".

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One S-5 table row: an untrusted `session.seat` value, and why it is
/// untrusted. [seatValue] is `Object` rather than `List<String>` because the
/// wrong-type row stores a plain [String] under the key, exactly what
/// RETURN 1 measured breaking `getStringList` on `449fc30`.
typedef _UntrustedSeatCase = ({String description, Object seatValue});

const List<_UntrustedSeatCase> _untrustedSeatCases = <_UntrustedSeatCase>[
  (description: 'wrong length: 2 elements', seatValue: <String>['K7M2QP', '2']),
  (
    description: 'wrong length: 4 elements',
    seatValue: <String>['K7M2QP', '2', 'tok', 'extra'],
  ),
  (
    description: "invalid room code: one confusable character ('0')",
    seatValue: <String>['K7M2Q0', '2', 'tok'],
  ),
  (
    description: 'invalid room code: wrong length (5 characters)',
    seatValue: <String>['K7M2Q', '2', 'tok'],
  ),
  (description: "seat '4'", seatValue: <String>['K7M2QP', '4', 'tok']),
  (description: "seat '-1'", seatValue: <String>['K7M2QP', '-1', 'tok']),
  (description: "seat '01'", seatValue: <String>['K7M2QP', '01', 'tok']),
  (description: "seat ' 1'", seatValue: <String>['K7M2QP', ' 1', 'tok']),
  (description: "seat '+1'", seatValue: <String>['K7M2QP', '+1', 'tok']),
  (description: "seat 'x'", seatValue: <String>['K7M2QP', 'x', 'tok']),
  (description: 'empty token', seatValue: <String>['K7M2QP', '2', '']),
  (
    description: 'the wrong type: session.seat stored as a String, not a list',
    seatValue: 'K7M2QP,2,tok',
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'S-1 round trip: recordSeat then load returns an equal SeatRecord',
    () async {
      const SeatRecord record = SeatRecord(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok-s1',
      );
      await SessionMemory.recordSeat(record);

      final SessionMemory memory = await SessionMemory.load();

      expect(
        memory.seatRecord,
        equals(record),
        reason:
            'a later load must return a SeatRecord equal to the one '
            'recordSeat wrote; got ${memory.seatRecord}',
      );
    },
  );

  test('S-2 storage shape (S2): recordSeat stores session.seat as exactly '
      '[code, seat-as-base-10-string, seatToken]', () async {
    await SessionMemory.recordSeat(
      const SeatRecord(code: 'K7M2QP', seat: 2, seatToken: 'tok'),
    );

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String>? stored = prefs.getStringList('session.seat');

    expect(
      stored,
      <String>['K7M2QP', '2', 'tok'],
      reason:
          'session.seat must hold exactly [code, seat, seatToken] in '
          'that order; got $stored',
    );
  });

  test('S-3 overwrite: writing a second record replaces the first', () async {
    await SessionMemory.recordSeat(
      const SeatRecord(code: 'K7M2QP', seat: 1, seatToken: 'tok-first'),
    );
    await SessionMemory.recordSeat(
      const SeatRecord(code: 'ZZZZZZ', seat: 3, seatToken: 'tok-second'),
    );

    final SessionMemory memory = await SessionMemory.load();

    expect(
      memory.seatRecord,
      const SeatRecord(code: 'ZZZZZZ', seat: 3, seatToken: 'tok-second'),
      reason:
          'load must return the second record, not the first; there is '
          'only ever one; got ${memory.seatRecord}',
    );
  });

  test('S-4 clear: clearSeat removes the record, and clearing an empty store '
      'completes without throwing', () async {
    await SessionMemory.recordSeat(
      const SeatRecord(code: 'K7M2QP', seat: 2, seatToken: 'tok'),
    );
    await SessionMemory.clearSeat();

    final SessionMemory afterClear = await SessionMemory.load();
    expect(
      afterClear.seatRecord,
      isNull,
      reason: 'clearSeat must remove the stored record',
    );

    late Future<void> secondClear;
    expect(
      () => secondClear = SessionMemory.clearSeat(),
      returnsNormally,
      reason: 'S4: clearing an empty store must not throw synchronously',
    );
    await expectLater(
      secondClear,
      completes,
      reason:
          'S4: clearSeat on an empty store must complete without '
          'throwing',
    );
  });

  for (final _UntrustedSeatCase case_ in _untrustedSeatCases) {
    test('S-5 untrusted shapes (S5): ${case_.description}', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'session.lastName': 'Priya',
        'session.lastSeats': 3,
        'session.recentCodes': <String>['ABCDEF', 'GHJKLM'],
        'session.seat': case_.seatValue,
      });

      final SessionMemory memory = await SessionMemory.load();

      expect(
        memory.seatRecord,
        isNull,
        reason:
            'S5: ${case_.description} must not be trusted; seatRecord must '
            'be null, got ${memory.seatRecord}',
      );
      expect(
        memory.lastName,
        'Priya',
        reason:
            'S5: an untrusted seat value (${case_.description}) must not '
            'disturb lastName; got ${memory.lastName}',
      );
      expect(
        memory.lastSeats,
        3,
        reason:
            'S5: an untrusted seat value (${case_.description}) must not '
            'disturb lastSeats; got ${memory.lastSeats}',
      );
      expect(
        memory.recentCodes,
        <String>['ABCDEF', 'GHJKLM'],
        reason:
            'S5: an untrusted seat value (${case_.description}) must not '
            'disturb recentCodes; got ${memory.recentCodes}',
      );
    });
  }

  test('S-6 valid edges: seat 0 and seat 3 both load', () async {
    await SessionMemory.recordSeat(
      const SeatRecord(code: 'K7M2QP', seat: 0, seatToken: 'tok-0'),
    );
    final SessionMemory zero = await SessionMemory.load();
    expect(
      zero.seatRecord,
      const SeatRecord(code: 'K7M2QP', seat: 0, seatToken: 'tok-0'),
      reason: "S6: seat '0' must load; got ${zero.seatRecord}",
    );

    await SessionMemory.recordSeat(
      const SeatRecord(code: 'K7M2QP', seat: 3, seatToken: 'tok-3'),
    );
    final SessionMemory three = await SessionMemory.load();
    expect(
      three.seatRecord,
      const SeatRecord(code: 'K7M2QP', seat: 3, seatToken: 'tok-3'),
      reason: "S6: seat '3' must load; got ${three.seatRecord}",
    );
  });

  test('S-7 toString (S1): SeatRecord.toString does not contain the seat '
      'token', () {
    const SeatRecord record = SeatRecord(
      code: 'K7M2QP',
      seat: 2,
      seatToken: 'super-secret-token',
    );
    final String text = record.toString();

    expect(
      text.contains('super-secret-token'),
      isFalse,
      reason:
          'toString must never include the seat token, a capability; '
          'got "$text"',
    );
  });

  group('S-8 equality (S1)', () {
    test('equal fields are == with equal hashCode', () {
      const SeatRecord a = SeatRecord(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok',
      );
      const SeatRecord b = SeatRecord(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('a different code alone makes them unequal', () {
      const SeatRecord a = SeatRecord(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok',
      );
      const SeatRecord b = SeatRecord(
        code: 'ZZZZZZ',
        seat: 2,
        seatToken: 'tok',
      );
      expect(a, isNot(equals(b)));
    });

    test('a different seat alone makes them unequal', () {
      const SeatRecord a = SeatRecord(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok',
      );
      const SeatRecord b = SeatRecord(
        code: 'K7M2QP',
        seat: 1,
        seatToken: 'tok',
      );
      expect(a, isNot(equals(b)));
    });

    test('a different seatToken alone makes them unequal', () {
      const SeatRecord a = SeatRecord(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok-a',
      );
      const SeatRecord b = SeatRecord(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok-b',
      );
      expect(a, isNot(equals(b)));
    });
  });
}

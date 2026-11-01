// Unit proof for C-520 D1: quickChatRestsUntil mirrors PROTOCOL.md section 25
// rule 3 on the device. Written from work/ludo/orders/C-520-sweep36-refusals.md
// alone; the implementation (order 521) was being written in another tree and
// has not been read.
//
// The rule, as the contract states it: rest until `last + 3000 ms`, and when
// the list holds ten or more also until `tenth + 60 000 ms`, where `last` is
// the newest instant and `tenth` the tenth newest; the later of the two; null
// when that instant is at or before `now`; null for an empty list. An instant
// `a` counts toward the ten when `t - a < 60 000 ms`.
//
// Every instant is a literal DateTime built here. Every assertion is on the
// exact instant, never on "not null".
//
// This file does not compile on a tree without quickChatRestsUntil,
// kQuickChatPerWindow and kQuickChatWindow (C-520 D1); that is the expected
// failing arm on the base.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/quick_chat.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 1, 8, 0, 0);

DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

/// [count] instants [gapMs] apart, the first at [startMs], oldest first.
List<DateTime> _run(int count, int gapMs, {int startMs = 0}) => <DateTime>[
  for (int i = 0; i < count; i++) _at(startMs + i * gapMs),
];

String _fmt(DateTime? t) =>
    t == null ? 'null' : '+${t.difference(_t0).inMilliseconds} ms';

/// Fails with the whole scenario in the message.
void _expectRest(
  List<DateTime> admitted,
  int nowMs,
  int? expectedMs, {
  required String scenario,
}) {
  final DateTime now = _at(nowMs);
  final DateTime? got = quickChatRestsUntil(admitted, now);
  final DateTime? want = expectedMs == null ? null : _at(expectedMs);
  expect(
    got,
    want,
    reason:
        'C-520 D1, $scenario | expected: ${_fmt(want)} | got: ${_fmt(got)} | '
        'now +$nowMs ms | admitted '
        '${[for (final DateTime a in admitted) _fmt(a)]} (instants are '
        'offsets from $_t0)',
  );
}

void main() {
  group('the constants', () {
    test('section 25 rule 3 is ten in sixty seconds, 3000 ms apart', () {
      expect(kQuickChatPerWindow, 10, reason: 'at most ten per window');
      expect(
        kQuickChatWindow,
        const Duration(milliseconds: 60000),
        reason: 'the window is 60 000 ms',
      );
      expect(
        kQuickChatCooldown,
        const Duration(milliseconds: 3000),
        reason: 'C-520 keeps the 3000 ms name and value',
      );
    });
  });

  group('empty and single', () {
    test('an empty list never rests', () {
      for (final int nowMs in <int>[-5000, 0, 1, 3000, 1000000]) {
        _expectRest(
          const <DateTime>[],
          nowMs,
          null,
          scenario: 'empty list at now=+$nowMs',
        );
      }
    });

    test('one ack 2999 ms before now rests until 1 ms from now', () {
      _expectRest(
        <DateTime>[_at(0)],
        2999,
        3000,
        scenario: 'one ack, now = ack + 2999',
      );
    });

    test('one ack exactly 3000 ms before now is ready', () {
      _expectRest(
        <DateTime>[_at(0)],
        3000,
        null,
        scenario: 'one ack, now = ack + 3000 (at the bound, admitted)',
      );
    });

    test('one ack 3001 ms and a minute before now is ready', () {
      _expectRest(<DateTime>[_at(0)], 3001, null, scenario: 'ack + 3001');
      _expectRest(<DateTime>[_at(0)], 60000, null, scenario: 'ack + 60000');
    });

    test('one ack in the same instant as now rests the whole 3000 ms', () {
      _expectRest(<DateTime>[_at(500)], 500, 3500, scenario: 'now = ack');
    });
  });

  group('fewer than ten: only the 3000 ms bound', () {
    test(
      'nine acks packed into one second rest only 3000 ms past the last',
      () {
        final List<DateTime> admitted = _run(9, 100);
        // last is +800.
        _expectRest(admitted, 900, 3800, scenario: 'nine acks 100 ms apart');
        _expectRest(admitted, 3799, 3800, scenario: 'nine acks, 1 ms early');
        _expectRest(admitted, 3800, null, scenario: 'nine acks, at the bound');
      },
    );

    test('nine acks 3000 ms apart are ready 3000 ms after the last', () {
      final List<DateTime> admitted = _run(9, 3000);
      // last is +24000; the sixty second bound does not apply to nine.
      _expectRest(admitted, 26999, 27000, scenario: 'nine acks, 1 ms early');
      _expectRest(admitted, 27000, null, scenario: 'nine acks, at the bound');
    });
  });

  group('ten acks 3000 ms apart', () {
    // tenth newest is the oldest, +0; last is +27000.
    final List<DateTime> ten = _run(10, 3000);

    test('right after the last ack the minute bound is the one that rests', () {
      _expectRest(ten, 27000, 60000, scenario: 'ten acks, now = last');
      _expectRest(ten, 30000, 60000, scenario: 'ten acks, 3 s after last');
      _expectRest(ten, 45000, 60000, scenario: 'ten acks, mid window');
    });

    test('tenth + 59 999 ms still rests, until the tenth + 60 000 ms', () {
      _expectRest(ten, 59999, 60000, scenario: 'now = tenth + 59 999');
    });

    test('tenth + 60 000 ms is admitted', () {
      _expectRest(ten, 60000, null, scenario: 'now = tenth + 60 000');
    });

    test('well after the minute is ready', () {
      _expectRest(ten, 60001, null, scenario: 'now = tenth + 60 001');
      _expectRest(ten, 600000, null, scenario: 'now = tenth + ten minutes');
    });

    test('ten acks in the same instant rest a whole minute from it', () {
      final List<DateTime> same = List<DateTime>.filled(10, _at(1000));
      _expectRest(same, 1000, 61000, scenario: 'ten acks at one instant');
      _expectRest(same, 60999, 61000, scenario: 'ten at one instant, 1 early');
      _expectRest(same, 61000, null, scenario: 'ten at one instant, on time');
    });
  });

  group('eleven acks: only the newest ten matter', () {
    // +0 .. +30000 step 3000. The newest ten are +3000 .. +30000; the tenth
    // newest is +3000, not the oldest +0.
    final List<DateTime> eleven = _run(11, 3000);

    test('the rest runs to the second oldest plus a minute', () {
      _expectRest(eleven, 30000, 63000, scenario: 'eleven acks, now = last');
      _expectRest(eleven, 62999, 63000, scenario: 'eleven acks, 1 ms early');
    });

    test('the oldest ack plus a minute is not the bound', () {
      // If the oldest (+0) were counted as the tenth, +60000 would be ready.
      _expectRest(
        eleven,
        60000,
        63000,
        scenario: 'eleven acks, now = oldest + 60 000 (still resting)',
      );
    });

    test('ready exactly at the second oldest plus a minute', () {
      _expectRest(eleven, 63000, null, scenario: 'eleven acks, on time');
    });

    test('twenty-five acks: the tenth newest decides, not the oldest', () {
      final List<DateTime> many = _run(25, 3000);
      // last is +72000, tenth newest is index 15 = +45000.
      _expectRest(many, 72000, 105000, scenario: 'twenty-five acks, last');
      _expectRest(many, 104999, 105000, scenario: 'twenty-five acks, early');
      _expectRest(many, 105000, null, scenario: 'twenty-five acks, on time');
    });
  });

  group('the later of the two bounds wins', () {
    test('minute bound later: ten acks close together', () {
      // last = +9000 so 3 s bound is +12000; tenth = 0 so minute bound is
      // +60000. The minute wins.
      final List<DateTime> packed = _run(10, 1000);
      _expectRest(packed, 9000, 60000, scenario: 'ten packed, now = last');
      _expectRest(packed, 12000, 60000, scenario: 'ten packed, past 3 s bound');
      _expectRest(packed, 59999, 60000, scenario: 'ten packed, 1 ms early');
      _expectRest(packed, 60000, null, scenario: 'ten packed, on time');
    });

    test('3 s bound later: ten acks spread over 58 seconds', () {
      // tenth = +0 so minute bound is +60000; last = +58000 so the 3 s bound
      // is +61000. The 3 s bound wins.
      final List<DateTime> spread = <DateTime>[
        for (final int ms in const <int>[
          0,
          6000,
          12000,
          18000,
          24000,
          30000,
          36000,
          42000,
          50000,
          58000,
        ])
          _at(ms),
      ];
      _expectRest(spread, 58000, 61000, scenario: 'spread, now = last');
      _expectRest(spread, 60000, 61000, scenario: 'spread, now = minute bound');
      _expectRest(spread, 60999, 61000, scenario: 'spread, 1 ms early');
      _expectRest(spread, 61000, null, scenario: 'spread, on time');
    });

    test(
      'the two bounds equal: ten acks, last exactly 57 000 ms after tenth',
      () {
        // last + 3000 == tenth + 60000 == +60000.
        final List<DateTime> level = <DateTime>[
          for (final int ms in const <int>[
            0,
            1000,
            2000,
            3000,
            4000,
            5000,
            6000,
            7000,
            8000,
            57000,
          ])
            _at(ms),
        ];
        _expectRest(level, 59999, 60000, scenario: 'bounds equal, 1 ms early');
        _expectRest(level, 60000, null, scenario: 'bounds equal, on time');
      },
    );

    test('a count of nine with a long span never meets the minute bound', () {
      // Nine acks spread over 58 seconds: no tenth, so only last + 3000.
      final List<DateTime> nine = <DateTime>[
        for (final int ms in const <int>[
          0,
          6000,
          12000,
          18000,
          24000,
          30000,
          36000,
          42000,
          58000,
        ])
          _at(ms),
      ];
      _expectRest(nine, 58000, 61000, scenario: 'nine spread, now = last');
      _expectRest(nine, 61000, null, scenario: 'nine spread, on time');
    });
  });

  group('the window edge', () {
    test('an ack older than a minute no longer counts toward the ten', () {
      // Ten acks: one at +0 and nine from +40000 to +48000. At now = +60000
      // the +0 ack has aged out, so only nine count, and the rest is the
      // 3 s bound from +48000, which is long past. Ready.
      final List<DateTime> aged = <DateTime>[
        _at(0),
        for (int i = 0; i < 9; i++) _at(40000 + i * 1000),
      ];
      _expectRest(aged, 60000, null, scenario: 'tenth aged out at +60000');
      // One millisecond earlier the +0 ack still counts: ten in the window.
      _expectRest(aged, 59999, 60000, scenario: 'tenth still in at +59999');
    });
  });

  group('the list is read, not changed', () {
    test('the argument is the same after the call', () {
      final List<DateTime> admitted = _run(12, 2500);
      final List<DateTime> copy = List<DateTime>.of(admitted);
      quickChatRestsUntil(admitted, _at(31000));
      expect(
        admitted,
        copy,
        reason:
            'C-520 D1: the screen keeps this list for the life of the '
            'GameScreen, so the function must leave it as it found it',
      );
    });
  });
}

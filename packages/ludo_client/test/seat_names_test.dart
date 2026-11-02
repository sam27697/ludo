// Proof for C-536 D1 (work/ludo/orders/C-536-same-name-seats.md): the pure
// function that gives every seat one display name. Written from the contract
// text alone, before the function exists: lib/src/seat_names.dart is absent
// on this tree, so this file does not compile here and that is its red arm.
//
// The `numbered` callback is a recorder that joins the name and the number
// with a '#', so a case can tell "numbered was called with this name and this
// number" from "the name was left alone". The app's own callback (the ARB
// message seatNameNumbered) is covered by c536_screens_test.dart.
//
// Ambiguities, reported and not invented around:
//   - D1 says the first holder "keeps it unchanged" and later holders get
//     numbered(name, n), but not whether `name` there is the seat's own string
//     or its trimmed form. The trim case below puts the untrimmed spelling
//     first and the trimmed one second, so both readings give the same
//     numbered name and only the first holder's "unchanged" is pinned.
//   - D1 does not say what happens when a numbered label equals another
//     seat's real name ("Player", "Player 2", "Player"). The case below pins
//     the literal rule (the third seat is numbered 2, the rule reads nothing
//     else) and says so.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/snapshot.dart' show SeatState;
import 'package:ludo_client/src/seat_names.dart';

SeatState _seat(int seat, String name, {bool connected = true}) => SeatState(
  seat: seat,
  name: name,
  connected: connected,
  tokens: const <int>[-1, -1, -1, -1],
  clientSeed: null,
  seedOrigin: null,
);

String _numbered(String name, int number) => '$name#$number';

Map<int, String> _names(Iterable<SeatState> seats) =>
    seatDisplayNames(seats, _numbered);

String _scenario(String label, List<SeatState> seats) =>
    '$label | seats: ${<String>[for (final SeatState s in seats) '${s.seat}=${_quote(s.name)}'].join(', ')}';

String _quote(String s) => '"${s.replaceAll('"', r'\"')}"';

void _expectNames(
  String label,
  List<SeatState> seats,
  Map<int, String> expected,
) {
  final Map<int, String> got = _names(seats);
  expect(
    got,
    expected,
    reason:
        '${_scenario(label, seats)} | expected $expected | got $got '
        '(numbered is name#n)',
  );
}

void main() {
  group('seatDisplayNames', () {
    test('all names distinct: every seat keeps its own name', () {
      _expectNames(
        'distinct',
        <SeatState>[_seat(0, 'Ann'), _seat(1, 'Bob'), _seat(3, 'Cara')],
        <int, String>{0: 'Ann', 1: 'Bob', 3: 'Cara'},
      );
    });

    test('no seats: an empty map', () {
      _expectNames('empty room', <SeatState>[], <int, String>{});
    });

    test('one seat: its name unchanged', () {
      _expectNames(
        'single seat',
        <SeatState>[_seat(2, 'Player')],
        <int, String>{2: 'Player'},
      );
    });

    test('two equal names at seats 0 and 2: seat 2 is numbered 2, not 3', () {
      _expectNames(
        'two equal, gap in seat indexes',
        <SeatState>[_seat(0, 'Player'), _seat(2, 'Player')],
        <int, String>{0: 'Player', 2: 'Player#2'},
      );
    });

    test('two equal names at adjacent seats', () {
      _expectNames(
        'two equal, adjacent',
        <SeatState>[_seat(0, 'Player'), _seat(1, 'Player')],
        <int, String>{0: 'Player', 1: 'Player#2'},
      );
    });

    test('three equal names: 1st unchanged, then 2 and 3', () {
      _expectNames(
        'three equal',
        <SeatState>[_seat(0, 'Player'), _seat(1, 'Player'), _seat(2, 'Player')],
        <int, String>{0: 'Player', 1: 'Player#2', 2: 'Player#3'},
      );
    });

    test('four equal names: 1st unchanged, then 2, 3 and 4', () {
      _expectNames(
        'four equal',
        <SeatState>[
          _seat(0, 'Player'),
          _seat(1, 'Player'),
          _seat(2, 'Player'),
          _seat(3, 'Player'),
        ],
        <int, String>{0: 'Player', 1: 'Player#2', 2: 'Player#3', 3: 'Player#4'},
      );
    });

    test('three equal names on seats 0, 2 and 3: numbers count holders', () {
      _expectNames(
        'three equal, seat 1 empty',
        <SeatState>[_seat(0, 'Player'), _seat(2, 'Player'), _seat(3, 'Player')],
        <int, String>{0: 'Player', 2: 'Player#2', 3: 'Player#3'},
      );
    });

    test('equal after trim: " Player" and "Player" are the same name', () {
      _expectNames(
        'equal after trim',
        <SeatState>[_seat(0, ' Player'), _seat(1, 'Player')],
        <int, String>{0: ' Player', 1: 'Player#2'},
      );
    });

    test('tabs and runs of spaces around the first holder are trimmed too', () {
      _expectNames(
        'equal after trim, both ends',
        <SeatState>[_seat(0, '  Player\t'), _seat(1, 'Player')],
        <int, String>{0: '  Player\t', 1: 'Player#2'},
      );
    });

    test('case differs: "player" and "Player" are not equal', () {
      _expectNames(
        'case differs',
        <SeatState>[_seat(0, 'player'), _seat(1, 'Player')],
        <int, String>{0: 'player', 1: 'Player'},
      );
    });

    test(
      'script differs: the Arabic name and the Latin name are not equal',
      () {
        _expectNames(
          'script differs',
          <SeatState>[_seat(0, 'لاعب'), _seat(1, 'Player')],
          <int, String>{0: 'لاعب', 1: 'Player'},
        );
      },
    );

    test('the Arabic default twice: the second is numbered', () {
      _expectNames(
        'two Arabic defaults',
        <SeatState>[_seat(1, 'لاعب'), _seat(3, 'لاعب')],
        <int, String>{1: 'لاعب', 3: 'لاعب#2'},
      );
    });

    test('inner whitespace is part of the name: "Mo  Ali" is not "Mo Ali"', () {
      _expectNames(
        'inner whitespace differs',
        <SeatState>[_seat(0, 'Mo Ali'), _seat(1, 'Mo  Ali')],
        <int, String>{0: 'Mo Ali', 1: 'Mo  Ali'},
      );
    });

    test('seats given out of order: the rule follows seat index', () {
      // A const list cannot be sorted in place, so a function that sorts its
      // argument instead of a copy throws here.
      const List<SeatState> shuffled = <SeatState>[
        SeatState(
          seat: 3,
          name: 'Player',
          connected: true,
          tokens: <int>[-1, -1, -1, -1],
          clientSeed: null,
          seedOrigin: null,
        ),
        SeatState(
          seat: 0,
          name: 'Player',
          connected: true,
          tokens: <int>[-1, -1, -1, -1],
          clientSeed: null,
          seedOrigin: null,
        ),
        SeatState(
          seat: 1,
          name: 'Player',
          connected: true,
          tokens: <int>[-1, -1, -1, -1],
          clientSeed: null,
          seedOrigin: null,
        ),
      ];
      _expectNames('out of order 3,0,1', shuffled, <int, String>{
        0: 'Player',
        1: 'Player#2',
        3: 'Player#3',
      });
    });

    test('seats in descending order give the same labels as ascending', () {
      final List<SeatState> ascending = <SeatState>[
        _seat(0, 'Player'),
        _seat(1, 'Ann'),
        _seat(2, 'Player'),
        _seat(3, 'Player'),
      ];
      final Map<int, String> up = _names(ascending);
      final Map<int, String> down = _names(ascending.reversed.toList());
      expect(
        down,
        up,
        reason:
            '${_scenario('descending vs ascending', ascending)} | expected '
            'the same map whichever way the seats are listed | ascending '
            '$up | descending $down',
      );
      expect(up, <int, String>{
        0: 'Player',
        1: 'Ann',
        2: 'Player#2',
        3: 'Player#3',
      }, reason: 'ascending: ${_scenario('mixed', ascending)}');
    });

    test('a lazy Iterable is accepted, not only a List', () {
      final List<SeatState> seats = <SeatState>[
        _seat(2, 'Player'),
        _seat(0, 'Player'),
      ];
      final Map<int, String> got = seatDisplayNames(
        seats.map((SeatState s) => s),
        _numbered,
      );
      expect(got, <int, String>{
        0: 'Player',
        2: 'Player#2',
      }, reason: '${_scenario('lazy iterable', seats)} | got $got');
    });

    test('two different duplicated names in one room count separately', () {
      _expectNames(
        'A,B,A,B',
        <SeatState>[_seat(0, 'A'), _seat(1, 'B'), _seat(2, 'A'), _seat(3, 'B')],
        <int, String>{0: 'A', 1: 'B', 2: 'A#2', 3: 'B#2'},
      );
    });

    test(
      'a duplicate pair beside a distinct name leaves the distinct alone',
      () {
        _expectNames(
          'Ann,Player,Player',
          <SeatState>[_seat(0, 'Ann'), _seat(1, 'Player'), _seat(2, 'Player')],
          <int, String>{0: 'Ann', 1: 'Player', 2: 'Player#2'},
        );
      },
    );

    test('two empty names are equal like any other name', () {
      _expectNames(
        'two empty names',
        <SeatState>[_seat(0, ''), _seat(1, '')],
        <int, String>{0: '', 1: '#2'},
      );
    });

    test('connection state is not read: an offline seat is numbered too', () {
      _expectNames(
        'offline holder',
        <SeatState>[
          _seat(0, 'Player', connected: false),
          _seat(1, 'Player', connected: false),
        ],
        <int, String>{0: 'Player', 1: 'Player#2'},
      );
    });

    test('the rule reads nothing else: a real "Player#2" does not move it', () {
      // C-536 D1 does not dedupe a numbered label against another seat's own
      // name. Pinned literally: the third seat is numbered 2 even though
      // seat 1 is already called exactly that.
      _expectNames(
        'numbered label collides with a real name',
        <SeatState>[
          _seat(0, 'Player'),
          _seat(1, 'Player#2'),
          _seat(2, 'Player'),
        ],
        <int, String>{0: 'Player', 1: 'Player#2', 2: 'Player#2'},
      );
    });

    test(
      'a seat that leaves frees its name: labels follow the current set',
      () {
        final List<SeatState> three = <SeatState>[
          _seat(0, 'Player'),
          _seat(1, 'Player'),
          _seat(2, 'Player'),
        ];
        expect(_names(three), <int, String>{
          0: 'Player',
          1: 'Player#2',
          2: 'Player#3',
        }, reason: _scenario('three equal before the leave', three));
        final List<SeatState> after = <SeatState>[three[0], three[2]];
        _expectNames('seat 1 left', after, <int, String>{
          0: 'Player',
          2: 'Player#2',
        });
        final List<SeatState> hostLeft = <SeatState>[three[1], three[2]];
        _expectNames('seat 0 left', hostLeft, <int, String>{
          1: 'Player',
          2: 'Player#2',
        });
      },
    );

    test('numbered is called with the number only for later holders', () {
      final List<(String, int)> calls = <(String, int)>[];
      final Map<int, String> got = seatDisplayNames(
        <SeatState>[
          _seat(0, 'Ann'),
          _seat(1, 'Player'),
          _seat(2, 'Player'),
          _seat(3, 'Ann'),
        ],
        (String name, int number) {
          calls.add((name, number));
          return 'N($name,$number)';
        },
      );
      expect(
        calls,
        <(String, int)>[('Player', 2), ('Ann', 2)],
        reason:
            'scenario Ann,Player,Player,Ann | expected numbered to run once '
            'per later holder, in seat order, never for a first holder | '
            'calls $calls',
      );
      expect(got, <int, String>{
        0: 'Ann',
        1: 'Player',
        2: 'N(Player,2)',
        3: 'N(Ann,2)',
      }, reason: 'scenario Ann,Player,Player,Ann | got $got');
    });

    test('same input twice gives the same map', () {
      final List<SeatState> seats = <SeatState>[
        _seat(1, 'Player'),
        _seat(0, 'Player'),
      ];
      expect(
        _names(seats),
        _names(seats),
        reason: _scenario('repeat call', seats),
      );
    });
  });
}

// Order 432 -- parse tests for decision D3 of
// work/ludo/orders/C-432-timer-steps-survive-resume.md, written from that
// contract and from docs/PROTOCOL.md section 23 only:
//
//   SeatState gains `final int? timerSteps`, an optional named constructor
//   parameter (null default), carried by `copyWith`. `fromJson`: key absent or
//   JSON null -> null; a non-negative int -> that int; any other type, or a
//   negative int -> SnapshotFormatException('timer_steps').
//
// Cases: P1 (the four accepted shapes), P2 (the rejected shapes), P3
// (copyWith keeps it), plus P1e/P2e, the same decoder reached through
// RoomSnapshot.fromJson, which is the path every frame actually takes.
//
// The `timerSteps` getter does not exist on the base commit (12853b9). A
// direct `seat.timerSteps` would stop this whole file compiling, which would
// also take down P2 (it needs no getter) and the RoomSnapshot cases. The
// getter is therefore read through `_timerSteps`, one dynamic lookup that
// turns the missing getter into a plain test failure naming D3. Nothing else
// is dynamic; every fixture is raw JSON handed to the real decoders. Once the
// getter exists `_timerSteps` returns exactly what `seat.timerSteps` would,
// and the int-ness of the value is still asserted with `isA<int>()`.
//
// Reproduce any case: cd packages/ludo_client && flutter test
// test/net/snapshot_timer_steps_test.dart --plain-name "<case name>"

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/snapshot.dart';

const String _file = 'test/net/snapshot_timer_steps_test.dart';

const String _hex64 =
    '4b871c474b871c474b871c474b871c47'
    '4b871c474b871c474b871c474b871c47';

/// A seat object as section 6 gives it. `timer_steps` is added only when
/// [steps] is passed, so "key absent" and "JSON null" are different inputs.
Map<String, Object?> _seatJson({
  int seat = 0,
  String name = 'Sam',
  Object? steps = _absent,
}) {
  final Map<String, Object?> json = <String, Object?>{
    'seat': seat,
    'name': name,
    'connected': true,
    'tokens': <Object?>[-1, -1, -1, -1],
    'client_seed': null,
    'seed_origin': null,
  };
  if (!identical(steps, _absent)) {
    json['timer_steps'] = steps;
  }
  return json;
}

const Object _absent = Object();

Map<String, Object?> _roomJson(List<Map<String, Object?>> seats) =>
    <String, Object?>{
      'code': 'K7M2QP',
      'state': 'PLAYING',
      'host_seat': 0,
      'players': 4,
      'rules': <String, Object?>{
        'blocks': true,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
      'chain_commit': _hex64,
      'chain_index': 0,
      'game_id': 'a1b2c3d4e5f60718',
      'client_seeds': '0:a|1:b',
      'seats': seats,
      'turn': <String, Object?>{
        'seat': 0,
        'phase': 'await_roll',
        'deadline_ms': 30000,
        'k': 0,
      },
      'winner': null,
      'seq': 1,
    };

/// `seat.timerSteps`, read dynamically; see the file header for why.
Object? _timerSteps(SeatState seat, {required String caseName}) {
  try {
    return (seat as dynamic).timerSteps as Object?;
  } on NoSuchMethodError {
    fail(
      'D3: SeatState must expose `final int? timerSteps` and has no such '
      'getter. Case "$caseName" cannot read the parsed value. Reproduce: '
      'flutter test $_file --plain-name "$caseName"',
    );
  }
}

String _why(String caseName, String decision, String defect) =>
    'C-432 $decision. Catches: $defect. Reproduce: cd packages/ludo_client '
    '&& flutter test $_file --plain-name "$caseName"';

void main() {
  group('P1: accepted shapes', () {
    for (final int value in <int>[3, 0, 1, 99, 1000000]) {
      test('P1 timer_steps $value decodes to the int $value', () {
        final SeatState seat = SeatState.fromJson(_seatJson(steps: value));
        final Object? got = _timerSteps(
          seat,
          caseName: 'P1 timer_steps $value decodes to the int $value',
        );
        expect(
          got,
          isA<int>(),
          reason: _why(
            'P1 timer_steps $value decodes to the int $value',
            'D3 (a non-negative int is that int)',
            'a parse that keeps the value as num, String or bool',
          ),
        );
        expect(
          got,
          value,
          reason: _why(
            'P1 timer_steps $value decodes to the int $value',
            'D3 (a non-negative int is that int); got $got for the JSON '
                'value $value',
            'a decoder that drops the field, defaults it to 0, or clamps it',
          ),
        );
      });
    }

    test('P1 key absent decodes to null, not 0', () {
      const String name = 'P1 key absent decodes to null, not 0';
      final SeatState seat = SeatState.fromJson(_seatJson());
      expect(
        _timerSteps(seat, caseName: name),
        isNull,
        reason: _why(
          name,
          'D3 (key absent -> null, so a client talking to an older server '
              'changes nothing, D4)',
          'a decoder that defaults an absent key to 0, which D4 would read '
              'as "drop the notice" on every older server',
        ),
      );
    });

    test('P1 JSON null decodes to null, not 0 and not an exception', () {
      const String name =
          'P1 JSON null decodes to null, not 0 and not an '
          'exception';
      final SeatState seat = SeatState.fromJson(_seatJson(steps: null));
      expect(
        _timerSteps(seat, caseName: name),
        isNull,
        reason: _why(
          name,
          'D3 (JSON null -> null)',
          'a decoder that treats an explicit null as the wrong type',
        ),
      );
    });

    test(
      'P1e each seat of a RoomSnapshot keeps its own value: 3, absent, 0',
      () {
        const String name =
            'P1e each seat of a RoomSnapshot keeps its own value: 3, absent, 0';
        final RoomSnapshot room = RoomSnapshot.fromJson(
          _roomJson(<Map<String, Object?>>[
            _seatJson(seat: 0, steps: 3),
            _seatJson(seat: 1, name: 'Bob'),
            _seatJson(seat: 2, name: 'Cy', steps: 0),
          ]),
        );
        expect(room.seats, hasLength(3));
        expect(
          room.seats
              .map((SeatState s) => _timerSteps(s, caseName: name))
              .toList(),
          <Object?>[3, null, 0],
          reason: _why(
            name,
            'D3 through the snapshot path (section 23 rule 1: a value per seat '
                'object)',
            'one value shared by every seat, last seat wins, or the field '
                'read from the room object instead of the seat object',
          ),
        );
      },
    );
  });

  group('P2: rejected shapes', () {
    final Map<String, Object?> bad = <String, Object?>{
      'negative one (-1)': -1,
      'negative thousand (-1000)': -1000,
      'the string "2"': '2',
      'the empty string': '',
      'the double 1.5': 1.5,
      'the double 2.0': 2.0,
      'the bool true': true,
      'the bool false': false,
      'an empty list': <Object?>[],
      'the list [1]': <Object?>[1],
      'an empty object': <String, Object?>{},
    };
    for (final MapEntry<String, Object?> entry in bad.entries) {
      test('P2 ${entry.key} throws SnapshotFormatException(timer_steps)', () {
        final String name =
            'P2 ${entry.key} throws SnapshotFormatException(timer_steps)';
        Object? thrown;
        try {
          SeatState.fromJson(_seatJson(steps: entry.value));
        } catch (error) {
          thrown = error;
        }
        expect(
          thrown,
          isA<SnapshotFormatException>(),
          reason: _why(
            name,
            'D3 (any other type, or a negative int, is a '
                'SnapshotFormatException; section 23 rule 1: never negative)',
            'a lenient decoder that accepts ${entry.key} and carries it into '
                'the notice logic; got ${thrown ?? 'no exception'}',
          ),
        );
        expect(
          (thrown! as SnapshotFormatException).reason,
          'timer_steps',
          reason: _why(
            name,
            'D3 (the exception names the field: '
                "SnapshotFormatException('timer_steps'))",
            'a failure blamed on the wrong field, which makes a bad frame '
                'impossible to diagnose from the log',
          ),
        );
      });
    }

    test('P2e a bad value on the second seat fails the whole RoomSnapshot', () {
      const String name =
          'P2e a bad value on the second seat fails the whole RoomSnapshot';
      expect(
        () => RoomSnapshot.fromJson(
          _roomJson(<Map<String, Object?>>[
            _seatJson(seat: 0, steps: 1),
            _seatJson(seat: 1, name: 'Bob', steps: -1),
          ]),
        ),
        throwsA(isA<SnapshotFormatException>()),
        reason: _why(
          name,
          'D3 through the snapshot path (a negative count is malformed, '
              'section 23 rule 1)',
          'RoomSnapshot.fromJson swallowing a seat error, or only checking '
              'the first seat',
        ),
      );
    });
  });

  group('P3: copyWith', () {
    test('P3 copyWith with other fields keeps timerSteps', () {
      const String name = 'P3 copyWith with other fields keeps timerSteps';
      final SeatState seat = SeatState.fromJson(_seatJson(steps: 3));
      final SeatState copy = seat.copyWith(name: 'Renamed', connected: false);
      expect(
        copy.name,
        'Renamed',
        reason: 'setup: copyWith must still replace the fields it is given',
      );
      expect(
        _timerSteps(copy, caseName: name),
        3,
        reason: _why(
          name,
          'D3 (timerSteps is carried by copyWith)',
          'a copyWith that rebuilds the seat without the new field, which '
              'would silently zero the count on every presence update',
        ),
      );
    });

    test('P3 copyWith() with no arguments keeps a zero', () {
      const String name = 'P3 copyWith() with no arguments keeps a zero';
      final SeatState seat = SeatState.fromJson(_seatJson(steps: 0));
      expect(
        _timerSteps(seat.copyWith(), caseName: name),
        0,
        reason: _why(
          name,
          'D3 (carried by copyWith; 0 is a value, not "absent")',
          'a copyWith that uses `x ?? default` on a field whose value 0 is '
              'meaningful, or turns 0 into null',
        ),
      );
    });

    test('P3 copyWith keeps null as null', () {
      const String name = 'P3 copyWith keeps null as null';
      final SeatState seat = SeatState.fromJson(_seatJson());
      expect(
        _timerSteps(seat.copyWith(name: 'x'), caseName: name),
        isNull,
        reason: _why(
          name,
          'D3 (null default, carried by copyWith)',
          'a copyWith that invents 0 for an older server\'s seat',
        ),
      );
    });
  });
}

// Conformance tests for `docs/RULES.md` section 3.3 -- the turn timer: items
// 14, 15 and 16, and items 16a and 16b, which this order adds because 14 to
// 16 between them never covered the case that actually stalled a table.
//
// Written against `RoomRegistry` and `buildExpiryFrames` directly rather than
// through a running `WireServer`: every claim in section 3.3 is about the
// injected clock and the registry's own state machine, and `FakeClock` makes
// those claims decidable without 45 real seconds passing anywhere, or a
// periodic timer having to fire on schedule inside a test.
//
// Nothing below steers the dice. The suite drives a table where NOBODY ever
// acts and asserts the properties that must hold whatever the faces are:
// every expiry advances `seq`, the segment always restarts, an
// `await_move` expiry always plays the lowest legal token index, and a game
// left entirely to the timer keeps rotating the turn instead of stopping.
// That is exactly the failure this order exists to end.
import 'dart:math';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// The default room rules, whose `turnSeconds` is the 45 of rule 14.
const RulesConfig _rules = RulesConfig();

/// One started two-seat game, its registry, and the clock that drives it.
typedef _Table = ({RoomRegistry registry, FakeClock clock, String code});

_Table _startedGame() {
  final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
  final RoomRegistry registry =
      RoomRegistry(clock: clock, secure: Random.secure());

  final CreateResult created =
      registry.createRoom(name: 'Host', players: 2, rules: _rules);
  expect(created, isA<CreateOk>(),
      reason: 'test setup: a 2-seat room must be creatable');
  final CreateOk host = created as CreateOk;

  expect(registry.joinRoom(code: host.room.code, name: 'Guest'),
      isA<JoinOk>(),
      reason: 'test setup: the second seat must be joinable');
  expect(
      registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken),
      isA<StartOk>(),
      reason: 'test setup: a full 2-seat room must start');

  return (registry: registry, clock: clock, code: host.room.code);
}

Duration _budget(Room room) => Duration(seconds: room.rules.turnSeconds);

void main() {
  group('an unexpired segment, rule 14', () {
    test('is not touched at all before its budget is spent', () {
      final _Table t = _startedGame();
      final Room room = t.registry.lookup(t.code)!;
      final int seqAtStart = room.seq;

      expect(t.registry.expireTurns(), isEmpty,
          reason: 'the segment opened this instant: nothing has expired');

      t.clock.advance(_budget(room) - const Duration(milliseconds: 1));
      expect(t.registry.expireTurns(), isEmpty,
          reason: 'one millisecond short of the budget is still inside it');
      expect(room.seq, seqAtStart,
          reason: 'a sweep that acts on nothing must change no state');
      expect(room.rollCount, 0,
          reason: 'and must not have drawn a die');
    });

    test('expires exactly at the budget, not a millisecond later', () {
      final _Table t = _startedGame();
      final Room room = t.registry.lookup(t.code)!;
      t.clock.advance(_budget(room));

      expect(t.registry.expireTurns(), hasLength(1),
          reason: 'rule 14: the budget is spent, so the server acts');
    });
  });

  group('a segment that expires while the seat still owes a roll, rule 16a',
      () {
    test('is rolled for by the server, through the room dice chain', () {
      final _Table t = _startedGame();
      final Room room = t.registry.lookup(t.code)!;
      final int seat = room.game!.currentSeat;
      final int seqBefore = room.seq;
      t.clock.advance(_budget(room));

      final List<ExpiredTurn> acted = t.registry.expireTurns();
      expect(acted, hasLength(1));
      expect(acted.single.code, t.code);
      expect(acted.single.seat, seat,
          reason: 'the server acts for the seat that owed the action');
      expect(acted.single.roll, isNotNull,
          reason: 'the phase was await_roll, so the action is a roll');
      expect(acted.single.move, isNull,
          reason: 'roll and move are mutually exclusive on one expiry');

      expect(room.rollCount, 1,
          reason: 'the chain advanced by exactly one link');
      expect(acted.single.roll!.k, 1,
          reason: 'and the frame names that same link');
      expect(room.seq, greaterThan(seqBefore),
          reason: 'a state change carries seq (PROTOCOL section 6)');
    });

    test('restarts the segment, so one expiry produces one action', () {
      final _Table t = _startedGame();
      final Room room = t.registry.lookup(t.code)!;
      t.clock.advance(_budget(room));
      expect(t.registry.expireTurns(), hasLength(1));

      expect(t.registry.expireTurns(), isEmpty,
          reason: 'the fresh segment has its full budget; sweeping again '
              'this instant must not act a second time');
      expect(room.rollCount, 1,
          reason: 'and must not have drawn a second die');
    });

    test('acts for a seat that is still connected, rule 16b', () {
      final _Table t = _startedGame();
      final Room room = t.registry.lookup(t.code)!;
      final int seat = room.game!.currentSeat;
      expect(
          room.seats.firstWhere((Seat s) => s.seat == seat).connected, isTrue,
          reason: 'test setup: this seat has not dropped');

      t.clock.advance(_budget(room));
      expect(t.registry.expireTurns(), hasLength(1),
          reason: 'the timer is a property of the segment, not the socket');
    });
  });

  group('a table nobody ever acts on', () {
    test(
        'keeps making progress: 60 expiries, every one of them advancing '
        'seq, and the turn rotating between the seats', () {
      final _Table t = _startedGame();
      final Room room = t.registry.lookup(t.code)!;

      final Set<int> seatsThatHeldTheTurn = <int>{room.game!.currentSeat};
      int moves = 0;
      int rolls = 0;

      for (int i = 0; i < 60; i++) {
        if (room.state != RoomState.playing) {
          break;
        }
        // Rule 15's ordering is checked against the legal set as it stood
        // BEFORE the timer acted, read here and compared below.
        final bool awaitingMove =
            room.game!.phase == engine.GamePhase.awaitMove;
        final List<int> legalBefore = awaitingMove
            ? (List<int>.of(engine.legalTokens(room.game!))..sort())
            : const <int>[];
        final int seqBefore = room.seq;

        t.clock.advance(_budget(room));
        final List<ExpiredTurn> acted = t.registry.expireTurns();

        if (awaitingMove && legalBefore.isEmpty) {
          // Rule 15's tail: no legal move means the turn already passed
          // under rule 7 and no segment was ever armed. Unreachable in
          // practice -- the engine passes the turn itself -- but asserted
          // rather than assumed.
          expect(acted, isEmpty);
          continue;
        }

        expect(acted, hasLength(1),
            reason: 'sweep $i: a fully expired segment must be acted on, '
                'phase=${room.game!.phase}');
        expect(room.seq, greaterThan(seqBefore),
            reason: 'sweep $i: every action the timer takes is a state '
                'change and carries seq');

        final MoveOk? move = acted.single.move;
        if (move != null) {
          moves++;
          final engine.Moved moved =
              move.events.whereType<engine.Moved>().single;
          expect(moved.token, legalBefore.first,
              reason: 'rule 15: with legal tokens $legalBefore the timer '
                  'plays the lowest index');
        } else {
          rolls++;
        }
        if (room.state == RoomState.playing) {
          seatsThatHeldTheTurn.add(room.game!.currentSeat);
        }
      }

      expect(rolls, greaterThan(0),
          reason: 'a table left to the timer must still be rolling');
      expect(moves, greaterThan(0),
          reason: 'and must still be moving tokens -- a run of 60 expiries '
              'that never once reached await_move would mean the roll path '
              'is not arming the selection segment');
      expect(seatsThatHeldTheTurn.length, greaterThan(1),
          reason: 'the whole point: the turn must leave the seat that '
              'stopped acting. This is the assertion that fails on the '
              'behaviour this order replaces, where the table stalled for '
              'ever on seat ${room.game?.currentSeat}');
    });
  });

  group('rooms the timer must not touch', () {
    test('a room still in LOBBY, however long it sits there', () {
      final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
      final RoomRegistry registry =
          RoomRegistry(clock: clock, secure: Random.secure());
      final CreateOk host = registry.createRoom(
          name: 'Host', players: 2, rules: _rules) as CreateOk;
      final int seqBefore = host.room.seq;

      clock.advance(const Duration(hours: 1));

      expect(registry.expireTurns(), isEmpty,
          reason: 'no game, no segment, nothing to play');
      expect(host.room.seq, seqBefore);
      expect(host.room.game, isNull);
    });

    test('a registry holding no rooms at all', () {
      final RoomRegistry registry = RoomRegistry(
          clock: FakeClock(DateTime.utc(2026, 1, 1)), secure: Random.secure());
      expect(registry.expireTurns(), isEmpty);
    });
  });

  group('the frames a timer-played turn publishes, PROTOCOL section 12', () {
    test('a roll publishes rolled, then turn_passed and turn together '
        'exactly when the roll ended the turn', () {
      final _Table t = _startedGame();
      final Room room = t.registry.lookup(t.code)!;
      t.clock.advance(_budget(room));
      final ExpiredTurn acted = t.registry.expireTurns().single;

      final List<OutFrame> frames = buildExpiryFrames(acted);
      final List<String> types =
          frames.map((OutFrame f) => f.type).toList(growable: false);

      expect(types.first, 'rolled');
      final bool turnEnded = acted.roll!.turnSeq != null;
      expect(
        types,
        turnEnded
            ? <String>['rolled', 'turn_passed', 'turn']
            : <String>['rolled'],
        reason: 'section 12.1 fixes both the set and the order',
      );
      for (final OutFrame frame in frames) {
        expect(frame.data.containsKey('re'), isFalse,
            reason: 'section 12.3: `re` answers a request, and no client '
                'request produced these frames');
      }
      expect(frames.first.data['k'], acted.roll!.k);
      expect(frames.first.data['seq'], acted.roll!.rolledSeq);
    });

    test('a move publishes moved, then turn', () {
      final _Table t = _startedGame();
      final Room room = t.registry.lookup(t.code)!;

      ExpiredTurn? moved;
      for (int i = 0; i < 60 && moved == null; i++) {
        if (room.state != RoomState.playing) {
          break;
        }
        t.clock.advance(_budget(room));
        for (final ExpiredTurn acted in t.registry.expireTurns()) {
          if (acted.move != null) {
            moved = acted;
          }
        }
      }
      expect(moved, isNotNull,
          reason: 'test setup: 60 expiries must produce at least one move');

      final List<String> types = buildExpiryFrames(moved!)
          .map((OutFrame f) => f.type)
          .toList(growable: false);
      expect(types.first, 'moved');
      expect(types.length, 2);
      expect(types.last, anyOf('turn', 'game_over'),
          reason: 'section 12.2: exactly one of the two follows moved');
    });
  });
}

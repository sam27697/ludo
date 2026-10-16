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
// The groups above the frame-order group do not steer the dice. They drive
// a table where nobody ever acts and assert the properties that must hold
// whatever the faces are: every expiry advances `seq`, the segment always
// restarts, an `await_move` expiry always plays the lowest legal token
// index, and a game left entirely to the timer keeps rotating the turn
// instead of stopping. That is exactly the failure this order exists to end.
//
// The frame-order group does steer, through the chain seam
// `test/dice_steering_test.dart` proves. Section 21.3 rule 4 gives a roll
// three frame orders, and the first face of a fresh game is a 6 often
// enough that asserting only one of them fails. Each order is reached on
// purpose. Which order an expiry published is read off the frames:
// `rolled.queue`, `rolled.legal`, and the following `turn`'s `seat` and
// `phase`.
import 'dart:math';

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/engine_search.dart';
import 'support/scripted_bytes.dart';

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

  expect(registry.joinRoom(code: host.room.code, name: 'Guest'), isA<JoinOk>(),
      reason: 'test setup: the second seat must be joinable');
  expect(
      registry.startGame(code: host.room.code, seatToken: host.seat.seatToken),
      isA<StartOk>(),
      reason: 'test setup: a full 2-seat room must start');

  return (registry: registry, clock: clock, code: host.room.code);
}

Duration _budget(Room room) => Duration(seconds: room.rules.turnSeconds);

/// Section 21.3 rule 4's three roll rows.
enum _RollRow { turnEnded, movePending, owesRoll }

/// Fixed 2-player seats (`_seatIndicesFor(2)` is `[0, 2]`, host then guest)
/// and the client seeds those seats will carry, so `client_seeds` is known
/// before the room exists. Same seam `dice_steering_test.dart` uses.
const List<int> _steeredSeats = <int>[0, 2];
const String _hostSteerSeed = 'turn-timer-host-seed';
const String _guestSteerSeed = 'turn-timer-guest-seed';
const String _steerClientSeeds = '0:$_hostSteerSeed|2:$_guestSteerSeed';

String _predictedGameId() {
  final List<int> probe = buildScript(
    secret: List<int>.filled(serverSecretDraws, 0),
  );
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

/// A started 2-seat game whose first [wanted] die faces are fixed by the
/// chain, not by `Random.secure`. Both seats set a client seed before
/// `startGame`, so that call draws no server seed and [gameIdOffset] still
/// names `game_id`.
_Table _steeredTable(List<int> wanted) {
  final String gameId = _predictedGameId();
  final SteeredSecret steered = findSecretForFaces(
    wanted: wanted,
    gameId: gameId,
    clientSeeds: _steerClientSeeds,
  );
  final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
  final RoomRegistry registry = RoomRegistry(
    clock: clock,
    secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
  );

  final CreateResult created =
      registry.createRoom(name: 'Host', players: 2, rules: _rules);
  expect(created, isA<CreateOk>(),
      reason: 'test setup: a 2-seat room must be creatable');
  final CreateOk host = created as CreateOk;
  final JoinResult joined =
      registry.joinRoom(code: host.room.code, name: 'Guest');
  expect(joined, isA<JoinOk>(),
      reason: 'test setup: the second seat must be joinable');
  final JoinOk guest = joined as JoinOk;
  expect(<int>[host.seat.seat, guest.seat.seat], _steeredSeats,
      reason: 'steering assumes host seat 0 and guest seat 2; got '
          'host=${host.seat.seat} guest=${guest.seat.seat}');

  expect(
    registry.setSeed(
      code: host.room.code,
      seatToken: host.seat.seatToken,
      clientSeed: _hostSteerSeed,
    ),
    isA<SetSeedOk>(),
    reason: 'test setup: the host seed must be accepted before start',
  );
  expect(
    registry.setSeed(
      code: host.room.code,
      seatToken: guest.seat.seatToken,
      clientSeed: _guestSteerSeed,
    ),
    isA<SetSeedOk>(),
    reason: 'test setup: the guest seed must be accepted before start',
  );
  final StartResult started = registry.startGame(
    code: host.room.code,
    seatToken: host.seat.seatToken,
  );
  expect(started, isA<StartOk>(),
      reason: 'test setup: a full 2-seat room must start');
  expect((started as StartOk).serverSeeded, isEmpty,
      reason: 'both seats already hold a client seed, so startGame must '
          'not draw server seeds; a draw there shifts game_id off the '
          'script this table was steered with');

  final Room room = registry.lookup(host.room.code)!;
  expect(room.gameId, gameId,
      reason: 'predicted game_id did not match the room; the draw-order '
          'picture in scripted_bytes.dart no longer matches registry.dart');
  expect(room.clientSeeds, _steerClientSeeds,
      reason: 'predicted client_seeds did not match the room');

  return (registry: registry, clock: clock, code: host.room.code);
}

List<int> _asInts(Object? value, String field) {
  expect(value, isA<List<int>>(),
      reason: '$field must be the int list section 21.3 puts on this frame');
  return value! as List<int>;
}

/// The row [step] is, from the engine's own `legal` and `TurnEnded`. A 6
/// that owes another roll is the remaining case: `legal` empty and no
/// `TurnEnded` (ENGINE_API.md 10.3).
_RollRow _rowOfStep(EngineRollStep step) {
  if (step.legal.isNotEmpty) {
    return _RollRow.movePending;
  }
  if (step.turnEndReason != null) {
    return _RollRow.turnEnded;
  }
  return _RollRow.owesRoll;
}

String _turnPassedReason(engine.TurnEndReason reason) {
  switch (reason) {
    case engine.TurnEndReason.noLegalMove:
      return 'no_legal_move';
    case engine.TurnEndReason.threeSixes:
      return 'three_sixes';
  }
}

/// Section 21.3 rule 4 for one timer roll. The row comes from `queue` and
/// `legal` on `rolled`; `seat` and `phase` on the following `turn` have to
/// be the ones that row names. The type list is then that row's order.
_RollRow _assertExpiryRoll(ExpiredTurn acted, {required int face}) {
  expect(acted.roll, isNotNull);
  expect(acted.move, isNull,
      reason: 'this helper is the roll rows; a move is a different step');

  final List<OutFrame> frames = buildExpiryFrames(acted);
  final List<String> types =
      frames.map((OutFrame f) => f.type).toList(growable: false);
  expect(types, isNotEmpty);
  expect(types.first, 'rolled');
  for (final OutFrame frame in frames) {
    expect(frame.data.containsKey('re'), isFalse,
        reason: 'section 12.3: `re` answers a request, and no client '
            'request produced these frames');
  }
  final Map<String, Object?> rolled = frames.first.data;
  expect(rolled['value'], face,
      reason: 'steering must produce the wanted face; wanted $face, '
          'got ${rolled['value']}');
  expect(rolled['k'], acted.roll!.k);
  expect(rolled['seq'], acted.roll!.rolledSeq);

  final List<int> queue = _asInts(rolled['queue'], 'rolled.queue');
  final List<int> legal = _asInts(rolled['legal'], 'rolled.legal');
  final int seat = rolled['seat']! as int;

  if (legal.isNotEmpty) {
    expect(queue, isNotEmpty,
        reason: 'a pending move is faces still sitting in the queue');
    expect(queue, contains(face),
        reason: 'the face just rolled is one of the unspent faces');
    expect(types, <String>['rolled'],
        reason: 'section 21.3: a roll that leaves a move pending publishes '
            'rolled alone');
    return _RollRow.movePending;
  }

  if (queue.isEmpty) {
    expect(types, <String>['rolled', 'turn_passed', 'turn'],
        reason: 'section 21.3: a roll that voided or passed the turn '
            'publishes rolled, then turn_passed, then turn');
    final Map<String, Object?> turn =
        frames.firstWhere((OutFrame f) => f.type == 'turn').data;
    expect(turn['seat'], isNot(seat),
        reason: 'a passed or voided turn hands the next seat the turn');
    expect(turn['phase'], 'await_roll');
    expect(_asInts(turn['queue'], 'turn.queue'), isEmpty);
    return _RollRow.turnEnded;
  }

  expect(types, <String>['rolled', 'turn'],
      reason: 'section 21.3: a 6 that owes another roll publishes rolled, '
          'then turn for the same seat, and no turn_passed');
  expect(queue, contains(face), reason: 'the owed face stays in the queue');
  final Map<String, Object?> turn =
      frames.firstWhere((OutFrame f) => f.type == 'turn').data;
  expect(turn['seat'], seat, reason: 'the same seat still holds the turn');
  expect(turn['phase'], 'await_roll');
  expect(_asInts(turn['queue'], 'turn.queue'), queue);
  return _RollRow.owesRoll;
}

/// Plays [accepts]'s shortest face sequence through the timer, one expiry
/// per face. Every expiry's frames must name the same row the engine step
/// names, and the last row must be [want].
void _driveRollRow(
  bool Function(EngineRollStep step, engine.GameState state) accepts,
  _RollRow want,
  String because,
) {
  final List<int>? faces = findFaceSequence(
    seats: _steeredSeats,
    rules: serverRoomRules,
    accepts: accepts,
  );
  expect(faces, isNotNull,
      reason: 'engine search found no face sequence that is $because');
  final List<EngineRollStep> steps = simulateFaces(
    seats: _steeredSeats,
    faces: faces!,
    rules: serverRoomRules,
  ).steps;
  final _Table table = _steeredTable(faces);
  final Room room = table.registry.lookup(table.code)!;

  for (int i = 0; i < faces.length; i++) {
    expect(room.game!.phase, engine.GamePhase.awaitRoll,
        reason: 'roll ${i + 1} of $faces ($because) is taken by the timer '
            'only while the seat still owes a roll');
    table.clock.advance(_budget(room));
    final List<ExpiredTurn> acted = table.registry.expireTurns();
    expect(acted, hasLength(1),
        reason: 'roll ${i + 1} of $faces ($because): one expired segment');
    final _RollRow row = _assertExpiryRoll(acted.single, face: faces[i]);
    expect(row, _rowOfStep(steps[i]),
        reason: 'roll ${i + 1} of $faces ($because): the frames and the '
            'engine step name different section 21.3 rows');
    final engine.TurnEndReason? end = steps[i].turnEndReason;
    if (end != null) {
      final OutFrame passed = buildExpiryFrames(acted.single)
          .firstWhere((OutFrame f) => f.type == 'turn_passed');
      expect(passed.data['reason'], _turnPassedReason(end),
          reason: 'turn_passed.reason is the engine TurnEndReason');
    }
  }
  expect(_rowOfStep(steps.last), want,
      reason: 'the sequence $faces found for "$because" does not end on '
          'that row');
}

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
      expect(room.rollCount, 0, reason: 'and must not have drawn a die');
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
      expect(room.rollCount, 1, reason: 'and must not have drawn a second die');
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

  group('the frames a timer-played turn publishes, PROTOCOL section 21.3', () {
    test(
        'a roll publishes rolled, then turn_passed and turn together '
        'exactly when the roll ended the turn', () {
      _driveRollRow(
        (EngineRollStep step, engine.GameState _) =>
            step.turnEndReason == engine.TurnEndReason.noLegalMove,
        _RollRow.turnEnded,
        'a roll that passes the turn',
      );
    });

    test(
        'a 6 that owes another roll publishes rolled, then turn for the '
        'same seat in await_roll', () {
      _driveRollRow(
        (EngineRollStep step, engine.GameState state) =>
            step.legal.isEmpty &&
            step.turnEndReason == null &&
            state.phase == engine.GamePhase.awaitRoll &&
            state.queue.isNotEmpty,
        _RollRow.owesRoll,
        'a 6 that owes another roll',
      );
    });

    test('a roll that leaves a move pending publishes rolled alone', () {
      _driveRollRow(
        (EngineRollStep step, engine.GameState _) => step.legal.isNotEmpty,
        _RollRow.movePending,
        'a roll that leaves a move pending',
      );
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

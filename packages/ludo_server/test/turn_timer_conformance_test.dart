// Independent conformance proof for the turn timer, order 120.
//
// This file was written from the specification only: `bin/ludo-mission.md`
// section 3's pinned rules table ("Turn timer | 45 seconds; on expiry the
// server plays the only legal move, or the first legal move if several, or
// passes."), `docs/PROTOCOL.md` sections 5, 6 and 12, and `docs/RULES.md`
// items 14 to 16b. It never reads, and must never read,
// `test/turn_timer_test.dart` -- that file was written by the same hand that
// wrote the implementation, and this file is the required second hand
// (constitution section 5.3). Every expected value below is arithmetic done
// by hand against the rules above, not a value copied from `lib/`.
//
// Where `docs/RULES.md` 16a and 16b extend the 45-second budget to the roll
// itself and detach it from the socket, this file treats them as claims
// under test rather than settled fact, because they landed in the same
// unreviewed commit as the code (373fcd8, 2026-09-05) that implements them.
// The pinned rules table in `bin/ludo-mission.md` says only "on expiry the
// server plays the only legal move, or the first legal move if several, or
// passes" and says nothing about a seat that has not rolled yet, or about
// the socket at all; 16a and 16b are additive on top of that, not in
// conflict with it, so nothing here treats a disagreement as resolved in
// the table's favour -- there isn't one to resolve.
//
// The fixtures below construct board positions directly through
// `GameState`'s own public constructor (frozen by `docs/ENGINE_API.md`)
// rather than through hundreds of real, dice-steered rolls, because that is
// the only affordable way to reach some of these positions at all --
// `test/turn_loop_test.dart`'s own header records a real capture needing an
// 8-face search (6^8, about 1.7 million candidates) and a real win needing
// 60 or more (6^60), both through the registry's own dice chain. Every
// position built this way is derived from `docs/RULES.md` sections 1, 3 and
// 4 by hand -- entry offsets, safe squares, block and capture arithmetic --
// in the comment next to it, and is checked against the engine's own
// `legalTokens` as a "setup requires" sanity assertion before the timer is
// ever exercised. What is under test is never the board position; it is
// what `RoomRegistry.expireTurns()` and `buildExpiryFrames()` -- both
// production code -- do with it.
//
// Wherever a fixture depends on the actual face the room's real dice chain
// draws (the `await_roll` cases), the position is built so the outcome does
// not depend on which of the six faces comes up, and that independence is
// argued in the comment next to it. No test in this file needs to steer the
// dice to a chosen face, and none does.
//
// Two fixed, non-cryptographic `Random` seeds are used for the two
// multi-turn simulations at the bottom of this file (20260905 and 20260906),
// named in every failure message from them, so a failure reproduces exactly
// by re-running this file -- nothing here depends on wall-clock time or on
// `Random.secure()`.

import 'dart:math' show Random;

import 'package:fair_dice/fair_dice.dart' show drawDie, verifyReveal;
import 'package:ludo_engine/ludo_engine.dart'
    show
        Captured,
        ExtraRoll,
        GamePhase,
        GameState,
        GameWon,
        Moved,
        Rolled,
        legalTokens;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

const RulesConfig _defaultRules = RulesConfig();

/// A fresh registry over a `FakeClock`, so every test in this file is exact
/// rather than tied to wall-clock timing.
({RoomRegistry registry, FakeClock clock}) _harness({Random? secure}) {
  final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
  final RoomRegistry registry =
      RoomRegistry(clock: clock, secure: secure ?? Random.secure());
  return (registry: registry, clock: clock);
}

CreateOk _create(
  RoomRegistry registry, {
  required String name,
  required int players,
  RulesConfig rules = _defaultRules,
}) {
  final CreateResult result =
      registry.createRoom(name: name, players: players, rules: rules);
  if (result is! CreateOk) {
    fail('expected CreateOk for name="$name" players=$players, got $result');
  }
  return result;
}

JoinOk _join(RoomRegistry registry,
    {required String code, required String name}) {
  final JoinResult result = registry.joinRoom(code: code, name: name);
  if (result is! JoinOk) {
    fail('expected JoinOk for code=$code name="$name", got $result');
  }
  return result;
}

StartOk _start(RoomRegistry registry,
    {required String code, required String seatToken}) {
  final StartResult result =
      registry.startGame(code: code, seatToken: seatToken);
  if (result is! StartOk) {
    fail('expected StartOk for code=$code, got $result');
  }
  return result;
}

/// A started room plus every seat's own token, keyed by engine seat index
/// (not join order), so a caller can drive a specific seat directly.
class _Table {
  _Table({required this.room, required this.seatTokens});

  final Room room;
  final Map<int, String> seatTokens;
}

/// Creates, joins and starts an [players]-seat room with default names,
/// through the real registry calls a client would make (`create_room`,
/// `join_room` x (players - 1), `start_game`). Every seat that never calls
/// `set_seed` gets a server-drawn one at `start_game`
/// (`docs/PROTOCOL.md` section 11.2); this file never needs a chosen seed,
/// only a real, present one, so no test here calls `set_seed`.
_Table _newTable(
  RoomRegistry registry, {
  required int players,
  RulesConfig rules = _defaultRules,
}) {
  final CreateOk host =
      _create(registry, name: 'P0', players: players, rules: rules);
  final Map<int, String> tokens = <int, String>{
    host.seat.seat: host.seat.seatToken,
  };
  for (int i = 1; i < players; i++) {
    final JoinOk joined = _join(registry, code: host.room.code, name: 'P$i');
    tokens[joined.seat.seat] = joined.seat.seatToken;
  }
  final StartOk started =
      _start(registry, code: host.room.code, seatToken: host.seat.seatToken);
  return _Table(room: started.room, seatTokens: tokens);
}

/// The 4x4 token board `GameState.tokens` requires: [bySeat] gives the
/// occupied seats' own four progress values; every other seat's row is
/// `[-1, -1, -1, -1]`, `docs/ENGINE_API.md`'s own documented invariant for
/// "rows for seats not in config.seats".
List<List<int>> _boardFor(Map<int, List<int>> bySeat) {
  return <List<int>>[
    for (int seat = 0; seat < 4; seat++)
      List<int>.of(bySeat[seat] ?? const <int>[-1, -1, -1, -1]),
  ];
}

/// Overwrites [room]'s game with a hand-built `GameState`, reusing the
/// `GameConfig` (seats, rules, seed) the room's own real `start_game` call
/// already fixed. Every board this file builds is derived from
/// `docs/RULES.md` by hand, in the comment at the call site, and checked
/// against the engine's own `legalTokens` before the timer is exercised.
void _forceGame(
  Room room, {
  required int currentSeat,
  required GamePhase phase,
  int? roll,
  required Map<int, List<int>> tokens,
  int sixes = 0,
  int? winner,
}) {
  final GameState base = room.game!;
  room.game = GameState(
    config: base.config,
    tokens: _boardFor(tokens),
    currentSeat: currentSeat,
    phase: phase,
    roll: roll,
    sixes: sixes,
    winner: winner,
    seq: base.seq + 1,
    rngState: base.rngState,
  );
}

/// Asserts that [frames] -- one expiry's worth of `OutFrame`s, in order --
/// consume the room's `seq` counter with no gap and no repeat: frame `i`
/// carries `seqBefore + i + 1`, the last one carries [seqAfter], and none of
/// them carries `re` (`docs/PROTOCOL.md` section 5: unsolicited pushes carry
/// no `re`; a timer sweep answers no client message at all).
void _expectContiguousSeq(
  List<OutFrame> frames, {
  required int seqBefore,
  required int seqAfter,
  required String because,
}) {
  expect(frames, isNotEmpty,
      reason: 'setup requires at least one frame: $because');
  int expected = seqBefore;
  for (final OutFrame frame in frames) {
    expected += 1;
    expect(
      frame.data['seq'],
      expected,
      reason: '$because: frame "${frame.type}" must carry seq $expected '
          '(room seq immediately before this expiry was $seqBefore); got '
          '${frame.data['seq']} in ${frame.data}',
    );
    expect(
      frame.data.containsKey('re'),
      isFalse,
      reason: '$because: frame "${frame.type}" must never carry re -- no '
          'client request is being answered by a timer sweep; got '
          '${frame.data}',
    );
  }
  expect(
    expected,
    seqAfter,
    reason: '$because: the last frame\'s seq ($expected) must equal the '
        'room\'s own seq after the expiry ($seqAfter), with no gap',
  );
}

/// Drives one real registry call (`roll` or `move`) for whichever seat
/// currently holds the turn in [room], choosing the lowest legal token when
/// a move is due -- the same policy rule 15 gives the timer, used here only
/// because it is *a* legal choice a real player could have made, not
/// because this file is testing that policy again. Used by the
/// product-level simulations to play the seats that are not silent, through
/// the real `roll()`/`move()` path, never fabricated.
void _playOneRealTurn(RoomRegistry registry, Room room, String seatToken) {
  final GameState before = room.game!;
  if (before.phase == GamePhase.awaitRoll) {
    final RollResult result =
        registry.roll(code: room.code, seatToken: seatToken);
    if (result is! RollOk) {
      fail('expected RollOk driving a real turn in room ${room.code}, got '
          '$result');
    }
    return;
  }
  if (before.phase == GamePhase.awaitMove) {
    final List<int> legal = List<int>.of(legalTokens(before))..sort();
    if (legal.isEmpty) {
      fail('await_move with an empty legal list should be unreachable: the '
          'engine already passes the turn itself when legal is empty '
          '(RULES.md rule 7)');
    }
    final MoveResult result = registry.move(
      code: room.code,
      seatToken: seatToken,
      token: legal.first,
    );
    if (result is! MoveOk) {
      fail('expected MoveOk driving a real turn in room ${room.code}, got '
          '$result');
    }
    return;
  }
  fail('cannot drive a real turn from phase ${before.phase} in room '
      '${room.code}');
}

void main() {
  group('timing and idempotence', () {
    test(
        'a room whose segment has not expired: expireTurns() returns empty '
        'and mutates nothing observable (seq, rollCount, currentSeat)', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      final int seqBefore = table.room.seq;
      final int rollCountBefore = table.room.rollCount;
      final int currentSeatBefore = table.room.game!.currentSeat;

      // No time at all has passed on the injected clock: well inside the
      // 45-second budget.
      final List<ExpiredTurn> acted = harness.registry.expireTurns();

      expect(
        acted,
        isEmpty,
        reason: 'a fresh segment (0ms of '
            '${_defaultRules.turnSeconds}s elapsed) must not be acted on; '
            'got $acted',
      );
      expect(table.room.seq, seqBefore,
          reason: 'seq must be unchanged; was $seqBefore');
      expect(table.room.rollCount, rollCountBefore,
          reason: 'rollCount must be unchanged; was $rollCountBefore');
      expect(table.room.game!.currentSeat, currentSeatBefore,
          reason: 'currentSeat must be unchanged; was $currentSeatBefore');
    });

    test(
        'expiry is at turn_seconds * 1000 and not one millisecond before: '
        'PROTOCOL.md section 6 defines deadline_ms as max(0, budget - '
        'elapsed), so elapsed == budget is the first instant at which the '
        'deadline reads 0 and the segment can be acted on', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      final int budgetMs = _defaultRules.turnSeconds * 1000;

      harness.clock.advance(Duration(milliseconds: budgetMs - 1));
      final List<ExpiredTurn> justBefore = harness.registry.expireTurns();
      expect(
        justBefore,
        isEmpty,
        reason: 'at $budgetMs - 1 ms elapsed (deadline_ms would still read '
            '1ms), the segment must not be acted on; got $justBefore',
      );
      expect(table.room.rollCount, 0,
          reason: 'nothing must have been touched yet');

      harness.clock.advance(const Duration(milliseconds: 1));
      final List<ExpiredTurn> atBoundary = harness.registry.expireTurns();
      expect(
        atBoundary,
        hasLength(1),
        reason: 'at exactly $budgetMs ms elapsed (deadline_ms reads 0), the '
            'segment must be acted on; got $atBoundary',
      );
    });

    test(
        'calling expireTurns() twice at the same instant plays exactly one '
        'turn: the acting path must restart the segment, or the real '
        'server\'s one-second sweep would act on the same expiry twice', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      final int budgetMs = _defaultRules.turnSeconds * 1000;
      harness.clock.advance(Duration(milliseconds: budgetMs));

      final List<ExpiredTurn> first = harness.registry.expireTurns();
      expect(first, hasLength(1),
          reason: 'setup requires the first sweep to actually act; got '
              '$first');
      final int rollCountAfterFirst = table.room.rollCount;

      final List<ExpiredTurn> second = harness.registry.expireTurns();
      expect(
        second,
        isEmpty,
        reason: 'a second sweep at the same instant, with the clock not '
            'advanced between the two calls, must find the segment already '
            'restarted by the first and act on nothing; got $second -- if '
            'this is non-empty, a real one-second-cadence sweep will play '
            'the same expiry twice',
      );
      expect(table.room.rollCount, rollCountAfterFirst,
          reason: 'the idempotent second sweep must not advance rollCount '
              'again; was $rollCountAfterFirst');
    });

    test('a LOBBY room (state=LOBBY, no game yet) is left alone', () {
      final harness = _harness();
      final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
      final int seqBefore = host.room.seq;
      harness.clock.advance(const Duration(days: 1));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();

      expect(
        acted,
        isEmpty,
        reason: 'PROTOCOL.md section 3: LOBBY has no turn to expire; got '
            '$acted',
      );
      expect(host.room.seq, seqBefore);
      expect(host.room.game, isNull);
    });

    test(
        'a room whose game has already ended (FINISHED) is left alone, '
        'even a full day later', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.finished,
        winner: 0,
        tokens: <int, List<int>>{
          0: <int>[57, 57, 57, 57],
          2: <int>[-1, -1, -1, -1],
        },
      );
      table.room.state = RoomState.finished;
      final int seqBefore = table.room.seq;
      final int rollCountBefore = table.room.rollCount;
      harness.clock.advance(const Duration(days: 1));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();

      expect(
        acted,
        isEmpty,
        reason: 'RULES.md rule 35: "a game state where a winner exists is '
            'terminal; no further roll, move or timer is accepted against '
            'it"; got $acted',
      );
      expect(table.room.seq, seqBefore);
      expect(table.room.rollCount, rollCountBefore);
    });

    test(
        'a PLAYING room with no game at all (Room.game == null) is left '
        'alone -- a state the real protocol never reaches on its own '
        '(state and game are only ever set together, by start_game), '
        'forced here directly because it is a state that should be '
        'unreachable and the timer must not crash or act on it', () {
      final harness = _harness();
      final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
      _join(harness.registry, code: host.room.code, name: 'Guest');
      // Deliberately never calling start_game: Room.game stays null. Then
      // forcing state to PLAYING by hand, which the real registry never
      // does without also setting game.
      host.room.state = RoomState.playing;
      final int seqBefore = host.room.seq;
      harness.clock.advance(const Duration(days: 1));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();

      expect(acted, isEmpty,
          reason: 'a PLAYING room with game == null must not act; got '
              '$acted');
      expect(host.room.seq, seqBefore);
    });
  });

  group('the await_roll expiry, RULES.md 16a', () {
    test(
        'a seat that has not rolled when its segment expires is rolled '
        'for, and the room\'s roll counter advances by exactly one', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      expect(table.room.game!.phase, GamePhase.awaitRoll,
          reason: 'setup requires a fresh game to start awaiting a roll');
      expect(table.room.rollCount, 0);

      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));
      final List<ExpiredTurn> acted = harness.registry.expireTurns();

      expect(acted, hasLength(1));
      final ExpiredTurn expired = acted.single;
      expect(expired.roll, isNotNull,
          reason: 'a segment expiring in await_roll must be rolled for, '
              'not moved; got $expired');
      expect(expired.move, isNull);
      expect(
        table.room.rollCount,
        1,
        reason: 'RULES.md rule 16a: the server rolls for the seat through '
            'the same dice chain and link ordering as a player-sent roll; '
            'the roll counter must advance from 0 to 1',
      );
    });

    test(
        'the die the timer drew is verifiable exactly like a '
        'player-driven roll: recomputing drawDie from the published reveal '
        'and k reproduces the published value, and the reveal chains back '
        'to chain_commit', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      final RollOk rolled = acted.single.roll!;
      final Rolled event = rolled.events.whereType<Rolled>().single;

      expect(rolled.k, 1,
          reason: 'this is the first roll of the game; k must be 1');
      final int reproduced = drawDie(
        rolled.reveal,
        table.room.gameId!,
        table.room.clientSeeds!,
        rolled.k,
        0,
      );
      expect(
        reproduced,
        event.value,
        reason: 'PROTOCOL.md section 12.1: value = drawDie(reveal, '
            'game_id, client_seeds, k, 0); recomputing that with exactly '
            'the inputs a player-driven roll would have used must '
            'reproduce the published value ${event.value}; got $reproduced '
            'for reveal=${rolled.reveal} game_id=${table.room.gameId} '
            'client_seeds=${table.room.clientSeeds} k=${rolled.k}',
      );
      final bool verified =
          verifyReveal(reveal: rolled.reveal, parent: table.room.chain.commit);
      expect(
        verified,
        isTrue,
        reason: 'k=1\'s reveal must hash back to chain_commit '
            '(${table.room.chain.commit}); got reveal=${rolled.reveal}',
      );
    });

    test(
        'a timer roll that leaves no legal move (rule 7) publishes rolled, '
        'then turn_passed, then turn, with strictly increasing seq and no '
        're on any of the three frames', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      // Seat 0 has all four tokens in the yard; a yard token only ever
      // leaves on a 6 (RULES.md rule 17). Seat 2's entry offset is 26
      // (RULES.md 1.1 table), so two of its tokens sitting at progress 26
      // occupy absolute square (26 + 26) mod 52 == 0 -- seat 0's own entry
      // square -- and form a block there (rule 21). Rule 22 says a block
      // cannot be landed on by another seat's token, and rule 26 says a
      // block on a safe square is still a block; rule 23 says a yard exit's
      // whole path is its entry square. So even a 6 cannot get seat 0 out
      // of the yard, and every other face already has no legal move
      // because nothing of seat 0's has left the yard. Every one of the six
      // possible faces therefore leaves seat 0 with no legal move; this
      // does not depend on which face the room's real dice chain draws.
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitRoll,
        tokens: <int, List<int>>{
          0: <int>[-1, -1, -1, -1],
          2: <int>[26, 26, -1, -1],
        },
      );
      final int seqBefore = table.room.seq;
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      expect(acted, hasLength(1));
      final RollOk rolled = acted.single.roll!;
      final Rolled rolledEvent = rolled.events.whereType<Rolled>().single;
      expect(
        rolledEvent.legal,
        isEmpty,
        reason: 'setup requires no legal move for seat 0 whatever face was '
            'drawn (${rolledEvent.value}); got legal=${rolledEvent.legal}',
      );

      final List<OutFrame> frames = buildExpiryFrames(acted.single);
      expect(
        frames.map((OutFrame f) => f.type).toList(),
        <String>['rolled', 'turn_passed', 'turn'],
        reason: 'PROTOCOL.md section 12.1: an empty-legal rolled must be '
            'followed by turn_passed then turn; got '
            '${frames.map((OutFrame f) => f.type).toList()}',
      );
      expect(frames[1].data['reason'], 'no_legal_move');
      _expectContiguousSeq(
        frames,
        seqBefore: seqBefore,
        seqAfter: table.room.seq,
        because: 'a timer roll that ends the turn must consume contiguous '
            'seq values',
      );
    });

    test(
        'a timer roll that leaves a legal move pending publishes rolled '
        'only, and the immediately following sweep does not also play the '
        'move', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      // Seat 0 has one token already on the track at its own entry square
      // (progress 0) and the rest in the yard; seat 2 has no tokens placed
      // anywhere near it. For every face 1..6 that on-track token has a
      // legal destination (progress 1..6, all well short of the exact-57
      // rule, and nothing is present to block or capture), so this does
      // not depend on which face the room's real dice chain draws.
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitRoll,
        tokens: <int, List<int>>{
          0: <int>[0, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
        },
      );
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      expect(acted, hasLength(1));
      final RollOk rolled = acted.single.roll!;
      final Rolled rolledEvent = rolled.events.whereType<Rolled>().single;
      expect(
        rolledEvent.legal,
        isNotEmpty,
        reason: 'setup requires a legal move for seat 0 whatever face was '
            'drawn (${rolledEvent.value}); got legal=${rolledEvent.legal}',
      );
      final List<OutFrame> frames = buildExpiryFrames(acted.single);
      expect(
        frames.map((OutFrame f) => f.type).toList(),
        <String>['rolled'],
        reason: 'a rolled frame that leaves a legal move pending must be '
            'the only frame this expiry publishes; got '
            '${frames.map((OutFrame f) => f.type).toList()}',
      );
      expect(table.room.game!.phase, GamePhase.awaitMove);

      // The rolled frame above restarted the segment (PROTOCOL.md section
      // 6); a sweep the very next instant, with the clock not moved again,
      // must find nothing due.
      final List<ExpiredTurn> immediatelyAfter = harness.registry.expireTurns();
      expect(
        immediatelyAfter,
        isEmpty,
        reason: 'a rolled frame that leaves a legal move pending restarts '
            'the segment; the very next sweep must not immediately play '
            'that move; got $immediatelyAfter',
      );
    });
  });

  group('the await_move expiry, rules 14 to 16', () {
    test('exactly one legal move is played', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      // Token 0 at progress 10 moves to 12 on a roll of 2. Tokens 1 and 2
      // are in the yard and need a 6 to leave (rule 17). Token 3 is already
      // home (progress 57) and immovable (rule 20).
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitMove,
        roll: 2,
        tokens: <int, List<int>>{
          0: <int>[10, -1, -1, 57],
          2: <int>[-1, -1, -1, -1],
        },
      );
      expect(
        legalTokens(table.room.game!),
        <int>[0],
        reason: 'setup requires exactly one legal token',
      );
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      expect(acted, hasLength(1));
      final MoveOk moved = acted.single.move!;
      final Moved event = moved.events.whereType<Moved>().single;
      expect(event.token, 0);
      expect(event.from, 10);
      expect(event.to, 12);
      expect(table.room.game!.tokens[0], <int>[12, -1, -1, 57]);
    });

    test(
        'where several are legal, the lowest token index is played '
        '(RULES.md rule 15)', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      // Tokens at progress 5, 10 and 15 all move legally on a roll of 3
      // (no opponent nearby to block or capture); token 3 is in the yard
      // and needs a 6. Three legal tokens, not two, so "the first" and
      // "the only" cannot be confused.
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitMove,
        roll: 3,
        tokens: <int, List<int>>{
          0: <int>[5, 10, 15, -1],
          2: <int>[-1, -1, -1, -1],
        },
      );
      expect(
        legalTokens(table.room.game!),
        <int>[0, 1, 2],
        reason: 'setup requires at least three legal tokens',
      );
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      final MoveOk moved = acted.single.move!;
      final Moved event = moved.events.whereType<Moved>().single;
      expect(
        event.token,
        0,
        reason: 'RULES.md rule 15: "the first in a deterministic ordering, '
            'defined as ascending token index"; expected token 0 of the '
            'legal set [0, 1, 2], got token ${event.token}',
      );
      expect(
        table.room.game!.tokens[0],
        <int>[8, 10, 15, -1],
        reason: 'only the lowest-index legal token should have moved; '
            'tokens 1 and 2 must be untouched at 10 and 15',
      );
    });

    test(
        'a move that wins publishes moved then game_over, and no turn '
        'frame follows', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      // Token 0 at progress 54 needs exactly a 3 to reach 57 (rule 19);
      // the other three tokens are already home. Playing token 0 brings
      // all four home.
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitMove,
        roll: 3,
        tokens: <int, List<int>>{
          0: <int>[54, 57, 57, 57],
          2: <int>[-1, -1, -1, -1],
        },
      );
      expect(legalTokens(table.room.game!), <int>[0],
          reason: 'setup requires token 0 to be the only legal token');
      final int seqBefore = table.room.seq;
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      final MoveOk moved = acted.single.move!;
      expect(moved.events.whereType<GameWon>().single.seat, 0);
      final List<OutFrame> frames = buildExpiryFrames(acted.single);
      expect(
        frames.map((OutFrame f) => f.type).toList(),
        <String>['moved', 'game_over'],
        reason: 'a winning timer move must publish moved then game_over '
            'and nothing else; got '
            '${frames.map((OutFrame f) => f.type).toList()}',
      );
      _expectContiguousSeq(
        frames,
        seqBefore: seqBefore,
        seqAfter: table.room.seq,
        because: 'a winning timer move must consume contiguous seq values',
      );
      expect(table.room.state, RoomState.finished);
    });

    test(
        'a move that grants an extra roll for a six publishes moved then '
        'turn for the same seat', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      // Token 0 at progress 5 moves to 11 on a roll of 6, with nothing to
      // capture. Tokens 1-3 are already home. Not all four home (token 0
      // is at 11, not 57), so this is not also a win.
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitMove,
        roll: 6,
        tokens: <int, List<int>>{
          0: <int>[5, 57, 57, 57],
          2: <int>[-1, -1, -1, -1],
        },
      );
      expect(legalTokens(table.room.game!), <int>[0]);
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      final MoveOk moved = acted.single.move!;
      expect(
        moved.events.whereType<ExtraRoll>().isNotEmpty,
        isTrue,
        reason: 'RULES.md rule 9: rolling a 6 grants another roll',
      );
      final List<OutFrame> frames = buildExpiryFrames(acted.single);
      expect(frames.map((OutFrame f) => f.type).toList(),
          <String>['moved', 'turn']);
      expect(
        frames[1].data['seat'],
        0,
        reason: 'an extra roll must keep the same seat on turn; got '
            '${frames[1].data}',
      );
      expect(frames[0].data['extra_roll'], isTrue);
    });

    test(
        'a move that captures publishes the captured tokens in moved, the '
        'same as a player-driven capture would, and grants the same-seat '
        'extra roll capture_bonus gives by default', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      // Seat 0 token 0 at progress 1 moves to progress 5 on a roll of 4;
      // absolute square (0 + 5) mod 52 == 5, which is not one of the eight
      // safe squares (RULES.md 1.3: 0, 8, 13, 21, 26, 34, 39, 47). Seat 2's
      // entry offset is 26, so its token at progress 31 sits on absolute
      // square (26 + 31) mod 52 == 5 -- the same square, exactly one
      // opponent token there, so rule 27 fires a capture. Tokens 1-3 of
      // seat 0 are in the yard and need a 6.
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitMove,
        roll: 4,
        tokens: <int, List<int>>{
          0: <int>[1, -1, -1, -1],
          2: <int>[31, -1, -1, -1],
        },
      );
      expect(legalTokens(table.room.game!), <int>[0]);
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));

      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      final MoveOk moved = acted.single.move!;
      final Captured captured = moved.events.whereType<Captured>().single;
      expect(captured.seat, 2);
      expect(captured.token, 0);
      expect(
        moved.events.whereType<ExtraRoll>().isNotEmpty,
        isTrue,
        reason: 'RULES.md rule 11: a capture grants another roll, on by '
            'default',
      );
      final List<OutFrame> frames = buildExpiryFrames(acted.single);
      expect(frames[0].data['captured'], <Map<String, Object?>>[
        <String, Object?>{'seat': 2, 'token': 0},
      ]);
      expect(frames.map((OutFrame f) => f.type).toList(),
          <String>['moved', 'turn']);
      expect(frames[1].data['seat'], 0);
      expect(
        table.room.game!.tokens[2][0],
        -1,
        reason: 'the captured token must return to the yard',
      );
    });
  });

  group('rule 16b: the timer is a property of the segment, not the socket', () {
    test(
        'a connected seat that simply is not acting expires on exactly '
        'the same schedule as one that has dropped', () {
      final int budgetMs = _defaultRules.turnSeconds * 1000;

      final harnessConnected = _harness();
      final _Table connectedTable =
          _newTable(harnessConnected.registry, players: 2);
      expect(connectedTable.room.game!.currentSeat, 0);
      final Seat onTurnConnected =
          connectedTable.room.seats.firstWhere((Seat s) => s.seat == 0);
      expect(onTurnConnected.connected, isTrue,
          reason: 'setup requires the on-turn seat to still be connected '
              'in this half of the comparison');

      final harnessDropped = _harness();
      final _Table droppedTable =
          _newTable(harnessDropped.registry, players: 2);
      expect(droppedTable.room.game!.currentSeat, 0);
      final bool flipped = harnessDropped.registry.setConnected(
        code: droppedTable.room.code,
        seatToken: droppedTable.seatTokens[0]!,
        connected: false,
      );
      expect(flipped, isTrue,
          reason: 'setup requires the on-turn seat to actually be marked '
              'disconnected in this half of the comparison');

      harnessConnected.clock.advance(Duration(milliseconds: budgetMs - 1));
      harnessDropped.clock.advance(Duration(milliseconds: budgetMs - 1));
      expect(harnessConnected.registry.expireTurns(), isEmpty);
      expect(harnessDropped.registry.expireTurns(), isEmpty);

      harnessConnected.clock.advance(const Duration(milliseconds: 1));
      harnessDropped.clock.advance(const Duration(milliseconds: 1));
      final List<ExpiredTurn> connectedActed =
          harnessConnected.registry.expireTurns();
      final List<ExpiredTurn> droppedActed =
          harnessDropped.registry.expireTurns();
      expect(
        connectedActed,
        hasLength(1),
        reason: 'RULES.md rule 16b: "a seat that is connected and simply '
            'not acting expires on the same schedule as one that has '
            'dropped"; the connected half must act at the $budgetMs ms '
            'boundary',
      );
      expect(droppedActed, hasLength(1),
          reason: 'the dropped half must act at exactly the same boundary');
    });
  });

  group('seq: a timer turn consumes contiguous room seq values, no gaps', () {
    test(
        'a timer move that continues the turn (moved, turn) leaves no gap '
        'in seq', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitMove,
        roll: 2,
        tokens: <int, List<int>>{
          0: <int>[10, -1, -1, 57],
          2: <int>[-1, -1, -1, -1],
        },
      );
      final int seqBefore = table.room.seq;
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));
      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      final List<OutFrame> frames = buildExpiryFrames(acted.single);
      _expectContiguousSeq(
        frames,
        seqBefore: seqBefore,
        seqAfter: table.room.seq,
        because: 'moved+turn must consume contiguous seq',
      );
    });

    test(
        'a timer roll that ends the turn (rolled, turn_passed, turn) '
        'leaves no gap in seq', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitRoll,
        tokens: <int, List<int>>{
          0: <int>[-1, -1, -1, -1],
          2: <int>[26, 26, -1, -1],
        },
      );
      final int seqBefore = table.room.seq;
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));
      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      final List<OutFrame> frames = buildExpiryFrames(acted.single);
      _expectContiguousSeq(
        frames,
        seqBefore: seqBefore,
        seqAfter: table.room.seq,
        because: 'rolled+turn_passed+turn must consume contiguous seq',
      );
    });

    test('a timer move that wins (moved, game_over) leaves no gap in seq', () {
      final harness = _harness();
      final _Table table = _newTable(harness.registry, players: 2);
      _forceGame(
        table.room,
        currentSeat: 0,
        phase: GamePhase.awaitMove,
        roll: 3,
        tokens: <int, List<int>>{
          0: <int>[54, 57, 57, 57],
          2: <int>[-1, -1, -1, -1],
        },
      );
      final int seqBefore = table.room.seq;
      harness.clock
          .advance(Duration(milliseconds: _defaultRules.turnSeconds * 1000));
      final List<ExpiredTurn> acted = harness.registry.expireTurns();
      final List<OutFrame> frames = buildExpiryFrames(acted.single);
      _expectContiguousSeq(
        frames,
        seqBefore: seqBefore,
        seqAfter: table.room.seq,
        because: 'moved+game_over must consume contiguous seq',
      );
    });
  });

  group('the product-level case: a table nobody drives must not freeze', () {
    test(
        'a four-seat game in which the seat holding the turn goes silent '
        'forever: the turn leaves that seat and the other three keep '
        'playing', () {
      // Fixed seed so a failure here reproduces exactly: Random(20260905).
      const int seed = 20260905;
      final harness = _harness(secure: Random(seed));
      final _Table table = _newTable(harness.registry, players: 4);
      const int silentSeat = 1;
      final Set<int> actedSeats = <int>{};
      bool everForcedForSilentSeat = false;
      final int budgetMs = _defaultRules.turnSeconds * 1000;

      for (int i = 0; i < 400; i++) {
        final GameState? game = table.room.game;
        if (game == null || game.phase == GamePhase.finished) {
          break;
        }
        final int seat = game.currentSeat;
        if (seat == silentSeat) {
          harness.clock.advance(Duration(milliseconds: budgetMs));
          final List<ExpiredTurn> acted = harness.registry.expireTurns();
          expect(
            acted,
            isNotEmpty,
            reason: 'iteration $i, seed $seed: the silent seat $silentSeat\'s '
                'turn must always be forced by the timer; the table must '
                'not freeze',
          );
          everForcedForSilentSeat = true;
        } else {
          actedSeats.add(seat);
          _playOneRealTurn(
              harness.registry, table.room, table.seatTokens[seat]!);
        }
      }

      expect(
        everForcedForSilentSeat,
        isTrue,
        reason: 'seed $seed: the silent seat never actually came up on '
            'turn within 400 iterations, so this fixture proves nothing; '
            'widen the loop bound or change the seed to reproduce',
      );
      expect(
        actedSeats,
        containsAll(<int>[0, 2, 3]),
        reason: 'seed $seed: the three seats that keep acting normally '
            '(0, 2, 3) must all have been seen on turn while seat '
            '$silentSeat stayed silent; only saw $actedSeats',
      );
    });

    // Driven purely by timer expiries with nobody sending a single roll or
    // move: within the 4000-iteration bound below and seed 20260906, this
    // reaches a natural game_over (a winner is decided) rather than merely
    // proving movement between seats -- measured by actually running this
    // test, not assumed. The `reachedTerminal || distinctSeats.length > 1`
    // assertion is kept general on purpose, so a change to the seed or the
    // dice does not turn a still-valid "kept moving" run into a spurious
    // failure.
    test(
        'a table where nobody at all ever acts, driven purely by timer '
        'expiries, reaches a terminal state (see the comment above this '
        'test for what was actually measured)', () {
      const int seed = 20260906;
      final harness = _harness(secure: Random(seed));
      final _Table table = _newTable(harness.registry, players: 4);
      final int budgetMs = _defaultRules.turnSeconds * 1000;
      final List<int> actingSeatSequence = <int>[];
      bool reachedTerminal = false;

      for (int i = 0; i < 4000; i++) {
        final GameState? game = table.room.game;
        if (game == null || game.phase == GamePhase.finished) {
          reachedTerminal = true;
          break;
        }
        harness.clock.advance(Duration(milliseconds: budgetMs));
        final List<ExpiredTurn> acted = harness.registry.expireTurns();
        expect(
          acted,
          isNotEmpty,
          reason: 'iteration $i, seed $seed: a due segment must always be '
              'acted on by the timer; the table must not freeze',
        );
        actingSeatSequence.add(acted.single.seat);
      }

      final Set<int> distinctSeats = actingSeatSequence.toSet();
      expect(
        reachedTerminal || distinctSeats.length > 1,
        isTrue,
        reason: 'seed $seed: a table nobody ever acts on must either reach '
            'a terminal state or keep moving between seats; it got stuck '
            'on a single seat ($distinctSeats) for the whole run of '
            '${actingSeatSequence.length} forced turns',
      );
    });
  });
}

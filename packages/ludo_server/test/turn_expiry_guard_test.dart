// Order 125 -- the frozen contract between this order and the fix landing
// on a different branch for the same two defects, measured on `main` at
// `8ac430f`:
//
//   Defect A. `WireServer._runTurnExpiry` calls `registry.expireTurns()` in
//   the `for` statement's header, outside the `try` on the next line. A
//   throw from it escapes the method, escapes the `Timer.periodic`
//   callback, and -- with no `runZonedGuarded` in `bin/server.dart` --
//   terminates the isolate in production.
//
//   Defect B. `RoomRegistry.expireTurns()` has paths that leave a room's
//   already-expired segment without producing an `ExpiredTurn` and without
//   restarting the segment, so the next sweep, one second later, finds the
//   same expired segment and does the same nothing again, for ever.
//
// C1, C2 and C3 below are the master's contract, not this file's invention:
//
//   C1. No outcome of `registry.expireTurns()` may escape `_runTurnExpiry`.
//   A throw from it is caught, logged, and the periodic timer keeps
//   ticking.
//
//   C2. When a sweep passes the "this room's segment has expired" check and
//   does not produce an `ExpiredTurn` for that room, it restarts that
//   room's turn segment before moving on -- observed here as: a second
//   sweep one tick later does not act on that room again.
//
//   C3. Every such declined room prints exactly one line per sweep:
//     turn-expiry skipped room=<CODE> seat=<N> phase=<PHASE> reason=<REASON>
//   with ` error=<NAME>` appended for the two failure reasons only.
//
// This suite is written against that contract, not against what
// `_runTurnExpiry` and `expireTurns()` currently do. It is expected to be
// red on this branch: that redness is the evidence the two defects are
// real, and it is this order's entire deliverable.
//
// Reachability, read from the source rather than assumed from the work
// order's own summary (the order explicitly asks for this check):
//
//   - roll_failed and move_failed are both reachable honestly, by
//     subclassing `RoomRegistry` and overriding the ordinary public
//     `roll`/`move` instance methods `expireTurns()` already calls
//     unqualified, so they dispatch on `this`. Tested below, each with its
//     own C2 and C3 case.
//   - no_seat is NOT reachable through any public `RoomRegistry` API once a
//     room is PLAYING: `leaveRoom`'s PLAYING branch only flips
//     `seat.connected`, it never removes the seat from `room.seats`, and
//     there is no other public method that shortens `room.seats` for a
//     started room. `Room.seats` is a mutable public field, so a test could
//     null out a seat by writing to it directly -- but that is exactly the
//     "contorting the registry into a state the server could never
//     produce" the order warns against, since no protocol path can ever
//     produce a PLAYING room whose current-turn seat is entirely absent
//     from `room.seats`. Not tested; this paragraph is the finding.
//   - unhandled_phase is NOT reachable at all: `engine.GamePhase` has
//     exactly three values (`awaitRoll`, `awaitMove`, `finished`), and
//     `expireTurns()` already filters `finished` out one `if` above the
//     `if`/`else if` in question. The two branches of that `if`/`else if`
//     therefore cover every phase that can still reach it -- there is no
//     third live phase for either the current source or the frozen
//     `GamePhase` enum to produce. Not tested; dead code, not a gap.
//   - no_legal_tokens (an empty `legalTokens` while `awaitMove`) is not
//     tested either. `packages/ludo_server/test/turn_timer_test.dart`
//     already documents, in its own "a table nobody ever acts on" case,
//     that this is unreachable in practice: the engine passes the turn
//     itself whenever no legal move exists, so a room the sweep finds
//     sitting in `awaitMove` always has at least one legal token by
//     construction. Constructing an empty set here would mean forging
//     `room.game` directly, the same objection as `no_seat` above.
//
// Seams used, all from the work order's own list, none of them a source
// change:
//   - `RoomRegistry` is an ordinary non-final class with a `required`
//     constructor and ordinary public `expireTurns`/`roll`/`move`
//     instance methods; a test-local subclass overrides what it needs and
//     leaves the rest to the real implementation.
//   - An error thrown out of a `Timer.periodic` callback is routed to the
//     zone's `onError` rather than crashing anything, when the timer was
//     started inside `runZonedGuarded`; this is how C1 is observed from
//     inside a single test isolate, without claiming the test proves a
//     bare, unguarded process would have survived -- `bin/server.dart`
//     itself carries no such guard, which is precisely Defect A.
//   - Verified directly before relying on it (see `/tmp/timer_probe` in
//     the accompanying report, not part of this file): a periodic timer
//     whose callback throws keeps firing on schedule; the throw does not
//     cancel it.
//   - `print` is captured with `runZoned` and a `ZoneSpecification.print`
//     override. The synchronous cases (C2/C3 for roll_failed/move_failed)
//     call `expireTurns()` directly inside that zone, so no asynchronous
//     gap is involved. C1 does not need this seam: it asserts on the zone
//     error handler and on `expireTurns()`'s own call count instead.
//   - `turnExpiryInterval` is a hardcoded 1-second real Timer.periodic, not
//     driven by the injected `Clock`. Only the C1 case touches a running
//     `WireServer`'s own timer and therefore waits real seconds, bounded
//     by an explicit condition-poll timeout rather than a blind sleep, and
//     by the `test()` timeout on the case itself. Every other case below
//     calls `RoomRegistry.expireTurns()` directly, exactly as
//     `turn_timer_test.dart` already does, and needs no real waiting at
//     all.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// The default room rules; `turnSeconds` is what every "advance the clock
/// past the budget" call below advances by.
const RulesConfig _rules = RulesConfig();

Duration _budget(Room room) => Duration(seconds: room.rules.turnSeconds);

/// C1: makes `expireTurns()` throw synchronously on every call, and counts
/// how many times it was actually invoked -- the count that stops this case
/// passing vacuously if the periodic timer had died quietly instead of
/// really ticking.
class _ThrowingRegistry extends RoomRegistry {
  _ThrowingRegistry({required Clock clock, required Random secure})
      : super(clock: clock, secure: secure);

  int throwCount = 0;

  @override
  List<ExpiredTurn> expireTurns() {
    throwCount++;
    throw StateError(
      'synthetic expireTurns() failure #$throwCount, order 125 case C1',
    );
  }
}

/// C2/C3: `expireTurns()` runs for real, but the `roll` it calls
/// unqualified always fails, standing in for a real `RollFailure` outcome
/// (`docs/PROTOCOL.md` section 7's `INTERNAL`) without needing to coax the
/// real dice chain into refusing.
class _RollFailingRegistry extends RoomRegistry {
  _RollFailingRegistry({required Clock clock, required Random secure})
      : super(clock: clock, secure: secure);

  int rollCalls = 0;

  @override
  RollResult roll({required String code, required String seatToken}) {
    rollCalls++;
    return RollFailure(ProtocolError.internal);
  }
}

/// C2/C3's second reason: same idea as [_RollFailingRegistry], for `move`
/// instead of `roll`. `roll` itself is left real on this subclass, because
/// reaching `awaitMove` at all needs a genuine roll.
class _MoveFailingRegistry extends RoomRegistry {
  _MoveFailingRegistry({required Clock clock, required Random secure})
      : super(clock: clock, secure: secure);

  int moveCalls = 0;

  @override
  MoveResult move({
    required String code,
    required String seatToken,
    required int token,
  }) {
    moveCalls++;
    return MoveFailure(ProtocolError.internal);
  }
}

/// One started two-seat game on the given registry and clock, following the
/// same setup `turn_timer_test.dart` uses. Setup only; no assertion here is
/// reused from that file, per the work order.
typedef _Table = ({RoomRegistry registry, FakeClock clock, String code});

_Table _startedGameOn(RoomRegistry registry, FakeClock clock) {
  final CreateResult created =
      registry.createRoom(name: 'Host', players: 2, rules: _rules);
  if (created is! CreateOk) {
    fail('test setup: a 2-seat room must be creatable, got $created');
  }
  final JoinResult joined =
      registry.joinRoom(code: created.room.code, name: 'Guest');
  if (joined is! JoinOk) {
    fail('test setup: the second seat must be joinable, got $joined');
  }
  final StartResult started = registry.startGame(
    code: created.room.code,
    seatToken: created.seat.seatToken,
  );
  if (started is! StartOk) {
    fail('test setup: a full 2-seat room must start, got $started');
  }
  return (registry: registry, clock: clock, code: created.room.code);
}

/// Rolls for whichever seat currently owes the roll, through the real
/// (unoverridden) `roll()` every registry here inherits, until the game
/// reaches `awaitMove`. Only entering a token off the base -- a six, under
/// `docs/RULES.md` -- produces a legal move this early in a fresh game, so
/// this may take a number of real dice draws; the cap is far above what
/// chance alone would ever need, so a genuine stall fails loudly here
/// rather than the test hanging.
Room _driveToAwaitMove(RoomRegistry registry, String code) {
  final Room room = registry.lookup(code)!;
  for (int i = 0; i < 500; i++) {
    if (room.game!.phase == engine.GamePhase.awaitMove) {
      return room;
    }
    final int seat = room.game!.currentSeat;
    final String seatToken =
        room.seats.firstWhere((Seat s) => s.seat == seat).seatToken;
    final RollResult result = registry.roll(code: code, seatToken: seatToken);
    if (result is! RollOk) {
      fail(
        'test setup: roll() unexpectedly failed reaching await_move: '
        '$result',
      );
    }
  }
  fail('test setup: did not reach await_move within 500 real dice rolls');
}

/// `key=value` pairs, space-separated, out of one captured print line.
/// Deliberately not a byte-for-byte comparison against the frozen format,
/// per the work order, so a stray space does not turn a passing fix into a
/// red suite.
Map<String, String> _tokensOf(String line) {
  final Map<String, String> tokens = <String, String>{};
  for (final String part in line.split(' ')) {
    final int eq = part.indexOf('=');
    if (eq > 0) {
      tokens[part.substring(0, eq)] = part.substring(eq + 1);
    }
  }
  return tokens;
}

/// Polls [condition] on a real wall clock (deliberately not the injected
/// `FakeClock`: `turnExpiryInterval`'s `Timer.periodic` is not driven by
/// it), failing with [describe]'s message if [timeout] passes first, so a
/// stall is a fast, explicit test failure rather than a hang.
Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
  required String Function() describe,
  Duration step = const Duration(milliseconds: 25),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(describe());
    }
    await Future<void>.delayed(step);
  }
}

Future<int> _healthStatus(WireServer server) async {
  final HttpClient client = HttpClient();
  try {
    final Uri uri = Uri(
      scheme: 'http',
      host: 'localhost',
      port: server.port,
      path: '/health',
    );
    final HttpClientRequest request = await client.openUrl('GET', uri);
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('C1 -- expireTurns() throwing must not escape _runTurnExpiry', () {
    test(
      'after at least three ticks: no zone error, /health still answers '
      '200, and the sweep really ran more than once',
      () async {
        final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
        final _ThrowingRegistry registry =
            _ThrowingRegistry(clock: clock, secure: Random.secure());
        final RateLimiter rateLimiter = RateLimiter(clock: clock);
        final List<Object> zoneErrors = <Object>[];
        WireServer? server;

        await runZonedGuarded(() async {
          server = WireServer(
            registry: registry,
            rateLimiter: rateLimiter,
            clock: clock,
          );
          await server!.start(address: InternetAddress.loopbackIPv4, port: 0);
        }, (Object error, StackTrace stack) {
          zoneErrors.add(error);
        });

        final WireServer started = server!;
        try {
          await _waitUntil(
            () => registry.throwCount >= 3,
            timeout: const Duration(seconds: 8),
            describe: () => 'expireTurns() was only called '
                '${registry.throwCount} time(s) in 8 real seconds; the '
                'periodic timer may have stopped ticking entirely, which '
                'is itself the failure C1 exists to catch',
          );

          // The count that stops this case passing vacuously because the
          // timer died quietly: it did not, it ticked at least 3 times.
          expect(
            registry.throwCount,
            greaterThanOrEqualTo(3),
            reason: 'expireTurns() must have been called at least 3 times '
                'by now; got ${registry.throwCount}',
          );

          final int status = await _healthStatus(started);
          expect(
            status,
            200,
            reason: 'GET /health must still answer 200 after the sweep has '
                'thrown at least 3 times; got $status',
          );

          // C1 itself. We cannot observe "the process is still alive" from
          // inside the same process that would have died with it; per the
          // work order's own seam note, an error that escapes a
          // Timer.periodic callback and was never caught by
          // _runTurnErrors surfaces through this runZonedGuarded's
          // onError in a test isolate, instead of killing anything. A
          // non-empty zoneErrors here is therefore the evidence that the
          // throw crossed the boundary C1 says it must not cross -- not a
          // claim that a bare, unguarded isolate (bin/server.dart's own
          // shape) would have survived it.
          expect(
            zoneErrors,
            isEmpty,
            reason: 'C1: a throw from registry.expireTurns() must be '
                'caught inside _runTurnExpiry and never reach the zone; '
                'got ${zoneErrors.length} escaped error(s): $zoneErrors',
          );
        } finally {
          await started.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  group('C2 and C3 -- a room whose roll fails, reason=roll_failed', () {
    test(
      'C2: roll is called exactly once across two sweeps of the same '
      'expired segment',
      () {
        final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
        final _RollFailingRegistry registry =
            _RollFailingRegistry(clock: clock, secure: Random.secure());
        final _Table t = _startedGameOn(registry, clock);
        final Room room = registry.lookup(t.code)!;
        clock.advance(_budget(room));

        registry.expireTurns();
        registry.expireTurns();

        // C2's whole point: a declined room that produced no ExpiredTurn
        // must still have its segment restarted, so the very next sweep --
        // run here at the same clock instant, with no further advance --
        // finds a fresh, unexpired segment and does not act on this room
        // again. If the segment is left where it was (Defect B), every
        // future sweep re-evaluates the same already-expired segment and
        // calls roll() again, for ever: that is the spin this case is
        // named for, and exactly why a second call here must not happen.
        expect(
          registry.rollCalls,
          1,
          reason: 'C2: a failed roll must not be retried by the next '
              'sweep; roll() was called ${registry.rollCalls} time(s) '
              'across two sweeps of the same expired segment',
        );
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'C3: the sweep logs exactly one skip line, with room/seat/'
      'phase=await_roll/reason=roll_failed/error=internal',
      () {
        final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
        final _RollFailingRegistry registry =
            _RollFailingRegistry(clock: clock, secure: Random.secure());
        final List<String> lines = <String>[];
        late String code;
        late int seat;

        runZoned(() {
          final _Table t = _startedGameOn(registry, clock);
          code = t.code;
          final Room room = registry.lookup(code)!;
          seat = room.game!.currentSeat;
          clock.advance(_budget(room));
          registry.expireTurns();
        }, zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            lines.add(line);
          },
        ));

        expect(
          lines,
          hasLength(1),
          reason: 'C3: exactly one skip line is expected for the one '
              'declined room in this sweep; got ${lines.length}: $lines',
        );
        final String line = lines.single;
        expect(
          line,
          contains('turn-expiry skipped'),
          reason: 'line was: "$line"',
        );
        final Map<String, String> tokens = _tokensOf(line);
        expect(tokens['room'], code, reason: 'line was: "$line"');
        expect(tokens['seat'], '$seat', reason: 'line was: "$line"');
        expect(tokens['phase'], 'await_roll', reason: 'line was: "$line"');
        expect(
          tokens['reason'],
          'roll_failed',
          reason: 'line was: "$line"',
        );
        expect(
          tokens['error'],
          ProtocolError.internal.name,
          reason: 'line was: "$line"',
        );
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });

  group(
    'C2 and C3 for a second reason -- a room whose move fails, '
    'reason=move_failed',
    () {
      // Of the order's five listed reasons -- no_seat, roll_failed,
      // no_legal_tokens, move_failed, unhandled_phase -- only roll_failed
      // (above) and move_failed (here) are exercised. The file header
      // explains, for each of the other three, why it cannot be reached
      // without directly forging room/game state no protocol path could
      // ever produce.
      test(
        'C2: move is called exactly once across two sweeps of the same '
        'expired await_move segment',
        () {
          final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
          final _MoveFailingRegistry registry =
              _MoveFailingRegistry(clock: clock, secure: Random.secure());
          final _Table t = _startedGameOn(registry, clock);
          final Room room = _driveToAwaitMove(registry, t.code);
          clock.advance(_budget(room));

          registry.expireTurns();
          registry.expireTurns();

          expect(
            registry.moveCalls,
            1,
            reason: 'C2 for move_failed: the same spin as roll_failed, on '
                'the other branch of expireTurns\' if/else if -- move() '
                'was called ${registry.moveCalls} time(s) across two '
                'sweeps of the same expired segment',
          );
        },
        timeout: const Timeout(Duration(seconds: 15)),
      );

      test(
        'C3: the sweep logs one skip line, with phase=await_move, '
        'reason=move_failed, error=internal',
        () {
          final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
          final _MoveFailingRegistry registry =
              _MoveFailingRegistry(clock: clock, secure: Random.secure());
          final _Table t = _startedGameOn(registry, clock);
          final Room room = _driveToAwaitMove(registry, t.code);
          final int seat = room.game!.currentSeat;
          final List<String> lines = <String>[];

          runZoned(() {
            clock.advance(_budget(room));
            registry.expireTurns();
          }, zoneSpecification: ZoneSpecification(
            print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
              lines.add(line);
            },
          ));

          expect(
            lines,
            hasLength(1),
            reason: 'C3 for move_failed: got ${lines.length}: $lines',
          );
          final String line = lines.single;
          final Map<String, String> tokens = _tokensOf(line);
          expect(tokens['room'], t.code, reason: 'line was: "$line"');
          expect(tokens['seat'], '$seat', reason: 'line was: "$line"');
          expect(
            tokens['phase'],
            'await_move',
            reason: 'line was: "$line"',
          );
          expect(
            tokens['reason'],
            'move_failed',
            reason: 'line was: "$line"',
          );
          expect(
            tokens['error'],
            ProtocolError.internal.name,
            reason: 'line was: "$line"',
          );
        },
        timeout: const Timeout(Duration(seconds: 15)),
      );
    },
  );
}

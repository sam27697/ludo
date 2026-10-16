// Order 361: a seam for the roll-queue wire conformance suite
// (`test/roll_queue_wire_test.dart`) to put a real, running room's engine
// state into an exact position directly, through `Room.game`'s own public
// setter (`lib/src/room.dart:188`) -- the same way
// `test/turn_timer_conformance_test.dart`'s private `_forceGame` does for
// the turn timer, and the same way `test/verify_record_test.dart` forces a
// seat's row to set up a real win. Never through a dice-steered sequence of
// real rolls: `test/turn_loop_test.dart`'s own header records a real
// capture needing an 8-face search and a real win needing 60 or more,
// through the registry's real dice chain, and this suite needs exactly
// those positions (a capture mid-queue, a winning move with faces left) on
// top of a feature the server does not implement yet. What is under test,
// whenever this is used, is never the board position it builds -- it is
// what the live `WireServer` does with it once a real `roll` or `move`
// message reaches it over the socket.
//
// This lives only under `test/`. Nothing in `lib/` or `bin/` imports it, and
// nothing here is reachable from production code.

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';

/// The 4x4 token board `GameState.tokens` requires: [bySeat] gives the
/// occupied seats' own four progress values; every other seat's row is
/// `[-1, -1, -1, -1]`, `docs/ENGINE_API.md`'s own documented invariant for
/// "rows for seats not in config.seats". Identical in shape to
/// `turn_timer_conformance_test.dart`'s private helper of the same purpose;
/// duplicated here, not imported, because that file is outside this order's
/// file list.
List<List<int>> boardFor(Map<int, List<int>> bySeat) {
  return <List<int>>[
    for (int seat = 0; seat < 4; seat++)
      List<int>.of(bySeat[seat] ?? const <int>[-1, -1, -1, -1]),
  ];
}

/// Overwrites [room]'s engine state directly with a hand-built
/// `GameState`, reusing the seats and the seed `room.game!.config` already
/// fixed at `start_game`. The rule toggles are always `rollQueue: true`,
/// `homeBonus: true`, `blocks: false` -- `docs/PROTOCOL.md` section 21.3
/// rule 5, "every room" -- regardless of what the base server's own
/// `start_game` set them to, because the point of this order is to prove
/// what the wire does once those toggles are really on. `captureBonus`
/// defaults to whatever the room was actually created with and can be
/// overridden.
///
/// [now] becomes `room.turnSegmentStartedAt`, so every `deadline_ms` built
/// from the state this call leaves behind reads as a fresh, full-budget
/// segment rather than carrying over whatever segment start time the real
/// `start_game` call happened to leave in place. Callers pass their own
/// harness's `clock.now` here, never `DateTime.now()`.
///
/// [roomState] additionally overwrites `room.state`
/// (`docs/PROTOCOL.md`/`lib/src/room.dart`'s `RoomState`) for the one case
/// this suite needs it (a finished queue game): `room.state` and
/// `GameState.phase` are two separate fields -- `lib/src/snapshot.dart`'s
/// `_wireState` reads the former, `_turnSnapshot`'s `phase` the latter --
/// and nothing about assigning `room.game` ever touches the former.
void forceQueueGame(
  Room room, {
  required int currentSeat,
  required engine.GamePhase phase,
  required List<int> queue,
  required Map<int, List<int>> tokens,
  required DateTime now,
  int sixes = 0,
  int? winner,
  bool? captureBonus,
  RoomState? roomState,
}) {
  final engine.GameState base = room.game!;
  room.game = engine.GameState(
    config: engine.GameConfig(
      seats: base.config.seats,
      rules: engine.RulesConfig(
        blocks: false,
        captureBonus: captureBonus ?? base.config.rules.captureBonus,
        rollQueue: true,
        homeBonus: true,
      ),
      seed: base.config.seed,
    ),
    tokens: boardFor(tokens),
    currentSeat: currentSeat,
    phase: phase,
    roll: null,
    sixes: sixes,
    winner: winner,
    seq: base.seq + 1,
    rngState: base.rngState,
    queue: queue,
  );
  room.turnSegmentStartedAt = now;
  if (roomState != null) {
    room.state = roomState;
  }
}

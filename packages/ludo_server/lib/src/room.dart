// docs/PROTOCOL.md sections 2, 3 and 6; docs/RULES.md section 2.
//
// `docs/ENGINE_API.md` defines a `RulesConfig` with two fields, `blocks` and
// `captureBonus`; that is what the engine consumes. `docs/PROTOCOL.md`
// section 4 defines a wire-level `RulesConfig` with a third field,
// `turn_seconds`, that the engine has no concept of at all -- the turn timer
// is the server's, not the engine's, per `docs/ENGINE_API.md` section 3. A
// room has to carry `turn_seconds` from creation through to the turn loop
// that order 008 adds, and the frozen `Room` shape in the work order has no
// separate field for it, so this file's `RulesConfig` is that three-field
// wire shape, not a re-export of the engine's. `registry.dart` narrows it to
// the engine's two-field `RulesConfig` only at the moment it builds a
// `GameConfig` for `newGame`. This split is flagged in the work order report
// as the order's own ambiguity, not invented silently.

import 'package:ludo_engine/ludo_engine.dart' show GameState;

/// The rule toggles a room is created with. Mirrors the wire shape of
/// `docs/PROTOCOL.md` section 4 exactly, including the toggle the engine
/// itself does not know about.
class RulesConfig {
  const RulesConfig({
    this.blocks = true,
    this.captureBonus = true,
    this.turnSeconds = 45,
  });

  /// Rule 21 of `docs/RULES.md`.
  final bool blocks;

  /// Rule 11 of `docs/RULES.md`.
  final bool captureBonus;

  /// Seconds a seat has to act before the timer plays for it. 15 to 120.
  final int turnSeconds;

  @override
  String toString() => 'RulesConfig(blocks: $blocks, '
      'captureBonus: $captureBonus, turnSeconds: $turnSeconds)';
}

/// Where a room sits in `docs/PROTOCOL.md` section 3's lifecycle.
enum RoomState { lobby, playing, finished }

/// One occupied seat. `seatToken` is issued once, when the seat is taken,
/// and is the only thing that ever reclaims it.
class Seat {
  Seat({
    required this.seat,
    required this.name,
    required this.seatToken,
    required this.connected,
  });

  /// 0..3, the engine seat index.
  final int seat;

  /// 1..24 characters, trimmed, no control characters.
  final String name;

  final String seatToken;

  bool connected;

  @override
  String toString() => 'Seat(seat: $seat, name: $name, connected: $connected)';
}

/// A room, from creation to reap. `state`, `hostSeat`, `seats` and `game`
/// are mutated in place by the registry (and, from order 008 on, by the
/// turn loop) rather than replaced, because a `Room` is handed out to
/// callers who are expected to see it change under them.
class Room {
  Room({
    required this.code,
    required this.createdAt,
    required this.players,
    required this.rules,
    required this.state,
    required this.hostSeat,
    required this.seats,
    required this.game,
    this.seq = 0,
  });

  final String code;
  final DateTime createdAt;

  /// Monotonic, starts at 0 on creation, incremented by exactly one by the
  /// registry on every successful state-changing call
  /// (`docs/PROTOCOL.md` section 6). Never resets, never decrements, is not
  /// derived from the clock or from a random source. This is the wire
  /// layer's whole desync-detection mechanism: a push carries `room.seq` and
  /// a client that sees a gap knows it missed one and must `resume`.
  int seq;

  /// 2, 3 or 4. The configured seat count, not the current occupancy.
  /// Mutable: the host may change it while `state` is LOBBY, per
  /// `docs/PROTOCOL.md` section 3, which re-seats every occupied seat onto
  /// the canonical set for the new count.
  int players;

  final RulesConfig rules;

  RoomState state;

  /// The seat index of the host, or -1 if no seat is currently occupied.
  int hostSeat;

  /// Ordered by seat index, ascending.
  List<Seat> seats;

  /// Null until `start_game`.
  GameState? game;

  @override
  String toString() => 'Room(code: $code, state: $state, '
      'players: $players, seats: ${seats.length})';
}

// docs/PROTOCOL.md sections 2, 3, 6 and 11; docs/RULES.md section 2.
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

import 'package:fair_dice/fair_dice.dart' show DiceChain;
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

/// `docs/PROTOCOL.md` section 16.6, the room snapshot's `rematch` field.
/// Non-null only while the room is a rematch LOBBY (reached from FINISHED by
/// an accepted `rematch`, section 16.2) and null again the moment the game
/// it is waiting on actually starts (section 16.4).
class Rematch {
  Rematch({
    required this.by,
    required List<int> ready,
  }) : ready = List<int>.unmodifiable(ready);

  /// The seat that sent the `rematch` which reopened this LOBBY from
  /// FINISHED. Sticky: section 16.6 says `ready` always contains `by`
  /// "unless `by` has since left", which only makes sense if `by` itself can
  /// outlive that seat leaving the room -- so this is never cleared or
  /// reassigned for the life of one rematch LOBBY, even once the seat it
  /// names is gone.
  final int by;

  /// Ascending seat order, `docs/PROTOCOL.md` section 16.6. Never contains a
  /// seat that is not currently in [Room.seats] -- `RoomRegistry.leaveRoom`
  /// removes a departing seat from here in the same step that frees its
  /// seat index.
  ///
  /// `docs/PROTOCOL.md` section 16.4, as amended: the auto-start set is "the
  /// seats occupied when the accept arrives", read fresh off `Room.seats` at
  /// that instant, not fixed at the first `rematch` of the cycle -- a seat
  /// that left must never go on blocking a start it can no longer complete,
  /// and a seat that joined after the cycle opened must be waited for like
  /// any other. There used to be a second field here, `openSeats`, frozen at
  /// the moment the LOBBY opened; it is gone, because a set fixed at that
  /// moment is exactly the thing section 16.9 rule 4 rules out.
  final List<int> ready;
}

/// One occupied seat. `seatToken` is issued once, when the seat is taken,
/// and is the only thing that ever reclaims it.
class Seat {
  Seat({
    required this.seat,
    required this.name,
    required this.seatToken,
    required this.connected,
    this.clientSeed,
    this.seedOrigin,
  });

  /// 0..3, the engine seat index.
  final int seat;

  /// 1..24 characters, trimmed, no control characters.
  final String name;

  final String seatToken;

  bool connected;

  /// `docs/PROTOCOL.md` section 11.2. Null until this seat's seed is fixed,
  /// which happens exactly once: either an accepted `set_seed` in LOBBY, or
  /// a server-drawn seed handed out at `start_game` to any seat that sent
  /// none. Never null again after that, and never overwritten once set --
  /// the registry is the only thing that assigns it and it never assigns it
  /// twice for the same seat.
  String? clientSeed;

  /// `"player"` or `"server"`, fixed at the same moment as [clientSeed] and
  /// null exactly when [clientSeed] is null.
  String? seedOrigin;

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
    required this.chain,
    this.chainIndex = 0,
    this.gameId,
    this.clientSeeds,
    this.seq = 0,
    this.rematch,
    DateTime? lifetimeStartedAt,
    List<Map<String, Object?>>? gameLog,
  })  : lifetimeStartedAt = lifetimeStartedAt ?? createdAt,
        gameLog = gameLog ?? <Map<String, Object?>>[];

  final String code;
  final DateTime createdAt;

  /// The moment this room's current 60-minute lifetime budget began.
  /// `docs/PROTOCOL.md` section 3: "A room in any state is reaped 60 minutes
  /// after creation regardless." Starts at [createdAt] and is moved forward
  /// to "this moment" by the first `rematch` of a cycle (section 16.2 item
  /// 4: "The room's 60-minute total lifetime restarts from this moment, so a
  /// second game is not reaped half way through"). [createdAt] itself never
  /// changes -- it is still the room's true creation instant for anything
  /// that wants that -- so `RoomRegistry.reap` reads this field instead for
  /// the 60-minute ceiling.
  DateTime lifetimeStartedAt;

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

  /// The room's dice chain, built once at creation from a server secret
  /// drawn from a CSPRNG (`docs/PROTOCOL.md` section 11.3: "never reuse a
  /// chain across games"; this order never restarts a room's game, so one
  /// chain for the life of the room is the whole of that rule for now).
  /// `chain.commit` is `chain_commit` on the wire. Order 008's turn loop
  /// calls `chain.reveal(k)` for the roll path; this file never reveals a
  /// link itself.
  ///
  /// The server secret this chain was built from is `s[chainLength]`,
  /// the chain's root, and `DiceChain.build` keeps it verbatim as the last
  /// entry of the chain it materialises. `chain.reveal(chain.chainLength)`
  /// therefore returns that secret in hex through this same public API used
  /// for every other link -- there is no separate guard against it, and
  /// there must not be one, because the root is exactly what section 11.2's
  /// `rolled` frame is supposed to reveal on the chain's last valid roll
  /// (`k == chainLength`), so a future caller can verify the whole chain
  /// back to a value it can check was drawn honestly. What must never
  /// happen is a call to `reveal` with a `k` the caller did not get from an
  /// actual roll count for this chain: `reveal` has no way to know whether
  /// the `k` it is given is this game's current roll number or some other
  /// integer, so an off-by-one or a hardcoded `chainLength` handed to it
  /// early would reveal the root, and every roll after it, before their
  /// turns are due.
  DiceChain chain;

  /// `docs/PROTOCOL.md` section 11.2's `chain_index`, `0` for the first
  /// chain of the room. Order 008 is the only thing that ever advances this
  /// (a game exceeding `N = 4096` rolls starts a second chain); this order
  /// never changes it after creation.
  int chainIndex;

  /// 16 lowercase hex characters, server generated, set once at
  /// `start_game`. Null in LOBBY.
  String? gameId;

  /// The frozen `client_seeds` string of section 11.2: seats in ascending
  /// index, `seat:seed`, joined by `|`. Set once at `start_game`, from every
  /// seat's now-fixed [Seat.clientSeed], and never changes after. Null in
  /// LOBBY.
  String? clientSeeds;

  /// `docs/PROTOCOL.md` section 6's `turn.k`: the number of rolls this game
  /// has made so far. `0` from `start_game` until the first roll, thereafter
  /// exactly the `k` of the most recent `rolled` frame. `registry.dart`'s
  /// `roll()` is the only thing that ever advances this, and only on the one
  /// code path that has already committed to sending a `rolled` frame
  /// carrying the same `k` -- a rejected roll leaves this untouched.
  int rollCount = 0;

  /// The seat that rolled each roll of this game, ascending `k`: index `0`
  /// is roll `k = 1`, and so on, so `rollSeats.length == rollCount` always
  /// holds. `docs/VERIFY.md` section 1.2: `RoomRegistry.roll()` appends to
  /// this on the one code path that also sets [rollCount] to that same `k`,
  /// whether a player rolled or the turn timer did on their behalf --
  /// both go through that one method, so there is no second place a roll
  /// could be recorded here without also advancing [rollCount], or the
  /// reverse.
  final List<int> rollSeats = <int>[];

  /// The moment the currently active turn segment began, per section 6: a
  /// segment starts, and the full `rules.turnSeconds` is restored, on a
  /// seat's turn beginning, on a `rolled` that leaves a legal move pending,
  /// and on an extra roll being granted, and on nothing else. Null until
  /// `start_game`. Every `deadline_ms`, whether in a pushed frame or in a
  /// `room` snapshot built later, is `max(0, rules.turnSeconds * 1000 -
  /// now.difference(this).inMilliseconds)` on the registry's injected
  /// `Clock` -- never `DateTime.now()` directly.
  DateTime? turnSegmentStartedAt;

  /// `docs/PROTOCOL.md` section 16.6. Null except while this room is a
  /// rematch LOBBY: set by `RoomRegistry.rematch`'s first call in a FINISHED
  /// room (section 16.2 item 3) and cleared back to null the moment a game
  /// actually starts from it, whether that start was the server's own
  /// auto-start (section 16.4 "Everyone accepted") or the host's forced
  /// `start_game` (section 16.4 "Not everyone").
  Rematch? rematch;

  /// `docs/PROTOCOL.md` section 17. Every push the room broadcast for the
  /// current game, from its `game_started` on, in ascending seq order. Each
  /// entry is `{"t": type, "d": data}`.
  final List<Map<String, Object?>> gameLog;

  @override
  String toString() => 'Room(code: $code, state: $state, '
      'players: $players, seats: ${seats.length})';
}

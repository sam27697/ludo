// docs/PROTOCOL.md sections 2, 3, 6 and 11; docs/RULES.md section 2.
//
// `docs/ENGINE_API.md` defines a `RulesConfig` with three fields, `blocks`,
// `captureBonus` and `homeBonus`; that is what the engine consumes.
// `docs/PROTOCOL.md` section 4 defines a wire-level `RulesConfig` with
// `capture_bonus` and `turn_seconds` -- `turn_seconds` has no engine concept
// at all, since the turn timer is the server's, not the engine's, per
// `docs/ENGINE_API.md` section 3 -- plus a `blocks` key that is still
// accepted and type-checked on the wire but never stored or acted on
// (Sam's 2026-10-15 ruling: every room plays blocks off). A room has to
// carry `turn_seconds` from creation through to the turn loop that order
// 008 adds, and the frozen `Room` shape in the work order has no separate
// field for it, so this file's `RulesConfig` is that wire shape, not a
// re-export of the engine's. `registry.dart` builds the engine's
// `RulesConfig` at the moment it builds a `GameConfig` for `newGame`,
// taking `captureBonus` from here and hardcoding `blocks: false` and
// `homeBonus: true`. This split is flagged in the work order report as the
// order's own ambiguity, not invented silently.

import 'dart:math' show Random;

import 'package:fair_dice/fair_dice.dart' show DiceChain;
import 'package:ludo_engine/ludo_engine.dart' show GameState;

import 'ruleset.dart';

/// The rule toggles a room is created with. Mirrors the wire shape of
/// `docs/PROTOCOL.md` section 4 exactly, including the toggle the engine
/// itself does not know about.
///
/// Sam's ruling of 2026-10-15 (`docs/RULES.md` rule 21, `docs/PROTOCOL.md`
/// section 4): every room is created with blocks off, so this type no
/// longer carries a `blocks` field at all. The wire still accepts and
/// type-checks `blocks`; `connection.dart`'s `_parseRules` reads and
/// discards it rather than storing it here.
class RulesConfig {
  const RulesConfig({
    this.captureBonus = true,
    this.turnSeconds = 45,
  });

  /// Rule 11 of `docs/RULES.md`.
  final bool captureBonus;

  /// Seconds a seat has to act before the timer plays for it. 15 to 120.
  final int turnSeconds;

  @override
  String toString() => 'RulesConfig('
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
    this.via = 'code',
    this.barKey,
    this.bot,
  });

  /// Section 34 item 1: which of the six characters this computer seat is,
  /// 1 to 6. Null for a human seat, which has no `bot` key on the wire.
  final int? bot;

  /// `docs/PROTOCOL.md` section 31 item 1: how this seat was taken, `"host"`
  /// for the creating seat, `"link"` or `"code"` for a join, `"approved"` for
  /// a seat a knock was accepted for, and since section 33 item 5 `"public"`
  /// for a seat given from the waiting line (`"bot"` is section 34's). Fixed
  /// at seating; kept across a resume, a reseat and a rematch.
  final String via;

  /// Section 33 item 8: the host kicked this seat in PLAYING. Its token is
  /// dead from that moment, so no `resume` finds the seat again, though it
  /// stays in `seats` as a retired seat until `game_over` frees it.
  bool tokenDead = false;

  /// Section 31 item 7: the SHA-256 (hex) of the `install` this seat's socket
  /// sent, or of its IP when it sent none. Room state only; never logged,
  /// never on the wire. Null for a seat that has no such identity (the host).
  final String? barKey;

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

  /// `docs/PROTOCOL.md` section 23: how many `rolled` and `moved` frames
  /// carrying `by: "timer"` this seat has had since the later of the current
  /// game's start and its own last accepted `roll` or `move`. Room state,
  /// not game state: the engine never sees it and nothing but the snapshot
  /// publishes it. Never negative.
  int timerSteps = 0;

  /// `docs/PROTOCOL.md` section 28 rule 4 ("absent"): the registry clock's
  /// reading at the moment this seat's socket went down, that is, when the
  /// `presence` with `connected: false` was decided. Null while the seat is
  /// connected. Cleared by the `resume` that reconnects the seat, so a later
  /// drop starts a new count. Room state, never on the wire.
  DateTime? absentSince;

  /// `docs/PROTOCOL.md` section 26 rule 1: the seat has been away for one
  /// whole turn of its own and has not reconnected since, so every segment
  /// that starts for it has the fixed away budget. Room state, never on the
  /// wire: the snapshot shows its effect in `turn.segment_ms` and nothing
  /// else. Cleared for every seat by `game_started` and for one seat by the
  /// `resume` that reconnects it.
  bool away = false;

  /// Section 26 rule 2: whether this seat was connected at any point of the
  /// turn it holds now or held last, that is, connected as the turn began or
  /// reconnected by a `resume` before the turn ended. A turn that ends with
  /// this false makes the seat [away]. Meaningful only for the seat on turn
  /// in a PLAYING room; the registry sets it again as each turn begins.
  bool connectedThisTurn = true;

  @override
  String toString() => 'Seat(seat: $seat, name: $name, connected: $connected)';
}

/// One open knock, `docs/PROTOCOL.md` section 31 item 3: a typed-code join
/// that is waiting for the host while guest approval is on.
class Knock {
  Knock({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.barKey,
    required this.requestId,
    this.owner,
  });

  final String id;
  final String name;
  final DateTime createdAt;

  /// SHA-256 hex of the knocker's `install`, or of its IP when it sent none.
  final String barKey;

  /// The `id` of the `join_room` that made this knock, for the answer a close
  /// owes the knocker.
  final String requestId;

  /// Whatever the wire layer attached to identify the knocker's socket. The
  /// registry never looks inside it.
  final Object? owner;
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
    this.linkId = '',
    this.chainIndex = 0,
    this.gameId,
    this.clientSeeds,
    this.seq = 0,
    this.rematch,
    this.ruleset = ruleset202610,
    this.open = false,
    DateTime? lifetimeStartedAt,
    List<Map<String, Object?>>? gameLog,
  })  : lifetimeStartedAt = lifetimeStartedAt ?? createdAt,
        gameLog = gameLog ?? <Map<String, Object?>>[],
        turnSegmentMs = rules.turnSeconds * 1000;

  final String code;

  /// `docs/PROTOCOL.md` section 31 item 1: the id room links carry. Set once
  /// at creation, never derived from [code].
  final String linkId;

  final DateTime createdAt;

  /// Section 31 item 5: whether a typed-code join knocks instead of seating.
  /// False at creation, kept across a rematch.
  bool guestApproval = false;

  /// Section 33 item 1: the server may seat strangers here from the waiting
  /// line. Fixed at creation and kept across a rematch; only a computer seat
  /// clears it (section 34), and a room that lost it is not open.
  bool open;

  /// Section 33 item 2: a matchable room holds no computer seat. Section 34
  /// seats them with `via: "bot"` and a `bot` number.
  bool get hasComputerSeat =>
      seats.any((Seat s) => s.via == 'bot' || s.bot != null);

  /// Section 34 item 4: the room's one non-secret random source, from which
  /// the characters and the paces are drawn. Made by the registry from its
  /// injected factory the first time a computer seat needs it; never the
  /// source that feeds the dice.
  Random? computerRandom;

  /// Section 34 item 4: the pace of the decision now owed to a computer seat.
  /// [computerBase] is the instant the pace counts from (the later of the
  /// frame that left the seat to act, the end of a grace, and the last
  /// moment a human socket came back to a room with none); [computerDueAt]
  /// is that instant plus the drawn pace. Both are null while no decision is
  /// scheduled. Room state only, never on the wire.
  DateTime? computerBase;
  DateTime? computerDueAt;

  /// Section 34 item 4: when the first human socket returned to a room that
  /// had none connected, so the pace restarts from it. Null until then.
  DateTime? humanBackAt;

  /// Section 31 item 3: the open knocks, in arrival order.
  final List<Knock> knocks = <Knock>[];

  /// Section 31 item 7: bars by SHA-256 hex, in this room's memory only. A
  /// kicked seat bars `link` and `code` joins; a refused or timed-out knock
  /// bars the typed-code path.
  final Set<String> kickBars = <String>{};
  final Set<String> knockBars = <String>{};

  /// `docs/PROTOCOL.md` section 28 rule 1: the ruleset this room was created
  /// under, [ruleset202610], [ruleset202611] or [ruleset202612]. Taken from
  /// the server at `create_room` and kept for the life of the room,
  /// rematches included.
  final String ruleset;

  /// True when this room plays the 2026-11 ruleset (section 28) or the
  /// 2026-12 one, which plays everything 2026-11 does (section 30 rule 1).
  bool get isRuleset202611 =>
      ruleset == ruleset202611 || ruleset == ruleset202612;

  /// True when this room plays the 2026-12 ruleset (section 30): the shared
  /// release.
  bool get isRuleset202612 => ruleset == ruleset202612;

  /// The moment this room's current lifetime budget began.
  /// `docs/PROTOCOL.md` section 3, as amended by C-451: a LOBBY is reaped 60
  /// minutes after this moment even with a seat connected, and a room that
  /// is not a LOBBY is reaped 6 hours after it regardless. A PLAYING room is
  /// otherwise reaped only when no seat has been connected for 10 minutes,
  /// and a FINISHED one 10 minutes after it was first seen finished. Starts
  /// at [createdAt] and is moved forward to "this moment" by the first
  /// `rematch` of a cycle (section 16.2 item 4), so a second game is not
  /// held to the first one's budget. [createdAt] itself never changes -- it
  /// is still the room's true creation instant for anything that wants that
  /// -- so `RoomRegistry.reap` reads this field instead for both limits.
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

  /// `docs/PROTOCOL.md` section 35 item 3: the last `pre` handed to a socket,
  /// as the game ([gameId]), the seat and the roll number `k` it was for.
  /// Written only by `recordPreSent` in `registry.dart`. A seat holds a `pre` while
  /// these name the current game, that seat, and `rollCount + 1`, and the
  /// game still awaits that seat's roll. Never on the wire, in a snapshot or
  /// in the verify record.
  String? preGameId;
  int preSeat = -1;
  int preK = 0;

  /// The seat that rolled each roll of this game, ascending `k`: index `0`
  /// is roll `k = 1`, and so on, so `rollSeats.length == rollCount` always
  /// holds. `docs/VERIFY.md` section 1.2: `RoomRegistry.roll()` appends to
  /// this on the one code path that also sets [rollCount] to that same `k`,
  /// whether a player rolled or the turn timer did on their behalf --
  /// both go through that one method, so there is no second place a roll
  /// could be recorded here without also advancing [rollCount], or the
  /// reverse.
  final List<int> rollSeats = <int>[];

  /// `docs/PROTOCOL.md` section 28 rule 2: the roll numbers `k` of this game
  /// whose roll granted a yard release (rule 11r), lapses included,
  /// ascending. `RoomRegistry.roll()` appends to it on the one code path
  /// that also appends to [rollSeats]. Always empty under 2026-10.
  final List<int> releases = <int>[];

  /// `docs/PROTOCOL.md` section 30 rule 7: the roll numbers whose offered
  /// release the player declined, ascending. Always empty before 2026-12.
  final List<int> declined = <int>[];

  /// Section 30 rule 7: the roll numbers whose release was a lapse (no piece
  /// could come out), ascending, a subset of [releases]. Always empty before
  /// 2026-12.
  final List<int> lapsed = <int>[];

  /// Section 30 rule 5: the seat whose turn began with banked sixes queued
  /// and the count the engine's `SixesQueued` said, for a `turn` rebuilt
  /// without the event (a reconnect). Written only by
  /// `RoomRegistry._noteQueuedBanked`, cleared when that seat rolls, when the
  /// turn passes, when the game ends and at a game start. 0 means none.
  int queuedBankedSeat = -1;
  int queuedBankedCount = 0;

  /// Section 30 rule 7: for each taken release, the roll number and the
  /// seats granted a six, in the order the releases were taken.
  final List<Map<String, Object?>> grants = <Map<String, Object?>>[];

  /// The moment the currently active turn segment began, per section 6: a
  /// segment starts, and the full `rules.turnSeconds` is restored, on a
  /// seat's turn beginning, on a `rolled` that leaves a legal move pending,
  /// and on an extra roll being granted, and on nothing else. Null until
  /// `start_game`. Every `deadline_ms`, whether in a pushed frame or in a
  /// `room` snapshot built later, is `max(0, rules.turnSeconds * 1000 -
  /// now.difference(this).inMilliseconds)` on the registry's injected
  /// `Clock` -- never `DateTime.now()` directly. Section 26 rule 3 replaces
  /// `rules.turnSeconds * 1000` in that formula with [turnSegmentMs].
  DateTime? turnSegmentStartedAt;

  /// `docs/PROTOCOL.md` section 26 rule 3: the budget of the segment that
  /// began at [turnSegmentStartedAt], in milliseconds. `rules.turnSeconds *
  /// 1000` unless the seat the segment was started for was away, in which
  /// case the fixed away budget. Set only by the registry's
  /// `_restartSegment`, and published as `turn.segment_ms`.
  int turnSegmentMs;

  /// `docs/PROTOCOL.md` section 29 rule 3: when the grace of the segment that
  /// began at [turnSegmentStartedAt] runs out, on the registry's injected
  /// clock. Null for a segment with no grace (every `2026-10` segment, and
  /// every `2026-11` one that did not pass the turn). The segment's budget
  /// counts from this moment, not from its start.
  DateTime? turnGraceEndsAt;

  /// Section 29 rule 3: the grace still to run at [now], or 0 once it has run
  /// out (exactly at [turnGraceEndsAt] counts as run out) or when there was
  /// none.
  int graceLeftMs(DateTime now) {
    final DateTime? endsAt = turnGraceEndsAt;
    if (endsAt == null) {
      return 0;
    }
    final int left = endsAt.difference(now).inMilliseconds;
    return left > 0 ? left : 0;
  }

  /// Section 6, section 26 rule 3 and section 29 rule 3: `max(0, budget -
  /// elapsed)` for the segment running at [now], where elapsed counts from the
  /// segment's start, or from the end of its grace when that is later. During
  /// a grace this is the full budget. Zero when no segment has started.
  int segmentRemainingMs(DateTime now) {
    final DateTime? startedAt = turnSegmentStartedAt;
    if (startedAt == null) {
      return 0;
    }
    final DateTime? graceEnd = turnGraceEndsAt;
    final DateTime countFrom =
        graceEnd != null && graceEnd.isAfter(startedAt) ? graceEnd : startedAt;
    final int elapsedMs = now.difference(countFrom).inMilliseconds;
    final int remaining = turnSegmentMs - (elapsedMs > 0 ? elapsedMs : 0);
    return remaining > 0 ? remaining : 0;
  }

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

  /// `docs/PROTOCOL.md` section 25 rule 3. When each seat's recent `emote`
  /// requests were admitted, oldest first, keyed by seat token so a resume
  /// on a new socket does not reset it. Room state in the sense that it
  /// lives and dies with the room, but never game state: it is not in the
  /// snapshot, the game log or the verify record, and `admitEmote` prunes a
  /// list to the last minute each time it is touched.
  final Map<String, List<DateTime>> emoteAdmits = <String, List<DateTime>>{};

  @override
  String toString() => 'Room(code: $code, state: $state, '
      'players: $players, seats: ${seats.length})';
}

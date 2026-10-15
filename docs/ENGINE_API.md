# Engine API

Frozen 2026-08-18. This file exists for one reason: the worker that writes the
rules tests and the worker that writes the rules engine must agree on an
interface that neither of them owns. Both are given this file. Neither may
change it.

`docs/RULES.md` says what the game does. This file says what the code is
called. Where the two appear to disagree, `docs/RULES.md` wins and the
disagreement is a defect to report, not to resolve locally.

Names on the wire are fixed by `docs/PROTOCOL.md` and the mapping is in
section 9. Do not invent a third vocabulary.

## 1. Package shape

Package `ludo_engine`. Every public type below is exported from the single
entry point `package:ludo_engine/ludo_engine.dart`. Internal files under
`lib/src/` are the implementer's choice.

The engine has **no dependencies**. No `crypto`, no `collection`, no `meta`,
nothing but the Dart SDK and `test` as a dev dependency. Rules 37 and 38 of
`docs/RULES.md` are enforced by that emptiness: no clock, no network, no file
access, no global mutable state, no `DateTime.now()`, no `Random()` without a
seed, no `identityHashCode`, no iteration over an unordered `Set` or `Map` in
any code path that affects state.

The engine targets 64-bit Dart (VM and AOT). It is not compiled to JavaScript,
so `int` is a 64-bit two's complement integer with defined wraparound. The
arithmetic in section 7 depends on that.

## 2. Value types

All state types are **immutable**. Every field is `final`. There are no
setters. A transition returns a new object; it never edits one. Each type
implements `==` and `hashCode` by value, and `toString()` usefully.

```dart
enum GamePhase { awaitRoll, awaitMove, finished }

enum TurnEndReason { noLegalMove, threeSixes }

class RulesConfig {
  final bool blocks;         // rule 21, default true
  final bool captureBonus;   // rule 11, default true
  final bool homeBonus;      // rule 11a, default false (see section 8)
  const RulesConfig({
    this.blocks = true,
    this.captureBonus = true,
    this.homeBonus = false,
  });
}

class GameConfig {
  GameConfig({
    required List<int> seats,
    this.rules = const RulesConfig(),
    required this.seed,
  }) : seats = List<int>.unmodifiable(seats);

  final List<int> seats;     // occupied seat indices, ascending, unique, length 2..4
  final RulesConfig rules;
  final int seed;            // 64-bit, from the server CSPRNG, never sent to a client
}
```

The constructor is named, not positional, and it copies `seats` into an
unmodifiable list. `GameConfig` is not `const`, because that defensive copy
cannot be made in a const constructor and a shared mutable `seats` list held by
a caller would be a way to change a game's configuration after `newGame`
validated it. `rules` defaults to `const RulesConfig()`, which is the table of
defaults in `docs/RULES.md`.

`GameConfig`, `RulesConfig` and `GameState` all define `==` and `hashCode` by
value. Identity equality would make two structurally identical states compare
unequal, which would quietly break any test that rebuilds an expected state.

`seats` is the seat indices actually in play, ascending: `[0,2]` for two
players, `[0,1,2]` for three, `[0,1,2,3]` for four. Rule 2 of `docs/RULES.md`
fixes two players at seats 0 and 2. The engine does not choose seats; it is
given them and validates them.

```dart
class GameState {
  final GameConfig config;
  final List<List<int>> tokens; // ALWAYS 4 x 4. tokens[seat][index] is progress.
  final int currentSeat;
  final GamePhase phase;
  final int? roll;              // null in awaitRoll and finished; 1..6 in awaitMove
  final int sixes;              // consecutive 6s already rolled this turn, 0..2
  final int? winner;            // null until a seat wins, then that seat
  final int seq;                // increments by 1 on every accepted intention
  final int rngState;           // section 7. SECRET. Never leaves the server.
}
```

`tokens` is always 4 rows of 4, even for a two or three player game. Rows for
seats not in `config.seats` stay `[-1,-1,-1,-1]` forever and are never legal to
move. This keeps indexing total and keeps serialisation a fixed shape; it is
not an invitation to let an empty seat take a turn.

`rngState` is the future of the dice. It is part of the state because the state
must be a pure function of seed and intentions, and it is why `toJson()` in
section 8 is server-internal. Sending it to a client hands that client every
future roll. `docs/PROTOCOL.md` section 6 defines the redacted snapshot that
clients actually receive; the engine does not produce it and the server owns
that mapping.

## 3. Intentions

An intention is what a seat asks to do. It carries the seat, so the engine can
reject an out-of-turn action itself rather than trusting the caller to have
checked.

```dart
sealed class Intention {
  final int seat;
}

class RollIntention extends Intention {          // wire: "roll"
  final int face;                                // 1..6, drawn by the caller
  const RollIntention(int seat, this.face);
}

class MoveIntention extends Intention {          // wire: "move"
  final int token;                               // 0..3
  const MoveIntention(int seat, this.token);
}
```

There is no intention for the turn timer. Rule 37: the engine has no clock. On
expiry the server picks the token itself using `legalTokens` and section 5's
ordering, and submits an ordinary `MoveIntention`. The engine cannot tell the
difference and must not try.

## 4. Applying an intention

```dart
sealed class ApplyResult {}

class Applied extends ApplyResult {
  final GameState state;         // the NEW state
  final List<GameEvent> events;  // ordered, see section 6
}

class Rejected extends ApplyResult {
  final EngineError error;
  // No state field. A rejected intention changes nothing, by construction.
}

enum EngineError {
  notYourTurn,      // wire NOT_YOUR_TURN
  wrongPhase,       // wire WRONG_PHASE
  illegalMove,      // wire ILLEGAL_MOVE
  gameFinished,     // an intention against a terminal state, rule 35
  seatNotInPlay,    // a seat index not in config.seats
  noSuchToken,      // token index outside 0..3
}
```

The whole engine is two functions and three queries:

```dart
GameState newGame(GameConfig config);
ApplyResult apply(GameState state, Intention intention);

List<int> legalTokens(GameState state);   // token indices movable with state.roll
bool isTerminal(GameState state);
String stateHash(GameState state);        // section 8
```

`newGame` returns `phase = awaitRoll`, `currentSeat = config.seats.first`,
every token at -1, `sixes = 0`, `winner = null`, `seq = 0`,
`rngState = config.seed`. It throws `ArgumentError` on a malformed config
(seats out of range, not ascending, duplicated, or a length outside 2..4). A
malformed config is a programming error, not a game event, and it is the only
place the engine throws.

`legalTokens` returns ascending token indices, always, and returns the empty
list when `phase != awaitMove`. It never throws. Rule 15's "first legal move"
is defined as `legalTokens(state).first` and that is the whole definition.

`apply` never throws. Every refusal is a `Rejected`.

### The order of checks in `apply`

Fixed, because the error a client sees must not depend on an implementation
detail:

1. `isTerminal(state)` -> `gameFinished`.
2. `intention.seat` not in `config.seats` -> `seatNotInPlay`.
3. `intention.seat != state.currentSeat` -> `notYourTurn`.
4. Intention type does not match `state.phase` -> `wrongPhase`.
   (`RollIntention` needs `awaitRoll`, `MoveIntention` needs `awaitMove`.)
5. `RollIntention.face` not an integer in 1..6 -> `badFace`.
6. `MoveIntention.token` outside 0..3 -> `noSuchToken`.
7. `MoveIntention.token` not in `legalTokens(state)` -> `illegalMove`.

`badFace` sits at step 5 and not earlier on purpose. A face is only meaningful
once the seat and the phase are known to be right, so a spectator sending
`{"face": 99}` out of turn gets `notYourTurn`, which is what it did wrong first.
`badFace` is a new value at the end of the `EngineError` enum; appending keeps
every existing `.name` string and every existing `.index` stable, which the
golden corpus's optional `error` field depends on.

## 5. What each intention does

### RollIntention

1. Read the die value from `intention.face`. The engine draws nothing and
   `rngState` does not move; see section 7 and rule 38. A `face` that is not an
   integer in 1..6 is rejected with `badFace` before anything else in this list
   happens, and a rejection leaves the state untouched as always.
2. If the value is 6 and `state.sixes == 2`, this is the third consecutive 6.
   Rule 10: the roll is **not played**, no move is offered, the turn passes.
   Emit `Rolled` then `TurnEnded(threeSixes)` then `TurnBegan` for the next
   seat. New phase `awaitRoll`, `sixes = 0` for the new seat.
3. Otherwise compute the legal set for that value. If it is empty, rule 7: the
   turn passes immediately. Emit `Rolled` then `TurnEnded(noLegalMove)` then
   `TurnBegan`. New phase `awaitRoll`, `sixes = 0`.
4. Otherwise phase becomes `awaitMove`, `roll` is the value, and `sixes`
   becomes `state.sixes + 1` if the value is 6, otherwise 0. Emit `Rolled`.

`sixes` counts consecutive 6s **within the current turn** and resets to 0 the
moment the turn changes hands or a non-6 is rolled.

### MoveIntention

1. Apply the movement of rule 17 or 18 to the chosen token.
2. Resolve capture per rules 27 to 31.
3. If that token reached 57, emit `TokenHome`.
4. If the moving seat now has all four tokens at 57, rules 33 to 35: `winner`
   is that seat, `phase` is `finished`, emit `GameWon`, and emit nothing after
   it. No extra roll is granted to a winning move; the game is over.
5. Otherwise decide the extra roll, rule 12: the same seat rolls again if the
   roll was a 6, or the move captured and `rules.captureBonus` is on, or the
   token reached 57 in step 3 and `rules.homeBonus` is on. There is no queue
   and no stacking beyond that single boolean: a move that is a 6, a capture
   and a home arrival at once still grants exactly one `ExtraRoll`.
   - Extra roll: phase `awaitRoll`, same `currentSeat`, `sixes` unchanged
     (it was already incremented by the roll step), emit `ExtraRoll`.
   - No extra roll: phase `awaitRoll`, `currentSeat` advances to the next seat
     in `config.seats` cyclically, `sixes = 0`, emit `TurnBegan`.
6. `roll` becomes null. `seq` increments.

A move never emits `TurnEnded`. `TurnEnded` means the turn ended without a move
being played, which happens only in the two cases in the roll step.

## 6. Events

Events exist so the server can push the deltas in `docs/PROTOCOL.md` section 5
without recomputing what changed. They are a description of what just happened,
in order, and the state in `Applied.state` is already the state after all of
them.

```dart
sealed class GameEvent {}

class Rolled     extends GameEvent { final int seat; final int value; final List<int> legal; }
class Moved      extends GameEvent { final int seat; final int token; final int from; final int to; }
class Captured   extends GameEvent { final int seat; final int token; final int by; final int byToken; }
class TokenHome  extends GameEvent { final int seat; final int token; }
class ExtraRoll  extends GameEvent { final int seat; }
class TurnEnded  extends GameEvent { final int seat; final TurnEndReason reason; }
class TurnBegan  extends GameEvent { final int seat; }
class GameWon    extends GameEvent { final int seat; }
```

`Captured.seat` and `Captured.token` are the victim. `by` and `byToken` are the
capturer. A single move captures at most one token, by rule 28, so at most one
`Captured` is emitted per move.

Event order for a capturing move that grants an extra roll:
`Moved`, `Captured`, `ExtraRoll`. For a move that finishes a token and wins:
`Moved`, `TokenHome`, `GameWon`.

## 7. Dice, exactly

**The engine does not roll dice.** Rule 38. The face arrives inside
`RollIntention`, the engine validates it is 1..6, and that is the whole of the
engine's involvement with randomness.

Where a face comes from depends on who is calling:

| Caller | Source of the face |
|---|---|
| the game server | `packages/fair_dice`, per `docs/FAIRNESS.md` section 2.3: one HMAC draw per roll under a per-roll chain secret, revealed in the same frame as the result |
| `tool/generate_corpus.dart`, and offline simulation | the SplitMix64 below, seeded per game, so a corpus is reproducible from its seed alone |

That split is the point of the change. A per-roll verifiable secret cannot come
out of one generator held for a whole game, so the engine had to stop holding
one. It also makes rule 36 stronger: replay no longer depends on this
generator, because the faces are in the intention stream.

`rngState` and `config.seed` still exist on the state and in the hash, and the
engine no longer moves either. **They are vestigial and their removal belongs to
the protocol order** (`docs/FAIRNESS.md` section 7 item 3), which is when the
server stops computing `seed_commit` from `config.seed` and can drop them
together. They were left in place rather than removed here so that this change
does not have to break `packages/ludo_server` in the same commit.

### SplitMix64, for the corpus generator only

Retained in `lib/src/rng.dart` and off the gameplay path. The generator is
**SplitMix64**, with 64-bit wrapping arithmetic:

```
next(state):
    state = state + 0x9E3779B97F4A7C15          // wrapping
    z = state
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9    // wrapping
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB    // wrapping
    z = z ^ (z >>> 31)
    return (new state, z)
```

`>>>` is Dart's unsigned right shift on a 64-bit int. Multiplication wraps.

A die value is drawn with rejection sampling, so that no face is favoured:

```
roll(state):
    loop:
        (state, z) = next(state)
        u = (z >>> 32) & 0xFFFFFFFF              // a 32-bit value
        if u < 4294967292:                       // 2^32 - (2^32 mod 6)
            return (state, (u % 6) + 1)
        // otherwise draw again; the rejected draw still advanced the state
```

The rejection branch is reachable roughly once in a billion draws and it is
still specified, because "roughly never" is exactly when a determinism bug hides.

Nothing in `apply` consumes randomness. Only the corpus generator calls this.

### The golden corpus record

One JSON object per line in `test/golden/corpus.jsonl`, keys in this order:

```
name        string
seed        int          the generator's seed, NOT the engine's
seats       [int]
rules       { blocks: bool, captureBonus: bool }
intentions  [ {"t":"roll","seat":int,"face":int}
            | {"t":"move","seat":int,"token":int} ]
finalHash   string       16 lowercase hex, stateHash of the final state
finalSeq    int
```

**`face` is mandatory on every `roll` record.** A replayer that treats a missing
`face` as anything other than a hard failure would silently accept a corpus from
before this change and prove nothing; it must name the record and fail.

`seed` stays in the record because the generator still needs it to reproduce the
same faces, and because a face sequence that cannot be re-derived from anything
is a face sequence nobody can audit. It is no longer read by the engine.

## 8. Serialisation and the hash

`GameState.toJson()` returns a `Map<String, Object?>` with keys in exactly this
order, and `GameState.fromJson()` round-trips it:

```
config: { seats: [int], rules: { blocks: bool, captureBonus: bool[, homeBonus: true] }, seed: int }
tokens: [[int,int,int,int], x4]
currentSeat: int
phase: "awaitRoll" | "awaitMove" | "finished"
roll: int | null
sixes: int
winner: int | null
seq: int
rngState: int
```

**`homeBonus` is written only when it is true** (2026-10-15, rule 11a). A
state whose `homeBonus` is false serialises to exactly the bytes it did before
the toggle existed, so every `finalHash` in the golden corpus and every state
recorded before the ruling keeps its hash. `fromJson()` reads an absent
`homeBonus` as false and accepts an explicit `true`; an explicit `false` or any
non-bool is a `FormatException`-class error like any other malformed field,
because accepting it would give one state two serialisations.

This is the **internal** form. It contains `seed` and `rngState` and it is
never sent to a client. The server builds the redacted snapshot of
`docs/PROTOCOL.md` section 6 from the state; that mapping is the server's job,
not the engine's.

`stateHash(state)` is FNV-1a, 64-bit, over the UTF-8 bytes of the canonical
JSON text of `toJson()` -- keys in the order above, no whitespace, no trailing
newline -- returned as exactly 16 lowercase hex characters.

```
h = 0xCBF29CE484222325
for each byte b:
    h = h ^ b
    h = h * 0x00000100000001B3      // wrapping 64-bit
```

The golden corpus is `(seed, [intentions], final stateHash)`. A hash that
changes is a defect until someone proves it was an intended rule change. That
guarantee is worth nothing if the hash is not pinned to the byte, which is why
the field order above is normative and not a suggestion.

## 9. Wire mapping

| Engine | `docs/PROTOCOL.md` |
|---|---|
| `RollIntention` | `roll` |
| `MoveIntention.token` | `move` `{ "token": 0..3 }` |
| `Rolled{value, legal}` | `rolled` `{ value, legal, deadline_ms }`, server adds the deadline |
| `Moved` + `Captured` + `ExtraRoll` | one `moved` `{ from, to, captured: [], extra_roll }` |
| `TurnEnded{noLegalMove}` | `turn_passed` `{ reason: "no_legal_move" }` |
| `TurnEnded{threeSixes}` | `turn_passed` `{ reason: "three_sixes" }` |
| `TurnBegan` | `turn` `{ seat, deadline_ms }` |
| `GameWon` | `game_over` |
| `GameState.seq` | `seq` in the snapshot |
| `EngineError.notYourTurn` | `NOT_YOUR_TURN` |
| `EngineError.wrongPhase` | `WRONG_PHASE` |
| `EngineError.illegalMove` | `ILLEGAL_MOVE` |

`deadline_ms` has no engine equivalent and must not acquire one. The timer is
the server's, by rule 37.

## 10. The roll queue (`rollQueue`), 2026-10-15

`docs/RULES.md` section 3.2a is the rule; this is its engine shape. With
`rules.rollQueue` false nothing in sections 1 to 9 changes, byte for byte:
the golden corpus and every legacy state replay and hash exactly as before.

### 10.1 Types

```dart
class RulesConfig {
  final bool rollQueue;      // rule 9q, default false; toJson writes it only when true
}

class GameState {
  final List<int> queue;     // unspent faces in roll order; always [] when !rollQueue
}

class MoveIntention extends Intention {
  final int token;
  final int? face;           // the queued face to spend; null = the default face
  const MoveIntention(int seat, this.token, {this.face});
}

/// Faces with at least one legal token, in first-queued order, each with
/// its legal tokens ascending. Empty in awaitRoll and finished. With
/// !rollQueue: `{state.roll: legalTokens(state)}` in awaitMove.
Map<int, List<int>> legalByFace(GameState state);

/// The face a move with `face == null` spends: the first entry of the
/// queue, in queue order, that has a legal token. Null outside awaitMove
/// (a queue may be non-empty in awaitRoll) and when no face can move.
int? defaultFace(GameState state);
```

`legalTokens(state)` keeps its signature and, with `rollQueue`, returns the
legal tokens of `defaultFace(state)`. `state.roll` is always null with
`rollQueue` on; the queue replaces it.

### 10.2 Serialisation

`queue` is written in `toJson()` right after `roll`, as a list of ints,
**only when `config.rules.rollQueue` is true** (then always, even empty).
`rollQueue` is written in `rules` after `captureBonus` and before
`homeBonus`, only when true. `fromJson()` reads both absent as false / `[]`,
and rejects an explicit `rollQueue: false`, a `queue` key on a state whose
rules lack `rollQueue`, a missing `queue` when `rollQueue` is true, and a
face outside 1..6.

### 10.3 RollIntention with `rollQueue`

1. `badFace` exactly as section 5.
2. A 6 with `state.sixes == 2`: rule 10q. Emit `Rolled` then
   `TurnEnded(threeSixes)` then `TurnBegan` for the next seat; `queue = []`,
   `sixes = 0`, phase `awaitRoll`.
3. A 6 otherwise: append it, `sixes + 1`, phase stays `awaitRoll`, same
   seat. Emit `Rolled` then `ExtraRoll`.
4. A non-6: append it, `sixes = 0`. If `legalByFace` of the new state is
   empty, rule 13q: emit `Rolled` then `TurnEnded(noLegalMove)` then
   `TurnBegan`; `queue = []`, next seat, `awaitRoll`. Otherwise phase
   `awaitMove`; emit `Rolled`.

`Rolled.legal` is `legalTokens` of the state after the roll, as in section
5: the tokens of `defaultFace` when that state is `awaitMove`, `[]` in every
other case (a queued 6 that owes another roll, a voided or passed turn).
It is never the legal set of the rolled face alone. PROTOCOL.md section
21.1 sends the same list as `legal`.

### 10.4 MoveIntention with `rollQueue`

Checks, in order, after the shared ones of section 4 (phase, seat, token
range): `face` given and not in the queue, or not in 1..6: `illegalMove`;
`face` null and `defaultFace` null: impossible in `awaitMove` by 10.3;
the token not legal for the face: `illegalMove`.

1. Remove the first occurrence of the face from the queue.
2. Move, capture, `TokenHome` and the win exactly as section 5 steps 1 to 4
   for that face. A win: queue `[]`, `GameWon`, nothing after.
3. A bonus is owed if the move captured with `captureBonus` or reached 57
   with `homeBonus`. A 6 spent grants nothing (rule 12q). Bonus: phase
   `awaitRoll`, same seat, `sixes = 0`, emit `ExtraRoll`.
4. No bonus, and `legalByFace` of the new state non-empty: phase
   `awaitMove`, same seat. No event beyond the move's own.
5. No bonus, queue empty: next seat, `awaitRoll`, `sixes = 0`, emit
   `TurnBegan`.
6. No bonus, queue non-empty but no face can move: emit
   `TurnEnded(noLegalMove)` then `TurnBegan`; queue `[]`, next seat,
   `awaitRoll`, `sixes = 0`.

Every seat change in this section sets `sixes = 0`. Every malformed state
in 10.2 is a `FormatException`, as for `homeBonus`.

`sixes` is untouched by a move except where a step sets it.

### 10.5 The golden corpus

Records with `"rollQueue": true` in `rules` carry `face` on every `move`
intention (mandatory there, absent elsewhere). The 40 legacy records stay
byte-identical. The generator spends, on each move, the face and token its
seeded choice picks among `legalByFace`.

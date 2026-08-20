// Shared fixture builders for the rules acceptance suite.
//
// docs/ENGINE_API.md gives us exactly one door into an arbitrary mid-game
// position: GameState.fromJson(). Rolling dice we do not control cannot put
// a token at progress 55 with an opponent block three squares ahead, so
// every test that needs a specific board reaches for buildState() instead.
//
// This file talks to the engine only through the public entry point,
// package:ludo_engine/ludo_engine.dart, and only through the JSON shape
// fixed by docs/ENGINE_API.md section 8.

import 'package:ludo_engine/ludo_engine.dart';

/// The four token rows, always 4x4 per docs/ENGINE_API.md section 2. Seats
/// not supplied in [tokens] default to `[-1, -1, -1, -1]`, the yard, per
/// rule 3.
List<List<int>> _tokenRows(Map<int, List<int>> tokens) {
  return List<List<int>>.generate(4, (seat) {
    final List<int>? row = tokens[seat];
    if (row == null) {
      return const <int>[-1, -1, -1, -1];
    }
    if (row.length != 4) {
      throw ArgumentError(
        'seat $seat token row must have exactly 4 entries, got '
        '${row.length}: $row',
      );
    }
    return List<int>.of(row);
  });
}

/// Builds a [GameState] directly through [GameState.fromJson], the door the
/// frozen API gives tests to reach an exact mid-game position.
///
/// [tokens] maps seat index to that seat's four progress values, in token
/// order 0..3. [phase] is one of `'awaitRoll'`, `'awaitMove'`, `'finished'`,
/// matching the wire values from docs/ENGINE_API.md section 8 exactly.
GameState buildState({
  required List<int> seats,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  String phase = 'awaitRoll',
  int? roll,
  int sixes = 0,
  int? winner,
  int seq = 0,
  int rngState = 1,
  int seed = 1,
  bool blocks = true,
  bool captureBonus = true,
}) {
  final Map<String, Object?> json = <String, Object?>{
    'config': <String, Object?>{
      'seats': seats,
      'rules': <String, Object?>{
        'blocks': blocks,
        'captureBonus': captureBonus
      },
      'seed': seed,
    },
    'tokens': _tokenRows(tokens),
    'currentSeat': currentSeat,
    'phase': phase,
    'roll': roll,
    'sixes': sixes,
    'winner': winner,
    'seq': seq,
    'rngState': rngState,
  };
  return GameState.fromJson(json);
}

/// A ready-to-move fixture: `phase = awaitMove` with the given [roll]
/// already set. Most movement, block and capture tests want exactly this
/// shape so they can apply a single [MoveIntention] and inspect the result.
GameState buildAwaitMove({
  required List<int> seats,
  required int roll,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  int sixes = 0,
  int seq = 0,
  int rngState = 1,
  int seed = 1,
  bool blocks = true,
  bool captureBonus = true,
}) {
  return buildState(
    seats: seats,
    tokens: tokens,
    currentSeat: currentSeat,
    phase: 'awaitMove',
    roll: roll,
    sixes: sixes,
    seq: seq,
    rngState: rngState,
    seed: seed,
    blocks: blocks,
    captureBonus: captureBonus,
  );
}

/// A ready-to-roll fixture: `phase = awaitRoll`, `roll = null`. Tests that
/// exercise [RollIntention] itself (rule 7's turn pass, rule 10's third six,
/// rule 13's extra-roll-with-no-legal-move) build from this and pick
/// `rngState` with `findRngStateForNextRoll` so the draw is known in advance.
GameState buildAwaitRoll({
  required List<int> seats,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  int sixes = 0,
  int seq = 0,
  required int rngState,
  int seed = 1,
  bool blocks = true,
  bool captureBonus = true,
}) {
  return buildState(
    seats: seats,
    tokens: tokens,
    currentSeat: currentSeat,
    phase: 'awaitRoll',
    sixes: sixes,
    seq: seq,
    rngState: rngState,
    seed: seed,
    blocks: blocks,
    captureBonus: captureBonus,
  );
}

/// The standard two-player seat list, per rule 2: seats 0 and 2.
const List<int> twoPlayerSeats = <int>[0, 2];

/// The standard four-player seat list, per rule 2: seats 0, 1, 2 and 3.
const List<int> fourPlayerSeats = <int>[0, 1, 2, 3];

/// The eight safe squares of rule 3, absolute track indices.
const List<int> safeSquares = <int>[0, 8, 13, 21, 26, 34, 39, 47];

/// Entry offsets per seat, the table in rule 1 (section 1.1).
const Map<int, int> entryOffset = <int, int>{0: 0, 1: 13, 2: 26, 3: 39};

// Stage 1 of order 063's two-stage steering (see the header of
// ../turn_loop_test.dart for the shape this implements in full): an
// offline, pure-engine search for a short face sequence that drives a fresh
// game into a wanted state. `package:ludo_engine` only -- no server, no
// wire, no chain, no SHA-256. Everything here is deterministic and costs no
// hashing at all; the one-time cost of turning a face sequence found here
// into an actual server secret belongs to `dice_oracle.dart`'s
// `findSecretForFaces`, called from the wire-level test, never from here.
//
// The search below fixes one thing that is not fixed by the engine itself:
// which token to move when a roll leaves more than one legal. Every roll
// that leaves a legal move is followed here by moving
// `legalTokens(state).first` -- docs/ENGINE_API.md section 4, rule 15's own
// definition of "the first legal move" -- and that is also the exact policy
// every steered test in `turn_loop_test.dart` drives once these faces reach
// the wire (see that file's own `driveToSteeredRoll` and
// `driveSteeredRollSeries`). Fixing that policy is what turns "search over
// faces and moves" into "search over faces alone": a plain breadth-first
// search with a branching factor of 6 per roll, not 6 times however many
// tokens happen to be legal.
import 'package:ludo_engine/ludo_engine.dart';

/// One roll played out against the pure engine: the face rolled, the legal
/// list it left -- exactly what a `rolled` frame's own `legal` field would
/// carry for the same roll on the wire -- and, when the roll ended the turn
/// without a move being offered, why.
class EngineRollStep {
  const EngineRollStep({
    required this.face,
    required this.legal,
    required this.turnEndReason,
  });

  final int face;
  final List<int> legal;

  /// Non-null exactly when this roll's own `Rolled` event was immediately
  /// followed by `TurnEnded` -- the no-legal-move and three-consecutive-
  /// sixes cases of docs/ENGINE_API.md section 5. Null whenever the roll
  /// left a legal move instead.
  final TurnEndReason? turnEndReason;
}

/// Replays [faces] against a fresh game of [seats] under [rules], one
/// `RollIntention` per face, moving `legalTokens(state).first` immediately
/// whenever a roll leaves a legal move -- see this file's header for why
/// that is the only move policy a caller here ever needs. Returns one
/// [EngineRollStep] per face, in order, and the state the last one left.
///
/// Throws [StateError], naming the face and its 1-based position in
/// [faces], if a roll or its forced follow-up move is ever rejected --
/// which would mean [faces] is not actually playable from a fresh game
/// (most likely because an earlier face already ended it), and a caller
/// building a sequence by hand needs to know exactly where that happened.
({List<EngineRollStep> steps, GameState state}) simulateFaces({
  required List<int> seats,
  required List<int> faces,
  RulesConfig rules = const RulesConfig(),
  int seed = 0,
}) {
  GameState state = newGame(GameConfig(seats: seats, rules: rules, seed: seed));
  final List<EngineRollStep> steps = <EngineRollStep>[];
  for (int i = 0; i < faces.length; i++) {
    final int face = faces[i];
    final int seat = state.currentSeat;
    final ApplyResult rollResult = apply(state, RollIntention(seat, face));
    if (rollResult is! Applied) {
      throw StateError(
        'simulateFaces: roll ${i + 1}/${faces.length} (face $face) for '
        'seat $seat was rejected: '
        '${(rollResult as Rejected).error.name}; state before it: $state',
      );
    }
    state = rollResult.state;
    final Rolled rolled = rollResult.events.whereType<Rolled>().single;
    final Iterable<TurnEnded> ended = rollResult.events.whereType<TurnEnded>();
    steps.add(EngineRollStep(
      face: face,
      legal: rolled.legal,
      turnEndReason: ended.isEmpty ? null : ended.single.reason,
    ));
    if (rolled.legal.isNotEmpty) {
      final ApplyResult moveResult =
          apply(state, MoveIntention(seat, rolled.legal.first));
      if (moveResult is! Applied) {
        throw StateError(
          'simulateFaces: the forced first-legal-move token '
          '${rolled.legal.first} for seat $seat after roll ${i + 1}/'
          '${faces.length} (face $face) was rejected: '
          '${(moveResult as Rejected).error.name}; state before it: $state',
        );
      }
      state = moveResult.state;
    }
  }
  return (steps: steps, state: state);
}

/// Breadth-first search over the pure engine for the shortest face
/// sequence, starting from a fresh game of [seats] under [rules], whose
/// last roll satisfies [accepts]. Tries every face 1..6 at every roll, in
/// order, so the first sequence [accepts] is found on is provably the
/// shortest one reachable under the fixed "move `legalTokens(state).first`"
/// policy this file's header explains -- ties broken in favour of the
/// lowest face tried first, which keeps the result reproducible without a
/// second rule to state.
///
/// [accepts] is checked against the state immediately after the roll,
/// before any forced follow-up move -- the same moment a `rolled` frame's
/// own `legal` field describes on the wire.
///
/// Bounded by [maxDepth] rolls; returns null rather than searching forever
/// if nothing satisfies [accepts] within that bound. States are
/// deduplicated by `GameState`'s own value equality, so the frontier at any
/// depth holds at most one node per distinct reachable state -- this is
/// what keeps the search a search, rather than a blind 6^depth enumeration,
/// at the depths this file's callers actually need (single digits; see
/// `dice_oracle.dart`'s own doc comment for why depths past roughly 8 are
/// not a search anything in this suite can afford regardless of this
/// function's own cost, once `findSecretForFaces` has to turn the result
/// into a real server secret).
List<int>? findFaceSequence({
  required List<int> seats,
  required bool Function(EngineRollStep step, GameState stateAfterRoll) accepts,
  RulesConfig rules = const RulesConfig(),
  int seed = 0,
  int maxDepth = 8,
}) {
  final GameState start =
      newGame(GameConfig(seats: seats, rules: rules, seed: seed));
  List<(GameState, List<int>)> frontier = <(GameState, List<int>)>[
    (start, const <int>[]),
  ];
  final Set<GameState> visited = <GameState>{start};
  for (int depth = 0; depth < maxDepth; depth++) {
    final List<(GameState, List<int>)> next = <(GameState, List<int>)>[];
    for (final (GameState state, List<int> facesSoFar) in frontier) {
      if (isTerminal(state)) {
        continue;
      }
      final int seat = state.currentSeat;
      for (int face = 1; face <= 6; face++) {
        final ApplyResult rollResult = apply(state, RollIntention(seat, face));
        if (rollResult is! Applied) {
          // Not reachable from a well-formed search state (every state this
          // search reaches is awaitRoll for a seat actually in play), but
          // skipped rather than thrown so a future rule change fails this
          // search's caller loudly (no sequence found) instead of crashing
          // the whole suite on an assumption this file no longer holds.
          continue;
        }
        final GameState afterRoll = rollResult.state;
        final Rolled rolled = rollResult.events.whereType<Rolled>().single;
        final Iterable<TurnEnded> ended =
            rollResult.events.whereType<TurnEnded>();
        final EngineRollStep step = EngineRollStep(
          face: face,
          legal: rolled.legal,
          turnEndReason: ended.isEmpty ? null : ended.single.reason,
        );
        final List<int> faces = <int>[...facesSoFar, face];
        if (accepts(step, afterRoll)) {
          return faces;
        }
        GameState afterPly = afterRoll;
        if (rolled.legal.isNotEmpty) {
          final ApplyResult moveResult =
              apply(afterRoll, MoveIntention(seat, rolled.legal.first));
          if (moveResult is! Applied) {
            continue;
          }
          afterPly = moveResult.state;
        }
        if (visited.add(afterPly)) {
          next.add((afterPly, faces));
        }
      }
    }
    frontier = next;
    if (frontier.isEmpty) {
      break;
    }
  }
  return null;
}

/// Depth-first search, with backtracking, for a face sequence of exactly
/// [rolls] rolls -- every one of them a real, distinct rolled frame with
/// its own reveal, none of them a specific game state -- that never runs
/// the game to completion along the way. Tries face 1 first at every roll
/// and only backtracks to a higher face if a lower one would end the game
/// before [rolls] rolls have happened.
///
/// A natural win needs 4*57 = 228 total progress plus four yard exits per
/// docs/RULES.md rule 33 (see `_winUnreachable` in turn_loop_test.dart for
/// the fuller accounting), which single-digit roll counts cannot reach
/// under any face sequence, so in practice this returns `[1, 1, 1, ...]` on
/// its very first candidate -- verified here against the real engine on
/// every call, rather than assumed once and hand-copied into the test.
///
/// Returns null, rather than searching forever, if every face at some roll
/// would end the game -- which would mean [rolls] itself is unreasonably
/// large for this to promise, not that the search failed to look hard
/// enough.
List<int>? findRollBudgetFaces({
  required List<int> seats,
  required int rolls,
  RulesConfig rules = const RulesConfig(),
  int seed = 0,
}) {
  final GameState start =
      newGame(GameConfig(seats: seats, rules: rules, seed: seed));

  List<int>? search(GameState state, int remaining, List<int> facesSoFar) {
    if (remaining == 0) {
      return facesSoFar;
    }
    if (isTerminal(state)) {
      return null;
    }
    final int seat = state.currentSeat;
    for (int face = 1; face <= 6; face++) {
      final ApplyResult rollResult = apply(state, RollIntention(seat, face));
      if (rollResult is! Applied) {
        continue;
      }
      GameState afterPly = rollResult.state;
      final Rolled rolled = rollResult.events.whereType<Rolled>().single;
      if (rolled.legal.isNotEmpty) {
        final ApplyResult moveResult =
            apply(afterPly, MoveIntention(seat, rolled.legal.first));
        if (moveResult is! Applied) {
          continue;
        }
        afterPly = moveResult.state;
      }
      final List<int>? found =
          search(afterPly, remaining - 1, <int>[...facesSoFar, face]);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  return search(start, rolls, const <int>[]);
}

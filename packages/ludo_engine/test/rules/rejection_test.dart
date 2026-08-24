// docs/ENGINE_API.md section 4: "Rejected ... No state field. A rejected
// intention changes nothing, by construction." This file proves that
// construction claim for one fixture per EngineError: the state before the
// rejected call must equal the state after it, both by GameState's own ==
// and by stateHash, and its toJson() must be byte-for-byte the same, which
// also catches a rejection path that mutates a nested List in place before
// discovering the intention should have been refused.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Applies [intention] to [state], asserts it was rejected with [expected],
/// and asserts [state] is unchanged by every means the frozen API gives us
/// to check: ==, stateHash and toJson().
void _expectRejectionChangesNothing(
  GameState state,
  Intention intention,
  EngineError expected,
) {
  final beforeJson = state.toJson();
  final beforeHash = stateHash(state);
  final independentCopy = GameState.fromJson(state.toJson());

  final result = apply(state, intention);

  expect(result, isA<Rejected>());
  expect((result as Rejected).error, expected);
  expect(state.toJson(), equals(beforeJson));
  expect(stateHash(state), beforeHash);
  expect(state, equals(independentCopy));
  expect(state.hashCode, independentCopy.hashCode);
}

void main() {
  test('rejection changes nothing: gameFinished', () {
    final state = buildState(
      seats: twoPlayerSeats,
      phase: 'finished',
      winner: 0,
      currentSeat: 0,
      tokens: const {
        0: <int>[57, 57, 57, 57],
      },
    );
    _expectRejectionChangesNothing(
      state,
      const MoveIntention(0, 0),
      EngineError.gameFinished,
    );
  });

  test('rejection changes nothing: seatNotInPlay', () {
    final state =
        buildAwaitRoll(seats: twoPlayerSeats, currentSeat: 0, rngState: 1);
    _expectRejectionChangesNothing(
      state,
      const RollIntention(1),
      EngineError.seatNotInPlay,
    );
  });

  test('rejection changes nothing: notYourTurn', () {
    final state =
        buildAwaitRoll(seats: twoPlayerSeats, currentSeat: 0, rngState: 1);
    _expectRejectionChangesNothing(
      state,
      const RollIntention(2),
      EngineError.notYourTurn,
    );
  });

  test('rejection changes nothing: wrongPhase', () {
    final state =
        buildAwaitRoll(seats: twoPlayerSeats, currentSeat: 0, rngState: 1);
    _expectRejectionChangesNothing(
      state,
      const MoveIntention(0, 0),
      EngineError.wrongPhase,
    );
  });

  test('rejection changes nothing: noSuchToken', () {
    final state = buildAwaitMove(
      seats: twoPlayerSeats,
      roll: 3,
      currentSeat: 0,
      tokens: const {
        0: <int>[0, -1, -1, -1],
      },
    );
    _expectRejectionChangesNothing(
      state,
      const MoveIntention(0, 7),
      EngineError.noSuchToken,
    );
  });

  test('rejection changes nothing: illegalMove', () {
    final state = buildAwaitMove(
      seats: twoPlayerSeats,
      roll: 3,
      currentSeat: 0,
      tokens: const {
        0: <int>[-1, 0, 57, 57],
      },
    );
    _expectRejectionChangesNothing(
      state,
      const MoveIntention(0, 0),
      EngineError.illegalMove,
    );
  });
}

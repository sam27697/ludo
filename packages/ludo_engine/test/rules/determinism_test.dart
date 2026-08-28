// docs/RULES.md section 6, rule 36: determinism.
//
// Rule 36 no longer says "the same seed and the same intentions"; it says
// "the same intentions", full stop, and it says so precisely because rule
// 38 moved the die face into the intention stream. This file proves the
// stronger claim directly: two games built from DIFFERENT seeds, replayed
// with the exact same ordered list of intentions (faces included), reach
// the same tokens, currentSeat, phase, roll, sixes, winner and seq.
//
// They do not reach the same stateHash, and that is expected, not a defect
// to chase. docs/ENGINE_API.md section 7 says config.seed and rngState are
// still part of GameState.toJson() -- and therefore of stateHash -- and are
// vestigial, kept in place only until a later, separate order removes them
// once the protocol side is ready. Two configs built with deliberately
// different seeds will still disagree on that one field, on purpose, and
// this file says so at the point it matters rather than comparing hashes
// and being surprised.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/splitmix64.dart';

/// A recorded step: enough to reconstruct the intention without holding on
/// to any GameState. A roll step carries the face it was recorded with, per
/// rule 38 -- there is no rngState left to derive it from at replay time.
class _Step {
  const _Step.roll(this.seat, int face)
      : face = face,
        token = null;
  const _Step.move(this.seat, int token)
      : token = token,
        face = null;

  final int seat;
  final int? face;
  final int? token;

  Intention toIntention() {
    final f = face;
    return f != null ? RollIntention(seat, f) : MoveIntention(seat, token!);
  }
}

/// Plays a real game from [config] for up to [maxSteps] intentions.
///
/// Move steps always pick `legalTokens(state).first`, a deterministic,
/// well-defined choice per rule 15. Roll steps draw their face from a
/// SplitMix64 stream seeded by [faceSeed] -- test/support/splitmix64.dart's
/// hand-transcription of the generator in docs/ENGINE_API.md section 7,
/// used here exactly as that section says it may be used: as a source of a
/// realistic face sequence for the corpus/offline side, not as anything the
/// engine itself touches. [config.seed] plays no part in choosing these
/// faces; that is the entire point of the file.
///
/// Fails loudly, naming [faceSeed], if the game does not terminate in time
/// or if an intention the driver itself issues is rejected, since either
/// would mean the fixture is broken rather than the thing under test.
List<_Step> _recordScript(
  GameConfig config, {
  required int faceSeed,
  int maxSteps = 400,
}) {
  var state = newGame(config);
  var rngState = faceSeed;
  final steps = <_Step>[];
  while (!isTerminal(state) && steps.length < maxSteps) {
    late final _Step step;
    if (state.phase == GamePhase.awaitRoll) {
      final (nextRngState, face) = referenceRollDie(rngState);
      rngState = nextRngState;
      step = _Step.roll(state.currentSeat, face);
    } else if (state.phase == GamePhase.awaitMove) {
      final legal = legalTokens(state);
      step = _Step.move(state.currentSeat, legal.first);
    } else {
      break;
    }
    final intention = step.toIntention();
    final result = apply(state, intention);
    if (result is! Applied) {
      fail(
        'faceSeed=$faceSeed: recording driver produced a rejected '
        'intention at step ${steps.length}: '
        '${(result as Rejected).error}. The fixture is broken, not the '
        'thing under test.',
      );
    }
    steps.add(step);
    state = result.state;
  }
  return steps;
}

/// Replays [steps] against a fresh `newGame(config)`. When
/// [roundTripEachStep] is true, every intermediate state is pushed through
/// `toJson()`/`fromJson()` before the next intention is applied, forcing an
/// independently reconstructed GameState object at each step rather than
/// reusing the same chain of objects the engine itself built.
({GameState state, String hash}) _replay(
  GameConfig config,
  List<_Step> steps, {
  bool roundTripEachStep = false,
}) {
  var state = newGame(config);
  for (final step in steps) {
    final result = apply(state, step.toIntention());
    if (result is! Applied) {
      fail(
        'seed=${config.seed}: replay diverged, a previously-applied '
        'intention was rejected with ${(result as Rejected).error}',
      );
    }
    state = roundTripEachStep
        ? GameState.fromJson(result.state.toJson())
        : result.state;
  }
  return (state: state, hash: stateHash(state));
}

void main() {
  const seats = <int>[0, 1, 2, 3];
  final configA = GameConfig(seats: seats, rules: const RulesConfig(), seed: 111);
  final configB = GameConfig(seats: seats, rules: const RulesConfig(), seed: 999);

  test(
    'rule 36: two games built from different seeds, replayed with the same '
    'ordered intention list, reach the same tokens, currentSeat, phase, '
    'roll, sixes, winner and seq',
    () {
      expect(
        configA.seed,
        isNot(equals(configB.seed)),
        reason: 'this test only proves anything if the two configs really '
            'do disagree on seed',
      );

      final script = _recordScript(configA, faceSeed: 20260828);
      expect(
        script,
        isNotEmpty,
        reason: 'faceSeed=20260828 produced no recorded steps; widen '
            'maxSteps or pick a different faceSeed',
      );

      final runA = _replay(configA, script);
      final runB = _replay(configB, script);

      expect(
        runB.state.tokens,
        equals(runA.state.tokens),
        reason: 'seedA=${configA.seed}, seedB=${configB.seed}, '
            '${script.length}-step script: tokens diverged despite '
            'identical intentions',
      );
      expect(
        runB.state.currentSeat,
        runA.state.currentSeat,
        reason: 'seedA=${configA.seed}, seedB=${configB.seed}: currentSeat '
            'diverged despite identical intentions',
      );
      expect(
        runB.state.phase,
        runA.state.phase,
        reason: 'seedA=${configA.seed}, seedB=${configB.seed}: phase '
            'diverged despite identical intentions',
      );
      expect(
        runB.state.roll,
        runA.state.roll,
        reason: 'seedA=${configA.seed}, seedB=${configB.seed}: roll '
            'diverged despite identical intentions',
      );
      expect(
        runB.state.sixes,
        runA.state.sixes,
        reason: 'seedA=${configA.seed}, seedB=${configB.seed}: sixes '
            'diverged despite identical intentions',
      );
      expect(
        runB.state.winner,
        runA.state.winner,
        reason: 'seedA=${configA.seed}, seedB=${configB.seed}: winner '
            'diverged despite identical intentions',
      );
      expect(
        runB.state.seq,
        runA.state.seq,
        reason: 'seedA=${configA.seed}, seedB=${configB.seed}: seq '
            'diverged despite identical intentions',
      );

      // stateHash is deliberately NOT compared above. docs/ENGINE_API.md
      // section 7 says config.seed and rngState remain part of
      // GameState.toJson(), and therefore of stateHash, purely as
      // vestigial fields awaiting removal by a later, separate order; they
      // are no longer read by the engine but they are still hashed. Since
      // configA.seed and configB.seed differ on purpose, their hashes are
      // expected to differ even though every field that actually describes
      // the game state is identical. The next assertion is the sanity
      // check for that: if the hashes matched anyway, either the seeds
      // were not really different or stateHash silently stopped covering
      // config.seed, and either way this file would no longer be proving
      // what its own comment claims.
      expect(
        runB.hash,
        isNot(equals(runA.hash)),
        reason: 'seedA=${configA.seed}, seedB=${configB.seed}: stateHash '
            'matched despite different seeds; either the seeds were not '
            'actually different or stateHash stopped covering config.seed',
      );
    },
  );

  test(
    'rule 36: replaying through a GameState chain that is reconstructed '
    'via toJson/fromJson at every step produces the same stateHash as '
    'replaying through the chain the engine itself built',
    () {
      final script = _recordScript(configA, faceSeed: 424242);

      final direct = _replay(configA, script);
      final rebuilt = _replay(configA, script, roundTripEachStep: true);

      expect(
        rebuilt.hash,
        direct.hash,
        reason: 'seed=${configA.seed}, ${script.length} steps: a state '
            'chain rebuilt from toJson/fromJson at every step must hash '
            'identically to the chain the engine built directly, or the '
            'state is not a pure function of the intentions (rule 36) and '
            'toJson/fromJson does not round-trip '
            '(docs/ENGINE_API.md section 8)',
      );
      expect(rebuilt.state.seq, direct.state.seq);
    },
  );

  test(
    'seq increments by exactly 1 for every accepted intention, the '
    'running count that makes "the same intentions" well-defined at all',
    () {
      final script = _recordScript(configA, faceSeed: 7, maxSteps: 40);
      var state = newGame(configA);
      for (var i = 0; i < script.length; i++) {
        final before = state.seq;
        final result = apply(state, script[i].toIntention());
        expect(result, isA<Applied>(), reason: 'faceSeed=7, step $i');
        state = (result as Applied).state;
        expect(
          state.seq,
          before + 1,
          reason: 'faceSeed=7, step $i: seq must advance by exactly 1 per '
              'accepted intention',
        );
      }
    },
  );
}

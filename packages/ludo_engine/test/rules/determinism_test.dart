// docs/RULES.md section 6, rules 36 and 38: determinism.
//
// "Given the same seed and the same ordered list of intentions, the engine
// produces byte-identical state, on any machine, in any process, at any
// time" (rule 36). "The engine itself is a pure function of seed and
// intentions" (rule 38). Both are proven the same way: play a real game
// once to record a script of intentions, then replay that exact script
// through two independently built GameState chains and compare stateHash
// and seq.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

/// A recorded step: enough to reconstruct the intention without holding on
/// to any GameState.
class _Step {
  const _Step.roll(this.seat) : token = null;
  const _Step.move(this.seat, this.token);
  final int seat;
  final int? token;

  Intention toIntention() {
    final t = token;
    return t == null ? RollIntention(seat) : MoveIntention(seat, t);
  }
}

/// Plays a real game from [config] for up to [maxSteps] intentions, always
/// picking `legalTokens(state).first` (a deterministic, well-defined choice
/// per rule 15), and returns the script of intentions actually applied.
/// Fails loudly, naming the seed, if the game does not terminate in time or
/// if an intention the driver itself issues is rejected, since either would
/// mean the fixture is not exercising what this test claims to exercise.
List<_Step> _recordScript(GameConfig config, {int maxSteps = 400}) {
  var state = newGame(config);
  final steps = <_Step>[];
  while (!isTerminal(state) && steps.length < maxSteps) {
    late final Intention intention;
    late final _Step step;
    if (state.phase == GamePhase.awaitRoll) {
      step = _Step.roll(state.currentSeat);
    } else if (state.phase == GamePhase.awaitMove) {
      final legal = legalTokens(state);
      step = _Step.move(state.currentSeat, legal.first);
    } else {
      break;
    }
    intention = step.toIntention();
    final result = apply(state, intention);
    if (result is! Applied) {
      fail(
        'seed=${config.seed}: recording driver produced a rejected '
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
({String hash, int seq}) _replay(
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
  return (hash: stateHash(state), seq: state.seq);
}

void main() {
  final config = GameConfig(
    seats: <int>[0, 1, 2, 3],
    rules: const RulesConfig(),
    seed: 987654321,
  );

  test(
    'rule 36: the same seed and the same ordered intentions produce an '
    'identical stateHash across two independently built GameState chains, '
    'run twice in the same process',
    () {
      final script = _recordScript(config);
      expect(
        script,
        isNotEmpty,
        reason: 'seed=${config.seed} produced no recorded steps; widen '
            'maxSteps or pick a different seed',
      );

      final runA = _replay(config, script);
      final runB = _replay(config, script);

      expect(
        runB.hash,
        runA.hash,
        reason: 'two independent replays of the same seed=${config.seed} and '
            'the same ${script.length}-step script produced different '
            'stateHash values: $runA vs $runB',
      );
      expect(runB.seq, runA.seq);
    },
  );

  test(
    'rule 36: replaying through a GameState chain that is reconstructed '
    'via toJson/fromJson at every step produces the same stateHash as '
    'replaying through the chain the engine itself built',
    () {
      final script = _recordScript(config);

      final direct = _replay(config, script);
      final rebuilt = _replay(config, script, roundTripEachStep: true);

      expect(
        rebuilt.hash,
        direct.hash,
        reason: 'seed=${config.seed}, ${script.length} steps: a state chain '
            'rebuilt from toJson/fromJson at every step must hash '
            'identically to the chain the engine built directly, or the '
            'state is not a pure function of seed and intentions '
            '(rule 38) and toJson/fromJson does not round-trip '
            '(docs/ENGINE_API.md section 8)',
      );
      expect(rebuilt.seq, direct.seq);
    },
  );

  test(
    'rule 38: seq increments by exactly 1 for every accepted intention, '
    'the running count that makes "same intentions" well-defined at all',
    () {
      final script = _recordScript(config, maxSteps: 40);
      var state = newGame(config);
      for (var i = 0; i < script.length; i++) {
        final before = state.seq;
        final result = apply(state, script[i].toIntention());
        expect(result, isA<Applied>(), reason: 'seed=${config.seed}, step $i');
        state = (result as Applied).state;
        expect(
          state.seq,
          before + 1,
          reason: 'seed=${config.seed}, step $i: seq must advance by '
              'exactly 1 per accepted intention',
        );
      }
    },
  );
}

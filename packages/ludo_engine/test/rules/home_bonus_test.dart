// docs/RULES.md rule 11a and 12; docs/ENGINE_API.md section 4 step 5 and
// section 8 (the homeBonus paragraph). Sam's ruling of 2026-10-15: a move
// that brings a token home grants another roll, unless it wins the game.
// Engine toggle RulesConfig.homeBonus, default false.
//
// seat 0 has entry offset 0 (progress equals absolute square), so these
// fixtures never need the seat-2 absolute-square arithmetic the capture and
// blocks files use.

import 'dart:convert';

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test(
    'H1: a non-6 roll that brings a token home with homeBonus true and '
    'other tokens still out grants an extra roll to the same seat',
    () {
      // token 0 at progress 55 rolls 2, reaching exactly 57. Tokens 1-3 are
      // still in the yard (-1), so "other tokens still out" is literal.
      final state = buildState(
        seats: twoPlayerSeats,
        phase: 'awaitMove',
        roll: 2,
        sixes: 0,
        currentSeat: 0,
        homeBonus: true,
        tokens: const {
          0: <int>[55, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(
        applied.events,
        equals(<Object?>[
          isA<Moved>(),
          isA<TokenHome>().having((e) => e.seat, 'seat', 0),
          isA<ExtraRoll>().having((e) => e.seat, 'seat', 0),
        ]),
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 0);
      expect(
        applied.state.sixes,
        0,
        reason: 'roll was not a 6, sixes must stay at what the roll step '
            'already set it to',
      );
    },
  );

  test(
    'H2: the same arrival with homeBonus false (the key absent from the '
    'JSON, which is how fromJson spells off) grants no extra roll and the '
    'turn passes',
    () {
      final state = buildState(
        seats: twoPlayerSeats,
        phase: 'awaitMove',
        roll: 2,
        sixes: 0,
        currentSeat: 0,
        // homeBonus omitted on purpose: absent means false (ENGINE_API.md
        // section 8), which is the only legal way fromJson accepts "off".
        tokens: const {
          0: <int>[55, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(
        applied.events,
        equals(<Object?>[
          isA<Moved>(),
          isA<TokenHome>().having((e) => e.seat, 'seat', 0),
          isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
        ]),
      );
      expect(applied.events.whereType<ExtraRoll>(), isEmpty);
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2, reason: 'turn changes hands');
    },
  );

  test(
    'H3: the arrival that wins the game grants no extra roll even with '
    'homeBonus true, per rule 34',
    () {
      // seat 0's last token, at progress 55, rolls 2 to complete all four.
      final state = buildState(
        seats: twoPlayerSeats,
        phase: 'awaitMove',
        roll: 2,
        sixes: 0,
        currentSeat: 0,
        homeBonus: true,
        tokens: const {
          0: <int>[57, 57, 57, 55],
        },
      );
      final result = apply(state, const MoveIntention(0, 3));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(
        applied.events,
        equals(<Object?>[
          isA<Moved>(),
          isA<TokenHome>().having((e) => e.seat, 'seat', 0),
          isA<GameWon>().having((e) => e.seat, 'seat', 0),
        ]),
      );
      expect(applied.events.whereType<ExtraRoll>(), isEmpty);
      expect(applied.state.phase, GamePhase.finished);
      expect(applied.state.winner, 0);
    },
  );

  test(
    'H4: a 6 that brings a token home with homeBonus true grants exactly '
    'one extra roll, never two',
    () {
      // token 0 at progress 51 rolls 6, reaching exactly 57. The roll
      // itself is a 6 (which alone would earn a bonus) and it is also a
      // home arrival (which also would, on its own, earn a bonus); rule 12
      // says the two must not stack.
      final state = buildState(
        seats: twoPlayerSeats,
        phase: 'awaitMove',
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        homeBonus: true,
        tokens: const {
          0: <int>[51, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(applied.state.tokens[0][0], 57);
      expect(applied.events.whereType<TokenHome>(), hasLength(1));
      expect(
        applied.events.whereType<ExtraRoll>(),
        hasLength(1),
        reason: 'a 6 and a home arrival together must not grant two extra '
            'rolls',
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 0);
    },
  );

  test(
    'H5: a capture is impossible on the home column, so instead: a capture '
    'on the main track with captureBonus false and homeBonus true grants '
    'no roll, because home bonus is not a capture bonus',
    () {
      // seat 0 moves absolute 9 -> 12 on a roll of 3. seat 2's token at
      // progress 38 sits at absolute (26 + 38) mod 52 = 12, alone and not
      // on a safe square, so it is captured. The destination is nowhere
      // near progress 57 for seat 0, so this move could never be confused
      // with a home arrival.
      final state = buildState(
        seats: twoPlayerSeats,
        phase: 'awaitMove',
        roll: 3,
        currentSeat: 0,
        captureBonus: false,
        homeBonus: true,
        tokens: const {
          0: <int>[9, -1, -1, -1],
          2: <int>[38, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(
        applied.state.tokens[2][0],
        -1,
        reason: 'the capture itself still happens, rule 27',
      );
      expect(applied.events.whereType<Captured>(), hasLength(1));
      expect(
        applied.events.whereType<ExtraRoll>(),
        isEmpty,
        reason: 'homeBonus must not pay out a bonus for a capture; '
            'captureBonus is what gates a capture bonus, and it is off here',
      );
      expect(
        applied.events,
        equals(<Object?>[
          isA<Moved>(),
          isA<Captured>(),
          isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
        ]),
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2);
    },
  );

  test(
    'H6: serialisation -- homeBonus is written only when true, at the end '
    'of the rules keys, and fromJson round-trips both and rejects an '
    'explicit false or a non-bool',
    () {
      final offState = buildState(seats: twoPlayerSeats);
      final onState = buildState(seats: twoPlayerSeats, homeBonus: true);

      final offRules = (offState.toJson()['config']!
          as Map<String, Object?>)['rules']! as Map<String, Object?>;
      expect(
        offRules.keys.toList(),
        <String>['blocks', 'captureBonus'],
        reason: 'a false homeBonus must serialise to exactly the bytes it '
            'did before the toggle existed',
      );

      final onRules = (onState.toJson()['config']!
          as Map<String, Object?>)['rules']! as Map<String, Object?>;
      expect(
        onRules.keys.toList(),
        <String>['blocks', 'captureBonus', 'homeBonus'],
        reason: 'homeBonus must appear after captureBonus, and only when '
            'true',
      );

      expect(
        GameState.fromJson(offState.toJson()),
        equals(offState),
        reason: 'round trip of the homeBonus-absent state',
      );
      expect(
        GameState.fromJson(onState.toJson()),
        equals(onState),
        reason: 'round trip of the homeBonus-true state',
      );

      expect(
        () => buildState(seats: twoPlayerSeats, homeBonus: false),
        throwsA(isA<Object>()),
        reason: 'an explicit "homeBonus": false gives one state two '
            'serialisations and must be rejected, per ENGINE_API.md '
            'section 8',
      );

      // bool? cannot carry a non-bool value through buildState, so the
      // malformed-type case is built by hand, matching the exact wire
      // shape of ENGINE_API.md section 8.
      final nonBoolJson = <String, Object?>{
        'config': <String, Object?>{
          'seats': twoPlayerSeats,
          'rules': <String, Object?>{
            'blocks': true,
            'captureBonus': true,
            'homeBonus': 'yes',
          },
          'seed': 1,
        },
        'tokens': const <List<int>>[
          <int>[-1, -1, -1, -1],
          <int>[-1, -1, -1, -1],
          <int>[-1, -1, -1, -1],
          <int>[-1, -1, -1, -1],
        ],
        'currentSeat': 0,
        'phase': 'awaitRoll',
        'roll': null,
        'sixes': 0,
        'winner': null,
        'seq': 0,
        'rngState': 1,
      };
      expect(
        () => GameState.fromJson(nonBoolJson),
        throwsA(isA<Object>()),
        reason: 'a non-bool "homeBonus" is malformed input, like any other '
            'wrongly-typed field',
      );
    },
  );

  test(
    'H7: stateHash is unaffected by the homeBonus key being absent versus '
    'rebuilt through fromJson(toJson()), and the canonical JSON carries no '
    'homeBonus substring when it is false',
    () {
      // An ordinary mid-game position; homeBonus plays no part in it, which
      // is the point.
      final state = buildState(
        seats: twoPlayerSeats,
        phase: 'awaitMove',
        roll: 4,
        currentSeat: 0,
        tokens: const {
          0: <int>[10, 20, -1, -1],
          2: <int>[5, -1, -1, -1],
        },
      );
      final rebuilt = GameState.fromJson(state.toJson());

      expect(
        stateHash(rebuilt),
        stateHash(state),
        reason: 'a state with no homeBonus key must hash identically before '
            'and after a fromJson(toJson()) round trip',
      );
      expect(
        stateHash(state),
        hasLength(16),
        reason: 'stateHash is always exactly 16 lowercase hex characters',
      );

      final canonicalJson = jsonEncode(state.toJson());
      expect(
        canonicalJson.contains('homeBonus'),
        isFalse,
        reason: 'a false homeBonus must leave no trace in the serialised '
            'form, so every pre-ruling hash keeps its value',
      );
    },
  );

  test(
    'H8: RulesConfig(homeBonus: true) is unequal to the all-defaults '
    'config, and the default homeBonus is false',
    () {
      expect(const RulesConfig().homeBonus, isFalse);
      expect(
        const RulesConfig(homeBonus: true),
        isNot(equals(const RulesConfig())),
      );
    },
  );
}

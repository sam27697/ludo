// docs/RULES.md section 3.2a (rules 9q-15q) and docs/ENGINE_API.md section 10:
// the roll queue. With rollQueue on, a turn rolls every owed die first and
// spends the queued faces afterward, in whichever order the player picks.
//
// Q14 to Q16 pin the run 91 rulings in section 10: Rolled.legal is
// legalTokens of the state after the roll, defaultFace is null outside
// awaitMove, and spending a repeated face removes its first occurrence.
// Every seat change sets sixes to 0 (10.4, last paragraph); Q6 checks it.

// Every fixture below that turns rollQueue on also passes `queue` explicitly,
// even when empty: docs/ENGINE_API.md section 10.2 requires both keys
// together ("rollQueue without queue throws", covered in
// roll_queue_json_test.dart), so buildState's JSON must carry both or not at
// all.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Row builder mirroring fixtures.dart's private `_tokenRows`, needed here
/// because buildState has no `homeBonus` parameter (fixtures.dart is only
/// authorised to grow `rollQueue` and `queue`, per order 359). Q8 needs
/// `homeBonus` and `rollQueue` on at once, so it goes around buildState and
/// talks to `GameState.fromJson` directly, exactly as fixtures.dart's own
/// docstring says a test may when the shared builder cannot reach the shape
/// it needs.
List<List<int>> _rows(Map<int, List<int>> tokens) {
  return List<List<int>>.generate(4, (seat) {
    final row = tokens[seat];
    return row == null ? const <int>[-1, -1, -1, -1] : List<int>.of(row);
  });
}

/// A state with both `homeBonus` and `rollQueue` on, per docs/ENGINE_API.md
/// sections 8 and 10.2. Only `main.dart`'s Q8 needs this combination.
GameState buildHomeBonusQueueState({
  required List<int> seats,
  required String phase,
  required List<int> queue,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  int sixes = 0,
  int seq = 0,
  int rngState = 1,
  int seed = 1,
}) {
  return GameState.fromJson(<String, Object?>{
    'config': <String, Object?>{
      'seats': seats,
      'rules': <String, Object?>{
        'blocks': true,
        'captureBonus': true,
        'rollQueue': true,
        'homeBonus': true,
      },
      'seed': seed,
    },
    'tokens': _rows(tokens),
    'currentSeat': currentSeat,
    'phase': phase,
    'roll': null,
    'queue': queue,
    'sixes': sixes,
    'winner': null,
    'seq': seq,
    'rngState': rngState,
  });
}

/// Mirrors rejection_test.dart's helper: a rejected intention must leave the
/// state byte-for-byte as it found it.
void _expectRejectionChangesNothing(
  GameState state,
  Intention intention,
  EngineError expected,
) {
  final beforeJson = state.toJson();
  final beforeHash = stateHash(state);

  final result = apply(state, intention);

  expect(result, isA<Rejected>());
  expect((result as Rejected).error, expected);
  expect(state.toJson(), equals(beforeJson));
  expect(stateHash(state), beforeHash);
}

void main() {
  group('docs/RULES.md 3.2a / docs/ENGINE_API.md section 10: the roll queue',
      () {
    test(
      'Q1: 6,6,3 at turn start rolls two ExtraRolls then lands on awaitMove '
      'with queue [6,6,3]',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitRoll',
          rollQueue: true,
          queue: const <int>[],
          currentSeat: 0,
          sixes: 0,
        );

        final r1 = apply(start, const RollIntention(0, 6));
        expect(r1, isA<Applied>());
        final s1 = (r1 as Applied).state;
        expect(
          r1.events,
          equals(<Object?>[
            isA<Rolled>().having((e) => e.seat, 'seat', 0),
            isA<ExtraRoll>().having((e) => e.seat, 'seat', 0),
          ]),
        );
        expect(s1.queue, equals(const [6]));
        expect(s1.sixes, 1);
        expect(s1.phase, GamePhase.awaitRoll);

        final r2 = apply(s1, const RollIntention(0, 6));
        expect(r2, isA<Applied>());
        final s2 = (r2 as Applied).state;
        expect(
          r2.events,
          equals(<Object?>[isA<Rolled>(), isA<ExtraRoll>()]),
        );
        expect(s2.queue, equals(const [6, 6]));
        expect(s2.sixes, 2);
        expect(s2.phase, GamePhase.awaitRoll);

        final r3 = apply(s2, const RollIntention(0, 3));
        expect(r3, isA<Applied>());
        final s3 = (r3 as Applied).state;
        expect(
          r3.events,
          equals(<Object?>[isA<Rolled>()]),
          reason: 'a non-6 never grants an ExtraRoll, queue or not',
        );
        expect(s3.queue, equals(const [6, 6, 3]));
        expect(s3.sixes, 0, reason: 'a non-6 resets the streak');
        expect(s3.phase, GamePhase.awaitMove);
        expect(s3.roll, isNull, reason: 'the queue replaces state.roll');
        expect(s3.currentSeat, 0);
      },
    );

    test(
      'Q2: 6,6,6 forfeits the turn with TurnEnded(threeSixes), empty queue, '
      'next seat, and no token moved',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitRoll',
          rollQueue: true,
          queue: const <int>[],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );

        final s1 = (apply(start, const RollIntention(0, 6)) as Applied).state;
        final s2 = (apply(s1, const RollIntention(0, 6)) as Applied).state;
        final r3 = apply(s2, const RollIntention(0, 6));
        expect(r3, isA<Applied>());
        final applied = r3 as Applied;

        expect(
          applied.events,
          equals(<Object?>[
            isA<Rolled>().having((e) => e.seat, 'seat', 0),
            isA<TurnEnded>()
                .having((e) => e.seat, 'seat', 0)
                .having((e) => e.reason, 'reason', TurnEndReason.threeSixes),
            isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
          ]),
        );
        expect(applied.events.whereType<Moved>(), isEmpty);
        expect(applied.state.tokens[0][0], 10,
            reason: 'no move was ever offered on the third six');
        expect(applied.state.queue, equals(const <int>[]));
        expect(applied.state.sixes, 0);
        expect(applied.state.currentSeat, 2);
        expect(applied.state.phase, GamePhase.awaitRoll);
      },
    );

    test(
      'Q3: moves made on earlier faces stand when a later bonus streak '
      'hits three 6s; the captured token stays home and the queue is '
      'discarded',
      () {
        // queue [4], a capture pending: seat 0 token at progress 9 (absolute
        // 9) captures seat 2's token at progress 38 (absolute (26+38)%52 =
        // 12... wait, recomputed below) on a move of 4.
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [4],
          currentSeat: 0,
          sixes: 0,
          captureBonus: true,
          tokens: const {
            0: <int>[10, -1, -1, -1],
            2: <int>[40, -1, -1, -1],
          },
        );
        // seat 0 token 10 + 4 = 14 (absolute 14, not a safe square).
        // seat 2 token at progress 40 sits at absolute (26 + 40) % 52 = 14.
        final capture = apply(start, const MoveIntention(0, 0, face: 4));
        expect(capture, isA<Applied>());
        final afterCapture = capture as Applied;
        expect(
          afterCapture.events,
          equals(<Object?>[
            isA<Moved>(),
            isA<Captured>(),
            isA<ExtraRoll>().having((e) => e.seat, 'seat', 0),
          ]),
        );
        expect(afterCapture.state.tokens[0][0], 14);
        expect(afterCapture.state.tokens[2][0], -1);
        expect(afterCapture.state.queue, equals(const <int>[]));
        expect(afterCapture.state.sixes, 0);
        expect(afterCapture.state.phase, GamePhase.awaitRoll);
        expect(afterCapture.state.currentSeat, 0);

        final s1 =
            (apply(afterCapture.state, const RollIntention(0, 6)) as Applied)
                .state;
        final s2 = (apply(s1, const RollIntention(0, 6)) as Applied).state;
        final r3 = apply(s2, const RollIntention(0, 6));
        expect(r3, isA<Applied>());
        final afterForfeit = r3 as Applied;

        expect(
          afterForfeit.events,
          equals(<Object?>[
            isA<Rolled>(),
            isA<TurnEnded>()
                .having((e) => e.reason, 'reason', TurnEndReason.threeSixes),
            isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
          ]),
        );
        expect(afterForfeit.state.tokens[0][0], 14,
            reason: 'the earlier capturing move stands');
        expect(afterForfeit.state.tokens[2][0], -1,
            reason: 'the captured token stays home; the forfeit does not '
                'undo rule 27');
        expect(afterForfeit.state.queue, equals(const <int>[]),
            reason: 'the forfeit discards every unspent face');
        expect(afterForfeit.state.sixes, 0);
        expect(afterForfeit.state.currentSeat, 2);
      },
    );

    test(
      'Q4a: queue [6,3] with a token in the yard and one out -- spending '
      'the 3 before the 6 is legal',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 3],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[-1, 5, -1, -1],
          },
        );

        final r1 = apply(start, const MoveIntention(0, 1, face: 3));
        expect(r1, isA<Applied>(), reason: 'spending the 3 first is legal');
        final s1 = (r1 as Applied).state;
        expect(s1.queue, equals(const [6]));
        expect(s1.tokens[0][1], 8);
        expect(s1.phase, GamePhase.awaitMove,
            reason: 'face 6 still has legal tokens');

        final r2 = apply(s1, const MoveIntention(0, 0, face: 6));
        expect(r2, isA<Applied>(), reason: 'spending the 6 second is legal');
        final s2 = (r2 as Applied).state;
        expect(s2.queue, equals(const <int>[]));
        expect(s2.tokens[0][0], 0);
        expect(s2.phase, GamePhase.awaitRoll);
        expect(s2.currentSeat, 2);
      },
    );

    test(
      'Q4b: the same queue [6,3] also accepts the 6 before the 3, and both '
      'orders land on the same final position',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 3],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[-1, 5, -1, -1],
          },
        );

        final r1 = apply(start, const MoveIntention(0, 0, face: 6));
        expect(r1, isA<Applied>(), reason: 'spending the 6 first is legal');
        final s1 = (r1 as Applied).state;
        expect(s1.queue, equals(const [3]));
        expect(s1.tokens[0][0], 0);
        expect(s1.phase, GamePhase.awaitMove);

        final r2 = apply(s1, const MoveIntention(0, 1, face: 3));
        expect(r2, isA<Applied>(), reason: 'spending the 3 second is legal');
        final s2 = (r2 as Applied).state;
        expect(s2.queue, equals(const <int>[]));
        expect(s2.tokens[0][1], 8);
        expect(s2.phase, GamePhase.awaitRoll);
        expect(s2.currentSeat, 2);

        expect(s2.tokens[0], equals(const [0, 8, -1, -1]),
            reason: 'order of spending does not change where the tokens '
                'end up');
      },
    );

    test(
      'Q5: a face legal only after another is spent stays queued and is '
      'then playable (6 brings the only token out, 3 then moves it)',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 3],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
          },
        );
        expect(
          legalByFace(start),
          equals(const {
            6: [0],
          }),
          reason: 'the only token is in the yard; only 6 can move it '
              '(rule 17), so 3 is queued with no legal target yet',
        );

        final r1 = apply(start, const MoveIntention(0, 0, face: 6));
        expect(r1, isA<Applied>());
        final s1 = (r1 as Applied).state;
        expect(s1.queue, equals(const [3]));
        expect(s1.tokens[0][0], 0);
        expect(s1.phase, GamePhase.awaitMove);
        expect(
          legalByFace(s1),
          equals(const {
            3: [0],
          }),
          reason: 'now on the track, the token can use the still-queued 3',
        );

        final r2 = apply(s1, const MoveIntention(0, 0, face: 3));
        expect(r2, isA<Applied>());
        final s2 = (r2 as Applied).state;
        expect(s2.queue, equals(const <int>[]));
        expect(s2.tokens[0][0], 3);
        expect(s2.phase, GamePhase.awaitRoll);
        expect(s2.currentSeat, 2);
      },
    );

    test(
      'Q6: a dead remainder after a move ends the turn with '
      'TurnEnded(noLegalMove), TurnBegan, and an empty queue',
      () {
        // seat 2 holds a block at absolute square 3 (progress 29: (26+29)
        // % 52 = 3). The lone seat 0 token leaves the yard on the 6, lands
        // on absolute 0, and a +5 move would cross squares 1..5, including
        // the blocked square 3 (rules 22, 23).
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 5],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
            2: <int>[29, 29, -1, -1],
          },
        );
        expect(
          legalByFace(start),
          equals(const {
            6: [0],
          }),
          reason: '5 is already dead before the move: the only token is in '
              'the yard and only 6 can bring it out',
        );

        final result = apply(start, const MoveIntention(0, 0, face: 6));
        expect(result, isA<Applied>());
        final applied = result as Applied;

        expect(
          applied.events,
          equals(<Object?>[
            isA<Moved>(),
            isA<TurnEnded>()
                .having((e) => e.seat, 'seat', 0)
                .having((e) => e.reason, 'reason', TurnEndReason.noLegalMove),
            isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
          ]),
        );
        expect(applied.state.tokens[0][0], 0);
        expect(applied.state.queue, equals(const <int>[]));
        expect(applied.state.currentSeat, 2);
        expect(applied.state.phase, GamePhase.awaitRoll);
        // docs/ENGINE_API.md section 10.4 step 6 does not restate "sixes =
        // 0" the way step 5 does; this follows from the general rule that
        // sixes resets the moment the turn changes hands (section 5).
        expect(applied.state.sixes, 0);
      },
    );

    test(
      'Q7: a capture mid-queue grants an ExtraRoll into awaitRoll, keeps '
      "the queue, and appends the bonus roll's face at the end",
      () {
        // seat 0 token 9 + 3 = 12 (absolute 12, not safe). seat 2 token at
        // progress 38 sits at absolute (26+38)%52 = 12.
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [3, 2],
          currentSeat: 0,
          sixes: 0,
          captureBonus: true,
          tokens: const {
            0: <int>[9, -1, -1, -1],
            2: <int>[38, -1, -1, -1],
          },
        );

        final capture = apply(start, const MoveIntention(0, 0, face: 3));
        expect(capture, isA<Applied>());
        final afterCapture = capture as Applied;
        expect(
          afterCapture.events,
          equals(<Object?>[
            isA<Moved>(),
            isA<Captured>(),
            isA<ExtraRoll>().having((e) => e.seat, 'seat', 0),
          ]),
        );
        expect(afterCapture.state.tokens[2][0], -1);
        expect(afterCapture.state.phase, GamePhase.awaitRoll);
        expect(afterCapture.state.currentSeat, 0);
        expect(afterCapture.state.queue, equals(const [2]),
            reason: 'the unspent face is kept, not cleared, by the bonus');

        final bonusRoll = apply(afterCapture.state, const RollIntention(0, 5));
        expect(bonusRoll, isA<Applied>());
        final afterBonusRoll = bonusRoll as Applied;
        expect(afterBonusRoll.state.queue, equals(const [2, 5]),
            reason: "the bonus roll's face joins the end of the kept queue");
        expect(afterBonusRoll.state.phase, GamePhase.awaitMove);
      },
    );

    test(
      'Q8a: a non-winning home arrival mid-queue (homeBonus on) behaves '
      'like Q7: ExtraRoll, queue kept, bonus face appended at the end',
      () {
        final start = buildHomeBonusQueueState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          queue: const [4, 2],
          currentSeat: 0,
          tokens: const {
            0: <int>[53, 10, -1, -1],
          },
        );

        final arrival = apply(start, const MoveIntention(0, 0, face: 4));
        expect(arrival, isA<Applied>());
        final afterArrival = arrival as Applied;
        expect(
          afterArrival.events,
          equals(<Object?>[
            isA<Moved>(),
            isA<TokenHome>().having((e) => e.token, 'token', 0),
            isA<ExtraRoll>().having((e) => e.seat, 'seat', 0),
          ]),
        );
        expect(afterArrival.state.tokens[0][0], 57);
        expect(afterArrival.state.winner, isNull,
            reason: 'only one of the four tokens is home');
        expect(afterArrival.state.phase, GamePhase.awaitRoll);
        expect(afterArrival.state.queue, equals(const [2]),
            reason: 'kept, exactly as a capture bonus keeps it');

        final bonusRoll = apply(afterArrival.state, const RollIntention(0, 5));
        expect(bonusRoll, isA<Applied>());
        expect((bonusRoll as Applied).state.queue, equals(const [2, 5]));
      },
    );

    test(
      'Q8b: a winning home arrival ends the game at once, discards every '
      'unspent face, and grants no ExtraRoll even with homeBonus on',
      () {
        final start = buildHomeBonusQueueState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          queue: const [4, 6],
          currentSeat: 0,
          tokens: const {
            0: <int>[53, 57, 57, 57],
          },
        );

        final result = apply(start, const MoveIntention(0, 0, face: 4));
        expect(result, isA<Applied>());
        final applied = result as Applied;

        expect(
          applied.events,
          equals(<Object?>[
            isA<Moved>(),
            isA<TokenHome>(),
            isA<GameWon>().having((e) => e.seat, 'seat', 0),
          ]),
        );
        expect(applied.events.whereType<ExtraRoll>(), isEmpty);
        expect(applied.state.winner, 0);
        expect(applied.state.phase, GamePhase.finished);
        expect(applied.state.queue, equals(const <int>[]),
            reason: 'the unspent 6 is discarded by the win, not kept');
        expect(isTerminal(applied.state), isTrue);
      },
    );

    test(
      'Q9a: a 6 spent on a move grants nothing, and the turn continues '
      'while a face remains',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 3],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );

        final result = apply(start, const MoveIntention(0, 0, face: 6));
        expect(result, isA<Applied>());
        final applied = result as Applied;

        expect(applied.events, equals(<Object?>[isA<Moved>()]));
        expect(applied.events.whereType<ExtraRoll>(), isEmpty,
            reason: 'the 6 was already rewarded when it was rolled');
        expect(applied.state.queue, equals(const [3]));
        expect(applied.state.phase, GamePhase.awaitMove);
        expect(applied.state.currentSeat, 0);
      },
    );

    test(
      'Q9b: a 6 spent as the only remaining face grants nothing and the '
      'turn passes exactly as any other last face would',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );

        final result = apply(start, const MoveIntention(0, 0, face: 6));
        expect(result, isA<Applied>());
        final applied = result as Applied;

        expect(
          applied.events,
          equals(<Object?>[
            isA<Moved>(),
            isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
          ]),
        );
        expect(applied.events.whereType<ExtraRoll>(), isEmpty);
        expect(applied.state.queue, equals(const <int>[]));
        expect(applied.state.currentSeat, 2);
        expect(applied.state.sixes, 0);
      },
    );

    test(
      'Q10a: MoveIntention with no face spends defaultFace, the first '
      'queued face with a legal token, not merely the first queued face',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [3, 6],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
          },
        );
        expect(defaultFace(start), 6,
            reason: '3 is queued first but has no legal token; 6 does');

        final result = apply(start, const MoveIntention(0, 0));
        expect(result, isA<Applied>());
        final applied = result as Applied;
        expect(applied.state.queue, equals(const [3]),
            reason: 'only the 6 instance is removed; the earlier-queued 3 '
                'is untouched');
        expect(applied.state.tokens[0][0], 0);
      },
    );

    test(
      'Q10b: a face not present in the queue is illegalMove and leaves the '
      'state untouched',
      () {
        final state = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [3, 6],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
          },
        );
        _expectRejectionChangesNothing(
          state,
          const MoveIntention(0, 0, face: 5),
          EngineError.illegalMove,
        );
      },
    );

    test(
      'Q10c: a queued face that is not legal for the named token is '
      'illegalMove and leaves the state untouched',
      () {
        final state = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [3, 6],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
          },
        );
        // face 3 is queued, but token 0 is in the yard and rule 17 lets
        // only a 6 bring it out.
        _expectRejectionChangesNothing(
          state,
          const MoveIntention(0, 0, face: 3),
          EngineError.illegalMove,
        );
      },
    );

    test(
      'Q11a: legalByFace lists only faces with a legal token, in '
      'first-queued order, each with its tokens ascending',
      () {
        // Tokens 1 and 3 sit in the home column at progress 53 and 54: a
        // +6 overshoots 57 for both (rule 19), so face 6 has no legal
        // token and is absent from the map, while +3 and +2 stay in range
        // for both.
        final state = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 3, 2],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[57, 53, 57, 54],
          },
        );

        final map = legalByFace(state);
        expect(map.keys.toList(), equals(const [3, 2]),
            reason: '6 is excluded; the remaining faces keep queue order');
        expect(map[3], equals(const [1, 3]));
        expect(map[2], equals(const [1, 3]));
        expect(map.containsKey(6), isFalse);
      },
    );

    test(
        'Q11b: legalByFace is empty in awaitRoll, even with a non-empty '
        'queue mid-streak', () {
      final state = buildState(
        seats: twoPlayerSeats,
        phase: 'awaitRoll',
        rollQueue: true,
        queue: const [6],
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[10, -1, -1, -1],
        },
      );
      expect(legalByFace(state), isEmpty,
          reason: 'legalByFace is gated by phase, not by queue contents');
    });

    test('Q11c: legalByFace is empty in a finished game', () {
      final state = buildState(
        seats: twoPlayerSeats,
        phase: 'finished',
        rollQueue: true,
        queue: const <int>[],
        winner: 0,
        currentSeat: 0,
        tokens: const {
          0: <int>[57, 57, 57, 57],
        },
      );
      expect(legalByFace(state), isEmpty);
    });

    test(
      'Q12: legalTokens under rollQueue returns the legal tokens of '
      'defaultFace, not of the first queued face, and stays empty outside '
      'awaitMove',
      () {
        final state = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [3, 6],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
          },
        );
        expect(defaultFace(state), 6);
        expect(legalByFace(state)[defaultFace(state)], equals(const [0]));
        expect(legalTokens(state), equals(const [0]));
        expect(
            legalTokens(state), equals(legalByFace(state)[defaultFace(state)]));

        final awaitingRoll = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitRoll',
          rollQueue: true,
          queue: const [6],
          sixes: 1,
          currentSeat: 0,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );
        expect(legalTokens(awaitingRoll), isEmpty,
            reason: 'legalTokens still returns [] outside awaitMove '
                '(docs/ENGINE_API.md section 4), unchanged by rollQueue');
      },
    );

    test(
      'Q13a: sixes resets to 0 on a non-6 roll even after a 6 raised it',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitRoll',
          rollQueue: true,
          queue: const <int>[],
          sixes: 0,
          currentSeat: 0,
          tokens: const {
            0: <int>[-1, 10, -1, -1],
          },
        );
        final afterSix = apply(start, const RollIntention(0, 6));
        expect((afterSix as Applied).state.sixes, 1);

        final afterNonSix = apply(afterSix.state, const RollIntention(0, 2));
        expect(afterNonSix, isA<Applied>());
        final applied = afterNonSix as Applied;
        expect(applied.state.sixes, 0,
            reason: 'a non-6 resets the streak even though it was 1');
        expect(applied.state.queue, equals(const [6, 2]));
        expect(applied.state.phase, GamePhase.awaitMove);
      },
    );

    test(
      'Q13b: sixes resets to 0 on a capture bonus, and a 6,6,6 streak '
      'rolled after that bonus still voids the turn (rule 10q) regardless '
      'of the non-6 face already spent earlier in the turn',
      () {
        // sixes: 1 is constructed directly rather than reached through
        // play: entering awaitMove under rollQueue always follows a non-6
        // roll (docs/ENGINE_API.md section 10.3 step 4), which always sets
        // sixes to 0 first, so a real game can never have sixes != 0 at
        // awaitMove. This fixture exists only to pin the literal "sixes =
        // 0" instruction of section 10.4 step 3 regardless of that
        // precondition's reachability, the same way fixtures.dart's own
        // docstring endorses reaching for buildState to hit an exact shape
        // play cannot produce.
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [2],
          currentSeat: 0,
          sixes: 1,
          captureBonus: true,
          tokens: const {
            0: <int>[10, -1, -1, -1],
            2: <int>[38, -1, -1, -1],
          },
        );
        // seat 0 token 10 + 2 = 12 (absolute 12, not safe). seat 2 token at
        // progress 38 sits at absolute (26+38)%52 = 12.
        final capture = apply(start, const MoveIntention(0, 0, face: 2));
        expect(capture, isA<Applied>());
        final afterCapture = capture as Applied;
        expect(afterCapture.state.tokens[2][0], -1);
        expect(afterCapture.state.sixes, 0,
            reason: 'the capture bonus sets sixes to 0 outright, per '
                'section 10.4 step 3, regardless of the prior value');
        expect(afterCapture.state.queue, equals(const <int>[]));
        expect(afterCapture.state.phase, GamePhase.awaitRoll);

        final s1 =
            (apply(afterCapture.state, const RollIntention(0, 6)) as Applied)
                .state;
        expect(s1.sixes, 1);
        final s2 = (apply(s1, const RollIntention(0, 6)) as Applied).state;
        expect(s2.sixes, 2);
        final r3 = apply(s2, const RollIntention(0, 6));
        expect(r3, isA<Applied>());
        final afterForfeit = r3 as Applied;

        expect(
          afterForfeit.events,
          equals(<Object?>[
            isA<Rolled>(),
            isA<TurnEnded>()
                .having((e) => e.reason, 'reason', TurnEndReason.threeSixes),
            isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
          ]),
        );
        expect(afterForfeit.state.queue, equals(const <int>[]));
        expect(afterForfeit.state.sixes, 0);
        expect(afterForfeit.state.currentSeat, 2);
      },
    );

    test(
      'Q14: Rolled.legal is legalTokens of the state after the roll: [] '
      'after a queued 6, the default face tokens after the closing non-6',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitRoll',
          rollQueue: true,
          queue: const <int>[],
          currentSeat: 0,
          sixes: 0,
        );

        // Every token is in the yard, so a 6 alone could bring any of them
        // out; the roll still owes another roll, so nothing is movable yet.
        final r1 = apply(start, const RollIntention(0, 6)) as Applied;
        expect((r1.events.first as Rolled).legal, isEmpty);

        // The closing 3 moves nothing by itself, but the queued 6 can bring
        // every token out: legal is the default face's tokens, not the 3's.
        final r2 = apply(r1.state, const RollIntention(0, 3)) as Applied;
        final rolled = r2.events.first as Rolled;
        expect(rolled.value, 3);
        expect(rolled.legal, equals(const [0, 1, 2, 3]));
        expect(rolled.legal, equals(legalTokens(r2.state)));
      },
    );

    test(
      'Q14b: Rolled.legal is [] when the roll passes the turn',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitRoll',
          rollQueue: true,
          queue: const <int>[],
          currentSeat: 0,
          sixes: 0,
        );
        final r = apply(start, const RollIntention(0, 3)) as Applied;
        expect(r.events[1], isA<TurnEnded>());
        expect((r.events.first as Rolled).legal, isEmpty);
      },
    );

    test(
      'Q15: defaultFace is null in awaitRoll even when a queued face has a '
      'legal token',
      () {
        final state = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitRoll',
          rollQueue: true,
          queue: const [6],
          sixes: 1,
          currentSeat: 0,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );
        expect(defaultFace(state), isNull);
        expect(legalTokens(state), isEmpty);
      },
    );

    test(
      'Q16: spending a face queued twice removes its first occurrence and '
      'keeps the order of the rest',
      () {
        final start = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 3, 6],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );
        final r = apply(start, const MoveIntention(0, 0, face: 6)) as Applied;
        expect(r.state.queue, equals(const [3, 6]));
      },
    );
  });
}

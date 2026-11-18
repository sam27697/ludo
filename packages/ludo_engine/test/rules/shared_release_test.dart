// docs/RULES.md section 3.2c (rules 16s to 20s) and docs/ENGINE_API.md
// section 13: the shared release. A seat that reaches the tenth non-6 with
// every token in the yard is OFFERED a release and chooses to take it or to
// decline it. Taking it brings one token out, ends the turn at once and
// grants every other playing seat a banked six; declining brings nothing out,
// grants nothing and leaves the drought at 9.
//
// Written from the two documents only. Every state is reached one of two
// ways and each case says which:
//
//   play      newGame, then intentions applied one by one;
//   hand      GameState.fromJson of a hand-written map (test/support).
//
// Every failure message carries the scenario name, the seed and the list of
// intentions applied so far, which is everything needed to replay it. The
// random games at the bottom carry their seed in the test name and in every
// message.
//
// These tests cannot pass until the engine grows the names of section 13
// (RulesConfig.sharedRelease, GameState.banked, GameState.releaseOffered,
// DeclineIntention, ReleaseDeclined, SixesBanked, SixesQueued,
// TurnEndReason.released). Until then the file does not compile.

import 'dart:convert';
import 'dart:io';

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/shared_release_support.dart';
import '../support/splitmix64.dart';

// ---------------------------------------------------------------------------
// The shape of a take, stated once from rules 17s and 13.4 / 13.6.
// ---------------------------------------------------------------------------

/// Applies the take of [token] by [seat] on [run] and checks every line of
/// rule 17s: the events in order, the new state, the banked counts.
///
/// [playing] is every seat still playing, ascending. [pre] is the banked list
/// before the take.
void expectTake(
  Run run,
  List<int> playing,
  int seat,
  int token, {
  List<int> pre = zeros,
}) {
  final before = run.state;
  final grantees = others(playing, seat);
  final next = nextOf(playing, seat);
  final owed = pre[next] + 1;
  final events = run.move(seat, token);
  expect(
    events,
    equals(<String>[
      'Moved($seat,$token,-1->0)',
      'YardReleased($seat)',
      'SixesBanked($grantees)',
      'TurnEnded($seat,released)',
      'TurnBegan($next)',
      'SixesQueued($next,$owed)',
    ]),
    reason: 'taking the release: expected Moved, YardReleased, SixesBanked, '
        'TurnEnded(released), TurnBegan, SixesQueued; got $events. '
        '${run.trace}',
  );
  final s = run.state;
  final wantBanked = List<int>.of(pre);
  for (final g in grantees) {
    wantBanked[g] += 1;
  }
  wantBanked[next] = 0;
  expect(s.banked, equals(wantBanked),
      reason: 'banked after the take: expected $wantBanked (every other '
          'playing seat +1, the next seat\'s count moved into its queue); '
          'got ${s.banked}. ${run.trace}');
  expect(s.currentSeat, next, reason: run.trace);
  expect(s.phase, GamePhase.awaitRoll,
      reason: 'the taker must not roll again and the next seat starts at '
          'awaitRoll. ${run.trace}');
  expect(s.queue, equals(List<int>.filled(owed, 6)),
      reason: 'the next seat\'s queue is its banked sixes and nothing else; '
          'the drawn face is gone. ${run.trace}');
  expect(s.sixes, 0, reason: run.trace);
  expect(s.roll, isNull, reason: run.trace);
  expect(s.releaseOwed, isFalse, reason: run.trace);
  expect(s.releaseOffered, isFalse, reason: run.trace);
  expect(s.drought[seat], 0,
      reason: 'the taker\'s drought is 0 (13.4). ${run.trace}');
  for (var t = 0; t < 4; t++) {
    expect(s.tokens[seat][t], t == token ? 0 : before.tokens[seat][t],
        reason: 'only token $token comes out, onto the entry square. '
            '${run.trace}');
  }
  expect(s.seq, before.seq + 1, reason: run.trace);
}

void main() {
  // -------------------------------------------------------------------------
  group('S1 (play): the offer on the tenth non-6 (rule 16s, 13.3)', () {
    for (final seats in <List<int>>[twoSeats, threeSeats, fourSeats]) {
      for (var face = 1; face <= 5; face++) {
        test('$seats seats, tenth roll is a $face', () {
          final run = Run('S1 $seats tenth roll $face',
              newGame(sharedConfig(seats: seats)));
          expect(run.state.banked, equals(zeros));
          expect(run.state.releaseOffered, isFalse);
          stuckRounds(run, seats, 9);
          for (final s in seats) {
            expect(run.state.drought[s], 9,
                reason: 'nine rounds of non-6: drought 9. ${run.trace}');
          }
          final seqBefore = run.state.seq;

          final events = run.roll(0, face);
          expect(
            events,
            equals(<String>[
              rolled(0, face, const <int>[0, 1, 2, 3])
            ]),
            reason: 'the tenth non-6 only offers: Rolled with legal = the '
                'releasable tokens, and no YardReleased yet. got $events. '
                '${run.trace}',
          );
          final s = run.state;
          expect(s.releaseOwed, isTrue, reason: run.trace);
          expect(s.releaseOffered, isTrue, reason: run.trace);
          expect(s.phase, GamePhase.awaitMove, reason: run.trace);
          expect(s.currentSeat, 0, reason: run.trace);
          expect(s.queue, equals(<int>[face]), reason: run.trace);
          expect(s.sixes, 0, reason: run.trace);
          expect(s.roll, isNull, reason: run.trace);
          expect(s.drought[0], 9,
              reason: 'the offer leaves the drought at 9 (13.3). '
                  '${run.trace}');
          expect(s.banked, equals(zeros),
              reason: 'nothing is banked by an offer. ${run.trace}');
          expect(s.seq, seqBefore + 1, reason: run.trace);
          expect(s.tokens[0], equals(yardRow),
              reason: 'nothing has moved yet. ${run.trace}');
          expect(legalTokens(s), equals(<int>[0, 1, 2, 3]), reason: run.trace);
          expect(legalByFace(s), isEmpty,
              reason: 'legalByFace is empty while a release is offered. '
                  '${run.trace}');
          expect(defaultFace(s), isNull, reason: run.trace);
        });
      }
    }

    test('nine non-6 rolls offer nothing', () {
      final run = Run('S1 nine rolls', newGame(sharedConfig()));
      stuckRounds(run, twoSeats, 9);
      expect(run.state.releaseOffered, isFalse, reason: run.trace);
      expect(run.state.releaseOwed, isFalse, reason: run.trace);
      expect(run.state.banked, equals(zeros), reason: run.trace);
    });

    test('a 6 at drought 9 is not an offer, it clears the count', () {
      final run = Run('S1 six at 9', hand(drought: const <int>[9, 0, 0, 0]));
      final events = run.roll(0, 6);
      expect(
          events, equals(<String>[rolled(0, 6, const <int>[]), 'ExtraRoll(0)']),
          reason: run.trace);
      expect(run.state.drought[0], 0, reason: run.trace);
      expect(run.state.releaseOffered, isFalse, reason: run.trace);
      expect(run.state.releaseOwed, isFalse, reason: run.trace);
    });

    test('a seat with a token on the track is never offered', () {
      final run = Run(
        'S1 token on track',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[10, -1, -1, -1],
          },
          drought: const <int>[9, 0, 0, 0],
        ),
      );
      final events = run.roll(0, 3);
      expect(
          events,
          equals(<String>[
            rolled(0, 3, const <int>[0])
          ]),
          reason: run.trace);
      expect(run.state.releaseOffered, isFalse, reason: run.trace);
      expect(run.state.drought[0], 0, reason: run.trace);
    });

    test('hand: a single opponent token on the entry square still offers', () {
      final run = Run(
        'S1 single token on entry square',
        hand(
          tokens: const <int, List<int>>{
            2: <int>[26, -1, -1, -1],
          },
          drought: const <int>[9, 0, 0, 0],
        ),
      );
      expect(
          run.roll(0, 2),
          equals(<String>[
            rolled(0, 2, const <int>[0, 1, 2, 3])
          ]),
          reason: run.trace);
      expect(run.state.releaseOffered, isTrue, reason: run.trace);
    });
  });

  // -------------------------------------------------------------------------
  group('S2 (play): taking the release (rule 17s, 13.4)', () {
    for (final seats in <List<int>>[twoSeats, threeSeats, fourSeats]) {
      test('$seats seats: every other seat is granted a banked six', () {
        final run = Run('S2 take, $seats', newGame(sharedConfig(seats: seats)));
        stuckRounds(run, seats, 9);
        run.roll(0, 4);
        expectTake(run, seats, 0, 2);
        // The taker did not roll again: the seat to act is the next one.
        expect(run.state.currentSeat, isNot(0), reason: run.trace);
      });
    }

    test('the drawn face is gone and the taker is not rolled again', () {
      final run = Run('S2 no further roll', newGame(sharedConfig()));
      stuckRounds(run, twoSeats, 9);
      run.roll(0, 5);
      final events = run.move(0, 3);
      expect(events.any((e) => e.startsWith('ExtraRoll')), isFalse,
          reason: 'a release is not a 6 and grants no roll. got $events. '
              '${run.trace}');
      expect(run.state.queue.contains(5), isFalse,
          reason: 'the drawn 5 is discarded. ${run.trace}');
      expect(run.refused(const RollIntention(0, 3)), isNotNull,
          reason: 'seat 0 may not roll again after taking. ${run.trace}');
      expect(run.refused(const MoveIntention(0, 3, face: 5)), isNotNull,
          reason: 'the discarded face cannot be spent. ${run.trace}');
    });

    test('every token index can be the one released', () {
      for (var token = 0; token < 4; token++) {
        final run = Run('S2 token $token', offeredHand());
        expectTake(run, twoSeats, 0, token);
      }
    });

    for (final seats in <List<int>>[twoSeats, threeSeats, fourSeats]) {
      for (final seat in seats) {
        test('hand: seat $seat of $seats takes; next seat wraps around', () {
          final run = Run('S2 hand take seat $seat of $seats',
              offeredHand(seats: seats, seat: seat));
          expectTake(run, seats, seat, 1);
        });
      }
    }

    test('hand: banked sixes already owed add one more (a count of 2, 3)', () {
      final two = Run(
        'S2 pre-banked 1 on seat 2',
        offeredHand(banked: const <int>[0, 0, 1, 0]),
      );
      expectTake(two, twoSeats, 0, 0, pre: const <int>[0, 0, 1, 0]);

      final three = Run(
        'S2 pre-banked 2 on seat 1, four seats',
        offeredHand(seats: fourSeats, banked: const <int>[0, 2, 0, 0]),
      );
      expectTake(three, fourSeats, 0, 0, pre: const <int>[0, 2, 0, 0]);
      expect(three.state.queue, equals(<int>[6, 6, 6]), reason: three.trace);
    });

    test('hand: a finished seat is not granted a banked six', () {
      final run = Run(
        'S2 finished seat 1',
        hand(
          seats: threeSeats,
          tokens: const <int, List<int>>{
            1: <int>[57, 57, 57, 57],
          },
          currentSeat: 0,
          phase: 'awaitMove',
          queue: const <int>[3],
          drought: const <int>[9, 0, 0, 0],
          releaseOwed: true,
          releaseOffered: true,
          playOut: true,
          placings: const <int>[1],
        ),
      );
      expectTake(run, const <int>[0, 2], 0, 0);
      expect(run.state.banked[1], 0,
          reason: 'finished seat 1 holds no banked six. ${run.trace}');
    });

    test('hand: a retired seat is not granted a banked six', () {
      final run = Run(
        'S2 retired seat 1',
        hand(
          seats: threeSeats,
          currentSeat: 0,
          phase: 'awaitMove',
          queue: const <int>[3],
          drought: const <int>[9, 0, 0, 0],
          releaseOwed: true,
          releaseOffered: true,
          playOut: true,
          retired: const <int>[1],
        ),
      );
      expectTake(run, const <int>[0, 2], 0, 0);
      expect(run.state.banked[1], 0,
          reason: 'retired seat 1 holds no banked six. ${run.trace}');
    });

    test('play: a seat retired mid-game is not granted', () {
      final run = Run('S2 retire then take',
          newGame(sharedConfig(seats: threeSeats, playOut: true)));
      expect(run.play(const RetireIntention(1)),
          equals(<String>['SeatRetired(1)']),
          reason: run.trace);
      stuckRounds(run, const <int>[0, 2], 9);
      run.roll(0, 2);
      expectTake(run, const <int>[0, 2], 0, 3);
    });

    test('seat 0 cannot act again once it has taken the release', () {
      final run = Run('S2 taker has a token out, then plays on',
          offeredHand(banked: const <int>[0, 0, 0, 0]));
      expectTake(run, twoSeats, 0, 0);
      // Seat 2 now owns a queued 6 and must roll; seat 0 may not act.
      expect(run.refused(const RollIntention(0, 3)), EngineError.notYourTurn,
          reason: run.trace);
    });
  });

  // -------------------------------------------------------------------------
  group('S3: declining the release (rule 18s, 13.4)', () {
    test('play: ReleaseDeclined, TurnEnded(noLegalMove), TurnBegan; drought 9',
        () {
      final run = Run('S3 decline', newGame(sharedConfig()));
      stuckRounds(run, twoSeats, 9);
      run.roll(0, 4);
      final seq = run.state.seq;
      final events = run.decline(0);
      expect(
        events,
        equals(<String>[
          'ReleaseDeclined(0)',
          'TurnEnded(0,noLegalMove)',
          'TurnBegan(2)',
        ]),
        reason: 'declining: got $events. ${run.trace}',
      );
      final s = run.state;
      expect(s.tokens[0], equals(yardRow), reason: run.trace);
      expect(s.queue, isEmpty, reason: run.trace);
      expect(s.releaseOwed, isFalse, reason: run.trace);
      expect(s.releaseOffered, isFalse, reason: run.trace);
      expect(s.drought[0], 9,
          reason: 'rule 18s: the drought is 9. ${run.trace}');
      expect(s.banked, equals(zeros),
          reason: 'declining grants nothing. ${run.trace}');
      expect(s.currentSeat, 2, reason: run.trace);
      expect(s.phase, GamePhase.awaitRoll, reason: run.trace);
      expect(s.sixes, 0, reason: run.trace);
      expect(s.seq, seq + 1, reason: run.trace);
    });

    for (final seats in <List<int>>[threeSeats, fourSeats]) {
      test('$seats seats: declining grants nobody anything', () {
        final run =
            Run('S3 decline $seats', newGame(sharedConfig(seats: seats)));
        stuckRounds(run, seats, 9);
        run.roll(0, 3);
        final events = run.decline(0);
        expect(
          events,
          equals(<String>[
            'ReleaseDeclined(0)',
            'TurnEnded(0,noLegalMove)',
            'TurnBegan(1)',
          ]),
          reason: run.trace,
        );
        expect(run.state.banked, equals(zeros), reason: run.trace);
      });
    }

    test('hand: the next non-6 offers again, and again', () {
      // Seat 2 has a token that no face 2..5 can move, so it only passes.
      final run = Run(
        'S3 repeat',
        hand(
          tokens: const <int, List<int>>{
            2: <int>[57, -1, -1, -1],
          },
          drought: const <int>[9, 0, 0, 0],
        ),
      );
      for (var round = 1; round <= 3; round++) {
        final f = face5(round);
        expect(
            run.roll(0, f),
            equals(<String>[
              rolled(0, f, const <int>[0, 1, 2, 3])
            ]),
            reason: 'round $round: the next non-6 after a decline must offer '
                'again. ${run.trace}');
        expect(run.state.drought[0], 9, reason: run.trace);
        expect(run.decline(0), contains('ReleaseDeclined(0)'),
            reason: run.trace);
        expect(run.state.drought[0], 9, reason: run.trace);
        run.roll(2, 2 + (round % 4));
      }
    });

    test('hand: after a decline a 6 resets the drought to 0 (rule 10r)', () {
      final run = Run(
        'S3 six after decline',
        hand(
          tokens: const <int, List<int>>{
            2: <int>[57, -1, -1, -1],
          },
          drought: const <int>[9, 0, 0, 0],
        ),
      );
      run.roll(0, 3);
      run.decline(0);
      run.roll(2, 4);
      expect(run.state.drought[0], 9, reason: run.trace);
      expect(
        run.roll(0, 6),
        equals(<String>[rolled(0, 6, const <int>[]), 'ExtraRoll(0)']),
        reason: run.trace,
      );
      expect(run.state.drought[0], 0, reason: run.trace);
      expect(run.state.releaseOffered, isFalse, reason: run.trace);
      // The real 6 brings a token out; nothing is banked by a 6.
      run.roll(0, 2);
      expect(run.move(0, 0, face: 6), equals(<String>['Moved(0,0,-1->0)']),
          reason: 'a spent 6 grants no roll. ${run.trace}');
      expect(run.state.drought[0], 0, reason: run.trace);
      expect(run.state.banked, equals(zeros), reason: run.trace);
    });

    test('play: both seats at drought 10 in a row are each offered', () {
      final run = Run('S3 both offered', newGame(sharedConfig()));
      stuckRounds(run, twoSeats, 9);
      run.roll(0, 4);
      run.decline(0);
      expect(
          run.roll(2, 3),
          equals(<String>[
            rolled(2, 3, const <int>[0, 1, 2, 3])
          ]),
          reason: 'seat 2 also reaches its tenth: ${run.trace}');
      expect(run.state.currentSeat, 2, reason: run.trace);
      expect(run.state.releaseOffered, isTrue, reason: run.trace);
      run.decline(2);
      expect(run.state.drought, equals(<int>[9, 0, 9, 0]), reason: run.trace);
      expect(
          run.roll(0, 1),
          equals(<String>[
            rolled(0, 1, const <int>[0, 1, 2, 3])
          ]),
          reason: run.trace);
    });

    test('hand: a decline with a banked six owed to the next seat queues it',
        () {
      final run = Run('S3 decline with banked',
          offeredHand(banked: const <int>[0, 0, 1, 0]));
      expect(
        run.decline(0),
        equals(<String>[
          'ReleaseDeclined(0)',
          'TurnEnded(0,noLegalMove)',
          'TurnBegan(2)',
          'SixesQueued(2,1)',
        ]),
        reason: run.trace,
      );
      expect(run.state.queue, equals(<int>[6]), reason: run.trace);
      expect(run.state.banked, equals(zeros), reason: run.trace);
    });
  });

  // -------------------------------------------------------------------------
  group('S4 (hand): the offer lapses (rule 16s, 13.3)', () {
    // Seat 2 holds two tokens on progress 26 = absolute square 0: a block on
    // seat 0's entry square.
    Map<int, List<int>> blocked() => const <int, List<int>>{
          2: <int>[26, 26, -1, -1],
        };

    test('nothing banked, drought 0, no YardReleased, the turn passes', () {
      final run = Run('S4 lapse',
          hand(tokens: blocked(), drought: const <int>[9, 0, 0, 0]));
      final events = run.roll(0, 3);
      expect(
        events,
        equals(<String>[
          rolled(0, 3, const <int>[]),
          'TurnEnded(0,noLegalMove)',
          'TurnBegan(2)',
        ]),
        reason: 'a lapse emits no YardReleased and no SixesBanked (13.5). '
            'got $events. ${run.trace}',
      );
      final s = run.state;
      expect(s.drought[0], 0, reason: run.trace);
      expect(s.banked, equals(zeros), reason: run.trace);
      expect(s.releaseOwed, isFalse, reason: run.trace);
      expect(s.releaseOffered, isFalse, reason: run.trace);
      expect(s.queue, isEmpty, reason: run.trace);
      expect(s.currentSeat, 2, reason: run.trace);
      expect(s.phase, GamePhase.awaitRoll, reason: run.trace);
    });

    test('three seats: a lapse banks nothing for either other seat', () {
      final run = Run(
        'S4 lapse three seats',
        hand(
          seats: threeSeats,
          tokens: blocked(),
          drought: const <int>[9, 0, 0, 0],
        ),
      );
      run.roll(0, 2);
      expect(run.state.banked, equals(zeros), reason: run.trace);
      expect(run.state.currentSeat, 1, reason: run.trace);
    });

    test('a banked six owed to the next seat is still queued after a lapse',
        () {
      final run = Run(
        'S4 lapse with banked',
        hand(
          tokens: blocked(),
          drought: const <int>[9, 0, 0, 0],
          banked: const <int>[0, 0, 2, 0],
        ),
      );
      expect(
        run.roll(0, 3),
        equals(<String>[
          rolled(0, 3, const <int>[]),
          'TurnEnded(0,noLegalMove)',
          'TurnBegan(2)',
          'SixesQueued(2,2)',
        ]),
        reason: run.trace,
      );
      expect(run.state.queue, equals(<int>[6, 6]), reason: run.trace);
      expect(run.state.banked, equals(zeros), reason: run.trace);
    });

    test('after the lapse the count starts at 1, not at 9', () {
      final run = Run('S4 count after lapse',
          hand(tokens: blocked(), drought: const <int>[9, 0, 0, 0]));
      run.roll(0, 3);
      run.roll(2, 1);
      run.move(2, 0, face: 1);
      final events = run.roll(0, 4);
      expect(events.any((e) => e.startsWith('Rolled(0,4,[0')), isFalse,
          reason: 'no offer on the first roll after a lapse. got $events. '
              '${run.trace}');
      expect(run.state.drought[0], 1, reason: run.trace);
    });

    test('contrast: with blocks off the same position offers', () {
      final run = Run(
        'S4 blocks off',
        hand(
          tokens: blocked(),
          drought: const <int>[9, 0, 0, 0],
          blocks: false,
        ),
      );
      expect(
          run.roll(0, 3),
          equals(<String>[
            rolled(0, 3, const <int>[0, 1, 2, 3])
          ]),
          reason: run.trace);
      expect(run.state.releaseOffered, isTrue, reason: run.trace);
    });
  });

  // -------------------------------------------------------------------------
  group('S5: the banked six at the next turn start (rule 19s)', () {
    test('play: take, then SixesQueued, queue [6], sixes 0, awaitRoll', () {
      final run = Run('S5 queued', newGame(sharedConfig()));
      stuckRounds(run, twoSeats, 9);
      run.roll(0, 4);
      run.move(0, 1);
      final s = run.state;
      expect(s.currentSeat, 2, reason: run.trace);
      expect(s.queue, equals(<int>[6]), reason: run.trace);
      expect(s.sixes, 0, reason: run.trace);
      expect(s.phase, GamePhase.awaitRoll, reason: run.trace);
      expect(s.banked, equals(zeros), reason: run.trace);
    });

    test('hand: a roll of 3 and the banked 6 releases a token, the 3 moves it',
        () {
      final run = Run(
          'S5 six then three', offeredHand(drought: const <int>[0, 0, 0, 0]));
      expectTake(run, twoSeats, 0, 0);
      expect(
        run.roll(2, 3),
        equals(<String>[
          rolled(2, 3, const <int>[0, 1, 2, 3])
        ]),
        reason: 'the banked 6 is in front of the rolled 3: queue [6, 3], the '
            '6 can leave the yard. ${run.trace}',
      );
      expect(run.state.queue, equals(<int>[6, 3]),
          reason: 'banked six first, then the drawn face. ${run.trace}');
      expect(run.state.phase, GamePhase.awaitMove, reason: run.trace);
      expect(
          legalByFace(run.state),
          equals(<int, List<int>>{
            6: <int>[0, 1, 2, 3],
          }),
          reason: 'only the 6 can move while every token is in the yard. '
              '${run.trace}');
      expect(defaultFace(run.state), 6, reason: run.trace);

      expect(run.move(2, 1, face: 6), equals(<String>['Moved(2,1,-1->0)']),
          reason: 'a banked 6 spent owes no extra roll (rule 19s, 12q). '
              '${run.trace}');
      expect(run.state.phase, GamePhase.awaitMove, reason: run.trace);
      expect(run.state.currentSeat, 2, reason: run.trace);
      expect(run.state.queue, equals(<int>[3]), reason: run.trace);
      expect(run.state.drought[2], 0, reason: run.trace);
      expect(
        legalByFace(run.state),
        equals(<int, List<int>>{
          3: <int>[1],
        }),
        reason: run.trace,
      );
      expect(run.move(2, 1, face: 3),
          equals(<String>['Moved(2,1,0->3)', 'TurnBegan(0)']),
          reason: run.trace);
      expect(run.state.tokens[2], equals(<int>[-1, 3, -1, -1]),
          reason: run.trace);
      expect(run.state.queue, isEmpty, reason: run.trace);
    });

    test('hand: the banked 6 can be spent with the default face (no face)', () {
      final run =
          Run('S5 default face', offeredHand(drought: const <int>[0, 0, 0, 0]));
      run.move(0, 0);
      run.roll(2, 2);
      expect(run.move(2, 3), equals(<String>['Moved(2,3,-1->0)']),
          reason: 'default face is the first queued face with a legal token, '
              'the banked 6. ${run.trace}');
    });

    test('hand: two banked sixes at once, both queued, both spent', () {
      final run = Run(
        'S5 two banked',
        offeredHand(banked: const <int>[0, 0, 1, 0]),
      );
      expectTake(run, twoSeats, 0, 0, pre: const <int>[0, 0, 1, 0]);
      expect(run.state.queue, equals(<int>[6, 6]), reason: run.trace);
      expect(
        run.roll(2, 3),
        equals(<String>[
          rolled(2, 3, const <int>[0, 1, 2, 3])
        ]),
        reason: run.trace,
      );
      expect(run.state.queue, equals(<int>[6, 6, 3]), reason: run.trace);
      expect(run.move(2, 0, face: 6), equals(<String>['Moved(2,0,-1->0)']),
          reason: run.trace);
      expect(run.move(2, 1, face: 6), equals(<String>['Moved(2,1,-1->0)']),
          reason: run.trace);
      expect(run.state.queue, equals(<int>[3]), reason: run.trace);
      expect(run.move(2, 0, face: 3),
          equals(<String>['Moved(2,0,0->3)', 'TurnBegan(0)']),
          reason: run.trace);
    });

    test('hand: a banked 6 spent on a token on the track grants no roll', () {
      final run = Run(
        'S5 banked six on track',
        hand(
          tokens: const <int, List<int>>{
            2: <int>[10, -1, -1, -1],
          },
          currentSeat: 2,
          queue: const <int>[6],
        ),
      );
      run.roll(2, 3);
      expect(run.state.queue, equals(<int>[6, 3]), reason: run.trace);
      final events = run.move(2, 0, face: 6);
      expect(events, equals(<String>['Moved(2,0,10->16)']),
          reason: 'no ExtraRoll: the banked 6 was never rolled. got $events. '
              '${run.trace}');
      expect(run.state.sixes, 0, reason: run.trace);
      expect(run.state.phase, GamePhase.awaitMove, reason: run.trace);
      expect(run.move(2, 0, face: 3),
          equals(<String>['Moved(2,0,16->19)', 'TurnBegan(0)']),
          reason: run.trace);
    });

    test('hand: a banked 6 is not counted towards three 6s', () {
      final run = Run(
        'S5 banked six and two rolled sixes',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[10, -1, -1, -1],
          },
          queue: const <int>[6],
        ),
      );
      expect(run.roll(0, 6),
          equals(<String>[rolled(0, 6, const <int>[]), 'ExtraRoll(0)']),
          reason: run.trace);
      expect(run.state.sixes, 1, reason: run.trace);
      expect(run.roll(0, 6),
          equals(<String>[rolled(0, 6, const <int>[]), 'ExtraRoll(0)']),
          reason: 'banked 6 plus two rolled 6s is not three 6s. ${run.trace}');
      expect(run.state.sixes, 2, reason: run.trace);
      expect(run.state.queue, equals(<int>[6, 6, 6]), reason: run.trace);
      expect(
          run.roll(0, 2),
          equals(<String>[
            rolled(0, 2, const <int>[0, 1, 2, 3])
          ]),
          reason: run.trace);
      expect(run.state.queue, equals(<int>[6, 6, 6, 2]), reason: run.trace);
    });

    test('hand: the third rolled 6 voids the turn and the banked 6 with it',
        () {
      final run = Run(
        'S5 banked six voided',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[10, -1, -1, -1],
          },
          queue: const <int>[6],
        ),
      );
      run.roll(0, 6);
      run.roll(0, 6);
      expect(
        run.roll(0, 6),
        equals(<String>[
          rolled(0, 6, const <int>[]),
          'TurnEnded(0,threeSixes)',
          'TurnBegan(2)',
        ]),
        reason: run.trace,
      );
      expect(run.state.queue, isEmpty, reason: run.trace);
      expect(run.state.banked, equals(zeros), reason: run.trace);
      expect(run.state.sixes, 0, reason: run.trace);
    });

    test('hand: a banked 6 with no legal move is lost on the pass', () {
      // Seat 0 holds a block on seat 2's entry square, so the banked 6 cannot
      // bring a token out, and a 3 has no token to move.
      final run = Run(
        'S5 banked six lost',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[26, 26, -1, -1],
          },
          currentSeat: 2,
          queue: const <int>[6],
        ),
      );
      expect(
        run.roll(2, 3),
        equals(<String>[
          rolled(2, 3, const <int>[]),
          'TurnEnded(2,noLegalMove)',
          'TurnBegan(0)',
        ]),
        reason: 'nothing can move, the turn passes with the banked 6 '
            'unspent. ${run.trace}',
      );
      expect(run.state.queue, isEmpty,
          reason: 'the unspent banked 6 is discarded (rule 19s). ${run.trace}');
      expect(run.state.banked, equals(zeros), reason: run.trace);
      expect(run.state.currentSeat, 0, reason: run.trace);
    });
  });

  // -------------------------------------------------------------------------
  group('S6 (hand): the next-seat sequence at every place (13.6)', () {
    // Seat 2 is owed one banked six; every way seat 0's turn can end must
    // end with TurnBegan(2), SixesQueued(2,1) and the six at the queue front.
    void expectQueued(Run run, List<String> events, List<String> head) {
      expect(
          events, equals(<String>[...head, 'TurnBegan(2)', 'SixesQueued(2,1)']),
          reason: 'got $events. ${run.trace}');
      expect(run.state.queue, equals(<int>[6]), reason: run.trace);
      expect(run.state.banked, equals(zeros), reason: run.trace);
      expect(run.state.currentSeat, 2, reason: run.trace);
      expect(run.state.phase, GamePhase.awaitRoll, reason: run.trace);
      expect(run.state.sixes, 0, reason: run.trace);
    }

    const owed = <int>[0, 0, 1, 0];

    test('a pass on no legal move', () {
      final run = Run(
        'S6 pass',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[57, -1, -1, -1],
          },
          banked: owed,
        ),
      );
      expectQueued(run, run.roll(0, 3), <String>[
        rolled(0, 3, const <int>[]),
        'TurnEnded(0,noLegalMove)',
      ]);
    });

    test('three 6s', () {
      final run = Run(
        'S6 three sixes',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[57, -1, -1, -1],
          },
          banked: owed,
        ),
      );
      run.roll(0, 6);
      run.roll(0, 6);
      expectQueued(run, run.roll(0, 6), <String>[
        rolled(0, 6, const <int>[]),
        'TurnEnded(0,threeSixes)',
      ]);
    });

    test('a spent queue', () {
      final run = Run(
        'S6 spent queue',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[10, -1, -1, -1],
          },
          banked: owed,
        ),
      );
      run.roll(0, 2);
      expectQueued(run, run.move(0, 0, face: 2), <String>['Moved(0,0,10->12)']);
    });

    test('a queue left with no legal face', () {
      // Seat 2 holds a block on seat 0's entry square. Seat 0 queues a 6 and
      // a 2: the 6 cannot leave the yard, the 2 takes the token at 55 home,
      // and the leftover 6 has no move.
      final run = Run(
        'S6 leftover face',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[55, -1, -1, -1],
            2: <int>[26, 26, -1, -1],
          },
          banked: owed,
        ),
      );
      run.roll(0, 6);
      run.roll(0, 2);
      expect(run.state.queue, equals(<int>[6, 2]), reason: run.trace);
      expectQueued(run, run.move(0, 0, face: 2), <String>[
        'Moved(0,0,55->57)',
        'TokenHome(0,0)',
        'TurnEnded(0,noLegalMove)',
      ]);
    });

    test('a retirement of the seat to act (playOut)', () {
      final run = Run(
        'S6 retirement',
        hand(
          seats: threeSeats,
          banked: const <int>[0, 1, 0, 0],
          playOut: true,
        ),
      );
      expect(
        run.play(const RetireIntention(0)),
        equals(<String>['SeatRetired(0)', 'TurnBegan(1)', 'SixesQueued(1,1)']),
        reason: run.trace,
      );
      expect(run.state.queue, equals(<int>[6]), reason: run.trace);
      expect(run.state.banked, equals(zeros), reason: run.trace);
      expect(run.state.currentSeat, 1, reason: run.trace);
      expect(run.state.phase, GamePhase.awaitRoll, reason: run.trace);
    });

    test('a seat that finishes (playOut): banked six of the next playing seat',
        () {
      final run = Run(
        'S6 finishing move',
        hand(
          seats: threeSeats,
          tokens: const <int, List<int>>{
            0: <int>[57, 57, 57, 55],
          },
          banked: const <int>[0, 1, 0, 0],
          playOut: true,
        ),
      );
      run.roll(0, 2);
      expect(
        run.move(0, 3, face: 2),
        equals(<String>[
          'Moved(0,3,55->57)',
          'TokenHome(0,3)',
          'SeatFinished(0,1)',
          'TurnBegan(1)',
          'SixesQueued(1,1)',
        ]),
        reason: run.trace,
      );
      expect(run.state.queue, equals(<int>[6]), reason: run.trace);
    });

    test('a finished seat in between is skipped and never queued', () {
      // Seat 1 has finished. Seat 0 passes: the next playing seat is 2.
      final run = Run(
        'S6 skip finished seat',
        hand(
          seats: threeSeats,
          tokens: const <int, List<int>>{
            0: <int>[57, -1, -1, -1],
            1: <int>[57, 57, 57, 57],
          },
          banked: const <int>[0, 0, 1, 0],
          playOut: true,
          placings: const <int>[1],
        ),
      );
      expectQueued(run, run.roll(0, 4), <String>[
        rolled(0, 4, const <int>[]),
        'TurnEnded(0,noLegalMove)',
      ]);
    });

    test('a game that ends in the step emits none of it', () {
      final run = Run(
        'S6 win',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[57, 57, 57, 55],
          },
          banked: owed,
        ),
      );
      run.roll(0, 2);
      final events = run.move(0, 3, face: 2);
      expect(events,
          equals(<String>['Moved(0,3,55->57)', 'TokenHome(0,3)', 'GameWon(0)']),
          reason: 'no TurnBegan and no SixesQueued once the game is won. '
              'got $events. ${run.trace}');
      expect(run.state.phase, GamePhase.finished, reason: run.trace);
    });

    test('no banked six, no SixesQueued: the plain sequence is unchanged', () {
      final run = Run(
        'S6 plain pass',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[57, -1, -1, -1],
          },
        ),
      );
      expect(run.roll(0, 3), equals(passEvents(0, 3, 2)), reason: run.trace);
      expect(run.state.queue, isEmpty, reason: run.trace);
    });
  });

  // -------------------------------------------------------------------------
  group('S7: every illegal answer (13.4), the state never changes', () {
    GameState offeredPlay() {
      final run = Run('S7 offered', newGame(sharedConfig()));
      stuckRounds(run, twoSeats, 9);
      run.roll(0, 4);
      return run.state;
    }

    test('a face given during an offer is illegalMove', () {
      final run = Run('S7 face during offer', offeredPlay());
      for (final face in <int>[4, 6, 1, 0, 7, -1]) {
        expect(run.refused(MoveIntention(0, 1, face: face)),
            EngineError.illegalMove,
            reason: 'expected illegalMove for move(token 1, face $face) '
                'during an offer (13.4). Scenario S7: nine stuck rounds then '
                'seat 0 rolls 4. seed 1');
      }
    });

    test('a token that does not exist is noSuchToken', () {
      final run = Run('S7 bad token', offeredPlay());
      expect(run.refused(const MoveIntention(0, 4)), EngineError.noSuchToken,
          reason: 'token 4');
      expect(run.refused(const MoveIntention(0, -1)), EngineError.noSuchToken,
          reason: 'token -1');
    });

    test('hand: a token that is not in the yard is illegalMove', () {
      final run = Run(
        'S7 wrong token',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[10, -1, -1, -1],
          },
          phase: 'awaitMove',
          queue: const <int>[3],
          releaseOwed: true,
          releaseOffered: true,
        ),
      );
      expect(legalTokens(run.state), equals(<int>[1, 2, 3]), reason: run.trace);
      expect(run.refused(const MoveIntention(0, 0)), EngineError.illegalMove,
          reason: 'token 0 is on the track. ${run.trace}');
      expect(run.refused(const MoveIntention(0, 0, face: 3)),
          EngineError.illegalMove,
          reason: run.trace);
      expect(run.move(0, 2), contains('YardReleased(0)'), reason: run.trace);
    });

    test('a roll during an offer is wrongPhase', () {
      final run = Run('S7 roll during offer', offeredPlay());
      expect(run.refused(const RollIntention(0, 3)), EngineError.wrongPhase);
    });

    test('the wrong seat answering: take or decline is notYourTurn', () {
      final run = Run('S7 wrong seat', offeredPlay());
      expect(run.refused(const MoveIntention(2, 0)), EngineError.notYourTurn);
      expect(run.refused(const DeclineIntention(2)), EngineError.notYourTurn);
    });

    test('a seat not in the game answering is seatNotInPlay', () {
      final run = Run('S7 stranger', offeredPlay());
      expect(run.refused(const DeclineIntention(1)), EngineError.seatNotInPlay);
      expect(run.refused(const DeclineIntention(3)), EngineError.seatNotInPlay);
      expect(run.refused(const MoveIntention(1, 0)), EngineError.seatNotInPlay);
    });

    test('decline with no offer: awaitRoll is wrongPhase', () {
      final run = Run('S7 decline in awaitRoll', newGame(sharedConfig()));
      expect(run.refused(const DeclineIntention(0)), EngineError.wrongPhase);
    });

    test('decline with no offer: an ordinary awaitMove is wrongPhase', () {
      final run = Run(
        'S7 decline in awaitMove',
        hand(
          tokens: const <int, List<int>>{
            0: <int>[10, -1, -1, -1],
          },
          phase: 'awaitMove',
          queue: const <int>[3],
        ),
      );
      expect(run.refused(const DeclineIntention(0)), EngineError.wrongPhase);
    });

    test('decline by the wrong seat out of phase: notYourTurn first', () {
      final run = Run('S7 wrong seat, no offer', newGame(sharedConfig()));
      expect(run.refused(const DeclineIntention(2)), EngineError.notYourTurn,
          reason: 'the seat check comes before the phase check, as for a '
              'MoveIntention');
    });

    test('decline against a finished game is gameFinished', () {
      final run = Run(
        'S7 finished',
        GameState.fromJson(
          handJson(
            phase: 'finished',
            tokens: const <int, List<int>>{
              0: <int>[57, 57, 57, 57],
            },
            winner: 0,
          ),
        ),
      );
      expect(run.refused(const DeclineIntention(0)), EngineError.gameFinished);
      expect(run.refused(const DeclineIntention(1)), EngineError.gameFinished,
          reason: 'gameFinished is the first check');
    });

    test('replays: an answer repeated after it was accepted is refused', () {
      final take = Run('S7 replay take', offeredPlay());
      take.move(0, 1);
      expect(take.refused(const MoveIntention(0, 1)), EngineError.notYourTurn,
          reason: 'seat 0 taking twice. ${take.trace}');
      expect(take.refused(const DeclineIntention(0)), EngineError.notYourTurn,
          reason: 'seat 0 declining after taking. ${take.trace}');
      expect(take.refused(const DeclineIntention(2)), EngineError.wrongPhase,
          reason: 'seat 2 has the turn but no offer. ${take.trace}');

      final dec = Run('S7 replay decline', offeredPlay());
      dec.decline(0);
      expect(dec.refused(const DeclineIntention(0)), EngineError.notYourTurn,
          reason: 'seat 0 declining twice. ${dec.trace}');
      expect(dec.refused(const MoveIntention(0, 1)), EngineError.notYourTurn,
          reason: 'seat 0 taking after declining. ${dec.trace}');
    });

    test('a refusal leaves the state, its JSON and its hash untouched', () {
      final s = offeredPlay();
      final hash = stateHash(s);
      final json = jsonEncode(s.toJson());
      for (final i in <Intention>[
        const MoveIntention(0, 1, face: 4),
        const MoveIntention(0, 9),
        const MoveIntention(2, 0),
        const DeclineIntention(2),
        const RollIntention(0, 3),
      ]) {
        expect(apply(s, i), isA<Rejected>(), reason: renderIntention(i));
      }
      expect(stateHash(s), hash);
      expect(jsonEncode(s.toJson()), json);
    });

    test('sharedRelease off: a decline is wrongPhase, in every state', () {
      // yardRelease and rollQueue only.
      final cfg = GameConfig(
        seats: twoSeats,
        rules: const RulesConfig(rollQueue: true, yardRelease: true),
        seed: 1,
      );
      final run = Run('S7 off, yardRelease only', newGame(cfg));
      expect(run.refused(const DeclineIntention(0)), EngineError.wrongPhase,
          reason: 'awaitRoll');
      stuckRounds(run, twoSeats, 9);
      run.roll(0, 4);
      expect(run.state.releaseOwed, isTrue, reason: run.trace);
      expect(run.state.releaseOffered, isFalse, reason: run.trace);
      expect(run.refused(const DeclineIntention(0)), EngineError.wrongPhase,
          reason: 'a plain yardRelease owed release cannot be declined. '
              '${run.trace}');
    });

    test('sharedRelease off, no rollQueue: a decline is wrongPhase', () {
      final run =
          Run('S7 legacy', newGame(GameConfig(seats: twoSeats, seed: 1)));
      expect(run.refused(const DeclineIntention(0)), EngineError.wrongPhase,
          reason: 'awaitRoll');
      run.roll(0, 6);
      expect(run.refused(const DeclineIntention(0)), EngineError.wrongPhase,
          reason: 'awaitMove');
    });
  });

  // -------------------------------------------------------------------------
  group('S8: newGame configuration (13.1)', () {
    test('sharedRelease without yardRelease is an ArgumentError', () {
      for (final seats in <List<int>>[twoSeats, threeSeats, fourSeats]) {
        expect(
          () => newGame(GameConfig(
            seats: seats,
            rules: const RulesConfig(rollQueue: true, sharedRelease: true),
            seed: 1,
          )),
          throwsArgumentError,
          reason: 'sharedRelease + rollQueue, no yardRelease, seats $seats',
        );
        expect(
          () => newGame(GameConfig(
            seats: seats,
            rules: const RulesConfig(sharedRelease: true),
            seed: 1,
          )),
          throwsArgumentError,
          reason: 'sharedRelease alone, seats $seats',
        );
        expect(
          () => newGame(GameConfig(
            seats: seats,
            rules: const RulesConfig(yardRelease: false, sharedRelease: true),
            seed: 1,
          )),
          throwsArgumentError,
        );
      }
    });

    test('sharedRelease with yardRelease and rollQueue starts clean', () {
      for (final seats in <List<int>>[twoSeats, threeSeats, fourSeats]) {
        final s = newGame(sharedConfig(seats: seats));
        expect(s.banked, equals(zeros), reason: 'seats $seats');
        expect(s.releaseOffered, isFalse);
        expect(s.releaseOwed, isFalse);
        expect(s.drought, equals(zeros));
        expect(s.queue, isEmpty);
        expect(s.config.rules.sharedRelease, isTrue);
        expect(s.phase, GamePhase.awaitRoll);
      }
    });

    test('RulesConfig: sharedRelease defaults off and takes part in equality',
        () {
      expect(const RulesConfig().sharedRelease, isFalse);
      const on =
          RulesConfig(rollQueue: true, yardRelease: true, sharedRelease: true);
      const off = RulesConfig(rollQueue: true, yardRelease: true);
      expect(on, isNot(off));
      expect(
          on,
          equals(const RulesConfig(
              rollQueue: true, yardRelease: true, sharedRelease: true)));
      expect(
          on.hashCode,
          const RulesConfig(
                  rollQueue: true, yardRelease: true, sharedRelease: true)
              .hashCode);
    });

    test('off: banked stays [0,0,0,0] and releaseOffered false', () {
      final cfg = GameConfig(
        seats: twoSeats,
        rules: const RulesConfig(rollQueue: true, yardRelease: true),
        seed: 1,
      );
      final run = Run('S8 off', newGame(cfg));
      expect(run.state.banked, equals(zeros));
      stuckRounds(run, twoSeats, 9);
      // The old behaviour: Rolled then YardReleased, nothing about banking.
      expect(
          run.roll(0, 4),
          equals(<String>[
            rolled(0, 4, const <int>[0, 1, 2, 3]),
            'YardReleased(0)'
          ]),
          reason: run.trace);
      expect(run.state.releaseOffered, isFalse, reason: run.trace);
      expect(run.move(0, 1), equals(<String>['Moved(0,1,-1->0)']),
          reason: run.trace);
      expect(run.move(0, 1, face: 4),
          equals(<String>['Moved(0,1,0->4)', 'TurnBegan(2)']),
          reason: run.trace);
      expect(run.state.banked, equals(zeros), reason: run.trace);
      expect(run.state.queue, isEmpty, reason: run.trace);
    });
  });

  // -------------------------------------------------------------------------
  group('S9: determinism', () {
    List<Intention> script() {
      final out = <Intention>[];
      for (var r = 1; r <= 9; r++) {
        out
          ..add(RollIntention(0, face5(r)))
          ..add(RollIntention(2, face5(r + 2)));
      }
      out
        ..add(const RollIntention(0, 3)) // offer to seat 0
        ..add(const DeclineIntention(0))
        ..add(const RollIntention(2, 4)) // offer to seat 2
        ..add(const MoveIntention(2, 3)) // take
        ..add(const RollIntention(0, 6)) // seat 0 holds a banked 6 as well
        ..add(const RollIntention(0, 2))
        ..add(const MoveIntention(0, 1, face: 6))
        ..add(const MoveIntention(0, 1, face: 6))
        ..add(const MoveIntention(0, 1, face: 2));
      return out;
    }

    List<String> hashes(List<Intention> intentions, {GameState? from}) {
      var state = from ?? newGame(sharedConfig(seed: 99));
      final out = <String>[];
      for (final i in intentions) {
        final r = apply(state, i);
        if (r is! Applied) {
          fail('scenario S9 script: ${renderIntention(i)} rejected with $r '
              '(seed 99)');
        }
        state = r.state;
        out.add(stateHash(state));
      }
      return out;
    }

    test('the script plays through and holds a decline, a take, a banked 6',
        () {
      var state = newGame(sharedConfig(seed: 99));
      var declines = 0;
      var banks = 0;
      var queued = 0;
      for (final i in script()) {
        final r = apply(state, i);
        expect(r, isA<Applied>(),
            reason: 'scenario S9 script, seed 99: ${renderIntention(i)}');
        final applied = r as Applied;
        declines += applied.events.whereType<ReleaseDeclined>().length;
        banks += applied.events.whereType<SixesBanked>().length;
        queued += applied.events.whereType<SixesQueued>().length;
        state = applied.state;
      }
      expect([declines, banks, queued], equals(<int>[1, 1, 1]),
          reason: 'scenario S9 script, seed 99');
    });

    test('the same intention list twice gives the same hash at every step', () {
      final a = hashes(script());
      final b = hashes(script());
      expect(a, equals(b), reason: 'scenario S9 script, seed 99');
      expect(a.toSet().length, greaterThan(20), reason: 'seed 99');
    });

    test('a snapshot through JSON at any cut replays to the same end', () {
      final intentions = script();
      final whole = hashes(intentions);
      for (var cut = 1; cut < intentions.length; cut++) {
        var state = newGame(sharedConfig(seed: 99));
        for (final i in intentions.take(cut)) {
          state = (apply(state, i) as Applied).state;
        }
        final restored = GameState.fromJson(
          jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
        );
        expect(restored, equals(state),
            reason: 'snapshot after $cut intentions of the S9 script, '
                'seed 99');
        final tail = hashes(intentions.skip(cut).toList(), from: restored);
        expect(tail, equals(whole.skip(cut).toList()),
            reason: 'scenario S9 script, seed 99, snapshot after $cut');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Random games against an oracle written from rules 16s to 19s.
  // -------------------------------------------------------------------------

  group('S10: random games against an oracle of rules 16s-19s', () {
    var offers = 0;
    var takes = 0;
    var declines = 0;
    var queuedTurns = 0;

    for (var seed = 1; seed <= 60; seed++) {
      test('seed $seed', () {
        final result = _playRandom(seed);
        offers += result.offers;
        takes += result.takes;
        declines += result.declines;
        queuedTurns += result.queued;
        final again = _playRandom(seed);
        expect(again.hashes, equals(result.hashes),
            reason: 'seed $seed: the same game replayed gave different '
                'hashes (rule 36)');
      });
    }

    test('the random games exercised offers, takes, declines, banked sixes',
        () {
      expect(offers, greaterThan(20), reason: 'offers seen: $offers');
      expect(takes, greaterThan(5), reason: 'takes seen: $takes');
      expect(declines, greaterThan(5), reason: 'declines seen: $declines');
      expect(queuedTurns, greaterThan(5),
          reason: 'banked-six turns seen: $queuedTurns');
    });
  });

  // -------------------------------------------------------------------------
  group('S11: sharedRelease off leaves the corpus byte-identical', () {
    test('every corpus record replays to its recorded hash with no new keys',
        () {
      final file = File('test/golden/corpus.jsonl');
      if (!file.existsSync()) {
        fail('golden corpus not found at ${file.absolute.path}');
      }
      var checked = 0;
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) {
          continue;
        }
        final record = jsonDecode(line) as Map<String, Object?>;
        final rules = record['rules']! as Map<String, Object?>;
        if (rules['sharedRelease'] == true || rules['yardRelease'] == true) {
          continue;
        }
        final name = record['name']! as String;
        final rollQueue = rules['rollQueue'] == true;
        var state = newGame(GameConfig(
          seats: (record['seats']! as List<Object?>).cast<int>(),
          rules: RulesConfig(
            blocks: rules['blocks']! as bool,
            captureBonus: rules['captureBonus']! as bool,
            rollQueue: rollQueue,
            homeBonus: rules['homeBonus'] == true,
          ),
          seed: record['seed']! as int,
        ));
        final intentions = record['intentions']! as List<Object?>;
        for (var i = 0; i < intentions.length; i++) {
          final raw = intentions[i]! as Map<String, Object?>;
          final Intention intention = raw['t'] == 'roll'
              ? RollIntention(raw['seat']! as int, raw['face']! as int)
              : MoveIntention(raw['seat']! as int, raw['token']! as int,
                  face: raw['face'] as int?);
          final result = apply(state, intention);
          if (result is! Applied) {
            fail('corpus record "$name" intention $i ($raw) rejected: $result');
          }
          state = result.state;
          expect(state.banked, equals(zeros),
              reason: 'record "$name", after intention $i');
          expect(state.releaseOffered, isFalse,
              reason: 'record "$name", after intention $i');
          final text = jsonEncode(state.toJson());
          for (final key in <String>[
            'sharedRelease',
            'banked',
            'releaseOffered'
          ]) {
            expect(text.contains('"$key"'), isFalse,
                reason: 'with sharedRelease off "$key" must be absent. '
                    'record "$name", after intention $i, text: $text');
          }
          for (final e in result.events) {
            expect(e is ReleaseDeclined || e is SixesBanked || e is SixesQueued,
                isFalse,
                reason: 'record "$name", intention $i emitted $e');
          }
        }
        expect(stateHash(state), record['finalHash'],
            reason: 'record "$name": stateHash drifted');
        checked++;
      }
      expect(checked, greaterThan(0));
    });
  });
}

// ---------------------------------------------------------------------------
// The random-game oracle.
// ---------------------------------------------------------------------------

class _RandomResult {
  _RandomResult(
      this.hashes, this.offers, this.takes, this.declines, this.queued);
  final List<String> hashes;
  final int offers;
  final int takes;
  final int declines;
  final int queued;
}

class _Rng {
  _Rng(this._state);
  int _state;
  int next(int bound) {
    final (s, z) = splitMix64Next(_state);
    _state = s;
    return ((z >>> 33) % bound);
  }
}

_RandomResult _playRandom(int seed) {
  final seatSets = <List<int>>[twoSeats, threeSeats, fourSeats];
  final seats = seatSets[seed % 3];
  final rng = _Rng(seed * 7919 + 13);
  var state = newGame(sharedConfig(seats: seats, seed: seed));
  final log = <String>[];
  final hashes = <String>[];
  var offers = 0;
  var takes = 0;
  var declines = 0;
  var queued = 0;

  String why(String msg) => '$msg. seed $seed, seats $seats, intentions: '
      '${log.join('; ')}';

  for (var step = 0; step < 900 && state.phase != GamePhase.finished; step++) {
    final before = state;
    final seat = before.currentSeat;
    final Intention intention;
    if (before.phase == GamePhase.awaitRoll) {
      // Mostly non-6, so that droughts reach ten.
      final face = rng.next(12) == 0 ? 6 : rng.next(5) + 1;
      intention = RollIntention(seat, face);
    } else if (before.releaseOffered) {
      final legal = legalTokens(before);
      intention = rng.next(2) == 0
          ? DeclineIntention(seat)
          : MoveIntention(seat, legal[rng.next(legal.length)]);
    } else {
      final byFace = legalByFace(before);
      final faces = byFace.keys.toList();
      final f = faces[rng.next(faces.length)];
      final toks = byFace[f]!;
      intention = MoveIntention(seat, toks[rng.next(toks.length)], face: f);
    }
    log.add(renderIntention(intention));
    final result = apply(before, intention);
    if (result is! Applied) {
      fail(why('a legal-looking intention was rejected with '
          '${(result as Rejected).error.name}'));
    }
    final s = result.state;
    final events = renderEvents(result.events);
    state = s;
    hashes.add(stateHash(s));

    expect(s.seq, before.seq + 1, reason: why('seq must grow by one'));
    expect(
        GameState.fromJson(
            jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>),
        equals(s),
        reason: why('toJson/fromJson round trip failed'));
    for (var k = 0; k < 4; k++) {
      expect(s.banked[k], inInclusiveRange(0, 3),
          reason: why('banked[$k] = ${s.banked[k]} outside 0..3'));
      expect(s.drought[k], inInclusiveRange(0, 9),
          reason: why('drought[$k] = ${s.drought[k]} outside 0..9'));
      if (!seats.contains(k)) {
        expect(s.banked[k], 0, reason: why('seat $k is not in the game'));
      }
    }
    if (s.phase != GamePhase.finished) {
      expect(s.banked[s.currentSeat], 0,
          reason: why('the seat to act has banked sixes still unqueued'));
    }
    if (s.releaseOffered) {
      expect(s.releaseOwed, isTrue, reason: why('offered without owed'));
      expect(s.phase, GamePhase.awaitMove,
          reason: why('offer outside awaitMove'));
      offers++;
    }

    // Every banked six is created by a take and nowhere else.
    final tookRelease = intention is MoveIntention &&
        before.releaseOffered &&
        intention.face == null;
    final bankedEvents = result.events.whereType<SixesBanked>().toList();
    if (!tookRelease) {
      expect(bankedEvents, isEmpty,
          reason: why('SixesBanked outside a take: $events'));
    }

    if (tookRelease) {
      takes++;
      final mover = intention.seat;
      final grantees = others(seats, mover);
      expect(events.length >= 5, isTrue, reason: why('short take: $events'));
      expect(events[0], 'Moved($mover,${intention.token},-1->0)',
          reason: why('take: first event $events'));
      expect(events[1], 'YardReleased($mover)',
          reason: why('take: second event $events'));
      expect(events[2], 'SixesBanked($grantees)',
          reason: why('take: third event $events'));
      expect(events[3], 'TurnEnded($mover,released)',
          reason: why('take: fourth event $events'));
      expect(s.drought[mover], 0, reason: why('taker drought'));
      expect(events.any((e) => e.startsWith('ExtraRoll')), isFalse,
          reason: why('a take must not owe a roll: $events'));
      expect(s.currentSeat, isNot(mover), reason: why('taker acts again'));
    } else if (intention is DeclineIntention) {
      declines++;
      expect(
          events.take(2).toList(),
          equals(<String>[
            'ReleaseDeclined(${intention.seat})',
            'TurnEnded(${intention.seat},noLegalMove)'
          ]),
          reason: why('decline events $events'));
      expect(s.drought[intention.seat], 9, reason: why('decline drought'));
      expect(
          s.banked,
          equals(<int>[
            for (var k = 0; k < 4; k++)
              k == s.currentSeat ? 0 : before.banked[k]
          ]),
          reason: why('a decline must bank nothing'));
    } else if (events.any((e) => e.startsWith('YardReleased'))) {
      fail(why('YardReleased outside a take: $events'));
    }

    // A turn that begins with banked sixes owed queues all of them first.
    final began = result.events.whereType<TurnBegan>().toList();
    if (began.isNotEmpty && s.phase != GamePhase.finished) {
      final n = began.last.seat;
      final owedBefore =
          before.banked[n] + (tookRelease && n != intention.seat ? 1 : 0);
      if (owedBefore > 0) {
        queued++;
        expect(events.last, 'SixesQueued($n,$owedBefore)',
            reason: why('TurnBegan($n) with $owedBefore banked: $events'));
        expect(s.queue.take(owedBefore).toList(),
            equals(List<int>.filled(owedBefore, 6)),
            reason: why('banked sixes not at the queue front'));
        expect(s.phase, GamePhase.awaitRoll, reason: why('phase'));
        expect(s.sixes, 0, reason: why('sixes'));
      } else {
        expect(events.any((e) => e.startsWith('SixesQueued')), isFalse,
            reason: why('SixesQueued with nothing banked: $events'));
      }
    }
  }
  return _RandomResult(hashes, offers, takes, declines, queued);
}

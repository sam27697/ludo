// Order C-674t, first file: the `turn` frame the OTHER sockets get when an away
// seat reconnects on turn (docs/PROTOCOL.md section 26 rule 5) carries the
// section 30 keys of the seat's current turn: `release` and `offer` while an
// offer is pending (rule 2), `banked` for a seat that holds banked sixes in
// await_roll (rule 5), and under 2026-11 neither `offer` nor `banked`.
//
// Real sockets, real WireServer, fake clock, steered dice (no 6 in the first
// rolls). A seat becomes away by being disconnected for a whole turn (section
// 26 rule 2). A failure names its scenario:
//   dart test test/c674_away_turn_frame_test.dart --plain-name "<scenario>"

import 'package:test/test.dart';

import 'support/c672_harness.dart';

/// Seat 2 drops while seat 0 is on turn; seat 0 rolls (roll 1, a pass); seat
/// 2's whole turn runs on the timer (roll 2, a pass); seat 2 is now away.
/// Leaves seat 0 on turn awaiting a roll.
Future<void> makeSeatTwoAway(Table t) async {
  final Fixture fx = t.fx;
  await dropMany(t, <int>[2]);
  final Map<int, List<Frame>> one =
      await t.step(0, 'roll', <String, Object?>{});
  fx.eq(typesOf(noPresence(one[0]!)), <String>['rolled', 'turn_passed', 'turn'],
      'setup: roll 1 is an ordinary pass');
  fx.eq(dataOf(one[0]!.last)['seat'], 2, 'setup: seat 2 is on turn');
  fx.clock.advance(const Duration(milliseconds: 45000 + graceSlackMs));
  fx.server.runTurnExpiryOnce();
  final Map<int, List<Frame>> two = await t.syncAll();
  fx.eq(
      typesOf(two[0]!.where((Frame f) => f['t'] != 'presence').toList()),
      <String>['rolled', 'turn_passed', 'turn'],
      'setup: the timer plays the whole turn of seat 2 (roll 2, a pass)');
  fx.eq(dataOf(two[0]!.last)['seat'], 0, 'setup: seat 0 is on turn again');
}

Future<Frame> pushedTurn(Fixture fx, Table t, String what) async {
  final List<Frame> seen = await flush(fx, t.c(0));
  fx.eq(typesOf(seen), <String>['presence', 'turn'],
      '$what: seat 0 gets presence then turn when away seat 2 reconnects');
  return seen.last;
}

/// A turn frame that passes the turn may carry grace_ms (section 29): the
/// timer never acts inside it, so every expiry here advances past it too.
const int graceSlackMs = 5000;

List<Frame> noPresence(List<Frame> frames) =>
    frames.where((Frame f) => f['t'] != 'presence').toList();

void main() {
  test(
      'A1: 2026-12, away seat with an offer pending reconnects: the pushed '
      'turn carries release true and offer true', () async {
    final Steer steer = Steer.noSix(4);
    await withFixture('A1 away seat, offer pending', (Fixture fx) async {
      final Table t = await openTable(fx, players: 2, seeds: true);
      await startGame(t);
      await makeSeatTwoAway(t);
      final Map<int, List<Frame>> three =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(
          typesOf(noPresence(three[0]!)),
          <String>['rolled', 'turn_passed', 'turn'],
          'setup: roll 3 is an ordinary pass');
      fx.eq(dataOf(three[0]!.last)['deadline_ms'], 10000,
          'setup: seat 2 is away, its segment is 10 000 ms');
      force(t, drought: <int>[0, 0, 9, 0]);
      fx.clock.advance(const Duration(milliseconds: 10000 + graceSlackMs));
      fx.server.runTurnExpiryOnce();
      final List<Frame> offer = await flush(fx, t.c(0));
      final Frame rolled = offer.firstWhere((Frame f) => f['t'] == 'rolled',
          orElse: () => fx.fail('setup: the timer rolled for seat 2',
              expected: 'a rolled frame', actual: typesOf(offer)));
      fx.eq(dataOf(rolled)['offer'], true, 'setup: roll 4 raised an offer');

      await resume(t, 2);
      final Map<String, Object?> turn =
          dataOf(await pushedTurn(fx, t, 'offer pending'));
      fx.eq(turn['seat'], 2, 'pushed turn.seat');
      fx.eq(turn['phase'], 'await_move', 'pushed turn.phase');
      fx.eq(turn['release'], true, 'pushed turn.release');
      fx.eq(turn['offer'], true, 'pushed turn.offer');
      fx.eq(turn['deadline_ms'], 45000, 'pushed turn.deadline_ms restarts');
    }, ruleset: v12, steer: steer);
  });

  test(
      'A2: 2026-12, away seat granted a six reconnects in await_roll: the '
      'pushed turn carries banked 1 and no offer', () async {
    final Steer steer = Steer.noSix(3);
    await withFixture('A2 away seat, banked six', (Fixture fx) async {
      final Table t = await openTable(fx, players: 2, seeds: true);
      await startGame(t);
      await makeSeatTwoAway(t);
      force(t, drought: <int>[9, 0, 0, 0]);
      final Map<int, List<Frame>> offer =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(dataOf(noPresence(offer[0]!).single)['offer'], true,
          'setup: roll 3 raises the offer for seat 0');
      final Map<int, List<Frame>> take =
          await t.step(0, 'move', <String, Object?>{'token': 0});
      fx.eq(
          typesOf(take[0]!.where((Frame f) => f['t'] != 'presence').toList()),
          <String>['moved', 'sixes_granted', 'turn_passed', 'turn'],
          'setup: seat 0 takes the release');
      final Map<String, Object?> opening = dataOf(take[0]!.last);
      fx.eq(opening['banked'], 1, 'setup: the opening turn of seat 2 banks 1');
      fx.eq(opening['deadline_ms'], 10000, 'setup: seat 2 is away');

      await resume(t, 2);
      final Map<String, Object?> turn =
          dataOf(await pushedTurn(fx, t, 'banked six'));
      fx.eq(turn['seat'], 2, 'pushed turn.seat');
      fx.eq(turn['phase'], 'await_roll', 'pushed turn.phase');
      fx.eq(turn['banked'], 1, 'pushed turn.banked');
      fx.eq(turn['queue'], <int>[6], 'pushed turn.queue holds the banked six');
      fx.absent(turn, 'offer', 'the pushed turn of a banked six');
      fx.eq(turn['deadline_ms'], 45000, 'pushed turn.deadline_ms restarts');
    }, ruleset: v12, steer: steer);
  });

  test(
      'A3: 2026-11, away seat with a release owed reconnects: the pushed '
      'turn carries neither offer nor banked', () async {
    final Steer steer = Steer.noSix(4);
    await withFixture('A3 2026-11 away seat', (Fixture fx) async {
      final Table t = await openTable(fx, players: 2, seeds: true);
      await startGame(t);
      await makeSeatTwoAway(t);
      await t.step(0, 'roll', <String, Object?>{});
      force(t, drought: <int>[0, 0, 9, 0]);
      fx.clock.advance(const Duration(milliseconds: 10000 + graceSlackMs));
      fx.server.runTurnExpiryOnce();
      final List<Frame> after = await flush(fx, t.c(0));
      final Frame rolled = after.firstWhere((Frame f) => f['t'] == 'rolled',
          orElse: () => fx.fail('setup: the timer rolled for seat 2',
              expected: 'a rolled frame', actual: typesOf(after)));
      fx.eq(
          dataOf(rolled)['release'], true, 'setup: a 2026-11 release is owed');

      await resume(t, 2);
      final Map<String, Object?> turn =
          dataOf(await pushedTurn(fx, t, '2026-11'));
      fx.eq(turn['seat'], 2, 'pushed turn.seat');
      fx.absent(turn, 'offer', 'a 2026-11 pushed turn');
      fx.absent(turn, 'banked', 'a 2026-11 pushed turn');
    }, ruleset: v11, steer: steer);
  });

  // A seat that merely holds a self-rolled six is not holding a banked six:
  // the pushed turn has its queue and no `banked` key.
  for (final String name in <String>['a', 'b']) {
    test(
        'A4$name: 2026-12, away seat on its own extra roll '
        '${name == 'a' ? '(rolled a 6, queue [6])' : '(6 then a 3 that captured, bonus roll, queue [6])'} '
        'reconnects: the pushed turn has queue and no banked', () async {
      final Steer steer = Steer.noSix(3);
      await withFixture('A4$name away seat, self-rolled six',
          (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await makeSeatTwoAway(t);
        await t.step(0, 'roll', <String, Object?>{});
        force(
          t,
          currentSeat: 2,
          phase: 'awaitRoll',
          queue: <int>[6],
          sixes: 1,
          tokens: name == 'a'
              ? <int, List<int>>{
                  2: <int>[0, -1, -1, -1]
                }
              : <int, List<int>>{
                  2: <int>[13, -1, -1, -1],
                  0: <int>[-1, -1, -1, -1]
                },
        );
        await resume(t, 2);
        final Map<String, Object?> turn =
            dataOf(await pushedTurn(fx, t, 'self-rolled six'));
        fx.eq(turn['seat'], 2, 'pushed turn.seat');
        fx.eq(turn['phase'], 'await_roll', 'pushed turn.phase');
        fx.eq(turn['queue'], <int>[6], 'pushed turn.queue');
        fx.absent(turn, 'banked', 'the pushed turn of a self-rolled six');
      }, ruleset: v12, steer: steer);
    });
  }

  test(
      'A5: 2026-12, banked six, the away seat has since rolled: the pushed '
      'turn mid-turn carries no banked', () async {
    final Steer steer = Steer.noSix(4);
    await withFixture('A5 banked six, seat has rolled', (Fixture fx) async {
      final Table t = await openTable(fx, players: 2, seeds: true);
      await startGame(t);
      await makeSeatTwoAway(t);
      force(t, drought: <int>[9, 0, 0, 0]);
      await t.step(0, 'roll', <String, Object?>{});
      await t.step(0, 'move', <String, Object?>{'token': 0});
      fx.clock.advance(const Duration(milliseconds: 10000 + graceSlackMs));
      fx.server.runTurnExpiryOnce();
      final List<Frame> after = await flush(fx, t.c(0));
      fx.eq(typesOf(after), <String>['rolled'],
          'setup: the timer rolled for away seat 2, whose move is now pending');
      fx.eq(t.room.game!.currentSeat, 2, 'setup: seat 2 holds the turn');
      await resume(t, 2);
      final Map<String, Object?> turn =
          dataOf(await pushedTurn(fx, t, 'banked six already rolled past'));
      fx.eq(turn['seat'], 2, 'pushed turn.seat');
      fx.absent(turn, 'banked', 'the pushed turn once the seat has rolled');
    }, ruleset: v12, steer: steer);
  });
}

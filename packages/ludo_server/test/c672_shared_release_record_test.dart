// Order C-672t, second file: the verify record and the verify page of a
// 2026-12 game (docs/PROTOCOL.md section 30 rule 7, docs/VERIFY.md 1.1).
//
// Real sockets, real WireServer, fake clock, steered dice; the record and the
// page are read over HTTP exactly as a browser would. A failure names its
// scenario: dart test test/c672_shared_release_record_test.dart
//   --plain-name "<scenario>".
//
// The two page lines, from rule 7:
//   taken (en)    No 6 for 10 rolls with every piece at home: one piece comes
//                 out and the turn ends. Everyone else gets a six.
//   declined (en) "... the player kept the piece in the yard."
//   taken (ar)    ما طلع 6 بعشر رميات وكل القطع بالبيت: بتطلع قطعة ويخلص دوره،
//                 وكل واحد تاني بياخد 6.
//   declined (ar) "... فضّل يبقي القطع بالبيت."
// The declined lines are written with an ellipsis in the section. It is read
// here as "the same lead as the taken line", so the declined line is tested
// as that lead and that tail both inside the roll's own row, and the taken
// tail must not appear in a declined roll's row. If the ellipsis means
// something else the master must say so; the reading is reported with the
// run.

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fair_dice/fair_dice.dart' show drawDie, hexEncode;
import 'package:test/test.dart';

import 'support/c672_harness.dart';

const String enLead = 'No 6 for 10 rolls with every piece at home:';
const String enTaken =
    'No 6 for 10 rolls with every piece at home: one piece comes out and the '
    'turn ends. Everyone else gets a six.';
const String enTakenTail =
    'one piece comes out and the turn ends. Everyone else gets a six.';
const String enDeclinedTail = 'the player kept the piece in the yard.';
const String arLead = 'ما طلع 6 بعشر رميات وكل القطع بالبيت:';
const String arTaken =
    'ما طلع 6 بعشر رميات وكل القطع بالبيت: بتطلع قطعة ويخلص دوره، وكل واحد '
    'تاني بياخد 6.';
const String arTakenTail = 'بتطلع قطعة ويخلص دوره، وكل واحد تاني بياخد 6.';
const String arDeclinedTail = 'فضّل يبقي القطع بالبيت.';
const String oldEn =
    'No 6 for 10 rolls with every piece at home: one piece comes out (rule 11r)';

Future<Map<String, String>> pages(Table t) async {
  final Map<String, String> out = <String, String>{};
  for (final String lang in <String>['en', 'ar']) {
    final Map<String, Object?> res =
        await httpGet(t.fx, '/v/${t.gameId}?lang=$lang');
    t.fx.eq(res['status'], 200, 'the $lang page');
    out[lang] = res['body']! as String;
  }
  return out;
}

/// The part of [body] that belongs to roll [k]: from the open table row that
/// holds its reveal to the start of the next roll's row (or the table end).
String rowOf(Table t, String body, List<Object?> rolls, int k) {
  final String reveal =
      (rolls[k - 1]! as Map<String, Object?>)['reveal']! as String;
  final int start = openRowStart(body, reveal);
  t.fx.ok(start >= 0, 'the page lists roll $k in a table row');
  int end = body.indexOf('</table>', start);
  if (k < rolls.length) {
    final String next =
        (rolls[k]! as Map<String, Object?>)['reveal']! as String;
    final int nextStart = openRowStart(body, next);
    if (nextStart > start) {
      end = nextStart;
    }
  }
  return body.substring(start, end);
}

/// Roll [k] of [rec] verifies alone: its die is drawn from its own reveal,
/// and the reveal hashes k times to the published commitment.
void verifyAlone(Table t, Map<String, Object?> rec, int k) {
  final List<Object?> rolls = rec['rolls']! as List<Object?>;
  final Map<String, Object?> roll = rolls[k - 1]! as Map<String, Object?>;
  final String reveal = roll['reveal']! as String;
  t.fx.eq(
      drawDie(reveal, rec['game_id']! as String, rec['client_seeds']! as String,
          k, 0),
      roll['die'],
      'roll $k: the die is the fair draw of its own reveal');
  List<int> link = <int>[
    for (int i = 0; i < reveal.length; i += 2)
      int.parse(reveal.substring(i, i + 2), radix: 16)
  ];
  for (int i = 0; i < k; i++) {
    link = sha256.convert(link).bytes;
  }
  t.fx.eq(hexEncode(link), rec['chain_commit'],
      'roll $k: the reveal hashes $k times to chain_commit');
}

/// Ends a two-seat game by a finishing move of [seat] and returns the record.
Future<Map<String, Object?>> finishAndRecord(Table t, int seat) async {
  forceFinishingMove(t, seat);
  final Map<int, List<Frame>> end =
      await t.step(seat, 'move', <String, Object?>{'token': 3});
  t.fx.ok(
      end.values
          .any((List<Frame> f) => f.any((Frame x) => x['t'] == 'game_over')),
      'setup: the finishing move ends the game',
      typesOf(end[seat]!));
  return recordOf(t);
}

void main() {
  group('the record keys', () {
    test(
        'K1: a taken release at roll 19: ruleset, releases [19], declined '
        '[], grants [{k: 19, seats: [2]}]; every roll still verifies alone',
        () async {
      final Steer steer = Steer.noSix(19);
      await withFixture('K1 record of a take', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await playToOffer(t);
        await t.step(0, 'move', <String, Object?>{'token': 0});
        final Map<String, Object?> rec = await finishAndRecord(t, 2);
        fx.eq(rec['ruleset'], v12, 'record.ruleset');
        fx.eq(rec['releases'], <int>[19], 'record.releases');
        fx.eq(rec['declined'], <int>[], 'record.declined');
        fx.eq(
            rec['grants'],
            <Object?>[
              <String, Object?>{
                'k': 19,
                'seats': <int>[2]
              }
            ],
            'record.grants');
        fx.eq(rec['format'], 1, 'record.format');
        final List<Object?> rolls = rec['rolls']! as List<Object?>;
        fx.eq(rolls.length, 19,
            'one entry per fair draw: the banked six and the take add none');
        for (final int k in <int>[1, 10, 18, 19]) {
          verifyAlone(t, rec, k);
        }
        fx.eq(
            (rolls.last! as Map<String, Object?>).keys.toList()..sort(),
            <String>['die', 'k', 'reveal', 'seat'],
            'a roll entry keeps its four keys');
      }, ruleset: v12, steer: steer);
    });

    test(
        'K2: a declined release at roll 19: releases [19], declined [19], '
        'grants []', () async {
      final Steer steer = Steer.noSix(19);
      await withFixture('K2 record of a decline', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await playToOffer(t);
        await t.step(0, 'decline_release', <String, Object?>{});
        final Map<String, Object?> rec = await finishAndRecord(t, 2);
        fx.eq(rec['releases'], <int>[19], 'record.releases');
        fx.eq(rec['declined'], <int>[19], 'record.declined');
        fx.eq(rec['grants'], <Object?>[], 'record.grants');
        verifyAlone(t, rec, 19);
      }, ruleset: v12, steer: steer);
    });

    test('K3: a lapse is in releases and in neither declined nor grants',
        () async {
      final Steer steer = Steer.faces(<int>[4]);
      await withFixture('K3 record of a lapse', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        force(
          t,
          drought: <int>[9, 0, 0, 0],
          blocks: true,
          tokens: <int, List<int>>{
            2: <int>[26, 26, -1, -1],
          },
        );
        await t.step(0, 'roll', <String, Object?>{});
        force(t, blocks: false);
        final Map<String, Object?> rec = await finishAndRecord(t, 2);
        fx.eq(rec['releases'], <int>[1], 'record.releases holds the lapse');
        fx.eq(rec['declined'], <int>[], 'record.declined');
        fx.eq(rec['grants'], <Object?>[], 'record.grants');
      }, ruleset: v12, steer: steer);
    });

    test(
        'K4: a take by the timer is a take: in releases and grants, never '
        'in declined', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('K4 record of a timer take', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        fx.clock.advance(const Duration(seconds: 45));
        fx.server.runTurnExpiryOnce();
        await t.syncAll();
        final Map<String, Object?> rec = await finishAndRecord(t, 2);
        fx.eq(rec['releases'], <int>[1], 'record.releases');
        fx.eq(rec['declined'], <int>[], 'the timer never declines');
        fx.eq(
            rec['grants'],
            <Object?>[
              <String, Object?>{
                'k': 1,
                'seats': <int>[2]
              }
            ],
            'record.grants');
      }, ruleset: v12, steer: steer);
    });

    test(
        'K5: a decline then a take in one game: releases ascending, '
        'declined the first, grants the second', () async {
      final Steer steer = Steer.faces(<int>[3, 4, 5]);
      await withFixture('K5 decline then take', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        await t.step(0, 'decline_release', <String, Object?>{});
        await t.step(2, 'roll', <String, Object?>{});
        final Map<int, List<Frame>> third =
            await t.step(0, 'roll', <String, Object?>{});
        fx.eq(dataOf(third[0]!.single)['offer'], true,
            'setup: roll 3 offers again');
        await t.step(0, 'move', <String, Object?>{'token': 0});
        final Map<String, Object?> rec = await finishAndRecord(t, 2);
        fx.eq(rec['releases'], <int>[1, 3], 'record.releases');
        fx.eq(rec['declined'], <int>[1], 'record.declined');
        fx.eq(
            rec['grants'],
            <Object?>[
              <String, Object?>{
                'k': 3,
                'seats': <int>[2]
              }
            ],
            'record.grants');
        fx.eq((rec['rolls']! as List<Object?>).length, 3, 'three fair draws');
        for (final int k in <int>[1, 2, 3]) {
          verifyAlone(t, rec, k);
        }
      }, ruleset: v12, steer: steer);
    });

    test(
        'K6: three seats: grants lists the seats granted, ascending, for '
        'the roll that was taken', () async {
      final Steer steer = Steer.faces(<int>[3], players: 3);
      await withFixture('K6 record, three seats', (Fixture fx) async {
        final Table t = await openTable(fx, players: 3, seeds: true);
        await startGame(t);
        force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        await t.step(0, 'move', <String, Object?>{'token': 0});
        forceFinishingMove(t, 1);
        await t.step(1, 'move', <String, Object?>{'token': 3});
        forceFinishingMove(t, 2);
        await t.step(2, 'move', <String, Object?>{'token': 3});
        final Map<String, Object?> rec = await recordOf(t);
        fx.eq(
            rec['grants'],
            <Object?>[
              <String, Object?>{
                'k': 1,
                'seats': <int>[1, 2]
              }
            ],
            'record.grants');
        fx.eq(rec['releases'], <int>[1], 'record.releases');
        fx.eq(rec['declined'], <int>[], 'record.declined');
      }, ruleset: v12, steer: steer);
    });

    test(
        'K7: a 2026-12 game with no release has the three keys present and '
        'empty', () async {
      await withFixture('K7 record without a release', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2);
        await startGame(t);
        final Map<String, Object?> rec = await finishAndRecord(t, 0);
        fx.eq(rec['ruleset'], v12, 'record.ruleset');
        fx.eq(rec['releases'], <int>[], 'record.releases');
        fx.eq(rec['declined'], <int>[], 'record.declined');
        fx.eq(rec['grants'], <Object?>[], 'record.grants');
        for (final String lang in <String>['en', 'ar']) {
          final String body =
              (await httpGet(fx, '/v/${t.gameId}?lang=$lang'))['body']!
                  as String;
          for (final String text in <String>[
            enLead,
            enDeclinedTail,
            enTakenTail,
            arLead,
            arDeclinedTail,
            arTakenTail
          ]) {
            fx.ok(!body.contains(text),
                'the $lang page of a game with no release shows no line', text);
          }
        }
      }, ruleset: v12);
    });

    for (final String ruleset in <String>[v11, v10]) {
      test(
          'K8: a $ruleset record has none of declined and grants '
          '(and ${ruleset == v10 ? 'no ruleset or releases either' : 'the 2026-11 keys as before'})',
          () async {
        await withFixture('K8 $ruleset record', (Fixture fx) async {
          final Table t = await openTable(fx, players: 2);
          await startGame(t);
          final Map<String, Object?> rec = await finishAndRecord(t, 0);
          fx.absent(rec, 'declined', 'a $ruleset record');
          fx.absent(rec, 'grants', 'a $ruleset record');
          if (ruleset == v11) {
            fx.eq(rec['ruleset'], v11, 'record.ruleset');
            fx.eq(rec['releases'], <int>[], 'record.releases');
          } else {
            fx.absent(rec, 'ruleset', 'a 2026-10 record');
            fx.absent(rec, 'releases', 'a 2026-10 record');
          }
          for (final String lang in <String>['en', 'ar']) {
            final String body =
                (await httpGet(fx, '/v/${t.gameId}?lang=$lang'))['body']!
                    as String;
            for (final String text in <String>[
              enTakenTail,
              enDeclinedTail,
              arTakenTail,
              arDeclinedTail
            ]) {
              fx.ok(
                  !body.contains(text),
                  'the $lang page of a $ruleset game shows no 2026-12 line',
                  text);
            }
          }
        }, ruleset: ruleset);
      });
    }
  });

  group('the page lines', () {
    test(
        'P1: a taken release: its line in both languages, once, in the row '
        'of roll 19 and in no other row', () async {
      final Steer steer = Steer.noSix(19);
      await withFixture('P1 page, taken', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await playToOffer(t);
        await t.step(0, 'move', <String, Object?>{'token': 0});
        final Map<String, Object?> rec = await finishAndRecord(t, 2);
        final List<Object?> rolls = rec['rolls']! as List<Object?>;
        final Map<String, String> p = await pages(t);
        final Map<String, List<String>> expected = <String, List<String>>{
          'en': <String>[enTaken, enDeclinedTail],
          'ar': <String>[arTaken, arDeclinedTail],
        };
        for (final String lang in <String>['en', 'ar']) {
          final String body = p[lang]!;
          final String taken = expected[lang]![0];
          fx.eq(RegExp(RegExp.escape(taken)).allMatches(body).length, 1,
              'the $lang page shows the taken line once');
          fx.ok(!body.contains(expected[lang]![1]),
              'the $lang page shows no declined line for a take');
          fx.ok(rowOf(t, body, rolls, 19).contains(taken),
              'the $lang taken line sits in the row of roll 19');
          for (final int k in <int>[1, 2, 18]) {
            fx.ok(!rowOf(t, body, rolls, k).contains(taken.substring(0, 20)),
                'the $lang taken line is not in the row of roll $k');
          }
        }
      }, ruleset: v12, steer: steer);
    });

    test(
        'P2: a declined release: the declined line in both languages in the '
        'row of roll 19, and not the taken tail', () async {
      final Steer steer = Steer.noSix(19);
      await withFixture('P2 page, declined', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        await playToOffer(t);
        await t.step(0, 'decline_release', <String, Object?>{});
        final Map<String, Object?> rec = await finishAndRecord(t, 2);
        final List<Object?> rolls = rec['rolls']! as List<Object?>;
        final Map<String, String> p = await pages(t);
        final Map<String, List<String>> lines = <String, List<String>>{
          'en': <String>[enLead, enDeclinedTail, enTakenTail],
          'ar': <String>[arLead, arDeclinedTail, arTakenTail],
        };
        for (final String lang in <String>['en', 'ar']) {
          final String row = rowOf(t, p[lang]!, rolls, 19);
          fx.ok(row.contains(lines[lang]![0]),
              'the $lang row of roll 19 carries the lead of the line');
          fx.ok(
              row.contains(lines[lang]![1]),
              'the $lang row of roll 19 says the player kept the piece in '
              'the yard');
          fx.ok(!p[lang]!.contains(lines[lang]![2]),
              'the $lang page does not say everyone else gets a six');
          fx.eq(
              RegExp(RegExp.escape(lines[lang]![1]))
                  .allMatches(p[lang]!)
                  .length,
              1,
              'the $lang declined line appears once');
        }
      }, ruleset: v12, steer: steer);
    });

    test(
        'P3: a decline at roll 1 and a take at roll 3: each line sits with '
        'its own roll and not with the roll between', () async {
      final Steer steer = Steer.faces(<int>[3, 4, 5]);
      await withFixture('P3 page, decline then take', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        await t.step(0, 'decline_release', <String, Object?>{});
        await t.step(2, 'roll', <String, Object?>{});
        await t.step(0, 'roll', <String, Object?>{});
        await t.step(0, 'move', <String, Object?>{'token': 0});
        final Map<String, Object?> rec = await finishAndRecord(t, 2);
        final List<Object?> rolls = rec['rolls']! as List<Object?>;
        final Map<String, String> p = await pages(t);
        final Map<String, List<String>> lines = <String, List<String>>{
          'en': <String>[enDeclinedTail, enTaken],
          'ar': <String>[arDeclinedTail, arTaken],
        };
        for (final String lang in <String>['en', 'ar']) {
          final String declinedTail = lines[lang]![0];
          final String taken = lines[lang]![1];
          fx.ok(rowOf(t, p[lang]!, rolls, 1).contains(declinedTail),
              'the $lang declined line is with roll 1');
          fx.ok(!rowOf(t, p[lang]!, rolls, 1).contains(taken),
              'the $lang taken line is not with roll 1');
          final String two = rowOf(t, p[lang]!, rolls, 2);
          fx.ok(!two.contains(declinedTail) && !two.contains(taken),
              'no line with roll 2, an ordinary pass');
          fx.ok(rowOf(t, p[lang]!, rolls, 3).contains(taken),
              'the $lang taken line is with roll 3');
          fx.ok(!rowOf(t, p[lang]!, rolls, 3).contains(declinedTail),
              'the $lang declined line is not with roll 3');
        }
      }, ruleset: v12, steer: steer);
    });

    test(
        'P4: a 2026-11 page keeps its own line and shows neither 2026-12 '
        'line', () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('P4 2026-11 page', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        await t.step(0, 'move', <String, Object?>{'token': 0});
        await finishAndRecord(t, 2);
        final Map<String, String> p = await pages(t);
        fx.eq(RegExp(RegExp.escape(oldEn)).allMatches(p['en']!).length, 1,
            'the 2026-11 line, once');
        for (final String text in <String>[
          enTakenTail,
          enDeclinedTail,
          arTakenTail,
          arDeclinedTail
        ]) {
          fx.ok(!p['en']!.contains(text) && !p['ar']!.contains(text),
              'no 2026-12 line on a 2026-11 page', text);
        }
      }, ruleset: v11, steer: steer);
    });

    test('P5: the json of a declined game carries all four 2026-12 keys',
        () async {
      final Steer steer = Steer.faces(<int>[3]);
      await withFixture('P5 embedded record', (Fixture fx) async {
        final Table t = await openTable(fx, players: 2, seeds: true);
        await startGame(t);
        force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        await t.step(0, 'decline_release', <String, Object?>{});
        await finishAndRecord(t, 2);
        final String json =
            (await httpGet(fx, '/v/${t.gameId}.json'))['body']! as String;
        final Map<String, Object?> rec =
            jsonDecode(json) as Map<String, Object?>;
        fx.eq(<bool>[
          rec.containsKey('ruleset'),
          rec.containsKey('releases'),
          rec.containsKey('declined'),
          rec.containsKey('grants')
        ], <bool>[
          true,
          true,
          true,
          true
        ], 'the four 2026-12 keys');
      }, ruleset: v12, steer: steer);
    });
  });
}

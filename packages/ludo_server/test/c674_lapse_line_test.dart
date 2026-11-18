// Order C-674t, second file: the lapse in the verify record and on the verify
// page (docs/PROTOCOL.md section 30 rule 7). A lapse (an offer that found no
// piece to release) is in `releases` and in `lapsed`, and its roll's row shows
// the lapse line in en and ar, never the taken or declined text. An offer
// whose seat leaves before answering is in `releases` only and shows no line.
//
// Real sockets, real WireServer, fake clock, steered dice. A failure names its
// scenario: dart test test/c674_lapse_line_test.dart --plain-name "<scenario>"

import 'dart:convert';

import 'package:test/test.dart';

import 'support/c672_harness.dart';

const String enLapse =
    'No 6 for 10 rolls with every piece at home, but no piece could come out: '
    'the turn passes.';
const String arLapse =
    'ما طلع 6 بعشر رميات وكل القطع بالبيت، بس ما قدرت تطلع ولا قطعة: الدور '
    'بيعدّي.';
const String enTakenTail =
    'one piece comes out and the turn ends. Everyone else gets a six.';
const String enDeclinedTail = 'the player kept the piece in the yard.';
const String arTakenTail = 'بتطلع قطعة ويخلص دوره، وكل واحد تاني بياخد 6.';
const String arDeclinedTail = 'فضّل يبقي القطع بالبيت.';
const String enLead = 'No 6 for 10 rolls with every piece at home';
const String arLead = 'ما طلع 6 بعشر رميات وكل القطع بالبيت';

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

int count(String body, String needle) =>
    RegExp(RegExp.escape(needle)).allMatches(body).length;

void main() {
  test(
      'LP1: a lapse is in releases and lapsed, not in declined or grants, '
      'and its row shows the lapse line in en and ar and nothing else',
      () async {
    final Steer steer = Steer.faces(<int>[4]);
    await withFixture('LP1 lapse record and page', (Fixture fx) async {
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
      final Map<int, List<Frame>> r =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(typesOf(r[0]!), <String>['rolled', 'turn_passed', 'turn'],
          'setup: roll 1 is a lapse');
      fx.eq(dataOf(r[0]!.first)['release'], true, 'setup: rolled.release');
      forceFinishingMove(t, 2);
      await t.step(2, 'move', <String, Object?>{'token': 3});
      final Map<String, Object?> rec = await recordOf(t);
      fx.eq(rec['releases'], <int>[1], 'record.releases holds the lapse');
      fx.eq(rec['lapsed'], <int>[1], 'record.lapsed holds the lapse');
      fx.eq(rec['declined'], <int>[], 'record.declined');
      fx.eq(rec['grants'], <Object?>[], 'record.grants');
      final List<Object?> rolls = rec['rolls']! as List<Object?>;
      final Map<String, String> p = await pages(t);
      final Map<String, String> lapse = <String, String>{
        'en': enLapse,
        'ar': arLapse,
      };
      for (final String lang in <String>['en', 'ar']) {
        final String body = p[lang]!;
        fx.eq(count(body, lapse[lang]!), 1,
            'the $lang page shows the lapse line once');
        fx.ok(rowOf(t, body, rolls, 1).contains(lapse[lang]!),
            'the $lang lapse line sits in the row of roll 1');
        for (final String other in <String>[
          enTakenTail,
          enDeclinedTail,
          arTakenTail,
          arDeclinedTail,
        ]) {
          fx.ok(
              !body.contains(other),
              'the $lang page of a lapse shows no taken or declined text',
              other);
        }
      }
    }, ruleset: v12, steer: steer);
  });

  test(
      'LP2: a lapse and a taken release in one game: each line in its own '
      'row, the record lists both in releases and only the lapse in lapsed',
      () async {
    final Steer steer = Steer.faces(<int>[4, 3]);
    await withFixture('LP2 lapse then take', (Fixture fx) async {
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
      // Lift the block and give seat 0 a fresh drought: roll 2 is an offer.
      force(
        t,
        currentSeat: 0,
        phase: 'awaitRoll',
        queue: <int>[],
        drought: <int>[9, 0, 0, 0],
        tokens: <int, List<int>>{
          2: <int>[-1, -1, -1, -1],
        },
      );
      final Map<int, List<Frame>> offer =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(dataOf(offer[0]!.single)['offer'], true,
          'setup: roll 2 raises an offer');
      await t.step(0, 'move', <String, Object?>{'token': 0});
      forceFinishingMove(t, 2);
      await t.step(2, 'move', <String, Object?>{'token': 3});
      final Map<String, Object?> rec = await recordOf(t);
      fx.eq(rec['releases'], <int>[1, 2], 'record.releases');
      fx.eq(rec['lapsed'], <int>[1], 'record.lapsed is the lapse only');
      final List<Object?> rolls = rec['rolls']! as List<Object?>;
      final Map<String, String> p = await pages(t);
      final String enRow1 = rowOf(t, p['en']!, rolls, 1);
      final String enRow2 = rowOf(t, p['en']!, rolls, 2);
      fx.ok(enRow1.contains(enLapse), 'roll 1 row carries the lapse line');
      fx.ok(!enRow1.contains(enTakenTail), 'roll 1 row carries no taken text');
      fx.ok(enRow2.contains(enTakenTail), 'roll 2 row carries the taken line');
      fx.ok(!enRow2.contains(enLapse), 'roll 2 row carries no lapse line');
    }, ruleset: v12, steer: steer);
  });

  test(
      'LP3: an offer whose seat leaves before answering is in releases only '
      'and shows no line on either page', () async {
    final Steer steer = Steer.faces(<int>[3], players: 3);
    await withFixture('LP3 offer unanswered, seat left', (Fixture fx) async {
      final Table t = await openTable(fx, players: 3, seeds: true);
      await startGame(t);
      force(t, drought: <int>[9, 0, 0, 0]);
      final Map<int, List<Frame>> offer =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(dataOf(offer[0]!.single)['offer'], true,
          'setup: roll 1 raises an offer for seat 0');
      await t.step(0, 'leave_room', <String, Object?>{});
      t.seats[0]!.up = false;
      bool over = false;
      for (final int seat in <int>[1, 2]) {
        if (over) {
          break;
        }
        forceFinishingMove(t, seat);
        final Map<int, List<Frame>> end =
            await t.step(seat, 'move', <String, Object?>{'token': 3});
        over = end.values
            .any((List<Frame> f) => f.any((Frame x) => x['t'] == 'game_over'));
      }
      fx.ok(over, 'setup: the game ended so its record is stored');
      final Map<String, Object?> rec = await recordOf(t);
      fx.eq(rec['releases'], <int>[1], 'record.releases holds the offer');
      fx.eq(rec['lapsed'], <int>[], 'record.lapsed: it was not a lapse');
      fx.eq(rec['declined'], <int>[], 'record.declined');
      fx.eq(rec['grants'], <Object?>[], 'record.grants');
      final Map<String, String> p = await pages(t);
      for (final String lang in <String>['en', 'ar']) {
        fx.eq(count(p[lang]!, lang == 'en' ? enLead : arLead), 0,
            'the $lang page shows no line for an unanswered offer');
      }
    }, ruleset: v12, steer: steer);
  });

  test('LP4: a 2026-11 record has no lapsed key', () async {
    final Steer steer = Steer.faces(<int>[4]);
    await withFixture('LP4 2026-11 record', (Fixture fx) async {
      final Table t = await openTable(fx, players: 2, seeds: true);
      await startGame(t);
      await t.step(0, 'roll', <String, Object?>{});
      forceFinishingMove(t, 2);
      await t.step(2, 'move', <String, Object?>{'token': 3});
      final String json =
          (await httpGet(fx, '/v/${t.gameId}.json'))['body']! as String;
      final Map<String, Object?> rec = jsonDecode(json) as Map<String, Object?>;
      fx.absent(rec, 'lapsed', 'a 2026-11 record');
    }, ruleset: v11, steer: steer);
  });
}

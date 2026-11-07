// Proof of the recorded real-games fixture, orders 575 and 583t.
//
// `packages/ludo_client/integration_test/fixtures/real_games.json` holds
// complete games of two, three or four players recorded off a real server
// socket. The store captures are rebuilt from it, so every frame in it has to
// be one the real server produces. The checks live in
// `support/real_games_check.dart` as one pure function over the decoded JSON;
// this file loads the real file, asserts the function finds nothing wrong
// with it, and then proves the function is not vacuous by corrupting a copy
// eight ways (and a few more) and asserting each corruption is reported
// against the frame it touched. The four-seat game has its own group of
// corruptions, because the seats a check names there are 0..3, not 0 and 2.
//
// Runs from `packages/ludo_server` or from the repository root
// (`dart test packages/ludo_server/test/real_games_fixture_test.dart`, the
// way bin/ludo-verify.sh and CI run the server tests): the fixture path is
// anchored on the package root, never on the working directory.
//
// The fixture is read-only here. A missing or unreadable file is a failure,
// never a skip.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'support/real_games_check.dart';

typedef Json = Map<String, Object?>;

/// The absolute path of this package's root directory (the one holding
/// `lib/` and `pubspec.yaml`), resolved from the package configuration and
/// not from the working directory. Same method as `_packageRoot` in
/// privacy_route_test.dart and `_oracleUri` in dice_oracle_test.dart: under
/// `dart test` the package config is the same whether the runner was started
/// in `packages/ludo_server` or at the repository root.
Future<String> packageRoot() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:ludo_server/ludo_server.dart'),
  );
  if (libUri == null) {
    fail(
      'could not resolve package:ludo_server/ludo_server.dart to a file URI '
      '(cwd ${Directory.current.path}); cannot locate the fixture',
    );
  }
  // <package root>/lib/ludo_server.dart
  return File.fromUri(libUri).parent.parent.path;
}

/// Loads and decodes the fixture, failing the test run if it cannot. A
/// relative [path] is taken relative to the server package root; an absolute
/// one is used as given.
Future<Json> loadRealGames([String path = realGamesFixturePath]) async {
  final File given = File(path);
  final File file =
      given.isAbsolute ? given : File('${await packageRoot()}/$path');
  final String where =
      'fixture "$path" (resolved ${file.absolute.path}, cwd ${Directory.current.path})';
  if (!file.existsSync()) {
    fail('$where does not exist');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on Object catch (e) {
    fail('$where could not be read as JSON: $e');
  }
  if (decoded is! Map<String, Object?>) {
    fail('$where is not a JSON object');
  }
  return decoded;
}

Json deepCopy(Json j) => jsonDecode(jsonEncode(j)) as Json;

List<Json> gamesOf(Json doc) => (doc['games']! as List<Object?>).cast<Json>();

List<Json> framesOf(Json game, String seat) =>
    ((game['views']! as Json)[seat]! as List<Object?>).cast<Json>();

Json dOf(Json frame) => frame['d']! as Json;

String nameOf(Json game) => game['name']! as String;

int startOf(Json game, String seat) =>
    framesOf(game, seat).indexWhere((Json f) => f['t'] == 'game_started');

/// Which run recorded each game: its own `recorded` object when it has one,
/// else the top-level fields.
String recordedOf(Json doc) => gamesOf(doc)
    .map((Json g) =>
        '${nameOf(g)}=${jsonEncode(g['recorded'] ?? <String, Object?>{
              'server_version': doc['server_version'],
              'recorded_at': doc['recorded_at'],
              'choice_seed': doc['choice_seed'],
            })}')
    .join('; ');

/// The first game of [players] seats in the copy. Fails the test if the copy
/// has none.
Json gameWith(Json doc, int players) => gamesOf(doc).firstWhere(
      (Json g) => g['players'] == players,
      orElse: () {
        fail('the fixture has no $players-seat game to corrupt');
      },
    );

class Hit {
  Hit(this.game, this.index, this.frame);

  final Json game;
  final int index;
  final Json frame;
}

/// First frame of view [seat], after `game_started`, in any game, that
/// satisfies [test]. Fails the test if the copy has none.
Hit findFrame(
  Json doc,
  String seat,
  bool Function(Json game, Json frame) test,
  String what,
) {
  for (final Json g in gamesOf(doc)) {
    final List<Json> frames = framesOf(g, seat);
    for (var i = startOf(g, seat) + 1; i < frames.length; i++) {
      if (test(g, frames[i])) {
        return Hit(g, i, frames[i]);
      }
    }
  }
  fail('the fixture has no $what to corrupt');
}

/// The checker's problems on the untouched file, set once in `setUpAll`.
late List<String> baseline;

/// Asserts that corrupting the copy produced a problem containing [needle]
/// that the untouched file did not produce.
void expectCaught(
  String scenario,
  Json corrupted,
  String needle, {
  List<String> alsoContains = const <String>[],
}) {
  final List<String> before = baseline;
  final List<String> after = checkRealGames(corrupted);
  final List<String> fresh =
      after.where((String p) => !before.contains(p)).toList();
  final List<String> named =
      fresh.where((String p) => p.contains(needle)).toList();
  final String listing = fresh.isEmpty
      ? '(no new problems at all)'
      : fresh.take(12).map((String p) => '  - $p').join('\n');
  expect(
    named,
    isNotEmpty,
    reason: 'scenario: $scenario\n'
        'expected a new problem containing "$needle"\n'
        'the checker reported ${fresh.length} new problem(s):\n$listing\n'
        'reproduce: load $realGamesFixturePath, apply the scenario above, '
        'run checkRealGames',
  );
  for (final String extra in alsoContains) {
    expect(
      named.any((String p) => p.contains(extra)),
      isTrue,
      reason: 'scenario: $scenario\n'
          'a problem named "$needle" but none of them mentions "$extra":\n'
          '${named.map((String p) => '  - $p').join('\n')}',
    );
  }
}

void main() {
  late Json fixture;

  setUpAll(() async {
    fixture = await loadRealGames();
    baseline = checkRealGames(fixture);
  });

  group('the recorded file', () {
    test('has no problems against engine, dice chain and itself', () {
      final List<String> notes = <String>[];
      final List<String> problems = checkRealGames(fixture, info: notes.add);
      // ignore: avoid_print
      print('chain_commit sources:\n  ${notes.join('\n  ')}');
      // ignore: avoid_print
      print('checker problem count on the real file: ${problems.length}');
      expect(
        problems,
        isEmpty,
        reason: '${problems.length} problem(s) in $realGamesFixturePath '
            '(top level: choice_seed ${fixture['choice_seed']}, '
            'server_version ${fixture['server_version']}; per game: '
            '${recordedOf(fixture)}):\n'
            '${problems.map((String p) => '  - $p').join('\n')}',
      );
    });

    test('a missing file is a failure, not a skip', () async {
      await expectLater(
        loadRealGames('../ludo_client/integration_test/fixtures/nope.json'),
        throwsA(isA<TestFailure>()),
      );
    });

    test('a file that is not JSON is a failure, not a skip', () async {
      final Directory dir = Directory.systemTemp.createTempSync('rg575');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File bad = File('${dir.path}/bad.json')
        ..writeAsStringSync('{"games": [');
      await expectLater(loadRealGames(bad.path), throwsA(isA<TestFailure>()));
    });
  });

  group('the checker is not vacuous', () {
    test('input that is not a fixture is reported, not crashed on', () {
      expect(checkRealGames(null), isNotEmpty);
      expect(checkRealGames(<String, Object?>{}), isNotEmpty);
      expect(
        checkRealGames(<String, Object?>{
          'format': 1,
          'games': <Object?>[<String, Object?>{}],
        }),
        isNotEmpty,
      );
    });

    test('a game with no coverage of the required kinds says so', () {
      final Json copy = deepCopy(fixture);
      final List<Object?> games = copy['games']! as List<Object?>;
      games.removeWhere((Object? g) => (g! as Json)['winner'] == 2);
      expectCaught(
        'remove every game whose winner is seat 2',
        copy,
        'coverage: no game won by the guest',
      );
    });

    test('the four-seat game cannot stand in for a missing two-seat game', () {
      final Json copy = deepCopy(fixture);
      final List<Object?> games = copy['games']! as List<Object?>;
      games.removeWhere((Object? g) => (g! as Json)['players'] == 2);
      expect(games, isNotEmpty, reason: 'the fixture has no game of 3+ seats');
      final List<String> problems = checkRealGames(copy);
      for (final String needle in const <String>[
        'coverage: no game won by the host (seat 0)',
        'coverage: no game won by the guest (seat 2)',
        'coverage: no capture made by seat 0',
        'coverage: no capture made by seat 2',
        'coverage: no turn_passed with reason three_sixes',
        'coverage: no turn_passed with reason no_legal_move',
      ]) {
        expect(
          problems,
          contains(needle),
          reason: 'scenario: remove every two-seat game, keep the rest\n'
              'expected "$needle"; the checker said:\n'
              '${problems.map((String p) => '  - $p').join('\n')}\n'
              'reproduce: load $realGamesFixturePath, drop the games with '
              'players 2, run checkRealGames',
        );
      }
    });

    test('a game of four seats with no capture says so', () {
      final Json copy = deepCopy(fixture);
      final Json game = gameWith(copy, 4);
      for (final Json f in framesOf(game, '0')) {
        if (f['t'] == 'moved') {
          dOf(f)['captured'] = <Object?>[];
        }
      }
      expectCaught(
        'game ${nameOf(game)} view 0: every moved.captured emptied',
        copy,
        'game ${nameOf(game)} coverage: no capture in a 4-seat game',
      );
    });

    test('a players count that is not 2, 3 or 4 is reported', () {
      for (final Object? bad in <Object?>[1, 5, 0, '4', 4.0, null]) {
        final Json copy = deepCopy(fixture);
        final Json game = gameWith(copy, 4);
        game['players'] = bad;
        expectCaught(
          'game ${nameOf(game)}: players 4 -> ${jsonEncode(bad)}',
          copy,
          'game ${nameOf(game)} players: is ${jsonEncode(bad)}, want 2, 3 '
              'or 4',
        );
      }
    });
  });

  group('one corruption each is reported against its frame', () {
    test('(a) a rolled.value changed to another face', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
        copy,
        '0',
        (Json g, Json f) =>
            f['t'] == 'rolled' &&
            dOf(f)['seat'] == 2 &&
            (dOf(f)['legal']! as List<Object?>).isNotEmpty,
        'rolled by seat 2 with a legal move',
      );
      final int was = dOf(h.frame)['value']! as int;
      final int now = was % 6 + 1;
      dOf(h.frame)['value'] = now;
      expectCaught(
        '(a) game ${nameOf(h.game)} view 0 frame ${h.index}: '
            'rolled.value $was -> $now',
        copy,
        'game ${nameOf(h.game)} view 0 frame ${h.index} (rolled)',
      );
    });

    test('(b) a captured entry removed from a capturing moved', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
        copy,
        '0',
        (Json g, Json f) =>
            f['t'] == 'moved' &&
            (dOf(f)['captured']! as List<Object?>).isNotEmpty,
        'moved with a capture',
      );
      final Object? removed =
          (dOf(h.frame)['captured']! as List<Object?>).removeLast();
      expectCaught(
        '(b) game ${nameOf(h.game)} view 0 frame ${h.index}: '
            'captured entry ${jsonEncode(removed)} removed',
        copy,
        'game ${nameOf(h.game)} view 0 frame ${h.index} (moved)',
        alsoContains: <String>['captured'],
      );
    });

    test('(c) an extra_roll flipped', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
        copy,
        '0',
        (Json g, Json f) =>
            f['t'] == 'moved' &&
            dOf(f)['seat'] == 0 &&
            dOf(f)['extra_roll'] == false,
        'moved by seat 0 without an extra roll',
      );
      dOf(h.frame)['extra_roll'] = true;
      expectCaught(
        '(c) game ${nameOf(h.game)} view 0 frame ${h.index}: '
            'extra_roll false -> true',
        copy,
        'game ${nameOf(h.game)} view 0 frame ${h.index} (moved)',
        alsoContains: <String>['extra_roll'],
      );
    });

    test('(d) the winner changed', () {
      final Json copy = deepCopy(fixture);
      final Json game =
          gamesOf(copy).firstWhere((Json g) => g['winner'] == 0, orElse: () {
        fail('the fixture has no game won by seat 0 to corrupt');
      });
      game['winner'] = 2;
      expectCaught(
        '(d) game ${nameOf(game)}: winner 0 -> 2',
        copy,
        'game ${nameOf(game)} winner',
      );
    });

    test('(e) two adjacent frames swapped in views["2"]', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
        copy,
        '2',
        (Json g, Json f) {
          final List<Json> frames = framesOf(g, '2');
          final int i = frames.indexOf(f);
          return f['t'] == 'moved' &&
              i + 1 < frames.length &&
              frames[i + 1]['t'] == 'turn';
        },
        'moved followed by a turn in view 2',
      );
      final List<Json> frames = framesOf(h.game, '2');
      final Json first = frames[h.index];
      frames[h.index] = frames[h.index + 1];
      frames[h.index + 1] = first;
      expectCaught(
        '(e) game ${nameOf(h.game)} view 2: frames ${h.index} and '
            '${h.index + 1} swapped',
        copy,
        'game ${nameOf(h.game)} view 2 frame ${h.index} (',
      );
    });

    test('(f) a reveal changed by one hex digit', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
        copy,
        '0',
        (Json g, Json f) => f['t'] == 'rolled' && (dOf(f)['k']! as int) >= 3,
        'rolled with k >= 3',
      );
      final String reveal = dOf(h.frame)['reveal']! as String;
      final String last = reveal[reveal.length - 1];
      final String flipped =
          reveal.substring(0, reveal.length - 1) + (last == '0' ? '1' : '0');
      dOf(h.frame)['reveal'] = flipped;
      expectCaught(
        '(f) game ${nameOf(h.game)} view 0 frame ${h.index}: reveal last '
            'digit $last -> ${flipped[flipped.length - 1]}',
        copy,
        'game ${nameOf(h.game)} view 0 frame ${h.index} (rolled)',
        alsoContains: <String>['reveal'],
      );
    });

    test('(g) a counts number off by one', () {
      final Json copy = deepCopy(fixture);
      final Json game = gamesOf(copy).firstWhere(
        (Json g) => ((g['counts']! as Json)['0']! as Json)['rolls'] is int,
        orElse: () {
          fail('the fixture has no game with counts for seat 0');
        },
      );
      final Json seat0 = (game['counts']! as Json)['0']! as Json;
      final int was = seat0['sixes']! as int;
      seat0['sixes'] = was + 1;
      expectCaught(
        '(g) game ${nameOf(game)} counts seat 0 sixes $was -> ${was + 1}',
        copy,
        'game ${nameOf(game)} counts seat 0 key sixes',
      );
    });

    for (final String kind in const <String>[
      'capture',
      'three_sixes',
      'no_legal_move',
      'dead_face',
    ]) {
      test('(h) an events index moved by one: $kind', () {
        final Json copy = deepCopy(fixture);
        Json? game;
        var n = -1;
        for (final Json g in gamesOf(copy)) {
          final int at = (g['events']! as List<Object?>)
              .indexWhere((Object? e) => (e! as Json)['kind'] == kind);
          if (at >= 0) {
            game = g;
            n = at;
            break;
          }
        }
        if (game == null) {
          fail('the fixture has no $kind event to corrupt');
        }
        final Json vi = ((game['events']! as List<Object?>)[n]!
            as Json)['view_index']! as Json;
        final int was = vi['0']! as int;
        vi['0'] = was + 1;
        expectCaught(
          '(h) game ${nameOf(game)} events[$n] ($kind): view_index["0"] '
              '$was -> ${was + 1}',
          copy,
          'game ${nameOf(game)} events[$n] kind $kind view 0 frame '
              '${was + 1} (',
        );
      });
    }
  });

  group('more states that must be unreachable in a clean recording', () {
    test('a frame missing from views["2"]', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
          copy, '2', (Json g, Json f) => f['t'] == 'moved', 'moved in view 2');
      framesOf(h.game, '2').removeAt(h.index);
      expectCaught(
        'game ${nameOf(h.game)} view 2: frame ${h.index} removed',
        copy,
        'game ${nameOf(h.game)} view 2 frame ${h.index} (',
      );
    });

    test('a replayed frame in views["0"]', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
          copy, '0', (Json g, Json f) => f['t'] == 'turn', 'turn in view 0');
      framesOf(h.game, '0').insert(h.index + 1, deepCopy(h.frame));
      expectCaught(
        'game ${nameOf(h.game)} view 0: frame ${h.index} delivered twice',
        copy,
        'game ${nameOf(h.game)} view 0 frame ${h.index + 1} (turn)',
        alsoContains: <String>['seq'],
      );
    });

    test('a turn_passed reason changed', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
        copy,
        '0',
        (Json g, Json f) =>
            f['t'] == 'turn_passed' && dOf(f)['reason'] == 'no_legal_move',
        'turn_passed for no_legal_move',
      );
      dOf(h.frame)['reason'] = 'three_sixes';
      expectCaught(
        'game ${nameOf(h.game)} view 0 frame ${h.index}: reason '
            'no_legal_move -> three_sixes',
        copy,
        'game ${nameOf(h.game)} view 0 frame ${h.index} (turn_passed)',
        alsoContains: <String>['reason'],
      );
    });

    test('a move by the seat that is not on turn', () {
      final Json copy = deepCopy(fixture);
      final Hit h = findFrame(
          copy, '0', (Json g, Json f) => f['t'] == 'moved', 'moved in view 0');
      final int seat = dOf(h.frame)['seat']! as int;
      dOf(h.frame)['seat'] = seat == 0 ? 2 : 0;
      expectCaught(
        'game ${nameOf(h.game)} view 0 frame ${h.index}: moved.seat $seat '
            '-> ${seat == 0 ? 2 : 0}',
        copy,
        'game ${nameOf(h.game)} view 0 frame ${h.index} (moved)',
      );
    });

    test('final_tokens that disagree with the replay', () {
      final Json copy = deepCopy(fixture);
      final Json game = gamesOf(copy).first;
      final List<Object?> row =
          (game['final_tokens']! as Json)['0']! as List<Object?>;
      row[0] = row[0] == 57 ? 56 : 57;
      expectCaught(
        'game ${nameOf(game)} final_tokens seat 0 token 0 changed',
        copy,
        'game ${nameOf(game)} final_tokens',
      );
    });

    test('a game_over missing from the end of a view', () {
      final Json copy = deepCopy(fixture);
      final Json game = gamesOf(copy).first;
      final List<Json> frames = framesOf(game, '0');
      final int at = frames.lastIndexWhere((Json f) => f['t'] == 'game_over');
      frames.removeAt(at);
      expectCaught(
        'game ${nameOf(game)} view 0: game_over removed',
        copy,
        'game ${nameOf(game)} view 0',
        alsoContains: <String>['game_over'],
      );
    });
  });

  group('the four-seat game, one corruption each', () {
    test('(i) a frame removed from views["3"]', () {
      final Json copy = deepCopy(fixture);
      final Json game = gameWith(copy, 4);
      final List<Json> frames = framesOf(game, '3');
      final int at = frames.indexWhere(
        (Json f) => f['t'] == 'moved',
        startOf(game, '3') + 1,
      );
      expect(at, greaterThan(0), reason: 'no moved in view 3 to remove');
      frames.removeAt(at);
      expectCaught(
        '(i) game ${nameOf(game)} view 3: frame $at removed',
        copy,
        'game ${nameOf(game)} view 3 frame $at (',
      );
    });

    test('(ii) counts["1"].sixes off by one', () {
      final Json copy = deepCopy(fixture);
      final Json game = gameWith(copy, 4);
      final Json seat1 = (game['counts']! as Json)['1']! as Json;
      final int was = seat1['sixes']! as int;
      seat1['sixes'] = was + 1;
      expectCaught(
        '(ii) game ${nameOf(game)} counts seat 1 sixes $was -> ${was + 1}',
        copy,
        'game ${nameOf(game)} counts seat 1 key sixes',
      );
    });

    test('(iii) an events index moved by one in view_index["2"]', () {
      final Json copy = deepCopy(fixture);
      final Json game = gameWith(copy, 4);
      final List<Object?> events = game['events']! as List<Object?>;
      final int n =
          events.indexWhere((Object? e) => (e! as Json)['kind'] == 'capture');
      expect(n, greaterThanOrEqualTo(0), reason: 'no capture event');
      final Json vi = (events[n]! as Json)['view_index']! as Json;
      final int was = vi['2']! as int;
      vi['2'] = was + 1;
      expectCaught(
        '(iii) game ${nameOf(game)} events[$n] (capture): view_index["2"] '
            '$was -> ${was + 1}',
        copy,
        'game ${nameOf(game)} events[$n] kind capture view 2 frame '
            '${was + 1} (',
      );
    });

    test('(iv) players set to 3 with seats left at four', () {
      final Json copy = deepCopy(fixture);
      final Json game = gameWith(copy, 4);
      game['players'] = 3;
      expectCaught(
        '(iv) game ${nameOf(game)}: players 4 -> 3, seats left [0,1,2,3]',
        copy,
        'game ${nameOf(game)} seats: is [0,1,2,3], want [0,1,2]',
      );
      expectCaught(
        '(iv) game ${nameOf(game)}: players 4 -> 3, the lobby room says 4',
        copy,
        'game ${nameOf(game)} view 0 frame',
        alsoContains: <String>['players is 4, want 3'],
      );
      expectCaught(
        '(iv) game ${nameOf(game)}: players 4 -> 3, view 3 is one too many',
        copy,
        'game ${nameOf(game)} view 3: present',
      );
    });

    test('(v) a rolled.value changed in views["0"], caught by the dice chain',
        () {
      final Json copy = deepCopy(fixture);
      final Json game = gameWith(copy, 4);
      final List<Json> frames = framesOf(game, '0');
      final int at = frames.indexWhere(
          (Json f) => f['t'] == 'rolled' && (dOf(f)['k']! as int) >= 5);
      expect(at, greaterThan(0), reason: 'no rolled in view 0');
      final int was = dOf(frames[at])['value']! as int;
      dOf(frames[at])['value'] = was % 6 + 1;
      expectCaught(
        '(v) game ${nameOf(game)} view 0 frame $at: rolled.value $was -> '
            '${was % 6 + 1}',
        copy,
        'game ${nameOf(game)} view 0 frame $at (rolled)',
        alsoContains: <String>['fair_dice derives'],
      );
    });

    test('(vi) recorded.choice_seed made a string', () {
      final Json copy = deepCopy(fixture);
      final Json game = gameWith(copy, 4);
      final Json rec = game['recorded']! as Json;
      rec['choice_seed'] = '${rec['choice_seed']}';
      expectCaught(
        '(vi) game ${nameOf(game)} recorded.choice_seed -> '
            '${jsonEncode(rec['choice_seed'])}',
        copy,
        'game ${nameOf(game)} recorded: choice_seed',
        alsoContains: <String>['want an int'],
      );
    });

    test('(vii) views["1"] deleted', () {
      final Json copy = deepCopy(fixture);
      final Json game = gameWith(copy, 4);
      (game['views']! as Json).remove('1');
      expectCaught(
        '(vii) game ${nameOf(game)}: views["1"] deleted',
        copy,
        'game ${nameOf(game)} view 1: missing or not a list',
      );
    });
  });

  group('the recorded object', () {
    Json four(Json copy) => gameWith(copy, 4);

    test('a well-formed one on a two-seat game adds no problem', () {
      final Json copy = deepCopy(fixture);
      gamesOf(copy).first['recorded'] = <String, Object?>{
        'server_version': 'abc1234',
        'recorded_at': '2026-11-07T05:10:41Z',
        'choice_seed': 7,
      };
      expect(
        checkRealGames(copy).where((String p) => !baseline.contains(p)),
        isEmpty,
        reason:
            'scenario: recorded object added to ${nameOf(gamesOf(copy).first)}',
      );
    });

    final Map<String, void Function(Json rec)> cases =
        <String, void Function(Json rec)>{
      'an extra key': (Json r) => r['note'] = 'x',
      'server_version missing': (Json r) => r.remove('server_version'),
      'recorded_at missing': (Json r) => r.remove('recorded_at'),
      'choice_seed missing': (Json r) => r.remove('choice_seed'),
      'server_version empty': (Json r) => r['server_version'] = '',
      'server_version a number': (Json r) => r['server_version'] = 1234567,
      'recorded_at a date only': (Json r) => r['recorded_at'] = '2026-11-07',
      'recorded_at with no Z': (Json r) =>
          r['recorded_at'] = '2026-11-07T05:10:41',
      'recorded_at with an offset': (Json r) =>
          r['recorded_at'] = '2026-11-07T09:10:41+04:00',
      'recorded_at month 13': (Json r) =>
          r['recorded_at'] = '2026-13-07T05:10:41Z',
      'recorded_at 31st of February': (Json r) =>
          r['recorded_at'] = '2026-02-31T05:10:41Z',
      'recorded_at not text': (Json r) => r['recorded_at'] = 1794028241,
      'choice_seed a double': (Json r) => r['choice_seed'] = 1.5,
      'choice_seed a bool': (Json r) => r['choice_seed'] = true,
      'choice_seed null': (Json r) => r['choice_seed'] = null,
    };
    cases.forEach((String what, void Function(Json rec) corrupt) {
      test('$what is reported', () {
        final Json copy = deepCopy(fixture);
        final Json game = four(copy);
        corrupt(game['recorded']! as Json);
        expectCaught(
          'game ${nameOf(game)} recorded: $what -> '
              '${jsonEncode(game['recorded'])}',
          copy,
          'game ${nameOf(game)} recorded: ',
        );
      });
    });

    test('recorded that is not an object is reported', () {
      for (final Object? bad in <Object?>['1b42602', 3, null, <Object?>[]]) {
        final Json copy = deepCopy(fixture);
        final Json game = four(copy);
        game['recorded'] = bad;
        expectCaught(
          'game ${nameOf(game)} recorded -> ${jsonEncode(bad)}',
          copy,
          'game ${nameOf(game)} recorded: is ${jsonEncode(bad)}, not an '
              'object',
        );
      }
    });
  });
}

// Proof of the recorded real-games fixture, order 575.
//
// `packages/ludo_client/integration_test/fixtures/real_games.json` holds
// complete two-player games recorded off a real server socket. The store
// captures are rebuilt from it, so every frame in it has to be one the real
// server produces. The checks live in `support/real_games_check.dart` as one
// pure function over the decoded JSON; this file loads the real file, asserts
// the function finds nothing wrong with it, and then proves the function is
// not vacuous by corrupting a copy eight ways (and a few more) and asserting
// each corruption is reported against the frame it touched.
//
// Run from `packages/ludo_server`:
//   dart test test/real_games_fixture_test.dart -r expanded
//
// The fixture is read-only here. A missing or unreadable file is a failure,
// never a skip.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/real_games_check.dart';

typedef Json = Map<String, Object?>;

/// Loads and decodes the fixture, failing the test run if it cannot.
Json loadRealGames([String path = realGamesFixturePath]) {
  final File file = File(path);
  final String where =
      'fixture "$path" (resolved ${file.absolute.path}, cwd ${Directory.current.path})';
  if (!file.existsSync()) {
    fail('$where does not exist; run the tests from packages/ludo_server');
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

/// Asserts that corrupting the copy produced a problem containing [needle]
/// that the untouched file did not produce.
void expectCaught(
  String scenario,
  Json corrupted,
  String needle, {
  List<String> alsoContains = const <String>[],
}) {
  final List<String> before = checkRealGames(loadRealGames());
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

  setUpAll(() {
    fixture = loadRealGames();
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
            '(choice_seed ${fixture['choice_seed']}, server_version '
            '${fixture['server_version']}):\n'
            '${problems.map((String p) => '  - $p').join('\n')}',
      );
    });

    test('a missing file is a failure, not a skip', () {
      expect(
        () =>
            loadRealGames('../ludo_client/integration_test/fixtures/nope.json'),
        throwsA(isA<TestFailure>()),
      );
    });

    test('a file that is not JSON is a failure, not a skip', () {
      final Directory dir = Directory.systemTemp.createTempSync('rg575');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File bad = File('${dir.path}/bad.json')
        ..writeAsStringSync('{"games": [');
      expect(() => loadRealGames(bad.path), throwsA(isA<TestFailure>()));
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
}

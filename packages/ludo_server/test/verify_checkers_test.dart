// Tests for docs/VERIFY.md sections 6 and 7, running the real scripts:
// verifyJsSource and verifyPySource (package:ludo_server/ludo_server.dart)
// are written to a temp directory and executed with a real `node` and a
// real `python3`, never mocked. If either interpreter is missing this file
// fails loudly, naming which one -- it never uses `skip:`.
//
// Every vector check below reads packages/fair_dice/test/vectors.json
// itself, located via Isolate.resolvePackageUri rather than a relative
// path, since cwd when this package's own tests run is not that package's
// root.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fair_dice/fair_dice.dart' show DiceChain, drawDie;
import 'package:ludo_server/ludo_server.dart'
    show verifyJsSource, verifyPySource, verifyRecordFormat;
import 'package:test/test.dart';

// ---------------------------------------------------------------------
// Interpreter presence: fail loudly, never skip.
// ---------------------------------------------------------------------

Future<void> _requireInterpreter(String executable) async {
  ProcessResult result;
  try {
    result = await Process.run(executable, <String>['--version']);
  } on ProcessException catch (e) {
    fail(
      'this suite requires "$executable" to be installed and on PATH '
      '(docs/VERIFY.md section 6 runs under Node 20+, section 7 runs '
      'under python3); Process.run(\'$executable\', [\'--version\']) '
      'failed to even start: $e. This test never skips for a missing '
      'interpreter.',
    );
  }
  if (result.exitCode != 0) {
    fail(
      '"$executable --version" exited ${result.exitCode}; this suite '
      'requires a working "$executable" on PATH and never skips for one '
      'that is missing or broken. stdout: ${result.stdout} stderr: '
      '${result.stderr}',
    );
  }
}

// ---------------------------------------------------------------------
// Locating packages/fair_dice/test/vectors.json from this package.
// ---------------------------------------------------------------------

Future<String> _fairDiceVectorsPath() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:fair_dice/fair_dice.dart'),
  );
  if (libUri == null) {
    fail(
      'could not resolve package:fair_dice/fair_dice.dart to a file URI; '
      'cannot locate packages/fair_dice/test/vectors.json',
    );
  }
  final Directory packageRoot = File.fromUri(libUri).parent.parent;
  return '${packageRoot.path}${Platform.pathSeparator}test'
      '${Platform.pathSeparator}vectors.json';
}

// ---------------------------------------------------------------------
// The Node and Python driver scripts this file writes into its own temp
// directory alongside verify.js/verify.py. Each reads a small JSON
// instruction file (a list of drawDie calls, a list of verifyRecord/
// verify_record calls) and prints one JSON object with both results, so a
// single process invocation can answer one specific question this file
// asks, named at the call site.
// ---------------------------------------------------------------------

const String _jsDriverSource = r'''
const fs = require('fs');
const verify = require(process.argv[2]);
const input = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));

(async () => {
  const draws = [];
  for (const d of input.draws) {
    draws.push(await verify.drawDie(d.reveal, d.gameId, d.clientSeeds, d.k, d.d));
  }
  const records = [];
  for (const r of input.records) {
    records.push(await verify.verifyRecord(r));
  }
  process.stdout.write(JSON.stringify({ draws: draws, records: records }));
})().catch((err) => {
  process.stderr.write(String((err && err.stack) || err));
  process.exit(1);
});
''';

const String _pyDriverSource = r'''
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location('verify_module_under_test', sys.argv[1])
verify_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_module)

with open(sys.argv[2]) as f:
    data = json.load(f)

draws = [
    verify_module.draw_die(d['reveal'], d['gameId'], d['clientSeeds'], d['k'], d['d'])
    for d in data['draws']
]
records = []
for r in data['records']:
    ok, lines = verify_module.verify_record(r)
    records.append({'ok': ok, 'lines': lines})

print(json.dumps({'draws': draws, 'records': records}))
''';

int _inputSeq = 0;

Future<Map<String, Object?>> _runJsDriver(
  Directory tempDir,
  File jsFile,
  File jsDriverFile,
  Map<String, Object?> input,
) async {
  final File inputFile = File(
    '${tempDir.path}${Platform.pathSeparator}js_in_${_inputSeq++}.json',
  )..writeAsStringSync(jsonEncode(input));
  final ProcessResult result = await Process.run(
    'node',
    <String>[jsDriverFile.path, jsFile.path, inputFile.path],
  );
  if (result.exitCode != 0) {
    fail(
      'node driver failed (exit ${result.exitCode}) for input '
      '${jsonEncode(input)}\nstdout: ${result.stdout}\nstderr: '
      '${result.stderr}',
    );
  }
  return jsonDecode(result.stdout as String)! as Map<String, Object?>;
}

Future<Map<String, Object?>> _runPyDriver(
  Directory tempDir,
  File pyFile,
  File pyDriverFile,
  Map<String, Object?> input,
) async {
  final File inputFile = File(
    '${tempDir.path}${Platform.pathSeparator}py_in_${_inputSeq++}.json',
  )..writeAsStringSync(jsonEncode(input));
  final ProcessResult result = await Process.run(
    'python3',
    <String>[pyDriverFile.path, pyFile.path, inputFile.path],
  );
  if (result.exitCode != 0) {
    fail(
      'python3 driver failed (exit ${result.exitCode}) for input '
      '${jsonEncode(input)}\nstdout: ${result.stdout}\nstderr: '
      '${result.stderr}',
    );
  }
  return jsonDecode(result.stdout as String)! as Map<String, Object?>;
}

Future<num> _jsDrawDie(
  Directory tempDir,
  File jsFile,
  File jsDriverFile, {
  required String reveal,
  required String gameId,
  required String clientSeeds,
  required int k,
  required int d,
}) async {
  final Map<String, Object?> out = await _runJsDriver(
    tempDir,
    jsFile,
    jsDriverFile,
    <String, Object?>{
      'draws': <Map<String, Object?>>[
        <String, Object?>{
          'reveal': reveal,
          'gameId': gameId,
          'clientSeeds': clientSeeds,
          'k': k,
          'd': d,
        },
      ],
      'records': const <Object?>[],
    },
  );
  return (out['draws']! as List<Object?>).single! as num;
}

Future<num> _pyDrawDie(
  Directory tempDir,
  File pyFile,
  File pyDriverFile, {
  required String reveal,
  required String gameId,
  required String clientSeeds,
  required int k,
  required int d,
}) async {
  final Map<String, Object?> out = await _runPyDriver(
    tempDir,
    pyFile,
    pyDriverFile,
    <String, Object?>{
      'draws': <Map<String, Object?>>[
        <String, Object?>{
          'reveal': reveal,
          'gameId': gameId,
          'clientSeeds': clientSeeds,
          'k': k,
          'd': d,
        },
      ],
      'records': const <Object?>[],
    },
  );
  return (out['draws']! as List<Object?>).single! as num;
}

Future<Map<String, Object?>> _jsVerifyRecord(
  Directory tempDir,
  File jsFile,
  File jsDriverFile,
  Map<String, Object?> record,
) async {
  final Map<String, Object?> out = await _runJsDriver(
    tempDir,
    jsFile,
    jsDriverFile,
    <String, Object?>{
      'draws': const <Object?>[],
      'records': <Map<String, Object?>>[record],
    },
  );
  return (out['records']! as List<Object?>).single! as Map<String, Object?>;
}

Future<Map<String, Object?>> _pyVerifyRecord(
  Directory tempDir,
  File pyFile,
  File pyDriverFile,
  Map<String, Object?> record,
) async {
  final Map<String, Object?> out = await _runPyDriver(
    tempDir,
    pyFile,
    pyDriverFile,
    <String, Object?>{
      'draws': const <Object?>[],
      'records': <Map<String, Object?>>[record],
    },
  );
  return (out['records']! as List<Object?>).single! as Map<String, Object?>;
}

Future<ProcessResult> _runPyCli(
  Directory tempDir,
  File pyFile,
  Map<String, Object?> record,
  String name,
) async {
  final File recordFile = File(
    '${tempDir.path}${Platform.pathSeparator}$name.json',
  )..writeAsStringSync(jsonEncode(record));
  return Process.run('python3', <String>[pyFile.path, recordFile.path]);
}

// ---------------------------------------------------------------------
// The good record and its tampered siblings, in the exact shape of
// docs/VERIFY.md section 1.1.
// ---------------------------------------------------------------------

Map<String, Object?> _deepCopy(Map<String, Object?> record) =>
    jsonDecode(jsonEncode(record))! as Map<String, Object?>;

String _flipLastHexChar(String hex) {
  final String last = hex.substring(hex.length - 1);
  final String replacement = last == '0' ? '1' : '0';
  return '${hex.substring(0, hex.length - 1)}$replacement';
}

const String _goodGameId = 'abcdef0123456789';
const String _goodClientSeeds = '0:alice-checkers-seed|1:srv-seed-000000';

Map<String, Object?> _buildGoodRecord() {
  final List<int> secret = List<int>.generate(32, (int i) => (i * 7 + 3) % 256);
  final DiceChain chain = DiceChain.build(secret);
  final List<Map<String, Object?>> rolls = <Map<String, Object?>>[
    for (int k = 1; k <= 30; k++)
      <String, Object?>{
        'k': k,
        'seat': k.isOdd ? 0 : 1,
        'reveal': chain.reveal(k),
        'die': drawDie(chain.reveal(k), _goodGameId, _goodClientSeeds, k, 0),
      },
  ];
  return <String, Object?>{
    'format': verifyRecordFormat,
    'game_id': _goodGameId,
    'chain_commit': chain.commit,
    'chain_index': 0,
    'chain_length': chain.chainLength,
    'client_seeds': _goodClientSeeds,
    'seeds': <Map<String, Object?>>[
      <String, Object?>{
        'seat': 0,
        'seed': 'alice-checkers-seed',
        'origin': 'player',
      },
      <String, Object?>{
        'seat': 1,
        'seed': 'srv-seed-000000',
        'origin': 'server',
      },
    ],
    'rolls': rolls,
    'winner': 0,
    'finished_at': '2026-01-01T00:00:00Z',
  };
}

Map<String, Object?> _tamperDieChangedByOne(Map<String, Object?> good) {
  final Map<String, Object?> record = _deepCopy(good);
  final List<Object?> rolls = record['rolls']! as List<Object?>;
  final Map<String, Object?> first = rolls.first! as Map<String, Object?>;
  final int die = first['die']! as int;
  first['die'] = die == 6 ? 1 : die + 1;
  return record;
}

/// Tampers the LAST roll's reveal specifically, not an arbitrary middle
/// one: docs/VERIFY.md section 7 rule 4 checks `sha256(reveal_k) ==
/// previous`, where the *next* roll's own check uses `reveal_k` as its
/// "previous". Corrupting a middle roll's reveal would therefore also
/// break the very next roll's chainOk, which is not "exactly that roll's
/// chainOk false" -- the order's own wording for this case. The last roll
/// has no roll after it, so only its own chainOk (and, incidentally, its
/// own dieOk, since the corrupted reveal also draws a different face) is
/// affected.
Map<String, Object?> _tamperLastRevealDigit(Map<String, Object?> good) {
  final Map<String, Object?> record = _deepCopy(good);
  final List<Object?> rolls = record['rolls']! as List<Object?>;
  final Map<String, Object?> last = rolls.last! as Map<String, Object?>;
  last['reveal'] = _flipLastHexChar(last['reveal']! as String);
  return record;
}

Map<String, Object?> _tamperTwoRollsSwapped(Map<String, Object?> good) {
  final Map<String, Object?> record = _deepCopy(good);
  final List<Object?> rolls = record['rolls']! as List<Object?>;
  final Map<String, Object?> rollAtK10 = rolls[9]! as Map<String, Object?>;
  final Map<String, Object?> rollAtK20 = rolls[19]! as Map<String, Object?>;
  final Object? reveal10 = rollAtK10['reveal'];
  final Object? die10 = rollAtK10['die'];
  final Object? seat10 = rollAtK10['seat'];
  rollAtK10['reveal'] = rollAtK20['reveal'];
  rollAtK10['die'] = rollAtK20['die'];
  rollAtK10['seat'] = rollAtK20['seat'];
  rollAtK20['reveal'] = reveal10;
  rollAtK20['die'] = die10;
  rollAtK20['seat'] = seat10;
  return record;
}

Map<String, Object?> _tamperGapAtK5(Map<String, Object?> good) {
  final Map<String, Object?> record = _deepCopy(good);
  final List<Object?> rolls = record['rolls']! as List<Object?>;
  rolls.removeWhere(
    (Object? r) => (r! as Map<String, Object?>)['k'] == 5,
  );
  record['rolls'] = rolls;
  return record;
}

Map<String, Object?> _tamperClientSeedsChanged(Map<String, Object?> good) {
  final Map<String, Object?> record = _deepCopy(good);
  record['client_seeds'] = '${record['client_seeds']}-tampered';
  return record;
}

Map<String, Object?> _tamperChainCommitChanged(Map<String, Object?> good) {
  final Map<String, Object?> record = _deepCopy(good);
  record['chain_commit'] = _flipLastHexChar(record['chain_commit']! as String);
  return record;
}

Map<String, Object?> _tamperFormat(Map<String, Object?> good) {
  final Map<String, Object?> record = _deepCopy(good);
  record['format'] = verifyRecordFormat + 1;
  return record;
}

/// A record whose dice were drawn with a game_id different from the one it
/// states -- proves the checkers actually recompute the die from the
/// record's own stated game_id, rather than trusting the die field.
Map<String, Object?> _buildGameIdMismatchRecord() {
  final List<int> secret =
      List<int>.generate(32, (int i) => (i * 11 + 5) % 256);
  final DiceChain chain = DiceChain.build(secret);
  const String derivedFromGameId = 'aaaaaaaaaaaaaaaa';
  const String statedGameId = 'bbbbbbbbbbbbbbbb';
  const String clientSeeds = '0:mismatch-seed-a|1:mismatch-seed-b';
  final List<Map<String, Object?>> rolls = <Map<String, Object?>>[
    for (int k = 1; k <= 5; k++)
      <String, Object?>{
        'k': k,
        'seat': k.isOdd ? 0 : 1,
        'reveal': chain.reveal(k),
        'die': drawDie(chain.reveal(k), derivedFromGameId, clientSeeds, k, 0),
      },
  ];
  return <String, Object?>{
    'format': verifyRecordFormat,
    'game_id': statedGameId,
    'chain_commit': chain.commit,
    'chain_index': 0,
    'chain_length': chain.chainLength,
    'client_seeds': clientSeeds,
    'seeds': <Map<String, Object?>>[
      <String, Object?>{
        'seat': 0,
        'seed': 'mismatch-seed-a',
        'origin': 'player',
      },
      <String, Object?>{
        'seat': 1,
        'seed': 'mismatch-seed-b',
        'origin': 'player',
      },
    ],
    'rolls': rolls,
    'winner': 0,
    'finished_at': '2026-01-01T00:00:00Z',
  };
}

void main() {
  late Directory tempDir;
  late File jsFile;
  late File pyFile;
  late File jsDriverFile;
  late File pyDriverFile;
  late Map<String, Object?> vectors;

  setUpAll(() async {
    await _requireInterpreter('node');
    await _requireInterpreter('python3');

    tempDir = Directory.systemTemp.createTempSync('verify_checkers_test_');
    jsFile = File('${tempDir.path}${Platform.pathSeparator}verify.js')
      ..writeAsStringSync(verifyJsSource);
    pyFile = File('${tempDir.path}${Platform.pathSeparator}verify.py')
      ..writeAsStringSync(verifyPySource);
    jsDriverFile = File('${tempDir.path}${Platform.pathSeparator}driver.js')
      ..writeAsStringSync(_jsDriverSource);
    pyDriverFile = File('${tempDir.path}${Platform.pathSeparator}driver.py')
      ..writeAsStringSync(_pyDriverSource);

    final String vectorsPath = await _fairDiceVectorsPath();
    vectors = jsonDecode(File(vectorsPath).readAsStringSync())!
        as Map<String, Object?>;
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  group('vectors.json: single-die rolls, both checkers', () {
    late String gameId;
    late String clientSeeds;
    late List<Map<String, Object?>> rolls;

    setUpAll(() {
      gameId = vectors['game_id']! as String;
      clientSeeds = vectors['client_seeds']! as String;
      rolls = (vectors['rolls']! as List<Object?>).cast<Map<String, Object?>>();
    });

    for (final int index in List<int>.generate(6, (int i) => i)) {
      test('rolls[$index]: JS drawDie matches the vector\'s die', () async {
        final Map<String, Object?> vector = rolls[index];
        final num die = await _jsDrawDie(
          tempDir,
          jsFile,
          jsDriverFile,
          reveal: vector['reveal']! as String,
          gameId: gameId,
          clientSeeds: clientSeeds,
          k: vector['k']! as int,
          d: 0,
        );
        expect(die, vector['die']);
      });

      test('rolls[$index]: Python draw_die matches the vector\'s die',
          () async {
        final Map<String, Object?> vector = rolls[index];
        final num die = await _pyDrawDie(
          tempDir,
          pyFile,
          pyDriverFile,
          reveal: vector['reveal']! as String,
          gameId: gameId,
          clientSeeds: clientSeeds,
          k: vector['k']! as int,
          d: 0,
        );
        expect(die, vector['die']);
      });
    }
  });

  group('vectors.json: backgammon_rolls (die index 1 too), both checkers', () {
    late String gameId;
    late String clientSeeds;
    late List<Map<String, Object?>> backgammonRolls;

    setUpAll(() {
      gameId = vectors['game_id']! as String;
      clientSeeds = vectors['client_seeds']! as String;
      backgammonRolls = (vectors['backgammon_rolls']! as List<Object?>)
          .cast<Map<String, Object?>>();
    });

    for (final int index in List<int>.generate(3, (int i) => i)) {
      for (final int dieIndex in const <int>[0, 1]) {
        test(
            'backgammon_rolls[$index], die index $dieIndex: JS drawDie '
            'matches the vector', () async {
          final Map<String, Object?> vector = backgammonRolls[index];
          final List<Object?> dice = vector['dice']! as List<Object?>;
          final num die = await _jsDrawDie(
            tempDir,
            jsFile,
            jsDriverFile,
            reveal: vector['reveal']! as String,
            gameId: gameId,
            clientSeeds: clientSeeds,
            k: vector['k']! as int,
            d: dieIndex,
          );
          expect(die, dice[dieIndex]);
        });

        test(
            'backgammon_rolls[$index], die index $dieIndex: Python '
            'draw_die matches the vector', () async {
          final Map<String, Object?> vector = backgammonRolls[index];
          final List<Object?> dice = vector['dice']! as List<Object?>;
          final num die = await _pyDrawDie(
            tempDir,
            pyFile,
            pyDriverFile,
            reveal: vector['reveal']! as String,
            gameId: gameId,
            clientSeeds: clientSeeds,
            k: vector['k']! as int,
            d: dieIndex,
          );
          expect(die, dice[dieIndex]);
        });
      }
    }
  });

  group('the good record: both checkers pass it in full', () {
    test('JS verifyRecord: ok true, every roll chainOk and dieOk', () async {
      final Map<String, Object?> good = _buildGoodRecord();
      final Map<String, Object?> result =
          await _jsVerifyRecord(tempDir, jsFile, jsDriverFile, good);

      expect(result['ok'], isTrue, reason: 'result: $result');
      final List<Object?> rolls = result['rolls']! as List<Object?>;
      expect(rolls.length, 30);
      for (final Object? rawRoll in rolls) {
        final Map<String, Object?> roll = rawRoll! as Map<String, Object?>;
        expect(roll['chainOk'], isTrue, reason: 'roll: $roll');
        expect(roll['dieOk'], isTrue, reason: 'roll: $roll');
      }
    });

    test(
        'python3 verify.py <file> exits 0 and prints a line starting '
        '"PASS: 30 rolls"', () async {
      final Map<String, Object?> good = _buildGoodRecord();
      final ProcessResult result =
          await _runPyCli(tempDir, pyFile, good, 'good_record');

      expect(result.exitCode, 0,
          reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}');
      final List<String> lines = (result.stdout as String).split('\n');
      expect(
        lines.any((String line) => line.startsWith('PASS: 30 rolls')),
        isTrue,
        reason: 'expected a line starting "PASS: 30 rolls" in stdout: '
            '${result.stdout}',
      );
    });
  });

  group('tampered records: each fails in both checkers', () {
    final Map<String, Object?> good = _buildGoodRecord();
    final Map<String, Map<String, Object?> Function()> tamperers =
        <String, Map<String, Object?> Function()>{
      'a die changed by one': () => _tamperDieChangedByOne(good),
      'the last roll\'s reveal, last hex digit changed': () =>
          _tamperLastRevealDigit(good),
      'two rolls (k=10 and k=20) swapped': () => _tamperTwoRollsSwapped(good),
      'roll k=5 removed (a gap)': () => _tamperGapAtK5(good),
      'client_seeds changed while seeds is not': () =>
          _tamperClientSeedsChanged(good),
      'chain_commit changed': () => _tamperChainCommitChanged(good),
      'format: 2': () => _tamperFormat(good),
    };

    tamperers.forEach((String label, Map<String, Object?> Function() build) {
      test('$label: JS verifyRecord.ok is false', () async {
        final Map<String, Object?> tampered = build();
        final Map<String, Object?> result =
            await _jsVerifyRecord(tempDir, jsFile, jsDriverFile, tampered);
        expect(result['ok'], isFalse, reason: 'result: $result');
      });

      test('$label: python3 verify.py <file> exits 1 with a FAIL: line',
          () async {
        final Map<String, Object?> tampered = build();
        final ProcessResult result = await _runPyCli(
          tempDir,
          pyFile,
          tampered,
          'tampered_${label.hashCode}',
        );
        expect(result.exitCode, 1,
            reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}');
        final List<String> lines = (result.stdout as String).split('\n');
        expect(
          lines.any((String line) => line.startsWith('FAIL:')),
          isTrue,
          reason: 'expected a line starting "FAIL:" in stdout: '
              '${result.stdout}',
        );
      });
    });

    test(
        'the reveal-changed case specifically: JS marks exactly that '
        'roll\'s chainOk false', () async {
      final Map<String, Object?> tampered = _tamperLastRevealDigit(good);
      final Map<String, Object?> result =
          await _jsVerifyRecord(tempDir, jsFile, jsDriverFile, tampered);

      expect(result['ok'], isFalse, reason: 'result: $result');
      final List<Object?> rolls = result['rolls']! as List<Object?>;
      expect(rolls.length, 30);
      for (final Object? rawRoll in rolls) {
        final Map<String, Object?> roll = rawRoll! as Map<String, Object?>;
        final bool isTamperedRoll = roll['k'] == 30;
        expect(
          roll['chainOk'],
          isTamperedRoll ? isFalse : isTrue,
          reason: 'roll k=${roll['k']}: expected chainOk to be false only '
              'for the tampered roll (k=30); roll: $roll',
        );
      }
    });
  });

  test(
      'a record whose dice were drawn with a different game_id than the '
      'one it states fails the die check, in both checkers', () async {
    final Map<String, Object?> mismatched = _buildGameIdMismatchRecord();

    final Map<String, Object?> jsResult =
        await _jsVerifyRecord(tempDir, jsFile, jsDriverFile, mismatched);
    expect(jsResult['ok'], isFalse, reason: 'JS result: $jsResult');
    final List<Object?> jsRolls = jsResult['rolls']! as List<Object?>;
    expect(jsRolls, isNotEmpty);
    expect(
      jsRolls.every(
        (Object? r) => (r! as Map<String, Object?>)['dieOk'] == false,
      ),
      isTrue,
      reason: 'every roll\'s die was drawn under a different game_id than '
          'the one the record states, so every dieOk must be false; JS '
          'result: $jsResult',
    );

    final Map<String, Object?> pyResult =
        await _pyVerifyRecord(tempDir, pyFile, pyDriverFile, mismatched);
    expect(pyResult['ok'], isFalse, reason: 'python3 result: $pyResult');
  });
}

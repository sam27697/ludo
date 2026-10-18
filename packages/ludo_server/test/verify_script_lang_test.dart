// Tests for contract C-396 (work/ludo/orders/C-396-verify-page-arabic.md),
// decision 5: "the script stays language-free". Runs the real
// `verify.js` source (verifyJsSource, package:ludo_server/ludo_server.dart)
// under a real `node`, the way test/verify_checkers_test.dart runs it --
// its interpreter-presence check is copied by hand below (never imported,
// per the order), and this file fails loudly rather than skipping when
// `node` is missing, the same way that file does.
//
// verify_checkers_test.dart drives verify.js by `require`-ing it as a
// CommonJS module, which only ever reaches its `module.exports` branch
// (`if (typeof module !== 'undefined' && module.exports)`). That branch
// never touches the DOM. The DOM-touching branch -- the one this file has
// to drive to test decision 5 -- is the `else` arm, which only runs when
// `module` is not defined in the script's own global scope at all. Under
// plain `node script.js` or `require('./script.js')`, `module` is always
// defined (every Node file is a CommonJS module), so that branch is
// unreachable through either of those. The way around this without
// touching verify_scripts.dart or verify_page.dart: Node's `vm` module
// runs the raw source as a *script* inside a fresh context that holds
// nothing but what this file puts there -- no `module`, so
// `typeof module` reads 'undefined' and the script takes the DOM branch,
// finding only the `document` stub (a tiny `getElementById` over plain
// objects carrying `dataset` and `textContent`, built in `_driverSource`
// below) this file supplies. `crypto.subtle`, `TextEncoder` and
// `Uint8Array` are added to that context explicitly, since none of them
// are language-level globals a fresh V8 context carries on its own.

import 'dart:convert';
import 'dart:io';

import 'package:fair_dice/fair_dice.dart' show DiceChain, drawDie;
import 'package:ludo_server/ludo_server.dart'
    show verifyJsSource, verifyRecordFormat;
import 'package:test/test.dart';

Future<void> _requireInterpreter(String executable) async {
  ProcessResult result;
  try {
    result = await Process.run(executable, <String>['--version']);
  } on ProcessException catch (e) {
    fail(
      'this suite requires "$executable" to be installed and on PATH '
      '(docs/VERIFY.md section 6 runs verify.js under Node 20+); '
      'Process.run(\'$executable\', [\'--version\']) failed to even '
      'start: $e. This test never skips for a missing interpreter.',
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

/// Runs inside plain `node`, outside any vm context: reads `verify.js`'s
/// source and the test's input, builds the `document` stub described
/// above, runs the source with `vm.runInContext` in a context that holds
/// no `module`, and waits for `#summary`'s `textContent` setter to fire
/// (every mutation verify.js's DOM branch makes happens synchronously
/// inside the same `.then` callback, before it touches `#summary`, so
/// that setter firing means every cell is already settled too) before
/// printing the final state of every stubbed element as JSON.
const String _driverSource = r'''
const fs = require('fs');
const vm = require('vm');
const nodeCrypto = require('crypto');

const verifySource = fs.readFileSync(process.argv[2], 'utf8');
const input = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));

const record = input.record;
const ks = record.rolls.map((r) => r.k);

const cells = {};
cells['record'] = { textContent: JSON.stringify(record), dataset: {} };
for (const k of ks) {
  cells['chain-' + k] = { textContent: 'not checked', dataset: {} };
  cells['die-' + k] = { textContent: 'not checked', dataset: {} };
}

let resolveDone;
const done = new Promise((resolve) => { resolveDone = resolve; });

let summaryText = 'not checked';
cells['summary'] = {
  dataset: input.summaryDataset || {},
  get textContent() { return summaryText; },
  set textContent(v) { summaryText = v; resolveDone(); },
};

// Not read by verify.js as it stands on the commit this file targets --
// kept so a future script that does look it up (by whatever id the
// implementation picks) has a stub ready, and so this driver's shape
// does not have to change if that lookup is added.
cells['rolls-table'] = { dataset: input.tableDataset || {}, textContent: '' };

const sandbox = {
  document: {
    getElementById: (id) =>
      Object.prototype.hasOwnProperty.call(cells, id) ? cells[id] : null,
  },
  TextEncoder: TextEncoder,
  Uint8Array: Uint8Array,
  crypto: nodeCrypto.webcrypto,
  console: console,
};
vm.createContext(sandbox);
vm.runInContext(verifySource, sandbox, { filename: 'verify.js' });

const timeout = new Promise((_, reject) => {
  setTimeout(
    () => reject(new Error(
      'timed out waiting for #summary.textContent to be set by ' +
      'verify.js\'s DOM branch -- either the module-exports branch was ' +
      'taken instead (module leaked into the sandbox) or the record ' +
      'never resolved',
    )),
    5000,
  );
});

Promise.race([done, timeout]).then(() => {
  const out = { summaryTextContent: summaryText };
  for (const k of ks) {
    out['chain-' + k] = cells['chain-' + k].textContent;
    out['die-' + k] = cells['die-' + k].textContent;
  }
  process.stdout.write(JSON.stringify(out));
}).catch((err) => {
  process.stderr.write(String((err && err.stack) || err));
  process.exit(1);
});
''';

int _inputSeq = 0;

/// Writes [verifyJsSource] and [_driverSource] into [tempDir] once (via
/// the two files handed in), then runs the driver against [record] with
/// the given data-attribute stand-ins, returning the driver's parsed
/// stdout: `{summaryTextContent, 'chain-<k>': ..., 'die-<k>': ...}` for
/// every k in record.rolls.
Future<Map<String, Object?>> _runDomDriver(
  Directory tempDir,
  File jsFile,
  File driverFile,
  Map<String, Object?> record, {
  Map<String, String>? summaryDataset,
  Map<String, String>? tableDataset,
}) async {
  final File inputFile = File(
    '${tempDir.path}${Platform.pathSeparator}dom_in_${_inputSeq++}.json',
  )..writeAsStringSync(jsonEncode(<String, Object?>{
      'record': record,
      'summaryDataset': summaryDataset ?? const <String, String>{},
      'tableDataset': tableDataset ?? const <String, String>{},
    }));
  final ProcessResult result = await Process.run(
    'node',
    <String>[driverFile.path, jsFile.path, inputFile.path],
  );
  if (result.exitCode != 0) {
    fail(
      'node DOM driver failed (exit ${result.exitCode}) for record '
      '${jsonEncode(record)}\nstdout: ${result.stdout}\nstderr: '
      '${result.stderr}',
    );
  }
  return jsonDecode(result.stdout as String)! as Map<String, Object?>;
}

const String _goodGameId = 'abcdef9876543210';
const String _goodClientSeeds = '0:lang-script-seed-a|1:lang-script-seed-b';

/// A record that verifies in full: every roll's chain link and die both
/// check out, so verifyRecord resolves with `ok: true` and the "all N
/// rolls verified" branch runs.
Map<String, Object?> _buildGoodRecord({int rollCount = 5}) {
  final List<int> secret =
      List<int>.generate(32, (int i) => (i * 13 + 1) % 256);
  final DiceChain chain = DiceChain.build(secret);
  final List<Map<String, Object?>> rolls = <Map<String, Object?>>[
    for (int k = 1; k <= rollCount; k++)
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
        'seed': 'lang-script-seed-a',
        'origin': 'player',
      },
      <String, Object?>{
        'seat': 1,
        'seed': 'lang-script-seed-b',
        'origin': 'server',
      },
    ],
    'rolls': rolls,
    'winner': 0,
    'finished_at': '2026-03-02T00:00:00Z',
  };
}

/// A record whose format fails verifyRecord's very first check, so it
/// resolves with `ok: false, error: 'format', rolls: []` immediately --
/// the simplest way to drive the summary's failure branch with a known,
/// stable `{reason}` ("format") and no per-roll work to wait on.
Map<String, Object?> _buildFormatBrokenRecord() {
  final Map<String, Object?> good = _buildGoodRecord(rollCount: 1);
  return <String, Object?>{...good, 'format': verifyRecordFormat + 1};
}

void main() {
  late Directory tempDir;
  late File jsFile;
  late File driverFile;

  setUpAll(() async {
    await _requireInterpreter('node');
    tempDir = Directory.systemTemp.createTempSync('verify_script_lang_test_');
    jsFile = File('${tempDir.path}${Platform.pathSeparator}verify.js')
      ..writeAsStringSync(verifyJsSource);
    driverFile = File('${tempDir.path}${Platform.pathSeparator}driver.js')
      ..writeAsStringSync(_driverSource);
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  group(
      'decision 5 (data-attribute half): the script reads the words from '
      'data attributes when they are present', () {
    test(
        '#summary[data-ok] with the Arabic string is used, {n} replaced '
        'by the roll count, on a record that verifies in full', () async {
      final Map<String, Object?> good = _buildGoodRecord(rollCount: 5);
      final Map<String, Object?> result = await _runDomDriver(
        tempDir,
        jsFile,
        driverFile,
        good,
        summaryDataset: const <String, String>{
          'ok': 'تم التحقق: كل الرميات ({n}) سليمة',
          'fail': 'تم التحقق: فشل ({reason})',
        },
        tableDataset: const <String, String>{
          'match': 'تم الفحص: مطابق',
          'mismatch': 'تم الفحص: غير مطابق',
        },
      );

      expect(
        result['summaryTextContent'],
        'تم التحقق: كل الرميات (5) سليمة',
        reason: 'decision 5: with #summary[data-ok] set to the Arabic '
            'template, verify.js must write that template with {n} '
            'replaced by the roll count (5), not its own hardcoded '
            'English ("checked: all 5 rolls verified"); this must fail '
            'on ffe63fd, where the script never reads data-ok at all; '
            'full driver result: $result',
      );
    });

    test(
        '#summary[data-fail] with the Arabic string is used, {reason} '
        'replaced, on a record that fails to verify', () async {
      final Map<String, Object?> broken = _buildFormatBrokenRecord();
      final Map<String, Object?> result = await _runDomDriver(
        tempDir,
        jsFile,
        driverFile,
        broken,
        summaryDataset: const <String, String>{
          'ok': 'تم التحقق: كل الرميات ({n}) سليمة',
          'fail': 'تم التحقق: فشل ({reason})',
        },
      );

      expect(
        result['summaryTextContent'],
        'تم التحقق: فشل (format)',
        reason: 'decision 5: with #summary[data-fail] set to the Arabic '
            'template, a record that fails with error "format" must '
            'produce that template with {reason} replaced by "format", '
            'not the script\'s own hardcoded English '
            '("checked: failed (format)"); this must fail on ffe63fd; '
            'full driver result: $result',
      );
    });

    test(
        'rolls table data-match / data-mismatch are used for a verifying '
        'record\'s chain and die cells', () async {
      final Map<String, Object?> good = _buildGoodRecord(rollCount: 3);
      final Map<String, Object?> result = await _runDomDriver(
        tempDir,
        jsFile,
        driverFile,
        good,
        tableDataset: const <String, String>{
          'match': 'تم الفحص: مطابق',
          'mismatch': 'تم الفحص: غير مطابق',
        },
      );

      for (int k = 1; k <= 3; k++) {
        expect(
          result['chain-$k'],
          'تم الفحص: مطابق',
          reason: 'decision 5: roll k=$k\'s chain cell must read its '
              'match text from the rolls table\'s data-match attribute '
              '("تم الفحص: مطابق"), not the script\'s hardcoded English '
              '("checked: matches"); this must fail on ffe63fd, where '
              'the script never reads a table data attribute at all; '
              'full driver result: $result',
        );
        expect(
          result['die-$k'],
          'تم الفحص: مطابق',
          reason: 'decision 5: roll k=$k\'s die cell must likewise read '
              'its match text from data-match; full driver result: '
              '$result',
        );
      }
    });
  });

  group(
      'decision 5 (fallback half): with no data attributes, the script '
      'writes exactly today\'s English', () {
    test(
        'no #summary data attributes: a verifying record gets '
        '"checked: all N rolls verified" and "checked: matches" on every '
        'cell', () async {
      final Map<String, Object?> good = _buildGoodRecord(rollCount: 5);
      final Map<String, Object?> result =
          await _runDomDriver(tempDir, jsFile, driverFile, good);

      expect(
        result['summaryTextContent'],
        'checked: all 5 rolls verified',
        reason: 'decision 5: an old cached page with no data-ok '
            'attribute must still get today\'s exact English summary '
            'for a fully-verifying 5-roll record; full driver result: '
            '$result',
      );
      for (int k = 1; k <= 5; k++) {
        expect(
          result['chain-$k'],
          'checked: matches',
          reason: 'decision 5: roll k=$k\'s chain cell must read '
              '"checked: matches" with no data-match attribute present; '
              'full driver result: $result',
        );
        expect(
          result['die-$k'],
          'checked: matches',
          reason: 'decision 5: roll k=$k\'s die cell must likewise read '
              '"checked: matches"; full driver result: $result',
        );
      }
    });

    test(
        'no #summary data attributes: a record that fails with error '
        '"format" gets "checked: failed (format)"', () async {
      final Map<String, Object?> broken = _buildFormatBrokenRecord();
      final Map<String, Object?> result =
          await _runDomDriver(tempDir, jsFile, driverFile, broken);

      expect(
        result['summaryTextContent'],
        'checked: failed (format)',
        reason: 'decision 5: with no data-fail attribute, a record that '
            'fails with error "format" must get exactly today\'s '
            'English summary "checked: failed (format)"; full driver '
            'result: $result',
      );
    });
  });
}

// Tests for contract C-613 (work/ludo/orders/613-verify-page-says-failed.md),
// decisions D1 to D5: the verify page says a failed check plainly, in the
// page's own language, with a mark and a colour.
//
// The real served script (verifyJsSource) is run under a real `node`, against
// the real buildVerifyPageHtml output, with a minimal DOM built here from that
// HTML: getElementById, textContent, dataset, classList (and className kept in
// step with it). verify_script_lang_test.dart explains why the script has to
// run in a `vm` context with no `module` to reach its DOM branch; the same
// approach is used here, and this file fails loudly rather than skipping when
// `node` is missing.
//
// Nothing here is random: every record is built from a fixed secret, so a
// failure reproduces by running the one test named in its message:
//   cd packages/ludo_server && dart test test/c613_verify_fail_state_test.dart -N '<test name>'
//
// The per-cause attributes D2 puts on #summary have no fixed names in the
// contract, so the tests never name them: they are found by value (the five
// D2 sentences) and, where a page without them is needed, by removing every
// data-* attribute of #summary except data-ok and data-fail.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show pow;

import 'package:crypto/crypto.dart' show sha256;
import 'package:fair_dice/fair_dice.dart' show DiceChain, drawDie;
import 'package:ludo_server/ludo_server.dart'
    show buildVerifyPageHtml, verifyJsSource, verifyRecordFormat;
import 'package:test/test.dart';

const String _tick = '✓';
const String _cross = '✗';

/// Bidi marks and spaces tolerated between a glyph and the words after it.
final RegExp _gap = RegExp('^[\\s\\u200e\\u200f\\u061c\\u2066-\\u2069]+');

// ---------------------------------------------------------------------
// The contract's words, copied from the order, per language.
// ---------------------------------------------------------------------

class _Words {
  const _Words({
    required this.okTemplate,
    required this.failTemplate,
    required this.format,
    required this.clientSeeds,
    required this.rollSequence,
    required this.mismatch,
    required this.error,
    required this.noscript,
    required this.cellMatch,
    required this.cellMismatch,
  });

  final String okTemplate;
  final String failTemplate;
  final String format;
  final String clientSeeds;
  final String rollSequence;
  final String mismatch;
  final String error;
  final String noscript;
  final String cellMatch;
  final String cellMismatch;

  List<String> get sentences =>
      <String>[format, clientSeeds, rollSequence, mismatch, error];

  String fail(String reason) => failTemplate.replaceAll('{reason}', reason);
  String ok(int n) => okTemplate.replaceAll('{n}', '$n');
}

const Map<String, _Words> _words = <String, _Words>{
  'en': _Words(
    okTemplate: 'checked: all {n} rolls verified',
    failTemplate: 'Check failed: {reason}.',
    format: 'this record is in a format this page does not know',
    clientSeeds: 'the players\' seeds in the record disagree with each other',
    rollSequence: 'the rolls in the record are missing or out of order',
    mismatch: 'at least one roll does not match what the server committed to',
    error: 'this browser could not run the check',
    noscript: 'This page checks the rolls with JavaScript, which is off in '
        'this browser. The checks below can also be run with verify.py.',
    cellMatch: 'checked: matches',
    cellMismatch: 'checked: does not match',
  ),
  'ar': _Words(
    okTemplate: 'تم التحقق: كل الرميات ({n}) سليمة',
    failTemplate: 'فشل الفحص: {reason}.',
    format: 'سجل اللعبة بصيغة لا تعرفها هذه الصفحة',
    clientSeeds: 'بذور اللاعبين في السجل لا تتفق مع بعضها',
    rollSequence: 'رميات السجل ناقصة أو بغير ترتيبها',
    mismatch: 'رمية واحدة على الأقل لا تطابق ما ثبّته الخادم',
    error: 'تعذّر على هذا المتصفح إجراء الفحص',
    noscript: 'تفحص هذه الصفحة الرميات بجافاسكربت، وهي معطلة في هذا '
        'المتصفح. يمكن أيضاً تشغيل الفحوص أدناه بـ verify.py.',
    cellMatch: 'تم الفحص: مطابق',
    cellMismatch: 'تم الفحص: غير مطابق',
  ),
};

const List<String> _langs = <String>['en', 'ar'];

/// The old error tokens and the old hard-coded phrase: none may ever reach
/// the reader.
const List<String> _tokens = <String>[
  'client_seeds',
  'roll_sequence',
  'a roll did not match',
  '(format)',
];

// ---------------------------------------------------------------------
// Interpreter presence: fail loudly, never skip.
// ---------------------------------------------------------------------

Future<void> _requireInterpreter(String executable) async {
  ProcessResult result;
  try {
    result = await Process.run(executable, <String>['--version']);
  } on ProcessException catch (e) {
    fail(
      'this suite requires "$executable" to be installed and on PATH; '
      'Process.run(\'$executable\', [\'--version\']) failed to even start: '
      '$e. This test never skips for a missing interpreter.',
    );
  }
  if (result.exitCode != 0) {
    fail(
      '"$executable --version" exited ${result.exitCode}; this suite '
      'requires a working "$executable" on PATH. stdout: ${result.stdout} '
      'stderr: ${result.stderr}',
    );
  }
}

// ---------------------------------------------------------------------
// Fixtures: records in the shape of docs/VERIFY.md section 1.1.
// ---------------------------------------------------------------------

const String _gameId = 'c613c613c613c613';
const String _clientSeeds = '0:c613-seed-alice|1:c613-seed-server';

Map<String, Object?> _deepCopy(Map<String, Object?> record) =>
    jsonDecode(jsonEncode(record))! as Map<String, Object?>;

List<Map<String, Object?>> _rollsOf(Map<String, Object?> record) =>
    (record['rolls']! as List<Object?>).cast<Map<String, Object?>>();

Map<String, Object?> _goodRecord({int rollCount = 5}) {
  final List<int> secret =
      List<int>.generate(32, (int i) => (i * 17 + 9) % 256);
  final DiceChain chain = DiceChain.build(secret);
  return <String, Object?>{
    'format': verifyRecordFormat,
    'game_id': _gameId,
    'chain_commit': chain.commit,
    'chain_index': 0,
    'chain_length': chain.chainLength,
    'client_seeds': _clientSeeds,
    'seeds': <Map<String, Object?>>[
      <String, Object?>{
        'seat': 0,
        'seed': 'c613-seed-alice',
        'origin': 'player',
      },
      <String, Object?>{
        'seat': 1,
        'seed': 'c613-seed-server',
        'origin': 'server',
      },
    ],
    'rolls': <Map<String, Object?>>[
      for (int k = 1; k <= rollCount; k++)
        <String, Object?>{
          'k': k,
          'seat': k.isOdd ? 0 : 1,
          'reveal': chain.reveal(k),
          'die': drawDie(chain.reveal(k), _gameId, _clientSeeds, k, 0),
        },
    ],
    'winner': 0,
    'finished_at': '2026-03-02T00:00:00Z',
  };
}

/// Roll [k]'s die moved to a different face; every other field intact.
Map<String, Object?> _dieAltered(int k) {
  final Map<String, Object?> record = _deepCopy(_goodRecord());
  final Map<String, Object?> roll = _rollsOf(record)[k - 1];
  final int die = roll['die']! as int;
  roll['die'] = die == 6 ? 1 : die + 1;
  return record;
}

/// The last roll's reveal changed in its last hex digit: that roll's chain
/// link and its die both stop matching.
Map<String, Object?> _lastRevealAltered() {
  final Map<String, Object?> record = _deepCopy(_goodRecord());
  final Map<String, Object?> last = _rollsOf(record).last;
  last['reveal'] = _flipLastHexChar(last['reveal']! as String);
  return record;
}

Map<String, Object?> _formatTwo() {
  final Map<String, Object?> record = _deepCopy(_goodRecord());
  record['format'] = verifyRecordFormat + 1;
  return record;
}

Map<String, Object?> _seedsDisagree() {
  final Map<String, Object?> record = _deepCopy(_goodRecord());
  record['client_seeds'] = '${record['client_seeds']}-tampered';
  return record;
}

Map<String, Object?> _rollOutOfOrder() {
  final Map<String, Object?> record = _deepCopy(_goodRecord());
  _rollsOf(record)[2]['k'] = 7;
  return record;
}

/// A reveal of odd length: hexToBytes throws inside the check.
Map<String, Object?> _oddLengthReveal() {
  final Map<String, Object?> record = _deepCopy(_goodRecord());
  final Map<String, Object?> roll = _rollsOf(record)[1];
  final String reveal = roll['reveal']! as String;
  roll['reveal'] = reveal.substring(0, reveal.length - 1);
  return record;
}

String _flipLastHexChar(String hex) {
  final String last = hex.substring(hex.length - 1);
  return '${hex.substring(0, hex.length - 1)}${last == '0' ? '1' : '0'}';
}

// ---------------------------------------------------------------------
// A minimal HTML reader: elements that carry an id.
// ---------------------------------------------------------------------

String _decodeEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', '\'')
    .replaceAll('&#x27;', '\'')
    .replaceAll('&amp;', '&');

Map<String, String> _attrsOf(String attrText) => <String, String>{
      for (final RegExpMatch m
          in RegExp(r'([\w:-]+)="([^"]*)"').allMatches(attrText))
        m.group(1)!: _decodeEntities(m.group(2)!),
    };

/// id -> {attrs, text} for every element of [html] that has an id. The text
/// runs from the opening tag to the next closing tag of the same name, which
/// is the element's whole content for the leaf elements the script reads
/// (nested containers such as the tables are never read for their text).
Map<String, Map<String, Object?>> _elementsById(String html) {
  final Map<String, Map<String, Object?>> out =
      <String, Map<String, Object?>>{};
  final RegExp open = RegExp(r'<(\w+)(\s[^>]*?\bid="([^"]+)"[^>]*)>');
  for (final RegExpMatch m in open.allMatches(html)) {
    final String tag = m.group(1)!;
    final int close = html.indexOf('</$tag>', m.end);
    final String inner = close < 0 ? '' : html.substring(m.end, close);
    out[m.group(3)!] = <String, Object?>{
      'attrs': _attrsOf(m.group(2)!),
      'text': tag == 'script' ? inner : _decodeEntities(inner),
    };
  }
  return out;
}

final RegExp _summaryTag = RegExp(r'<p[^>]*\sid="summary"[^>]*>');

/// [html] with every data-* attribute of #summary removed except [keep];
/// [removed] receives the names taken out.
String _stripSummaryData(
  String html,
  List<String> removed, {
  Set<String> keep = const <String>{'data-ok', 'data-fail'},
}) {
  return html.replaceFirstMapped(_summaryTag, (Match m) {
    return m.group(0)!.replaceAllMapped(
      RegExp(r'\s(data-[\w-]+)="[^"]*"'),
      (Match a) {
        if (keep.contains(a.group(1))) {
          return a.group(0)!;
        }
        removed.add(a.group(1)!);
        return '';
      },
    );
  });
}

// ---------------------------------------------------------------------
// The node driver.
// ---------------------------------------------------------------------

/// Reads {html elements, verify.js source, crypto mode} and runs the script
/// in a context holding only a `document` stub (and the few host globals a
/// browser would have), then waits on a condition -- #summary carrying a
/// state class and different text -- not on a fixed delay. If that never
/// happens within the cap it reports `timedOut` instead of failing, so the
/// Dart side can say what the page was left showing.
const String _driverSource = r'''
const fs = require('fs');
const vm = require('vm');
const nodeCrypto = require('crypto');

const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const errors = [];
process.on('unhandledRejection', (e) => {
  errors.push('unhandledRejection: ' + String((e && e.stack) || e));
});
process.on('uncaughtException', (e) => {
  errors.push('uncaughtException: ' + String((e && e.stack) || e));
});

function camel(name) {
  return name.replace(/^data-/, '').replace(/-([a-z])/g, (m, c) => c.toUpperCase());
}

function makeElement(spec) {
  const classes = new Set((spec.attrs['class'] || '').split(/\s+/).filter(Boolean));
  let text = spec.text;
  const el = { dataset: {} };
  for (const [name, value] of Object.entries(spec.attrs)) {
    if (name.startsWith('data-')) el.dataset[camel(name)] = value;
  }
  Object.defineProperty(el, 'textContent', {
    get: () => text,
    set: (v) => { text = String(v); },
    enumerable: true,
  });
  Object.defineProperty(el, 'className', {
    get: () => Array.from(classes).join(' '),
    set: (v) => {
      classes.clear();
      String(v).split(/\s+/).filter(Boolean).forEach((c) => classes.add(c));
    },
  });
  el.classList = {
    add: (...n) => n.forEach((c) => classes.add(c)),
    remove: (...n) => n.forEach((c) => classes.delete(c)),
    contains: (c) => classes.has(c),
    toggle: (c, force) => {
      const on = force === undefined ? !classes.has(c) : !!force;
      if (on) classes.add(c); else classes.delete(c);
      return on;
    },
    replace: (a, b) => {
      if (!classes.has(a)) return false;
      classes.delete(a);
      classes.add(b);
      return true;
    },
  };
  el.__classes = classes;
  el.__text = () => text;
  return el;
}

const els = {};
for (const [id, spec] of Object.entries(input.elements)) els[id] = makeElement(spec);

const sandbox = {
  document: {
    getElementById: (id) =>
      Object.prototype.hasOwnProperty.call(els, id) ? els[id] : null,
  },
  TextEncoder: TextEncoder,
  Uint8Array: Uint8Array,
  console: console,
  setTimeout: setTimeout,
  clearTimeout: clearTimeout,
};
sandbox.window = sandbox;
if (input.crypto === 'real') sandbox.crypto = nodeCrypto.webcrypto;
else if (input.crypto === 'noSubtle') sandbox.crypto = {};
// 'absent': no crypto global at all.
vm.createContext(sandbox);

const summary = els['summary'];
const initialText = summary ? summary.__text() : null;
const settled = () =>
  summary &&
  (summary.__classes.has('verify-ok') || summary.__classes.has('verify-fail')) &&
  summary.__text() !== initialText;
const turn = () => new Promise((r) => setImmediate(r));

(async () => {
  let loadError = null;
  try {
    vm.runInContext(input.verifyJs, sandbox, { filename: 'verify.js' });
  } catch (e) {
    loadError = String((e && e.stack) || e);
  }
  const deadline = Date.now() + input.capMs;
  let timedOut = false;
  while (!settled()) {
    if (Date.now() > deadline) { timedOut = true; break; }
    await new Promise((r) => setTimeout(r, 5));
  }
  for (let i = 0; i < 50; i++) await turn();
  const cells = {};
  for (const id of Object.keys(els)) {
    if (/^(chain|die)-/.test(id)) {
      cells[id] = { text: els[id].__text(), classes: Array.from(els[id].__classes) };
    }
  }
  const out = {
    timedOut: timedOut,
    loadError: loadError,
    errors: errors,
    summary: summary
      ? { text: summary.__text(), classes: Array.from(summary.__classes) }
      : null,
    cells: cells,
  };
  process.stdout.write(JSON.stringify(out), () => process.exit(0));
})();
''';

/// What the page was left showing after the script ran.
class _Outcome {
  _Outcome(this.raw, this.scenario);

  final Map<String, Object?> raw;
  final String scenario;

  bool get timedOut => raw['timedOut']! as bool;
  Map<String, Object?>? get _summary => raw['summary'] as Map<String, Object?>?;
  String get text => (_summary?['text'] as String?) ?? '<no #summary>';
  List<String> get classes =>
      ((_summary?['classes'] as List<Object?>?) ?? const <Object?>[])
          .cast<String>();
  Map<String, Object?> get cells => raw['cells']! as Map<String, Object?>;

  String cellText(String id) =>
      (cells[id]! as Map<String, Object?>)['text']! as String;
  List<String> cellClasses(String id) =>
      ((cells[id]! as Map<String, Object?>)['classes']! as List<Object?>)
          .cast<String>();

  /// Everything a failing assertion should print.
  String get why => 'scenario: $scenario | summary text: "$text" | summary '
      'classes: $classes | timedOut: $timedOut | load error: '
      '${raw['loadError']} | script errors: ${raw['errors']} | cells: '
      '${jsonEncode(cells)} | reproduce: cd packages/ludo_server && dart '
      'test test/c613_verify_fail_state_test.dart -N \'$scenario\' (fixtures '
      'are fixed, there is no seed)';
}

int _inputSeq = 0;

void main() {
  late Directory tempDir;
  late File driverFile;

  setUpAll(() async {
    await _requireInterpreter('node');
    tempDir = Directory.systemTemp.createTempSync('c613_verify_fail_state_');
    driverFile = File('${tempDir.path}${Platform.pathSeparator}driver.js')
      ..writeAsStringSync(_driverSource);
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  /// Builds the real page for [record] in [lang] (optionally rewritten by
  /// [editHtml]) and runs [verifyJs] against it.
  Future<_Outcome> run(
    String scenario,
    String lang,
    Map<String, Object?> record, {
    String crypto = 'real',
    String Function(String html)? editHtml,
    String? verifyJs,
  }) async {
    String html = buildVerifyPageHtml(jsonEncode(record), language: lang);
    if (editHtml != null) {
      html = editHtml(html);
    }
    final File inputFile = File(
      '${tempDir.path}${Platform.pathSeparator}in_${_inputSeq++}.json',
    )..writeAsStringSync(jsonEncode(<String, Object?>{
        'elements': _elementsById(html),
        'verifyJs': verifyJs ?? verifyJsSource,
        'crypto': crypto,
        'capMs': 4000,
      }));
    final ProcessResult result = await Process.run(
      'node',
      <String>[driverFile.path, inputFile.path],
    );
    if (result.exitCode != 0) {
      fail(
        'node driver failed (exit ${result.exitCode}) for scenario '
        '$scenario ($lang)\nstdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
    }
    return _Outcome(
      jsonDecode(result.stdout as String)! as Map<String, Object?>,
      scenario,
    );
  }

  // -------------------------------------------------------------------
  // Shared assertions.
  // -------------------------------------------------------------------

  /// Strips [mark] from the front of [o]'s summary (failing with the full
  /// picture if it is not there) and returns what follows.
  String afterMark(_Outcome o, String mark, String lang, String expected) {
    expect(
      o.text.startsWith(mark),
      isTrue,
      reason:
          'expected the $lang summary to START with U+${mark.codeUnitAt(0).toRadixString(16).toUpperCase()} '
          'and then read "$expected"; ${o.why}',
    );
    return o.text.substring(mark.length).replaceFirst(_gap, '');
  }

  void expectPass(_Outcome o, String lang, int n) {
    final _Words w = _words[lang]!;
    final String rest = afterMark(o, _tick, lang, w.ok(n));
    expect(rest, w.ok(n),
        reason: 'expected the pass template with n=$n after the check '
            'mark; ${o.why}');
    expect(o.text.contains(_cross), isFalse,
        reason: 'a pass must never carry the failure cross; ${o.why}');
    expect(o.classes, contains('verify-ok'),
        reason: 'expected class verify-ok on #summary; ${o.why}');
    expect(o.classes, isNot(contains('verify-fail')),
        reason: 'a pass must not carry verify-fail; ${o.why}');
  }

  void expectFail(_Outcome o, String lang, String reason) {
    final _Words w = _words[lang]!;
    final String rest = afterMark(o, _cross, lang, w.fail(reason));
    expect(rest, w.fail(reason),
        reason: 'expected the D1 fail template for $lang with the D2 '
            'sentence "$reason" after the cross; ${o.why}');
    expect(o.text.contains(_tick), isFalse,
        reason: 'a failure must never carry the pass tick; ${o.why}');
    expect(_cross.allMatches(o.text).length, 1,
        reason: 'exactly one cross expected in the summary; ${o.why}');
    expect(o.classes, contains('verify-fail'),
        reason: 'expected class verify-fail on #summary; ${o.why}');
    expect(o.classes, isNot(contains('verify-ok')),
        reason: 'a failure must not carry verify-ok; ${o.why}');
    for (final String token in _tokens) {
      expect(o.text.contains(token), isFalse,
          reason: 'the raw token/phrase "$token" must never reach the '
              'reader; ${o.why}');
    }
    if (lang == 'ar') {
      final String bare = o.text.replaceAll(_cross, '').replaceAll(_tick, '');
      expect(RegExp(r'[A-Za-z]').hasMatch(bare), isFalse,
          reason: 'no English word may appear in the Arabic summary; '
              '${o.why}');
    }
  }

  void expectCellsAllMatch(_Outcome o, String lang, int n) {
    final _Words w = _words[lang]!;
    for (int k = 1; k <= n; k++) {
      for (final String id in <String>['chain-$k', 'die-$k']) {
        expect(o.cellText(id), w.cellMatch,
            reason: 'matching cell $id must keep exactly the data-match '
                'words "${w.cellMatch}"; ${o.why}');
        expect(o.cellClasses(id), isNot(contains('verify-mismatch')),
            reason: 'matching cell $id must not be marked; ${o.why}');
      }
    }
  }

  void expectMismatchCell(_Outcome o, String lang, String id) {
    final _Words w = _words[lang]!;
    expect(o.cellClasses(id), contains('verify-mismatch'),
        reason: 'cell $id should carry class verify-mismatch; ${o.why}');
    final String text = o.cellText(id);
    expect(text.startsWith(_cross), isTrue,
        reason: 'cell $id should start with the cross glyph; ${o.why}');
    expect(text.substring(_cross.length).replaceFirst(_gap, ''), w.cellMismatch,
        reason: 'cell $id should keep the data-mismatch words '
            '"${w.cellMismatch}" after the cross; ${o.why}');
    expect(_cross.allMatches(text).length, 1,
        reason: 'exactly one cross in cell $id; ${o.why}');
  }

  // -------------------------------------------------------------------
  // (a) to (g): the page, run for real, in both languages.
  // -------------------------------------------------------------------

  for (final String lang in _langs) {
    final _Words w = _words[lang]!;

    group('behaviour, $lang page', () {
      test(
          '(a) $lang: a valid record reads as a pass: tick, pass template '
          'with n, verify-ok, no marked cell', () async {
        final _Outcome o = await run(
            '(a) $lang: a valid record reads as a pass: tick, pass '
            'template with n, verify-ok, no marked cell',
            lang,
            _goodRecord());
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached a verify-ok or verify-fail state; ${o.why}');
        expectPass(o, lang, 5);
        expectCellsAllMatch(o, lang, 5);
      });

      test(
          '(b) $lang: one die altered: cross, D1 fail template with the '
          'mismatch sentence, verify-fail, that die cell marked', () async {
        final _Outcome o = await run(
            '(b) $lang: one die altered: cross, D1 fail template with the '
            'mismatch sentence, verify-fail, that die cell marked',
            lang,
            _dieAltered(3));
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached a verify-ok or verify-fail state; ${o.why}');
        expectFail(o, lang, w.mismatch);
        expectMismatchCell(o, lang, 'die-3');
        for (final String id in <String>[
          'chain-1', 'chain-2', 'chain-3', 'chain-4', 'chain-5',
          'die-1', 'die-2', 'die-4', 'die-5', //
        ]) {
          expect(o.cellText(id), w.cellMatch,
              reason: 'only die-3 was altered, so $id must still match; '
                  '${o.why}');
          expect(o.cellClasses(id), isNot(contains('verify-mismatch')),
              reason: '$id must not be marked; ${o.why}');
        }
      });

      test(
          '(b2) $lang: last reveal altered: both of that roll\'s cells '
          'marked, the mismatch sentence', () async {
        final _Outcome o = await run(
            '(b2) $lang: last reveal altered: both of that roll\'s cells '
            'marked, the mismatch sentence',
            lang,
            _lastRevealAltered());
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached a verify-ok or verify-fail state; ${o.why}');
        expectFail(o, lang, w.mismatch);
        expectMismatchCell(o, lang, 'chain-5');
        for (int k = 1; k <= 4; k++) {
          expect(o.cellClasses('chain-$k'), isNot(contains('verify-mismatch')),
              reason: 'chain-$k was not altered; ${o.why}');
          expect(o.cellClasses('die-$k'), isNot(contains('verify-mismatch')),
              reason: 'die-$k was not altered; ${o.why}');
        }
      });

      test('(c) $lang: format 2 gets the format sentence', () async {
        final _Outcome o = await run(
            '(c) $lang: format 2 gets the format sentence', lang, _formatTwo());
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached a verify-ok or verify-fail state; ${o.why}');
        expectFail(o, lang, w.format);
      });

      test('(d) $lang: seeds that disagree get the client_seeds sentence',
          () async {
        final _Outcome o = await run(
            '(d) $lang: seeds that disagree get the client_seeds sentence',
            lang,
            _seedsDisagree());
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached a verify-ok or verify-fail state; ${o.why}');
        expectFail(o, lang, w.clientSeeds);
      });

      test(
          '(e) $lang: a roll numbered out of order gets the roll_sequence '
          'sentence', () async {
        final _Outcome o = await run(
            '(e) $lang: a roll numbered out of order gets the roll_sequence '
            'sentence',
            lang,
            _rollOutOfOrder());
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached a verify-ok or verify-fail state; ${o.why}');
        expectFail(o, lang, w.rollSequence);
      });

      test(
          '(f) $lang: an odd-length reveal (the check throws) ends in the '
          'fail state with the error sentence', () async {
        final _Outcome o = await run(
            '(f) $lang: an odd-length reveal (the check throws) ends in the '
            'fail state with the error sentence',
            lang,
            _oddLengthReveal());
        expect(o.timedOut, isFalse,
            reason: 'a throw left the summary on "not checked" forever, '
                'which reads as "not done yet"; ${o.why}');
        expectFail(o, lang, w.error);
      });

      test(
          '(g) $lang: crypto.subtle absent ends in the fail state with the '
          'error sentence', () async {
        final _Outcome o = await run(
            '(g) $lang: crypto.subtle absent ends in the fail state with the '
            'error sentence',
            lang,
            _goodRecord(),
            crypto: 'noSubtle');
        expect(o.timedOut, isFalse,
            reason: 'no crypto.subtle left the summary on "not checked" '
                'forever; ${o.why}');
        expectFail(o, lang, w.error);
      });

      test(
          '(g2) $lang: no crypto global at all ends in the fail state with '
          'the error sentence', () async {
        final _Outcome o = await run(
            '(g2) $lang: no crypto global at all ends in the fail state with '
            'the error sentence',
            lang,
            _goodRecord(),
            crypto: 'absent');
        expect(o.timedOut, isFalse,
            reason: 'a missing crypto global left the summary on "not '
                'checked" forever; ${o.why}');
        expectFail(o, lang, w.error);
      });

      test(
          '(l) $lang: an unknown future error token maps to the error '
          'sentence', () async {
        // The check's own return line is frozen by D5, so this edit of the
        // served source is stable: it makes the first check report a token
        // that no table row names.
        const String old = "return { ok: false, error: 'format', rolls: "
            'rollsOut };';
        expect(verifyJsSource.contains(old), isTrue,
            reason: 'D5 freezes verifyRecord, so its format check must '
                'still read exactly: $old');
        final String patched = verifyJsSource.replaceFirst(
            old,
            "return { ok: false, error: 'future_token_x', rolls: "
            'rollsOut };');
        final _Outcome o = await run(
            '(l) $lang: an unknown future error token maps to the error '
            'sentence',
            lang,
            _formatTwo(),
            verifyJs: patched);
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached a verify-ok or verify-fail state; ${o.why}');
        expectFail(o, lang, w.error);
        expect(o.text.contains('future_token_x'), isFalse,
            reason: 'the unknown token must not be shown; ${o.why}');
      });
    });
  }

  // -------------------------------------------------------------------
  // (h) a cached page: none of the new attributes.
  // -------------------------------------------------------------------

  group('(h) a page without the per-cause attributes', () {
    final Map<String, Map<String, Object?> Function()> causes =
        <String, Map<String, Object?> Function()>{
      'format': _formatTwo,
      'client_seeds': _seedsDisagree,
      'roll_sequence': _rollOutOfOrder,
      'mismatch': () => _dieAltered(2),
      'error': _oddLengthReveal,
    };
    final Map<String, String> enSentence = <String, String>{
      'format': _words['en']!.format,
      'client_seeds': _words['en']!.clientSeeds,
      'roll_sequence': _words['en']!.rollSequence,
      'mismatch': _words['en']!.mismatch,
      'error': _words['en']!.error,
    };

    for (final String lang in _langs) {
      causes.forEach((String cause, Map<String, Object?> Function() build) {
        test(
            '(h) $lang page, attributes stripped, cause $cause: the '
            'English sentence, never a token', () async {
          final String name = '(h) $lang page, attributes stripped, cause '
              '$cause: the English sentence, never a token';
          final List<String> removed = <String>[];
          final _Outcome o = await run(name, lang, build(),
              editHtml: (String html) => _stripSummaryData(html, removed));
          expect(removed.length, 5,
              reason: 'the page should carry five per-cause data attributes '
                  'on #summary besides data-ok and data-fail (one per D2 '
                  'cause); found ${removed.length}: $removed; ${o.why}');
          expect(o.timedOut, isFalse,
              reason:
                  'the summary never reached a verify-ok or verify-fail state; ${o.why}');
          final _Words w = _words[lang]!;
          final String sentence = enSentence[cause]!;
          final String rest = afterMark(o, _cross, lang, w.fail(sentence));
          expect(rest, w.fail(sentence),
              reason: 'with the attributes gone, the reason must be the '
                  'English sentence "$sentence" inside the $lang template; '
                  '${o.why}');
          expect(o.classes, contains('verify-fail'),
              reason: 'expected verify-fail; ${o.why}');
          for (final String token in _tokens) {
            expect(o.text.contains(token), isFalse,
                reason: 'raw token "$token" shown; ${o.why}');
          }
        });
      });
    }

    for (final String cause in <String>['format', 'mismatch', 'error']) {
      test(
          '(h2) en page, every summary data attribute stripped, cause '
          '$cause: the D1 English template with the English sentence',
          () async {
        final String name = '(h2) en page, every summary data attribute '
            'stripped, cause $cause: the D1 English template with the '
            'English sentence';
        final _Outcome o = await run(name, 'en', causes[cause]!(),
            editHtml: (String html) =>
                _stripSummaryData(html, <String>[], keep: const <String>{}));
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached a verify-ok or verify-fail state; ${o.why}');
        expectFail(o, 'en', enSentence[cause]!);
      });
    }

    test(
        '(h2) en page, every summary data attribute stripped, a valid '
        'record: tick then the English pass wording', () async {
      const String name = '(h2) en page, every summary data attribute '
          'stripped, a valid record: tick then the English pass wording';
      final _Outcome o = await run(name, 'en', _goodRecord(),
          editHtml: (String html) =>
              _stripSummaryData(html, <String>[], keep: const <String>{}));
      expect(o.timedOut, isFalse,
          reason:
              'the summary never reached a verify-ok or verify-fail state; ${o.why}');
      expectPass(o, 'en', 5);
    });
  });

  // -------------------------------------------------------------------
  // (i) static HTML and stylesheet.
  // -------------------------------------------------------------------

  for (final String lang in _langs) {
    final _Words w = _words[lang]!;

    group('static page, $lang', () {
      late String html;
      late Map<String, Map<String, Object?>> els;

      setUpAll(() {
        html = buildVerifyPageHtml(jsonEncode(_goodRecord()), language: lang);
        els = _elementsById(html);
      });

      test(
          '(i) $lang: #summary carries the pass and fail templates and the '
          'five D2 sentences, and no state class', () {
        final Map<String, String> attrs =
            (els['summary']!['attrs']! as Map<String, Object?>)
                .cast<String, String>();
        expect(attrs['data-ok'], w.okTemplate,
            reason: 'D1: the pass template must be unchanged; attrs: $attrs');
        expect(attrs['data-fail'], w.failTemplate,
            reason: 'D1: the fail template must be "${w.failTemplate}"; '
                'attrs: $attrs');
        final Set<String> values = attrs.values.toSet();
        for (final String sentence in w.sentences) {
          expect(values.contains(sentence), isTrue,
              reason: 'D2: #summary should carry a data attribute whose '
                  'value is exactly "$sentence"; attrs: $attrs');
        }
        final List<String> state = (attrs['class'] ?? '')
            .split(RegExp(r'\s+'))
            .where((String c) => c.startsWith('verify-'))
            .toList();
        expect(state, isEmpty,
            reason: 'D3: no state class before the script runs; attrs: '
                '$attrs');
        expect(els['summary']!['text'], isNotEmpty);
        expect(RegExp(r'class="[^"]*verify-(ok|fail|mismatch)').hasMatch(html),
            isFalse,
            reason: 'no element may carry a verify-* state class in the '
                'markup before the script runs');
      });

      test('(i) $lang: a noscript line with D4\'s words sits under #summary',
          () {
        final int summaryAt =
            html.indexOf(_summaryTag.firstMatch(html)!.group(0)!);
        final RegExpMatch? m = RegExp(
          r'<noscript[^>]*>(.*?)</noscript>',
          dotAll: true,
        ).firstMatch(html);
        expect(m, isNotNull,
            reason: 'D4: the page needs a <noscript> line; none found');
        final String text =
            _decodeEntities(m!.group(1)!.replaceAll(RegExp(r'<[^>]*>'), ''))
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
        expect(text, w.noscript,
            reason: 'D4: the <noscript> text for $lang must be exactly the '
                'contract sentence');
        expect(m.start > summaryAt, isTrue,
            reason: 'D4: the <noscript> must come after #summary');
        expect(m.start < html.indexOf('<h2'), isTrue,
            reason: 'D4: the <noscript> must sit directly under #summary, '
                'before the first heading');
      });

      test(
          '(i) $lang: the stylesheet defines verify-ok, verify-fail and '
          'verify-mismatch with the D3 colours, 4.5:1 or better on white', () {
        final String css = RegExp(r'<style>(.*?)</style>', dotAll: true)
            .firstMatch(html)!
            .group(1)!;
        final Map<String, Map<String, String>> byClass =
            _declarationsByClass(css);
        const Map<String, String> colours = <String, String>{
          'verify-ok': '#1b5e20',
          'verify-fail': '#b3261e',
          'verify-mismatch': '#b3261e',
        };
        colours.forEach((String cls, String hex) {
          final Map<String, String>? d = byClass[cls];
          expect(d, isNotNull,
              reason: 'D3: the stylesheet has no rule for .$cls');
          expect(d!['color']?.toLowerCase(), hex,
              reason: 'D3: .$cls text colour must be $hex; declarations: $d');
          final double ratio = _contrastOnWhite(hex);
          expect(ratio >= 4.5, isTrue,
              reason: 'D3: .$cls ($hex) contrast on #ffffff is '
                  '${ratio.toStringAsFixed(2)}, needs 4.5 or better');
        });
        for (final String cls in <String>['verify-fail', 'verify-mismatch']) {
          final String? weight = byClass[cls]?['font-weight']?.toLowerCase();
          expect(
            <String>['bold', 'bolder', '700', '800', '900'].contains(weight),
            isTrue,
            reason: 'D3: .$cls must be bold; font-weight is $weight',
          );
        }
      });

      test(
          '(k) $lang: the page needs no inline script, handler or style '
          'attribute (CSP: script-src \'self\')', () {
        for (final RegExpMatch m
            in RegExp(r'<script([^>]*)>').allMatches(html)) {
          final String attrs = m.group(1)!;
          expect(
            attrs.contains('src="') || attrs.contains('application/json'),
            isTrue,
            reason: 'an executable inline <script$attrs> would be blocked '
                'by the CSP',
          );
        }
        expect(RegExp(r'\son\w+\s*=').hasMatch(html), isFalse,
            reason: 'inline event handlers are blocked by the CSP');
        expect(html.contains('javascript:'), isFalse,
            reason: 'javascript: URLs are blocked by the CSP');
        expect(verifyJsSource.contains('eval('), isFalse,
            reason: 'eval is blocked by the CSP');
        expect(verifyJsSource.contains('new Function'), isFalse,
            reason: 'new Function is blocked by the CSP');
      });
    });
  }

  // -------------------------------------------------------------------
  // (j) the decision itself is frozen.
  // -------------------------------------------------------------------

  group('(j) the pass or fail decision is unchanged', () {
    // The pins were taken on base 413ddf2 (before any C-613 change) by
    // running this group's fixtures through that tree's verifyRecord and
    // hashing the exact JSON each returned (sha256 of JSON.stringify of the
    // result, key order included). The fixtures are the ones
    // verify_checkers_test.dart uses, rebuilt here; a change to what
    // verifyRecord returns for any of them changes its hash.
    final Map<String, Map<String, Object?>> fixtures =
        <String, Map<String, Object?>>{
      'good record, 30 rolls': _goodRecord(rollCount: 30),
      'a die changed by one': _dieChangedByOne(),
      'last reveal, last hex digit changed': _lastRevealChanged30(),
      'rolls 10 and 20 swapped': _twoRollsSwapped(),
      'roll 5 removed': _gapAtFive(),
      'client_seeds changed': _seedsDisagree30(),
      'chain_commit changed': _chainCommitChanged(),
      'format 2': _formatTwo30(),
      'dice drawn under another game_id': _gameIdMismatch(),
    };
    const Map<String, String> pinnedResultHash = <String, String>{
      'good record, 30 rolls':
          '271d8bb992516eca87a64da99b7e7326ce47bf0359c35ee205003dcd750a9777',
      'a die changed by one':
          'de89a547dedfb22082a0fd4609b05d820ace2c8e7c66a028cf858c4d51676d58',
      'last reveal, last hex digit changed':
          '362344df70cbeb0fb3148779f845bf11b705df63ecb4a7722f3feca33f60924c',
      'rolls 10 and 20 swapped':
          '65ab34cd0effee1ce135b8d8bceacde1cfc3777ceaf24b43c1d063bff1eaa201',
      'roll 5 removed':
          '9c542f3448d14196e66286219f14eaf96b7b8cd3c6f297dbbe33bf7f065a34ff',
      'client_seeds changed':
          '89814b14440d483249452bb57690228e652ce68ac85f622d54ff3be2d9b15f55',
      'chain_commit changed':
          '7e45e560aeb24ad9e45443fe8d247f26523394ddb91430bb3e7c354da60c0f3c',
      'format 2':
          'fd38128a36361fe258f8658604e59991f920399ff9fdefec447c934c1a0c080d',
      'dice drawn under another game_id':
          '21d869de9a67f026ea1baefefaf5499dcfdc7af802f05eaa2a50311d8101b7de',
    };
    const Map<String, bool> expectedOk = <String, bool>{
      'good record, 30 rolls': true,
    };

    test(
        'verifyRecord returns exactly what it returned on 413ddf2 for '
        'every fixture', () async {
      final File jsFile =
          File('${tempDir.path}${Platform.pathSeparator}verify_j.js')
            ..writeAsStringSync(verifyJsSource);
      final File driver =
          File('${tempDir.path}${Platform.pathSeparator}driver_j.js')
            ..writeAsStringSync(r'''
const fs = require('fs');
const verify = require(process.argv[2]);
const input = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
(async () => {
  const out = {};
  for (const [name, record] of Object.entries(input)) {
    out[name] = JSON.stringify(await verify.verifyRecord(record));
  }
  process.stdout.write(JSON.stringify(out));
})();
''');
      final File inputFile =
          File('${tempDir.path}${Platform.pathSeparator}in_j.json')
            ..writeAsStringSync(jsonEncode(fixtures));
      final ProcessResult r = await Process.run(
          'node', <String>[driver.path, jsFile.path, inputFile.path]);
      expect(r.exitCode, 0, reason: 'node failed: ${r.stderr}');
      final Map<String, Object?> results =
          jsonDecode(r.stdout as String)! as Map<String, Object?>;
      final List<String> differences = <String>[];
      for (final String name in fixtures.keys) {
        final String json = results[name]! as String;
        final Map<String, Object?> parsed =
            jsonDecode(json)! as Map<String, Object?>;
        final String hash = sha256.convert(utf8.encode(json)).toString();
        if (parsed['ok'] != (expectedOk[name] ?? false)) {
          differences.add('"$name": ok is ${parsed['ok']}, result: $json');
        }
        if (hash != pinnedResultHash[name]) {
          differences.add('"$name": result hash $hash, pinned '
              '${pinnedResultHash[name]}, result: $json');
        }
      }
      expect(differences, isEmpty,
          reason: 'verifyRecord no longer returns what it returned on '
              '413ddf2 for these fixtures (D5 freezes the decision); '
              'reproduce with: dart test '
              'test/c613_verify_fail_state_test.dart -N "(j)"');
    });

    test(
        'the source of verifyRecord and the module exports are '
        'byte-identical to 413ddf2 (D5)', () {
      const String head = 'async function verifyRecord(record) {';
      final int start = verifyJsSource.indexOf(head);
      expect(start, greaterThanOrEqualTo(0),
          reason: 'D5: verifyRecord must still be declared as "$head"');
      final int end = verifyJsSource.indexOf('\n}\n', start) + 3;
      final String fn = verifyJsSource.substring(start, end);
      expect(sha256.convert(utf8.encode(fn)).toString(), _verifyRecordSrcHash,
          reason: 'D5: verifyRecord\'s source changed; it is frozen');
      const String exports =
          'module.exports = { drawDie: drawDie, verifyRecord: verifyRecord };';
      expect(verifyJsSource.contains(exports), isTrue,
          reason: 'D5: the exports must stay exactly: $exports');
    });
  });
}

/// sha256 of verifyRecord's source text on 413ddf2: from the line
/// `async function verifyRecord(record) {` through its closing `}` and
/// newline. Taken with:
///   sed -n '/^async function verifyRecord/,/^}$/p' <verify_scripts.dart at
///   413ddf2> | sha256sum
const String _verifyRecordSrcHash =
    '5fc3701879c0c6e7e03f3a1c8f3abe60e77e18286fc78d52b813770ce8e87d2e';

// ---------------------------------------------------------------------
// (j) fixtures, rebuilt from verify_checkers_test.dart.
// ---------------------------------------------------------------------

const String _jGameId = 'abcdef0123456789';
const String _jClientSeeds = '0:alice-checkers-seed|1:srv-seed-000000';

Map<String, Object?> _jGood(
    {int rollCount = 30,
    int mul = 7,
    int add = 3,
    String gameId = _jGameId,
    String statedGameId = _jGameId,
    String clientSeeds = _jClientSeeds}) {
  final List<int> secret =
      List<int>.generate(32, (int i) => (i * mul + add) % 256);
  final DiceChain chain = DiceChain.build(secret);
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
        'seed': 'alice-checkers-seed',
        'origin': 'player',
      },
      <String, Object?>{
        'seat': 1,
        'seed': 'srv-seed-000000',
        'origin': 'server',
      },
    ],
    'rolls': <Map<String, Object?>>[
      for (int k = 1; k <= rollCount; k++)
        <String, Object?>{
          'k': k,
          'seat': k.isOdd ? 0 : 1,
          'reveal': chain.reveal(k),
          'die': drawDie(chain.reveal(k), gameId, clientSeeds, k, 0),
        },
    ],
    'winner': 0,
    'finished_at': '2026-01-01T00:00:00Z',
  };
}

Map<String, Object?> _dieChangedByOne() {
  final Map<String, Object?> record = _deepCopy(_jGood());
  final Map<String, Object?> first = _rollsOf(record).first;
  final int die = first['die']! as int;
  first['die'] = die == 6 ? 1 : die + 1;
  return record;
}

Map<String, Object?> _lastRevealChanged30() {
  final Map<String, Object?> record = _deepCopy(_jGood());
  final Map<String, Object?> last = _rollsOf(record).last;
  last['reveal'] = _flipLastHexChar(last['reveal']! as String);
  return record;
}

Map<String, Object?> _twoRollsSwapped() {
  final Map<String, Object?> record = _deepCopy(_jGood());
  final List<Map<String, Object?>> rolls = _rollsOf(record);
  for (final String field in <String>['reveal', 'die', 'seat']) {
    final Object? tmp = rolls[9][field];
    rolls[9][field] = rolls[19][field];
    rolls[19][field] = tmp;
  }
  return record;
}

Map<String, Object?> _gapAtFive() {
  final Map<String, Object?> record = _deepCopy(_jGood());
  (record['rolls']! as List<Object?>).removeWhere(
    (Object? r) => (r! as Map<String, Object?>)['k'] == 5,
  );
  return record;
}

Map<String, Object?> _seedsDisagree30() {
  final Map<String, Object?> record = _deepCopy(_jGood());
  record['client_seeds'] = '${record['client_seeds']}-tampered';
  return record;
}

Map<String, Object?> _chainCommitChanged() {
  final Map<String, Object?> record = _deepCopy(_jGood());
  record['chain_commit'] = _flipLastHexChar(record['chain_commit']! as String);
  return record;
}

Map<String, Object?> _formatTwo30() {
  final Map<String, Object?> record = _deepCopy(_jGood());
  record['format'] = verifyRecordFormat + 1;
  return record;
}

Map<String, Object?> _gameIdMismatch() {
  final Map<String, Object?> record = _jGood(
    rollCount: 5,
    mul: 11,
    add: 5,
    gameId: 'aaaaaaaaaaaaaaaa',
    statedGameId: 'bbbbbbbbbbbbbbbb',
    clientSeeds: '0:mismatch-seed-a|1:mismatch-seed-b',
  );
  record['seeds'] = <Map<String, Object?>>[
    <String, Object?>{'seat': 0, 'seed': 'mismatch-seed-a', 'origin': 'player'},
    <String, Object?>{'seat': 1, 'seed': 'mismatch-seed-b', 'origin': 'player'},
  ];
  return record;
}

// ---------------------------------------------------------------------
// CSS helpers.
// ---------------------------------------------------------------------

/// class name -> merged declarations of every rule whose selector list names
/// that class (later rules win; specificity is not modelled).
Map<String, Map<String, String>> _declarationsByClass(String css) {
  final Map<String, Map<String, String>> out = <String, Map<String, String>>{};
  for (final RegExpMatch rule
      in RegExp(r'([^{}]+)\{([^}]*)\}').allMatches(css)) {
    final Map<String, String> decls = <String, String>{};
    for (final String d in rule.group(2)!.split(';')) {
      final int colon = d.indexOf(':');
      if (colon > 0) {
        decls[d.substring(0, colon).trim().toLowerCase()] =
            d.substring(colon + 1).trim();
      }
    }
    for (final String selector in rule.group(1)!.split(',')) {
      for (final RegExpMatch c
          in RegExp(r'\.(verify-[\w-]+)(?![\w-])').allMatches(selector)) {
        out.putIfAbsent(c.group(1)!, () => <String, String>{}).addAll(decls);
      }
    }
  }
  return out;
}

double _channel(int v) {
  final double s = v / 255;
  return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(String hex) {
  final int v = int.parse(hex.substring(1), radix: 16);
  return 0.2126 * _channel((v >> 16) & 0xff) +
      0.7152 * _channel((v >> 8) & 0xff) +
      0.0722 * _channel(v & 0xff);
}

/// WCAG contrast ratio of [hex] against #ffffff.
double _contrastOnWhite(String hex) => 1.05 / (_luminance(hex) + 0.05);

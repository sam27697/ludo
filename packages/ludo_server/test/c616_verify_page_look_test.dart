// Tests for contract C-616 (work/ludo/orders/616-verify-page-plain-verdict.md),
// decisions D1 to D6: the verify pages and the not-found page wear the room
// page's look, the verdict leads as a block on the card, the table folds
// under one closed <details id="proof"> that verify.js opens on any failure,
// and the language switch is a 3 rem tap target.
//
// Written from the contract, not from the implementation. The real
// buildVerifyPageHtml / buildVerifyNotFoundHtml output is parsed with a small
// tag-tree reader and a small CSS reader built below (package:html is not a
// dependency of this package, and this file may not change pubspec.yaml). The
// CSS reader knows tag, class and id selectors with the descendant and child
// combinators, selector specificity, source order and !important; a selector
// using anything else (pseudo-classes, attribute selectors, custom
// properties) is ignored, so a rule written that way is reported as missing
// rather than guessed at.
//
// D4 runs the real served verify.js under a real `node`, the way
// c613_verify_fail_state_test.dart does (that file explains the `vm` context),
// with its DOM stub extended by a #proof element whose `open` state can be
// read back. This file fails loudly rather than skipping when `node` is
// missing.
//
// Nothing here is random: every record is built from a fixed secret, so a
// failure reproduces by running the one test named in its message:
//   cd packages/ludo_server && dart test test/c616_verify_page_look_test.dart -N '<test name>'

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show pow;

import 'package:fair_dice/fair_dice.dart' show DiceChain, drawDie;
import 'package:ludo_server/ludo_server.dart'
    show
        buildVerifyNotFoundHtml,
        buildVerifyPageHtml,
        verifyJsSource,
        verifyRecordFormat;
import 'package:test/test.dart';

const List<String> _langs = <String>['en', 'ar'];

const String _gameId = 'c616c616c616c616';
const String _clientSeeds = '0:c616-seed-alice|1:c616-seed-server';

const String _okGreen = '#1b5e20';
const String _failRed = '#b3261e';

// ---------------------------------------------------------------------
// The contract's words, per language. Everything except `proofSummary` is
// copied from the base page, which D2, D3 and D6 say stays word for word.
// ---------------------------------------------------------------------

class _Words {
  const _Words({
    required this.title,
    required this.h1,
    required this.lead,
    required this.notChecked,
    required this.noscript,
    required this.finished,
    required this.proves,
    required this.doesNotProve,
    required this.commitment,
    required this.seeds,
    required this.rolls,
    required this.checkYourself,
    required this.retention,
    required this.proofSummary,
    required this.switchHref,
    required this.switchText,
    required this.nfTitle,
    required this.nfH1,
    required this.nfParagraph,
  });

  final String title;
  final String h1;
  final String lead;
  final String notChecked;
  final String noscript;
  final String finished;
  final String proves;
  final String doesNotProve;
  final String commitment;
  final String seeds;
  final String rolls;
  final String checkYourself;
  final String retention;
  final String proofSummary;
  final String switchHref;
  final String switchText;
  final String nfTitle;
  final String nfH1;
  final String nfParagraph;
}

const Map<String, _Words> _words = <String, _Words>{
  'en': _Words(
    title: 'Verify game $_gameId - Ludo RNG',
    h1: 'Game $_gameId',
    lead: 'Every roll of this game is verifiable: the server committed to all '
        'of them before the game began, and this page checks each one in '
        'your browser.',
    notChecked: 'not checked',
    noscript: 'This page checks the rolls with JavaScript, which is off in '
        'this browser. The checks below can also be run with verify.py.',
    finished: 'Finished 2026-03-02T00:00:00Z UTC. Winner:',
    proves: 'What this proves',
    doesNotProve: 'What this does not prove',
    commitment: 'Commitment',
    seeds: 'Seeds',
    rolls: 'Rolls',
    checkYourself: 'Check it yourself',
    retention: 'This record is kept for 90 days after the game ends.',
    proofSummary: 'Show every roll and how to check it yourself',
    switchHref: '?lang=ar',
    switchText: 'العربية',
    nfTitle: 'Record not found - Ludo RNG',
    nfH1: 'No record for this id',
    nfParagraph: 'There is no verification record for this id. Records are '
        'kept for 90 days after the game they belong to ends.',
  ),
  'ar': _Words(
    title: 'التحقق من اللعبة $_gameId - Ludo RNG',
    h1: 'اللعبة $_gameId',
    lead: 'كل رمية في هذه اللعبة قابلة للتحقق: الخادم ثبّتها كلها قبل أن '
        'تبدأ اللعبة، وهذه الصفحة تفحص كل واحدة منها في متصفحك.',
    notChecked: 'لم يتم التحقق بعد',
    noscript: 'تفحص هذه الصفحة الرميات بجافاسكربت، وهي معطلة في هذا '
        'المتصفح. يمكن أيضاً تشغيل الفحوص أدناه بـ verify.py.',
    finished: 'انتهت في 2026-03-02T00:00:00Z UTC. الفائز:',
    proves: 'ما الذي تثبته هذه الصفحة',
    doesNotProve: 'ما الذي لا تثبته',
    commitment: 'التثبيت',
    seeds: 'البذور',
    rolls: 'الرميات',
    checkYourself: 'تحقق بنفسك',
    retention: 'يُحفظ هذا السجل 90 يومًا بعد انتهاء اللعبة.',
    proofSummary: 'اعرض كل رمية وطريقة التحقق منها بنفسك',
    switchHref: '?lang=en',
    switchText: 'English',
    nfTitle: 'السجل غير موجود - Ludo RNG',
    nfH1: 'لا يوجد سجل بهذا المعرّف',
    nfParagraph: 'لا يوجد سجل تحقق بهذا المعرّف. تُحفظ السجلات 90 يومًا '
        'بعد انتهاء اللعبة التي تخصها.',
  ),
};

/// The #summary data attributes the script reads (C-613): D2 says they are
/// kept, with their words.
const Map<String, Map<String, String>> _summaryData =
    <String, Map<String, String>>{
  'en': <String, String>{
    'data-ok': 'checked: all {n} rolls verified',
    'data-fail': 'Check failed: {reason}.',
    'data-reason-format': 'this record is in a format this page does not know',
    'data-reason-client-seeds':
        'the players\' seeds in the record disagree with each other',
    'data-reason-roll-sequence':
        'the rolls in the record are missing or out of order',
    'data-reason-mismatch':
        'at least one roll does not match what the server committed to',
    'data-reason-error': 'this browser could not run the check',
  },
  'ar': <String, String>{
    'data-ok': 'تم التحقق: كل الرميات ({n}) سليمة',
    'data-fail': 'فشل الفحص: {reason}.',
    'data-reason-format': 'سجل اللعبة بصيغة لا تعرفها هذه الصفحة',
    'data-reason-client-seeds': 'بذور اللاعبين في السجل لا تتفق مع بعضها',
    'data-reason-roll-sequence': 'رميات السجل ناقصة أو بغير ترتيبها',
    'data-reason-mismatch': 'رمية واحدة على الأقل لا تطابق ما ثبّته الخادم',
    'data-reason-error': 'تعذّر على هذا المتصفح إجراء الفحص',
  },
};

// ---------------------------------------------------------------------
// Fixtures: records in the shape of docs/VERIFY.md section 1.1.
// ---------------------------------------------------------------------

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
        'seed': 'c616-seed-alice',
        'origin': 'player',
      },
      <String, Object?>{
        'seat': 1,
        'seed': 'c616-seed-server',
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

Map<String, Object?> _dieAltered(int k) {
  final Map<String, Object?> record = _deepCopy(_goodRecord());
  final Map<String, Object?> roll = _rollsOf(record)[k - 1];
  final int die = roll['die']! as int;
  roll['die'] = die == 6 ? 1 : die + 1;
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

// ---------------------------------------------------------------------
// A small tag-tree reader.
// ---------------------------------------------------------------------

const Set<String> _voidTags = <String>{
  'meta',
  'link',
  'br',
  'hr',
  'img',
  'input',
  'area',
  'base',
  'col',
  'source',
  'wbr',
};

class _Node {
  _Node(this.tag, this.attrs, this.start, this.parent);

  /// Lower-case tag name; `#text` for text, `#root` for the document.
  final String tag;
  final Map<String, String> attrs;

  /// Offset of the node's first character in the source: document order.
  final int start;
  final _Node? parent;
  final List<_Node> children = <_Node>[];

  /// Decoded text of a `#text` node, raw source of a script or style body.
  String text = '';

  bool get isElement => !tag.startsWith('#');

  Set<String> get classes => (attrs['class'] ?? '')
      .split(RegExp(r'\s+'))
      .where((String c) => c != '')
      .toSet();

  Iterable<_Node> get elements sync* {
    for (final _Node c in children) {
      if (c.isElement) {
        yield c;
        yield* c.elements;
      }
    }
  }

  List<_Node> get elementChildren =>
      children.where((_Node c) => c.isElement).toList();

  bool isInside(_Node ancestor) {
    for (_Node? n = parent; n != null; n = n.parent) {
      if (identical(n, ancestor)) {
        return true;
      }
    }
    return false;
  }

  /// Whitespace-collapsed visible text, scripts and styles left out.
  String get textContent {
    final StringBuffer buf = StringBuffer();
    void walk(_Node n) {
      if (n.tag == '#text') {
        buf.write(n.text);
      } else if (n.tag != 'script' && n.tag != 'style') {
        n.children.forEach(walk);
      }
    }

    walk(this);
    return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  String toString() => '<$tag ${jsonEncode(attrs)}>';
}

String _decodeEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', '\'')
    .replaceAll('&#x27;', '\'')
    .replaceAll('&amp;', '&');

final RegExp _tokenRe = RegExp(
  r'<!--.*?-->|<!DOCTYPE[^>]*>|</(\w+)\s*>|<(\w+)((?:"[^"]*"|'
  "'[^']*'"
  r'|[^>"\x27])*)>',
  caseSensitive: false,
  dotAll: true,
);

final RegExp _attrRe = RegExp(
  r'([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|' "'([^']*)'" r'|([^\s>]+)))?',
);

_Node _parse(String html) {
  final _Node root = _Node('#root', <String, String>{}, 0, null);
  _Node cur = root;
  int pos = 0;
  void addText(int from, int to) {
    if (to > from) {
      final String raw = html.substring(from, to);
      if (raw.trim().isNotEmpty) {
        final _Node t = _Node('#text', <String, String>{}, from, cur)
          ..text = _decodeEntities(raw);
        cur.children.add(t);
      }
    }
  }

  for (final RegExpMatch m in _tokenRe.allMatches(html)) {
    if (m.start < pos) {
      continue;
    }
    addText(pos, m.start);
    pos = m.end;
    final String? closing = m.group(1);
    final String? opening = m.group(2);
    if (closing != null) {
      final String name = closing.toLowerCase();
      _Node? target;
      for (_Node? n = cur; n != null && n.tag != '#root'; n = n.parent) {
        if (n.tag == name) {
          target = n;
          break;
        }
      }
      if (target != null) {
        cur = target.parent!;
      }
    } else if (opening != null) {
      final String name = opening.toLowerCase();
      final String attrText = m.group(3) ?? '';
      final Map<String, String> attrs = <String, String>{};
      for (final RegExpMatch a in _attrRe.allMatches(attrText)) {
        attrs[a.group(1)!.toLowerCase()] =
            _decodeEntities(a.group(2) ?? a.group(3) ?? a.group(4) ?? '');
      }
      final _Node n = _Node(name, attrs, m.start, cur);
      cur.children.add(n);
      if (name == 'script' || name == 'style') {
        final int close = html.toLowerCase().indexOf('</$name>', pos);
        final int end = close < 0 ? html.length : close;
        n.text = html.substring(pos, end);
        pos = close < 0 ? html.length : close + name.length + 3;
      } else if (!_voidTags.contains(name) &&
          !attrText.trimRight().endsWith('/')) {
        cur = n;
      }
    }
  }
  addText(pos, html.length);
  return root;
}

// ---------------------------------------------------------------------
// A small CSS reader: selectors, specificity, cascade.
// ---------------------------------------------------------------------

class _Compound {
  _Compound(this.tag, this.ids, this.classes);
  final String? tag;
  final List<String> ids;
  final List<String> classes;
}

class _Selector {
  _Selector(this.parts, this.combinators);
  final List<_Compound> parts;

  /// combinators[i] sits between parts[i] and parts[i + 1]: ' ' or '>'.
  final List<String> combinators;

  List<int> get specificity => <int>[
        parts.fold<int>(0, (int a, _Compound c) => a + c.ids.length),
        parts.fold<int>(0, (int a, _Compound c) => a + c.classes.length),
        parts.fold<int>(0, (int a, _Compound c) => a + (c.tag == null ? 0 : 1)),
      ];
}

final RegExp _compoundRe = RegExp(r'^([a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)$');

_Selector? _parseSelector(String text) {
  final String spaced = text.trim().replaceAll(RegExp(r'\s*>\s*'), ' > ');
  if (spaced.isEmpty) {
    return null;
  }
  final List<_Compound> parts = <_Compound>[];
  final List<String> combs = <String>[];
  String pending = ' ';
  for (final String tok in spaced.split(RegExp(r'\s+'))) {
    if (tok == '>') {
      pending = '>';
      continue;
    }
    final RegExpMatch? m = _compoundRe.firstMatch(tok);
    if (m == null) {
      return null;
    }
    final List<String> ids = <String>[];
    final List<String> classes = <String>[];
    for (final RegExpMatch p
        in RegExp(r'([.#])([\w-]+)').allMatches(m.group(2) ?? '')) {
      (p.group(1) == '#' ? ids : classes).add(p.group(2)!);
    }
    if (parts.isNotEmpty) {
      combs.add(pending);
    }
    pending = ' ';
    parts.add(_Compound(m.group(1)?.toLowerCase(), ids, classes));
  }
  return _Selector(parts, combs);
}

class _Decl {
  _Decl(this.prop, this.value, this.important, this.spec, this.order);
  final String prop;
  final String value;
  final bool important;
  final List<int> spec;
  final int order;
}

class _Rule {
  _Rule(this.selectors, this.decls);
  final List<_Selector> selectors;
  final List<MapEntry<String, String>> decls;
}

List<_Rule> _parseCss(String css) {
  final String bare = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final List<_Rule> rules = <_Rule>[];
  for (final RegExpMatch m
      in RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(bare)) {
    final String sel = m.group(1)!.trim();
    if (sel.startsWith('@')) {
      continue;
    }
    final List<_Selector> sels = <_Selector>[
      for (final String part in sel.split(','))
        if (_parseSelector(part) != null) _parseSelector(part)!,
    ];
    final List<MapEntry<String, String>> decls = <MapEntry<String, String>>[
      for (final String d in m.group(2)!.split(';'))
        if (d.contains(':'))
          MapEntry<String, String>(
            d.substring(0, d.indexOf(':')).trim().toLowerCase(),
            d.substring(d.indexOf(':') + 1).trim(),
          ),
    ];
    rules.add(_Rule(sels, decls));
  }
  return rules;
}

int _cmpSpec(List<int> a, List<int> b) {
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return a[i].compareTo(b[i]);
    }
  }
  return 0;
}

class _Page {
  _Page(this.html) {
    root = _parse(html);
    final List<_Node> styles =
        root.elements.where((_Node n) => n.tag == 'style').toList();
    styleCount = styles.length;
    css = styles.map((_Node s) => s.text).join('\n');
    rules = _parseCss(css);
  }

  final String html;
  late final _Node root;
  late final int styleCount;
  late final String css;
  late final List<_Rule> rules;

  Iterable<_Node> all(String tag) =>
      root.elements.where((_Node n) => n.tag == tag);

  _Node? byId(String id) {
    for (final _Node n in root.elements) {
      if (n.attrs['id'] == id) {
        return n;
      }
    }
    return null;
  }

  _Node? get card {
    for (final _Node n in all('main')) {
      if (n.classes.contains('card')) {
        return n;
      }
    }
    return null;
  }

  bool _compoundMatches(
      _Compound c, _Node n, Set<String> extra, _Node subject) {
    if (c.tag != null && c.tag != n.tag) {
      return false;
    }
    for (final String id in c.ids) {
      if (n.attrs['id'] != id) {
        return false;
      }
    }
    final Set<String> have =
        identical(n, subject) ? <String>{...n.classes, ...extra} : n.classes;
    return c.classes.every(have.contains);
  }

  bool _matchFrom(
      _Selector s, int i, _Node n, Set<String> extra, _Node subject) {
    if (!_compoundMatches(s.parts[i], n, extra, subject)) {
      return false;
    }
    if (i == 0) {
      return true;
    }
    if (s.combinators[i - 1] == '>') {
      final _Node? p = n.parent;
      return p != null &&
          p.isElement &&
          _matchFrom(s, i - 1, p, extra, subject);
    }
    for (_Node? p = n.parent; p != null && p.isElement; p = p.parent) {
      if (_matchFrom(s, i - 1, p, extra, subject)) {
        return true;
      }
    }
    return false;
  }

  /// The declarations that apply to [n] (optionally with [extra] classes on
  /// it), in cascade order: later entries win.
  List<MapEntry<String, String>> declsFor(
    _Node n, {
    Set<String> extra = const <String>{},
  }) {
    final List<_Decl> hits = <_Decl>[];
    int order = 0;
    for (final _Rule r in rules) {
      List<int>? best;
      for (final _Selector s in r.selectors) {
        if (_matchFrom(s, s.parts.length - 1, n, extra, n)) {
          if (best == null || _cmpSpec(s.specificity, best) > 0) {
            best = s.specificity;
          }
        }
      }
      for (final MapEntry<String, String> d in r.decls) {
        order++;
        if (best != null) {
          final bool important = d.value.contains('!important');
          hits.add(_Decl(
            d.key,
            d.value.replaceAll('!important', '').trim(),
            important,
            best,
            order,
          ));
        }
      }
    }
    hits.sort((_Decl a, _Decl b) {
      if (a.important != b.important) {
        return a.important ? 1 : -1;
      }
      final int c = _cmpSpec(a.spec, b.spec);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    return <MapEntry<String, String>>[
      for (final _Decl d in hits) MapEntry<String, String>(d.prop, d.value),
    ];
  }

  String? valueOf(_Node n, String prop,
      {Set<String> extra = const <String>{}}) {
    String? out;
    for (final MapEntry<String, String> e in declsFor(n, extra: extra)) {
      if (e.key == prop) {
        out = e.value;
      }
    }
    return out;
  }

  /// A property that inherits: the nearest ancestor-or-self that sets it.
  String? inheritedValue(_Node n, String prop,
      {Set<String> extra = const <String>{}}) {
    for (_Node? c = n; c != null && c.isElement; c = c.parent) {
      final String? v =
          valueOf(c, prop, extra: identical(c, n) ? extra : const <String>{});
      if (v != null) {
        return v;
      }
    }
    return null;
  }
}

// ---------------------------------------------------------------------
// Colours.
// ---------------------------------------------------------------------

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;

  String get hex => '#${<int>[
        r,
        g,
        b
      ].map((int v) => v.toRadixString(16).padLeft(2, '0')).join()}';

  double get luminance {
    double lin(int v) {
      final double s = v / 255;
      return s <= 0.03928
          ? s / 12.92
          : pow((s + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  }

  @override
  String toString() => hex;
}

final RegExp _colourRe = RegExp(
  r'#[0-9a-fA-F]{8}\b|#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b|rgba?\([^)]*\)|\b(white|black|transparent|currentcolor)\b',
  caseSensitive: false,
);

/// The last colour written in [value], blended over [backdrop] when it is
/// translucent; null when there is none (or it is `currentcolor` or clear).
_Rgb? _colourIn(String value, {_Rgb backdrop = const _Rgb(255, 255, 255)}) {
  final Iterable<RegExpMatch> ms = _colourRe.allMatches(value);
  if (ms.isEmpty) {
    return null;
  }
  final String t = ms.last.group(0)!.toLowerCase();
  if (t == 'white') {
    return const _Rgb(255, 255, 255);
  }
  if (t == 'black') {
    return const _Rgb(0, 0, 0);
  }
  if (t == 'transparent' || t == 'currentcolor') {
    return null;
  }
  if (t.startsWith('rgb')) {
    final List<double> p = RegExp(r'[\d.]+')
        .allMatches(t)
        .map((RegExpMatch m) => double.parse(m.group(0)!))
        .toList();
    final double a = p.length > 3 ? p[3] : 1;
    int mix(double f, int under) => (f * a + under * (1 - a)).round();
    return _Rgb(
        mix(p[0], backdrop.r), mix(p[1], backdrop.g), mix(p[2], backdrop.b));
  }
  String h = t.substring(1);
  if (h.length == 3) {
    h = h.split('').map((String c) => '$c$c').join();
  }
  int part(int i) => int.parse(h.substring(i, i + 2), radix: 16);
  return _Rgb(part(0), part(2), part(4));
}

double _contrast(_Rgb a, _Rgb b) {
  final double la = a.luminance;
  final double lb = b.luminance;
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

extension on _Page {
  /// The last colour among [props] in the cascade for [n], gradients skipped.
  _Rgb? colourOf(
    _Node n,
    List<String> props, {
    Set<String> extra = const <String>{},
    _Rgb backdrop = const _Rgb(255, 255, 255),
  }) {
    _Rgb? out;
    for (final MapEntry<String, String> e in declsFor(n, extra: extra)) {
      if (props.contains(e.key) && !e.value.contains('gradient(')) {
        final _Rgb? c = _colourIn(e.value, backdrop: backdrop);
        if (c != null) {
          out = c;
        }
      }
    }
    return out;
  }

  /// The colour the text of [n] is painted in.
  _Rgb? textColour(_Node n, {Set<String> extra = const <String>{}}) {
    final String? v = inheritedValue(n, 'color', extra: extra);
    return v == null ? const _Rgb(0, 0, 0) : _colourIn(v);
  }

  /// The colour painted behind [n]: its own background, else the nearest
  /// ancestor's, else the card's, else white.
  _Rgb backgroundBehind(_Node n, {Set<String> extra = const <String>{}}) {
    for (_Node? c = n; c != null && c.isElement; c = c.parent) {
      final _Rgb? bg = colourOf(
        c,
        <String>['background', 'background-color'],
        extra: identical(c, n) ? extra : const <String>{},
      );
      if (bg != null) {
        return bg;
      }
    }
    return const _Rgb(255, 255, 255);
  }
}

// ---------------------------------------------------------------------
// The node driver: c613's, with a #proof element whose open state is kept.
// ---------------------------------------------------------------------

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
  let isOpen = false;
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
  if (spec.tag === 'details') {
    // The property and the attribute are one state, as in a browser.
    Object.defineProperty(el, 'open', {
      get: () => isOpen,
      set: (v) => { isOpen = !!v; },
      enumerable: true,
    });
    el.setAttribute = (n, v) => { if (n === 'open') isOpen = true; };
    el.removeAttribute = (n) => { if (n === 'open') isOpen = false; };
    el.hasAttribute = (n) => n === 'open' && isOpen;
    el.getAttribute = (n) => (n === 'open' && isOpen ? '' : null);
    el.toggleAttribute = (n, force) => {
      if (n !== 'open') return false;
      isOpen = force === undefined ? !isOpen : !!force;
      return isOpen;
    };
  }
  el.__classes = classes;
  el.__text = () => text;
  el.__open = () => isOpen;
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
  const proof = els['proof'];
  const out = {
    timedOut: timedOut,
    loadError: loadError,
    errors: errors,
    summary: summary
      ? { text: summary.__text(), classes: Array.from(summary.__classes) }
      : null,
    proof: proof ? { open: proof.__open() } : null,
  };
  process.stdout.write(JSON.stringify(out), () => process.exit(0));
})();
''';

/// Elements of [html] that carry an id: attributes, tag and text.
Map<String, Map<String, Object?>> _elementsById(String html) {
  final Map<String, Map<String, Object?>> out =
      <String, Map<String, Object?>>{};
  for (final _Node n in _parse(html).elements) {
    final String? id = n.attrs['id'];
    if (id != null) {
      out[id] = <String, Object?>{
        'tag': n.tag,
        'attrs': n.attrs,
        'text': n.tag == 'script' ? n.text : n.textContent,
      };
    }
  }
  return out;
}

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
  Map<String, Object?>? get proof => raw['proof'] as Map<String, Object?>?;
  bool get proofPresent => proof != null;
  bool get proofOpen => (proof?['open'] as bool?) ?? false;
  bool get threw =>
      raw['loadError'] != null || (raw['errors']! as List<Object?>).isNotEmpty;

  String get why => 'scenario: $scenario | summary text: "$text" | summary '
      'classes: $classes | #proof: ${proof == null ? 'absent' : proof!['open'] == true ? 'open' : 'closed'} '
      '| timedOut: $timedOut | load error: ${raw['loadError']} | script '
      'errors: ${raw['errors']} | reproduce: cd packages/ludo_server && dart '
      'test test/c616_verify_page_look_test.dart -N \'$scenario\' (fixtures '
      'are fixed, there is no seed)';
}

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

int _inputSeq = 0;

// ---------------------------------------------------------------------
// Assertion helpers that always say what, which scenario, how to rerun.
// ---------------------------------------------------------------------

String _why(String scenario, String expected) => 'expected $expected | '
    'scenario: $scenario | reproduce: cd packages/ludo_server && dart test '
    'test/c616_verify_page_look_test.dart -N \'$scenario\' (fixtures are '
    'fixed, there is no seed)';

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();

bool _hasPadding(_Page p, _Node n, {Set<String> extra = const <String>{}}) {
  for (final MapEntry<String, String> e in p.declsFor(n, extra: extra)) {
    if (e.key.startsWith('padding') &&
        !RegExp(r'^0(\.0+)?(px|rem|em)?(\s+0(\.0+)?(px|rem|em)?)*$')
            .hasMatch(e.value)) {
      return true;
    }
  }
  return false;
}

/// The border colour of [n] as the cascade leaves it: `border` and
/// `border-color` read in cascade order.
_Rgb? _borderColour(_Page p, _Node n, {Set<String> extra = const <String>{}}) {
  _Rgb? out;
  for (final MapEntry<String, String> e in p.declsFor(n, extra: extra)) {
    if (e.key == 'border' || e.key == 'border-color') {
      if (e.key == 'border' && RegExp(r'^(none|0)\b').hasMatch(e.value)) {
        out = null;
        continue;
      }
      if (e.value.toLowerCase().contains('currentcolor')) {
        out = p.textColour(n, extra: extra);
        continue;
      }
      final _Rgb? c = _colourIn(e.value);
      if (c != null) {
        out = c;
      }
    }
  }
  return out;
}

bool _hasBorder(_Page p, _Node n, {Set<String> extra = const <String>{}}) {
  bool shorthand = false;
  bool width = false;
  bool style = false;
  for (final MapEntry<String, String> e in p.declsFor(n, extra: extra)) {
    if (e.key == 'border') {
      shorthand = !RegExp(r'^(none|0)\b').hasMatch(e.value);
    } else if (e.key == 'border-width') {
      width = !RegExp(r'^0').hasMatch(e.value);
    } else if (e.key == 'border-style') {
      style = e.value != 'none';
    }
  }
  return shorthand || (width && style);
}

void main() {
  late Directory tempDir;
  late File driverFile;

  setUpAll(() async {
    await _requireInterpreter('node');
    tempDir = Directory.systemTemp.createTempSync('c616_verify_page_look_');
    driverFile = File('${tempDir.path}${Platform.pathSeparator}driver.js')
      ..writeAsStringSync(_driverSource);
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  _Page verifyPage(String lang, {Map<String, Object?>? record}) => _Page(
        buildVerifyPageHtml(jsonEncode(record ?? _goodRecord()),
            language: lang),
      );

  _Page notFoundPage(String lang) =>
      _Page(buildVerifyNotFoundHtml(language: lang));

  Future<_Outcome> run(
    String scenario,
    String lang,
    Map<String, Object?> record, {
    String crypto = 'real',
    String Function(String html)? editHtml,
  }) async {
    String html = buildVerifyPageHtml(jsonEncode(record), language: lang);
    if (editHtml != null) {
      html = editHtml(html);
    }
    final File inputFile = File(
      '${tempDir.path}${Platform.pathSeparator}in_${_inputSeq++}.json',
    )..writeAsStringSync(jsonEncode(<String, Object?>{
        'elements': _elementsById(html),
        'verifyJs': verifyJsSource,
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
  // The look shared by all three pages (D1), checked once per page.
  // -------------------------------------------------------------------

  void expectRoomLook(_Page p, String maxWidth, String scenario) {
    final _Node? html = p.all('html').isEmpty ? null : p.all('html').first;
    final _Node? body = p.all('body').isEmpty ? null : p.all('body').first;
    expect(html, isNotNull, reason: _why(scenario, 'an <html> element'));
    expect(body, isNotNull, reason: _why(scenario, 'a <body> element'));
    expect(
      p.colourOf(html!, <String>['background', 'background-color'])?.hex,
      '#0a3d38',
      reason: _why(scenario, '<html> background #0A3D38'),
    );
    final String? gradient = p
        .declsFor(body!)
        .where((MapEntry<String, String> e) =>
            e.key == 'background' || e.key == 'background-image')
        .map((MapEntry<String, String> e) => e.value)
        .fold<String?>(null, (String? a, String v) => v);
    expect(
      _norm(gradient ?? ''),
      _norm('linear-gradient(160deg, #0A3D38, #14665C)'),
      reason: _why(scenario,
          '<body> background linear-gradient(160deg, #0A3D38, #14665C), got "${gradient ?? 'none'}"'),
    );
    final List<_Node> mains = p.all('main').toList();
    expect(mains.length, 1,
        reason: _why(scenario, 'exactly one <main>, found ${mains.length}'));
    final _Node? card = p.card;
    expect(card, isNotNull,
        reason: _why(scenario, 'a <main class="card"> element'));
    expect(
      p.colourOf(card!, <String>['background', 'background-color'])?.hex,
      '#f7fbfa',
      reason: _why(scenario, 'card background #F7FBFA'),
    );
    expect(p.valueOf(card, 'border-radius'), '1.25rem',
        reason: _why(scenario, 'card border-radius 1.25rem'));
    expect(p.textColour(card)?.hex, '#0a2a27',
        reason: _why(scenario, 'card text colour #0A2A27'));
    expect(p.valueOf(card, 'max-width'), maxWidth,
        reason: _why(scenario, 'card max-width $maxWidth'));
    expect(p.css, contains('#0A3D38'),
        reason: _why(scenario, 'the <style> text to contain #0A3D38'));
    expect(p.css, contains('#14665C'),
        reason: _why(scenario, 'the <style> text to contain #14665C'));
    expect(p.css, contains('#F7FBFA'),
        reason: _why(scenario, 'the <style> text to contain #F7FBFA'));
    expect(p.styleCount, 1,
        reason: _why(scenario,
            'one <style> element (D6: style stays in the one element), found ${p.styleCount}'));
    final List<_Node> kids = card.elementChildren;
    expect(kids, isNotEmpty,
        reason: _why(scenario, 'the card to have content'));
    final _Node seats = kids.first;
    expect(seats.classes, contains('seats'),
        reason: _why(scenario,
            'the card\'s first child to be the .seats row, got ${seats}'));
    expect(seats.attrs['aria-hidden'], 'true',
        reason: _why(scenario, '.seats aria-hidden="true"'));
    final List<_Node> dots = seats.elementChildren;
    expect(dots.length, 4,
        reason: _why(scenario, 'four seat dots, found ${dots.length}'));
    expect(dots.every((_Node d) => d.tag == 'span'), isTrue,
        reason: _why(scenario, 'the four seat dots to be <span> elements'));
    final List<String?> dotColours = <String?>[
      for (final _Node d in dots)
        p.colourOf(d, <String>['background', 'background-color'])?.hex ??
            (d.attrs['style'] == null
                ? null
                : _colourIn(d.attrs['style']!)?.hex),
    ];
    expect(dotColours.contains(null), isFalse,
        reason: _why(scenario,
            'every seat dot to have a background colour, got $dotColours'));
    expect(dotColours.toSet().length, 4,
        reason:
            _why(scenario, 'four distinct seat dot colours, got $dotColours'));
  }

  /// Table cells and `code` stay readable on the card (D1): their colours
  /// are re-chosen, so not the white-page values, and the text on them keeps
  /// 4.5:1.
  void expectCardTablesReadable(_Page p, String scenario) {
    final _Node card = p.card!;
    final _Rgb cardBg = p.colourOf(card, <String>['background'])!;
    final List<_Node> cells = p.all('td').toList();
    expect(cells, isNotEmpty,
        reason: _why(scenario, 'table cells on the page'));
    final _Node td = cells.first;
    final _Rgb? border = _borderColour(p, td);
    expect(border, isNotNull,
        reason:
            _why(scenario, 'a readable cell border colour for td, none found'));
    expect(border!.hex, isNot('#cccccc'),
        reason: _why(scenario,
            'the cell border re-chosen for the card, still the white-page #ccc'));
    expect(border.hex, isNot(cardBg.hex),
        reason: _why(scenario,
            'a cell border that differs from the card background ${cardBg.hex}'));
    expect(
      _contrast(p.textColour(td)!, p.backgroundBehind(td)),
      greaterThanOrEqualTo(4.5),
      reason: _why(scenario, 'cell text at 4.5:1 or better on its background'),
    );
    final List<_Node> codes = p.all('code').toList();
    expect(codes, isNotEmpty,
        reason: _why(scenario, '<code> elements on the page'));
    for (final _Node code in codes) {
      final _Rgb? bg =
          p.colourOf(code, <String>['background', 'background-color']);
      expect(bg, isNotNull,
          reason: _why(scenario, 'a background colour on <code>, none found'));
      expect(bg!.hex, isNot('#f2f2f2'),
          reason: _why(scenario,
              'the <code> background re-chosen for the card, still the white-page #f2f2f2'));
      expect(bg.hex, isNot(cardBg.hex),
          reason: _why(scenario,
              'a <code> background that differs from the card background ${cardBg.hex}'));
      expect(
        _contrast(p.textColour(code)!, bg),
        greaterThanOrEqualTo(4.5),
        reason: _why(scenario,
            '<code> text at 4.5:1 or better on its background ${bg.hex}, text ${p.textColour(code)}'),
      );
    }
  }

  /// D5: the switch is a 3 rem tap target and keeps its words.
  void expectSwitch(_Page p, _Words w, String scenario) {
    final List<_Node> links = p
        .all('a')
        .where((_Node a) => (a.attrs['href'] ?? '').startsWith('?lang='))
        .toList();
    expect(links.length, 1,
        reason:
            _why(scenario, 'exactly one language link, found ${links.length}'));
    final _Node a = links.first;
    expect(a.attrs['href'], w.switchHref,
        reason: _why(scenario, 'the switch to keep href ${w.switchHref}'));
    expect(a.textContent, w.switchText,
        reason: _why(scenario, 'the switch to keep its text ${w.switchText}'));
    expect(p.valueOf(a, 'display'), 'inline-flex',
        reason: _why(scenario, 'the switch link display: inline-flex'));
    expect(p.valueOf(a, 'min-height'), '3rem',
        reason: _why(scenario, 'the switch link min-height: 3rem'));
    expect(_hasPadding(p, a), isTrue,
        reason: _why(scenario, 'padding on the switch link'));
    final _Node h1 = p.all('h1').first;
    expect(a.start, lessThan(h1.start),
        reason: _why(scenario, 'the switch at the top, before the <h1>'));
    // End edge: the nearest text-align on the link or an ancestor says
    // `end`, or the link is pushed with flex end / an auto inline-start margin.
    String? align;
    bool pushed = false;
    for (_Node? n = a; n != null && n.isElement; n = n.parent) {
      align ??= p.valueOf(n, 'text-align');
      final String? jc = p.valueOf(n, 'justify-content');
      final String? ms = p.valueOf(n, 'margin-inline-start');
      if (jc == 'flex-end' || jc == 'end' || ms == 'auto') {
        pushed = true;
      }
    }
    expect(align == 'end' || pushed, isTrue,
        reason: _why(scenario,
            'the switch aligned to the end edge (text-align: end, or flex end), nearest text-align was "$align"'));
  }

  // -------------------------------------------------------------------
  // (a) D1: the room page's look, per language.
  // -------------------------------------------------------------------

  for (final String lang in _langs) {
    final _Words w = _words[lang]!;

    group('D1 look, $lang verify page', () {
      final String a1 =
          '(a) $lang: the verify page wears the room look on one card of 48rem with the seats row first';
      test(a1, () {
        final _Page p = verifyPage(lang);
        expectRoomLook(p, '48rem', a1);
      });

      final String a2 =
          '(a) $lang: #summary, both tables and the details are inside main.card';
      test(a2, () {
        final _Page p = verifyPage(lang);
        final _Node? card = p.card;
        expect(card, isNotNull,
            reason: _why(a2, 'a <main class="card"> element'));
        final _Node? summary = p.byId('summary');
        expect(summary, isNotNull, reason: _why(a2, 'a #summary element'));
        expect(summary!.isInside(card!), isTrue,
            reason: _why(a2, '#summary inside main.card'));
        final List<_Node> tables = p.all('table').toList();
        expect(tables.length, 2,
            reason:
                _why(a2, 'two tables (seeds, rolls), found ${tables.length}'));
        for (final _Node t in tables) {
          expect(t.isInside(card), isTrue,
              reason: _why(a2, 'every table inside main.card'));
        }
        final List<_Node> details = p.all('details').toList();
        expect(details.length, 1,
            reason: _why(a2, 'exactly one <details>, found ${details.length}'));
        expect(details.first.isInside(card), isTrue,
            reason: _why(a2, 'the <details> inside main.card'));
        expect(p.all('h1').first.isInside(card), isTrue,
            reason: _why(a2, 'the <h1> inside main.card'));
      });

      final String a3 =
          '(a) $lang: tables and code stay readable on the card (border and code background re-chosen, 4.5:1 text)';
      test(a3, () {
        final _Page p = verifyPage(lang);
        expect(p.card, isNotNull,
            reason: _why(a3, 'a <main class="card"> element'));
        expectCardTablesReadable(p, a3);
      });

      final String a4 =
          '(a) $lang: the page keeps its title, language and no inline script (D6)';
      test(a4, () {
        final String html =
            buildVerifyPageHtml(jsonEncode(_goodRecord()), language: lang);
        final _Page p = _Page(html);
        expect(p.all('title').first.textContent, w.title,
            reason: _why(a4, 'the <title> unchanged: ${w.title}'));
        expect(p.all('html').first.attrs['lang'], lang,
            reason: _why(a4, '<html lang="$lang">'));
        expect(p.all('html').first.attrs['dir'], lang == 'ar' ? 'rtl' : isNull,
            reason: _why(a4, '<html dir> rtl for ar, absent for en'));
        final List<_Node> scripts = p.all('script').toList();
        final List<String> shapes = <String>[
          for (final _Node s in scripts)
            '${s.attrs['type'] ?? ''}|${s.attrs['id'] ?? ''}|${s.attrs['src'] ?? ''}',
        ];
        expect(shapes, <String>['application/json|record|', '||/v/verify.js'],
            reason: _why(a4,
                'only the #record JSON script and the /v/verify.js tag, got $shapes'));
      });
    });

    // -----------------------------------------------------------------
    // (b) D2 order and the verdict block.
    // -----------------------------------------------------------------

    group('D2 verdict, $lang verify page', () {
      final String b1 =
          '(b) $lang: document order is h1, lead line, #summary, noscript, what this proves, #proof';
      test(b1, () {
        final _Page p = verifyPage(lang);
        final _Node h1 = p.all('h1').first;
        final _Node? lead =
            p.all('p').where((_Node n) => n.textContent == w.lead).firstOrNull;
        final _Node? summary = p.byId('summary');
        final _Node? noscript = p.all('noscript').firstOrNull;
        final _Node? proves = p
            .all('h2')
            .where((_Node n) => n.textContent == w.proves)
            .firstOrNull;
        final _Node? proof = p.byId('proof');
        expect(h1.textContent, w.h1,
            reason: _why(b1, '<h1> reading "${w.h1}"'));
        expect(lead, isNotNull,
            reason: _why(b1, 'the lead line "${w.lead}" in a <p>'));
        expect(summary, isNotNull, reason: _why(b1, 'a #summary element'));
        expect(noscript, isNotNull, reason: _why(b1, 'a <noscript> element'));
        expect(proves, isNotNull,
            reason: _why(b1, 'an <h2> reading "${w.proves}"'));
        expect(proof, isNotNull, reason: _why(b1, 'a #proof element'));
        final List<int> order = <int>[
          h1.start,
          lead!.start,
          summary!.start,
          noscript!.start,
          proves!.start,
          proof!.start,
        ];
        expect(order, orderedEquals(List<int>.from(order)..sort()),
            reason: _why(b1,
                'h1 < lead < #summary < noscript < proves heading < #proof, got source offsets $order'));
        expect(order.toSet().length, order.length,
            reason: _why(
                b1, 'six distinct elements in that order, offsets $order'));
        // "Right after the h1 and the lead line": nothing else sits between
        // the lead line and the verdict.
        final List<_Node> kids = summary.parent!.elementChildren;
        final int at = kids.indexWhere((_Node n) => identical(n, summary));
        expect(at, greaterThan(0),
            reason: _why(b1, '#summary to follow the lead line'));
        expect(kids[at - 1].textContent, w.lead,
            reason: _why(b1,
                'the element right before #summary to be the lead line, got ${kids[at - 1]}'));
      });

      final String b2 =
          '(b) $lang: noscript, finished line, proves and does-not-prove stay visible below #summary, outside #proof, words unchanged';
      test(b2, () {
        final _Page p = verifyPage(lang);
        final _Node? proof = p.byId('proof');
        final _Node? summary = p.byId('summary');
        expect(proof, isNotNull, reason: _why(b2, 'a #proof element'));
        expect(summary, isNotNull, reason: _why(b2, 'a #summary element'));
        final _Node? noscript = p.all('noscript').firstOrNull;
        expect(noscript?.textContent, w.noscript,
            reason: _why(b2, '<noscript> words unchanged: "${w.noscript}"'));
        final _Node? finished = p
            .all('p')
            .where((_Node n) => n.textContent.startsWith(w.finished))
            .firstOrNull;
        expect(finished, isNotNull,
            reason: _why(b2, 'a line starting "${w.finished}"'));
        final List<_Node> headings = <_Node>[
          for (final String t in <String>[w.proves, w.doesNotProve])
            p.all('h2').where((_Node n) => n.textContent == t).firstOrNull ??
                finished!,
        ];
        for (final String t in <String>[w.proves, w.doesNotProve]) {
          expect(
              p.all('h2').where((_Node n) => n.textContent == t), hasLength(1),
              reason: _why(b2, 'exactly one <h2> reading "$t"'));
        }
        for (final _Node n in <_Node>[noscript!, finished!, ...headings]) {
          expect(n.start, greaterThan(summary!.start),
              reason: _why(b2, '$n after #summary'));
          expect(n.isInside(proof!), isFalse,
              reason: _why(b2, '$n outside #proof'));
          expect(n.isInside(p.card!), isTrue,
              reason: _why(b2, '$n inside the card'));
        }
      });

      final String b3 =
          '(b) $lang: #summary keeps every data- attribute and its not-checked text, and no state class';
      test(b3, () {
        final _Page p = verifyPage(lang);
        final _Node? summary = p.byId('summary');
        expect(summary, isNotNull, reason: _why(b3, 'a #summary element'));
        final Map<String, String> data = <String, String>{
          for (final MapEntry<String, String> e in summary!.attrs.entries)
            if (e.key.startsWith('data-')) e.key: e.value,
        };
        expect(data, _summaryData[lang],
            reason:
                _why(b3, 'the seven C-613 data- attributes with their words'));
        expect(summary.textContent, w.notChecked,
            reason: _why(
                b3, '#summary text "${w.notChecked}" before the script runs'));
        expect(summary.classes, isNot(contains('verify-ok')),
            reason: _why(b3, 'no verify-ok before the check'));
        expect(summary.classes, isNot(contains('verify-fail')),
            reason: _why(b3, 'no verify-fail before the check'));
      });

      final String b4 =
          '(b) $lang: #summary is a block of 1.25rem bold text, padded, rounded 0.75rem, with a border; neutral until checked';
      test(b4, () {
        final _Page p = verifyPage(lang);
        final _Node? summary = p.byId('summary');
        expect(summary, isNotNull, reason: _why(b4, 'a #summary element'));
        final _Node s = summary!;
        expect(p.valueOf(s, 'font-size'), '1.25rem',
            reason: _why(b4, '#summary font-size 1.25rem'));
        final String? weight = p.valueOf(s, 'font-weight');
        expect(weight == '700' || weight == 'bold', isTrue,
            reason: _why(b4, '#summary font-weight 700, got "$weight"'));
        expect(_hasPadding(p, s), isTrue,
            reason: _why(b4, 'padding on #summary'));
        expect(p.valueOf(s, 'border-radius'), '0.75rem',
            reason: _why(b4, '#summary border-radius 0.75rem'));
        expect(_hasBorder(p, s), isTrue,
            reason: _why(b4, 'a border on #summary in the not-checked state'));
        final _Rgb? neutral = _borderColour(p, s);
        expect(neutral, isNotNull,
            reason: _why(b4, 'a readable neutral border colour on #summary'));
        expect(neutral!.hex, isNot(_okGreen),
            reason: _why(b4, 'a neutral (not green) border before the check'));
        expect(neutral.hex, isNot(_failRed),
            reason: _why(b4, 'a neutral (not red) border before the check'));
      });

      for (final MapEntry<String, String> state in <String, String>{
        'verify-ok': _okGreen,
        'verify-fail': _failRed,
      }.entries) {
        final String b5 =
            '(b) $lang: #summary.${state.key} has text and border ${state.value}';
        test(b5, () {
          final _Page p = verifyPage(lang);
          final _Node? summary = p.byId('summary');
          expect(summary, isNotNull, reason: _why(b5, 'a #summary element'));
          final Set<String> extra = <String>{state.key};
          expect(p.textColour(summary!, extra: extra)?.hex, state.value,
              reason:
                  _why(b5, 'text colour ${state.value} in state ${state.key}'));
          expect(_hasBorder(p, summary, extra: extra), isTrue,
              reason: _why(b5, 'a border in state ${state.key}'));
          expect(_borderColour(p, summary, extra: extra)?.hex, state.value,
              reason: _why(
                  b5, 'border colour ${state.value} in state ${state.key}'));
        });
      }

      final String e1 =
          '(e) $lang: verdict text colours keep 4.5:1 against the verdict block\'s own background';
      test(e1, () {
        final _Page p = verifyPage(lang);
        final _Node? summary = p.byId('summary');
        expect(summary, isNotNull, reason: _why(e1, 'a #summary element'));
        for (final MapEntry<String, String> state in <String, String>{
          'verify-ok': _okGreen,
          'verify-fail': _failRed,
          'not-checked': '',
        }.entries) {
          final Set<String> extra =
              state.key == 'not-checked' ? <String>{} : <String>{state.key};
          final _Rgb? text = p.textColour(summary!, extra: extra);
          expect(text, isNotNull,
              reason: _why(e1, 'a readable text colour in state ${state.key}'));
          final _Rgb bg = p.backgroundBehind(summary, extra: extra);
          final double ratio = _contrast(text!, bg);
          expect(ratio, greaterThanOrEqualTo(4.5),
              reason: _why(e1,
                  'contrast >= 4.5 for ${state.key}: text $text on block background $bg, measured ${ratio.toStringAsFixed(2)}'));
        }
      });
    });

    // -----------------------------------------------------------------
    // (c) D3: the fold.
    // -----------------------------------------------------------------

    group('D3 fold, $lang verify page', () {
      final String c1 =
          '(c) $lang: #proof is a closed <details> whose first child is the <summary> with the exact words';
      test(c1, () {
        final _Page p = verifyPage(lang);
        final _Node? proof = p.byId('proof');
        expect(proof, isNotNull, reason: _why(c1, 'a #proof element'));
        expect(proof!.tag, 'details',
            reason: _why(c1, '#proof to be a <details>, got <${proof.tag}>'));
        expect(proof.attrs.containsKey('open'), isFalse,
            reason: _why(c1,
                '#proof closed by default (no open attribute), got ${proof.attrs}'));
        final List<_Node> kids = proof.elementChildren;
        expect(kids, isNotEmpty, reason: _why(c1, '#proof to have content'));
        expect(kids.first.tag, 'summary',
            reason: _why(c1,
                'the first child of #proof to be <summary>, got ${kids.first}'));
        expect(kids.first.textContent, w.proofSummary,
            reason: _why(c1, '<summary> reading exactly "${w.proofSummary}"'));
        expect(p.all('summary'), hasLength(1),
            reason: _why(c1, 'exactly one <summary>'));
      });

      final String c2 =
          '(c) $lang: the <summary> is a 3rem flex-centred tap target';
      test(c2, () {
        final _Page p = verifyPage(lang);
        final _Node? summary = p.all('summary').firstOrNull;
        expect(summary, isNotNull, reason: _why(c2, 'a <summary> element'));
        expect(p.valueOf(summary!, 'min-height'), '3rem',
            reason: _why(c2, '<summary> min-height: 3rem'));
        final String? display = p.valueOf(summary, 'display');
        expect(display == 'flex' || display == 'inline-flex', isTrue,
            reason: _why(c2, '<summary> display: flex, got "$display"'));
        expect(p.valueOf(summary, 'align-items'), 'center',
            reason: _why(c2, '<summary> align-items: center'));
      });

      final String c3 =
          '(c) $lang: the four headings, both tables, the commitment, the verify.py command and the source link are inside #proof in order';
      test(c3, () {
        final _Page p = verifyPage(lang);
        final _Node? proof = p.byId('proof');
        expect(proof, isNotNull, reason: _why(c3, 'a #proof element'));
        final _Node pf = proof!;
        final List<String> headings = <String>[
          for (final _Node h in p.all('h2'))
            if (h.isInside(pf)) h.textContent,
        ];
        expect(
            headings, <String>[w.commitment, w.seeds, w.rolls, w.checkYourself],
            reason: _why(c3,
                'the <h2>s inside #proof to be commitment, seeds, rolls, check-it-yourself in that order, got $headings'));
        final List<_Node> tables = p.all('table').toList();
        expect(tables, hasLength(2),
            reason: _why(c3, 'two tables on the page'));
        for (final _Node t in tables) {
          expect(t.isInside(pf), isTrue,
              reason: _why(c3, 'every table inside #proof'));
        }
        final _Node? rolls = p.byId('rolls-table');
        expect(rolls, isNotNull, reason: _why(c3, 'a #rolls-table element'));
        expect(rolls!.isInside(pf), isTrue,
            reason: _why(c3, '#rolls-table inside #proof'));
        expect(identical(tables.last, rolls), isTrue,
            reason: _why(c3, 'the seeds table before #rolls-table'));
        final _Node? commit = p
            .all('code')
            .where((_Node c) =>
                c.textContent == (_goodRecord()['chain_commit']! as String))
            .firstOrNull;
        expect(commit, isNotNull,
            reason: _why(c3, 'the chain commitment hex in a <code>'));
        expect(commit!.isInside(pf), isTrue,
            reason: _why(c3, 'the chain commitment inside #proof'));
        final _Node? command = p
            .all('code')
            .where((_Node c) =>
                c.textContent.contains('verify.py') &&
                c.textContent.contains('curl'))
            .firstOrNull;
        expect(command, isNotNull,
            reason: _why(c3, 'the curl ... verify.py command in a <code>'));
        expect(command!.isInside(pf), isTrue,
            reason: _why(c3, 'the verify.py command inside #proof'));
        expect(command.textContent, contains(_gameId),
            reason: _why(c3, 'the command naming game $_gameId'));
        final _Node? source = p
            .all('a')
            .where((_Node a) =>
                a.attrs['href'] == 'https://github.com/sam27697/ludo')
            .firstOrNull;
        expect(source, isNotNull,
            reason: _why(
                c3, 'the source link to https://github.com/sam27697/ludo'));
        expect(source!.isInside(pf), isTrue,
            reason: _why(c3, 'the source link inside #proof'));
        final List<int> offsets = <int>[
          commit.start,
          tables.first.start,
          rolls.start,
          command.start,
          source.start,
        ];
        expect(offsets, orderedEquals(List<int>.from(offsets)..sort()),
            reason: _why(c3,
                'commitment < seeds table < rolls table < command < source, got $offsets'));
      });

      final String c4 =
          '(c) $lang: every id, class and data attribute of the folded markup is unchanged';
      test(c4, () {
        final _Page p = verifyPage(lang);
        final _Node? proof = p.byId('proof');
        expect(proof, isNotNull, reason: _why(c4, 'a #proof element'));
        final _Node? rolls = p.byId('rolls-table');
        expect(rolls, isNotNull, reason: _why(c4, 'a #rolls-table element'));
        final Map<String, String> data = <String, String>{
          for (final MapEntry<String, String> e in rolls!.attrs.entries)
            if (e.key.startsWith('data-')) e.key: e.value,
        };
        expect(
          data,
          lang == 'en'
              ? <String, String>{
                  'data-match': 'checked: matches',
                  'data-mismatch': 'checked: does not match',
                }
              : <String, String>{
                  'data-match': 'تم الفحص: مطابق',
                  'data-mismatch': 'تم الفحص: غير مطابق',
                },
          reason: _why(c4, '#rolls-table data-match and data-mismatch words'),
        );
        for (int k = 1; k <= 5; k++) {
          for (final String id in <String>['chain-$k', 'die-$k']) {
            final _Node? cell = p.byId(id);
            expect(cell, isNotNull, reason: _why(c4, 'a #$id cell'));
            expect(cell!.isInside(proof!), isTrue,
                reason: _why(c4, '#$id inside #proof'));
          }
        }
        final Set<int> seats = <int>{
          for (final _Node td in p.all('td'))
            if (td.attrs['data-seat'] != null)
              int.parse(td.attrs['data-seat']!),
        };
        expect(seats, <int>{0, 1},
            reason: _why(c4, 'data-seat cells for seats 0 and 1 kept'));
      });

      final String c5 =
          '(c) $lang: the retention line, #record and the verify.js tag are outside #proof, after it';
      test(c5, () {
        final _Page p = verifyPage(lang);
        final _Node? proof = p.byId('proof');
        expect(proof, isNotNull, reason: _why(c5, 'a #proof element'));
        final _Node? retention = p
            .all('p')
            .where((_Node n) => n.textContent == w.retention)
            .firstOrNull;
        expect(retention, isNotNull,
            reason: _why(c5, 'the retention line "${w.retention}"'));
        final _Node? record = p.byId('record');
        expect(record, isNotNull, reason: _why(c5, 'a #record script'));
        final _Node? js = p
            .all('script')
            .where((_Node s) => s.attrs['src'] == '/v/verify.js')
            .firstOrNull;
        expect(js, isNotNull, reason: _why(c5, 'a /v/verify.js script tag'));
        for (final _Node n in <_Node>[retention!, record!, js!]) {
          expect(n.isInside(proof!), isFalse,
              reason: _why(c5, '$n outside #proof'));
          expect(n.start, greaterThan(proof.start),
              reason: _why(c5, '$n after #proof in the document'));
        }
        expect(retention.isInside(p.card!), isTrue,
            reason: _why(c5, 'the retention line inside the card'));
        expect(record.text, jsonEncode(_goodRecord()),
            reason: _why(c5, '#record JSON unchanged'));
      });
    });
  }

  // -------------------------------------------------------------------
  // (d) D4: verify.js opens #proof on any failure, leaves it on a pass.
  // -------------------------------------------------------------------

  group('D4 verify.js opens #proof', () {
    for (final String lang in _langs) {
      final Map<String, String> data = _summaryData[lang]!;
      final String Function(String) failLine = (String reasonKey) =>
          data['data-fail']!
              .replaceAll('{reason}', data['data-reason-$reasonKey']!);

      void expectSettled(_Outcome o) {
        expect(o.timedOut, isFalse,
            reason:
                'the summary never reached verify-ok or verify-fail; ${o.why}');
        expect(o.threw, isFalse,
            reason: 'the script threw or left an unhandled error; ${o.why}');
      }

      void expectFailLine(_Outcome o, String reasonKey) {
        expect(o.classes, contains('verify-fail'),
            reason: 'expected the fail state; ${o.why}');
        expect(o.text, '✗ ${failLine(reasonKey)}',
            reason: 'expected the C-613 fail line for "$reasonKey"; ${o.why}');
      }

      final String d1 =
          '(d) $lang: a valid record passes and #proof stays closed';
      test(d1, () async {
        final _Outcome o = await run(d1, lang, _goodRecord());
        expectSettled(o);
        expect(o.classes, contains('verify-ok'),
            reason: 'expected the pass state; ${o.why}');
        expect(o.text, '✓ ${data['data-ok']!.replaceAll('{n}', '5')}',
            reason: 'expected the C-613 pass line for 5 rolls; ${o.why}');
        expect(o.proofPresent, isTrue,
            reason: 'expected the served page to carry #proof; ${o.why}');
        expect(o.proofOpen, isFalse,
            reason: 'expected #proof closed after a pass; ${o.why}');
      });

      final Map<String, (Map<String, Object?>, String, String)> failures =
          <String, (Map<String, Object?>, String, String)>{
        'one die altered': (_dieAltered(3), 'real', 'mismatch'),
        'format unknown': (_formatTwo(), 'real', 'format'),
        'client seeds disagree': (_seedsDisagree(), 'real', 'client-seeds'),
        'roll out of order': (_rollOutOfOrder(), 'real', 'roll-sequence'),
        'odd-length reveal throws inside the check': (
          _oddLengthReveal(),
          'real',
          'error'
        ),
        'crypto.subtle absent': (_goodRecord(), 'noSubtle', 'error'),
        'no crypto global at all': (_goodRecord(), 'absent', 'error'),
      };
      for (final MapEntry<String, (Map<String, Object?>, String, String)> f
          in failures.entries) {
        final String d2 = '(d) $lang: ${f.key} fails and #proof is opened';
        test(d2, () async {
          final _Outcome o =
              await run(d2, lang, f.value.$1, crypto: f.value.$2);
          expectSettled(o);
          expectFailLine(o, f.value.$3);
          expect(o.proofPresent, isTrue,
              reason: 'expected the served page to carry #proof; ${o.why}');
          expect(o.proofOpen, isTrue,
              reason:
                  'expected #proof open after a failure ("${f.key}"); ${o.why}');
        });
      }

      String stripProof(String html) =>
          html.replaceAll(RegExp('\\sid=["\']proof["\']'), '');

      final String d3 =
          '(d) $lang: a failure on a page with no #proof still reaches the fail line without a throw';
      test(d3, () async {
        final _Outcome o =
            await run(d3, lang, _dieAltered(2), editHtml: stripProof);
        expectSettled(o);
        expectFailLine(o, 'mismatch');
        expect(o.proofPresent, isFalse,
            reason:
                'the test page should have no #proof element left; ${o.why}');
      });

      final String d4 =
          '(d) $lang: a crypto failure on a page with no #proof still reaches the error line without a throw';
      test(d4, () async {
        final _Outcome o = await run(d4, lang, _goodRecord(),
            crypto: 'noSubtle', editHtml: stripProof);
        expectSettled(o);
        expectFailLine(o, 'error');
        expect(o.proofPresent, isFalse,
            reason:
                'the test page should have no #proof element left; ${o.why}');
      });

      final String d5 =
          '(d) $lang: a pass on a page with no #proof still reaches the pass line without a throw';
      test(d5, () async {
        final _Outcome o =
            await run(d5, lang, _goodRecord(), editHtml: stripProof);
        expectSettled(o);
        expect(o.classes, contains('verify-ok'),
            reason: 'expected the pass state; ${o.why}');
        expect(o.text, '✓ ${data['data-ok']!.replaceAll('{n}', '5')}',
            reason: 'expected the C-613 pass line; ${o.why}');
        expect(o.proofPresent, isFalse,
            reason:
                'the test page should have no #proof element left; ${o.why}');
      });
    }
  });

  // -------------------------------------------------------------------
  // (f) D5 on the verify pages, (g) and D1 on the not-found page.
  // -------------------------------------------------------------------

  for (final String lang in _langs) {
    final _Words w = _words[lang]!;

    final String f1 =
        '(f) $lang: the verify page switch is inline-flex, 3rem, padded, with its href and text';
    test(f1, () {
      expectSwitch(verifyPage(lang), w, f1);
    });

    final String f2 =
        '(f) $lang: the not-found page switch is inline-flex, 3rem, padded, with its href and text';
    test(f2, () {
      expectSwitch(notFoundPage(lang), w, f2);
    });

    final String g1 =
        '(g) $lang: the not-found page is a 28rem room-look card with the seats row first';
    test(g1, () {
      expectRoomLook(notFoundPage(lang), '28rem', g1);
    });

    final String g2 =
        '(g) $lang: the not-found page keeps its title, h1 and paragraph word for word and has no fold';
    test(g2, () {
      final _Page p = notFoundPage(lang);
      expect(p.all('title').first.textContent, w.nfTitle,
          reason: _why(g2, 'the <title> "${w.nfTitle}"'));
      expect(p.all('h1').map((_Node h) => h.textContent).toList(),
          <String>[w.nfH1],
          reason: _why(g2, 'one <h1> reading "${w.nfH1}"'));
      expect(
        p.all('p').where((_Node n) => n.textContent == w.nfParagraph),
        hasLength(1),
        reason: _why(g2, 'the paragraph "${w.nfParagraph}"'),
      );
      expect(p.all('details'), isEmpty,
          reason: _why(g2, 'no <details> on the not-found page'));
      expect(p.all('h1').first.isInside(p.card ?? p.root), isTrue,
          reason: _why(g2, 'the <h1> inside main.card'));
      expect(
        p
            .all('p')
            .where((_Node n) => n.textContent == w.nfParagraph)
            .first
            .isInside(p.card ?? p.root),
        isTrue,
        reason: _why(g2, 'the paragraph inside main.card'),
      );
    });
  }
}

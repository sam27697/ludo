// Tests for contract C-619 (work/ludo/orders/619-verify-rolls-blocks-narrow.md),
// decisions D1 and D2 (D3 is measured in a browser by the integration, D4 is
// the freeze): on a phone the two tables of the verify page become one block
// per row, each cell carries its column header as `data-label`, and the label
// is drawn from it. Wide screens keep exactly the tables of C-618.
//
// Written from the contract, not from the implementation. The real
// buildVerifyPageHtml output is parsed with a small tag-tree reader and a
// small CSS reader (package:html is not a dependency of this package). The
// CSS reader is the one of c618_verify_table_wrap_test.dart with three
// additions: a rule inside `@media` is read and tagged with its condition; the
// cascade can be asked for the narrow view (the one `@media (max-width: 40rem)`
// block applies) or the wide view (it does not); and a `::before` pseudo
// element is a target of its own. Selector forms the reader does not know
// (attribute selectors, other pseudo-classes, `+` and `~` combinators) make a
// rule unreadable, and a test says so by name instead of guessing.
//
// Nothing here is random: every record is built from a fixed secret, so a
// failure reproduces by running the one test named in its message:
//   cd packages/ludo_server && dart test test/c619_verify_rolls_blocks_test.dart -N '<test name>'

import 'dart:convert';
import 'dart:math' show pow;

import 'package:fair_dice/fair_dice.dart' show DiceChain, drawDie;
import 'package:ludo_server/ludo_server.dart'
    show buildVerifyPageHtml, verifyRecordFormat;
import 'package:test/test.dart';

const List<String> _langs = <String>['en', 'ar'];

const String _gameId = 'c619c619c619c619';
const String _clientSeeds = '0:c619-seed-alice|1:c619-seed-server';

/// A seed as long as a real client seed can be: it has to break to fit.
final String _longSeed = List<String>.generate(
  16,
  (int i) => 'deadbeef$i'.padRight(12, 'c'),
).join();

// ---------------------------------------------------------------------
// Words of the base page, which D1 and D4 keep word for word.
// ---------------------------------------------------------------------

const Map<String, List<String>> _seedHeaders = <String, List<String>>{
  'en': <String>['Player', 'Seed', 'Origin'],
  'ar': <String>['اللاعب', 'البذرة', 'المصدر'],
};

const Map<String, List<String>> _rollHeaders = <String, List<String>>{
  'en': <String>[
    'k',
    'Player',
    'Die',
    'Reveal',
    'Chain check',
    'Die check',
  ],
  'ar': <String>[
    'k',
    'اللاعب',
    'النرد',
    'الكشف',
    'فحص السلسلة',
    'فحص النرد',
  ],
};

const Map<String, List<String>> _seatNames = <String, List<String>>{
  'en': <String>['Red', 'Green', 'Yellow', 'Blue'],
  'ar': <String>['الأحمر', 'الأخضر', 'الأصفر', 'الأزرق'],
};

/// The seats whose printed name is the longest in [lang]; the Arabic names are
/// all the same length, so more than one seat can tie.
List<int> _longestSeats(String lang) {
  final List<String> names = _seatNames[lang]!;
  final int longest =
      names.map((String n) => n.length).reduce((int a, int b) => a > b ? a : b);
  return <int>[
    for (int s = 0; s < names.length; s++)
      if (names[s].length == longest) s,
  ];
}

/// The `@media` condition D2 names, normalised the way [_normMedia] writes it.
const String _narrowMedia = '@media (max-width: 40rem)';

/// The rules of the C-618 base stylesheet that name a table, a th, a td,
/// `.hex` or `.table-scroll`, byte for byte as the base page prints them. D2
/// says that outside the media block nothing changes.
const List<String> _baseTableRules = <String>[
  'table {\n'
      '  border-collapse: collapse;\n'
      '  width: 100%;\n'
      '  margin-top: 0.5rem;\n'
      '  font-size: 0.9rem;\n'
      '}',
  'th, td {\n'
      '  border: 1px solid #B7CFCB;\n'
      '  padding: 0.3rem 0.5rem;\n'
      '  text-align: start;\n'
      '  vertical-align: top;\n'
      '}',
  'th, td:not(.hex) {\n'
      '  overflow-wrap: normal;\n'
      '  word-break: normal;\n'
      '}',
  'td.reveal {\n'
      '  font-family: monospace;\n'
      '}',
  '.hex {\n'
      '  overflow-wrap: anywhere;\n'
      '  word-break: break-all;\n'
      '}',
  '.table-scroll {\n'
      '  overflow-x: auto;\n'
      '}',
];

// ---------------------------------------------------------------------
// Fixtures: records in the shape of docs/VERIFY.md section 1.1.
// ---------------------------------------------------------------------

Map<String, Object?> _record({
  int rollCount = 5,
  List<Map<String, Object?>>? seeds,
  List<int>? rollSeats,
  String gameId = _gameId,
}) {
  final List<int> secret =
      List<int>.generate(32, (int i) => (i * 17 + 9) % 256);
  final DiceChain chain = DiceChain.build(secret);
  return <String, Object?>{
    'format': verifyRecordFormat,
    'game_id': gameId,
    'chain_commit': chain.commit,
    'chain_index': 0,
    'chain_length': chain.chainLength,
    'client_seeds': _clientSeeds,
    'seeds': seeds ??
        <Map<String, Object?>>[
          <String, Object?>{
            'seat': 0,
            'seed': 'c619-seed-alice',
            'origin': 'player',
          },
          <String, Object?>{
            'seat': 1,
            'seed': 'c619-seed-server',
            'origin': 'server',
          },
        ],
    'rolls': <Map<String, Object?>>[
      for (int k = 1; k <= rollCount; k++)
        <String, Object?>{
          'k': k,
          'seat': rollSeats != null
              ? rollSeats[(k - 1) % rollSeats.length]
              : (k.isOdd ? 0 : 1),
          'reveal': chain.reveal(k),
          'die': drawDie(chain.reveal(k), _gameId, _clientSeeds, k, 0),
        },
    ],
    'winner': 0,
    'finished_at': '2026-03-02T00:00:00Z',
  };
}

List<Map<String, Object?>> _fourSeeds() => <Map<String, Object?>>[
      for (int s = 0; s < 4; s++)
        <String, Object?>{
          'seat': s,
          'seed': s == 0 ? _longSeed : 'seed-$s',
          'origin': s.isEven ? 'player' : 'server',
        },
    ];

/// The records every structural test runs on: the plain one, four seats with a
/// seed long enough to need breaking, markup characters in a seed, no rolls at
/// all, exactly one roll, and rolls drawn only by the seats whose printed name
/// is the longest the page can print.
Map<String, Map<String, Object?>> _variantsFor(String lang) =>
    <String, Map<String, Object?>>{
      'five rolls': _record(),
      'four seats, long seed': _record(
        rollCount: 8,
        seeds: _fourSeeds(),
        rollSeats: <int>[0, 1, 2, 3],
      ),
      'markup in a seed': _record(
        seeds: <Map<String, Object?>>[
          <String, Object?>{
            'seat': 0,
            'seed': '<b>&amp;"x\'</b>',
            'origin': 'player',
          },
        ],
      ),
      'no rolls': _record(rollCount: 0),
      'one roll': _record(rollCount: 1),
      'longest seat name': _record(
        rollCount: 6,
        seeds: _fourSeeds(),
        rollSeats: _longestSeats(lang),
      ),
    };

// ---------------------------------------------------------------------
// A small tag-tree reader (the one of the C-618 test, copied).
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
    .replaceAllMapped(
      RegExp(r'&#(x[0-9a-fA-F]+|\d+);'),
      (Match m) {
        final String v = m.group(1)!;
        return String.fromCharCode(v.startsWith('x')
            ? int.parse(v.substring(1), radix: 16)
            : int.parse(v));
      },
    )
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
// A small CSS reader: selectors, specificity, media, cascade.
// ---------------------------------------------------------------------

class _Compound {
  _Compound(this.tag, this.ids, this.classes, this.nots, this.pseudo);
  final String? tag;
  final List<String> ids;
  final List<String> classes;

  /// The simple selectors inside `:not(...)`: `.x`, `#x` or a tag name.
  final List<String> nots;

  /// `before` or `after` when the compound ends in a pseudo element.
  final String? pseudo;
}

class _Selector {
  _Selector(this.parts, this.combinators);
  final List<_Compound> parts;

  /// combinators[i] sits between parts[i] and parts[i + 1]: ' ' or '>'.
  final List<String> combinators;

  /// The pseudo element the selector targets, null for the element itself.
  String? get pseudo => parts.last.pseudo;

  /// A `:not(x)` weighs what `x` weighs; a pseudo element weighs a tag.
  List<int> get specificity {
    int ids = 0;
    int classes = 0;
    int tags = 0;
    for (final _Compound c in parts) {
      ids += c.ids.length;
      classes += c.classes.length;
      tags += c.tag == null ? 0 : 1;
      tags += c.pseudo == null ? 0 : 1;
      for (final String n in c.nots) {
        if (n.startsWith('#')) {
          ids++;
        } else if (n.startsWith('.')) {
          classes++;
        } else {
          tags++;
        }
      }
    }
    return <int>[ids, classes, tags];
  }
}

final RegExp _compoundRe = RegExp(
  r'^([a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)((?::not\([.#]?[\w-]+\))*)(?:::?(before|after))?$',
);

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
    final List<String> nots = <String>[
      for (final RegExpMatch p
          in RegExp(r':not\(([.#]?[\w-]+)\)').allMatches(m.group(3) ?? ''))
        p.group(1)!,
    ];
    if (parts.isNotEmpty) {
      combs.add(pending);
    }
    pending = ' ';
    parts.add(_Compound(m.group(1)?.toLowerCase(), ids, classes, nots,
        m.group(4)?.toLowerCase()));
  }
  // A pseudo element can only end the selector.
  for (int i = 0; i < parts.length - 1; i++) {
    if (parts[i].pseudo != null) {
      return null;
    }
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
  _Rule(this.rawSelectors, this.selectors, this.decls, this.raw, this.media);

  /// The selector texts as written, one per comma part.
  final List<String> rawSelectors;

  /// The readable ones; shorter than [rawSelectors] when one is not understood.
  final List<_Selector> selectors;
  final List<MapEntry<String, String>> decls;

  /// The rule as written, from its first selector to its closing brace.
  final String raw;

  /// The normalised `@media` condition the rule sits in, null at top level.
  final String? media;

  bool get fullyReadable => selectors.length == rawSelectors.length;
}

String _normMedia(String prelude) => prelude
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\(\s*'), '(')
    .replaceAll(RegExp(r'\s*\)'), ')')
    .replaceAll(RegExp(r'\s*:\s*'), ': ')
    .trim()
    .toLowerCase();

/// Every rule of [css] in source order, rules inside `@media` included and
/// tagged with their condition. Other at-rules are skipped whole. [atRules]
/// collects the normalised prelude of every top-level at-rule met.
List<_Rule> _parseCss(String css, {List<String>? atRules}) {
  final String bare = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final List<_Rule> rules = <_Rule>[];

  void block(String text, String? media, bool top) {
    int depth = 0;
    int preludeStart = 0;
    int bodyStart = 0;
    String prelude = '';
    for (int i = 0; i < text.length; i++) {
      final String ch = text[i];
      if (ch == '{') {
        if (depth == 0) {
          prelude = text.substring(preludeStart, i).trim();
          bodyStart = i + 1;
        }
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          final String body = text.substring(bodyStart, i);
          final String raw = text.substring(preludeStart, i + 1).trim();
          preludeStart = i + 1;
          if (prelude.startsWith('@')) {
            if (top) {
              atRules?.add(_normMedia(prelude));
              if (prelude.toLowerCase().startsWith('@media')) {
                block(body, _normMedia(prelude), false);
              }
            }
            continue;
          }
          final List<String> rawSels = <String>[
            for (final String part in prelude.split(','))
              if (part.trim().isNotEmpty) part.trim(),
          ];
          final List<_Selector> sels = <_Selector>[
            for (final String part in rawSels)
              if (_parseSelector(part) != null) _parseSelector(part)!,
          ];
          final List<MapEntry<String, String>> decls =
              <MapEntry<String, String>>[
            for (final String d in body.split(';'))
              if (d.contains(':'))
                MapEntry<String, String>(
                  d.substring(0, d.indexOf(':')).trim().toLowerCase(),
                  d.substring(d.indexOf(':') + 1).trim(),
                ),
          ];
          rules.add(_Rule(rawSels, sels, decls, raw, media));
        }
      }
    }
  }

  block(bare, null, true);
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
    css = root.elements
        .where((_Node n) => n.tag == 'style')
        .map((_Node s) => s.text)
        .join('\n');
    rules = _parseCss(css, atRules: atRules);
  }

  final String html;
  late final _Node root;
  late final String css;
  final List<String> atRules = <String>[];
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

  bool _simpleMatches(String simple, _Node n) {
    if (simple.startsWith('.')) {
      return n.classes.contains(simple.substring(1));
    }
    if (simple.startsWith('#')) {
      return n.attrs['id'] == simple.substring(1);
    }
    return n.tag == simple.toLowerCase();
  }

  bool _compoundMatches(_Compound c, _Node n) {
    if (c.tag != null && c.tag != n.tag) {
      return false;
    }
    for (final String id in c.ids) {
      if (n.attrs['id'] != id) {
        return false;
      }
    }
    if (!c.classes.every(n.classes.contains)) {
      return false;
    }
    return !c.nots.any((String s) => _simpleMatches(s, n));
  }

  bool _matchFrom(_Selector s, int i, _Node n) {
    if (!_compoundMatches(s.parts[i], n)) {
      return false;
    }
    if (i == 0) {
      return true;
    }
    if (s.combinators[i - 1] == '>') {
      final _Node? p = n.parent;
      return p != null && p.isElement && _matchFrom(s, i - 1, p);
    }
    for (_Node? p = n.parent; p != null && p.isElement; p = p.parent) {
      if (_matchFrom(s, i - 1, p)) {
        return true;
      }
    }
    return false;
  }

  /// Whether a rule tagged [media] applies in the view asked for: the narrow
  /// view is the one the D2 condition matches, the wide view applies no media.
  bool _applies(String? media, bool narrow) =>
      media == null || (narrow && media == _narrowMedia);

  /// The declarations that apply to [n] (or to its [pseudo] element), in
  /// cascade order: later wins.
  List<MapEntry<String, String>> declsFor(
    _Node n, {
    bool narrow = false,
    String? pseudo,
  }) {
    final List<_Decl> hits = <_Decl>[];
    int order = 0;
    for (final _Rule r in rules) {
      List<int>? best;
      if (_applies(r.media, narrow)) {
        for (final _Selector s in r.selectors) {
          if (s.pseudo == pseudo && _matchFrom(s, s.parts.length - 1, n)) {
            if (best == null || _cmpSpec(s.specificity, best) > 0) {
              best = s.specificity;
            }
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

  String? valueOf(_Node n, String prop, {bool narrow = false, String? pseudo}) {
    String? out;
    for (final MapEntry<String, String> e
        in declsFor(n, narrow: narrow, pseudo: pseudo)) {
      if (e.key == prop) {
        out = e.value;
      }
    }
    return out;
  }

  /// A property that inherits: the nearest ancestor-or-self that sets it.
  String? inheritedValue(_Node n, String prop, {bool narrow = false}) {
    for (_Node? c = n; c != null && c.isElement; c = c.parent) {
      final String? v = valueOf(c, prop, narrow: narrow);
      if (v != null) {
        return v;
      }
    }
    return null;
  }

  /// `overflow-wrap` / `word-break` on [n] itself or the nearest ancestor that
  /// sets it; `normal` (the initial value of both) when none does.
  String wrapValue(_Node n, String prop, {bool narrow = false}) =>
      (inheritedValue(n, prop, narrow: narrow) ?? 'normal').toLowerCase();
}

// ---------------------------------------------------------------------
// Colours and contrast (WCAG 2 relative luminance).
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
  /// The last colour among [props] in the cascade for [n] (or its [pseudo]),
  /// gradients skipped.
  _Rgb? colourOf(
    _Node n,
    List<String> props, {
    bool narrow = false,
    String? pseudo,
    _Rgb backdrop = const _Rgb(255, 255, 255),
  }) {
    _Rgb? out;
    for (final MapEntry<String, String> e
        in declsFor(n, narrow: narrow, pseudo: pseudo)) {
      if (props.contains(e.key) && !e.value.contains('gradient(')) {
        final _Rgb? c = _colourIn(e.value, backdrop: backdrop);
        if (c != null) {
          out = c;
        }
      }
    }
    return out;
  }

  /// The colour painted behind the label of cell [td]: the pseudo element's own
  /// background, else the cell's, else the nearest ancestor's (the row, then up
  /// to the card), else white.
  _Rgb backgroundBehindLabel(_Node td) {
    final _Rgb? own = colourOf(td, <String>['background', 'background-color'],
        narrow: true, pseudo: 'before');
    if (own != null) {
      return own;
    }
    for (_Node? c = td; c != null && c.isElement; c = c.parent) {
      final _Rgb? bg =
          colourOf(c, <String>['background', 'background-color'], narrow: true);
      if (bg != null) {
        return bg;
      }
    }
    return const _Rgb(255, 255, 255);
  }

  /// The colour the label of [td] is painted in: the pseudo element's `color`,
  /// else what it inherits from the cell. An `opacity` below 1 on the pseudo
  /// element blends it into [bg].
  _Rgb labelColour(_Node td, _Rgb bg) {
    final String? own = valueOf(td, 'color', narrow: true, pseudo: 'before');
    final String? v = own ?? inheritedValue(td, 'color', narrow: true);
    final _Rgb c = v == null ? const _Rgb(0, 0, 0) : (_colourIn(v) ?? bg);
    final String? op = valueOf(td, 'opacity', narrow: true, pseudo: 'before');
    final double a = op == null ? 1 : (double.tryParse(op) ?? 1);
    if (a >= 1) {
      return c;
    }
    int mix(int f, int under) => (f * a + under * (1 - a)).round();
    return _Rgb(mix(c.r, bg.r), mix(c.g, bg.g), mix(c.b, bg.b));
  }
}

// ---------------------------------------------------------------------
// Assertion helpers that always say what, which scenario, how to rerun.
// ---------------------------------------------------------------------

String _why(String scenario, String expected) => 'expected $expected | '
    'scenario: $scenario | reproduce: cd packages/ludo_server && dart test '
    'test/c619_verify_rolls_blocks_test.dart -N \'$scenario\' (fixtures are '
    'fixed, there is no seed)';

String _where(_Node n) => '$n with text "${n.textContent}"';

/// The seeds table and the rolls table, in document order.
List<_Node> _tables(_Page p) => p.all('table').toList();

List<_Node> _cellsOf(_Node row, String tag) =>
    row.elementChildren.where((_Node c) => c.tag == tag).toList();

List<_Node> _bodyRows(_Node table) => <_Node>[
      for (final _Node tb in table.elementChildren)
        if (tb.tag == 'tbody')
          ...tb.elementChildren.where((_Node r) => r.tag == 'tr'),
    ];

List<_Node> _headerCells(_Node table) => <_Node>[
      for (final _Node th in table.elementChildren)
        if (th.tag == 'thead')
          for (final _Node r in th.elementChildren) ..._cellsOf(r, 'th'),
    ];

List<_Node> _theadsOf(_Node table) =>
    table.elementChildren.where((_Node c) => c.tag == 'thead').toList();

List<_Node> _tbodysOf(_Node table) =>
    table.elementChildren.where((_Node c) => c.tag == 'tbody').toList();

/// The chain commitment `<code>`: the one whose text is the commitment.
List<_Node> _chainCodes(_Page p, Map<String, Object?> record) => p
    .all('code')
    .where((_Node c) => c.textContent == record['chain_commit'])
    .toList();

/// Every element the C-618 contract says carries `hex`, for [record].
List<_Node> _expectedHex(_Page p, Map<String, Object?> record) {
  final List<_Node> tables = _tables(p);
  return <_Node>[
    ..._chainCodes(p, record),
    for (final _Node r in _bodyRows(tables[0])) _cellsOf(r, 'td')[1],
    for (final _Node r in _bodyRows(tables[1])) _cellsOf(r, 'td')[3],
  ];
}

List<_Node> _tdsAndThs(_Page p) => <_Node>[...p.all('th'), ...p.all('td')];

bool _hasHex(_Node n) => n.classes.contains('hex');

/// Every body cell of both tables with the header word of its column.
List<MapEntry<_Node, String>> _labelledCells(_Page p, String lang) {
  final List<_Node> tables = _tables(p);
  final List<List<String>> headers = <List<String>>[
    _seedHeaders[lang]!,
    _rollHeaders[lang]!,
  ];
  return <MapEntry<_Node, String>>[
    for (int t = 0; t < tables.length; t++)
      for (final _Node r in _bodyRows(tables[t]))
        for (final MapEntry<int, _Node> c in _cellsOf(r, 'td').asMap().entries)
          MapEntry<_Node, String>(c.value, headers[t][c.key]),
  ];
}

double? _lengthPx(String v) {
  final RegExpMatch? m = RegExp(r'^(-?[\d.]+)(px|rem|em)?$').firstMatch(v);
  return m == null ? null : double.parse(m.group(1)!);
}

/// Whether the value of a spacing property has a non-zero length in it.
bool _nonZeroSpace(String? v) {
  if (v == null) {
    return false;
  }
  return v
      .split(RegExp(r'\s+'))
      .any((String t) => (_lengthPx(t) ?? (t == 'auto' ? 1 : 0)) != 0);
}

/// What the cascade leaves of the border of [n]: whether one is drawn, and in
/// which colour. Reads `border`, `border-width`, `border-style` and
/// `border-color` (all sides at once); the per-side forms are not read.
class _Border {
  _Border(this.drawn, this.colour, this.written);
  final bool drawn;
  final _Rgb? colour;
  final String written;
}

_Border _borderOf(_Page p, _Node n) {
  String style = 'none';
  String width = 'medium';
  _Rgb? colour;
  final List<String> written = <String>[];
  for (final MapEntry<String, String> e in p.declsFor(n, narrow: true)) {
    if (e.key == 'border') {
      written.add('border: ${e.value}');
      style = 'none';
      width = 'medium';
      colour = null;
      for (final String t in e.value.split(RegExp(r'\s+(?![^(]*\))'))) {
        final String l = t.toLowerCase();
        if (RegExp(
                r'^(none|hidden|solid|dashed|dotted|double|groove|ridge|inset|outset)$')
            .hasMatch(l)) {
          style = l;
        } else if (RegExp(r'^(-?[\d.]+(px|rem|em)?|thin|medium|thick)$')
            .hasMatch(l)) {
          width = l;
        } else {
          colour = _colourIn(l) ?? colour;
        }
      }
      if (e.value.trim() == '0' || e.value.trim() == 'none') {
        style = 'none';
      }
    } else if (e.key == 'border-style') {
      written.add('border-style: ${e.value}');
      style = e.value.toLowerCase().split(RegExp(r'\s+')).first;
    } else if (e.key == 'border-width') {
      written.add('border-width: ${e.value}');
      width = e.value.toLowerCase().split(RegExp(r'\s+')).first;
    } else if (e.key == 'border-color') {
      written.add('border-color: ${e.value}');
      colour = _colourIn(e.value) ?? colour;
    }
  }
  final double? w = _lengthPx(width);
  final bool zero = w != null && w == 0;
  return _Border(style != 'none' && style != 'hidden' && !zero, colour,
      written.isEmpty ? 'nothing' : written.join('; '));
}

void main() {
  _Page verifyPage(String lang, Map<String, Object?> record) =>
      _Page(buildVerifyPageHtml(jsonEncode(record), language: lang));

  for (final String lang in _langs) {
    for (final MapEntry<String, Map<String, Object?>> v
        in _variantsFor(lang).entries) {
      final String tag = '$lang / ${v.key}';
      final Map<String, Object?> record = v.value;
      final int seedCount = (record['seeds']! as List<Object?>).length;
      final int rollCount = (record['rolls']! as List<Object?>).length;

      group('C-619 $tag', () {
        // -------------------------------------------------------------
        // (a) D1: every td carries data-label, the text of its column's th.
        // -------------------------------------------------------------

        final String a1 =
            '(a) $tag: every td of both tables carries data-label equal to the th text at its column index';
        test(a1, () {
          final _Page p = verifyPage(lang, record);
          final List<_Node> tables = _tables(p);
          expect(tables.length, 2,
              reason: _why(a1, 'two tables, found ${tables.length}'));
          expect(<String>[
            for (final _Node th in _headerCells(tables[0])) th.textContent
          ], _seedHeaders[lang],
              reason: _why(a1,
                  'the seeds headers to stay ${_seedHeaders[lang]}, they are the labels'));
          expect(<String>[
            for (final _Node th in _headerCells(tables[1])) th.textContent
          ], _rollHeaders[lang],
              reason: _why(a1,
                  'the rolls headers to stay ${_rollHeaders[lang]}, they are the labels'));
          expect(_bodyRows(tables[0]).length, seedCount,
              reason: _why(a1, '$seedCount seed rows'));
          expect(_bodyRows(tables[1]).length, rollCount,
              reason: _why(a1, '$rollCount roll rows'));
          final List<MapEntry<_Node, String>> cells = _labelledCells(p, lang);
          expect(cells.length, seedCount * 3 + rollCount * 6,
              reason: _why(a1,
                  '${seedCount * 3 + rollCount * 6} body cells (3 per seed row, 6 per roll row), found ${cells.length}'));
          for (final MapEntry<_Node, String> c in cells) {
            expect(c.key.attrs['data-label'], c.value,
                reason: _why(a1,
                    'data-label="${c.value}" (the text of that column\'s th, byte for byte) on ${_where(c.key)}, got ${c.key.attrs['data-label'] == null ? 'no data-label' : 'data-label="${c.key.attrs['data-label']}"'} (attributes ${c.key.attrs})'));
          }
        });

        final String a2 =
            '(a) $tag: no th and no element other than a td carries data-label, and no td sits outside the two tables';
        test(a2, () {
          final _Page p = verifyPage(lang, record);
          for (final _Node th in p.all('th')) {
            expect(th.attrs.containsKey('data-label'), isFalse,
                reason: _why(a2, 'no data-label on a th, got ${_where(th)}'));
          }
          for (final _Node n in p.root.elements) {
            if (n.tag != 'td' && n.attrs.containsKey('data-label')) {
              fail(_why(
                  a2, 'data-label only on td cells, found it on ${_where(n)}'));
            }
          }
          final List<_Node> tables = _tables(p);
          final int inTables = <_Node>[
            for (final _Node t in tables)
              for (final _Node r in _bodyRows(t)) ..._cellsOf(r, 'td'),
          ].length;
          expect(p.all('td').length, inTables,
              reason: _why(a2,
                  'every td inside a body row of the two tables ($inTables), found ${p.all('td').length} td elements'));
        });

        final String a3 =
            '(a) $tag: apart from data-label a cell keeps its text, id, data-seat, dir and classes';
        test(a3, () {
          final _Page p = verifyPage(lang, record);
          final String dir = lang == 'ar' ? 'ltr' : '';
          Map<String, String> noLabel(_Node c) =>
              <String, String>{...c.attrs}..remove('data-label');
          Map<String, String> withDir(Map<String, String> a) =>
              <String, String>{...a, if (dir != '') 'dir': dir};
          final List<_Node> tables = _tables(p);
          for (final _Node r in _bodyRows(tables[0])) {
            final List<_Node> c = _cellsOf(r, 'td');
            final String seat = c[0].attrs['data-seat'] ?? '';
            expect(noLabel(c[0]), <String, String>{'data-seat': seat},
                reason: _why(a3,
                    'the player cell to keep only data-seat, got ${noLabel(c[0])}'));
            expect(noLabel(c[1]), withDir(<String, String>{'class': 'hex'}),
                reason: _why(a3,
                    'the seed cell to keep class hex (and dir in Arabic), got ${noLabel(c[1])}'));
            expect(noLabel(c[2]), <String, String>{},
                reason: _why(a3,
                    'the origin cell to keep no attribute but data-label, got ${noLabel(c[2])}'));
          }
          for (final _Node r in _bodyRows(tables[1])) {
            final List<_Node> c = _cellsOf(r, 'td');
            final String k = c[0].textContent;
            final String seat = c[1].attrs['data-seat'] ?? '';
            expect(<Map<String, String>>[
              for (final _Node x in c) noLabel(x)
            ], <Map<String, String>>[
              withDir(<String, String>{}),
              <String, String>{'data-seat': seat},
              withDir(<String, String>{}),
              withDir(<String, String>{'class': 'reveal hex'}),
              <String, String>{'id': 'chain-$k'},
              <String, String>{'id': 'die-$k'},
            ],
                reason: _why(
                    a3, 'roll $k to keep its ids, data-seat, dir and classes'));
          }
        });

        // -------------------------------------------------------------
        // (b) D2: what the narrow view resolves.
        // -------------------------------------------------------------

        final String b1 =
            '(b) $tag: in the narrow view every thead inside #proof is display none';
        test(b1, () {
          final _Page p = verifyPage(lang, record);
          for (final _Node t in _tables(p)) {
            for (final _Node h in _theadsOf(t)) {
              expect(p.valueOf(h, 'display', narrow: true), 'none',
                  reason: _why(b1,
                      'display: none on the thead of ${t.attrs['id'] ?? 'the seeds table'} in the @media (max-width: 40rem) view, resolved ${p.valueOf(h, 'display', narrow: true) ?? 'nothing'}'));
            }
          }
        });

        final String b2 =
            '(b) $tag: in the narrow view every table and tbody inside #proof is display block';
        test(b2, () {
          final _Page p = verifyPage(lang, record);
          for (final _Node t in _tables(p)) {
            expect(p.valueOf(t, 'display', narrow: true), 'block',
                reason: _why(b2,
                    'display: block on ${t.attrs['id'] ?? 'the seeds table'} in the narrow view, resolved ${p.valueOf(t, 'display', narrow: true) ?? 'nothing'}'));
            for (final _Node b in _tbodysOf(t)) {
              expect(p.valueOf(b, 'display', narrow: true), 'block',
                  reason: _why(b2,
                      'display: block on the tbody of ${t.attrs['id'] ?? 'the seeds table'} in the narrow view, resolved ${p.valueOf(b, 'display', narrow: true) ?? 'nothing'}'));
            }
          }
        });

        final String b3 =
            '(b) $tag: in the narrow view every body tr is display flex with flex-wrap wrap';
        test(b3, () {
          final _Page p = verifyPage(lang, record);
          int rows = 0;
          for (final _Node t in _tables(p)) {
            for (final _Node r in _bodyRows(t)) {
              rows++;
              expect(p.valueOf(r, 'display', narrow: true), 'flex',
                  reason: _why(b3,
                      'display: flex on a body row of ${t.attrs['id'] ?? 'the seeds table'}, resolved ${p.valueOf(r, 'display', narrow: true) ?? 'nothing'}'));
              expect(p.valueOf(r, 'flex-wrap', narrow: true), 'wrap',
                  reason: _why(b3,
                      'flex-wrap: wrap on a body row of ${t.attrs['id'] ?? 'the seeds table'}, resolved ${p.valueOf(r, 'flex-wrap', narrow: true) ?? 'nothing'}'));
            }
          }
          expect(rows, seedCount + rollCount,
              reason: _why(b3, '${seedCount + rollCount} body rows checked'));
        });

        final String b4 =
            '(b) $tag: in the narrow view every td draws its data-label before its value';
        test(b4, () {
          final _Page p = verifyPage(lang, record);
          final RegExp content = RegExp(
              r'''^(?:(?:"[^"]*"|'[^']*')\s*)*attr\(\s*data-label\s*\)(?:\s*(?:"[^"]*"|'[^']*'))*$''');
          for (final MapEntry<_Node, String> c in _labelledCells(p, lang)) {
            final String? v =
                p.valueOf(c.key, 'content', narrow: true, pseudo: 'before');
            expect(v != null && content.hasMatch(v), isTrue,
                reason: _why(b4,
                    'td::before { content: attr(data-label) } (a separator string may sit beside it) on ${_where(c.key)} in the narrow view, resolved ${v ?? 'no ::before content'}'));
          }
        });

        final String b5 =
            '(b) $tag: in the narrow view a hex cell takes a whole line (flex-basis 100%) and is ordered after the other cells of its row';
        test(b5, () {
          final _Page p = verifyPage(lang, record);
          int hexCells = 0;
          for (final _Node t in _tables(p)) {
            for (final _Node r in _bodyRows(t)) {
              final List<_Node> cells = _cellsOf(r, 'td');
              int orderOf(_Node c) =>
                  int.tryParse(p.valueOf(c, 'order', narrow: true) ?? '0') ?? 0;
              final List<_Node> plain = <_Node>[
                for (final _Node c in cells)
                  if (!_hasHex(c)) c,
              ];
              final int plainMax = plain.isEmpty
                  ? 0
                  : plain.map(orderOf).reduce((int a, int b) => a > b ? a : b);
              for (final _Node c in cells.where(_hasHex)) {
                hexCells++;
                final String? basis = p.valueOf(c, 'flex-basis', narrow: true);
                final String? flex = p.valueOf(c, 'flex', narrow: true);
                final bool whole = basis == '100%' ||
                    (flex != null && flex.split(RegExp(r'\s+')).last == '100%');
                expect(whole, isTrue,
                    reason: _why(b5,
                        'flex-basis: 100% on ${_where(c)} in the narrow view, resolved flex-basis ${basis ?? 'nothing'}, flex ${flex ?? 'nothing'}'));
                expect(orderOf(c), greaterThan(plainMax),
                    reason: _why(b5,
                        'an order greater than ${plainMax} (the greatest of the plain cells of the row) on ${_where(c)}, resolved ${p.valueOf(c, 'order', narrow: true) ?? 'nothing (0)'}'));
              }
            }
          }
          expect(hexCells, seedCount + rollCount,
              reason: _why(b5,
                  '${seedCount + rollCount} hex body cells checked (one per row), found $hexCells'));
        });

        final String b6 =
            '(b) $tag: in the narrow view a row has a visible #B7CFCB border, room between rows and inner spacing, and its cells have no border of their own';
        test(b6, () {
          final _Page p = verifyPage(lang, record);
          for (final _Node t in _tables(p)) {
            for (final _Node r in _bodyRows(t)) {
              final _Border rb = _borderOf(p, r);
              expect(rb.drawn, isTrue,
                  reason: _why(b6,
                      'a drawn border round a body row, resolved ${rb.written}'));
              expect(rb.colour?.hex.toLowerCase(), '#b7cfcb',
                  reason: _why(b6,
                      'the row border in the existing #B7CFCB, resolved ${rb.colour} from ${rb.written}'));
              final bool gap = <String>[
                'margin',
                'margin-bottom',
                'margin-top',
                'margin-block',
                'margin-block-end',
                'margin-block-start',
              ].any((String k) => _nonZeroSpace(p.valueOf(r, k, narrow: true)));
              expect(gap, isTrue,
                  reason: _why(b6,
                      'a margin between rows on the tr (margin, margin-top or margin-bottom, non-zero) in the narrow view, none resolved'));
              final bool pad = <String>[
                'padding',
                'padding-top',
                'padding-bottom',
                'padding-block',
                'padding-inline',
                'padding-left',
                'padding-right',
              ].any((String k) => _nonZeroSpace(p.valueOf(r, k, narrow: true)));
              expect(pad, isTrue,
                  reason: _why(b6,
                      'inner spacing (non-zero padding) on the tr in the narrow view, none resolved'));
              for (final _Node c in _cellsOf(r, 'td')) {
                final _Border cb = _borderOf(p, c);
                expect(cb.drawn, isFalse,
                    reason: _why(b6,
                        'no border of its own on ${_where(c)} in the narrow view, resolved ${cb.written}'));
              }
            }
          }
        });

        final String b7 =
            '(b) $tag: in the wide view no thead is hidden, no table or row is a block or flex box, and no cell draws a label';
        test(b7, () {
          final _Page p = verifyPage(lang, record);
          for (final _Node t in _tables(p)) {
            expect(p.valueOf(t, 'display'), isNull,
                reason: _why(b7,
                    'no display on a table outside the media block, resolved ${p.valueOf(t, 'display')}'));
            for (final _Node h in _theadsOf(t)) {
              expect(p.valueOf(h, 'display'), isNull,
                  reason: _why(b7,
                      'no display on a thead outside the media block, resolved ${p.valueOf(h, 'display')}'));
            }
            for (final _Node b in _tbodysOf(t)) {
              expect(p.valueOf(b, 'display'), isNull,
                  reason: _why(b7,
                      'no display on a tbody outside the media block, resolved ${p.valueOf(b, 'display')}'));
            }
            for (final _Node r in _bodyRows(t)) {
              expect(p.valueOf(r, 'display'), isNull,
                  reason: _why(b7,
                      'no display on a tr outside the media block, resolved ${p.valueOf(r, 'display')}'));
              for (final _Node c in _cellsOf(r, 'td')) {
                expect(p.declsFor(c, pseudo: 'before'), isEmpty,
                    reason: _why(b7,
                        'no td::before outside the media block, got ${p.declsFor(c, pseudo: 'before')}'));
                expect(p.valueOf(c, 'order'), isNull,
                    reason: _why(b7,
                        'no order on a cell outside the media block, resolved ${p.valueOf(c, 'order')}'));
              }
            }
          }
        });

        // -------------------------------------------------------------
        // (c) D2 and C-618: the word rules hold in both views.
        // -------------------------------------------------------------

        final String c1 =
            '(c) $tag: in the narrow view no non-hex td, no th and no label breaks mid-word; hex still breaks anywhere';
        test(c1, () {
          final _Page p = verifyPage(lang, record);
          int plain = 0;
          for (final _Node n in _tdsAndThs(p)) {
            if (_hasHex(n)) {
              expect(p.wrapValue(n, 'overflow-wrap', narrow: true), 'anywhere',
                  reason: _why(c1,
                      'overflow-wrap: anywhere on ${_where(n)} in the narrow view'));
              expect(p.wrapValue(n, 'word-break', narrow: true), 'break-all',
                  reason: _why(c1,
                      'word-break: break-all on ${_where(n)} in the narrow view'));
              continue;
            }
            plain++;
            expect(p.wrapValue(n, 'overflow-wrap', narrow: true), 'normal',
                reason: _why(c1,
                    'overflow-wrap: normal on ${_where(n)} in the narrow view (a word never splits), resolved ${p.wrapValue(n, 'overflow-wrap', narrow: true)}'));
            expect(p.wrapValue(n, 'word-break', narrow: true), 'normal',
                reason: _why(c1,
                    'word-break: normal on ${_where(n)} in the narrow view, resolved ${p.wrapValue(n, 'word-break', narrow: true)}'));
            if (n.tag == 'td') {
              final String? ow =
                  p.valueOf(n, 'overflow-wrap', narrow: true, pseudo: 'before');
              final String? wb =
                  p.valueOf(n, 'word-break', narrow: true, pseudo: 'before');
              expect(ow == 'anywhere' || ow == 'break-word', isFalse,
                  reason: _why(c1,
                      'no overflow-wrap: $ow on the ::before label of ${_where(n)}'));
              expect(wb == 'break-all' || wb == 'break-word', isFalse,
                  reason: _why(c1,
                      'no word-break: $wb on the ::before label of ${_where(n)}'));
            }
          }
          expect(plain, greaterThan(0),
              reason: _why(c1, 'plain th and td cells to check'));
        });

        final String c2 =
            '(c) $tag: in the wide view the rules C-618 pinned resolve as before';
        test(c2, () {
          final _Page p = verifyPage(lang, record);
          int plain = 0;
          for (final _Node n in _tdsAndThs(p)) {
            if (_hasHex(n)) {
              expect(p.wrapValue(n, 'overflow-wrap'), 'anywhere',
                  reason: _why(
                      c2, 'overflow-wrap: anywhere on ${_where(n)} when wide'));
              expect(p.wrapValue(n, 'word-break'), 'break-all',
                  reason: _why(
                      c2, 'word-break: break-all on ${_where(n)} when wide'));
            } else {
              plain++;
              expect(p.wrapValue(n, 'overflow-wrap'), 'normal',
                  reason: _why(
                      c2, 'overflow-wrap: normal on ${_where(n)} when wide'));
              expect(p.wrapValue(n, 'word-break'), 'normal',
                  reason:
                      _why(c2, 'word-break: normal on ${_where(n)} when wide'));
            }
          }
          expect(plain, greaterThan(0),
              reason: _why(c2, 'plain th and td cells to check'));
          for (final _Node w in p
              .all('div')
              .where((_Node d) => d.classes.contains('table-scroll'))) {
            expect(p.valueOf(w, 'overflow-x'), 'auto',
                reason: _why(c2, 'overflow-x: auto on ${_where(w)} when wide'));
          }
        });

        // -------------------------------------------------------------
        // (d) D2: the label colour is readable on the row it sits on.
        // -------------------------------------------------------------

        final String d1 =
            '(d) $tag: in the narrow view the label colour has a contrast ratio of at least 4.5:1 against the row background';
        test(d1, () {
          final _Page p = verifyPage(lang, record);
          for (final MapEntry<_Node, String> c in _labelledCells(p, lang)) {
            expect(p.valueOf(c.key, 'color', narrow: true, pseudo: 'before'),
                isNotNull,
                reason: _why(d1,
                    'a muted colour of its own on the td::before label of ${_where(c.key)} in the narrow view, resolved none (the label would take the colour of the value)'));
            final _Rgb bg = p.backgroundBehindLabel(c.key);
            final _Rgb fg = p.labelColour(c.key, bg);
            final double ratio = _contrast(fg, bg);
            expect(ratio, greaterThanOrEqualTo(4.5),
                reason: _why(d1,
                    'label colour $fg on row background $bg to measure at least 4.5:1 on ${_where(c.key)}, measured ${ratio.toStringAsFixed(2)}:1'));
          }
        });

        final String d2 =
            '(d) $tag: the label stays readable on a cell the page script has marked verify-mismatch';
        test(d2, () {
          final _Page p = verifyPage(lang, record);
          for (final _Node c in p.all('td')) {
            final String id = c.attrs['id'] ?? '';
            if (id.startsWith('chain-') || id.startsWith('die-')) {
              c.attrs['class'] = 'verify-mismatch';
              expect(p.valueOf(c, 'color', narrow: true, pseudo: 'before'),
                  isNotNull,
                  reason: _why(d2,
                      'a muted colour of its own on the td::before label of $id in the narrow view, resolved none'));
              final _Rgb bg = p.backgroundBehindLabel(c);
              final _Rgb fg = p.labelColour(c, bg);
              final double ratio = _contrast(fg, bg);
              expect(ratio, greaterThanOrEqualTo(4.5),
                  reason: _why(d2,
                      'label colour $fg on $bg to measure at least 4.5:1 on $id carrying verify-mismatch, measured ${ratio.toStringAsFixed(2)}:1'));
            }
          }
        });

        final String d3 =
            '(d) $tag: in the narrow view the label is bold or semibold';
        test(d3, () {
          final _Page p = verifyPage(lang, record);
          for (final MapEntry<_Node, String> c in _labelledCells(p, lang)) {
            final String w = (p.valueOf(c.key, 'font-weight',
                        narrow: true, pseudo: 'before') ??
                    p.inheritedValue(c.key, 'font-weight', narrow: true) ??
                    'normal')
                .toLowerCase();
            final int? n = int.tryParse(w);
            expect(
                w == 'bold' || w == 'bolder' || (n != null && n >= 600), isTrue,
                reason: _why(d3,
                    'font-weight bold or 600 and above on the label of ${_where(c.key)}, resolved $w'));
          }
        });

        // -------------------------------------------------------------
        // (g) the failed-state mark keeps its colour in the narrow view (D4:
        // every colour C-616 chose stays, and the red mark must be on screen).
        // -------------------------------------------------------------

        final String g1 =
            '(g) $tag: in the narrow view a cell marked verify-mismatch still resolves the red #b3261e and bold';
        test(g1, () {
          final _Page p = verifyPage(lang, record);
          int marked = 0;
          for (final _Node c in p.all('td')) {
            final String id = c.attrs['id'] ?? '';
            if (id.startsWith('chain-') || id.startsWith('die-')) {
              marked++;
              c.attrs['class'] = 'verify-mismatch';
              final String? colour = p.valueOf(c, 'color', narrow: true);
              final String? weight = p.valueOf(c, 'font-weight', narrow: true);
              expect(colour?.toLowerCase(), '#b3261e',
                  reason: _why(g1,
                      'color #b3261e on $id carrying verify-mismatch in the narrow view, resolved ${colour ?? 'nothing'}'));
              expect(weight == 'bold' || weight == '700', isTrue,
                  reason: _why(g1,
                      'bold on $id carrying verify-mismatch in the narrow view, resolved ${weight ?? 'nothing'}'));
            }
          }
          expect(marked, rollCount * 2,
              reason: _why(g1,
                  '${rollCount * 2} chain and die cells (two per roll), found $marked'));
        });

        // -------------------------------------------------------------
        // (f) the ugly records: what stays hex, one roll, longest names.
        // -------------------------------------------------------------

        final String f1 =
            '(f) $tag: the seed value cells, the reveal cells and the chain commitment are the only elements with class hex';
        test(f1, () {
          final _Page p = verifyPage(lang, record);
          final List<_Node> allowed = _expectedHex(p, record);
          expect(allowed.length, 1 + seedCount + rollCount,
              reason: _why(f1,
                  '${1 + seedCount + rollCount} hex elements (commitment, seed values, reveals), found ${allowed.length}'));
          for (final _Node n in p.root.elements) {
            if (_hasHex(n) && !allowed.any((_Node a) => identical(a, n))) {
              fail(_why(f1,
                  'class hex only on the seed value cells, reveal cells and the chain commitment code, found it on ${_where(n)}'));
            }
          }
          for (final _Node n in allowed) {
            expect(_hasHex(n), isTrue,
                reason: _why(f1, 'class hex on ${_where(n)}'));
          }
        });
      });
    }

    // -----------------------------------------------------------------
    // Ugly cases that are not per-variant.
    // -----------------------------------------------------------------

    group('C-619 $lang extra', () {
      final String f2 =
          '(f) $lang: a record with one roll prints one block with six labelled cells';
      test(f2, () {
        final _Page p = _Page(buildVerifyPageHtml(
            jsonEncode(_record(rollCount: 1)),
            language: lang));
        final List<_Node> rows = _bodyRows(_tables(p)[1]);
        expect(rows.length, 1,
            reason: _why(f2, 'one roll row, found ${rows.length}'));
        final List<_Node> cells = _cellsOf(rows.single, 'td');
        expect(<String?>[for (final _Node c in cells) c.attrs['data-label']],
            _rollHeaders[lang],
            reason: _why(f2,
                'the six labels ${_rollHeaders[lang]} on the one roll row, in column order'));
      });

      final String f3 =
          '(f) $lang: a roll by the seat with the longest printed name keeps its data-seat, its colour swatch and the player label';
      test(f3, () {
        final List<int> seats = _longestSeats(lang);
        final _Page p = _Page(buildVerifyPageHtml(
            jsonEncode(_record(
                rollCount: seats.length * 2,
                seeds: _fourSeeds(),
                rollSeats: seats)),
            language: lang));
        final List<_Node> rows = _bodyRows(_tables(p)[1]);
        expect(rows.length, seats.length * 2,
            reason: _why(f3, '${seats.length * 2} roll rows'));
        for (int i = 0; i < rows.length; i++) {
          final _Node cell = _cellsOf(rows[i], 'td')[1];
          final int seat = seats[i % seats.length];
          expect(cell.textContent, _seatNames[lang]![seat],
              reason: _why(f3,
                  'the printed name ${_seatNames[lang]![seat]} (the label never enters the text), got ${_where(cell)}'));
          expect(cell.attrs['data-seat'], '$seat',
              reason: _why(f3, 'data-seat="$seat" kept, got ${cell.attrs}'));
          expect(cell.attrs['data-label'], _rollHeaders[lang]![1],
              reason: _why(f3,
                  'data-label="${_rollHeaders[lang]![1]}" on the player cell, got ${cell.attrs}'));
          expect(cell.elementChildren.length, 1,
              reason: _why(f3,
                  'the colour swatch span kept as the one child, got ${cell.elementChildren}'));
        }
      });

      // ---------------------------------------------------------------
      // (b) D2: the block itself.
      // ---------------------------------------------------------------

      final String e1 =
          '(b) $lang: the stylesheet holds exactly one @media block and its condition is (max-width: 40rem)';
      test(e1, () {
        final _Page p =
            _Page(buildVerifyPageHtml(jsonEncode(_record()), language: lang));
        final List<String> media = <String>[
          for (final String a in p.atRules)
            if (a.startsWith('@media')) a,
        ];
        expect(media, <String>[_narrowMedia],
            reason: _why(e1,
                'one @media (max-width: 40rem) block, found ${media.isEmpty ? 'none' : media}'));
        expect(p.rules.where((_Rule r) => r.media == _narrowMedia).length,
            greaterThan(0),
            reason: _why(e1, 'rules inside the media block'));
        expect(RegExp(r'@media').allMatches(p.css).length, 1,
            reason: _why(e1,
                'the text @media once in the stylesheet (nested or commented blocks do not count as the one)'));
      });

      final String e2 =
          '(b) $lang: every selector inside the media block is scoped to #proof';
      test(e2, () {
        final _Page p =
            _Page(buildVerifyPageHtml(jsonEncode(_record()), language: lang));
        final List<_Rule> inside =
            p.rules.where((_Rule r) => r.media != null).toList();
        expect(inside, isNotEmpty,
            reason: _why(e2, 'rules inside the media block'));
        for (final _Rule r in inside) {
          for (final String s in r.rawSelectors) {
            expect(s.contains('#proof'), isTrue,
                reason: _why(e2,
                    'selector "$s" inside the media block to name #proof (the block touches the two tables in #proof only)'));
          }
        }
      });

      final String e3 =
          '(b) $lang: every selector inside the media block is one this reader understands';
      test(e3, () {
        final _Page p =
            _Page(buildVerifyPageHtml(jsonEncode(_record()), language: lang));
        for (final _Rule r in p.rules.where((_Rule r) => r.media != null)) {
          expect(r.fullyReadable, isTrue,
              reason: _why(e3,
                  'tag, #id, .class, :not(simple), > and descendant combinators and ::before only, got ${r.rawSelectors}'));
        }
      });

      // ---------------------------------------------------------------
      // (e) D2: outside the media block nothing changes.
      // ---------------------------------------------------------------

      final String e4 =
          '(e) $lang: outside the media block every rule for table, th, td, .hex and .table-scroll is byte-identical to the base';
      test(e4, () {
        final _Page p =
            _Page(buildVerifyPageHtml(jsonEncode(_record()), language: lang));
        final RegExp names = RegExp(
            r'(?:^|[\s>])(?:table|th|td)(?![\w-])|\.hex(?![\w-])|\.table-scroll(?![\w-])');
        final List<String> outside = <String>[
          for (final _Rule r in p.rules)
            if (r.media == null &&
                r.rawSelectors.any((String s) => names.hasMatch(s)))
              r.raw,
        ];
        expect(outside, _baseTableRules,
            reason: _why(e4,
                'exactly the six base rules for table, th, td, .hex and .table-scroll, in this order and byte for byte, outside the media block'));
      });
    });
  }
}

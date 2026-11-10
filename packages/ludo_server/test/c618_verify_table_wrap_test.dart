// Tests for contract C-618 (work/ludo/orders/618-verify-tables-no-midword-break.md),
// decisions D1 to D5: on the verify page only a hex run may break anywhere. A
// header, a player name, a die, k, an origin sentence or a check result is a
// word and never splits mid-letter; each of the two tables scrolls inside a
// `div.table-scroll` instead of widening the page; the prose outside the
// tables keeps `overflow-wrap: anywhere`.
//
// Written from the contract, not from the implementation. The real
// buildVerifyPageHtml / buildVerifyNotFoundHtml output is parsed with a small
// tag-tree reader and a small CSS reader (package:html is not a dependency of
// this package). The CSS reader is the one of c616_verify_page_look_test.dart
// with two additions: `:not(<one simple selector>)` is understood, because
// "every td that is not .hex" is most naturally written that way, and a rule
// inside an at-rule (@media and friends) is ignored, so a wrap rule that only
// applies at some widths is reported as missing rather than guessed at. Any
// other selector form (attribute selectors, other pseudo-classes) is ignored.
// The properties read here (overflow-wrap, word-break) inherit, so each is
// resolved by the cascade on the element itself and then up its ancestors.
//
// Nothing here is random: every record is built from a fixed secret, so a
// failure reproduces by running the one test named in its message:
//   cd packages/ludo_server && dart test test/c618_verify_table_wrap_test.dart -N '<test name>'

import 'dart:convert';

import 'package:fair_dice/fair_dice.dart' show DiceChain, drawDie;
import 'package:ludo_server/ludo_server.dart'
    show buildVerifyNotFoundHtml, buildVerifyPageHtml, verifyRecordFormat;
import 'package:test/test.dart';

const List<String> _langs = <String>['en', 'ar'];

const String _gameId = 'c618c618c618c618';
const String _clientSeeds = '0:c618-seed-alice|1:c618-seed-server';

/// A seed as long as a real client seed can be: it has to break to fit.
final String _longSeed = List<String>.generate(
  16,
  (int i) => 'deadbeef$i'.padRight(12, 'c'),
).join();

// ---------------------------------------------------------------------
// Words pinned from the base page, which D5 says stays word for word.
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

const Map<String, Map<String, String>> _rollTableData =
    <String, Map<String, String>>{
  'en': <String, String>{
    'data-match': 'checked: matches',
    'data-mismatch': 'checked: does not match',
  },
  'ar': <String, String>{
    'data-match': 'تم الفحص: مطابق',
    'data-mismatch': 'تم الفحص: غير مطابق',
  },
};

const Map<String, List<String>> _seatNames = <String, List<String>>{
  'en': <String>['Red', 'Green', 'Yellow', 'Blue'],
  'ar': <String>['الأحمر', 'الأخضر', 'الأصفر', 'الأزرق'],
};

const Map<String, String> _notChecked = <String, String>{
  'en': 'not checked',
  'ar': 'لم يُفحص',
};

const Map<String, Map<String, String>> _origin = <String, Map<String, String>>{
  'en': <String, String>{
    'player': 'chosen by this player',
    'server': 'drawn by the server: this player added no randomness of '
        'their own',
  },
  'ar': <String, String>{
    'player': 'اختارها هذا اللاعب',
    'server': 'سحبها الخادم: هذا اللاعب لم يضف عشوائية من عنده',
  },
};

// ---------------------------------------------------------------------
// Fixtures: records in the shape of docs/VERIFY.md section 1.1.
// ---------------------------------------------------------------------

Map<String, Object?> _record({
  int rollCount = 5,
  List<Map<String, Object?>>? seeds,
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
            'seed': 'c618-seed-alice',
            'origin': 'player',
          },
          <String, Object?>{
            'seat': 1,
            'seed': 'c618-seed-server',
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

/// The records every structural test runs on: the plain one, one with four
/// seats and a seed long enough to need breaking, one with markup characters
/// in a seed, and one with no rolls at all (an empty table is still a table).
final Map<String, Map<String, Object?>> _variants =
    <String, Map<String, Object?>>{
  'five rolls': _record(),
  'four seats, long seed': _record(
    rollCount: 8,
    seeds: <Map<String, Object?>>[
      for (int s = 0; s < 4; s++)
        <String, Object?>{
          'seat': s,
          'seed': s == 0 ? _longSeed : 'seed-$s',
          'origin': s.isEven ? 'player' : 'server',
        },
    ],
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
};

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
// A small CSS reader: selectors, specificity, cascade.
// ---------------------------------------------------------------------

class _Compound {
  _Compound(this.tag, this.ids, this.classes, this.nots);
  final String? tag;
  final List<String> ids;
  final List<String> classes;

  /// The simple selectors inside `:not(...)`: `.x`, `#x` or a tag name.
  final List<String> nots;
}

class _Selector {
  _Selector(this.parts, this.combinators);
  final List<_Compound> parts;

  /// combinators[i] sits between parts[i] and parts[i + 1]: ' ' or '>'.
  final List<String> combinators;

  /// A `:not(x)` weighs what `x` weighs.
  List<int> get specificity {
    int ids = 0;
    int classes = 0;
    int tags = 0;
    for (final _Compound c in parts) {
      ids += c.ids.length;
      classes += c.classes.length;
      tags += c.tag == null ? 0 : 1;
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
  r'^([a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)((?::not\([.#]?[\w-]+\))*)$',
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
    parts.add(_Compound(m.group(1)?.toLowerCase(), ids, classes, nots));
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

/// The top-level rules of [css]. A block whose prelude starts with `@` is
/// skipped whole, nested rules included.
List<_Rule> _parseCss(String css) {
  final String bare = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final List<_Rule> rules = <_Rule>[];
  int depth = 0;
  int preludeStart = 0;
  int bodyStart = 0;
  String prelude = '';
  for (int i = 0; i < bare.length; i++) {
    final String ch = bare[i];
    if (ch == '{') {
      if (depth == 0) {
        prelude = bare.substring(preludeStart, i).trim();
        bodyStart = i + 1;
      }
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        final String body = bare.substring(bodyStart, i);
        preludeStart = i + 1;
        if (prelude.startsWith('@')) {
          continue;
        }
        final List<_Selector> sels = <_Selector>[
          for (final String part in prelude.split(','))
            if (_parseSelector(part) != null) _parseSelector(part)!,
        ];
        final List<MapEntry<String, String>> decls = <MapEntry<String, String>>[
          for (final String d in body.split(';'))
            if (d.contains(':'))
              MapEntry<String, String>(
                d.substring(0, d.indexOf(':')).trim().toLowerCase(),
                d.substring(d.indexOf(':') + 1).trim(),
              ),
        ];
        rules.add(_Rule(sels, decls));
      }
    }
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
    css = root.elements
        .where((_Node n) => n.tag == 'style')
        .map((_Node s) => s.text)
        .join('\n');
    rules = _parseCss(css);
  }

  final String html;
  late final _Node root;
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

  /// The declarations that apply to [n], in cascade order: later wins.
  List<MapEntry<String, String>> declsFor(_Node n) {
    final List<_Decl> hits = <_Decl>[];
    int order = 0;
    for (final _Rule r in rules) {
      List<int>? best;
      for (final _Selector s in r.selectors) {
        if (_matchFrom(s, s.parts.length - 1, n)) {
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

  String? valueOf(_Node n, String prop) {
    String? out;
    for (final MapEntry<String, String> e in declsFor(n)) {
      if (e.key == prop) {
        out = e.value;
      }
    }
    return out;
  }

  /// A property that inherits: the nearest ancestor-or-self that sets it,
  /// `normal` (the initial value of both wrap properties) when none does.
  String wrapValue(_Node n, String prop) {
    for (_Node? c = n; c != null && c.isElement; c = c.parent) {
      final String? v = valueOf(c, prop);
      if (v != null) {
        return v.toLowerCase();
      }
    }
    return 'normal';
  }
}

// ---------------------------------------------------------------------
// Assertion helpers that always say what, which scenario, how to rerun.
// ---------------------------------------------------------------------

String _why(String scenario, String expected) => 'expected $expected | '
    'scenario: $scenario | reproduce: cd packages/ludo_server && dart test '
    'test/c618_verify_table_wrap_test.dart -N \'$scenario\' (fixtures are '
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

/// The chain commitment `<code>`: the one whose text is the commitment.
List<_Node> _chainCodes(_Page p, Map<String, Object?> record) => p
    .all('code')
    .where((_Node c) => c.textContent == record['chain_commit'])
    .toList();

/// Every element the contract says carries `hex`, for [record].
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

void main() {
  _Page verifyPage(String lang, Map<String, Object?> record) =>
      _Page(buildVerifyPageHtml(jsonEncode(record), language: lang));

  for (final String lang in _langs) {
    for (final MapEntry<String, Map<String, Object?>> v in _variants.entries) {
      final String tag = '$lang / ${v.key}';
      final Map<String, Object?> record = v.value;

      group('C-618 $tag', () {
        // -------------------------------------------------------------
        // (a) D1: which elements carry `hex`.
        // -------------------------------------------------------------

        final String a1 =
            '(a) $tag: the seed value cells, every td.reveal and the chain commitment code carry class hex';
        test(a1, () {
          final _Page p = verifyPage(lang, record);
          final List<_Node> tables = _tables(p);
          expect(tables.length, 2,
              reason: _why(a1, 'two tables, found ${tables.length}'));
          expect(_chainCodes(p, record).length, 1,
              reason: _why(a1,
                  'exactly one <code> holding the chain commitment, found ${_chainCodes(p, record).length}'));
          final List<_Node> seedCells = <_Node>[
            for (final _Node r in _bodyRows(tables[0])) _cellsOf(r, 'td')[1],
          ];
          final List<_Node> revealCells = p
              .all('td')
              .where((_Node c) => c.classes.contains('reveal'))
              .toList();
          final int seeds = (record['seeds']! as List<Object?>).length;
          final int rolls = (record['rolls']! as List<Object?>).length;
          expect(seedCells.length, seeds,
              reason: _why(a1, '$seeds seed rows, found ${seedCells.length}'));
          expect(revealCells.length, rolls,
              reason: _why(a1,
                  '$rolls td.reveal cells (the class is kept), found ${revealCells.length}'));
          for (final _Node n in <_Node>[
            ...seedCells,
            ...revealCells,
            ..._chainCodes(p, record),
          ]) {
            expect(n.classes, contains('hex'),
                reason: _why(
                    a1, 'class hex on ${_where(n)}, classes are ${n.classes}'));
          }
          for (final _Node n in revealCells) {
            expect(n.classes, contains('reveal'),
                reason: _why(a1, 'td.reveal to keep class reveal beside hex'));
          }
        });

        final String a2 =
            '(a) $tag: no other td, no th and no other element carries class hex';
        test(a2, () {
          final _Page p = verifyPage(lang, record);
          final List<_Node> allowed = _expectedHex(p, record);
          for (final _Node n in p.root.elements) {
            if (_hasHex(n) && !allowed.any((_Node a) => identical(a, n))) {
              fail(_why(a2,
                  'class hex only on the seed value cells, td.reveal cells and the chain commitment code, found it on ${_where(n)}'));
            }
          }
          for (final _Node th in p.all('th')) {
            expect(_hasHex(th), isFalse,
                reason: _why(a2, 'no th with class hex, got ${_where(th)}'));
          }
        });

        // -------------------------------------------------------------
        // (b) D1 and D2: what the stylesheet resolves for each.
        // -------------------------------------------------------------

        final String b1 =
            '(b) $tag: every hex element resolves overflow-wrap anywhere and word-break break-all';
        test(b1, () {
          final _Page p = verifyPage(lang, record);
          final List<_Node> hexes = _expectedHex(p, record);
          expect(hexes, isNotEmpty,
              reason: _why(b1, 'hex elements on the page'));
          for (final _Node n in hexes) {
            expect(p.wrapValue(n, 'overflow-wrap'), 'anywhere',
                reason: _why(b1,
                    'overflow-wrap: anywhere on ${_where(n)} (a long hex has to be able to break anywhere)'));
            expect(p.wrapValue(n, 'word-break'), 'break-all',
                reason: _why(b1, 'word-break: break-all on ${_where(n)}'));
          }
        });

        final String b2 =
            '(b) $tag: every th and every td that is not hex resolves overflow-wrap normal and word-break normal';
        test(b2, () {
          final _Page p = verifyPage(lang, record);
          int checked = 0;
          for (final _Node n in _tdsAndThs(p)) {
            if (_hasHex(n)) {
              continue;
            }
            checked++;
            expect(p.wrapValue(n, 'overflow-wrap'), 'normal',
                reason: _why(b2,
                    'overflow-wrap: normal on ${_where(n)} (a word in a header or a cell never splits)'));
            expect(p.wrapValue(n, 'word-break'), 'normal',
                reason: _why(b2, 'word-break: normal on ${_where(n)}'));
          }
          expect(checked, greaterThan(0),
              reason: _why(b2, 'plain th and td cells to check'));
        });

        // -------------------------------------------------------------
        // (c) D3: each table scrolls inside its own wrapper, inside #proof.
        // -------------------------------------------------------------

        final String c1 =
            '(c) $tag: each table is the only child of a div.table-scroll inside #proof';
        test(c1, () {
          final _Page p = verifyPage(lang, record);
          final _Node? proof = p.byId('proof');
          expect(proof, isNotNull, reason: _why(c1, 'a #proof element'));
          final List<_Node> tables = _tables(p);
          expect(tables.length, 2,
              reason: _why(c1, 'two tables, found ${tables.length}'));
          for (final _Node t in tables) {
            final _Node? wrap = t.parent;
            expect(wrap?.tag, 'div',
                reason:
                    _why(c1, 'the table\'s parent to be a <div>, got $wrap'));
            expect(wrap!.classes, contains('table-scroll'),
                reason: _why(c1,
                    'the table\'s parent to carry class table-scroll, got $wrap'));
            expect(wrap.isInside(proof!), isTrue,
                reason: _why(c1, 'the wrapper inside #proof'));
            expect(t.isInside(proof), isTrue,
                reason: _why(c1, 'the table inside #proof'));
            expect(wrap.elementChildren.length, 1,
                reason: _why(c1,
                    'the wrapper to hold only the table, holds ${wrap.elementChildren}'));
          }
          expect(
            p
                .all('div')
                .where((_Node d) => d.classes.contains('table-scroll'))
                .length,
            2,
            reason: _why(c1, 'exactly two div.table-scroll wrappers'),
          );
        });

        final String c2 =
            '(c) $tag: the stylesheet gives .table-scroll overflow-x auto';
        test(c2, () {
          final _Page p = verifyPage(lang, record);
          final List<_Node> wraps = p
              .all('div')
              .where((_Node d) => d.classes.contains('table-scroll'))
              .toList();
          expect(wraps, isNotEmpty,
              reason: _why(c2, 'a div.table-scroll to read the style of'));
          for (final _Node w in wraps) {
            String? x;
            for (final MapEntry<String, String> e in p.declsFor(w)) {
              if (e.key == 'overflow-x' || e.key == 'overflow') {
                x = e.value.split(RegExp(r'\s+')).first;
              }
            }
            expect(x, 'auto',
                reason: _why(c2,
                    'overflow-x: auto (or overflow: auto) on ${_where(w)}, resolved ${x ?? 'nothing'}'));
          }
        });

        // -------------------------------------------------------------
        // (d) D4: prose keeps overflow-wrap anywhere.
        // -------------------------------------------------------------

        final String d1 =
            '(d) $tag: the body and the prose outside the tables resolve overflow-wrap anywhere and no forced word-break';
        test(d1, () {
          final _Page p = verifyPage(lang, record);
          final _Node body = p.all('body').first;
          expect(p.wrapValue(body, 'overflow-wrap'), 'anywhere',
              reason: _why(d1, 'the body to resolve overflow-wrap: anywhere'));
          final List<_Node> prose = <_Node>[
            ...p.all('h1'),
            ...p.all('h2'),
            ...p.all('p'),
            ...p.all('li'),
            ...p.all('summary'),
            ...p.all('noscript'),
            if (p.byId('summary') != null) p.byId('summary')!,
          ];
          expect(prose, isNotEmpty, reason: _why(d1, 'prose to check'));
          for (final _Node n in prose) {
            expect(p.wrapValue(n, 'overflow-wrap'), 'anywhere',
                reason:
                    _why(d1, 'overflow-wrap: anywhere on prose ${_where(n)}'));
            expect(p.wrapValue(n, 'word-break'), 'normal',
                reason: _why(d1, 'no forced word-break on prose ${_where(n)}'));
          }
        });

        // -------------------------------------------------------------
        // (e) D5: ids, data attributes, classes and words are unchanged.
        // -------------------------------------------------------------

        final String e1 =
            '(e) $tag: table ids, classes, data attributes and header words are those of the base';
        test(e1, () {
          final _Page p = verifyPage(lang, record);
          final List<_Node> tables = _tables(p);
          expect(tables.length, 2,
              reason: _why(e1, 'two tables, found ${tables.length}'));
          expect(tables[0].attrs, <String, String>{},
              reason: _why(e1,
                  'the seeds table to have no id, class or data attribute, got ${tables[0].attrs}'));
          expect(
              tables[1].attrs,
              <String, String>{
                'id': 'rolls-table',
                ..._rollTableData[lang]!,
              },
              reason: _why(e1,
                  'the rolls table to keep id rolls-table and its two data attributes, got ${tables[1].attrs}'));
          final List<String> seedHead = <String>[
            for (final _Node th in _headerCells(tables[0])) th.textContent,
          ];
          final List<String> rollHead = <String>[
            for (final _Node th in _headerCells(tables[1])) th.textContent,
          ];
          expect(seedHead, _seedHeaders[lang],
              reason: _why(e1, 'the seeds headers ${_seedHeaders[lang]}'));
          expect(rollHead, _rollHeaders[lang],
              reason: _why(e1, 'the rolls headers ${_rollHeaders[lang]}'));
          for (final _Node th in p.all('th')) {
            expect(th.attrs, <String, String>{},
                reason: _why(e1,
                    'th without attributes, got ${_where(th)} ${th.attrs}'));
          }
        });

        final String e2 =
            '(e) $tag: every cell keeps its text, ids, data-seat and dir; only the hex cells gain a class';
        test(e2, () {
          final _Page p = verifyPage(lang, record);
          final List<_Node> tables = _tables(p);
          final String dir = lang == 'ar' ? 'ltr' : '';
          Map<String, String> attrs(Map<String, String> a) =>
              <String, String>{...a, if (dir != '') 'dir': dir};
          String seat(Object? s) => _seatNames[lang]![s! as int];

          final List<Object?> seeds = record['seeds']! as List<Object?>;
          final List<_Node> seedRows = _bodyRows(tables[0]);
          expect(seedRows.length, seeds.length,
              reason: _why(
                  e2, '${seeds.length} seed rows, found ${seedRows.length}'));
          for (int i = 0; i < seeds.length; i++) {
            final Map<String, Object?> s = seeds[i]! as Map<String, Object?>;
            final List<_Node> cells = _cellsOf(seedRows[i], 'td');
            expect(cells.length, 3,
                reason: _why(
                    e2, 'three cells in seed row $i, found ${cells.length}'));
            expect(<String>[
              for (final _Node c in cells) c.textContent
            ], <String>[
              seat(s['seat']),
              s['seed']! as String,
              _origin[lang]![s['origin']]!,
            ], reason: _why(e2, 'the words of seed row $i'));
            expect(<Map<String, String>>[
              for (final _Node c in cells)
                <String, String>{...c.attrs}..remove('class'),
            ], <Map<String, String>>[
              <String, String>{'data-seat': '${s['seat']}'},
              attrs(<String, String>{}),
              <String, String>{},
            ], reason: _why(e2, 'the attributes of seed row $i'));
            expect(<Set<String>>[
              for (final _Node c in cells) c.classes
            ], <Set<String>>[
              <String>{},
              <String>{'hex'},
              <String>{}
            ],
                reason: _why(e2,
                    'the classes of seed row $i: only the seed cell has hex'));
          }

          final List<Object?> rolls = record['rolls']! as List<Object?>;
          final List<_Node> rollRows = _bodyRows(tables[1]);
          expect(rollRows.length, rolls.length,
              reason: _why(
                  e2, '${rolls.length} roll rows, found ${rollRows.length}'));
          for (int i = 0; i < rolls.length; i++) {
            final Map<String, Object?> r = rolls[i]! as Map<String, Object?>;
            final List<_Node> cells = _cellsOf(rollRows[i], 'td');
            expect(cells.length, 6,
                reason: _why(
                    e2, 'six cells in roll row $i, found ${cells.length}'));
            expect(<String>[
              for (final _Node c in cells) c.textContent
            ], <String>[
              '${r['k']}',
              seat(r['seat']),
              '${r['die']}',
              r['reveal']! as String,
              _notChecked[lang]!,
              _notChecked[lang]!,
            ], reason: _why(e2, 'the words of roll row $i'));
            expect(<Map<String, String>>[
              for (final _Node c in cells)
                <String, String>{...c.attrs}..remove('class'),
            ], <Map<String, String>>[
              attrs(<String, String>{}),
              <String, String>{'data-seat': '${r['seat']}'},
              attrs(<String, String>{}),
              attrs(<String, String>{}),
              <String, String>{'id': 'chain-${r['k']}'},
              <String, String>{'id': 'die-${r['k']}'},
            ], reason: _why(e2, 'the attributes of roll row $i'));
            expect(<Set<String>>[
              for (final _Node c in cells) c.classes
            ], <Set<String>>[
              <String>{},
              <String>{},
              <String>{},
              <String>{'reveal', 'hex'},
              <String>{},
              <String>{},
            ],
                reason: _why(e2,
                    'the classes of roll row $i: only the reveal cell has hex, and keeps reveal'));
          }
        });
      });
    }

    // -----------------------------------------------------------------
    // Ugly cases that are not per-variant.
    // -----------------------------------------------------------------

    group('C-618 $lang extra', () {
      final String d2 =
          '(d) $lang: a long game id in the h1 still wraps, and the not-found page keeps overflow-wrap anywhere';
      test(d2, () {
        final String longId = List<String>.filled(8, 'c618c618c618c618').join();
        final _Page p = verifyPage(lang, _record(gameId: longId));
        final _Node h1 = p.all('h1').first;
        expect(h1.textContent, contains(longId),
            reason:
                _why(d2, 'the long game id in the <h1>, got ${_where(h1)}'));
        expect(p.wrapValue(h1, 'overflow-wrap'), 'anywhere',
            reason: _why(d2,
                'overflow-wrap: anywhere on the <h1> holding a ${longId.length}-character id'));
        expect(p.wrapValue(h1, 'word-break'), 'normal',
            reason: _why(d2, 'no forced word-break on the <h1>'));
        final _Page nf = _Page(buildVerifyNotFoundHtml(language: lang));
        expect(nf.all('table'), isEmpty,
            reason: _why(d2, 'no table on the not-found page'));
        for (final _Node n in <_Node>[
          nf.all('body').first,
          ...nf.all('h1'),
          ...nf.all('p')
        ]) {
          expect(nf.wrapValue(n, 'overflow-wrap'), 'anywhere',
              reason: _why(d2,
                  'overflow-wrap: anywhere on ${_where(n)} of the not-found page'));
        }
      });

      final String f1 =
          '(b) $lang: wrap rules are not hidden in an at-rule and the stylesheet is the single <style> element';
      test(f1, () {
        final _Page p = verifyPage(lang, _record());
        final int styles = p.all('style').length;
        expect(styles, 1,
            reason: _why(f1,
                'one <style> element (no stylesheet link, no inline style on a table), found $styles'));
        for (final _Node n in <_Node>[..._tables(p), ..._tdsAndThs(p)]) {
          final String style = n.attrs['style'] ?? '';
          expect(
              style.contains('overflow-wrap') || style.contains('word-break'),
              isFalse,
              reason: _why(f1,
                  'no inline wrap rule on ${_where(n)}, the cascade lives in the stylesheet'));
        }
      });
    });
  }
}

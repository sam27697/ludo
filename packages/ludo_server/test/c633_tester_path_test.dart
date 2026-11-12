// Proof for order 633 (work/ludo/orders/633-closed-test-install-path.md),
// decisions D1 to D5. Written from the contract, not from the
// implementation.
//
// Ludo RNG is on the closed testing track, so the Play listing answers 404
// for anyone who has not joined the testers group and opted in. Every page
// that offers the app must lead a friend through the group, the opt-in and
// the install, in order, in their language, and `closedTest: false` must give
// back the public pages byte for byte so the flip back is one constant.
//
// The builders are called directly for D1 to D5 and over a real WireServer on
// an ephemeral port for the route cases.
//
// The goldens under test/fixtures/c633_public_mode were rendered from commit
// a828fb5, before the contract was implemented, by calling the four builders
// (room code ABCDEF) and writing the UTF-8 bytes of what they returned.
//
// Every case is deterministic: there is no seed. Every failure text names the
// scenario and the command that re-runs it.
//
// Interpretations the contract leaves open:
//
// - "Byte exact" words are compared after HTML entities are decoded, because
//   the apostrophe in "phone's" may be served as an entity and is the same
//   text to the reader. The attribute values are also compared as served
//   (escaped with the attribute escaper).
// - The block of D4b is compared with whitespace between tags collapsed, so a
//   newline or none between two elements is not a difference.
// - "Numbers shown" for the ordered list is checked in the style: no
//   list-style none, no display on the list or its items other than block or
//   list-item, and no zero padding on the list unless the markers are inside.
// - Rules are matched by the last compound selector only (.btn, a.btn, a,
//   #id, .steps, ol, li); the cascade is read as "last matching rule wins".
// - Links to ludo.provefair.app (the intent URL and its fallback) are allowed
//   next to the relative paths, groups.google.com and play.google.com.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:ludo_server/src/link_pages.dart';
import 'package:test/test.dart';

const String _testFile = 'test/c633_tester_path_test.dart';

const String _expectedCsp = "default-src 'none'; script-src 'self'; "
    "style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'none'";

const String _groupUrl = 'https://groups.google.com/g/ludo-rng-testers';
const String _optInUrl = 'https://play.google.com/apps/testing/app.fayad.ludo';
const String _listingUrl =
    'https://play.google.com/store/apps/details?id=app.fayad.ludo';

const String _code = 'ABCDEF';

/// The D4c table. Keys: introRoom, introPlain, join, become, get, waitRoom,
/// waitPlain, stay.
const Map<String, Map<String, String>> _words = <String, Map<String, String>>{
  'en': <String, String>{
    'introRoom':
        'New to Ludo RNG? It is in testing on Google Play, so installing it '
            "takes three steps, once. Use the Google account your phone's Play "
            'Store uses.',
    'introPlain':
        'Ludo RNG is in testing on Google Play, so installing it takes three '
            "steps, once. Use the Google account your phone's Play Store "
            'uses.',
    'join': 'Join the Ludo RNG testers group',
    'become': 'Become a tester on Google Play',
    'get': 'Get Ludo RNG on Google Play',
    'waitRoom': 'If Play says the app is not found, wait a few minutes and try '
        'again. Then come back here and tap Open in Ludo RNG, or type the '
        'code on the home screen.',
    'waitPlain': 'If Play says the app is not found, wait a few minutes and '
        'try again.',
    'stay': 'Please stay in the group while the test runs.',
  },
  'ar': <String, String>{
    'introRoom':
        'جديد على Ludo RNG؟ اللعبة في مرحلة الاختبار على Google Play، لذلك '
            'يحتاج تثبيتها إلى ثلاث خطوات، مرة واحدة فقط. استخدم حساب Google '
            'نفسه الموجود في متجر Play على هاتفك.',
    'introPlain':
        'Ludo RNG في مرحلة الاختبار على Google Play، لذلك يحتاج تثبيتها إلى '
            'ثلاث خطوات، مرة واحدة فقط. استخدم حساب Google نفسه الموجود في '
            'متجر Play على هاتفك.',
    'join': 'انضم إلى مجموعة مختبري Ludo RNG',
    'become': 'سجّل كمختبر على Google Play',
    'get': 'احصل على Ludo RNG من Google Play',
    'waitRoom': 'إذا ظهر في Play أن التطبيق غير موجود، انتظر بضع دقائق وحاول '
        'مرة أخرى. ثم ارجع إلى هنا واضغط «افتح في Ludo RNG»، أو اكتب الرمز '
        'في الشاشة الرئيسية.',
    'waitPlain': 'إذا ظهر في Play أن التطبيق غير موجود، انتظر بضع دقائق وحاول '
        'مرة أخرى.',
    'stay': 'من فضلك ابقَ في المجموعة طوال فترة الاختبار.',
  },
};

const List<String> _stepIds = <String>[
  'tester-intro',
  'tester-steps',
  'join-group',
  'become-tester',
  'get-app',
  'tester-wait',
  'tester-stay',
];

// ---------------------------------------------------------------------
// Failure text
// ---------------------------------------------------------------------

String _repro(String scenario) =>
    'scenario: $scenario. Deterministic, no seed. Reproduce with: cd '
    'packages/ludo_server && dart test $_testFile -n "$scenario"';

// ---------------------------------------------------------------------
// HTML helpers (package:html is not a dependency)
// ---------------------------------------------------------------------

const HtmlEscape _attributeEscaper = HtmlEscape(HtmlEscapeMode.attribute);

String _unescape(String input) {
  return input
      .replaceAllMapped(
        RegExp(r'&#[xX]([0-9a-fA-F]+);'),
        (Match m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (Match m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

final RegExp _attrPattern = RegExp(
  r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
);

Map<String, String> _parseAttrs(String raw) {
  final Map<String, String> attrs = <String, String>{};
  for (final RegExpMatch m in _attrPattern.allMatches(raw)) {
    attrs[m.group(1)!.toLowerCase()] = _unescape(m.group(2) ?? m.group(3)!);
  }
  return attrs;
}

class _Tag {
  _Tag(this.name, this.attrs, this.openStart, this.openEnd, this.raw);

  final String name;
  final Map<String, String> attrs;
  final int openStart;
  final int openEnd;
  final String raw;
}

List<_Tag> _tagsWithId(String html, String id) {
  final List<_Tag> found = <_Tag>[];
  final RegExp open = RegExp(r'<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>');
  for (final RegExpMatch m in open.allMatches(html)) {
    final Map<String, String> attrs = _parseAttrs(m.group(2)!);
    if (attrs['id'] == id) {
      found.add(
        _Tag(m.group(1)!.toLowerCase(), attrs, m.start, m.end, m.group(0)!),
      );
    }
  }
  return found;
}

/// Markup between the end of [tag]'s opening tag and its matching close.
String _inner(String html, _Tag tag) {
  final RegExp same = RegExp('<(/?)${tag.name}\\b([^>]*)>');
  int depth = 1;
  for (final RegExpMatch m in same.allMatches(html.substring(tag.openEnd))) {
    final bool closing = m.group(1) == '/';
    final bool selfClosing = !closing && m.group(2)!.trimRight().endsWith('/');
    if (closing) {
      depth -= 1;
    } else if (!selfClosing) {
      depth += 1;
    }
    if (depth == 0) {
      return html.substring(tag.openEnd, tag.openEnd + m.start);
    }
  }
  return html.substring(tag.openEnd);
}

/// The end offset of the element opened by [tag], including its close tag.
int _elementEnd(String html, _Tag tag) {
  final String inner = _inner(html, tag);
  final int closeAt = tag.openEnd + inner.length;
  final int gt = html.indexOf('>', closeAt);
  return gt < 0 ? html.length : gt + 1;
}

String _styleText(String html) {
  final StringBuffer buffer = StringBuffer();
  for (final RegExpMatch m in RegExp(
    r'<style\b[^>]*>(.*?)</style>',
    dotAll: true,
  ).allMatches(html)) {
    buffer.writeln(m.group(1));
  }
  return buffer.toString();
}

String _collapseBetweenTags(String markup) =>
    markup.replaceAll(RegExp(r'>\s+<'), '><').trim();

// ---------------------------------------------------------------------
// CSS reading
// ---------------------------------------------------------------------

class _Rule {
  _Rule(this.selector, this.decls);

  final String selector;
  final Map<String, String> decls;

  /// The last compound selector: ".steps li a" gives "a".
  String get last {
    final List<String> parts = selector
        .split(RegExp(r'[\s>+~]+'))
        .where((String s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? '' : parts.last;
  }

  String get canonical =>
      '$selector{${(decls.keys.toList()..sort()).map((String k) => '$k:${decls[k]}').join(';')}}';
}

List<_Rule> _rules(String html) {
  final String css =
      _styleText(html).replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final List<_Rule> out = <_Rule>[];
  for (final RegExpMatch m in RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(css)) {
    final Map<String, String> decls = <String, String>{};
    for (final String d in m.group(2)!.split(';')) {
      final int i = d.indexOf(':');
      if (i < 0) {
        continue;
      }
      decls[d.substring(0, i).trim().toLowerCase()] =
          d.substring(i + 1).trim().toLowerCase();
    }
    for (final String sel in m.group(1)!.split(',')) {
      out.add(_Rule(sel.trim().replaceAll(RegExp(r'\s+'), ' '), decls));
    }
  }
  return out;
}

/// The value of [prop] after the last rule whose last compound selector is in
/// [targets] and that sets [prop], or null.
String? _effective(List<_Rule> rules, Set<String> targets, String prop) {
  String? value;
  for (final _Rule r in rules) {
    if (targets.contains(r.last) && r.decls.containsKey(prop)) {
      value = r.decls[prop];
    }
  }
  return value;
}

/// A length in px, or null when it is not a plain rem or px length.
double? _px(String? value) {
  if (value == null) {
    return null;
  }
  final RegExpMatch? m = RegExp(r'^(\d*\.?\d+)(rem|px)$').firstMatch(value);
  if (m == null) {
    return null;
  }
  final double n = double.parse(m.group(1)!);
  return m.group(2) == 'rem' ? n * 16 : n;
}

// ---------------------------------------------------------------------
// The pages under test
// ---------------------------------------------------------------------

class _PageCase {
  _PageCase(this.name, this.kind, this.lang, this.html, this.golden);

  final String name;

  /// room, home, cut or plain.
  final String kind;
  final String lang;
  final String html;

  /// The fixture file name in the public-mode directory, or null.
  final String? golden;

  bool get isRoom => kind == 'room';
  bool get isAr => lang == 'ar';
  Map<String, String> get w => _words[lang]!;
  String get intro => isRoom ? w['introRoom']! : w['introPlain']!;
  String get wait => isRoom ? w['waitRoom']! : w['waitPlain']!;
}

List<_PageCase> _closedPages() => <_PageCase>[
      for (final String l in <String>['en', 'ar'])
        _PageCase(
            'room page $l',
            'room',
            l,
            buildRoomLandingPageHtml(_code, language: l, closedTest: true),
            'room_$l.html'),
      for (final String l in <String>['en', 'ar'])
        _PageCase('home page $l', 'home', l,
            buildHomePageHtml(language: l, closedTest: true), 'home_$l.html'),
      for (final String l in <String>['en', 'ar'])
        _PageCase(
            '404 cut invite $l',
            'cut',
            l,
            buildLinkNotFoundHtml(
                cutInvite: true, language: l, closedTest: true),
            'notfound_cut_$l.html'),
      _PageCase(
          '404 plain en',
          'plain',
          'en',
          buildLinkNotFoundHtml(
              cutInvite: false, language: 'en', closedTest: true),
          'notfound_plain_en.html'),
      _PageCase(
          '404 plain ar',
          'plain',
          'ar',
          buildLinkNotFoundHtml(
              cutInvite: false, language: 'ar', closedTest: true),
          null),
    ];

Future<String> _golden(String file) async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:ludo_server/ludo_server.dart'),
  );
  if (libUri == null) {
    fail('could not resolve package:ludo_server to a file URI, so the golden '
        '$file cannot be located. This case never skips.');
  }
  final File f = File(
    '${File.fromUri(libUri).parent.parent.path}/test/fixtures/'
    'c633_public_mode/$file',
  );
  if (!f.existsSync()) {
    fail('expected the golden at ${f.path}; it does not exist. This case '
        'never skips.');
  }
  return utf8.decode(f.readAsBytesSync());
}

String _firstDiff(String expected, String actual) {
  final int n = min(expected.length, actual.length);
  int i = 0;
  while (i < n && expected.codeUnitAt(i) == actual.codeUnitAt(i)) {
    i += 1;
  }
  String around(String s) => s
      .substring(max(0, i - 40), min(s.length, i + 60))
      .replaceAll('\n', r'\n');
  return 'lengths ${expected.length} (expected) and ${actual.length} (got), '
      'first difference at offset $i; expected "...${around(expected)}..." '
      'got "...${around(actual)}..."';
}

/// The block D4b prescribes, as plain text with entities decoded.
String _expectedBlock(_PageCase p) => <String>[
      '<p id="tester-intro" class="hint">${p.intro}</p>',
      '<ol id="tester-steps" class="steps">',
      '<li><a id="join-group" class="btn" href="$_groupUrl">${p.w['join']}</a></li>',
      '<li><a id="become-tester" class="btn" href="$_optInUrl">${p.w['become']}</a></li>',
      '<li><a id="get-app" class="btn" href="$_listingUrl">${p.w['get']}</a></li>',
      '</ol>',
      '<p id="tester-wait" class="hint">${p.wait}</p>',
      '<p id="tester-stay" class="hint">${p.w['stay']}</p>',
    ].join('\n');

String _servedBlock(String html) {
  final List<_Tag> intro = _tagsWithId(html, 'tester-intro');
  final List<_Tag> stay = _tagsWithId(html, 'tester-stay');
  if (intro.length != 1 || stay.length != 1) {
    return '';
  }
  return html.substring(intro.single.openStart, _elementEnd(html, stay.single));
}

// ---------------------------------------------------------------------
// Server plumbing for the route cases
// ---------------------------------------------------------------------

class _Res {
  _Res(this.path, this.status, this.headers, this.body);

  final String path;
  final int status;
  final Map<String, String> headers;
  final String body;

  String describe() =>
      'GET $path -> $status, headers $headers, body (first 300 chars): '
      '${body.length > 300 ? body.substring(0, 300) : body}';
}

late WireServer _server;
late HttpClient _client;

Future<_Res> _get(String pathAndQuery) async {
  final HttpClientRequest request = await _client.getUrl(
    Uri.parse('http://127.0.0.1:${_server.port}$pathAndQuery'),
  );
  final HttpClientResponse response = await request.close();
  final String body = await response.transform(utf8.decoder).join();
  final Map<String, String> seen = <String, String>{};
  response.headers.forEach((String name, List<String> values) {
    seen[name.toLowerCase()] = values.join(', ');
  });
  return _Res(pathAndQuery, response.statusCode, seen, body);
}

// ---------------------------------------------------------------------

void main() {
  group('D1 constants', () {
    test('D1 the three constants and the unchanged listing', () {
      expect(testerGroupUrl, 'https://groups.google.com/g/ludo-rng-testers',
          reason: 'D1 testerGroupUrl. ${_repro('D1 the three constants')}');
      expect(
          testerOptInUrl, 'https://play.google.com/apps/testing/app.fayad.ludo',
          reason: 'D1 testerOptInUrl. ${_repro('D1 the three constants')}');
      expect(playClosedTest, isTrue,
          reason: 'D1 playClosedTest is true until the day of promotion. '
              '${_repro('D1 the three constants')}');
      expect(
        playStoreListingUrl,
        'https://play.google.com/store/apps/details?id=app.fayad.ludo',
        reason: 'D1 playStoreListingUrl keeps its name and value. '
            '${_repro('D1 the three constants')}',
      );
      expect(androidPackageName, 'app.fayad.ludo');
    });
  });

  group('D2 defaults', () {
    test('D2 omitting closedTest equals closedTest: playClosedTest', () {
      const String name = 'D2 omitting closedTest follows playClosedTest';
      expect(buildOpenInAppUrl(_code),
          buildOpenInAppUrl(_code, closedTest: playClosedTest),
          reason: _repro(name));
      for (final String l in <String>['en', 'ar']) {
        expect(
            buildRoomLandingPageHtml(_code, language: l),
            buildRoomLandingPageHtml(_code,
                language: l, closedTest: playClosedTest),
            reason: 'room $l. ${_repro(name)}');
        expect(buildHomePageHtml(language: l),
            buildHomePageHtml(language: l, closedTest: playClosedTest),
            reason: 'home $l. ${_repro(name)}');
        for (final bool cut in <bool>[true, false]) {
          expect(
              buildLinkNotFoundHtml(cutInvite: cut, language: l),
              buildLinkNotFoundHtml(
                  cutInvite: cut, language: l, closedTest: playClosedTest),
              reason: '404 cut=$cut $l. ${_repro(name)}');
        }
      }
    });

    test('D2 every existing call shape still answers', () {
      const String name = 'D2 existing call shapes';
      expect(buildOpenInAppUrl(_code), isNotEmpty, reason: _repro(name));
      expect(buildRoomLandingPageHtml(_code), isNotEmpty, reason: _repro(name));
      expect(buildHomePageHtml(), isNotEmpty, reason: _repro(name));
      expect(buildLinkNotFoundHtml(cutInvite: true), isNotEmpty,
          reason: _repro(name));
    });
  });

  group('D3 public mode is today, byte for byte', () {
    test('D3 the goldens are the public listing pages', () async {
      const String name = 'D3 the goldens are the public listing pages';
      for (final String f in <String>[
        'room_en.html',
        'room_ar.html',
        'home_en.html',
        'home_ar.html',
        'notfound_cut_en.html',
        'notfound_cut_ar.html',
        'notfound_plain_en.html',
      ]) {
        final String g = await _golden(f);
        expect(g, contains(_listingUrl), reason: '$f. ${_repro(name)}');
        expect(g, isNot(contains('tester-steps')),
            reason: 'golden $f already carries the tester block; it must be '
                'rendered from a828fb5. ${_repro(name)}');
      }
    });

    final Map<String, String Function()> builders = <String, String Function()>{
      'room_en.html': () =>
          buildRoomLandingPageHtml(_code, language: 'en', closedTest: false),
      'room_ar.html': () =>
          buildRoomLandingPageHtml(_code, language: 'ar', closedTest: false),
      'home_en.html': () =>
          buildHomePageHtml(language: 'en', closedTest: false),
      'home_ar.html': () =>
          buildHomePageHtml(language: 'ar', closedTest: false),
      'notfound_cut_en.html': () => buildLinkNotFoundHtml(
          cutInvite: true, language: 'en', closedTest: false),
      'notfound_cut_ar.html': () => buildLinkNotFoundHtml(
          cutInvite: true, language: 'ar', closedTest: false),
      'notfound_plain_en.html': () => buildLinkNotFoundHtml(
          cutInvite: false, language: 'en', closedTest: false),
    };
    builders.forEach((String file, String Function() build) {
      test('D3 closedTest: false equals the golden $file', () async {
        final String name = 'D3 closedTest false equals golden $file';
        final String golden = await _golden(file);
        final String got = build();
        expect(got == golden, isTrue,
            reason: 'D3: with closedTest: false the page must equal what '
                'a828fb5 renders. ${_firstDiff(golden, got)}. ${_repro(name)}');
      });
    });

    test('D3 closedTest: false with no language equals the English golden',
        () async {
      const String name = 'D3 closedTest false default language';
      expect(
          buildHomePageHtml(closedTest: false), await _golden('home_en.html'),
          reason: _repro(name));
      expect(buildRoomLandingPageHtml(_code, closedTest: false),
          await _golden('room_en.html'),
          reason: _repro(name));
      expect(buildLinkNotFoundHtml(cutInvite: false, closedTest: false),
          await _golden('notfound_plain_en.html'),
          reason: _repro(name));
    });

    test('D3 the intent URL in public mode is today for both languages', () {
      const String name = 'D3 intent URL in public mode';
      const String today = 'intent://ludo.provefair.app/r/K7M2QP#Intent;'
          'scheme=https;package=app.fayad.ludo;'
          'S.browser_fallback_url=https%3A%2F%2Fplay.google.com%2Fstore%2F'
          'apps%2Fdetails%3Fid%3Dapp.fayad.ludo;end';
      for (final String l in <String>['en', 'ar', 'fr']) {
        expect(
            buildOpenInAppUrl('K7M2QP', language: l, closedTest: false), today,
            reason: 'language $l. ${_repro(name)}');
      }
    });

    test('D3 closed-test pages differ from the public ones', () async {
      const String name = 'D3 closed pages differ from public pages';
      expect(buildHomePageHtml(language: 'en', closedTest: true),
          isNot(await _golden('home_en.html')),
          reason: 'closedTest: true returned the public home page. '
              '${_repro(name)}');
      expect(buildRoomLandingPageHtml(_code, language: 'ar', closedTest: true),
          isNot(await _golden('room_ar.html')),
          reason: 'closedTest: true returned the public room page. '
              '${_repro(name)}');
    });
  });

  group('D4a the intent fallback', () {
    String expectedIntent(String code, String langOut) =>
        'intent://ludo.provefair.app/r/$code#Intent;scheme=https;'
        'package=app.fayad.ludo;'
        'S.browser_fallback_url=${Uri.encodeComponent('https://ludo.provefair.app/r/$code?lang=$langOut#tester-steps')};end';

    test('D4a en and ar carry the steps of their own language', () {
      const String name = 'D4a fallback per language';
      expect(buildOpenInAppUrl('K7M2QP', language: 'en', closedTest: true),
          expectedIntent('K7M2QP', 'en'),
          reason: 'en. ${_repro(name)}');
      expect(buildOpenInAppUrl('K7M2QP', language: 'ar', closedTest: true),
          expectedIntent('K7M2QP', 'ar'),
          reason: 'ar. ${_repro(name)}');
      expect(buildOpenInAppUrl('Z98765', language: 'ar', closedTest: true),
          expectedIntent('Z98765', 'ar'),
          reason: 'second code. ${_repro(name)}');
    });

    test('D4a omitting the language is English', () {
      const String name = 'D4a default language';
      expect(buildOpenInAppUrl('K7M2QP', closedTest: true),
          expectedIntent('K7M2QP', 'en'),
          reason: _repro(name));
    });

    test('D4a any language but exactly ar gives lang=en', () {
      const String name = 'D4a fr gives lang=en';
      for (final String l in <String>['fr', '', 'AR', 'ar-AE', 'xx', ' ar']) {
        expect(buildOpenInAppUrl('K7M2QP', language: l, closedTest: true),
            expectedIntent('K7M2QP', 'en'),
            reason: 'language "$l" must give lang=en. ${_repro(name)}');
      }
    });

    test('D4a the fallback never carries the bare Play listing', () {
      const String name = 'D4a no store listing in the fallback';
      final String url =
          buildOpenInAppUrl('K7M2QP', language: 'ar', closedTest: true);
      expect(url, isNot(contains(Uri.encodeComponent(playStoreListingUrl))),
          reason: 'the closed-test fallback must not be the 404 listing. '
              'got $url. ${_repro(name)}');
      expect(url, contains(Uri.encodeComponent('#tester-steps')),
          reason: 'got $url. ${_repro(name)}');
    });

    test('D4a the room page open button passes the page language', () {
      const String name = 'D4a room page open-app href per language';
      for (final String l in <String>['en', 'ar', 'fr']) {
        final String html =
            buildRoomLandingPageHtml(_code, language: l, closedTest: true);
        final List<_Tag> tags = _tagsWithId(html, 'open-app');
        expect(tags.length, 1, reason: 'open-app count on $l. ${_repro(name)}');
        expect(tags.single.attrs['href'],
            buildOpenInAppUrl(_code, language: l, closedTest: true),
            reason: 'the $l page open-app href (unescaped) must equal '
                'buildOpenInAppUrl(code, language: $l). ${_repro(name)}');
      }
      final String ar = buildRoomLandingPageHtml(_code, language: 'ar');
      expect(_tagsWithId(ar, 'open-app').single.attrs['href'],
          expectedIntent(_code, 'ar'),
          reason: 'a person on the Arabic page who taps Open without the app '
              'must land on the Arabic steps. ${_repro(name)}');
    });
  });

  group('D4b the block', () {
    for (final _PageCase p in _closedPages()) {
      test('D4b ${p.name}: each id once, steps in order inside an ol', () {
        final String name = 'D4b ${p.name} ids and order';
        for (final String id in _stepIds) {
          expect(_tagsWithId(p.html, id).length, 1,
              reason: 'expected exactly one element with id="$id" on the '
                  '${p.name}. ${_repro(name)}');
        }
        final _Tag ol = _tagsWithId(p.html, 'tester-steps').single;
        expect(ol.name, 'ol',
            reason: '#tester-steps must be an <ol>, got <${ol.name}>. '
                '${_repro(name)}');
        expect(ol.attrs['class'], 'steps', reason: _repro(name));
        final int olEnd = ol.openEnd + _inner(p.html, ol).length;
        final List<String> ids = <String>[
          'join-group',
          'become-tester',
          'get-app'
        ];
        int previous = ol.openEnd - 1;
        for (final String id in ids) {
          final _Tag a = _tagsWithId(p.html, id).single;
          expect(a.name, 'a', reason: '#$id must be an <a>. ${_repro(name)}');
          expect(a.attrs['class'], 'btn',
              reason: '#$id must carry class btn. ${_repro(name)}');
          expect(a.openStart, greaterThan(previous),
              reason: '#$id must come after the previous step. '
                  '${_repro(name)}');
          expect(a.openStart, lessThan(olEnd),
              reason: '#$id must sit inside #tester-steps. ${_repro(name)}');
          previous = a.openStart;
        }
        final int intro = _tagsWithId(p.html, 'tester-intro').single.openStart;
        final int wait = _tagsWithId(p.html, 'tester-wait').single.openStart;
        final int stay = _tagsWithId(p.html, 'tester-stay').single.openStart;
        expect(intro, lessThan(ol.openStart), reason: _repro(name));
        expect(olEnd, lessThan(wait), reason: _repro(name));
        expect(wait, lessThan(stay), reason: _repro(name));
        for (final String id in <String>[
          'tester-intro',
          'tester-wait',
          'tester-stay'
        ]) {
          final _Tag t = _tagsWithId(p.html, id).single;
          expect(t.name, 'p', reason: '#$id must be a <p>. ${_repro(name)}');
          expect(t.attrs['class'], 'hint',
              reason: '#$id must carry class hint. ${_repro(name)}');
        }
      });

      test('D4b ${p.name}: hrefs are the constants, escaped as served', () {
        final String name = 'D4b ${p.name} hrefs';
        final Map<String, String> want = <String, String>{
          'join-group': testerGroupUrl,
          'become-tester': testerOptInUrl,
          'get-app': playStoreListingUrl,
        };
        want.forEach((String id, String url) {
          final _Tag a = _tagsWithId(p.html, id).single;
          expect(a.attrs['href'], url,
              reason: '#$id href on the ${p.name}. ${_repro(name)}');
          expect(a.raw, contains('href="${_attributeEscaper.convert(url)}"'),
              reason: '#$id href must be served attribute-escaped. '
                  'got ${a.raw}. ${_repro(name)}');
        });
      });

      test('D4b ${p.name}: the block is exactly the contract markup', () {
        final String name = 'D4b ${p.name} block markup';
        final String served = _servedBlock(p.html);
        expect(served, isNotEmpty,
            reason: 'no block between #tester-intro and #tester-stay on the '
                '${p.name}. ${_repro(name)}');
        final String got = _collapseBetweenTags(_unescape(served));
        final String want = _collapseBetweenTags(_expectedBlock(p));
        expect(got == want, isTrue,
            reason: 'the block differs. ${_firstDiff(want, got)}. '
                '${_repro(name)}');
      });

      test('D4b ${p.name}: no script added, no external request', () {
        final String name = 'D4b ${p.name} scripts and references';
        final List<RegExpMatch> scripts =
            RegExp(r'<script\b([^>]*)>(.*?)</script>', dotAll: true)
                .allMatches(p.html)
                .toList();
        if (p.isRoom) {
          expect(scripts.length, 1,
              reason: 'the room page keeps exactly its /r/room.js script, '
                  'found ${scripts.length}. ${_repro(name)}');
          expect(_parseAttrs(scripts.single.group(1)!)['src'], '/r/room.js',
              reason: _repro(name));
          expect(scripts.single.group(2)!.trim(), isEmpty,
              reason: 'inline script text. ${_repro(name)}');
        } else {
          expect(scripts, isEmpty,
              reason: 'the ${p.name} must carry no script. ${_repro(name)}');
        }
        final String lower = p.html.toLowerCase();
        for (final String banned in <String>[
          '<img',
          '<link',
          '<iframe',
          '<form',
          '<object',
          '<embed',
          '@import',
          'url(',
          'srcset',
        ]) {
          expect(lower, isNot(contains(banned)),
              reason: 'the ${p.name} contains "$banned". ${_repro(name)}');
        }
        final RegExp ref = RegExp(
          r'''\s(?:href|src|action|formaction|poster|ping)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
          caseSensitive: false,
        );
        for (final RegExpMatch m in ref.allMatches(p.html)) {
          final String value = _unescape(m.group(1) ?? m.group(2)!);
          final bool relative = value.startsWith('/') || value.startsWith('?');
          if (relative) {
            continue;
          }
          final Uri? uri = Uri.tryParse(value);
          final String host = uri?.host ?? '';
          expect(
            <String>{
              'groups.google.com',
              'play.google.com',
              'ludo.provefair.app'
            }.contains(host),
            isTrue,
            reason: 'the ${p.name} references "$value", host "$host", which '
                'is not a relative path, groups.google.com or '
                'play.google.com. ${_repro(name)}',
          );
        }
      });

      test('D4b ${p.name}: the old install offer is gone', () {
        final String name = 'D4b ${p.name} old offer replaced';
        expect(p.html, isNot(contains('<p class="hint">')),
            reason: 'a bare <p class="hint"> is left on the ${p.name}; the '
                'block must replace the old hint. ${_repro(name)}');
        for (final String old in <String>[
          'New to Ludo RNG? Install it, then type this code on the home screen.',
          'جديد على Ludo RNG؟ ثبّته، ثم اكتب هذا الرمز في الشاشة الرئيسية.',
        ]) {
          expect(p.html, isNot(contains(old)),
              reason: 'the old hint "$old" is still on the ${p.name}. '
                  '${_repro(name)}');
        }
      });
    }

    for (final String l in <String>['en', 'ar']) {
      test('D4b room page $l: open, code and copy, block, fairness, switch',
          () {
        final String name = 'D4b room page $l element order';
        final String html =
            buildRoomLandingPageHtml(_code, language: l, closedTest: true);
        int at(String id) => _tagsWithId(html, id).single.openStart;
        final int fair = html.indexOf('<p class="fair">');
        expect(fair, greaterThan(0),
            reason: 'no fairness line. ${_repro(name)}');
        final List<int> order = <int>[
          at('open-app'),
          at('room-code'),
          at('copy-code'),
          at('tester-intro'),
          at('tester-stay'),
          fair,
          at('lang-switch'),
        ];
        final List<int> sorted = List<int>.from(order)..sort();
        expect(order, sorted,
            reason: 'expected open-app, room-code, copy-code, tester-intro, '
                'tester-stay, fairness line, lang-switch in that order; '
                'offsets were $order. ${_repro(name)}');
      });
    }
  });

  group('D4c the words', () {
    for (final _PageCase p in _closedPages()) {
      test('D4c ${p.name}: every text byte exact', () {
        final String name = 'D4c ${p.name} words';
        final Map<String, String> want = <String, String>{
          'tester-intro': p.intro,
          'join-group': p.w['join']!,
          'become-tester': p.w['become']!,
          'get-app': p.w['get']!,
          'tester-wait': p.wait,
          'tester-stay': p.w['stay']!,
        };
        want.forEach((String id, String text) {
          final _Tag t = _tagsWithId(p.html, id).single;
          final String got = _unescape(_inner(p.html, t));
          expect(got, text,
              reason: 'text of #$id on the ${p.name}: expected "$text", got '
                  '"$got". ${_repro(name)}');
        });
      });
    }

    test('D4c the table itself has no em-dash and no forbidden phrase', () {
      const String name = 'D4c table hygiene';
      for (final String l in _words.keys) {
        _words[l]!.forEach((String key, String text) {
          expect(text, isNot(contains('—')),
              reason: '$l $key. ${_repro(name)}');
        });
      }
    });
  });

  group('D4d the rest of each page is kept', () {
    for (final _PageCase p
        in _closedPages().where((_PageCase p) => p.golden != null)) {
      test('D4d ${p.name}: heading, lead, fairness, links and title kept',
          () async {
        final String name = 'D4d ${p.name} kept parts';
        final String golden = await _golden(p.golden!);
        final List<RegExp> keep = <RegExp>[
          RegExp(r'<title>.*?</title>', dotAll: true),
          RegExp(r'<h1>.*?</h1>', dotAll: true),
          RegExp(r'<p class="lead">.*?</p>', dotAll: true),
          RegExp(r'<p class="fair">.*?</p>', dotAll: true),
          RegExp(r'<p class="label">.*?</p>', dotAll: true),
          RegExp(r'<a id="privacy"[^>]*>.*?</a>', dotAll: true),
          RegExp(r'<a id="home"[^>]*>.*?</a>', dotAll: true),
          RegExp(r'<a id="lang-switch"[^>]*>.*?</a>', dotAll: true),
          RegExp(r'<div id="room-code"[^>]*>.*?</div>', dotAll: true),
          RegExp(r'<button[^>]*id="copy-code"[^>]*>.*?</button>', dotAll: true),
          RegExp(r'<html[^>]*>'),
        ];
        int kept = 0;
        for (final RegExp r in keep) {
          for (final RegExpMatch m in r.allMatches(golden)) {
            kept += 1;
            expect(p.html, contains(m.group(0)!),
                reason: 'D4d: the ${p.name} lost "${m.group(0)}" that '
                    'a828fb5 carries. ${_repro(name)}');
          }
        }
        expect(kept, greaterThanOrEqualTo(5),
            reason: 'the golden ${p.golden} yielded only $kept kept parts; '
                'the pattern list is out of step with the page. '
                '${_repro(name)}');
      });
    }
  });

  group('D5 layout and style', () {
    for (final _PageCase p in _closedPages()) {
      test('D5 ${p.name}: the ordered list shows its numbers, mirrored', () {
        final String name = 'D5 ${p.name} ordered list';
        final List<_Rule> rules = _rules(p.html);
        final Set<String> olTargets = <String>{
          '.steps',
          'ol.steps',
          '#tester-steps',
          'ol'
        };
        expect(
            rules.any((_Rule r) => <String>{
                  '.steps',
                  'ol.steps',
                  '#tester-steps'
                }.contains(r.last)),
            isTrue,
            reason: 'the style has no .steps rule. ${_repro(name)}');
        final Set<String> liTargets = <String>{'li'};
        for (final Set<String> targets in <Set<String>>[olTargets, liTargets]) {
          for (final String prop in <String>['list-style', 'list-style-type']) {
            final String? v = _effective(rules, targets, prop);
            expect(v == null || !v.contains('none'), isTrue,
                reason: '$prop: $v hides the numbers of the steps. '
                    '${_repro(name)}');
          }
          final String? display = _effective(rules, targets, 'display');
          expect(
              display == null || display == 'block' || display == 'list-item',
              isTrue,
              reason: 'display: $display on ${targets.first} removes the '
                  'list markers. ${_repro(name)}');
          final String? dir = _effective(rules, targets, 'direction');
          expect(dir == null || dir == 'inherit', isTrue,
              reason: 'direction: $dir on the steps breaks the mirrored '
                  'layout. ${_repro(name)}');
          final String? align = _effective(rules, targets, 'text-align');
          expect(align == null || (align != 'left' && align != 'right'), isTrue,
              reason: 'text-align: $align on the steps is not mirrored. '
                  '${_repro(name)}');
        }
        final String? position =
            _effective(rules, olTargets, 'list-style-position');
        bool anyZero = false;
        bool anyRoom = false;
        final List<String> seen = <String>[];
        for (final String prop in <String>[
          'padding',
          'padding-left',
          'padding-right',
          'padding-inline',
          'padding-inline-start'
        ]) {
          final String? v = _effective(rules, olTargets, prop);
          if (v == null) {
            continue;
          }
          seen.add('$prop: $v');
          final bool zero = v
              .split(RegExp(r'\s+'))
              .every((String t) => RegExp(r'^0(\.0+)?[a-z%]*$').hasMatch(t));
          if (zero) {
            anyZero = true;
          } else {
            anyRoom = true;
          }
        }
        expect(anyZero && !anyRoom && position != 'inside', isFalse,
            reason: 'the list padding is zero on every side ($seen) and the '
                'markers are outside, so its numbers have no room. '
                '${_repro(name)}');
        final _Tag ol = _tagsWithId(p.html, 'tester-steps').single;
        expect(ol.attrs.containsKey('dir'), isFalse,
            reason: 'the <ol> must follow the page direction, it carries '
                'dir="${ol.attrs['dir']}". ${_repro(name)}');
        expect(
            p.html,
            contains(
                p.isAr ? '<html lang="ar" dir="rtl">' : '<html lang="en">'),
            reason: _repro(name));
      });

      test('D5 ${p.name}: the three links are 3rem tall, full width and wrap',
          () {
        final String name = 'D5 ${p.name} link size';
        final List<_Rule> rules = _rules(p.html);
        for (final String id in <String>[
          'join-group',
          'become-tester',
          'get-app'
        ]) {
          final Set<String> targets = <String>{
            '.btn',
            'a.btn',
            'a',
            '#$id',
            'a#$id'
          };
          final double? minHeight =
              _px(_effective(rules, targets, 'min-height'));
          expect(minHeight, isNotNull,
              reason: '#$id has no min-height in rem or px. ${_repro(name)}');
          expect(minHeight! >= 48, isTrue,
              reason: '#$id min-height is $minHeight px, below 48. '
                  '${_repro(name)}');
          final double? height = _px(_effective(rules, targets, 'height'));
          expect(height == null || height >= 48, isTrue,
              reason: '#$id height $height px is below 48. ${_repro(name)}');
          expect(_effective(rules, targets, 'max-height'), isNull,
              reason: '#$id has a max-height. ${_repro(name)}');
          expect(_effective(rules, targets, 'width'), '100%',
              reason: '#$id must be full width. ${_repro(name)}');
          for (final String prop in <String>[
            'white-space',
            'text-overflow',
            'overflow'
          ]) {
            final String? v = _effective(rules, targets, prop);
            expect(
                v == null ||
                    (!v.contains('nowrap') &&
                        !v.contains('ellipsis') &&
                        !v.contains('hidden')),
                isTrue,
                reason: '#$id sets $prop: $v, so its text would be cut at '
                    '320 px instead of wrapping. ${_repro(name)}');
          }
        }
        final bool breaks = rules.any((_Rule r) {
          final String? ow = r.decls['overflow-wrap'] ?? r.decls['word-wrap'];
          final String? wb = r.decls['word-break'];
          final bool reaches = <String>{
            'body',
            '.card',
            '.btn',
            'a.btn',
            'a',
            'main'
          }.contains(r.last);
          return reaches &&
              ((ow != null &&
                      (ow.contains('anywhere') || ow.contains('break-word'))) ||
                  (wb != null &&
                      (wb.contains('break-all') || wb.contains('break-word'))));
        });
        expect(breaks, isTrue,
            reason: 'no rule lets long words wrap on the ${p.name} '
                '(overflow-wrap: anywhere on body, card or the links). '
                '${_repro(name)}');
        for (final _Rule r in rules) {
          expect(r.decls['white-space'] ?? '', isNot(contains('nowrap')),
              reason: 'rule ${r.selector} sets white-space: nowrap. '
                  '${_repro(name)}');
        }
      });

      if (p.golden != null) {
        test('D5 ${p.name}: no style rule of a828fb5 is changed', () async {
          final String name = 'D5 ${p.name} old style kept';
          final String golden = await _golden(p.golden!);
          final Set<String> now =
              _rules(p.html).map((_Rule r) => r.canonical).toSet();
          for (final _Rule r in _rules(golden)) {
            if (r.selector.contains('#get-app')) {
              continue;
            }
            expect(now.contains(r.canonical), isTrue,
                reason: 'D5: the rule "${r.canonical}" of a828fb5 is gone or '
                    'changed on the ${p.name}. Only a .steps rule and what '
                    'keeps the links 3rem and full width may be added. '
                    '${_repro(name)}');
          }
        });
      }
    }
  });

  group('7 wording', () {
    test('every closed-test page has no em-dash and no "provably fair"', () {
      const String name = '7 no em-dash, no provably fair';
      for (final _PageCase p in _closedPages()) {
        expect(p.html, isNot(contains('—')),
            reason: 'the ${p.name} contains an em-dash. ${_repro(name)}');
        expect(p.html.toLowerCase(), isNot(contains('provably fair')),
            reason: 'the ${p.name} says "provably fair". ${_repro(name)}');
      }
    });
  });

  group('6 over the real routes', () {
    setUpAll(() async {
      final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 12));
      _server = WireServer(
        registry: RoomRegistry(clock: clock, secure: Random.secure()),
        rateLimiter: RateLimiter(clock: clock),
        clock: clock,
      );
      await _server.start(address: InternetAddress.loopbackIPv4, port: 0);
      _client = HttpClient();
    });

    tearDownAll(() async {
      _client.close(force: true);
      await _server.close();
    });

    final List<List<Object?>> routes = <List<Object?>>[
      <Object?>['/r/ABCDEF', 200, 'room', 'en'],
      <Object?>['/r/ABCDEF?lang=ar', 200, 'room', 'ar'],
      <Object?>['/', 200, 'home', 'en'],
      <Object?>['/?lang=ar', 200, 'home', 'ar'],
      <Object?>['/r/AB', 404, 'cut', 'en'],
      <Object?>['/r/AB?lang=ar', 404, 'cut', 'ar'],
      <Object?>['/nope', 404, 'plain', 'en'],
      <Object?>['/nope?lang=ar', 404, 'plain', 'ar'],
    ];
    for (final List<Object?> r in routes) {
      final String path = r[0]! as String;
      final int status = r[1]! as int;
      final String kind = r[2]! as String;
      final String lang = r[3]! as String;
      test('6 GET $path answers $status with the tester steps', () async {
        final String name = '6 GET $path';
        final _Res res = await _get(path);
        expect(res.status, status,
            reason: 'GET $path must answer $status as today. '
                '${_repro(name)}. ${res.describe()}');
        final List<_Tag> steps = _tagsWithId(res.body, 'tester-steps');
        expect(steps.length, 1,
            reason: 'GET $path must carry exactly one #tester-steps, found '
                '${steps.length}. ${_repro(name)}. ${res.describe()}');
        expect(steps.single.name, 'ol', reason: _repro(name));
        final List<_Tag> join = _tagsWithId(res.body, 'join-group');
        expect(join.length, 1, reason: '#join-group count. ${_repro(name)}');
        expect(join.single.attrs['href'], testerGroupUrl,
            reason: '#join-group href on GET $path. ${_repro(name)}');
        expect(_tagsWithId(res.body, 'become-tester').single.attrs['href'],
            testerOptInUrl,
            reason: '#become-tester href. ${_repro(name)}');
        expect(_tagsWithId(res.body, 'get-app').single.attrs['href'],
            playStoreListingUrl,
            reason: '#get-app href. ${_repro(name)}');

        final String built;
        switch (kind) {
          case 'room':
            built = buildRoomLandingPageHtml(_code, language: lang);
          case 'home':
            built = buildHomePageHtml(language: lang);
          case 'cut':
            built = buildLinkNotFoundHtml(cutInvite: true, language: lang);
          default:
            built = buildLinkNotFoundHtml(cutInvite: false, language: lang);
        }
        expect(res.body == built, isTrue,
            reason: 'the route must serve the builder output unchanged. '
                '${_firstDiff(built, res.body)}. ${_repro(name)}');
      });

      test('6 GET $path keeps its headers', () async {
        final String name = '6 headers of GET $path';
        final _Res res = await _get(path);
        final String cache = path.startsWith('/?') || path == '/'
            ? 'public, max-age=300'
            : 'no-store';
        final Map<String, String> want = <String, String>{
          'content-type': 'text/html; charset=utf-8',
          'cache-control': cache,
          'vary': 'accept-language',
          'referrer-policy': 'no-referrer',
          'x-content-type-options': 'nosniff',
          'content-security-policy': _expectedCsp,
        };
        want.forEach((String header, String value) {
          expect(res.headers[header], value,
              reason: 'header $header of GET $path. ${_repro(name)}. '
                  '${res.describe()}');
        });
      });
    }

    test('6 the real room page keeps its script route', () async {
      const String name = '6 room.js route';
      final _Res res = await _get('/r/room.js');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
    });

    test('7 no served page carries an em-dash or "provably fair"', () async {
      const String name = '7 served pages wording';
      for (final List<Object?> r in routes) {
        final _Res res = await _get(r[0]! as String);
        expect(res.body, isNot(contains('—')),
            reason: 'GET ${r[0]} has an em-dash. ${_repro(name)}');
        expect(res.body.toLowerCase(), isNot(contains('provably fair')),
            reason: 'GET ${r[0]} says "provably fair". ${_repro(name)}');
      }
    });
  });
}

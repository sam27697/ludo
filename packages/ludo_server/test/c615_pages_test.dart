// Proof for order 615 / C-615 (work/ludo/orders/615-branded-not-found-and-home.md),
// decisions D1 to D4, against a real WireServer on an ephemeral port with
// real HTTP requests, real raw-socket upgrade requests and a real WebSocket
// client. Written from the contract, not from the implementation.
//
// Only public names that exist on the base commit are used here
// (`buildRoomLandingPageHtml`, `roomLinkJsSource`, `playStoreListingUrl`), so
// this file compiles and runs against the commit before the contract was
// implemented; the new pages are only ever reached over HTTP.
//
// Every case is deterministic. The one random input is the room code the
// server mints for the WebSocket cases, printed in those cases' failure text.
// Every failure text names the scenario and the command that re-runs it.
//
// Interpretations the contract leaves open are listed where they are made:
//
// - D1 says HEAD answers "same headers". The content-length of a HEAD
//   answer is the length of its (empty) body, so it is left out of the
//   comparison with GET; every other header must be equal.
// - D2 names the lead only as "lead". The test finds it as a paragraph whose
//   text equals the lead, and takes the `.fair` line by its class, which D2
//   does name.
// - D1 does not say which wins for an upgrade request to a malformed
//   `/r/<x>`; no case sends one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ludo_server/ludo_server.dart';
import 'package:ludo_server/src/link_pages.dart'
    show buildRoomLandingPageHtml, playStoreListingUrl, roomLinkJsSource;
import 'package:test/test.dart';

const String _testFile = 'test/c615_pages_test.dart';

/// The room page's policy, verbatim (C-457 D7), and the one D1 requires on
/// every page the order adds.
const String _expectedCsp = "default-src 'none'; script-src 'self'; "
    "style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'none'";

/// sha256 of `buildRoomLandingPageHtml('ABCDEF', language: ...)` computed on
/// base 0f98f7c, by calling the function in a scratch `dart run` file and
/// hashing the UTF-8 bytes of the returned string.
const String _roomPageEnSha =
    'a71cce51d2df606b0a1173dfc4980d5382c08bfa033284053cf3d0a8640eeb38';
const String _roomPageArSha =
    '8afb959035ef1f420c658752aa9b8d029f56e9eacb919e4ca07ac770dbad246c';

/// sha256 of `roomLinkJsSource` on the same base, computed the same way.
const String _roomJsSha =
    '1ec8b167bd6cb64d51047ff731148a1521cfcae17d9f033bda41f608ffbb6ff1';

/// sha256 of the room page the server now serves (closed-test mode, order
/// 633), for code ABCDEF, computed on 3a7af8a by calling
/// `buildRoomLandingPageHtml('ABCDEF', language: ...)` in a scratch `dart run`
/// file and hashing the UTF-8 bytes of the returned string. The words and the
/// markup of that page are proved in c633_tester_path_test.dart; these two
/// only freeze it.
const String _roomPageClosedEnSha =
    'e55adb2a0c72b4913dcfbaeb1ea35a7339fdbe8386f8249b1103fc2ff37f50b6';
const String _roomPageClosedArSha =
    'ffc31d265d2380f299a97da7ee2f8a74f9dd394dcf2f90adcdddeed2d568b407';

/// The headers the room page answers with on the base, for `/r/ABCDEF`.
const Map<String, String> _roomPageHeaders = <String, String>{
  'content-type': 'text/html; charset=utf-8',
  'vary': 'accept-language',
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'content-security-policy': _expectedCsp,
};

const String _arabicMarkup = 'lang="ar" dir="rtl"';

/// D2 and D3 words, exactly as the contract tables give them.
const Map<String, Map<String, String>> _home = <String, Map<String, String>>{
  'en': <String, String>{
    'h1': 'Ludo RNG',
    'lead':
        'Ludo with your friends in a private room. Make a room, send the link, '
            'play.',
    'get': 'Get Ludo RNG on Google Play',
    'fair': 'Every roll is verifiable. At the end of every game, Check the '
        'rolls shows each one.',
    'privacy': 'Privacy',
    'switchText': 'العربية',
    'switchHref': '?lang=ar',
  },
  'ar': <String, String>{
    'h1': 'Ludo RNG',
    'lead': 'لودو مع أصحابك في غرفة خاصة. أنشئ غرفة، أرسل الرابط، والعب.',
    'get': 'احصل على Ludo RNG من Google Play',
    'fair': 'كل رمية قابلة للتحقق. في نهاية كل لعبة، يعرض لك «تحقق من الرميات» '
        'كل رمية.',
    'privacy': 'الخصوصية',
    'switchText': 'English',
    'switchHref': '?lang=en',
  },
};

const Map<String, Map<String, String>> _cut = <String, Map<String, String>>{
  'en': <String, String>{
    'h1': 'This invite link looks cut off',
    'lead': 'Ask your friend to send the link again, or open Ludo RNG and type '
        'the room code they give you.',
    'get': 'Get Ludo RNG on Google Play',
    'home': 'Ludo RNG home',
    'switchText': 'العربية',
    'switchHref': '?lang=ar',
  },
  'ar': <String, String>{
    'h1': 'يبدو أن رابط الدعوة ناقص',
    'lead': 'اطلب من صديقك أن يرسل الرابط مرة ثانية، أو افتح Ludo RNG واكتب '
        'رمز الغرفة الذي يعطيك إياه.',
    'get': 'احصل على Ludo RNG من Google Play',
    'home': 'الصفحة الرئيسية لـ Ludo RNG',
    'switchText': 'English',
    'switchHref': '?lang=en',
  },
};

const Map<String, Map<String, String>> _nothing = <String, Map<String, String>>{
  'en': <String, String>{
    'h1': 'Nothing here',
    'lead': 'This page does not exist.',
    'get': 'Get Ludo RNG on Google Play',
    'home': 'Ludo RNG home',
    'switchText': 'العربية',
    'switchHref': '?lang=ar',
  },
  'ar': <String, String>{
    'h1': 'لا شيء هنا',
    'lead': 'هذه الصفحة غير موجودة.',
    'get': 'احصل على Ludo RNG من Google Play',
    'home': 'الصفحة الرئيسية لـ Ludo RNG',
    'switchText': 'English',
    'switchHref': '?lang=en',
  },
};

// ---------------------------------------------------------------------
// Failure text
// ---------------------------------------------------------------------

String _repro(String scenario) =>
    'scenario: $scenario. Deterministic, no seed. Reproduce with: cd '
    'packages/ludo_server && dart test $_testFile -n "$scenario"';

// ---------------------------------------------------------------------
// Server and HTTP plumbing
// ---------------------------------------------------------------------

late WireServer _server;
late HttpClient _client;

int get _port => _server.port;

Uri _uri(String pathAndQuery) =>
    Uri.parse('http://127.0.0.1:$_port$pathAndQuery');

class _Res {
  _Res(this.method, this.path, this.status, this.headers, this.body);

  final String method;
  final String path;
  final int status;
  final Map<String, String> headers;
  final String body;

  String header(String name) => headers[name.toLowerCase()] ?? '';

  String describe() =>
      '$method $path -> $status, headers $headers, body (first 300 chars): '
      '${body.length > 300 ? body.substring(0, 300) : body}';
}

Future<_Res> _request(
  String method,
  String pathAndQuery, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClientRequest request =
      await _client.openUrl(method, _uri(pathAndQuery));
  headers.forEach(request.headers.set);
  final HttpClientResponse response = await request.close();
  final String body = await response.transform(utf8.decoder).join();
  final Map<String, String> seen = <String, String>{};
  response.headers.forEach((String name, List<String> values) {
    seen[name.toLowerCase()] = values.join(', ');
  });
  return _Res(method, pathAndQuery, response.statusCode, seen, body);
}

Future<_Res> _get(String pathAndQuery, {String? acceptLanguage}) => _request(
      'GET',
      pathAndQuery,
      headers: <String, String>{
        if (acceptLanguage != null) 'accept-language': acceptLanguage,
      },
    );

String _sha(String text) => sha256.convert(utf8.encode(text)).toString();

// ---------------------------------------------------------------------
// HTML helpers (package:html is not a dependency)
// ---------------------------------------------------------------------

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

String _collapse(String input) => input.replaceAll(RegExp(r'\s+'), ' ').trim();

class _Tag {
  _Tag(this.name, this.attrs, this.openEnd);

  final String name;
  final Map<String, String> attrs;
  final int openEnd;
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

List<_Tag> _allTags(String html) {
  final List<_Tag> found = <_Tag>[];
  final RegExp open = RegExp(r'<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>');
  for (final RegExpMatch m in open.allMatches(html)) {
    found.add(_Tag(m.group(1)!.toLowerCase(), _parseAttrs(m.group(2)!), m.end));
  }
  return found;
}

List<_Tag> _tagsWithId(String html, String id) =>
    _allTags(html).where((_Tag t) => t.attrs['id'] == id).toList();

List<_Tag> _tagsWithClass(String html, String cls) => _allTags(html)
    .where(
      (_Tag t) => (t.attrs['class'] ?? '').split(RegExp(r'\s+')).contains(cls),
    )
    .toList();

String _stripTags(String markup) =>
    _collapse(_unescape(markup.replaceAll(RegExp(r'<[^>]*>'), ' ')));

/// The text between [tag]'s opening tag and the next closing tag of the same
/// name. None of the elements read this way nests its own name.
String _inner(String html, _Tag tag) {
  final int close = html.indexOf('</${tag.name}', tag.openEnd);
  return _stripTags(
    html.substring(tag.openEnd, close < 0 ? html.length : close),
  );
}

_Tag _one(_Res res, List<_Tag> tags, String what, String scenario) {
  if (tags.length != 1) {
    fail(
      'expected exactly one $what on ${res.method} ${res.path}, found '
      '${tags.length}. ${_repro(scenario)}. ${res.describe()}',
    );
  }
  return tags.single;
}

List<String> _paragraphs(String html) => _allTags(html)
    .where((_Tag t) => t.name == 'p')
    .map((_Tag t) => _inner(html, t))
    .toList();

String _titleText(String html) {
  final RegExpMatch? m =
      RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(html);
  return m == null ? '' : _collapse(_unescape(m.group(1)!));
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

// ---------------------------------------------------------------------
// Shared assertions
// ---------------------------------------------------------------------

/// D1's header block for a page the order serves. [cache] is the
/// `cache-control` value for that page.
void _expectPageHeaders(_Res res, String cache, String scenario) {
  final Map<String, String> want = <String, String>{
    'content-type': 'text/html; charset=utf-8',
    'vary': 'accept-language',
    'cache-control': cache,
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'content-security-policy': _expectedCsp,
  };
  want.forEach((String name, String value) {
    expect(
      res.header(name),
      value,
      reason: 'expected header $name: "$value" on ${res.method} ${res.path}, '
          'got "${res.header(name)}". ${_repro(scenario)}. ${res.describe()}',
    );
  });
}

void _expectStatus(_Res res, int status, String scenario) {
  expect(
    res.status,
    status,
    reason: 'expected status $status on ${res.method} ${res.path}, got '
        '${res.status}. ${_repro(scenario)}. ${res.describe()}',
  );
}

void _expectEmptyBody(_Res res, String scenario) {
  expect(
    res.body,
    isEmpty,
    reason: 'expected an empty body on ${res.method} ${res.path}, got '
        '${res.body.length} chars. ${_repro(scenario)}. ${res.describe()}',
  );
}

void _expectLookAndNoScript(_Res res, String scenario) {
  final String style = _styleText(res.body);
  expect(
    style,
    contains('linear-gradient'),
    reason: 'expected the felt gradient in the page style on ${res.path}. '
        '${_repro(scenario)}. ${res.describe()}',
  );
  expect(
    style,
    contains('3rem'),
    reason: 'expected 3rem tap areas in the page style on ${res.path}. '
        '${_repro(scenario)}. ${res.describe()}',
  );
  final List<_Tag> seats = _tagsWithClass(res.body, 'seats');
  _one(res, seats, 'element with class "seats"', scenario);
  final RegExpMatch? dots = RegExp(
    r'class="seats"[^>]*>((?:\s*<span\b[^>]*></span>){4})\s*</div>',
  ).firstMatch(res.body);
  expect(
    dots,
    isNotNull,
    reason: 'expected four seat dots (four empty spans) inside the seats '
        'element on ${res.path}. ${_repro(scenario)}. ${res.describe()}',
  );
  expect(
    res.body.toLowerCase(),
    isNot(contains('<script')),
    reason: 'expected no script element on ${res.path}. ${_repro(scenario)}. '
        '${res.describe()}',
  );
}

void _expectLanguage(_Res res, String lang, String scenario) {
  if (lang == 'ar') {
    expect(
      res.body,
      contains(_arabicMarkup),
      reason: 'expected the <html> element to carry $_arabicMarkup on '
          '${res.path}. ${_repro(scenario)}. ${res.describe()}',
    );
  } else {
    expect(
      res.body,
      isNot(contains('dir="rtl"')),
      reason: 'expected no dir="rtl" in the English page on ${res.path}. '
          '${_repro(scenario)}. ${res.describe()}',
    );
    expect(
      res.body,
      contains('lang="en"'),
      reason: 'expected lang="en" on ${res.path}. ${_repro(scenario)}. '
          '${res.describe()}',
    );
  }
}

void _expectSharedLinks(
  _Res res,
  Map<String, String> words,
  String scenario, {
  required bool withHome,
}) {
  final _Tag get =
      _one(res, _tagsWithId(res.body, 'get-app'), 'id="get-app"', scenario);
  expect(get.name, 'a', reason: '#get-app must be a link. ${_repro(scenario)}');
  expect(
    get.attrs['href'],
    playStoreListingUrl,
    reason: '#get-app href on ${res.path}. ${_repro(scenario)}. '
        '${res.describe()}',
  );
  expect(
    _inner(res.body, get),
    words['get'],
    reason: '#get-app text on ${res.path}. ${_repro(scenario)}. '
        '${res.describe()}',
  );
  if (withHome) {
    final _Tag home =
        _one(res, _tagsWithId(res.body, 'home'), 'id="home"', scenario);
    expect(
      home.attrs['href'],
      '/',
      reason: '#home href on ${res.path}. ${_repro(scenario)}. '
          '${res.describe()}',
    );
    expect(
      _inner(res.body, home),
      words['home'],
      reason: '#home text on ${res.path}. ${_repro(scenario)}. '
          '${res.describe()}',
    );
  }
  final List<_Tag> switches = _allTags(res.body)
      .where(
          (_Tag t) => t.name == 'a' && t.attrs['href'] == words['switchHref'])
      .toList();
  final _Tag sw = _one(
    res,
    switches,
    'link with href="${words['switchHref']}"',
    scenario,
  );
  expect(
    _inner(res.body, sw),
    words['switchText'],
    reason: 'language switch text on ${res.path}. ${_repro(scenario)}. '
        '${res.describe()}',
  );
}

void _expectHeading(
  _Res res,
  String h1,
  String title,
  String scenario,
) {
  final List<_Tag> h1s =
      _allTags(res.body).where((_Tag t) => t.name == 'h1').toList();
  final _Tag tag = _one(res, h1s, '<h1>', scenario);
  expect(
    _inner(res.body, tag),
    h1,
    reason: '<h1> text on ${res.path}. ${_repro(scenario)}. ${res.describe()}',
  );
  expect(
    _titleText(res.body),
    title,
    reason: '<title> text on ${res.path}. ${_repro(scenario)}. '
        '${res.describe()}',
  );
}

void _expectLead(_Res res, String lead, String scenario) {
  expect(
    _paragraphs(res.body),
    contains(lead),
    reason: 'expected a paragraph with the lead "$lead" on ${res.path}. '
        '${_repro(scenario)}. ${res.describe()}',
  );
}

void _expectHomePage(_Res res, String lang, String scenario) {
  final Map<String, String> w = _home[lang]!;
  _expectStatus(res, 200, scenario);
  _expectPageHeaders(res, 'public, max-age=300', scenario);
  _expectLanguage(res, lang, scenario);
  _expectHeading(res, w['h1']!, 'Ludo RNG', scenario);
  _expectLead(res, w['lead']!, scenario);
  final _Tag fair =
      _one(res, _tagsWithClass(res.body, 'fair'), 'class="fair"', scenario);
  expect(
    _inner(res.body, fair),
    w['fair'],
    reason: '.fair text on ${res.path}. ${_repro(scenario)}. ${res.describe()}',
  );
  _expectSharedLinks(res, w, scenario, withHome: false);
  final _Tag privacy =
      _one(res, _tagsWithId(res.body, 'privacy'), 'id="privacy"', scenario);
  expect(
    privacy.attrs['href'],
    '/privacy?lang=$lang',
    reason: '#privacy href on ${res.path}. ${_repro(scenario)}. '
        '${res.describe()}',
  );
  expect(
    _inner(res.body, privacy),
    w['privacy'],
    reason: '#privacy text on ${res.path}. ${_repro(scenario)}. '
        '${res.describe()}',
  );
  _expectLookAndNoScript(res, scenario);
}

void _expectNotFoundPage(
  _Res res,
  Map<String, Map<String, String>> table,
  String lang,
  String scenario,
) {
  final Map<String, String> w = table[lang]!;
  _expectStatus(res, 404, scenario);
  _expectPageHeaders(res, 'no-store', scenario);
  _expectLanguage(res, lang, scenario);
  _expectHeading(res, w['h1']!, 'Ludo RNG - ${w['h1']}', scenario);
  _expectLead(res, w['lead']!, scenario);
  _expectSharedLinks(res, w, scenario, withHome: true);
  _expectLookAndNoScript(res, scenario);
}

/// [needle] must not appear in the body as typed, upper-cased, or in any case
/// as a standalone token.
void _expectNotReflected(_Res res, String needle, String scenario) {
  final String body = res.body;
  expect(
    body,
    isNot(contains(needle)),
    reason: 'the requested text "$needle" was reflected into the page body. '
        '${_repro(scenario)}. ${res.describe()}',
  );
  expect(
    body,
    isNot(contains(needle.toUpperCase())),
    reason: 'the requested text "$needle" (upper-cased) was reflected into '
        'the page body. ${_repro(scenario)}. ${res.describe()}',
  );
  final RegExp token = RegExp(
    '(?<![A-Za-z0-9])${RegExp.escape(needle)}(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  expect(
    token.hasMatch(body),
    isFalse,
    reason: 'the requested text "$needle" was reflected into the page body '
        '(case-insensitive). ${_repro(scenario)}. ${res.describe()}',
  );
}

// ---------------------------------------------------------------------
// Raw upgrade requests and the WebSocket protocol
// ---------------------------------------------------------------------

/// Sends one hand-written upgrade request and returns the status line the
/// server answers with. The header values are written exactly as given, so a
/// mixed-case `Upgrade: WebSocket` reaches the server as such.
Future<String> _rawUpgradeStatusLine(
  String path,
  String upgradeValue,
  String connectionValue,
) async {
  final Socket socket = await Socket.connect('127.0.0.1', _port);
  try {
    final StringBuffer request = StringBuffer()
      ..write('GET $path HTTP/1.1\r\n')
      ..write('Host: 127.0.0.1:$_port\r\n')
      ..write('Upgrade: $upgradeValue\r\n')
      ..write('Connection: $connectionValue\r\n')
      ..write('Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n')
      ..write('Sec-WebSocket-Version: 13\r\n')
      ..write('\r\n');
    socket.write(request.toString());
    await socket.flush();
    final StringBuffer seen = StringBuffer();
    final Completer<String> line = Completer<String>();
    final StreamSubscription<List<int>> sub = socket.listen(
      (List<int> chunk) {
        seen.write(latin1.decode(chunk));
        final String so = seen.toString();
        final int eol = so.indexOf('\r\n');
        if (eol >= 0 && !line.isCompleted) {
          line.complete(so.substring(0, eol));
        }
      },
      onDone: () {
        if (!line.isCompleted) {
          line.complete('<closed before a status line: ${seen.toString()}>');
        }
      },
    );
    try {
      return await line.future.timeout(const Duration(seconds: 15));
    } finally {
      await sub.cancel();
    }
  } finally {
    socket.destroy();
  }
}

Future<void> _expectCreateRoomExchange(String path, String scenario) async {
  final Uri uri = Uri(scheme: 'ws', host: '127.0.0.1', port: _port, path: path);
  final WebSocket socket = await WebSocket.connect(uri.toString())
      .timeout(const Duration(seconds: 15));
  try {
    final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
    final Completer<Map<String, Object?>> answer =
        Completer<Map<String, Object?>>();
    final StreamSubscription<dynamic> sub = socket.listen((dynamic data) {
      final Object? decoded = jsonDecode(data as String);
      if (decoded is Map<String, Object?>) {
        frames.add(decoded);
        final Object? t = decoded['t'];
        if ((t == 'room' || t == 'error') && !answer.isCompleted) {
          answer.complete(decoded);
        }
      }
    });
    const String id = 'c615create01';
    socket.add(
      jsonEncode(<String, Object?>{
        'v': 1,
        't': 'create_room',
        'id': id,
        'd': <String, Object?>{'name': 'Anna', 'players': 2},
      }),
    );
    Map<String, Object?> reply;
    try {
      reply = await answer.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      fail(
        'no room or error frame within 15 s of create_room on $uri; frames '
        'seen: $frames. ${_repro(scenario)}',
      );
    } finally {
      await sub.cancel();
    }
    expect(
      reply['t'],
      'room',
      reason: 'expected a room frame answering create_room on $uri, got '
          '$reply. ${_repro(scenario)}',
    );
    expect(
      reply['re'],
      id,
      reason: 'expected the room frame to carry re="$id" on $uri, got '
          '$reply. ${_repro(scenario)}',
    );
    final Object? d = reply['d'];
    final Object? code = d is Map<String, Object?> ? d['code'] : null;
    expect(
      code is String && isWellFormedRoomCode(code),
      isTrue,
      reason: 'expected a well-formed room code in the room frame on $uri, '
          'got $reply. ${_repro(scenario)}',
    );
  } finally {
    await socket.close();
  }
}

// ---------------------------------------------------------------------
// The cases
// ---------------------------------------------------------------------

void main() {
  setUpAll(() async {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 10));
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

  group('(a) the home page', () {
    const String name = '(a) GET / answers the English home page';
    test(name, () async {
      final _Res res = await _get('/');
      _expectHomePage(res, 'en', name);
    });

    const String queryName = '(a) GET /?x=1 still answers the home page';
    test(queryName, () async {
      final _Res res = await _get('/?x=1');
      _expectHomePage(res, 'en', queryName);
    });
  });

  group('(b) the home page in Arabic', () {
    const String queryName = '(b) GET /?lang=ar answers the Arabic home page';
    test(queryName, () async {
      final _Res res = await _get('/?lang=ar');
      _expectHomePage(res, 'ar', queryName);
    });

    const String headerName =
        '(b) GET / with Accept-Language ar answers the Arabic home page';
    test(headerName, () async {
      final _Res res = await _get('/', acceptLanguage: 'ar');
      _expectHomePage(res, 'ar', headerName);
    });

    const String latinName =
        '(b) Arabic home lead and fair line hold no Latin letters but Ludo RNG';
    test(latinName, () async {
      final _Res res = await _get('/?lang=ar');
      final Map<String, String> w = _home['ar']!;
      for (final String key in <String>['lead', 'fair']) {
        final String stripped = w[key]!.replaceAll('Ludo RNG', '');
        expect(
          RegExp('[A-Za-z]').hasMatch(stripped),
          isFalse,
          reason: 'the contract text for $key has stray Latin letters; the '
              'test table is wrong. ${_repro(latinName)}',
        );
      }
      final List<_Tag> fair = _tagsWithClass(res.body, 'fair');
      final String fairText =
          fair.length == 1 ? _inner(res.body, fair.single) : '';
      final String lead = _paragraphs(res.body).firstWhere(
        (String p) => p == w['lead'],
        orElse: () => '',
      );
      expect(
        lead,
        isNotEmpty,
        reason: 'no paragraph equals the Arabic lead. ${_repro(latinName)}. '
            '${res.describe()}',
      );
      for (final String text in <String>[lead, fairText]) {
        expect(
          RegExp('[A-Za-z]').hasMatch(text.replaceAll('Ludo RNG', '')),
          isFalse,
          reason: 'Latin letters other than Ludo RNG in "$text". '
              '${_repro(latinName)}. ${res.describe()}',
        );
      }
    });
  });

  group('(c) the home page methods', () {
    const String headName =
        '(c) HEAD / answers 200 with GET headers and no body';
    test(headName, () async {
      final _Res head = await _request('HEAD', '/');
      final _Res get = await _get('/');
      _expectStatus(head, 200, headName);
      _expectEmptyBody(head, headName);
      _expectPageHeaders(head, 'public, max-age=300', headName);
      final Set<String> skip = <String>{'content-length', 'date'};
      for (final String header in get.headers.keys) {
        if (skip.contains(header)) {
          continue;
        }
        expect(
          head.header(header),
          get.header(header),
          reason: 'HEAD / header $header differs from GET /. '
              '${_repro(headName)}. GET: ${get.headers}, HEAD: ${head.headers}',
        );
      }
    });

    for (final String method in <String>[
      'POST',
      'PUT',
      'DELETE',
      'PATCH',
      'OPTIONS',
    ]) {
      final String name = '(c) $method / answers 405 allow GET, HEAD';
      test(name, () async {
        final _Res res = await _request(method, '/');
        _expectStatus(res, 405, name);
        expect(
          res.header('allow'),
          'GET, HEAD',
          reason: 'expected allow: GET, HEAD on $method /, got '
              '"${res.header('allow')}". ${_repro(name)}. ${res.describe()}',
        );
      });
    }
  });

  group('(d) a cut invite link', () {
    const List<String> cutPaths = <String>[
      '/r/ABCDE',
      '/r/abc',
      '/r/0OOOOO',
    ];
    for (final String path in cutPaths) {
      for (final String lang in <String>['en', 'ar']) {
        final String name = '(d) GET $path in $lang answers the cut-link page';
        test(name, () async {
          final _Res res =
              lang == 'ar' ? await _get('$path?lang=ar') : await _get(path);
          _expectNotFoundPage(res, _cut, lang, name);
          _expectNotReflected(res, path.substring('/r/'.length), name);
        });
      }
    }

    const String headerName =
        '(d) GET /r/ABCDE with Accept-Language ar answers the Arabic cut-link '
        'page';
    test(headerName, () async {
      final _Res res = await _get('/r/ABCDE', acceptLanguage: 'ar');
      _expectNotFoundPage(res, _cut, 'ar', headerName);
    });

    const String headName = '(d) HEAD /r/ABCDE answers 404 with no body';
    test(headName, () async {
      final _Res res = await _request('HEAD', '/r/ABCDE');
      _expectStatus(res, 404, headName);
      _expectEmptyBody(res, headName);
    });
  });

  group('(e) an unknown path', () {
    const List<String> paths = <String>[
      '/foo',
      '/foo/bar',
      '/r/',
      '/r/ABCDEF/x',
    ];
    for (final String path in paths) {
      for (final String lang in <String>['en', 'ar']) {
        final String name = '(e) GET $path in $lang answers the generic '
            'not-found page';
        test(name, () async {
          final _Res res =
              lang == 'ar' ? await _get('$path?lang=ar') : await _get(path);
          _expectNotFoundPage(res, _nothing, lang, name);
        });
      }
    }

    const String reflectName =
        '(e) GET /foo<script> (encoded) is not reflected into the page';
    test(reflectName, () async {
      final _Res res = await _get('/foo%3Cscript%3E');
      _expectNotFoundPage(res, _nothing, 'en', reflectName);
      _expectNotReflected(res, 'foo', reflectName);
      expect(
        res.body,
        isNot(contains('%3C')),
        reason: 'the encoded path was reflected into the page. '
            '${_repro(reflectName)}. ${res.describe()}',
      );
    });

    const String reflectCutName =
        '(e) GET /r/<encoded markup> is not reflected into the cut-link page';
    test(reflectCutName, () async {
      final _Res res = await _get('/r/%3Cb%3Ex%3C%2Fb%3E');
      _expectNotFoundPage(res, _cut, 'en', reflectCutName);
      expect(
        res.body,
        isNot(contains('<b>x')),
        reason: 'the requested code was reflected as markup. '
            '${_repro(reflectCutName)}. ${res.describe()}',
      );
    });

    const String queryName =
        '(e) GET /foo?q=zzz does not reflect the query into the page';
    test(queryName, () async {
      final _Res res = await _get('/foo?q=zzzmarker');
      _expectNotFoundPage(res, _nothing, 'en', queryName);
      _expectNotReflected(res, 'zzzmarker', queryName);
    });
  });

  group('(f) not-found methods', () {
    const String headName = '(f) HEAD /foo answers 404 with no body';
    test(headName, () async {
      final _Res head = await _request('HEAD', '/foo');
      final _Res get = await _get('/foo');
      _expectStatus(head, 404, headName);
      _expectEmptyBody(head, headName);
      _expectPageHeaders(head, 'no-store', headName);
      final Set<String> skip = <String>{'content-length', 'date'};
      for (final String header in get.headers.keys) {
        if (skip.contains(header)) {
          continue;
        }
        expect(
          head.header(header),
          get.header(header),
          reason: 'HEAD /foo header $header differs from GET /foo. '
              '${_repro(headName)}. GET: ${get.headers}, HEAD: ${head.headers}',
        );
      }
    });

    for (final String method in <String>['DELETE', 'POST', 'PUT', 'PATCH']) {
      final String name = '(f) $method /foo answers 404 with no body';
      test(name, () async {
        final _Res res = await _request(method, '/foo');
        _expectStatus(res, 404, name);
        _expectEmptyBody(res, name);
      });
    }
  });

  group('(g) the game socket is untouched', () {
    const String rootName = '(g) a WebSocket client on / completes create_room';
    test(rootName, () => _expectCreateRoomExchange('/', rootName));

    const String otherName =
        '(g) a WebSocket client on /anything completes create_room';
    test(otherName, () => _expectCreateRoomExchange('/anything', otherName));

    for (final String path in <String>['/', '/anything']) {
      final String name =
          '(g) a raw upgrade request on $path with Upgrade: WebSocket gets 101';
      test(name, () async {
        final String line =
            await _rawUpgradeStatusLine(path, 'WebSocket', 'Upgrade');
        expect(
          line,
          startsWith('HTTP/1.1 101'),
          reason: 'expected a mixed-case Upgrade: WebSocket on $path to be '
              'treated as an upgrade, got status line "$line". ${_repro(name)}',
        );
      });
    }

    const String upperName =
        '(g) a raw upgrade request on / with Upgrade: WEBSOCKET gets 101';
    test(upperName, () async {
      final String line =
          await _rawUpgradeStatusLine('/', 'WEBSOCKET', 'upgrade');
      expect(
        line,
        startsWith('HTTP/1.1 101'),
        reason: 'expected Upgrade: WEBSOCKET on / to be treated as an '
            'upgrade, got status line "$line". ${_repro(upperName)}',
      );
    });
  });

  group('(h) frozen surfaces', () {
    const String enName = '(h) buildRoomLandingPageHtml en is byte-identical';
    test(enName, () {
      expect(
        _sha(buildRoomLandingPageHtml('ABCDEF',
            language: 'en', closedTest: false)),
        _roomPageEnSha,
        reason: 'the English room page output changed from base 0f98f7c. '
            '${_repro(enName)}',
      );
    });

    const String arName = '(h) buildRoomLandingPageHtml ar is byte-identical';
    test(arName, () {
      expect(
        _sha(buildRoomLandingPageHtml('ABCDEF',
            language: 'ar', closedTest: false)),
        _roomPageArSha,
        reason: 'the Arabic room page output changed from base 0f98f7c. '
            '${_repro(arName)}',
      );
    });

    const String jsName = '(h) roomLinkJsSource is byte-identical';
    test(jsName, () {
      expect(
        _sha(roomLinkJsSource),
        _roomJsSha,
        reason: 'roomLinkJsSource changed from base 0f98f7c. ${_repro(jsName)}',
      );
    });

    const String servedName =
        '(h) GET /r/ABCDEF serves the frozen page with the base headers';
    test(servedName, () async {
      final _Res res = await _get('/r/ABCDEF');
      _expectStatus(res, 200, servedName);
      _roomPageHeaders.forEach((String header, String value) {
        expect(
          res.header(header),
          value,
          reason: 'room page header $header on /r/ABCDEF. '
              '${_repro(servedName)}. ${res.describe()}',
        );
      });
      expect(
        _sha(res.body),
        _roomPageClosedEnSha,
        reason: 'served /r/ABCDEF body differs from the closed-test page. '
            '${_repro(servedName)}. ${res.describe()}',
      );
    });

    const String servedArName =
        '(h) GET /r/abcdef?lang=ar serves the frozen Arabic page';
    test(servedArName, () async {
      final _Res res = await _get('/r/abcdef?lang=ar');
      _expectStatus(res, 200, servedArName);
      expect(
        _sha(res.body),
        _roomPageClosedArSha,
        reason: 'served Arabic /r/abcdef body differs from the closed-test '
            'page. '
            '${_repro(servedArName)}. ${res.describe()}',
      );
    });

    const String roomJsRoute = '(h) GET /r/room.js still serves the script';
    test(roomJsRoute, () async {
      final _Res res = await _get('/r/room.js');
      _expectStatus(res, 200, roomJsRoute);
      expect(
        res.header('content-type'),
        'application/javascript; charset=utf-8',
        reason: 'room.js content-type. ${_repro(roomJsRoute)}. '
            '${res.describe()}',
      );
      expect(
        res.header('cache-control'),
        'public, max-age=300',
        reason: 'room.js cache-control. ${_repro(roomJsRoute)}. '
            '${res.describe()}',
      );
      expect(
        _sha(res.body),
        _roomJsSha,
        reason: 'room.js body differs from the base. ${_repro(roomJsRoute)}',
      );
    });

    const String routesName =
        '(h) /health and /privacy still answer 200 ahead of the new pages';
    test(routesName, () async {
      final _Res health = await _get('/health');
      _expectStatus(health, 200, routesName);
      expect(
        health.header('content-type'),
        startsWith('application/json'),
        reason: '/health content-type. ${_repro(routesName)}. '
            '${health.describe()}',
      );
      for (final String path in <String>['/privacy', '/privacy/']) {
        final _Res privacy = await _get(path);
        _expectStatus(privacy, 200, routesName);
        expect(
          privacy.header('content-type'),
          startsWith('text/html'),
          reason: '$path content-type. ${_repro(routesName)}. '
              '${privacy.describe()}',
        );
      }
    });
  });

  group('(i) wording', () {
    final RegExp banned = RegExp(
      r'provably|absolute|odds|\bbet|wager',
      caseSensitive: false,
    );
    final Map<String, List<String>> pages = <String, List<String>>{
      'home': <String>['/', '/?lang=ar'],
      'cut-link': <String>['/r/ABCDE', '/r/ABCDE?lang=ar'],
      'generic not-found': <String>['/foo', '/foo?lang=ar'],
    };
    pages.forEach((String label, List<String> paths) {
      final String name = '(i) the $label page, both languages, holds none of '
          'provably, absolute, odds, bet, wager';
      test(name, () async {
        for (final String path in paths) {
          final _Res res = await _get(path);
          expect(
            res.body,
            contains('id="get-app"'),
            reason: 'the $label page at $path has no #get-app, so there is no '
                'page to check the wording of. ${_repro(name)}. '
                '${res.describe()}',
          );
          // The style block is skipped: `position: absolute` is a rule, not
          // a word the page says.
          final String markup = res.body.replaceAll(
            RegExp(r'<style\b[^>]*>.*?</style>', dotAll: true),
            ' ',
          );
          final RegExpMatch? hit = banned.firstMatch(markup);
          expect(
            hit,
            isNull,
            reason: 'found the banned word "${hit?.group(0)}" in the $label '
                'page at $path. ${_repro(name)}. ${res.describe()}',
          );
        }
      });
    });
  });
}

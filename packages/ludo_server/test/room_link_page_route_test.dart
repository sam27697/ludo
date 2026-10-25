// Route tests for work/ludo/orders/C-457-room-link-page.md, decisions D1 to
// D7, against a real WireServer on an ephemeral port with real HTTP
// requests. Written from the contract, not from the implementation.
//
// Nothing here calls the new `buildOpenInAppUrl` or the new `language:`
// parameter, so this file compiles and runs on the commit before the
// contract was implemented. The direct calls live in
// room_link_page_unit_test.dart.
//
// Every case is deterministic: the one random input is the room code the
// server mints for the live-room comparison, and it is printed in that
// case's failure text. Every failure text names the scenario and the command
// that re-runs it.
//
// The D2 script cases run the served /r/room.js in a real `node` against a
// small DOM stub (written below as a driver script). A missing `node` fails
// the case loudly; nothing here ever skips.
//
// Interpretations the contract leaves open are listed where they are made
// and again in the order's report:
//
// - D6 says the bodies are byte-identical. They carry the code, so two
//   different codes cannot be identical bytes; the live and the unknown code
//   are compared with their own code replaced by a placeholder, and the same
//   code is also compared raw before and while its room exists.
// - D3 names the switch link target as `?lang=ar` / `?lang=en`; the href is
//   compared to exactly that string.
// - The code wrapper required by D3 is an element with dir="ltr", other than
//   html and body, whose visible text is the code.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

const String _testFile = 'test/room_link_page_route_test.dart';

/// The Play listing the page sends a person without the app to.
const String _playListing =
    'https://play.google.com/store/apps/details?id=app.fayad.ludo';

/// A well-formed code that no test ever creates a room for.
const String _code = 'K7M2QP';

/// A second well-formed code, used as the never-created partner.
const String _otherCode = 'ABCDEF';

/// The verify page's CSP string, verbatim (C-457 D7).
const String _expectedCsp = "default-src 'none'; script-src 'self'; "
    "style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'none'";

String _intentUrl(String code) =>
    'intent://ludo.provefair.app/r/$code#Intent;scheme=https;'
    'package=app.fayad.ludo;'
    'S.browser_fallback_url=${Uri.encodeComponent(_playListing)};end';

/// The D4 table. `<CODE>` stands for the room code.
const Map<String, Map<String, String>> _strings = <String, Map<String, String>>{
  'en': <String, String>{
    'title': 'Join room <CODE>',
    'lead': 'Your friend is waiting for you in Ludo RNG.',
    'open': 'Open in Ludo RNG',
    'codeLabel': 'Room code',
    'copy': 'Copy code',
    'copied': 'Copied',
    'newHere':
        'New to Ludo RNG? Install it, then type this code on the home screen.',
    'get': 'Get Ludo RNG on Google Play',
    'fair': 'Every roll in Ludo RNG is verifiable.',
  },
  'ar': <String, String>{
    'title': 'انضم إلى الغرفة <CODE>',
    'lead': 'صديقك بانتظارك في Ludo RNG.',
    'open': 'افتح في Ludo RNG',
    'codeLabel': 'رمز الغرفة',
    'copy': 'انسخ الرمز',
    'copied': 'تم النسخ',
    'newHere': 'جديد على Ludo RNG؟ ثبّته، ثم اكتب هذا الرمز في الشاشة '
        'الرئيسية.',
    'get': 'احصل على Ludo RNG من Google Play',
    'fair': 'كل رمية في Ludo RNG قابلة للتحقق.',
  },
};

String _s(String lang, String key, String code) =>
    _strings[lang]![key]!.replaceAll('<CODE>', code);

const List<String> _forbiddenWords = <String>[
  'directly',
  'مباشرة',
  'provably fair',
  'absolute random',
  'odds',
  'stake',
  'wager',
  'gambl',
];

// ---------------------------------------------------------------------
// Failure text
// ---------------------------------------------------------------------

String _repro(String scenario) =>
    'scenario: $scenario. Deterministic, no seed. Reproduce with: cd '
    'packages/ludo_server && dart test $_testFile -n "$scenario"';

// ---------------------------------------------------------------------
// Server and HTTP plumbing
// ---------------------------------------------------------------------

class _Server {
  _Server._(this.registry, this.server);

  final RoomRegistry registry;
  final WireServer server;

  static _Server build() {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 10, 25));
    final RoomRegistry registry =
        RoomRegistry(clock: clock, secure: Random.secure());
    final WireServer server = WireServer(
      registry: registry,
      rateLimiter: RateLimiter(clock: clock),
      clock: clock,
    );
    return _Server._(registry, server);
  }

  Future<void> start() =>
      server.start(address: InternetAddress.loopbackIPv4, port: 0);

  Uri uri(String pathAndQuery) =>
      Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery');

  Uri get wsUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');

  Future<void> close() => server.close();
}

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

late _Server _server;
late HttpClient _client;

Future<_Res> _request(
  String method,
  String pathAndQuery, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClientRequest request =
      await _client.openUrl(method, _server.uri(pathAndQuery));
  headers.forEach(request.headers.set);
  final HttpClientResponse response = await request.close();
  final String body = await response.transform(utf8.decoder).join();
  final Map<String, String> seen = <String, String>{};
  response.headers.forEach((String name, List<String> values) {
    seen[name.toLowerCase()] = values.join(', ');
  });
  return _Res(method, pathAndQuery, response.statusCode, seen, body);
}

Future<_Res> _get(
  String pathAndQuery, {
  String? acceptLanguage,
}) =>
    _request(
      'GET',
      pathAndQuery,
      headers: <String, String>{
        if (acceptLanguage != null) 'accept-language': acceptLanguage,
      },
    );

/// GET [path] for [lang] using the `?lang=` query, the unambiguous way to
/// ask for a language.
Future<_Res> _page(String lang, {String code = _code}) =>
    _get('/r/$code?lang=$lang');

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
  _Tag(this.name, this.attrs, this.openStart, this.openEnd);

  final String name;
  final Map<String, String> attrs;
  final int openStart;
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

/// Every opening tag whose id attribute is exactly [id].
List<_Tag> _tagsWithId(String html, String id) {
  final List<_Tag> found = <_Tag>[];
  final RegExp open = RegExp(r'<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>');
  for (final RegExpMatch m in open.allMatches(html)) {
    final Map<String, String> attrs = _parseAttrs(m.group(2)!);
    if (attrs['id'] == id) {
      found.add(_Tag(m.group(1)!.toLowerCase(), attrs, m.start, m.end));
    }
  }
  return found;
}

/// The one tag with id [id], or a failure naming what was found instead.
_Tag _requireTag(_Res res, String id, String scenario) {
  final List<_Tag> tags = _tagsWithId(res.body, id);
  if (tags.length != 1) {
    fail(
      'expected exactly one element with id="$id" on ${res.path}, found '
      '${tags.length}. ${_repro(scenario)}. ${res.describe()}',
    );
  }
  return tags.single;
}

/// The markup between the end of [tag]'s opening tag and its matching
/// closing tag, counting nested tags of the same name.
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

String _stripTags(String markup) =>
    _collapse(_unescape(markup.replaceAll(RegExp(r'<[^>]*>'), ' ')));

/// The text a reader sees: style and script bodies and all tags removed,
/// entities decoded, whitespace collapsed.
String _visibleText(String html) {
  final String noCode = html
      .replaceAll(RegExp(r'<style\b[^>]*>.*?</style>', dotAll: true), ' ')
      .replaceAll(RegExp(r'<script\b[^>]*>.*?</script>', dotAll: true), ' ');
  return _stripTags(noCode);
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

String _titleText(String html) {
  final RegExpMatch? m =
      RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(html);
  return m == null ? '' : _collapse(_unescape(m.group(1)!));
}

// ---------------------------------------------------------------------
// Finding the Android manifest from the package, not the cwd
// ---------------------------------------------------------------------

Future<String> _manifestText() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:ludo_server/ludo_server.dart'),
  );
  if (libUri == null) {
    fail('could not resolve package:ludo_server to a file URI, so the Android '
        'manifest cannot be located. This case never skips.');
  }
  final Directory packageRoot = File.fromUri(libUri).parent.parent;
  final File manifest = File(
    '${packageRoot.path}/../ludo_client/android/app/src/main/'
    'AndroidManifest.xml',
  );
  if (!manifest.existsSync()) {
    fail('expected the client manifest at ${manifest.path} (resolved from the '
        'ludo_server package root ${packageRoot.path}); it does not exist. '
        'This case never skips.');
  }
  return manifest.readAsStringSync();
}

// ---------------------------------------------------------------------
// node
// ---------------------------------------------------------------------

Future<void> _requireNode() async {
  ProcessResult result;
  try {
    result = await Process.run('node', <String>['--version']);
  } on ProcessException catch (e) {
    fail('this case requires "node" on PATH to run the served /r/room.js; '
        'Process.run(node --version) failed to start: $e. It never skips for '
        'a missing interpreter.');
  }
  if (result.exitCode != 0) {
    fail('"node --version" exited ${result.exitCode}; stdout: ${result.stdout} '
        'stderr: ${result.stderr}. This case never skips.');
  }
}

/// Runs a scenario of the stub DOM against the served script. The script
/// takes its stub configuration from a JSON file and prints one JSON object.
const String _driverSource = r'''
'use strict';
const fs = require('fs');
const vm = require('vm');

const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const src = fs.readFileSync(cfg.scriptPath, 'utf8');

const unhandled = [];
process.on('unhandledRejection', (reason) => {
  unhandled.push(String((reason && reason.message) || reason));
});

const out = {
  loadError: null,
  clickHandlers: 0,
  clickErrors: [],
  writes: [],
  writesBeforeClick: null,
  textBeforeClick: null,
  textAfterClick: null,
  conditionMet: false,
  selections: [],
  execCommands: 0,
  createElementCalls: [],
  timerDelays: [],
  textAfterTimers: null,
  consoleCalls: [],
  idMisses: [],
  unhandled: unhandled,
};

function camel(name) {
  return name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
}

class El {
  constructor(id, text, dataset) {
    this.id = id;
    this._text = text;
    this.dataset = dataset || {};
    this.listeners = {};
    this.onclick = null;
    this.style = {};
    this.classList = { add() {}, remove() {}, toggle() {}, contains() { return false; } };
  }
  get textContent() { return this._text; }
  set textContent(v) { this._text = String(v); }
  get innerText() { return this._text; }
  set innerText(v) { this._text = String(v); }
  get innerHTML() { return this._text; }
  set innerHTML(v) { this._text = String(v); }
  addEventListener(type, fn) {
    (this.listeners[type] = this.listeners[type] || []).push(fn);
  }
  removeEventListener() {}
  getAttribute(name) {
    if (name.indexOf('data-') === 0) {
      const key = camel(name.slice(5));
      return key in this.dataset ? this.dataset[key] : null;
    }
    return name === 'id' ? this.id : null;
  }
  setAttribute() {}
  focus() {}
  blur() {}
  select() { out.selections.push({ how: 'select', id: this.id }); }
  setSelectionRange() { out.selections.push({ how: 'setSelectionRange', id: this.id }); }
}

const button = new El('copy-code', cfg.copy, { copy: cfg.copy, copied: cfg.copied });
const roomCode = new El('room-code', cfg.roomCodeText, {});
const elements = {
  'copy-code': button,
  'room-code': roomCode,
  'open-app': new El('open-app', '', {}),
  'lang-switch': new El('lang-switch', '', {}),
  'get-app': new El('get-app', '', {}),
};

function selection() {
  return {
    rangeCount: 0,
    removeAllRanges() {},
    addRange(r) {
      (r.nodes || []).forEach((n) => out.selections.push({ how: 'addRange', id: n.id }));
    },
    selectAllChildren(n) { out.selections.push({ how: 'selectAllChildren', id: n.id }); },
    toString() { return ''; },
  };
}

function createRange() {
  const r = {
    nodes: [],
    selectNodeContents(n) { r.nodes.push(n); out.selections.push({ how: 'selectNodeContents', id: n.id }); },
    selectNode(n) { r.nodes.push(n); out.selections.push({ how: 'selectNode', id: n.id }); },
    setStart(n) { r.nodes.push(n); },
    setEnd() {},
  };
  return r;
}

const docListeners = {};
const winListeners = {};
const document = {
  readyState: 'loading',
  body: new El('body', '', {}),
  documentElement: new El('html', '', {}),
  getElementById(id) {
    if (Object.prototype.hasOwnProperty.call(elements, id)) return elements[id];
    out.idMisses.push(id);
    return null;
  },
  querySelector(sel) {
    if (sel.charAt(0) === '#' && elements[sel.slice(1)]) return elements[sel.slice(1)];
    if (sel.indexOf('[data-copy') === 0) return button;
    return null;
  },
  querySelectorAll() { return []; },
  addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
  removeEventListener() {},
  createRange,
  getSelection: selection,
  createElement(tag) { out.createElementCalls.push(tag); return new El('created-' + tag, '', {}); },
  execCommand() { out.execCommands += 1; return true; },
};

let navigator;
if (cfg.scenario === 'ok') {
  navigator = {
    clipboard: {
      writeText(text) { out.writes.push(text); return Promise.resolve(); },
    },
  };
} else if (cfg.scenario === 'reject') {
  navigator = {
    clipboard: {
      writeText(text) { out.writes.push(text); return Promise.reject(new Error('denied')); },
    },
  };
} else {
  navigator = {};
}

const timers = [];
const consoleStub = {};
['log', 'info', 'debug', 'warn', 'error'].forEach((level) => {
  consoleStub[level] = (...args) => {
    out.consoleCalls.push({ level: level, text: args.map(String).join(' ') });
  };
});

const sandbox = {
  document: document,
  navigator: navigator,
  console: consoleStub,
  setTimeout(fn, ms) { timers.push({ fn: fn, ms: ms }); return timers.length; },
  clearTimeout() {},
  setInterval() { return 0; },
  clearInterval() {},
  addEventListener(type, fn) { (winListeners[type] = winListeners[type] || []).push(fn); },
  removeEventListener() {},
  getSelection: selection,
  location: { href: 'https://ludo.provefair.app/r/' + cfg.code },
};
sandbox.window = sandbox;
sandbox.self = sandbox;
vm.createContext(sandbox);

async function turn() { await new Promise((r) => setImmediate(r)); }

async function waitFor(pred) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return true;
    await turn();
  }
  return pred();
}

async function fire(el, type) {
  const evt = {
    type: type,
    target: el,
    currentTarget: el,
    preventDefault() {},
    stopPropagation() {},
  };
  const fns = (el.listeners[type] || []).slice();
  if (type === 'click' && typeof el.onclick === 'function') fns.push(el.onclick);
  out.clickHandlers = fns.length;
  for (const fn of fns) {
    try {
      const r = fn.call(el, evt);
      if (r && typeof r.then === 'function') {
        r.then(() => {}, (e) => out.clickErrors.push('async: ' + String(e)));
      }
    } catch (e) {
      out.clickErrors.push(String((e && e.stack) || e));
    }
  }
}

(async () => {
  try {
    vm.runInContext(src, sandbox, { filename: 'room.js' });
  } catch (e) {
    out.loadError = String((e && e.stack) || e);
  }
  document.readyState = 'interactive';
  (docListeners['DOMContentLoaded'] || []).slice().forEach((fn) => {
    try { fn({ type: 'DOMContentLoaded' }); } catch (e) { out.loadError = String((e && e.stack) || e); }
  });
  document.readyState = 'complete';
  (winListeners['load'] || []).slice().forEach((fn) => {
    try { fn({ type: 'load' }); } catch (e) { out.loadError = String((e && e.stack) || e); }
  });

  out.writesBeforeClick = out.writes.length;
  out.textBeforeClick = button.textContent;
  await fire(button, 'click');

  if (cfg.scenario === 'ok') {
    out.conditionMet = await waitFor(() => button.textContent === cfg.copied);
  } else {
    out.conditionMet = await waitFor(
      () => out.selections.some((s) => s.id === 'room-code'));
  }
  for (let i = 0; i < 25; i += 1) await turn();
  out.textAfterClick = button.textContent;

  out.timerDelays = timers.map((t) => t.ms);
  for (const t of timers.slice()) {
    try { t.fn(); } catch (e) { out.clickErrors.push('timer: ' + String(e)); }
  }
  out.textAfterTimers = button.textContent;
  for (let i = 0; i < 25; i += 1) await turn();
  process.stdout.write(JSON.stringify(out));
})().catch((err) => {
  process.stderr.write(String((err && err.stack) || err));
  process.exit(1);
});
''';

Future<Map<String, Object?>> _runRoomJs({
  required String scenario,
  required String testName,
}) async {
  await _requireNode();
  final _Res script = await _get('/r/room.js');
  if (script.status != 200) {
    fail('GET /r/room.js must answer 200 with the page script, got '
        '${script.status}. ${_repro(testName)}. ${script.describe()}');
  }
  final _Res page = await _page('en');
  final _Tag copyTag = _requireTag(page, 'copy-code', testName);
  final _Tag codeTag = _requireTag(page, 'room-code', testName);
  final String? copy = copyTag.attrs['data-copy'];
  final String? copied = copyTag.attrs['data-copied'];
  if (copy == null || copied == null) {
    fail('the copy-code button must carry data-copy and data-copied, got '
        '${copyTag.attrs}. ${_repro(testName)}');
  }
  final String roomCodeText = _stripTags(_inner(page.body, codeTag));

  final Directory dataDir =
      Directory.systemTemp.createTempSync('room_js_data_');
  final Directory toolDir =
      Directory.systemTemp.createTempSync('room_js_tool_');
  try {
    final File scriptFile = File('${dataDir.path}/room.js')
      ..writeAsStringSync(script.body);
    final File cfgFile = File('${dataDir.path}/cfg.json')
      ..writeAsStringSync(jsonEncode(<String, Object?>{
        'scriptPath': scriptFile.path,
        'scenario': scenario,
        'code': _code,
        'roomCodeText': roomCodeText,
        'copy': copy,
        'copied': copied,
      }));
    final File driverFile = File('${toolDir.path}/driver.js')
      ..writeAsStringSync(_driverSource);

    final Process process = await Process.start(
      'node',
      <String>[driverFile.path, cfgFile.path],
    );
    final Future<String> stdoutText =
        process.stdout.transform(utf8.decoder).join();
    final Future<String> stderrText =
        process.stderr.transform(utf8.decoder).join();
    final int exit = await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    final String stdoutBody = await stdoutText;
    final String stderrBody = await stderrText;
    if (exit != 0) {
      fail('the node driver exited $exit running /r/room.js in scenario '
          '"$scenario". ${_repro(testName)}. stdout: $stdoutBody stderr: '
          '$stderrBody');
    }
    return jsonDecode(stdoutBody) as Map<String, Object?>;
  } finally {
    dataDir.deleteSync(recursive: true);
    toolDir.deleteSync(recursive: true);
  }
}

String _show(Map<String, Object?> result) => jsonEncode(result);

void _expectQuiet(Map<String, Object?> r, String scenario, String testName) {
  final String detail = 'driver result: ${_show(r)}. ${_repro(testName)}';
  expect(r['loadError'], isNull,
      reason: 'room.js threw while loading in scenario "$scenario". $detail');
  expect(r['clickErrors'], isEmpty,
      reason: 'a click handler of room.js threw in scenario "$scenario"; it '
          'must never throw. $detail');
  final List<Object?> consoleCalls = r['consoleCalls']! as List<Object?>;
  final List<Object?> loud = consoleCalls.where((Object? c) {
    final String level = (c! as Map<String, Object?>)['level']! as String;
    return level == 'error' || level == 'warn';
  }).toList();
  expect(loud, isEmpty,
      reason: 'room.js wrote to console.error or console.warn in scenario '
          '"$scenario"; D2 says it never throws to the console on either '
          'path. $detail');
  expect(r['unhandled'], isEmpty,
      reason: 'room.js left an unhandled promise rejection in scenario '
          '"$scenario". $detail');
}

bool _selectedRoomCode(Map<String, Object?> r) =>
    (r['selections']! as List<Object?>)
        .any((Object? s) => (s! as Map<String, Object?>)['id'] == 'room-code');

// ---------------------------------------------------------------------
// A live room, created over the real WebSocket protocol
// ---------------------------------------------------------------------

class _LiveRoom {
  _LiveRoom(this.code, this._socket);

  final String code;
  final WebSocket _socket;

  Future<void> close() => _socket.close();
}

Future<_LiveRoom> _createLiveRoom(String testName) async {
  final WebSocket socket = await WebSocket.connect(_server.wsUri.toString());
  final Completer<String> codeFound = Completer<String>();
  socket.listen((Object? raw) {
    final Object? frame = jsonDecode(raw! as String);
    if (frame is Map<String, Object?> && frame['d'] is Map<String, Object?>) {
      final Object? code = (frame['d']! as Map<String, Object?>)['code'];
      if (code is String && !codeFound.isCompleted) {
        codeFound.complete(code);
      }
    }
  });
  socket.add(jsonEncode(<String, Object?>{
    'v': 1,
    't': 'create_room',
    'id': 'room-link-test-create',
    'd': <String, Object?>{'name': 'Host', 'players': 2},
  }));
  final String code = await codeFound.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => throw TestFailure(
      'create_room over the WebSocket returned no room code within 5s. '
      '${_repro(testName)}',
    ),
  );
  return _LiveRoom(code, socket);
}

// ---------------------------------------------------------------------

void main() {
  setUpAll(() async {
    _server = _Server.build();
    await _server.start();
    _client = HttpClient();
  });

  tearDownAll(() async {
    _client.close(force: true);
    await _server.close();
  });

  group('D1 open in app', () {
    test('open-app href is exactly the intent URL for the code', () async {
      const String name = 'D1 open-app href is the intent URL';
      final _Res res = await _page('en');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      final _Tag tag = _requireTag(res, 'open-app', name);
      expect(tag.name, 'a',
          reason: 'open-app must be a link (an <a>), got <${tag.name}>. '
              '${_repro(name)}');
      expect(
        tag.attrs['href'],
        _intentUrl(_code),
        reason: 'expected the href of #open-app (HTML-unescaped) to be the '
            'intent URL for $_code; got ${tag.attrs['href']}. '
            '${_repro(name)}',
      );
    });

    test('open-app href is the same on the Arabic page', () async {
      const String name = 'D1 open-app href on the Arabic page';
      final _Res res = await _page('ar');
      final _Tag tag = _requireTag(res, 'open-app', name);
      expect(tag.attrs['href'], _intentUrl(_code),
          reason: 'the Arabic page must carry the same intent URL; got '
              '${tag.attrs['href']}. ${_repro(name)}');
    });

    test('a lower-case request path carries the upper-case code', () async {
      const String name = 'D1 lower-case path upper-cases the code';
      final _Res res = await _get('/r/${_code.toLowerCase()}');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      final _Tag tag = _requireTag(res, 'open-app', name);
      expect(tag.attrs['href'], _intentUrl(_code),
          reason: 'GET /r/${_code.toLowerCase()} must put the upper-case '
              'code $_code in the intent URL; got ${tag.attrs['href']}. '
              '${_repro(name)}');
    });

    test('the intent URL host and path match the manifest App Links filter',
        () async {
      const String name = 'D1 intent URL matches the manifest filter';
      final String manifest = await _manifestText();
      final RegExpMatch? filter = RegExp(
        r'<intent-filter[^>]*android:autoVerify="true"[^>]*>(.*?)'
        r'</intent-filter>',
        dotAll: true,
      ).firstMatch(manifest);
      if (filter == null) {
        fail('the manifest has no <intent-filter android:autoVerify="true">; '
            'D1 cannot be cross-checked. ${_repro(name)}');
      }
      final String body = filter.group(1)!;
      final String? host =
          RegExp(r'android:host="([^"]*)"').firstMatch(body)?.group(1);
      final String? prefix =
          RegExp(r'android:pathPrefix="([^"]*)"').firstMatch(body)?.group(1);
      final String? scheme =
          RegExp(r'android:scheme="([^"]*)"').firstMatch(body)?.group(1);
      if (host == null || prefix == null || scheme == null) {
        fail('the autoVerify filter must declare android:scheme, android:host '
            'and android:pathPrefix; found scheme=$scheme host=$host '
            'prefix=$prefix. ${_repro(name)}');
      }

      final _Res res = await _page('en');
      final _Tag tag = _requireTag(res, 'open-app', name);
      final String href = tag.attrs['href'] ?? '';
      final RegExpMatch? parts =
          RegExp(r'^intent://([^/]+)(/[^#]*)#Intent;(.*)$').firstMatch(href);
      if (parts == null) {
        fail('the open-app href must look like intent://<host>/<path>'
            '#Intent;...; got "$href". ${_repro(name)}');
      }
      expect(parts.group(1), host,
          reason: 'intent host must equal the manifest android:host. '
              '${_repro(name)}');
      expect(parts.group(2), startsWith(prefix),
          reason: 'intent path must start with the manifest '
              'android:pathPrefix "$prefix". ${_repro(name)}');
      expect(parts.group(3), contains('scheme=$scheme;'),
          reason: 'intent scheme must equal the manifest android:scheme. '
              '${_repro(name)}');
    });
  });

  group('D2 copy the code', () {
    test('copy-code carries data-copy and data-copied per language', () async {
      const String name = 'D2 copy-code data attributes';
      for (final String lang in <String>['en', 'ar']) {
        final _Res res = await _page(lang);
        final _Tag tag = _requireTag(res, 'copy-code', '$name ($lang)');
        expect(tag.name, 'button',
            reason: 'copy-code must be a <button>, got <${tag.name}> on the '
                '$lang page. ${_repro(name)}');
        expect(tag.attrs['data-copy'], _s(lang, 'copy', _code),
            reason: '$lang data-copy. ${_repro(name)}');
        expect(tag.attrs['data-copied'], _s(lang, 'copied', _code),
            reason: '$lang data-copied. ${_repro(name)}');
        expect(_stripTags(_inner(res.body, tag)), _s(lang, 'copy', _code),
            reason: 'the $lang button text must start as the copy string. '
                '${_repro(name)}');
      }
    });

    test('room-code shows the code and is selectable as one unit', () async {
      const String name = 'D2 room-code element';
      final _Res res = await _page('en');
      final _Tag tag = _requireTag(res, 'room-code', name);
      expect(_stripTags(_inner(res.body, tag)).replaceAll(' ', ''), _code,
          reason: 'the room-code element text must be the code. '
              '${_repro(name)}. ${res.describe()}');
      final String style = _styleText(res.body);
      expect(
        RegExp(r'user-select\s*:\s*all').hasMatch(style),
        isTrue,
        reason: 'the style must set user-select: all for the room code. '
            '${_repro(name)}. style: $style',
      );
    });

    test('the page loads /r/room.js with a script src', () async {
      const String name = 'D2 page loads room.js';
      final _Res res = await _page('en');
      expect(res.body, contains('<script src="/r/room.js"'),
          reason: 'expected <script src="/r/room.js" in the page. '
              '${_repro(name)}. ${res.describe()}');
    });

    test('GET /r/room.js answers 200 as application/javascript', () async {
      const String name = 'D2 GET room.js';
      final _Res res = await _get('/r/room.js');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      expect(res.header('content-type'), startsWith('application/javascript'),
          reason: '${_repro(name)}. ${res.describe()}');
      expect(res.body.trim(), isNotEmpty,
          reason: 'room.js body is empty. ${_repro(name)}');
    });

    test('HEAD /r/room.js answers 200 with an empty body', () async {
      const String name = 'D2 HEAD room.js';
      final _Res res = await _request('HEAD', '/r/room.js');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      expect(res.body, isEmpty, reason: '${_repro(name)}. ${res.describe()}');
      expect(res.header('content-type'), startsWith('application/javascript'),
          reason: '${_repro(name)}. ${res.describe()}');
    });

    test('room.js holds no user-facing text from the string table', () async {
      const String name = 'D2 room.js has no user-facing text';
      final _Res res = await _get('/r/room.js');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      for (final String lang in <String>['en', 'ar']) {
        for (final String key in <String>['copy', 'copied', 'open', 'get']) {
          final String text = _s(lang, key, _code);
          expect(res.body, isNot(contains(text)),
              reason: 'room.js must take its strings from data-copy and '
                  'data-copied, but it contains "$text". ${_repro(name)}');
        }
      }
    });

    test('click copies the code, shows the copied text, then restores it',
        () async {
      const String name = 'D2 script copies on click';
      final Map<String, Object?> r =
          await _runRoomJs(scenario: 'ok', testName: name);
      final String detail = 'driver result: ${_show(r)}. ${_repro(name)}';
      _expectQuiet(r, 'ok', name);
      expect(r['clickHandlers'], greaterThanOrEqualTo(1),
          reason: 'room.js registered no click handler on #copy-code. '
              '$detail');
      expect(r['writesBeforeClick'], 0,
          reason: 'room.js wrote to the clipboard before any click. $detail');
      expect(r['writes'], <Object?>[_code],
          reason: 'expected one clipboard write of the code "$_code". '
              '$detail');
      expect(r['conditionMet'], isTrue,
          reason: 'the button text never became data-copied. $detail');
      final List<Object?> delays = r['timerDelays']! as List<Object?>;
      expect(
        delays.any((Object? d) => d is num && d >= 1500 && d <= 2500),
        isTrue,
        reason: 'expected a restore timer of about two seconds (1500 to 2500 '
            'ms), recorded delays: $delays. $detail',
      );
      expect(r['textAfterTimers'], r['textBeforeClick'],
          reason: 'after the timer the button text must return to its '
              'original data-copy text. $detail');
    });

    test(
        'with navigator.clipboard missing it selects room-code and stays quiet',
        () async {
      const String name = 'D2 script without clipboard';
      final Map<String, Object?> r =
          await _runRoomJs(scenario: 'missing', testName: name);
      _expectQuiet(r, 'missing', name);
      expect(_selectedRoomCode(r), isTrue,
          reason: 'with navigator.clipboard undefined the script must select '
              'the room-code text. driver result: ${_show(r)}. '
              '${_repro(name)}');
    });

    test('when writeText rejects it selects room-code and leaves no rejection',
        () async {
      const String name = 'D2 script with rejecting writeText';
      final Map<String, Object?> r =
          await _runRoomJs(scenario: 'reject', testName: name);
      _expectQuiet(r, 'reject', name);
      expect(r['writes'], <Object?>[_code],
          reason: 'the script must try the clipboard first. driver result: '
              '${_show(r)}. ${_repro(name)}');
      expect(_selectedRoomCode(r), isTrue,
          reason: 'after a rejected writeText the script must select the '
              'room-code text. driver result: ${_show(r)}. ${_repro(name)}');
    });
  });

  group('D3 one language per page', () {
    Future<String> chosen(String path, {String? acceptLanguage}) async {
      final _Res res = await _get(path, acceptLanguage: acceptLanguage);
      expect(res.status, 200,
          reason: 'GET $path (accept-language: $acceptLanguage) must be 200. '
              '${res.describe()}');
      if (res.body.contains('<html lang="ar" dir="rtl">')) {
        return 'ar';
      }
      if (res.body.contains('<html lang="en">')) {
        return 'en';
      }
      return 'neither: ${res.body.substring(0, min(200, res.body.length))}';
    }

    final List<List<String?>> cases = <List<String?>>[
      <String?>['no header', '/r/$_code', null, 'en'],
      <String?>['?lang=ar', '/r/$_code?lang=ar', null, 'ar'],
      <String?>['?lang=en', '/r/$_code?lang=en', null, 'en'],
      <String?>[
        '?lang=en beats Accept-Language ar',
        '/r/$_code?lang=en',
        'ar',
        'en'
      ],
      <String?>[
        '?lang=ar beats Accept-Language en',
        '/r/$_code?lang=ar',
        'en',
        'ar'
      ],
      <String?>[
        'Accept-Language ar-AE,ar;q=0.9,en;q=0.8',
        '/r/$_code',
        'ar-AE,ar;q=0.9,en;q=0.8',
        'ar',
      ],
      <String?>[
        'Accept-Language en-US,en;q=0.9,ar;q=0.5',
        '/r/$_code',
        'en-US,en;q=0.9,ar;q=0.5',
        'en',
      ],
      <String?>[
        '?lang=xx falls through to the header',
        '/r/$_code?lang=xx',
        'ar',
        'ar'
      ],
      <String?>[
        '?lang=xx with no header is English',
        '/r/$_code?lang=xx',
        null,
        'en'
      ],
      <String?>[
        '?lang=AR is not exactly ar, falls through',
        '/r/$_code?lang=AR',
        null,
        'en'
      ],
      <String?>[
        'Accept-Language ar;q=0 is refused',
        '/r/$_code',
        'ar;q=0, en;q=0.5',
        'en'
      ],
      <String?>[
        'unrelated Accept-Language is English',
        '/r/$_code',
        'fr-FR,de;q=0.8',
        'en'
      ],
    ];
    for (final List<String?> c in cases) {
      test('language choice: ${c[0]}', () async {
        final String name = 'D3 language choice: ${c[0]}';
        final String got = await chosen(c[1]!, acceptLanguage: c[2]);
        expect(got, c[3],
            reason: 'GET ${c[1]} with accept-language ${c[2]} must render '
                '${c[3]}, rendered $got. ${_repro(name)}');
      });
    }

    test('lang-switch links to the other language with its own name', () async {
      const String name = 'D3 lang-switch';
      final _Res en = await _page('en');
      final _Tag enTag = _requireTag(en, 'lang-switch', '$name (en)');
      expect(enTag.name, 'a',
          reason: 'lang-switch must be a link. ${_repro(name)}');
      expect(enTag.attrs['href'], '?lang=ar',
          reason: 'English page lang-switch href. ${_repro(name)}');
      expect(_stripTags(_inner(en.body, enTag)), 'العربية',
          reason: 'English page lang-switch text. ${_repro(name)}');

      final _Res ar = await _page('ar');
      final _Tag arTag = _requireTag(ar, 'lang-switch', '$name (ar)');
      expect(arTag.attrs['href'], '?lang=en',
          reason: 'Arabic page lang-switch href. ${_repro(name)}');
      expect(_stripTags(_inner(ar.body, arTag)), 'English',
          reason: 'Arabic page lang-switch text. ${_repro(name)}');
    });

    for (final String lang in <String>['en', 'ar']) {
      test('the code sits inside a dir="ltr" element on the $lang page',
          () async {
        final String name = 'D3 code in dir ltr ($lang)';
        final _Res res = await _page(lang);
        bool wrapped = false;
        final RegExp open = RegExp(r'<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>');
        for (final RegExpMatch m in open.allMatches(res.body)) {
          final String tagName = m.group(1)!.toLowerCase();
          if (tagName == 'html' || tagName == 'body') {
            continue;
          }
          final Map<String, String> attrs = _parseAttrs(m.group(2)!);
          if (attrs['dir'] != 'ltr') {
            continue;
          }
          final _Tag tag = _Tag(tagName, attrs, m.start, m.end);
          if (_stripTags(_inner(res.body, tag)).replaceAll(' ', '') == _code) {
            wrapped = true;
          }
        }
        expect(wrapped, isTrue,
            reason: 'expected an element with dir="ltr" (not html or body) '
                'whose text is exactly the code $_code on the $lang page. '
                '${_repro(name)}. ${res.describe()}');
      });
    }

    test('Arabic page is html lang=ar dir=rtl, English page has no dir',
        () async {
      const String name = 'D3 html attributes';
      final _Res ar = await _page('ar');
      expect(ar.body, contains('<html lang="ar" dir="rtl">'),
          reason: '${_repro(name)}. ${ar.describe()}');
      final _Res en = await _page('en');
      expect(en.body, contains('<html lang="en">'),
          reason: '${_repro(name)}. ${en.describe()}');
    });

    test('HEAD answers like GET without a body, in the chosen language',
        () async {
      const String name = 'D3 HEAD keeps vary and an empty body';
      final _Res res = await _request(
        'HEAD',
        '/r/$_code',
        headers: <String, String>{'accept-language': 'ar'},
      );
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      expect(res.body, isEmpty, reason: '${_repro(name)}. ${res.describe()}');
      expect(res.header('vary'), 'accept-language',
          reason: '${_repro(name)}. ${res.describe()}');
    });
  });

  group('D4 honest words', () {
    for (final String lang in <String>['en', 'ar']) {
      test('every string of the table is on the $lang page', () async {
        final String name = 'D4 table strings ($lang)';
        final _Res res = await _page(lang);
        expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
        final String visible = _visibleText(res.body);
        for (final String key in <String>[
          'title',
          'lead',
          'open',
          'codeLabel',
          'copy',
          'newHere',
          'get',
          'fair',
        ]) {
          final String expected = _s(lang, key, _code);
          expect(visible, contains(expected),
              reason: 'the $lang page must show the "$key" string '
                  '"$expected". ${_repro(name)}. visible text: $visible');
        }
        expect(
          _tagsWithId(res.body, 'copy-code').single.attrs['data-copied'],
          _s(lang, 'copied', _code),
          reason: 'the $lang "copied" string must be on #copy-code as '
              'data-copied. ${_repro(name)}',
        );
      });

      test('the $lang <title> is "Ludo RNG - <title string>"', () async {
        final String name = 'D4 title ($lang)';
        final _Res res = await _page(lang);
        expect(_titleText(res.body), 'Ludo RNG - ${_s(lang, 'title', _code)}',
            reason: '${_repro(name)}. ${res.describe()}');
      });

      test('the $lang page has no forbidden word', () async {
        final String name = 'D4 forbidden words ($lang)';
        final _Res res = await _page(lang);
        final String lower = res.body.toLowerCase();
        for (final String word in _forbiddenWords) {
          expect(lower, isNot(contains(word.toLowerCase())),
              reason: 'the $lang page contains the forbidden word "$word". '
                  '${_repro(name)}. ${res.describe()}');
        }
      });
    }

    test('open-app and get-app carry the table texts; get-app is the Play link',
        () async {
      const String name = 'D4 link texts';
      for (final String lang in <String>['en', 'ar']) {
        final _Res res = await _page(lang);
        final _Tag open = _requireTag(res, 'open-app', '$name ($lang)');
        expect(_stripTags(_inner(res.body, open)), _s(lang, 'open', _code),
            reason: '$lang open-app text. ${_repro(name)}');
        final _Tag get = _requireTag(res, 'get-app', '$name ($lang)');
        expect(get.attrs['href'], _playListing,
            reason: '$lang get-app href. ${_repro(name)}');
        expect(_stripTags(_inner(res.body, get)), _s(lang, 'get', _code),
            reason: '$lang get-app text. ${_repro(name)}');
      }
    });

    test('the English page has none of the Arabic strings and the reverse',
        () async {
      const String name = 'D4 no language mixing';
      final _Res en = await _page('en');
      final _Res ar = await _page('ar');
      for (final String key in _strings['ar']!.keys) {
        final String arabic = _s('ar', key, _code);
        expect(en.body, isNot(contains(arabic)),
            reason: 'the English page contains the Arabic "$key" string '
                '"$arabic". ${_repro(name)}');
        final String english = _s('en', key, _code);
        expect(ar.body, isNot(contains(english)),
            reason: 'the Arabic page contains the English "$key" string '
                '"$english". ${_repro(name)}');
      }
      final String enNoSwitch = en.body.replaceAll(
        RegExp(r'<a\b[^>]*\bid="lang-switch"[^>]*>.*?</a>', dotAll: true),
        '',
      );
      expect(RegExp(r'[؀-ۿ]').hasMatch(enNoSwitch), isFalse,
          reason: 'the English page has Arabic letters outside the '
              'lang-switch link. ${_repro(name)}. ${en.describe()}');

      String arText = _visibleText(ar.body);
      for (final String allowed in <String>[
        'Ludo RNG',
        'Google Play',
        'English',
        _code,
      ]) {
        arText = arText.replaceAll(allowed, ' ');
      }
      expect(RegExp(r'[A-Za-z]{2,}').hasMatch(arText), isFalse,
          reason: 'the Arabic page shows English words besides the brand, '
              'Google Play, the English switch label and the code. '
              '${_repro(name)}. text left: $arText');
    });
  });

  group('D5 looks like the game', () {
    test(
        'references no URL beyond room.js, the Play listing, the intent URL '
        'and the two language links', () async {
      const String name = 'D5 only allowed references';
      for (final String lang in <String>['en', 'ar']) {
        final _Res res = await _page(lang);
        expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
        final Set<String> allowed = <String>{
          '/r/room.js',
          _playListing,
          _intentUrl(_code),
          '?lang=ar',
          '?lang=en',
        };
        final RegExp ref = RegExp(
          r'''\s(?:href|src|action|formaction|poster|srcset|ping)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
          caseSensitive: false,
        );
        final List<String> seen = ref
            .allMatches(res.body)
            .map((RegExpMatch m) => _unescape(m.group(1) ?? m.group(2)!))
            .toList();
        final String otherLang = lang == 'en' ? 'ar' : 'en';
        expect(seen.toSet(), allowed.difference(<String>{'?lang=$lang'}),
            reason: 'the $lang page must reference exactly room.js, the Play '
                'listing, the intent URL and the ?lang=$otherLang link; got '
                '$seen. ${_repro(name)}');
        final String lower = res.body.toLowerCase();
        for (final String banned in <String>[
          '<img',
          '<link',
          '@import',
          'url(',
        ]) {
          expect(lower, isNot(contains(banned)),
              reason: 'the $lang page contains "$banned". ${_repro(name)}');
        }
        for (final RegExpMatch m
            in RegExp(r'<script\b([^>]*)>(.*?)</script>', dotAll: true)
                .allMatches(res.body)) {
          expect(_parseAttrs(m.group(1)!)['src'], '/r/room.js',
              reason: 'the $lang page has a script that is not /r/room.js '
                  '(inline script is blocked by the CSP). ${_repro(name)}');
          expect(m.group(2)!.trim(), isEmpty,
              reason: 'the $lang page has inline script text. '
                  '${_repro(name)}');
        }
        final RegExp plainUrl = RegExp(r'https?://[^\s"<>]*');
        for (final RegExpMatch m in plainUrl.allMatches(_unescape(res.body))) {
          expect(m.group(0), _playListing,
              reason: 'the $lang page mentions a URL other than the Play '
                  'listing. ${_repro(name)}');
        }
      }
    });

    test('the style carries the felt, paper, ink, action and seat colours',
        () async {
      const String name = 'D5 colours';
      final _Res res = await _page('en');
      final String style = _styleText(res.body).toUpperCase();
      for (final String hex in <String>[
        '#0A3D38',
        '#14665C',
        '#F7FBFA',
        '#0A2A27',
        '#0F6B5F',
        '#D32F2F',
        '#388E3C',
        '#FBC02D',
        '#1976D2',
      ]) {
        expect(style, contains(hex),
            reason: 'the page style must contain $hex (C-457 D5). '
                '${_repro(name)}. style: ${_styleText(res.body)}');
      }
    });

    test('the viewport meta lets the page fit a 360 px wide screen', () async {
      const String name = 'D5 viewport meta';
      final _Res res = await _page('en');
      expect(
        RegExp(
          r'<meta[^>]*name="viewport"[^>]*content="[^"]*width=device-width',
        ).hasMatch(res.body),
        isTrue,
        reason: 'expected a viewport meta with width=device-width. '
            '${_repro(name)}. ${res.describe()}',
      );
    });
  });

  group('D6 unchanged behaviour', () {
    for (final String lang in <String>['en', 'ar']) {
      test(
          'the $lang body for a live room code matches the body for a '
          'never-created code', () async {
        final String name = 'D6 live versus unknown ($lang)';
        final _LiveRoom room = await _createLiveRoom(name);
        try {
          final String path = '/r/${room.code}?lang=$lang';
          final _Res live = await _get(path);
          expect(live.status, 200,
              reason: 'live code ${room.code}. ${_repro(name)}. '
                  '${live.describe()}');
          // A second request for the same code, then a never-created code.
          final _Res again = await _get(path);
          expect(again.body, live.body,
              reason: 'two requests for the live code ${room.code} differ. '
                  '${_repro(name)}');

          final String unknownCode =
              room.code == _otherCode ? _code : _otherCode;
          final _Res unknown = await _get('/r/$unknownCode?lang=$lang');
          expect(unknown.status, live.status,
              reason: 'status differs for live ${room.code} and unknown '
                  '$unknownCode. ${_repro(name)}');
          expect(
            unknown.body.replaceAll(unknownCode, '<<CODE>>'),
            live.body.replaceAll(room.code, '<<CODE>>'),
            reason: 'body differs between live code ${room.code} and unknown '
                'code $unknownCode apart from the code itself; that is an '
                'oracle for room existence. ${_repro(name)}',
          );
          for (final String header in <String>[
            'content-type',
            'cache-control',
            'vary',
            'content-security-policy',
            'x-content-type-options',
            'referrer-policy',
          ]) {
            expect(unknown.header(header), live.header(header),
                reason: 'header $header differs between live ${room.code} '
                    'and unknown $unknownCode. ${_repro(name)}');
          }
        } finally {
          await room.close();
        }
      });

      test(
          'the $lang body for one code is identical while its room is live '
          'and after it is gone', () async {
        final String name = 'D6 same code during and after ($lang)';
        // The server mints the code, so the page is fetched while the room
        // is live, the room is closed, and the same path is fetched again.
        final _LiveRoom room = await _createLiveRoom(name);
        final String path = '/r/${room.code}?lang=$lang';
        late final _Res during;
        try {
          during = await _get(path);
        } finally {
          await room.close();
        }
        final _Res after = await _get(path);
        expect(after.body, during.body,
            reason: 'the page for ${room.code} changed once its room was '
                'gone. ${_repro(name)}');
      });
    }

    test('an invalid shape answers 404', () async {
      const String name = 'D6 invalid shape is 404';
      for (final String bad in <String>[
        'ABCDE',
        'ABCDEFG',
        'K7M2Q0',
        'K7M2QO',
        'K7M2Q1',
        'K7M2QI',
        'K7M-QP',
        'room.j',
      ]) {
        final _Res res = await _get('/r/$bad');
        expect(res.status, 404,
            reason: 'GET /r/$bad must be 404. ${_repro(name)}. '
                '${res.describe()}');
      }
    });

    test('HEAD of a valid code is 200 with an empty body', () async {
      const String name = 'D6 HEAD';
      final _Res res = await _request('HEAD', '/r/$_code');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      expect(res.body, isEmpty, reason: '${_repro(name)}. ${res.describe()}');
    });

    test('other methods answer 405 with allow: GET, HEAD', () async {
      const String name = 'D6 other methods are 405';
      for (final String method in <String>['POST', 'PUT', 'DELETE', 'PATCH']) {
        final _Res res = await _request(method, '/r/$_code');
        expect(res.status, 405,
            reason: '$method /r/$_code must be 405. ${_repro(name)}. '
                '${res.describe()}');
        expect(res.header('allow'), 'GET, HEAD',
            reason: '$method /r/$_code allow header. ${_repro(name)}. '
                '${res.describe()}');
      }
    });

    test('assetlinks.json is untouched: 404 with an empty body when unset',
        () async {
      const String name = 'D6 assetlinks untouched';
      final _Res res = await _get('/.well-known/assetlinks.json');
      expect(res.status, 404, reason: '${_repro(name)}. ${res.describe()}');
      expect(res.body, isEmpty, reason: '${_repro(name)}. ${res.describe()}');
    });
  });

  group('D7 headers', () {
    test('/r/<CODE> carries the pinned headers', () async {
      const String name = 'D7 page headers';
      final _Res res = await _page('en');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      final Map<String, String> expected = <String, String>{
        'content-type': 'text/html; charset=utf-8',
        'vary': 'accept-language',
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'content-security-policy': _expectedCsp,
      };
      expected.forEach((String header, String value) {
        expect(res.header(header), value,
            reason: 'header $header on /r/$_code. ${_repro(name)}. '
                '${res.describe()}');
      });
    });

    test('/r/room.js carries the pinned headers', () async {
      const String name = 'D7 script headers';
      final _Res res = await _get('/r/room.js');
      expect(res.status, 200, reason: '${_repro(name)}. ${res.describe()}');
      final Map<String, String> expected = <String, String>{
        'content-type': 'application/javascript; charset=utf-8',
        'cache-control': 'public, max-age=300',
        'x-content-type-options': 'nosniff',
      };
      expected.forEach((String header, String value) {
        expect(res.header(header), value,
            reason: 'header $header on /r/room.js. ${_repro(name)}. '
                '${res.describe()}');
      });
    });
  });
}

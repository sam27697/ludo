// Conformance tests for `GET /privacy`, written from work order 048's spec,
// not from any implementation. `WireServer` does not answer `/privacy` on
// this branch at all: a GET falls through to the pre-existing WebSocket
// upgrade path exactly the way any other unknown path does today. Every test
// below is therefore expected to fail, at the request, until another worker's
// branch (built from the identical spec, blind to this file) lands and the
// two are merged. That is reported in this order's write-up, not worked
// around here.
//
// The in-process cases reuse `ServerHarness` from `test/support/wire_harness
// .dart`, the same harness `health_test.dart`'s own private harness is
// modelled on. One case -- the `PRIVACY_CONTACT_EMAIL` behaviour, which is an
// environment variable read by the running server process, not a
// constructor argument any test here is allowed to invent -- starts the real
// `bin/server.dart` entry point as a subprocess with a controlled
// environment, exactly the way `PORT`, `TRUSTED_PROXIES` and `LUDO_VERSION`
// already work for that same entry point. That subprocess is killed in every
// path out of the test that starts one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/wire_harness.dart';

/// A base64-encoded 16 byte nonce, the shape `Sec-WebSocket-Key` requires.
/// Its value is never checked by anything below; the point of sending it is
/// only that `/privacy` must not treat it as an invitation to upgrade.
const String _websocketKey = 'dGhlIHNhbXBsZSBub25jZQ==';

const List<String> _methodsRequiringGetOrHead = <String>[
  'POST',
  'PUT',
  'DELETE',
  'PATCH',
];

Uri _httpUri(ServerHarness harness, String path) => Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: harness.server.port,
      path: path,
    );

Future<HttpClientResponse> _send(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClientRequest request = await client.openUrl(method, uri);
  headers.forEach(request.headers.set);
  return request.close();
}

Future<String> _bodyOf(HttpClientResponse response) =>
    response.transform(utf8.decoder).join();

Future<List<int>> _bytesOf(HttpClientResponse response) =>
    response.fold<List<int>>(
      <int>[],
      (List<int> soFar, List<int> chunk) => soFar..addAll(chunk),
    );

/// A running `bin/server.dart` process with a caller-controlled environment,
/// so `PRIVACY_CONTACT_EMAIL` can be asserted both set and (deliberately)
/// absent regardless of whatever happens to be in this test runner's own
/// ambient environment. Modelled on how `PORT` is already read by that same
/// entry point: `PORT=0` here so the process binds an ephemeral port and
/// prints it, the same observable interface the deploy script already
/// relies on ("ludo_server listening on port N").
class _ServerProcess {
  _ServerProcess._(this._process, this.port);

  final Process _process;
  final int port;

  static final RegExp _listeningLine = RegExp(r'listening on port (\d+)');

  static Future<_ServerProcess> start({
    required bool setContactEmail,
    String contactEmail = 'privacy@example.invalid',
  }) async {
    final Map<String, String> env = Map<String, String>.from(
      Platform.environment,
    );
    env.remove('PRIVACY_CONTACT_EMAIL');
    env['PORT'] = '0';
    if (setContactEmail) {
      env['PRIVACY_CONTACT_EMAIL'] = contactEmail;
    }

    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', 'bin/server.dart'],
      environment: env,
      includeParentEnvironment: false,
    );

    final Completer<int> portCompleter = Completer<int>();
    final List<String> stdoutLines = <String>[];
    final List<String> stderrLines = <String>[];
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      stdoutLines.add(line);
      final Match? match = _listeningLine.firstMatch(line);
      if (match != null && !portCompleter.isCompleted) {
        portCompleter.complete(int.parse(match.group(1)!));
      }
    });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add);

    final int exitCodeIfEarly = -1;
    final Future<int> earlyExit = process.exitCode;

    final int port = await Future.any<int>(<Future<int>>[
      portCompleter.future,
      earlyExit.then((int code) {
        if (portCompleter.isCompleted) {
          // The port line already won the race; this branch's value is
          // discarded either way.
          return exitCodeIfEarly;
        }
        fail(
          'bin/server.dart exited with code $code before printing a '
          'listening port. stdout: ${stdoutLines.join('\n')} stderr: '
          '${stderrLines.join('\n')}',
        );
      }),
    ]).timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        fail(
          'bin/server.dart did not print "listening on port" within 15s. '
          'stdout so far: ${stdoutLines.join('\n')} stderr so far: '
          '${stderrLines.join('\n')}',
        );
      },
    );

    return _ServerProcess._(process, port);
  }

  Uri uri(String path) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path);

  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }

  Process get process => _process;
}

void main() {
  late HttpClient client;
  ServerHarness? active;
  _ServerProcess? activeProcess;

  setUp(() {
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    if (active != null) {
      await active!.close();
      active = null;
    }
    if (activeProcess != null) {
      await activeProcess!.stop();
      activeProcess = null;
    }
  });

  test(
    'GET /privacy answers 200 with content-type text/html; charset=utf-8',
    () async {
      final ServerHarness harness = ServerHarness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response = await _send(
        client,
        _httpUri(harness, '/privacy'),
      );
      final String body = await _bodyOf(response);

      expect(
        response.statusCode,
        200,
        reason: 'GET /privacy must answer 200; got ${response.statusCode} '
            'with body "$body"',
      );
      expect(
        response.headers.value('content-type'),
        'text/html; charset=utf-8',
        reason: 'content-type on GET /privacy must be exactly '
            '"text/html; charset=utf-8", got '
            '"${response.headers.value('content-type')}"',
      );
    },
  );

  test('cache-control on /privacy is exactly public, max-age=3600', () async {
    final ServerHarness harness = ServerHarness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      _httpUri(harness, '/privacy'),
    );
    await _bodyOf(response);

    expect(
      response.headers.value('cache-control'),
      'public, max-age=3600',
      reason: 'cache-control on GET /privacy must be exactly '
          '"public, max-age=3600", got '
          '"${response.headers.value('cache-control')}"',
    );
  });

  test(
      'the body is one complete, self-contained HTML document with doctype, '
      'html lang=en, a Ludo RNG title and a body tag', () async {
    final ServerHarness harness = ServerHarness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      _httpUri(harness, '/privacy'),
    );
    final String body = await _bodyOf(response);
    final String lower = body.toLowerCase();

    expect(
      lower.trimLeft().startsWith('<!doctype html'),
      isTrue,
      reason: 'expected the document to begin with a doctype, got the '
          'first 80 characters: "${body.substring(0, body.length < 80 ? body.length : 80)}"',
    );
    expect(
      body.contains('<html lang="en">'),
      isTrue,
      reason: 'expected the literal tag <html lang="en"> somewhere in the '
          'document; full body: $body',
    );
    final RegExpMatch? titleMatch = RegExp(
      r'<title>(.*?)</title>',
      dotAll: true,
    ).firstMatch(body);
    expect(
      titleMatch,
      isNotNull,
      reason: 'expected a <title>...</title> element; full body: $body',
    );
    if (titleMatch != null) {
      expect(
        titleMatch.group(1),
        contains('Ludo RNG'),
        reason: 'expected the <title> to contain "Ludo RNG", got '
            '"${titleMatch.group(1)}"',
      );
    }
    expect(
      lower.contains('<body'),
      isTrue,
      reason: 'expected a <body> element; full body: $body',
    );
  });

  test('the document references no external resource at all', () async {
    final ServerHarness harness = ServerHarness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      _httpUri(harness, '/privacy'),
    );
    final String body = await _bodyOf(response);
    final String lower = body.toLowerCase();

    expect(
      lower.contains('<script'),
      isFalse,
      reason: 'a privacy policy claiming no third-party sharing may not '
          'load a <script>; full body: $body',
    );
    expect(
      lower.contains('<link'),
      isFalse,
      reason: 'a privacy policy claiming no third-party sharing may not '
          'reference a <link>; full body: $body',
    );
    expect(
      lower.contains('<img'),
      isFalse,
      reason: 'a privacy policy claiming no third-party sharing may not '
          'load an <img>; full body: $body',
    );

    final Iterable<RegExpMatch> urlMatches =
        RegExp(r'''https?://[^\s"'<>)]+''').allMatches(body);
    for (final RegExpMatch match in urlMatches) {
      final String raw = match.group(0)!;
      final Uri parsed = Uri.parse(raw);
      expect(
        parsed.host,
        'ludo.provefair.app',
        reason: 'found a URL pointing at a host other than '
            'ludo.provefair.app: "$raw"; full body: $body',
      );
    }
  });

  test(
    'HEAD /privacy answers 200 with the same headers and an empty body',
    () async {
      final ServerHarness harness = ServerHarness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse getResponse = await _send(
        client,
        _httpUri(harness, '/privacy'),
      );
      await _bodyOf(getResponse);

      final HttpClientResponse headResponse = await _send(
        client,
        _httpUri(harness, '/privacy'),
        method: 'HEAD',
      );
      final String headBody = await _bodyOf(headResponse);

      expect(
        headResponse.statusCode,
        200,
        reason: 'HEAD /privacy must answer 200, got ${headResponse.statusCode}',
      );
      expect(
        headResponse.headers.value('content-type'),
        getResponse.headers.value('content-type'),
        reason: 'HEAD /privacy content-type must match GET /privacy '
            'content-type "${getResponse.headers.value('content-type')}", '
            'got "${headResponse.headers.value('content-type')}"',
      );
      expect(
        headResponse.headers.value('cache-control'),
        getResponse.headers.value('cache-control'),
        reason: 'HEAD /privacy cache-control must match GET /privacy '
            'cache-control "${getResponse.headers.value('cache-control')}", '
            'got "${headResponse.headers.value('cache-control')}"',
      );
      expect(
        headBody,
        isEmpty,
        reason: 'HEAD /privacy body must be empty, got "$headBody"',
      );
    },
  );

  for (final String method in _methodsRequiringGetOrHead) {
    test(
        '$method /privacy answers 405 with an allow header containing GET '
        'and HEAD', () async {
      final ServerHarness harness = ServerHarness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response = await _send(
        client,
        _httpUri(harness, '/privacy'),
        method: method,
      );
      await _bodyOf(response);

      expect(
        response.statusCode,
        405,
        reason: '$method /privacy must answer 405, got '
            '${response.statusCode}',
      );
      final String? allow = response.headers.value('allow');
      expect(
        allow,
        isNotNull,
        reason: '$method /privacy must set an allow header',
      );
      if (allow != null) {
        expect(
          allow,
          contains('GET'),
          reason: 'allow header on $method /privacy was "$allow", '
              'expected it to contain GET',
        );
        expect(
          allow,
          contains('HEAD'),
          reason: 'allow header on $method /privacy was "$allow", '
              'expected it to contain HEAD',
        );
      }
    });
  }

  test(
    '/privacy/ with a trailing slash answers exactly as /privacy does',
    () async {
      final ServerHarness harness = ServerHarness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse plain = await _send(
        client,
        _httpUri(harness, '/privacy'),
      );
      final List<int> plainBytes = await _bytesOf(plain);

      final HttpClientResponse slashed = await _send(
        client,
        _httpUri(harness, '/privacy/'),
      );
      final List<int> slashedBytes = await _bytesOf(slashed);

      expect(
        slashed.statusCode,
        plain.statusCode,
        reason: '/privacy/ status ${slashed.statusCode} must match /privacy '
            'status ${plain.statusCode}',
      );
      expect(
        slashed.headers.value('content-type'),
        plain.headers.value('content-type'),
        reason: '/privacy/ content-type must match /privacy content-type',
      );
      expect(
        slashedBytes,
        plainBytes,
        reason: '/privacy/ body bytes (${slashedBytes.length} bytes) must be '
            'identical to /privacy body bytes (${plainBytes.length} bytes)',
      );
    },
  );

  test(
      '/Privacy and /PRIVACY are not the privacy page, matching what '
      '/Health already produces for /health', () async {
    final ServerHarness harness = ServerHarness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse healthWrongCase = await _send(
      client,
      _httpUri(harness, '/Health'),
    );
    await _bodyOf(healthWrongCase);
    final int existingWrongCaseBehaviour = healthWrongCase.statusCode;

    final HttpClientResponse privacyCapital = await _send(
      client,
      _httpUri(harness, '/Privacy'),
    );
    await _bodyOf(privacyCapital);
    final HttpClientResponse privacyAllCaps = await _send(
      client,
      _httpUri(harness, '/PRIVACY'),
    );
    await _bodyOf(privacyAllCaps);

    expect(
      privacyCapital.statusCode,
      existingWrongCaseBehaviour,
      reason: '/Privacy must fall through to exactly what /Health already '
          'produces today ($existingWrongCaseBehaviour), got '
          '${privacyCapital.statusCode}',
    );
    expect(
      privacyAllCaps.statusCode,
      existingWrongCaseBehaviour,
      reason: '/PRIVACY must fall through to exactly what /Health already '
          'produces today ($existingWrongCaseBehaviour), got '
          '${privacyAllCaps.statusCode}',
    );
  });

  test(
      'GET /privacy with WebSocket upgrade headers still answers the HTML '
      'document, never upgrading', () async {
    final ServerHarness harness = ServerHarness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      _httpUri(harness, '/privacy'),
      headers: <String, String>{
        'connection': 'Upgrade',
        'upgrade': 'websocket',
        'sec-websocket-version': '13',
        'sec-websocket-key': _websocketKey,
      },
    );
    final String body = await _bodyOf(response);

    expect(
      response.statusCode,
      200,
      reason: '/privacy must never upgrade, even with upgrade headers set; '
          'got status ${response.statusCode} with body "$body"',
    );
    expect(
      response.headers.value('content-type'),
      'text/html; charset=utf-8',
      reason: 'content-type on the upgrade-headers request to /privacy '
          'must still be text/html; charset=utf-8, got '
          '"${response.headers.value('content-type')}"',
    );
  });

  test(
    'the document contains Last updated: followed by a YYYY-MM-DD date',
    () async {
      final ServerHarness harness = ServerHarness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response = await _send(
        client,
        _httpUri(harness, '/privacy'),
      );
      final String body = await _bodyOf(response);

      expect(
        RegExp(r'Last updated:\s*\d{4}-\d{2}-\d{2}').hasMatch(body),
        isTrue,
        reason: 'expected "Last updated:" followed by a YYYY-MM-DD date '
            'somewhere in the document; full body: $body',
      );
    },
  );

  test('the document contains no unresolved editorial placeholder', () async {
    final ServerHarness harness = ServerHarness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      _httpUri(harness, '/privacy'),
    );
    final String body = await _bodyOf(response);
    final String upper = body.toUpperCase();

    for (final String token in <String>[
      '[DATE',
      '[EMAIL',
      'TODO',
      'TBD',
      'FIXME',
    ]) {
      expect(
        upper.contains(token),
        isFalse,
        reason: 'found unresolved placeholder token "$token" in the '
            'document; full body: $body',
      );
    }

    final RegExpMatch? bracketed = RegExp(r'\[[^\]]+\]').firstMatch(body);
    expect(
      bracketed,
      isNull,
      reason: 'found a bracketed editorial instruction '
          '"${bracketed?.group(0)}" in the document; full body: $body',
    );
  });

  test(
      'the document contains no em-dash, no emoji, and avoids '
      '"Note that" / "This ensures"', () async {
    final ServerHarness harness = ServerHarness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      _httpUri(harness, '/privacy'),
    );
    final String body = await _bodyOf(response);

    expect(
      body.contains('—'),
      isFalse,
      reason: 'found an em-dash (U+2014) in the served document; the '
          'source draft in work/ludo/PRIVACY_DRAFT.md has three, none of '
          'which may reach the served page. Full body: $body',
    );

    final RegExp emoji = RegExp(
      r'[\u{1F1E6}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]',
      unicode: true,
    );
    expect(
      emoji.hasMatch(body),
      isFalse,
      reason: 'found an emoji codepoint in the served document; full '
          'body: $body',
    );

    expect(
      body.contains('Note that'),
      isFalse,
      reason: 'found the banned phrase "Note that" in the document',
    );
    expect(
      body.contains('This ensures'),
      isFalse,
      reason: 'found the banned phrase "This ensures" in the document',
    );
  });

  test(
      'PRIVACY_CONTACT_EMAIL set to a non-empty value puts that exact '
      'address in the document', () async {
    const String email = 'privacy-test@example.invalid';
    final _ServerProcess proc = await _ServerProcess.start(
      setContactEmail: true,
      contactEmail: email,
    );
    activeProcess = proc;

    final HttpClientResponse response = await _send(
      client,
      proc.uri('/privacy'),
    );
    final String body = await _bodyOf(response);

    expect(
      response.statusCode,
      200,
      reason: 'GET /privacy with PRIVACY_CONTACT_EMAIL="$email" set must '
          'still answer 200, got ${response.statusCode} with body "$body"',
    );
    expect(
      body.contains(email),
      isTrue,
      reason: 'expected the exact configured address "$email" in the '
          'document when PRIVACY_CONTACT_EMAIL is set; full body: $body',
    );
  });

  test(
      'PRIVACY_CONTACT_EMAIL unset omits the contact paragraph and still '
      'answers 200', () async {
    final _ServerProcess proc = await _ServerProcess.start(
      setContactEmail: false,
    );
    activeProcess = proc;

    final HttpClientResponse response = await _send(
      client,
      proc.uri('/privacy'),
    );
    final String body = await _bodyOf(response);

    expect(
      response.statusCode,
      200,
      reason: 'GET /privacy with PRIVACY_CONTACT_EMAIL unset must still '
          'answer 200, got ${response.statusCode} with body "$body"',
    );
    expect(
      body.toLowerCase().contains('@'),
      isFalse,
      reason: 'expected no contact address (no "@") in the document when '
          'PRIVACY_CONTACT_EMAIL is unset or empty; full body: $body',
    );
  });

  group('the required claims, each by a distinctive phrase', () {
    late ServerHarness harness;
    late String body;

    setUp(() async {
      harness = ServerHarness.build();
      active = harness;
      await harness.start();
      final HttpClientResponse response = await _send(
        client,
        _httpUri(harness, '/privacy'),
      );
      body = await _bodyOf(response);
    });

    test('there is no account and no sign-in', () {
      final String lower = body.toLowerCase();
      expect(
        lower.contains('no account'),
        isTrue,
        reason: 'expected the phrase "no account" in the document; '
            'see work/ludo/PRIVACY_DRAFT.md "no account, no sign-in"; '
            'full body: $body',
      );
      expect(
        lower.contains('no sign-in'),
        isTrue,
        reason: 'expected the phrase "no sign-in" in the document; full '
            'body: $body',
      );
    });

    test(
        'there is no advertising, no analytics and no third-party '
        'tracking', () {
      final String lower = body.toLowerCase();
      expect(
        lower.contains('no advertising'),
        isTrue,
        reason: 'expected the phrase "no advertising" in the document; '
            'full body: $body',
      );
      expect(
        lower.contains('no analytics'),
        isTrue,
        reason: 'expected the phrase "no analytics" in the document; full '
            'body: $body',
      );
      expect(
        lower.contains('tracking'),
        isTrue,
        reason: 'expected some mention of "tracking" in the document; '
            'full body: $body',
      );
    });

    test('a display name entered for a seat is visible to the room', () {
      final String lower = body.toLowerCase();
      expect(
        lower.contains('display name'),
        isTrue,
        reason: 'expected the phrase "display name" in the document; full '
            'body: $body',
      );
      expect(
        lower.contains('visible to'),
        isTrue,
        reason: 'expected the phrase "visible to" in the document; full '
            'body: $body',
      );
    });

    test('rooms are temporary and are deleted when they end or expire', () {
      final String lower = body.toLowerCase();
      expect(
        lower.contains('rooms are temporary'),
        isTrue,
        reason: 'expected the phrase "rooms are temporary" in the '
            'document; full body: $body',
      );
      expect(
        lower.contains('expire'),
        isTrue,
        reason: 'expected some mention of "expire" (rooms ending or '
            'expiring) in the document; full body: $body',
      );
    });

    test(
        'the server records IP address, connection time and error '
        'information', () {
      final String lower = body.toLowerCase();
      expect(
        lower.contains('ip address'),
        isTrue,
        reason: 'expected the phrase "IP address" in the document; full '
            'body: $body',
      );
      expect(
        lower.contains('connection'),
        isTrue,
        reason: 'expected some mention of "connection" (time of the '
            'connection) in the document; full body: $body',
      );
      expect(
        lower.contains('error'),
        isTrue,
        reason: 'expected some mention of "error" (error information) in '
            'the document; full body: $body',
      );
    });

    test('the app is not directed at children under 13', () {
      final String lower = body.toLowerCase();
      expect(
        lower.contains('under 13'),
        isTrue,
        reason: 'expected the phrase "under 13" in the document; full '
            'body: $body',
      );
    });
  });

  test(
    '/health still answers exactly as it did before /privacy existed',
    () async {
      final ServerHarness harness = ServerHarness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response = await _send(
        client,
        _httpUri(harness, '/health'),
      );
      final String body = await _bodyOf(response);

      expect(
        response.statusCode,
        200,
        reason: 'GET /health regressed after adding /privacy: expected 200, '
            'got ${response.statusCode} with body "$body"',
      );
      expect(
        response.headers.value('content-type'),
        contains('application/json'),
        reason: 'GET /health content-type regressed after adding /privacy: '
            'got "${response.headers.value('content-type')}"',
      );
      expect(
        response.headers.value('cache-control'),
        'no-store',
        reason: 'GET /health cache-control regressed after adding /privacy: '
            'got "${response.headers.value('cache-control')}"',
      );
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        fail('GET /health regressed: expected a JSON object body, got: $body');
      }
      expect(
        decoded['status'],
        'ok',
        reason: 'GET /health "status" field regressed after adding '
            '/privacy, got ${decoded['status']}',
      );
    },
  );
}

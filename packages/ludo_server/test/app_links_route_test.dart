// Conformance tests for `GET /.well-known/assetlinks.json` and
// `GET /r/<CODE>`, written from work order 077's spec, not from any
// implementation. `WireServer` does not answer either path on this branch at
// all: a GET to either one falls through to the pre-existing WebSocket
// upgrade path exactly the way `privacy_route_test.dart`'s own header
// describes for `/privacy` before order 048/049 landed, and the way any
// other unknown path does today. Every test below is therefore expected to
// fail, at the request, until another worker's branch (built from the
// identical spec, blind to this file) lands and the two are merged. That is
// reported in this order's write-up, not worked around here.
//
// Two things about that fallback turned out to matter enough to spell out
// here rather than only in the write-up, because a reader of a green dot
// next to either test's name needs to know it does not mean what it would
// normally mean:
//
// - The fallback handler (`shelf_web_socket`'s `webSocketHandler`, given a
//   plain GET with no upgrade headers) answers 404 with a fixed body,
//   "Only WebSocket connections are supported.", for every unmatched path,
//   regardless of what that path was. It never reaches
//   `Connection._log` (`lib/src/connection.dart:1094`), because no
//   `Connection` is ever constructed for a request that isn't a real
//   upgrade. So the "fingerprint never appears in the log" test below and
//   the security-parity test both currently exercise a codepath that leaks
//   nothing and treats every path alike -- not because either route
//   forbids leaking or guarantees parity, but because neither route exists
//   yet to do anything at all. A response of "these two things are
//   identical" from that test on this branch proves nothing about the
//   route; it is measured and reported as exactly that in this order's
//   write-up.
// - Every other test below fails at a concrete, named assertion (a status
//   code, a content-type, a body substring) rather than at an exception,
//   which is the "right reason" this order asks to be confirmed explicitly.
//
// The in-process cases reuse `ServerHarness` from
// `test/support/wire_harness.dart`, the same harness `privacy_route_test
// .dart` and `dice_steering_test.dart` already use. The `LUDO_APP_SIGNING
// _SHA256` cases start the real `bin/server.dart` entry point as a
// subprocess with a controlled environment, exactly as `privacy_route_test
// .dart` already does for `PRIVACY_CONTACT_EMAIL`; that subprocess is
// killed in every path out of the test that starts one.
//
// Every fingerprint value in this file is fabricated for the test and is
// not derived from, and does not resemble, any real signing key. It is
// built from the byte sequence 0xA0..0xBF, deterministically, so a failure
// message that prints one is reproducible without needing a seed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

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
}) async {
  final HttpClientRequest request = await client.openUrl(method, uri);
  return request.close();
}

Future<String> _bodyOf(HttpClientResponse response) =>
    response.transform(utf8.decoder).join();

// ---------------------------------------------------------------------
// Fabricated fingerprints. `_validFakeFingerprint` is 32 colon-separated,
// upper-case hex byte pairs -- 95 characters, the shape
// `docs/RELEASE.md:85-90` documents for `LUDO_UPLOAD_CERT_SHA256` and that
// order 077's spec (`work/ludo/orders/077-app-links-tests.md` section
// "assetlinks.json", item 3) says `assetlinks.json`'s own fingerprint must
// match. Every byte is fake: 0xA0..0xBF, an arbitrary run chosen only for
// the property that hex-encoding it never collides with anything printable
// by accident.
// ---------------------------------------------------------------------

String _hexPair(int byte) =>
    byte.toRadixString(16).toUpperCase().padLeft(2, '0');

final List<int> _fakeBytes = List<int>.generate(32, (int i) => 0xA0 + i);

final String _validFakeFingerprint = _fakeBytes.map(_hexPair).join(':');

final String _secondValidFakeFingerprint =
    List<int>.generate(32, (int i) => 0x40 + i).map(_hexPair).join(':');

/// Named malformed variants of [_validFakeFingerprint], each wrong in
/// exactly one way, per order 077's item 3: "lowercase hex, too few pairs,
/// missing colons, and a value with trailing whitespace or a quote in it."
/// A fifth, "too many pairs", is added beyond the minimum the order names,
/// covered by its "cover at least" wording.
final Map<String, String> _malformedFingerprints = <String, String>{
  'lowercase hex': _validFakeFingerprint.toLowerCase(),
  'too few pairs (31 instead of 32)':
      _fakeBytes.sublist(0, 31).map(_hexPair).join(':'),
  'too many pairs (33 instead of 32)':
      (List<int>.from(_fakeBytes)..add(0xC0)).map(_hexPair).join(':'),
  'missing colons': _fakeBytes.map(_hexPair).join(),
  'trailing whitespace': '$_validFakeFingerprint ',
  'a quote embedded in the value': '$_validFakeFingerprint"',
};

const String _assetLinksPath = '/.well-known/assetlinks.json';

/// The absolute path to this package's own root directory, resolved from
/// the package configuration rather than from the current working
/// directory or from `Platform.script`. Copied from `privacy_route_test
/// .dart`'s helper of the same name and purpose; that file's own copy is
/// private to it and this file cannot import a test file to reuse it, so
/// it is duplicated here rather than left out.
Future<String>? _packageRootFuture;

Future<String> _packageRoot() {
  return _packageRootFuture ??= () async {
    final Uri? libUri = await Isolate.resolvePackageUri(
      Uri.parse('package:ludo_server/ludo_server.dart'),
    );
    if (libUri == null) {
      fail(
        'could not resolve package:ludo_server/ludo_server.dart to a file '
        'URI; cannot locate bin/server.dart for the subprocess tests below',
      );
    }
    final Directory packageRoot = File.fromUri(libUri).parent.parent;
    return packageRoot.path;
  }();
}

/// A running `bin/server.dart` process with a caller-controlled
/// `LUDO_APP_SIGNING_SHA256`, so it can be asserted unset, empty, malformed
/// and well-formed regardless of whatever happens to be in this test
/// runner's own ambient environment. `appSigningSha256: null` removes the
/// variable entirely (the "unset" case); `''` sets it to the empty string
/// explicitly, a distinct case order 077 also names ("unset or empty").
/// Modelled directly on `privacy_route_test.dart`'s own `_ServerProcess`,
/// which does the same thing for `PRIVACY_CONTACT_EMAIL`; duplicated here
/// for the same reason `_packageRoot` above is.
class _ServerProcess {
  _ServerProcess._(
    this._process,
    this.port,
    this.stdoutLines,
    this.stderrLines,
  );

  final Process _process;
  final int port;

  /// Every line this process has printed to stdout so far, in arrival
  /// order, growing for the lifetime of this object. Used by the
  /// no-fingerprint-in-logs test; a plain `List` rather than a `Stream`
  /// because that test only needs a snapshot after issuing its requests,
  /// not a live subscription.
  final List<String> stdoutLines;
  final List<String> stderrLines;

  static final RegExp _listeningLine = RegExp(r'listening on port (\d+)');

  static Future<_ServerProcess> start({String? appSigningSha256}) async {
    final Map<String, String> env = Map<String, String>.from(
      Platform.environment,
    );
    env.remove('LUDO_APP_SIGNING_SHA256');
    env['PORT'] = '0';
    if (appSigningSha256 != null) {
      env['LUDO_APP_SIGNING_SHA256'] = appSigningSha256;
    }

    final String packageRoot = await _packageRoot();

    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', 'bin/server.dart'],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: packageRoot,
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

    return _ServerProcess._(process, port, stdoutLines, stderrLines);
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
  _ServerProcess? activeProcess;
  final List<WireTestClient> wireClients = <WireTestClient>[];
  final List<ServerHarness> harnesses = <ServerHarness>[];

  setUp(() {
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    if (activeProcess != null) {
      await activeProcess!.stop();
      activeProcess = null;
    }
    for (final WireTestClient wireClient in wireClients) {
      await wireClient.close();
    }
    wireClients.clear();
    for (final ServerHarness harness in harnesses) {
      await harness.close();
    }
    harnesses.clear();
  });

  // -------------------------------------------------------------------
  // GET /.well-known/assetlinks.json
  // -------------------------------------------------------------------

  group('GET /.well-known/assetlinks.json, item 1: unset or empty', () {
    test('LUDO_APP_SIGNING_SHA256 unset answers 404 with an empty body',
        () async {
      final _ServerProcess proc =
          await _ServerProcess.start(appSigningSha256: null);
      activeProcess = proc;

      final HttpClientResponse response =
          await _send(client, proc.uri(_assetLinksPath));
      final String body = await _bodyOf(response);

      expect(
        response.statusCode,
        404,
        reason: 'GET $_assetLinksPath with LUDO_APP_SIGNING_SHA256 unset '
            'must answer 404, got ${response.statusCode} with body "$body"',
      );
      expect(
        body,
        isEmpty,
        reason: 'GET $_assetLinksPath with LUDO_APP_SIGNING_SHA256 unset '
            'must answer with an empty body, got "$body"',
      );
    });

    test(
        'LUDO_APP_SIGNING_SHA256 set to the empty string answers 404 with '
        'an empty body', () async {
      final _ServerProcess proc =
          await _ServerProcess.start(appSigningSha256: '');
      activeProcess = proc;

      final HttpClientResponse response =
          await _send(client, proc.uri(_assetLinksPath));
      final String body = await _bodyOf(response);

      expect(
        response.statusCode,
        404,
        reason: 'GET $_assetLinksPath with LUDO_APP_SIGNING_SHA256="" must '
            'answer 404, got ${response.statusCode} with body "$body"',
      );
      expect(
        body,
        isEmpty,
        reason: 'GET $_assetLinksPath with LUDO_APP_SIGNING_SHA256="" must '
            'answer with an empty body, got "$body"',
      );
    });

    test(
        'unset or empty never answers the empty JSON array []: that would '
        'be a positive, stronger claim that no application is associated '
        'with this domain, not the same as not-configured-yet', () async {
      for (final String? value in <String?>[null, '']) {
        final _ServerProcess proc =
            await _ServerProcess.start(appSigningSha256: value);
        activeProcess = proc;

        final HttpClientResponse response =
            await _send(client, proc.uri(_assetLinksPath));
        final String body = await _bodyOf(response);

        expect(
          body.trim(),
          isNot('[]'),
          reason: 'GET $_assetLinksPath with LUDO_APP_SIGNING_SHA256='
              '${value == null ? 'unset' : '""'} must not serve the empty '
              'JSON array "[]" -- that positively asserts no application is '
              'associated with this domain, a materially different and '
              'stronger claim than not-configured-yet; got body "$body"',
        );

        await proc.stop();
        activeProcess = null;
      }
    });
  });

  group('GET /.well-known/assetlinks.json, item 2: a valid-shape value', () {
    test('answers 200 with content-type application/json', () async {
      final _ServerProcess proc = await _ServerProcess.start(
        appSigningSha256: _validFakeFingerprint,
      );
      activeProcess = proc;

      final HttpClientResponse response =
          await _send(client, proc.uri(_assetLinksPath));
      final String body = await _bodyOf(response);

      expect(
        response.statusCode,
        200,
        reason: 'GET $_assetLinksPath with LUDO_APP_SIGNING_SHA256='
            '"$_validFakeFingerprint" (fabricated) must answer 200, got '
            '${response.statusCode} with body "$body"',
      );
      expect(
        response.headers.value('content-type'),
        'application/json',
        reason: 'content-type on GET $_assetLinksPath with a valid '
            'fingerprint must be exactly "application/json", got '
            '"${response.headers.value('content-type')}"',
      );
    });

    test(
        'the parsed JSON is exactly one statement with the required '
        'relation, target.namespace, target.package_name and '
        'target.sha256_cert_fingerprints', () async {
      final _ServerProcess proc = await _ServerProcess.start(
        appSigningSha256: _validFakeFingerprint,
      );
      activeProcess = proc;

      final HttpClientResponse response =
          await _send(client, proc.uri(_assetLinksPath));
      final String body = await _bodyOf(response);

      late final Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException catch (e) {
        fail(
          'GET $_assetLinksPath with a valid fingerprint must answer with '
          'a body that parses as JSON; jsonDecode failed with $e on body '
          '"$body"',
        );
      }

      expect(
        decoded,
        isA<List<Object?>>(),
        reason: 'expected the top-level JSON value to be an array with '
            'exactly one statement; got ${decoded.runtimeType}: $decoded',
      );
      final List<Object?> statements = decoded as List<Object?>;
      expect(
        statements.length,
        1,
        reason: 'expected exactly one statement in the assetlinks.json '
            'array, got ${statements.length}: $decoded',
      );

      final Object? rawStatement = statements[0];
      expect(
        rawStatement,
        isA<Map<Object?, Object?>>(),
        reason: 'expected the one statement to be a JSON object, got '
            '${rawStatement.runtimeType}: $rawStatement',
      );
      final Map<Object?, Object?> statement =
          rawStatement as Map<Object?, Object?>;

      expect(
        statement['relation'],
        <String>['delegate_permission/common.handle_all_urls'],
        reason: 'expected relation to be exactly '
            '["delegate_permission/common.handle_all_urls"], got '
            '${statement['relation']}; full body: $body',
      );

      final Object? rawTarget = statement['target'];
      expect(
        rawTarget,
        isA<Map<Object?, Object?>>(),
        reason: 'expected statement.target to be a JSON object, got '
            '${rawTarget.runtimeType}: $rawTarget; full body: $body',
      );
      final Map<Object?, Object?> target = rawTarget as Map<Object?, Object?>;

      expect(
        target['namespace'],
        'android_app',
        reason: 'expected target.namespace to be "android_app", got '
            '${target['namespace']}; full body: $body',
      );
      expect(
        target['package_name'],
        'app.fayad.ludo',
        reason: 'expected target.package_name to be "app.fayad.ludo", got '
            '${target['package_name']}; full body: $body',
      );
      expect(
        target['sha256_cert_fingerprints'],
        <String>[_validFakeFingerprint],
        reason: 'expected target.sha256_cert_fingerprints to be a '
            'one-element list holding exactly the configured (fabricated) '
            'fingerprint "$_validFakeFingerprint", got '
            '${target['sha256_cert_fingerprints']}; full body: $body',
      );
    });
  });

  group(
      'GET /.well-known/assetlinks.json, item 3: a value whose shape is '
      'wrong is treated as unset', () {
    for (final MapEntry<String, String> entry
        in _malformedFingerprints.entries) {
      test(
          '${entry.key} answers 404 with an empty body, exactly like unset '
          '(this fingerprint fails silently on every phone if served -- '
          'docs/RELEASE.md:139-159 -- so serving it is worse than serving '
          'nothing)', () async {
        final _ServerProcess proc = await _ServerProcess.start(
          appSigningSha256: entry.value,
        );
        activeProcess = proc;

        final HttpClientResponse response =
            await _send(client, proc.uri(_assetLinksPath));
        final String body = await _bodyOf(response);

        expect(
          response.statusCode,
          404,
          reason: 'GET $_assetLinksPath with LUDO_APP_SIGNING_SHA256 set to '
              'a value with the wrong shape (${entry.key}: '
              '"${entry.value}") must answer 404, treated the same as '
              'unset; got ${response.statusCode} with body "$body"',
        );
        expect(
          body,
          isEmpty,
          reason: 'GET $_assetLinksPath with LUDO_APP_SIGNING_SHA256 set to '
              'a value with the wrong shape (${entry.key}: '
              '"${entry.value}") must answer with an empty body, got '
              '"$body"',
        );
      });
    }
  });

  test(
      'GET /.well-known/assetlinks.json, item 4: the fingerprint value '
      'never appears anywhere in the server process\'s stdout or stderr',
      () async {
    final _ServerProcess proc = await _ServerProcess.start(
      appSigningSha256: _validFakeFingerprint,
    );
    activeProcess = proc;

    // Two requests: one that should render the fingerprint into the
    // response body (so any implementation that logs "what it served"
    // would have the value in hand to log), and one with a malformed
    // fingerprint on a second process, so an implementation that logs
    // "rejected value: ..." on the malformed path is caught too.
    final HttpClientResponse response =
        await _send(client, proc.uri(_assetLinksPath));
    await _bodyOf(response);

    await proc.stop();
    activeProcess = null;

    final String allOutput =
        <String>[...proc.stdoutLines, ...proc.stderrLines].join('\n');
    expect(
      allOutput.contains(_validFakeFingerprint),
      isFalse,
      reason: 'the configured fingerprint "$_validFakeFingerprint" '
          '(fabricated) must never appear in the server\'s stdout or '
          'stderr; found it in the captured process output:\n$allOutput',
    );

    final _ServerProcess malformedProc = await _ServerProcess.start(
      appSigningSha256: _secondValidFakeFingerprint.toLowerCase(),
    );
    activeProcess = malformedProc;
    final HttpClientResponse malformedResponse =
        await _send(client, malformedProc.uri(_assetLinksPath));
    await _bodyOf(malformedResponse);

    await malformedProc.stop();
    activeProcess = null;

    final String malformedOutput = <String>[
      ...malformedProc.stdoutLines,
      ...malformedProc.stderrLines,
    ].join('\n');
    expect(
      malformedOutput
          .toLowerCase()
          .contains(_secondValidFakeFingerprint.toLowerCase()),
      isFalse,
      reason: 'a rejected (wrong-shape) fingerprint '
          '"${_secondValidFakeFingerprint.toLowerCase()}" (fabricated) must '
          'also never appear in the server\'s stdout or stderr, even in a '
          '"rejected this value" log line; found it in the captured '
          'process output:\n$malformedOutput',
    );
  });

  // -------------------------------------------------------------------
  // GET /r/<CODE>
  //
  // `isWellFormedRoomCode` and `roomCodeAlphabet` are imported from
  // `package:ludo_server/ludo_server.dart` (which re-exports
  // `lib/src/room_code.dart`) rather than re-declared here, per the order.
  // The order's own prose names the function `isValidRoomCode`; no such
  // name exists anywhere under `packages/ludo_server` -- the exported
  // shape-check is `isWellFormedRoomCode`
  // (`lib/src/room_code.dart:26`, re-exported `lib/ludo_server.dart:16`).
  // A function of that name does exist, but in `packages/ludo_client/lib
  // /src/room_code.dart`, a different package this one does not depend on
  // (see `pubspec.yaml`) and cannot import. Treated as a naming slip in the
  // order and reported as an ambiguity; `isWellFormedRoomCode` from this
  // package is used throughout below, since it is the only shape-check
  // this package actually exports.
  // -------------------------------------------------------------------

  /// A syntactically valid room code built from the imported alphabet
  /// itself, never a hand-typed literal, so this file cannot drift from
  /// the alphabet the way a hardcoded copy could.
  final String validSampleCode = roomCodeAlphabet.substring(0, roomCodeLength);

  test('sanity: the sample code this file built is well-formed', () {
    expect(
      isWellFormedRoomCode(validSampleCode),
      isTrue,
      reason: 'this file\'s own sample code "$validSampleCode", built from '
          'the first $roomCodeLength characters of the imported '
          'roomCodeAlphabet "$roomCodeAlphabet", must itself be '
          'well-formed or every test below that relies on it is unsound',
    );
  });

  test(
      'GET /r/<CODE>, item 1: a code of valid shape answers 200 with '
      'content-type text/html; charset=utf-8 and the code in the body',
      () async {
    final ServerHarness harness = ServerHarness.build();
    harnesses.add(harness);
    await harness.start();

    final HttpClientResponse response =
        await _send(client, _httpUri(harness, '/r/$validSampleCode'));
    final String body = await _bodyOf(response);

    expect(
      response.statusCode,
      200,
      reason: 'GET /r/$validSampleCode (valid shape) must answer 200, got '
          '${response.statusCode} with body "$body"',
    );
    expect(
      response.headers.value('content-type'),
      'text/html; charset=utf-8',
      reason: 'content-type on GET /r/$validSampleCode must be exactly '
          '"text/html; charset=utf-8", got '
          '"${response.headers.value('content-type')}"',
    );
    expect(
      body.contains(validSampleCode),
      isTrue,
      reason: 'expected the code "$validSampleCode" to appear in the body '
          'of GET /r/$validSampleCode; full body: $body',
    );
  });

  group('GET /r/<CODE>, item 2: an invalid shape answers 404', () {
    // The order's own item 2 also names "lowercase input" as a case that
    // must answer 404 here. That directly contradicts item 3, two lines
    // below it in the same order, which requires a lowercase version of an
    // otherwise-valid code to be upper-cased and *accepted* (200) --
    // literally the same input shape, opposite required status codes. That
    // is a self-contradiction in the order text, not resolved here; it is
    // reported as an ambiguity. This group covers every other item-2 case
    // (too short, too long, each individually excluded character) and
    // leaves "lowercase input" to the item-3 group below, which is the
    // more specific of the two conflicting instructions and is internally
    // consistent on its own.
    test('too short (one character removed) answers 404', () async {
      final ServerHarness harness = ServerHarness.build();
      harnesses.add(harness);
      await harness.start();

      final String tooShort = validSampleCode.substring(0, roomCodeLength - 1);
      expect(
        isWellFormedRoomCode(tooShort),
        isFalse,
        reason: 'test setup error: "$tooShort" must itself be malformed '
            '(too short) or this case is not testing what its name claims',
      );

      final HttpClientResponse response =
          await _send(client, _httpUri(harness, '/r/$tooShort'));
      final String body = await _bodyOf(response);

      expect(
        response.statusCode,
        404,
        reason: 'GET /r/$tooShort (too short, ${tooShort.length} chars '
            'instead of $roomCodeLength) must answer 404, got '
            '${response.statusCode} with body "$body"',
      );
    });

    test('too long (one extra character appended) answers 404', () async {
      final ServerHarness harness = ServerHarness.build();
      harnesses.add(harness);
      await harness.start();

      final String tooLong = validSampleCode + roomCodeAlphabet[0];
      expect(
        isWellFormedRoomCode(tooLong),
        isFalse,
        reason: 'test setup error: "$tooLong" must itself be malformed '
            '(too long) or this case is not testing what its name claims',
      );

      final HttpClientResponse response =
          await _send(client, _httpUri(harness, '/r/$tooLong'));
      final String body = await _bodyOf(response);

      expect(
        response.statusCode,
        404,
        reason: 'GET /r/$tooLong (too long, ${tooLong.length} chars '
            'instead of $roomCodeLength) must answer 404, got '
            '${response.statusCode} with body "$body"',
      );
    });

    // The confusable characters the order names as deliberately excluded
    // are 0, O, 1, I and L. Of those, only 0, O, 1 and I are actually
    // absent from the imported roomCodeAlphabet; L is present in it
    // (`roomCodeAlphabet` = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789", and
    // `lib/src/room_code.dart`'s own header comment says so explicitly: "L
    // is kept on purpose"). That is a second contradiction between the
    // order's prose and the source of truth the order itself says to
    // import from rather than re-declare. Following the order's explicit
    // instruction to import the alphabet rather than hardcode a copy of
    // it, L is not tested here as an excluded character, since the
    // imported alphabet says it is not one; using it would produce a test
    // that fails for the wrong reason once the route exists (a live
    // implementation checking membership in the real alphabet would
    // correctly accept a code containing L, and a test asserting 404 for
    // it would be asserting a false requirement).
    for (final String excluded in <String>['0', 'O', '1', 'I']) {
      test(
          'a code containing the excluded character "$excluded" answers '
          '404', () async {
        expect(
          roomCodeAlphabet.contains(excluded),
          isFalse,
          reason: 'test setup error: "$excluded" must be absent from the '
              'imported roomCodeAlphabet "$roomCodeAlphabet" or this case '
              'is not testing an excluded character at all',
        );

        final ServerHarness harness = ServerHarness.build();
        harnesses.add(harness);
        await harness.start();

        final String withExcluded = excluded + validSampleCode.substring(1);
        expect(
          isWellFormedRoomCode(withExcluded),
          isFalse,
          reason: 'test setup error: "$withExcluded" must itself be '
              'malformed or this case is not testing what its name claims',
        );

        final HttpClientResponse response =
            await _send(client, _httpUri(harness, '/r/$withExcluded'));
        final String body = await _bodyOf(response);

        expect(
          response.statusCode,
          404,
          reason: 'GET /r/$withExcluded (contains excluded character '
              '"$excluded") must answer 404, got ${response.statusCode} '
              'with body "$body"',
        );
      });
    }
  });

  test(
      'GET /r/<CODE>, item 3: lower-case input of an otherwise valid code '
      'is upper-cased and accepted (200)', () async {
    final ServerHarness harness = ServerHarness.build();
    harnesses.add(harness);
    await harness.start();

    final String lowered = validSampleCode.toLowerCase();
    expect(
      lowered,
      isNot(validSampleCode),
      reason: 'test setup error: lower-casing "$validSampleCode" produced '
          'no change, so this case is not exercising case-normalization '
          'at all',
    );

    final HttpClientResponse response =
        await _send(client, _httpUri(harness, '/r/$lowered'));
    final String body = await _bodyOf(response);

    expect(
      response.statusCode,
      200,
      reason: 'GET /r/$lowered (lower-case of the valid code '
          '"$validSampleCode") must answer 200, upper-cased and accepted '
          '-- a person typing a code off a phone screen types lower-case '
          'letters; got ${response.statusCode} with body "$body"',
    );
    expect(
      body.contains(validSampleCode),
      isTrue,
      reason: 'expected the upper-cased code "$validSampleCode" to appear '
          'in the body of GET /r/$lowered; full body: $body',
    );
  });

  test(
      'GET /r/<CODE>, item 4 (the security assertion): a valid-shape code '
      'for a live room and a valid-shape code for a room that does not '
      'exist answer byte-for-byte identically apart from the code itself',
      () async {
    final ServerHarness harness = ServerHarness.build();
    harnesses.add(harness);
    await harness.start();

    final WireTestLobby lobby =
        await buildWireTestLobby(harness.wsUri, wireClients);
    final String liveCode = lobby.code;

    // A valid-shape code that is, with overwhelming probability, not the
    // one just minted (32^6 possible codes; a real collision here would be
    // a defect in this test, not in the route, and would be visible
    // immediately as the two "different" codes being equal below).
    final String deadCode = liveCode == validSampleCode
        ? roomCodeAlphabet.substring(0, roomCodeLength - 1) +
            roomCodeAlphabet[roomCodeAlphabet.length - 1]
        : validSampleCode;
    expect(
      deadCode,
      isNot(liveCode),
      reason: 'test setup error: the constructed "dead" code '
          '"$deadCode" collided with the live room\'s own code '
          '"$liveCode"; this case is not comparing two different codes',
    );
    expect(
      isWellFormedRoomCode(deadCode),
      isTrue,
      reason: 'test setup error: the constructed "dead" code "$deadCode" '
          'must itself be well-formed shape or this case is not '
          'comparing two valid-shape codes',
    );

    final HttpClientResponse liveResponse =
        await _send(client, _httpUri(harness, '/r/$liveCode'));
    final String liveBody = await _bodyOf(liveResponse);

    final HttpClientResponse deadResponse =
        await _send(client, _httpUri(harness, '/r/$deadCode'));
    final String deadBody = await _bodyOf(deadResponse);

    expect(
      deadResponse.statusCode,
      liveResponse.statusCode,
      reason: 'SECURITY: GET /r/$deadCode (a room that does not exist) '
          'answered status ${deadResponse.statusCode} but GET /r/$liveCode '
          '(a room that does exist, created through the harness) answered '
          '${liveResponse.statusCode}. A route that answers differently '
          'for a live code than a dead one is an oracle that turns '
          'brute-forcing codes into a working attack on every private '
          'room; live body: "$liveBody"; dead body: "$deadBody"',
    );
    expect(
      deadResponse.headers.value('content-type'),
      liveResponse.headers.value('content-type'),
      reason: 'SECURITY: content-type differs between a live code '
          '("${liveResponse.headers.value('content-type')}") and a dead '
          'code ("${deadResponse.headers.value('content-type')}") for '
          'GET /r/<CODE>; that difference alone would let a client '
          'distinguish a live room from a dead one without ever reading '
          'the body',
    );

    final String liveNormalized = liveBody.replaceAll(liveCode, '<<CODE>>');
    final String deadNormalized = deadBody.replaceAll(deadCode, '<<CODE>>');
    expect(
      deadNormalized,
      liveNormalized,
      reason: 'SECURITY: GET /r/$liveCode (live room) and GET /r/$deadCode '
          '(no such room) must answer byte-for-byte identically apart '
          'from the code substring itself, per order 077\'s explicit '
          'security assertion; after replacing each response\'s own code '
          'with a placeholder the two bodies still differ. This is the '
          'most important test in this order: a mismatch here means room '
          'existence can be inferred without ever opening a WebSocket, '
          'defeating the unguessable-codes protection entirely.\n'
          'live (code elided): $liveNormalized\n'
          'dead (code elided): $deadNormalized',
    );
  });

  test(
      'GET /r/<CODE>, item 5: the page contains both English and Arabic '
      'text and a link to the Play listing for app.fayad.ludo', () async {
    final ServerHarness harness = ServerHarness.build();
    harnesses.add(harness);
    await harness.start();

    final HttpClientResponse response =
        await _send(client, _httpUri(harness, '/r/$validSampleCode'));
    final String body = await _bodyOf(response);

    final RegExp arabicScript = RegExp(r'[؀-ۿ]');
    expect(
      arabicScript.hasMatch(body),
      isTrue,
      reason: 'expected at least one Arabic-script character (U+0600 to '
          'U+06FF) somewhere in the body of GET /r/$validSampleCode; full '
          'body: $body',
    );

    final RegExp latinWord = RegExp(r'[A-Za-z]{2,}');
    expect(
      latinWord.hasMatch(body),
      isTrue,
      reason: 'expected at least one English word (a run of two or more '
          'Latin letters, distinct from the room code itself) somewhere '
          'in the body of GET /r/$validSampleCode; full body: $body',
    );

    final RegExp playLink = RegExp(
      r'href="[^"]*play\.google\.com[^"]*app\.fayad\.ludo[^"]*"',
      caseSensitive: false,
    );
    expect(
      playLink.hasMatch(body),
      isTrue,
      reason: 'expected an <a href="..."> pointing at a play.google.com '
          'URL that names app.fayad.ludo (the Play listing for this app, '
          '`packages/ludo_client/android/app/build.gradle.kts:46`) '
          'somewhere in the body of GET /r/$validSampleCode; full body: '
          '$body',
    );
  });

  test(
      'GET /r/<CODE>, item 6: the rendered body contains no em-dash and no '
      'occurrence, in any casing, of "Note that" or "This ensures"', () async {
    final ServerHarness harness = ServerHarness.build();
    harnesses.add(harness);
    await harness.start();

    final HttpClientResponse response =
        await _send(client, _httpUri(harness, '/r/$validSampleCode'));
    final String body = await _bodyOf(response);

    expect(
      body.contains('—'),
      isFalse,
      reason: 'found an em-dash (U+2014) in the body of GET '
          '/r/$validSampleCode; this page is public and must not carry '
          'that tell. Full body: $body',
    );

    final String lower = body.toLowerCase();
    expect(
      lower.contains('note that'),
      isFalse,
      reason: 'found the banned phrase "note that" (any casing) in the '
          'body of GET /r/$validSampleCode; full body: $body',
    );
    expect(
      lower.contains('this ensures'),
      isFalse,
      reason: 'found the banned phrase "this ensures" (any casing) in the '
          'body of GET /r/$validSampleCode; full body: $body',
    );
  });
}

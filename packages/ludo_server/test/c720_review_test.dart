// Proof for the five defects of the review of order 720 (RETURN 1 of
// work/ludo/orders/720-google-sign-in-server.md), against docs/PROTOCOL.md
// section 36.3, 36.3.1 and 36.2.
//
// Verifier cases run in process with a counting fetcher and a FakeClock. The
// directory cases start a real bin/server.dart process with a scrubbed
// environment. The redirect case talks to two in-test loopback servers.
//
// There is no random seed in this file. A failure names its scenario; the
// scenario plus testNow in support/c720_jwt.dart rebuilds every token.
//
// Readings the spec leaves open, taken conservatively:
// - A set "expires" after the default one hour when no Cache-Control comes
//   with it; the tests move the clock 3601 s to expire it.
// - After a failed load the 60 s window is counted from the failed attempt.
// - Only "no second fetch inside 60 s" is asserted after a first load; what
//   happens after 61 s with a known set is not asserted.
// - A directory the process cannot be allowed to change (owned by another
//   user) is tested besides the chmod 500 directory the order names, because
//   a directory owned by the server's own user that is chmod 500 can be set
//   back to 0700 by the server and then holds a probe file legitimately.

import 'dart:async';
import 'dart:io';

import 'package:ludo_server/ludo_server.dart' show FakeClock;
import 'package:ludo_server/src/google_token.dart';
import 'package:test/test.dart';

import 'support/c720_jwt.dart';

const String _clientId = 'c720-review-client.apps.googleusercontent.com';
const String _salt = 'zq7-salt-review-0123456789-abcdefghijklm';

String _describe(TokenCheck check) => switch (check) {
      TokenOk(:final String sub) => 'TokenOk(sub: "$sub")',
      TokenBad() => 'TokenBad',
      TokenUnavailable() => 'TokenUnavailable',
    };

String _tokenAt(FakeClock clock, TestKey key, String sub) => mintToken(
      key: key,
      claims: goodClaims(
        sub: sub,
        nowSeconds: clock.now.millisecondsSinceEpoch ~/ 1000,
      ),
    );

Future<int> _uid() async => int.parse(
    (await Process.run('id', <String>['-u'])).stdout.toString().trim());

void main() {
  group('defect 1: a miss while a fetch is in flight awaits that fetch', () {
    test(
        'two concurrent verifies with a newly rotated kid are both TokenOk '
        'and cost one fetch', () async {
      final FakeClock clock = FakeClock(testNow);
      int calls = 0;
      final Completer<void> secondStarted = Completer<void>();
      final Completer<void> release = Completer<void>();
      Future<JwksResponse> fetch() async {
        calls++;
        if (calls == 1) {
          return JwksResponse(jwkSetJson(<TestKey>[keyA]));
        }
        secondStarted.complete();
        await release.future;
        return JwksResponse(jwkSetJson(<TestKey>[keyA, keyB]));
      }

      final GoogleTokenVerifier verifier = GoogleTokenVerifier(
        clientId: testClientId,
        fetch: fetch,
        clock: clock,
      );
      final TokenCheck warm = await verifier.verify(_tokenAt(clock, keyA, 'w'));
      expect(warm, isA<TokenOk>(),
          reason: 'scenario "rotation warm-up": the first token, kid '
              '${keyA.kid}, must verify; got ${_describe(warm)}');
      // The miss window is 60 s from the load; leave it so the first miss may
      // refetch at once.
      clock.advance(const Duration(seconds: 61));

      final Future<TokenCheck> first =
          verifier.verify(_tokenAt(clock, keyB, 'first'));
      await secondStarted.future.timeout(const Duration(seconds: 10),
          onTimeout: () => throw TestFailure(
              'scenario "rotation": the unknown kid ${keyB.kid} never started '
              'a refetch (fetch calls so far: $calls)'));
      final Future<TokenCheck> second =
          verifier.verify(_tokenAt(clock, keyB, 'second'));
      // Let the second verify reach its key lookup while the fetch is held.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      release.complete();
      final List<TokenCheck> results =
          await Future.wait<TokenCheck>(<Future<TokenCheck>>[first, second]);
      expect(results.map(_describe).toList(),
          <String>['TokenOk(sub: "first")', 'TokenOk(sub: "second")'],
          reason: '36.3.1: a miss while a fetch is in flight must await that '
              'fetch and re-read the set. Scenario: set {${keyA.kid}} loaded, '
              'clock +61 s, then two concurrent verifies of kid ${keyB.kid} '
              'while the set is being fetched with {${keyA.kid}, ${keyB.kid}}.');
      expect(calls, 2,
          reason: '36.3.1: one load plus one refetch for the whole process; '
              'got $calls fetches. Scenario: concurrent rotated kid.');
    });
  });

  group('defect 2: a failed load is not retried for 60 s', () {
    test(
        'expired set, failing fetcher: sequential verifies in 60 s cause one '
        'attempt and the stale key still verifies; after 61 s one more',
        () async {
      final FakeClock clock = FakeClock(testNow);
      final FakeJwks jwks = FakeJwks(jwkSetJson(<TestKey>[keyA]));
      final GoogleTokenVerifier verifier = GoogleTokenVerifier(
        clientId: testClientId,
        fetch: jwks.fetch,
        clock: clock,
      );
      final TokenCheck warm = await verifier.verify(_tokenAt(clock, keyA, 'w'));
      expect(warm, isA<TokenOk>(),
          reason: 'scenario "stale warm-up": got ${_describe(warm)}');
      expect(jwks.calls, 1, reason: 'one load for the warm-up');

      clock.advance(const Duration(seconds: 3601));
      jwks.failure = const SocketException('c720 review: fetch refused');

      final List<String> seen = <String>[];
      for (int i = 0; i < 5; i++) {
        if (i > 0) {
          clock.advance(const Duration(seconds: 10));
        }
        seen.add(
            _describe(await verifier.verify(_tokenAt(clock, keyA, 'v$i'))));
      }
      expect(seen, List<String>.generate(5, (int i) => 'TokenOk(sub: "v$i")'),
          reason: '36.3.1: with the set expired and the fetch failing, the '
              'stale set keeps serving. Scenario: set expired at +3601 s, '
              'fetcher throwing, 5 verifies 10 s apart.');
      expect(jwks.calls, 2,
          reason: '36.3.1: after a failed load no new attempt for 60 s; the '
              'five verifies spanned 40 s and made ${jwks.calls - 1} attempts '
              '(expected 1). Scenario: expired set, failing fetcher.');

      clock.advance(const Duration(seconds: 21));
      final TokenCheck late =
          await verifier.verify(_tokenAt(clock, keyA, 'late'));
      expect(late, isA<TokenOk>(),
          reason: 'the stale key still verifies after 61 s; got '
              '${_describe(late)}');
      expect(jwks.calls, 3,
          reason: 'after 61 s from the failed attempt exactly one more '
              'attempt is due; fetch calls: ${jwks.calls} (expected 3). '
              'Scenario: expired set, failing fetcher, +61 s.');
    });

    test(
        'a first load followed by an unknown kid within 60 s makes no second '
        'fetch', () async {
      final FakeClock clock = FakeClock(testNow);
      final FakeJwks jwks = FakeJwks(jwkSetJson(<TestKey>[keyA]));
      final GoogleTokenVerifier verifier = GoogleTokenVerifier(
        clientId: testClientId,
        fetch: jwks.fetch,
        clock: clock,
      );
      final TokenCheck warm = await verifier.verify(_tokenAt(clock, keyA, 'w'));
      expect(warm, isA<TokenOk>(), reason: 'warm-up: ${_describe(warm)}');
      expect(jwks.calls, 1, reason: 'one load for the warm-up');
      for (final int step in <int>[0, 29, 29]) {
        clock.advance(Duration(seconds: step));
        final TokenCheck result =
            await verifier.verify(_tokenAt(clock, keyB, 'm$step'));
        expect(result, isA<TokenBad>(),
            reason: 'unknown kid ${keyB.kid} not in the set must be '
                'TokenBad; got ${_describe(result)}');
      }
      expect(jwks.calls, 1,
          reason: '36.3.1: the first load counts against the same 60 s clock '
              'as the miss refetch (at most one per 60 s for the process); '
              'fetch calls inside 60 s of the load: ${jwks.calls} (expected '
              '1). Scenario: load, then unknown kid at +0 s, +29 s, +58 s.');
    });
  });

  group('defect 3 and 4: the account directory at start', () {
    late Directory root;
    final List<ServerProcess> running = <ServerProcess>[];

    setUp(() {
      root = Directory.systemTemp.createTempSync('c720-review-');
    });

    tearDown(() async {
      for (final ServerProcess p in running) {
        await p.stop();
      }
      running.clear();
      await Process.run('chmod', <String>['-R', 'u+rwx', root.path]);
      root.deleteSync(recursive: true);
    });

    Map<String, String> signInOn(String dir) => <String, String>{
          'PORT': '0',
          'LUDO_GOOGLE_CLIENT_ID': _clientId,
          'LUDO_ACCOUNT_DIR': dir,
          'LUDO_ACCOUNT_SALT': _salt,
        };

    Future<void> expectRefusedNamingDir(String dir, String scenario) async {
      final ServerProcess process = await ServerProcess.start(signInOn(dir));
      running.add(process);
      final int code = await process.waitForExit();
      expect(code, 64,
          reason: '36.2: any failure preparing the directory stops the server '
              'with exit 64; got $code. Scenario: $scenario. stdout: '
              '${process.stdoutText} stderr: ${process.stderrText}');
      expect(process.stderrText, contains('LUDO_ACCOUNT_DIR'),
          reason: '36.2: the stderr line names LUDO_ACCOUNT_DIR. Scenario: '
              '$scenario. stderr: ${process.stderrText}');
      expect(process.stdoutText, isNot(contains('listening on port')),
          reason: '36.2: the refusal comes before the port opens. Scenario: '
              '$scenario. stdout: ${process.stdoutText}');
    }

    test('an existing 0755 directory is 0700 after start', () async {
      final Directory dir = Directory('${root.path}/existing')..createSync();
      final ProcessResult chmod =
          await Process.run('chmod', <String>['755', dir.path]);
      expect(chmod.exitCode, 0, reason: 'test setup: chmod 755 ${dir.path}');
      expect(FileStat.statSync(dir.path).mode & 0x1ff, 493,
          reason: 'test setup: the directory starts as 0755');
      final ServerProcess process = await ServerProcess.start(
        signInOn(dir.path),
      );
      running.add(process);
      await process.port.timeout(const Duration(seconds: 60),
          onTimeout: () => throw TestFailure(
              'scenario "existing 0755": no port in 60 s. stdout: '
              '${process.stdoutText} stderr: ${process.stderrText}'));
      final int mode = FileStat.statSync(dir.path).mode & 0x1ff;
      expect(mode, 448,
          reason: '36.2: at start the directory is set to 0700 whether new or '
              'existing; got ${mode.toRadixString(8)} octal. Scenario: '
              'LUDO_ACCOUNT_DIR=${dir.path} created 0755 before start.');
    });

    test(
        'a read-only existing directory (chmod 500) stops the server with '
        'exit 64 naming LUDO_ACCOUNT_DIR', () async {
      final int uid = await _uid();
      if (uid == 0) {
        fail('this test cannot run as root: root writes into a chmod 500 '
            'directory, so the refusal cannot be provoked. Run the suite as '
            'an unprivileged user. Not skipped on purpose.');
      }
      final Directory dir = Directory('${root.path}/readonly')..createSync();
      final ProcessResult chmod =
          await Process.run('chmod', <String>['500', dir.path]);
      expect(chmod.exitCode, 0, reason: 'test setup: chmod 500 ${dir.path}');
      await expectRefusedNamingDir(
          dir.path, 'LUDO_ACCOUNT_DIR=${dir.path} existing, mode 0500');
    });

    test(
        'an existing directory owned by another user, which chmod cannot '
        'change, stops the server with exit 64 naming LUDO_ACCOUNT_DIR',
        () async {
      final int uid = await _uid();
      if (uid == 0) {
        fail('this test cannot run as root: root may chmod /usr, so the '
            'failure cannot be provoked and the test must not touch it. Run '
            'the suite as an unprivileged user. Not skipped on purpose.');
      }
      final FileStat stat = FileStat.statSync('/usr');
      expect(stat.type, FileSystemEntityType.directory,
          reason: 'test setup: /usr must be a directory');
      await expectRefusedNamingDir(
          '/usr', 'LUDO_ACCOUNT_DIR=/usr, owned by another user');
    });
  });

  group('defect 5: the key fetch does not follow redirects', () {
    test(
        'a 302 to another local URL fails the fetch and the target is never '
        'requested', () async {
      final HttpServer target =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final HttpServer origin =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final List<String> targetHits = <String>[];
      final List<String> originHits = <String>[];
      final StreamSubscription<HttpRequest> targetSub =
          target.listen((HttpRequest request) async {
        targetHits.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jwkSetJson(<TestKey>[keyA]));
        await request.response.close();
      });
      final Uri targetUrl = Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: target.port,
          path: '/internal/keys');
      final StreamSubscription<HttpRequest> originSub =
          origin.listen((HttpRequest request) async {
        originHits.add(request.uri.path);
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '$targetUrl');
        await request.response.close();
      });
      try {
        final JwksFetcher fetch = httpJwksFetcher(Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: origin.port,
            path: '/certs'));
        Object? outcome;
        try {
          final JwksResponse got = await fetch();
          outcome = 'returned a body of ${got.body.length} characters';
        } on Object catch (error) {
          outcome = error;
        }
        expect(outcome, isA<Exception>(),
            reason: '36.3.1: a redirect is a failed fetch, so the fetcher '
                'must throw; it ${outcome is Exception ? 'threw' : outcome}. '
                'Scenario: origin 127.0.0.1:${origin.port} answers 302 to '
                '$targetUrl.');
        expect(originHits, <String>['/certs'],
            reason: 'the origin is asked exactly once');
        expect(targetHits, isEmpty,
            reason: '36.3.1: the redirect target must never be requested; it '
                'received $targetHits. Scenario: origin 127.0.0.1:'
                '${origin.port} answers 302 to $targetUrl.');
      } finally {
        await targetSub.cancel();
        await originSub.cancel();
        await target.close(force: true);
        await origin.close(force: true);
      }
    });
  });
}

// The email test of docs/PROTOCOL.md section 36.7 (order 720t): a real
// `bin/server.dart` process, its stdout and stderr captured, a token whose
// `email` claim is a unique address and whose `sub` is a unique string. The
// scenario: sign in, sign in again, send three bad tokens carrying the same
// claims, send one refused form POST, delete. After every step, neither
// string may appear in the captured output so far, in any file under the
// account directory, or in any response (status line aside, body and
// headers). After the process is stopped the whole captured output is scanned
// once more, because a log line may arrive late.
//
// The test cannot pass vacuously: it asserts that the first sign-in answered
// 200, that the key host was asked for keys, that an account file exists with
// exactly the three keys, and that the delete removed it.
//
// The key host is an in-test HttpServer on loopback, reached through
// LUDO_GOOGLE_CERTS_URL (36.2 allows http to 127.0.0.1 for exactly this).
// Time is real: the server's clock is the system clock, so tokens carry an
// `iat` of ten seconds ago and an `exp` an hour ahead.
//
// Reproducing a failure: the unique strings are derived from one number, the
// "run id", which every failure message prints. The key pairs are fixed. The
// run id only varies the strings, so any run id reproduces the scenario.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

import 'support/c720_jwt.dart';

const String _salt = 'zq7-salt-leak-0123456789-abcdefghijklmnop';

void main() {
  late HttpServer certs;
  late int certRequests;
  late Directory root;
  ServerProcess? started;
  late HttpClient client;

  setUp(() async {
    certRequests = 0;
    root = Directory.systemTemp.createTempSync('c720-leak-');
    client = HttpClient();
    certs = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    certs.listen((HttpRequest request) {
      certRequests++;
      request.response.headers.set('cache-control', 'public, max-age=3600');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jwkSetJson(<TestKey>[keyA, keyB]));
      unawaited(request.response.close());
    });
  });

  tearDown(() async {
    client.close(force: true);
    await certs.close(force: true);
    await started?.stop();
    await Process.run('chmod', <String>['-R', 'u+rwx', root.path]);
    root.deleteSync(recursive: true);
  });

  test(
      'neither the email nor the sub reaches output, a file or a response '
      'through sign-in, repeat sign-in, three bad tokens, a refused form '
      'POST and a delete', () async {
    final int runId = Random.secure().nextInt(1 << 30);
    final String unique = runId.toRadixString(36);
    final String email = 'leakmail-$unique@leakhost-$unique.example.invalid';
    final String sub = 'leaksub-$unique-0123456789';
    final String name = 'Leak Name';
    final Directory accounts = Directory('${root.path}/accounts');
    final String scenario = 'run id $runId (email $email, sub $sub)';

    final ServerProcess server = await ServerProcess.start(<String, String>{
      'PORT': '0',
      'LUDO_GOOGLE_CLIENT_ID': testClientId,
      'LUDO_ACCOUNT_DIR': accounts.path,
      'LUDO_ACCOUNT_SALT': _salt,
      'LUDO_GOOGLE_CERTS_URL': 'http://127.0.0.1:${certs.port}/certs',
    });
    started = server;
    await server.port.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TestFailure(
          'server did not start. $scenario. stdout: ${server.stdoutText} '
          'stderr: ${server.stderrText}'),
    );

    final List<String> responses = <String>[];

    int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

    String token(
            {Map<String, Object?> overrides = const <String, Object?>{}}) =>
        mintToken(
          claims: goodClaims(
            sub: sub,
            name: name,
            email: email,
            nowSeconds: nowSeconds(),
            overrides: <String, Object?>{
              'iat': nowSeconds() - 10,
              'exp': nowSeconds() + 3600,
              ...overrides,
            },
          ),
        );

    Future<({int status, String body})> send(
      String path,
      String contentType,
      String body, {
      Map<String, String> headers = const <String, String>{},
    }) async {
      final HttpClientRequest request = await client.postUrl(
        await server.uri(path),
      );
      request.headers.set('content-type', contentType);
      headers.forEach(request.headers.set);
      request.write(body);
      final HttpClientResponse response = await request.close();
      final String text = await response.transform(utf8.decoder).join();
      final StringBuffer seen = StringBuffer(text);
      response.headers.forEach((String name, List<String> values) {
        seen.write('\n$name: ${values.join(', ')}');
      });
      responses.add(seen.toString());
      return (status: response.statusCode, body: text);
    }

    Future<({int status, String body})> json(String path, String idToken) =>
        send(path, 'application/json', jsonEncode({'id_token': idToken}));

    final List<String> badTokens = <String>[
      withFlippedSignatureByte(token()),
      token(overrides: {'exp': nowSeconds() - 3600}),
      token(overrides: {'aud': 'someone-elses-client'}),
    ];
    final List<String> tokenPieces = <String>[
      for (final String t in badTokens) ...t.split('.'),
      ...token().split('.').take(2),
    ];

    void scan(String step) {
      final List<String> needles = <String>[
        email,
        'leakmail-$unique',
        'leakhost-$unique',
        sub,
        'leaksub-$unique',
        base64Url.encode(utf8.encode(email)).replaceAll('=', ''),
      ];
      final Map<String, String> haystacks = <String, String>{
        'captured stdout': server.stdoutText,
        'captured stderr': server.stderrText,
        for (int i = 0; i < responses.length; i++)
          'response #${i + 1}': responses[i],
      };
      if (accounts.existsSync()) {
        for (final FileSystemEntity entity
            in accounts.listSync(recursive: true)) {
          haystacks['name of ${entity.path}'] = entity.path;
          if (entity is File) {
            haystacks['content of ${entity.path}'] =
                latin1.decode(entity.readAsBytesSync());
          }
        }
      }
      haystacks.forEach((String where, String text) {
        for (final String needle in needles) {
          expect(text, isNot(contains(needle)),
              reason: '36.1.2 and 36.7: "$needle" must never appear in '
                  '$where. Step: $step. Scenario: $scenario. Text: $text');
        }
      });
      for (final String piece in tokenPieces) {
        for (final String where in <String>[
          'captured stdout',
          'captured stderr',
        ]) {
          final String text = where == 'captured stdout'
              ? server.stdoutText
              : server.stderrText;
          expect(text, isNot(contains(piece)),
              reason: '36.1.2: a token, whole or in part, must not be logged: '
                  '"$piece" found in $where. Step: $step. Scenario: '
                  '$scenario. Text: $text');
        }
        for (int i = 0; i < responses.length; i++) {
          expect(responses[i], isNot(contains(piece)),
              reason: '36.1.2: a token, whole or in part, must not be echoed '
                  'in a response: "$piece" found in response #${i + 1}. '
                  'Step: $step. Scenario: $scenario. Text: ${responses[i]}');
        }
      }
    }

    // Step 1: first sign-in.
    final ({int status, String body}) first =
        await json('/auth/google', token());
    expect(first.status, 200,
        reason: 'the first sign-in must succeed or the test proves nothing. '
            'Scenario: $scenario. Body: ${first.body}. stdout: '
            '${server.stdoutText} stderr: ${server.stderrText}');
    expect(jsonDecode(first.body), <String, Object?>{'name': name},
        reason: 'the sign-in answer carries the display name. Scenario: '
            '$scenario');
    expect(certRequests, greaterThanOrEqualTo(1),
        reason: 'the server must have fetched keys from the in-test key '
            'host, or the token was never really verified. Scenario: '
            '$scenario');
    final List<File> afterFirst =
        accounts.listSync().whereType<File>().toList();
    expect(afterFirst, hasLength(1),
        reason: 'one account file must exist after the first sign-in (this '
            'is what stops the scan below passing vacuously). Scenario: '
            '$scenario. Directory: ${accounts.existsSync() ? accounts.listSync().map((e) => e.path).toList() : 'missing'}');
    final Map<String, Object?> doc =
        jsonDecode(afterFirst.single.readAsStringSync())
            as Map<String, Object?>;
    expect(doc.keys.toSet(), <String>{'name', 'created_ms', 'last_ms'},
        reason: '36.4: exactly three keys. Scenario: $scenario. File: $doc');
    scan('after the first sign-in');

    // Step 2: sign in again.
    final ({int status, String body}) second =
        await json('/auth/google', token());
    expect(second.status, 200,
        reason:
            'the second sign-in. Scenario: $scenario. Body: ${second.body}');
    scan('after the second sign-in');

    // Step 3: three bad tokens carrying the same claims.
    for (int i = 0; i < badTokens.length; i++) {
      final ({int status, String body}) bad =
          await json('/auth/google', badTokens[i]);
      expect(bad.status, 401,
          reason: 'bad token #${i + 1} must be refused with 401. Scenario: '
              '$scenario. Body: ${bad.body}');
      expect(jsonDecode(bad.body), <String, Object?>{'code': 'BAD_TOKEN'},
          reason: 'bad token #${i + 1}: code BAD_TOKEN and nothing else. '
              'Scenario: $scenario');
      scan('after bad token #${i + 1}');
    }

    // Step 4: a form POST that the csrf rule refuses, with a good token.
    final ({int status, String body}) form = await send(
      '/account/delete',
      'application/x-www-form-urlencoded',
      'credential=${Uri.encodeQueryComponent(token())}&g_csrf_token=abc',
    );
    expect(form.status, inInclusiveRange(400, 499),
        reason: 'a form POST without the cookie must be refused. Scenario: '
            '$scenario. Status ${form.status}, body: ${form.body}');
    expect(accounts.listSync().whereType<File>(), hasLength(1),
        reason: 'a refused form POST must not delete. Scenario: $scenario');
    scan('after the refused form POST');

    // Step 5: delete.
    final ({int status, String body}) deleted =
        await json('/account/delete', token());
    expect(deleted.status, 200,
        reason: 'delete. Scenario: $scenario. Body: ${deleted.body}');
    expect(jsonDecode(deleted.body), <String, Object?>{'deleted': true},
        reason: 'delete must report that a file was removed. Scenario: '
            '$scenario. Body: ${deleted.body}');
    expect(accounts.listSync().whereType<File>(), isEmpty,
        reason: 'the account file must be gone. Scenario: $scenario');
    scan('after the delete');

    // Step 6: stop the process and scan everything it ever printed.
    await server.stop();
    scan('after the process stopped, whole captured output');
  }, timeout: const Timeout(Duration(seconds: 180)));
}

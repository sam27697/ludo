// Proof for docs/PROTOCOL.md section 36.2 (order 720t): the start-time rules
// of the four LUDO_* variables, against a real `bin/server.dart` process.
//
// Every process gets an environment built from scratch (support/c720_jwt.dart
// `scrubbedEnvironment`): PATH, HOME, PUB_CACHE if set, and the variables of
// the case. The session environment, which holds live endpoints, is never
// passed down. No case reaches a network: the certs URL, where one is needed,
// points at a loopback port that nothing answers, and no case sends a token.
//
// A refusal is judged by: a non-zero exit, a stderr that names the variable
// and not its value, and no "listening on port" line on stdout (the port must
// not have opened). The wait is on the process exiting; nothing sleeps.
//
// Readings the spec leaves open, taken conservatively:
// - "At least 32 characters" counts characters (Dart runes' worth of text as
//   a person counts them), not UTF-8 bytes; a 16 character Arabic salt of 32
//   bytes is therefore refused.
// - The account directory is created at start, before the port opens.
// - A certs URL is only judged when sign-in is on.
// - Whether `http://[::1]/` is local is read literally: only 127.0.0.1 and
//   localhost are.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/c720_jwt.dart';

const String _clientId = 'c720-start-client.apps.googleusercontent.com';

/// 40 ASCII characters, distinctive enough that its presence in any output is
/// a leak and not a coincidence.
const String _goodSalt = 'zq7-salt-start-0123456789-abcdefghijklmn';

late Directory _root;
final List<ServerProcess> _running = <ServerProcess>[];

String _scenario(Map<String, String> env) => env.entries
    .map((MapEntry<String, String> e) => '${e.key}="${e.value}"')
    .join(' ');

Future<ServerProcess> _start(Map<String, String> env) async {
  final ServerProcess process = await ServerProcess.start(<String, String>{
    'PORT': '0',
    ...env,
  });
  _running.add(process);
  return process;
}

Map<String, String> _signInOn({
  String? dir,
  String? salt,
  String? certs,
  String clientId = _clientId,
}) =>
    <String, String>{
      'LUDO_GOOGLE_CLIENT_ID': clientId,
      'LUDO_ACCOUNT_DIR': dir ?? '${_root.path}/accounts',
      'LUDO_ACCOUNT_SALT': salt ?? _goodSalt,
      if (certs != null) 'LUDO_GOOGLE_CERTS_URL': certs,
    };

/// Starts [env], expects the server to refuse to start, and checks the rules
/// every refusal shares.
Future<void> _expectRefusal(
  Map<String, String> env, {
  required String names,
  List<String> mustNotAppear = const <String>[],
}) async {
  final String scenario = _scenario(env);
  final ServerProcess process = await _start(env);
  final int code = await process.waitForExit();
  expect(code, isNot(0),
      reason: '36.2: the server must stop at start with a non-zero exit. '
          'Scenario: $scenario. stdout: ${process.stdoutText} stderr: '
          '${process.stderrText}');
  expect(process.stdoutText, isNot(contains('listening on port')),
      reason: '36.2: the refusal comes before the port opens. Scenario: '
          '$scenario. stdout: ${process.stdoutText}');
  expect(process.stderrText, contains(names),
      reason: '36.2: the stderr line must name $names. Scenario: $scenario. '
          'stderr: ${process.stderrText}');
  final List<String> lines = process.stderrText
      .split('\n')
      .where((String l) => l.trim().isNotEmpty)
      .toList();
  expect(lines, hasLength(1),
      reason: '36.2: one stderr line, no stack trace. Scenario: $scenario. '
          'stderr: ${process.stderrText}');
  for (final String secret in mustNotAppear) {
    expect(process.allOutput, isNot(contains(secret)),
        reason: '36.2: the line names the variable, never its value; the '
            'value "$secret" appeared. Scenario: $scenario. Output: '
            '${process.allOutput}');
  }
}

Future<Map<String, Object?>> _getJson(
    ServerProcess process, String path) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request =
        await client.getUrl(await process.uri(path));
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200, reason: 'GET $path: $body');
    return jsonDecode(body) as Map<String, Object?>;
  } finally {
    client.close(force: true);
  }
}

Future<void> _expectStarts(
  Map<String, String> env, {
  required Object? expectedClientId,
}) async {
  final String scenario = _scenario(env);
  final ServerProcess process = await _start(env);
  final int port = await process.port.timeout(
    const Duration(seconds: 60),
    onTimeout: () => throw TestFailure(
        'the server did not report a port in 60 s. Scenario: $scenario. '
        'stdout: ${process.stdoutText} stderr: ${process.stderrText}'),
  );
  expect(port, greaterThan(0), reason: 'a listening port. Scenario: $scenario');
  final Map<String, Object?> config = await _getJson(process, '/auth/config');
  expect(config, <String, Object?>{'google_client_id': expectedClientId},
      reason: 'GET /auth/config on a server started with $scenario');
  await process.stop();
  expect(process.allOutput, isNot(contains(_goodSalt)),
      reason: '36.2: the salt is a secret and must never be printed. '
          'Scenario: $scenario. Output: ${process.allOutput}');
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('c720-start-');
  });

  tearDown(() async {
    for (final ServerProcess process in _running) {
      await process.stop();
    }
    _running.clear();
    await Process.run('chmod', <String>['-R', 'u+rwx', _root.path]);
    _root.deleteSync(recursive: true);
  });

  group('sign-in off is a normal state', () {
    test(
        'no LUDO_ variable at all: starts, config is null, the POST routes '
        'answer 503 SIGN_IN_OFF, /health is as ever', () async {
      final ServerProcess process = await _start(<String, String>{});
      await process.port.timeout(const Duration(seconds: 60));
      expect(await _getJson(process, '/auth/config'),
          <String, Object?>{'google_client_id': null},
          reason: '36.2/36.4: with no client id, sign-in is off and the '
              'config says null');
      final Map<String, Object?> health = await _getJson(process, '/health');
      expect(health['status'], 'ok',
          reason: 'the game server plays as today; /health: $health');
      final HttpClient client = HttpClient();
      try {
        for (final String path in <String>['/auth/google', '/account/delete']) {
          final HttpClientRequest request =
              await client.postUrl(await process.uri(path));
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(<String, Object?>{'id_token': 'a.b.c'}));
          final HttpClientResponse response = await request.close();
          final String body = await response.transform(utf8.decoder).join();
          expect(response.statusCode, 503,
              reason: 'POST $path with sign-in off must answer 503; got '
                  '${response.statusCode}: $body');
          expect(jsonDecode(body), <String, Object?>{'code': 'SIGN_IN_OFF'},
              reason: 'POST $path with sign-in off: code SIGN_IN_OFF');
        }
      } finally {
        client.close(force: true);
      }
      await process.stop();
    });

    test(
        'an empty client id is off, even beside an empty directory and a '
        'too short salt', () async {
      await _expectStarts(
        <String, String>{
          'LUDO_GOOGLE_CLIENT_ID': '',
          'LUDO_ACCOUNT_DIR': '',
          'LUDO_ACCOUNT_SALT': 'short',
        },
        expectedClientId: null,
      );
    });

    test('an unset client id is off even with a directory and a salt set',
        () async {
      await _expectStarts(
        <String, String>{
          'LUDO_ACCOUNT_DIR': '${_root.path}/accounts',
          'LUDO_ACCOUNT_SALT': _goodSalt,
        },
        expectedClientId: null,
      );
    });
  });

  group('sign-in on needs a directory and a salt', () {
    test('LUDO_ACCOUNT_DIR empty is refused, naming LUDO_ACCOUNT_DIR',
        () async {
      await _expectRefusal(
        <String, String>{..._signInOn(), 'LUDO_ACCOUNT_DIR': ''},
        names: 'LUDO_ACCOUNT_DIR',
        mustNotAppear: <String>[_goodSalt],
      );
    });

    test('LUDO_ACCOUNT_DIR unset is refused, naming LUDO_ACCOUNT_DIR',
        () async {
      final Map<String, String> env = _signInOn()..remove('LUDO_ACCOUNT_DIR');
      await _expectRefusal(env,
          names: 'LUDO_ACCOUNT_DIR', mustNotAppear: <String>[_goodSalt]);
    });

    test('LUDO_ACCOUNT_SALT unset is refused, naming LUDO_ACCOUNT_SALT',
        () async {
      final Map<String, String> env = _signInOn()..remove('LUDO_ACCOUNT_SALT');
      await _expectRefusal(env, names: 'LUDO_ACCOUNT_SALT');
    });

    test('LUDO_ACCOUNT_SALT empty is refused, naming LUDO_ACCOUNT_SALT',
        () async {
      await _expectRefusal(
        <String, String>{..._signInOn(), 'LUDO_ACCOUNT_SALT': ''},
        names: 'LUDO_ACCOUNT_SALT',
      );
    });

    test(
        'a 31 character salt is refused, naming the variable and not '
        'printing the value', () async {
      const String salt = 'zq7-short-salt-0123456789-abcde';
      expect(salt.length, 31, reason: 'test constant must be 31 characters');
      await _expectRefusal(
        _signInOn(salt: salt),
        names: 'LUDO_ACCOUNT_SALT',
        mustNotAppear: <String>[salt],
      );
    });

    test(
        'a 16 character Arabic salt (32 UTF-8 bytes, 16 characters) is '
        'refused: the rule counts characters', () async {
      const String salt = 'ابتثجحخدذرزسشصضط';
      expect(salt.runes.length, 16,
          reason: 'test constant must be 16 characters');
      await _expectRefusal(
        _signInOn(salt: salt),
        names: 'LUDO_ACCOUNT_SALT',
        mustNotAppear: <String>[salt],
      );
    });

    test('a 32 character salt is accepted (the boundary)', () async {
      const String salt = 'zq7-salt-boundary-0123456789-abc';
      expect(salt.length, 32, reason: 'test constant must be 32 characters');
      await _expectStarts(_signInOn(salt: salt), expectedClientId: _clientId);
    });

    test(
        'with everything set the server starts, reports the id, creates '
        'the directory with mode 0700 and never prints the salt', () async {
      final String dir = '${_root.path}/accounts';
      expect(Directory(dir).existsSync(), isFalse,
          reason: 'precondition: the directory does not exist yet');
      final ServerProcess process = await _start(_signInOn(dir: dir));
      await process.port.timeout(const Duration(seconds: 60));
      expect(await _getJson(process, '/auth/config'),
          <String, Object?>{'google_client_id': _clientId},
          reason: '36.4: the configured client id is served');
      expect(Directory(dir).existsSync(), isTrue,
          reason: '36.2: the account directory is created if missing; '
              'stdout: ${process.stdoutText} stderr: ${process.stderrText}');
      expect(FileStat.statSync(dir).mode & 0x1ff, 448,
          reason: '36.2: the account directory is mode 0700 (448); got '
              '${(FileStat.statSync(dir).mode & 0x1ff).toRadixString(8)} octal');
      await process.stop();
      expect(process.allOutput, isNot(contains(_goodSalt)),
          reason: '36.2: the salt is a secret; output was '
              '${process.allOutput}');
    });

    test('an existing directory is used as it is', () async {
      final Directory dir = Directory('${_root.path}/existing')..createSync();
      await _expectStarts(_signInOn(dir: dir.path),
          expectedClientId: _clientId);
    });
  });

  group('LUDO_GOOGLE_CERTS_URL', () {
    final Map<String, String> refused = <String, String>{
      'plain http to a public host': 'http://example.com/certs',
      'plain http to a public IP': 'http://192.0.2.1/certs',
      'a host that starts with 127.0.0.1':
          'http://127.0.0.1.evil.example/certs',
      'a host that starts with localhost': 'http://localhost.evil.example/c',
      'a local name only in the user part': 'http://127.0.0.1@evil.example/c',
      'a local name only in the path': 'http://evil.example/127.0.0.1/certs',
      'a local name only in the query': 'http://evil.example/c?h=localhost',
      'the IPv6 loopback, which the spec does not list': 'http://[::1]/certs',
      'ftp': 'ftp://127.0.0.1/certs',
      'file': 'file:///etc/passwd',
      'no scheme': 'www.googleapis.com/oauth2/v3/certs',
      'only a scheme': 'https://',
      'a plain word': 'certs',
      'a websocket URL': 'ws://127.0.0.1/certs',
    };
    refused.forEach((String name, String url) {
      test('$name is refused, naming LUDO_GOOGLE_CERTS_URL', () async {
        await _expectRefusal(
          _signInOn(certs: url),
          names: 'LUDO_GOOGLE_CERTS_URL',
          mustNotAppear: <String>[_goodSalt],
        );
      });
    });

    final Map<String, String> accepted = <String, String>{
      'https to any host': 'https://certs.example.invalid/keys',
      'http to 127.0.0.1': 'http://127.0.0.1:1/certs',
      'http to localhost': 'http://localhost:1/certs',
    };
    accepted.forEach((String name, String url) {
      test('$name is accepted at start', () async {
        await _expectStarts(_signInOn(certs: url), expectedClientId: _clientId);
      });
    });
  });
}

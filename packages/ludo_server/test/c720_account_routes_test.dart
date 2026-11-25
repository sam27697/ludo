// Proof for docs/PROTOCOL.md sections 36.1, 36.4 and 36.5 (order 720t),
// written from the spec and the interface block of order 720 only.
//
// Every case runs a real WireServer on a real HttpServer on an ephemeral
// loopback port and speaks plain HTTP to it. The Google keys come from an
// injected fetcher with the fixed test key pairs of support/c720_jwt.dart, and
// time is a FakeClock that the fixture moves by hand: before every POST the
// fixture advances it by seven seconds, so that no case trips the limit of
// ten POSTs per 60 seconds by accident; the cases about that limit turn the
// spacing off. Tokens are minted at the clock's current time with an hour of
// life.
//
// Nothing sleeps. A failing case prints its scenario name, the request, the
// status and the body it got; there is no random seed, every value is fixed.
//
// Readings the spec leaves open, taken conservatively and listed once:
// - The account file is named by the 64 hex digits, with or without a
//   ".json" suffix; both are accepted.
// - A refused form POST (36.5) is any 4xx status with an HTML body that does
//   not say the account was deleted. The spec fixes "an error in words", not
//   the status.
// - Sign-in off with a form POST answers 503, as the JSON routes do.
// - A refused request's own count against the 60 second window is not
//   asserted.
// - Name limit: 40 characters, tested with ASCII only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/c720_jwt.dart';

const String _salt = 'c720-salt-0123456789-abcdefghijklmnop';
const String _jsonType = 'application/json; charset=utf-8';
const String _htmlType = 'text/html; charset=utf-8';
const int _modeMask = 0x1ff;

class _Res {
  _Res(this.status, this.headers, this.bodyBytes)
      : body = utf8.decode(bodyBytes, allowMalformed: true);

  final int status;
  final HttpHeaders headers;
  final List<int> bodyBytes;
  final String body;

  Object? get json => jsonDecode(body);

  String? header(String name) => headers.value(name);
}

class _Fixture {
  _Fixture._(
    this.clock,
    this.server,
    this.store,
    this.dir,
    this.jwks,
    this.printed,
  );

  final FakeClock clock;
  final WireServer server;
  final AccountStore? store;
  final Directory dir;
  final FakeJwks jwks;
  final List<String> printed;
  final HttpClient client = HttpClient();

  static Future<_Fixture> start({
    bool signIn = true,
    Set<String> trustedProxies = const <String>{},
    String? contactEmail,
    Directory? accountDir,
  }) async {
    final FakeClock clock = FakeClock(testNow);
    final Directory root =
        Directory.systemTemp.createTempSync('c720-accounts-');
    final Directory dir = accountDir ?? Directory('${root.path}/accounts')
      ..createSync();
    final FakeJwks jwks = FakeJwks(jwkSetJson(<TestKey>[keyA, keyB]));
    final List<String> printed = <String>[];
    final AccountStore? store =
        signIn ? AccountStore(dir: dir, salt: _salt, clock: clock) : null;
    final GoogleTokenVerifier? verifier = signIn
        ? GoogleTokenVerifier(
            clientId: testClientId,
            fetch: jwks.fetch,
            clock: clock,
          )
        : null;
    late WireServer server;
    await runZoned(
      () async {
        server = WireServer(
          registry: RoomRegistry(clock: clock, secure: Random.secure()),
          rateLimiter: RateLimiter(clock: clock),
          clock: clock,
          trustedProxies: trustedProxies,
          privacyContactEmail: contactEmail,
          googleVerifier: verifier,
          accountStore: store,
          googleClientId: signIn ? testClientId : null,
        );
        await server.start(address: InternetAddress.loopbackIPv4, port: 0);
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
          printed.add(line);
        },
      ),
    );
    return _Fixture._(clock, server, store, dir, jwks, printed);
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close();
    final Directory parent = dir.parent;
    // Restore write access first so the cleanup below can always run.
    await Process.run('chmod', <String>['-R', 'u+rwx', parent.path]);
    parent.deleteSync(recursive: true);
  }

  int get _nowSeconds => clock.now.millisecondsSinceEpoch ~/ 1000;

  /// A token valid now, with a unique email claim the server must never keep.
  String token({
    String sub = 'sub-route-0001',
    String? name = 'Route Player',
    TestKey? key,
    Map<String, Object?> overrides = const <String, Object?>{},
  }) =>
      mintToken(
        key: key,
        claims: goodClaims(
          sub: sub,
          name: name,
          email: 'person-$sub@example.invalid',
          nowSeconds: _nowSeconds,
          overrides: overrides,
        ),
      );

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<_Res> request(
    String method,
    String path, {
    List<int>? body,
    Map<String, String> headers = const <String, String>{},
    bool chunked = false,
    bool space = true,
  }) async {
    if (space && method == 'POST') {
      clock.advance(const Duration(seconds: 7));
    }
    final HttpClientRequest req = await client.openUrl(method, uri(path));
    headers.forEach(req.headers.set);
    if (body != null) {
      if (chunked) {
        req.bufferOutput = false;
        req.headers.chunkedTransferEncoding = true;
      } else {
        req.contentLength = body.length;
      }
      req.add(body);
    }
    final HttpClientResponse res = await req.close();
    final List<int> bytes = await res.fold<List<int>>(
      <int>[],
      (List<int> all, List<int> chunk) => all..addAll(chunk),
    );
    return _Res(res.statusCode, res.headers, bytes);
  }

  Future<_Res> get(String path, {Map<String, String> headers = const {}}) =>
      request('GET', path, headers: headers);

  Future<_Res> postJson(
    String path,
    Object? body, {
    bool space = true,
    Map<String, String> headers = const <String, String>{},
  }) =>
      postRaw(
        path,
        utf8.encode(jsonEncode(body)),
        space: space,
        headers: headers,
      );

  Future<_Res> postRaw(
    String path,
    List<int> bytes, {
    bool space = true,
    bool chunked = false,
    Map<String, String> headers = const <String, String>{},
  }) =>
      request(
        'POST',
        path,
        body: bytes,
        space: space,
        chunked: chunked,
        headers: <String, String>{
          'content-type': 'application/json',
          ...headers,
        },
      );

  Future<_Res> signIn(String token, {bool space = true}) =>
      postJson('/auth/google', <String, Object?>{'id_token': token},
          space: space);

  Future<_Res> deleteJson(String token, {bool space = true}) =>
      postJson('/account/delete', <String, Object?>{'id_token': token},
          space: space);

  Future<_Res> deleteForm({
    String? credential,
    String? csrfField,
    String? csrfCookie,
    String? rawCookie,
    bool space = true,
  }) {
    final List<String> pairs = <String>[
      if (credential != null)
        'credential=${Uri.encodeQueryComponent(credential)}',
      if (csrfField != null)
        'g_csrf_token=${Uri.encodeQueryComponent(csrfField)}',
    ];
    final String? cookie =
        rawCookie ?? (csrfCookie == null ? null : 'g_csrf_token=$csrfCookie');
    return request(
      'POST',
      '/account/delete',
      body: utf8.encode(pairs.join('&')),
      space: space,
      headers: <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        if (cookie != null) 'cookie': cookie,
      },
    );
  }

  List<FileSystemEntity> get entries => dir.listSync();

  String hashOf(String sub) => Hmac(sha256, utf8.encode(_salt))
      .convert(utf8.encode('google:$sub'))
      .toString();

  File? accountFile(String sub) {
    final String hash = hashOf(sub);
    for (final FileSystemEntity entity in entries) {
      final String name = entity.uri.pathSegments.lastWhere(
        (String s) => s.isNotEmpty,
      );
      if ((name == hash || name == '$hash.json') && entity is File) {
        return entity;
      }
    }
    return null;
  }

  Map<String, Object?> accountJson(String sub) {
    final File? file = accountFile(sub);
    if (file == null) {
      fail('no account file for sub "$sub" (hash ${hashOf(sub)}); directory '
          'holds: ${entries.map((FileSystemEntity e) => e.path).toList()}');
    }
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }
}

String _plain(String html) {
  final String blocks =
      html.replaceAll(RegExp(r'</(p|h1|h2|li|div)>|<br\s*/?>'), ' ');
  return blocks
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

void _expectCode(_Res res, int status, String code, String scenario) {
  expect(res.status, status,
      reason: 'scenario "$scenario": expected HTTP $status with code $code; '
          'got ${res.status}, body: ${res.body}');
  expect(res.header('content-type'), _jsonType,
      reason: 'scenario "$scenario": every JSON route answers '
          '"$_jsonType"; got "${res.header('content-type')}"');
  expect(res.json, <String, Object?>{'code': code},
      reason: 'scenario "$scenario": errors are {"code": "$code"} and '
          'nothing else (36.4); got body: ${res.body}');
}

void main() {
  _Fixture? fx;

  tearDown(() async {
    final _Fixture? f = fx;
    fx = null;
    if (f != null) {
      await f.close();
    }
  });

  Future<_Fixture> start({
    bool signIn = true,
    Set<String> trustedProxies = const <String>{},
    String? contactEmail,
  }) async {
    final _Fixture f = await _Fixture.start(
      signIn: signIn,
      trustedProxies: trustedProxies,
      contactEmail: contactEmail,
    );
    fx = f;
    return f;
  }

  group('AccountStore', () {
    late Directory root;
    late FakeClock clock;

    setUp(() {
      root = Directory.systemTemp.createTempSync('c720-store-');
      clock = FakeClock(testNow);
    });

    tearDown(() async {
      await Process.run('chmod', <String>['-R', 'u+rwx', root.path]);
      root.deleteSync(recursive: true);
    });

    AccountStore store({
      String salt = _salt,
    }) =>
        AccountStore(
            dir: Directory('${root.path}/accounts'), salt: salt, clock: clock);

    test(
        'hashOf is HMAC-SHA256 keyed by the salt over "google:" + sub, '
        'lowercase hex (value computed with openssl)', () {
      expect(
        store().hashOf('sub-vector-1'),
        '1543d8dc5d32130a05a1a2c15641a2db256e83bd0256ca534d127bc5283e0006',
        reason: '36.1.3: HMAC-SHA256(key = salt bytes, message = '
            '"google:" + sub); salt "$_salt", sub "sub-vector-1"',
      );
    });

    test('hashOf encodes the sub as UTF-8', () {
      expect(
        store().hashOf('سلام'),
        '98da20defd49b6087b13428807884e8c931d301aa13e546fd49737baa0714abf',
        reason: '36.1.3 with an Arabic sub: the message is the UTF-8 bytes',
      );
    });

    test('hashOf is 64 lowercase hex characters for odd subs', () {
      final AccountStore s = store();
      for (final String sub in <String>[
        'a',
        'a' * 255,
        ' ',
        '../../x',
        'A/b'
      ]) {
        expect(s.hashOf(sub), matches(RegExp(r'^[0-9a-f]{64}$')),
            reason: 'hash of sub "$sub" must be 64 lowercase hex digits');
      }
    });

    test('hashOf differs by sub and by salt, and is stable', () {
      final AccountStore a = store();
      final AccountStore b = store(salt: '${_salt}-other');
      expect(a.hashOf('s1'), a.hashOf('s1'), reason: 'same input, same hash');
      expect(a.hashOf('s1'), isNot(a.hashOf('s2')),
          reason: 'different subs must not collide');
      expect(a.hashOf('s1'), isNot(b.hashOf('s1')),
          reason: 'the salt is the key: a different salt, a different hash');
    });

    test('the hash of a path-like sub is a plain file name, never a path', () {
      final AccountStore s = store();
      s.upsert('../../escape', 'Name');
      final List<FileSystemEntity> found =
          Directory('${root.path}/accounts').listSync();
      expect(found, hasLength(1),
          reason: 'a sub with ../ must still land as one file inside the '
              'account directory; found ${found.map((e) => e.path).toList()}');
      expect(Directory(root.path).listSync().whereType<File>(), isEmpty,
          reason: 'nothing may be written outside the account directory');
    });

    test(
        'upsert creates a missing directory with mode 0700 and the file '
        'with mode 0600', () {
      final AccountStore s = store();
      s.upsert('s1', 'Ann');
      final Directory dir = Directory('${root.path}/accounts');
      expect(dir.existsSync(), isTrue,
          reason: 'the account directory is created if missing (36.2)');
      expect(FileStat.statSync(dir.path).mode & _modeMask, 448,
          reason: 'the account directory must be mode 0700 (448), got '
              '${(FileStat.statSync(dir.path).mode & _modeMask).toRadixString(8)} octal');
      final File file = dir.listSync().whereType<File>().single;
      expect(FileStat.statSync(file.path).mode & _modeMask, 384,
          reason: 'the account file must be mode 0600 (384), got '
              '${(FileStat.statSync(file.path).mode & _modeMask).toRadixString(8)} octal');
    });

    test(
        'upsert writes exactly name, created_ms and last_ms and leaves no '
        'temporary file behind', () {
      final AccountStore s = store();
      s.upsert('s1', 'Ann');
      final List<FileSystemEntity> found =
          Directory('${root.path}/accounts').listSync();
      expect(found, hasLength(1),
          reason: 'one account, one file, no temp file left; got '
              '${found.map((e) => e.path).toList()}');
      final Map<String, Object?> doc =
          jsonDecode((found.single as File).readAsStringSync())
              as Map<String, Object?>;
      expect(doc.keys.toSet(), <String>{'name', 'created_ms', 'last_ms'},
          reason: '36.4: nothing else is in the file; got $doc');
      expect(doc['name'], 'Ann', reason: 'the name as given');
      expect(doc['created_ms'], testNow.millisecondsSinceEpoch,
          reason: 'created_ms is the clock at creation, an int');
      expect(doc['last_ms'], testNow.millisecondsSinceEpoch,
          reason: 'last_ms equals created_ms on creation');
    });

    test(
        'a second upsert keeps created_ms, moves last_ms, takes the new '
        'name', () {
      final AccountStore s = store();
      s.upsert('s1', 'Ann');
      clock.advance(const Duration(minutes: 5));
      s.upsert('s1', 'Anna');
      final Map<String, Object?> doc = jsonDecode(
        Directory('${root.path}/accounts')
            .listSync()
            .whereType<File>()
            .single
            .readAsStringSync(),
      ) as Map<String, Object?>;
      expect(doc['created_ms'], testNow.millisecondsSinceEpoch,
          reason: 'created_ms must survive a second sign-in');
      expect(doc['last_ms'],
          testNow.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
          reason: 'last_ms must move to the second sign-in time');
      expect(doc['name'], 'Anna', reason: 'the name is updated');
    });

    test(
        'delete answers true once, then false, and false for an unknown '
        'sub', () {
      final AccountStore s = store();
      s.upsert('s1', 'Ann');
      expect(s.delete('s2'), isFalse, reason: 'no such account: false');
      expect(s.delete('s1'), isTrue, reason: 'a file was removed: true');
      expect(s.delete('s1'), isFalse, reason: 'already gone: false');
      expect(Directory('${root.path}/accounts').listSync(), isEmpty,
          reason: 'delete must remove the file');
    });

    test('upsert and delete throw when the directory cannot be written', () {
      final AccountStore s = store();
      s.upsert('s1', 'Ann');
      final Directory dir = Directory('${root.path}/accounts');
      Process.runSync('chmod', <String>['500', dir.path]);
      try {
        // Precondition: the permission change must really stop a write here,
        // or the two expectations below prove nothing.
        bool writable = true;
        try {
          File('${dir.path}/probe').writeAsStringSync('x');
        } on FileSystemException {
          writable = false;
        }
        expect(writable, isFalse,
            reason: 'precondition: chmod 500 must make the directory '
                'unwritable for this user (running as root defeats it)');
        expect(() => s.upsert('s2', 'Bob'), throwsA(isA<Exception>()),
            reason: 'upsert must throw on an I/O failure so the route can '
                'answer STORE_FAILED');
        expect(() => s.delete('s1'), throwsA(isA<Exception>()),
            reason: 'delete must throw on an I/O failure so the route can '
                'answer STORE_FAILED');
      } finally {
        Process.runSync('chmod', <String>['700', dir.path]);
      }
    });
  });

  group('GET /auth/config', () {
    test('with sign-in on answers the client id', () async {
      final _Fixture f = await start();
      final _Res res = await f.get('/auth/config');
      expect(res.status, 200, reason: 'GET /auth/config: ${res.body}');
      expect(res.header('content-type'), _jsonType,
          reason: 'content type of /auth/config');
      expect(res.json, <String, Object?>{'google_client_id': testClientId},
          reason: '36.4: the configured client id; got ${res.body}');
    });

    test('with sign-in off answers null', () async {
      final _Fixture f = await start(signIn: false);
      final _Res res = await f.get('/auth/config');
      expect(res.status, 200, reason: 'GET /auth/config off: ${res.body}');
      expect(res.header('content-type'), _jsonType,
          reason: 'content type of /auth/config');
      expect(res.json, <String, Object?>{'google_client_id': null},
          reason: '36.4: null when sign-in is off; got ${res.body}');
    });

    test('is not rate limited by the POST limit', () async {
      final _Fixture f = await start();
      for (int i = 0; i < 25; i++) {
        final _Res res = await f.get('/auth/config');
        expect(res.status, 200,
            reason: 'GET /auth/config request ${i + 1} of 25 in one instant '
                'must answer 200, the limit counts POSTs only; got '
                '${res.status}');
      }
    });

    test('does not disturb /health or /privacy', () async {
      final _Fixture f = await start();
      expect((await f.get('/health')).status, 200,
          reason: '/health must still answer 200 with sign-in on');
      expect((await f.get('/privacy')).status, 200,
          reason: '/privacy must still answer 200 with sign-in on');
    });
  });

  group('sign-in off', () {
    test('POST /auth/google answers 503 SIGN_IN_OFF', () async {
      final _Fixture f = await start(signIn: false);
      _expectCode(await f.signIn(mintToken()), 503, 'SIGN_IN_OFF',
          'POST /auth/google, sign-in off');
    });

    test('POST /account/delete (JSON) answers 503 SIGN_IN_OFF', () async {
      final _Fixture f = await start(signIn: false);
      _expectCode(await f.deleteJson(mintToken()), 503, 'SIGN_IN_OFF',
          'POST /account/delete, sign-in off');
    });

    test('a form POST to /account/delete answers 503 and deletes nothing',
        () async {
      final _Fixture f = await start(signIn: false);
      final _Res res = await f.deleteForm(
          credential: mintToken(), csrfField: 'abc', csrfCookie: 'abc');
      expect(res.status, 503,
          reason: 'form POST with sign-in off must be refused as '
              'SIGN_IN_OFF (503); got ${res.status}: ${res.body}');
      expect(res.body, isNot(contains('Your account is deleted.')),
          reason: 'sign-in off must never claim a deletion');
    });
  });

  group('POST /auth/google', () {
    test('a good token answers 200 {"name"} and creates the file', () async {
      final _Fixture f = await start();
      final _Res res = await f.signIn(f.token(sub: 'sub-a', name: 'Ann'));
      expect(res.status, 200, reason: 'good sign-in: ${res.body}');
      expect(res.header('content-type'), _jsonType,
          reason: 'content type of a successful sign-in');
      expect(res.json, <String, Object?>{'name': 'Ann'},
          reason: '36.4: the 200 answer is {"name": ...} and nothing else; '
              'got ${res.body}');
      expect(f.accountFile('sub-a'), isNotNull,
          reason: 'the account file must be named by the 64 hex digits of '
              '${f.hashOf('sub-a')}; directory holds '
              '${f.entries.map((e) => e.path).toList()}');
    });

    test(
        'the file holds exactly name, created_ms and last_ms, mode 0600, '
        'and no temporary file remains', () async {
      final _Fixture f = await start();
      await f.signIn(f.token(sub: 'sub-a', name: 'Ann'));
      final Map<String, Object?> doc = f.accountJson('sub-a');
      expect(doc.keys.toSet(), <String>{'name', 'created_ms', 'last_ms'},
          reason: '36.1.1 and 36.4: exactly three keys; got $doc');
      expect(doc['name'], 'Ann', reason: 'stored name');
      expect(doc['created_ms'], isA<int>(), reason: 'created_ms is an int');
      expect(doc['last_ms'], isA<int>(), reason: 'last_ms is an int');
      expect(
          FileStat.statSync(f.accountFile('sub-a')!.path).mode & _modeMask, 384,
          reason: 'account file mode must be 0600');
      expect(f.entries, hasLength(1),
          reason: 'one account, one file; a leftover temporary file is a '
              'defect. Directory: ${f.entries.map((e) => e.path).toList()}');
    });

    test(
        'the file and the answer never hold the email, the raw sub, the '
        'token or the picture', () async {
      final _Fixture f = await start();
      final String token = f.token(sub: 'sub-secret-xyz', name: 'Ann');
      final _Res res = await f.signIn(token);
      final String file = f.accountFile('sub-secret-xyz')!.readAsStringSync();
      for (final String needle in <String>[
        'person-sub-secret-xyz',
        'example.invalid',
        'sub-secret-xyz',
        token,
        token.split('.')[1],
        'picture-c720',
        'xx-c720',
        f.hashOf('sub-secret-xyz'),
      ]) {
        expect(file, isNot(contains(needle)),
            reason: '36.1.2: "$needle" must not be in the account file; '
                'file: $file');
        expect(res.body, isNot(contains(needle)),
            reason: '36.1.2/36.1.3: "$needle" must not be in the response; '
                'body: ${res.body}');
      }
    });

    test('a second sign-in keeps created_ms and moves last_ms', () async {
      final _Fixture f = await start();
      final int t0 = f.clock.now.millisecondsSinceEpoch;
      await f.signIn(f.token(sub: 'sub-a'));
      final int firstCreated = f.accountJson('sub-a')['created_ms']! as int;
      final int firstLast = f.accountJson('sub-a')['last_ms']! as int;
      f.clock.advance(const Duration(minutes: 30));
      final _Res res = await f.signIn(f.token(sub: 'sub-a'));
      expect(res.status, 200, reason: 'second sign-in: ${res.body}');
      final Map<String, Object?> doc = f.accountJson('sub-a');
      expect(doc['created_ms'], firstCreated,
          reason: 'created_ms (first $firstCreated, began near $t0) must '
              'not change on a second sign-in; file now $doc');
      expect(doc['last_ms'], greaterThan(firstLast),
          reason: 'last_ms (first $firstLast) must move forward on a second '
              'sign-in; file now $doc');
      expect(doc['last_ms'], f.clock.now.millisecondsSinceEpoch,
          reason: 'last_ms must be the clock at the second sign-in');
      expect(f.entries, hasLength(1),
          reason: 'a second sign-in must not add a second file');
    });

    test('a changed name is updated on the next sign-in', () async {
      final _Fixture f = await start();
      await f.signIn(f.token(sub: 'sub-a', name: 'Ann'));
      final _Res res = await f.signIn(f.token(sub: 'sub-a', name: 'Anna'));
      expect(res.json, <String, Object?>{'name': 'Anna'},
          reason: 'the answer carries the new name; got ${res.body}');
      expect(f.accountJson('sub-a')['name'], 'Anna',
          reason: 'the file carries the new name');
    });

    test(
        'replaying the very same token twice answers 200 both times and '
        'keeps one account', () async {
      final _Fixture f = await start();
      final String token = f.token(sub: 'sub-a');
      expect((await f.signIn(token)).status, 200, reason: 'first use');
      expect((await f.signIn(token)).status, 200,
          reason: 'a replayed token is still a valid token (36.3 has no '
              'single-use rule)');
      expect(f.entries, hasLength(1), reason: 'one account');
    });

    test('a name with spaces around it is trimmed', () async {
      final _Fixture f = await start();
      final _Res res =
          await f.signIn(f.token(sub: 'sub-a', name: '   Ann Lee \t\n'));
      expect(res.json, <String, Object?>{'name': 'Ann Lee'},
          reason: '36.1.1: the name is trimmed; got ${res.body}');
      expect(f.accountJson('sub-a')['name'], 'Ann Lee',
          reason: 'the stored name is trimmed too');
    });

    test('a name of 40 characters is kept whole and of 60 is cut to 40',
        () async {
      final _Fixture f = await start();
      final String forty = 'n' * 40;
      final _Res whole = await f.signIn(f.token(sub: 'sub-a', name: forty));
      expect(whole.json, <String, Object?>{'name': forty},
          reason: '36.1.1: 40 characters is within the limit; got '
              '${whole.body}');
      final _Res cut = await f.signIn(f.token(sub: 'sub-b', name: 'm' * 60));
      expect(cut.json, <String, Object?>{'name': 'm' * 40},
          reason: '36.1.1: at most 40 characters, so 60 become 40; got '
              '${cut.body}');
      expect(f.accountJson('sub-b')['name'], 'm' * 40,
          reason: 'the stored name is cut to 40 as well');
    });

    test('an absent, blank or non-string name answers and stores ""', () async {
      final _Fixture f = await start();
      final List<String?> subs = <String?>['s-abs', 's-blank', 's-num'];
      final List<String?> names = <String?>[null, '   ', null];
      final List<Map<String, Object?>> overrides = <Map<String, Object?>>[
        const <String, Object?>{},
        const <String, Object?>{},
        <String, Object?>{'name': 42},
      ];
      for (int i = 0; i < subs.length; i++) {
        final _Res res = await f.signIn(
            f.token(sub: subs[i]!, name: names[i], overrides: overrides[i]));
        expect(res.status, 200,
            reason: 'a missing or odd name is not a refusal (36.3); '
                'sub ${subs[i]}: ${res.body}');
        expect(res.json, <String, Object?>{'name': ''},
            reason: '36.3: display name "" for sub ${subs[i]}; got '
                '${res.body}');
        expect(f.accountJson(subs[i]!)['name'], '',
            reason: 'stored name "" for sub ${subs[i]}');
      }
    });

    test('a token failing a check answers 401 BAD_TOKEN and writes nothing',
        () async {
      final _Fixture f = await start();
      final Map<String, String> bad = <String, String>{
        'wrong aud': f.token(overrides: {'aud': 'other'}),
        'expired': f.token(overrides: {
          'exp': f.clock.now.millisecondsSinceEpoch ~/ 1000 - 61,
        }),
        'flipped signature': withFlippedSignatureByte(f.token()),
        'alg none': mintToken(header: {'alg': 'none'}, signatureOverride: 'AA'),
        'garbage': 'not.a.token',
        'empty': '',
      };
      for (final MapEntry<String, String> entry in bad.entries) {
        _expectCode(await f.signIn(entry.value), 401, 'BAD_TOKEN',
            'POST /auth/google with ${entry.key}');
      }
      expect(f.entries, isEmpty,
          reason: 'a refused token must not create an account; directory '
              'holds ${f.entries.map((e) => e.path).toList()}');
    });

    test('a bad token is never echoed in the response, in whole or in part',
        () async {
      final _Fixture f = await start();
      final String token =
          withFlippedSignatureByte(f.token(sub: 'sub-echo', name: 'Echo'));
      final _Res res = await f.signIn(token);
      for (final String piece in token.split('.')) {
        expect(res.body, isNot(contains(piece)),
            reason: '36.1.2: a refused token must not be echoed; the '
                'response contained "$piece"; body: ${res.body}');
      }
      expect(res.body, isNot(contains('sub-echo')),
          reason: 'the raw sub must not be echoed');
      expect(res.body, isNot(contains('example.invalid')),
          reason: 'the email must not be echoed');
    });

    test('an unknown kid is 401, a second key published in the set works',
        () async {
      final _Fixture f = await start();
      _expectCode(
          await f.signIn(f.token(sub: 'sub-k').replaceFirst(
              RegExp(r'^[^.]+'),
              b64url(utf8.encode(jsonEncode(
                {'alg': 'RS256', 'kid': 'nope'},
              ))))),
          401,
          'BAD_TOKEN',
          'unknown kid');
      final _Res ok = await f.signIn(f.token(sub: 'sub-k', key: keyB));
      expect(ok.status, 200,
          reason: 'a token signed by the second published key must work; '
              'got ${ok.status}: ${ok.body}');
    });

    test(
        'an id_token of empty string is a token problem (401), not a body '
        'problem', () async {
      final _Fixture f = await start();
      _expectCode(await f.signIn(''), 401, 'BAD_TOKEN',
          'id_token is the empty string (a string, so not BAD_REQUEST)');
    });

    test(
        '503 SIGN_IN_UNAVAILABLE when no key set can be had, for a well '
        'formed token only', () async {
      final _Fixture f = await start();
      f.jwks.failure = const SocketException('c720 keys down');
      _expectCode(await f.signIn(f.token()), 503, 'SIGN_IN_UNAVAILABLE',
          'POST /auth/google, key fetch failing');
      _expectCode(await f.deleteJson(f.token()), 503, 'SIGN_IN_UNAVAILABLE',
          'POST /account/delete, key fetch failing');
      _expectCode(await f.signIn('a.b'), 401, 'BAD_TOKEN',
          'a two part token is refused before any key is needed');
      expect(f.entries, isEmpty, reason: 'nothing may be written');
    });

    test(
        '500 STORE_FAILED when the account file cannot be written, with a '
        'body and a log that name nothing private', () async {
      final _Fixture f = await start();
      Process.runSync('chmod', <String>['500', f.dir.path]);
      final String token = f.token(sub: 'sub-store-fail', name: 'Fail Name');
      final _Res res = await f.signIn(token);
      Process.runSync('chmod', <String>['700', f.dir.path]);
      _expectCode(
          res,
          500,
          'STORE_FAILED',
          'POST /auth/google into a read-only account directory (the '
              'precondition that the write really failed is the 500 itself)');
      final String hash = f.hashOf('sub-store-fail');
      for (final String line in f.printed) {
        for (final String needle in <String>[
          hash,
          'Fail Name',
          'sub-store-fail',
          token,
          token.split('.')[1],
          'example.invalid',
        ]) {
          expect(line, isNot(contains(needle)),
              reason: '36.4: the STORE_FAILED log line names the operation '
                  'and the error class, never the hash, the name or the '
                  'token; printed line: $line');
        }
      }
    });
  });

  group('POST /account/delete (JSON)', () {
    test('removes the file, answers deleted true, then false', () async {
      final _Fixture f = await start();
      await f.signIn(f.token(sub: 'sub-a'));
      expect(f.accountFile('sub-a'), isNotNull, reason: 'setup: signed in');
      final _Res first = await f.deleteJson(f.token(sub: 'sub-a'));
      expect(first.status, 200, reason: 'first delete: ${first.body}');
      expect(first.header('content-type'), _jsonType,
          reason: 'content type of a delete answer');
      expect(first.json, <String, Object?>{'deleted': true},
          reason: '36.4: true when a file was removed; got ${first.body}');
      expect(f.accountFile('sub-a'), isNull,
          reason: 'the file must be gone at once');
      final _Res second = await f.deleteJson(f.token(sub: 'sub-a'));
      expect(second.status, 200, reason: 'second delete: ${second.body}');
      expect(second.json, <String, Object?>{'deleted': false},
          reason: '36.4: false when there was none; got ${second.body}');
    });

    test('for a sub that never signed in answers deleted false', () async {
      final _Fixture f = await start();
      final _Res res = await f.deleteJson(f.token(sub: 'sub-never'));
      expect(res.status, 200, reason: 'delete without account: ${res.body}');
      expect(res.json, <String, Object?>{'deleted': false},
          reason: 'no file, so false; got ${res.body}');
    });

    test('leaves every other account alone', () async {
      final _Fixture f = await start();
      await f.signIn(f.token(sub: 'sub-a'));
      await f.signIn(f.token(sub: 'sub-b'));
      expect(f.entries, hasLength(2), reason: 'setup: two accounts');
      await f.deleteJson(f.token(sub: 'sub-a'));
      expect(f.accountFile('sub-a'), isNull, reason: 'a is gone');
      expect(f.accountFile('sub-b'), isNotNull,
          reason: 'deleting account a must not touch account b');
    });

    test('with a bad token answers 401 and deletes nothing', () async {
      final _Fixture f = await start();
      await f.signIn(f.token(sub: 'sub-a'));
      final String bad = withFlippedSignatureByte(f.token(sub: 'sub-a'));
      _expectCode(await f.deleteJson(bad), 401, 'BAD_TOKEN',
          'delete with a flipped signature');
      _expectCode(
          await f.deleteJson(f.token(sub: 'sub-a', overrides: {'aud': 'x'})),
          401,
          'BAD_TOKEN',
          'delete with a wrong aud');
      expect(f.accountFile('sub-a'), isNotNull,
          reason: 'a refused token must not delete the account');
    });

    test('500 STORE_FAILED when the file cannot be removed', () async {
      final _Fixture f = await start();
      await f.signIn(f.token(sub: 'sub-a'));
      Process.runSync('chmod', <String>['500', f.dir.path]);
      final _Res res = await f.deleteJson(f.token(sub: 'sub-a'));
      Process.runSync('chmod', <String>['700', f.dir.path]);
      _expectCode(res, 500, 'STORE_FAILED',
          'delete from a read-only account directory');
      expect(f.accountFile('sub-a'), isNotNull,
          reason: 'the file is still there after a failed removal');
    });
  });

  group('simultaneous requests', () {
    test(
        'eight simultaneous sign-ins of one account leave one valid file '
        'and no temporary file', () async {
      final _Fixture f = await start();
      f.clock.advance(const Duration(seconds: 7));
      final List<_Res> all = await Future.wait(<Future<_Res>>[
        for (int i = 0; i < 8; i++)
          f.signIn(f.token(sub: 'sub-race', name: 'Racer $i'), space: false),
      ]);
      for (final _Res res in all) {
        expect(res.status, 200,
            reason: 'every simultaneous sign-in must succeed; got '
                '${res.status}: ${res.body}');
      }
      expect(f.entries, hasLength(1),
          reason: 'one account, one file, no leftover temporary file; '
              'directory holds ${f.entries.map((e) => e.path).toList()}');
      final Map<String, Object?> doc = f.accountJson('sub-race');
      expect(doc.keys.toSet(), <String>{'name', 'created_ms', 'last_ms'},
          reason: 'the surviving file must be whole and valid; got $doc');
    });

    test(
        'simultaneous sign-ins and deletes never answer 5xx and leave a '
        'consistent directory', () async {
      final _Fixture f = await start();
      await f.signIn(f.token(sub: 'sub-mix'));
      f.clock.advance(const Duration(seconds: 7));
      final List<_Res> all = await Future.wait(<Future<_Res>>[
        for (int i = 0; i < 4; i++)
          f.signIn(f.token(sub: 'sub-mix'), space: false),
        for (int i = 0; i < 4; i++)
          f.deleteJson(f.token(sub: 'sub-mix'), space: false),
      ]);
      for (final _Res res in all) {
        expect(res.status, 200,
            reason: 'a race between sign-in and delete is not an error; got '
                '${res.status}: ${res.body}');
      }
      expect(f.entries.length, lessThanOrEqualTo(1),
          reason: 'at most the one account file may remain, no temporary '
              'file; directory holds '
              '${f.entries.map((e) => e.path).toList()}');
      if (f.entries.isNotEmpty) {
        expect(f.accountJson('sub-mix').keys.toSet(),
            <String>{'name', 'created_ms', 'last_ms'},
            reason: 'a surviving file must be whole');
      }
    });
  });

  group('400 BAD_REQUEST', () {
    final Map<String, List<int>> badBodies = <String, List<int>>{
      'empty body': <int>[],
      'not JSON': utf8.encode('id_token=abc'),
      'a JSON array': utf8.encode('[]'),
      'a JSON string': utf8.encode('"id_token"'),
      'JSON null': utf8.encode('null'),
      'a JSON number': utf8.encode('7'),
      'an empty object': utf8.encode('{}'),
      'id_token a number': utf8.encode('{"id_token": 5}'),
      'id_token null': utf8.encode('{"id_token": null}'),
      'id_token a list': utf8.encode('{"id_token": ["a.b.c"]}'),
      'id_token an object': utf8.encode('{"id_token": {"a": 1}}'),
      'an unknown key beside id_token':
          utf8.encode('{"id_token": "a.b.c", "extra": 1}'),
      'a differently cased key': utf8.encode('{"ID_TOKEN": "a.b.c"}'),
      'invalid UTF-8': <int>[0x7b, 0x22, 0xff, 0xfe, 0x22, 0x7d],
      'truncated JSON': utf8.encode('{"id_token": "a.b.c"'),
    };
    for (final String route in <String>['/auth/google', '/account/delete']) {
      badBodies.forEach((String name, List<int> body) {
        test('POST $route with $name answers 400 BAD_REQUEST', () async {
          final _Fixture f = await start();
          _expectCode(await f.postRaw(route, body), 400, 'BAD_REQUEST',
              'POST $route, body: $name');
          expect(f.entries, isEmpty,
              reason: 'a malformed request must write nothing');
        });
      });
    }

    test('a good token inside a body with an unknown key is still refused',
        () async {
      final _Fixture f = await start();
      _expectCode(
          await f.postJson('/auth/google',
              <String, Object?>{'id_token': f.token(), 'email': 'a@b.invalid'}),
          400,
          'BAD_REQUEST',
          'valid token plus an unknown key "email"');
      expect(f.entries, isEmpty, reason: 'nothing may be created');
    });
  });

  group('413 TOO_LARGE', () {
    List<int> jsonOfSize(int total) {
      const String head = '{"id_token":"';
      const String tail = '"}';
      return utf8
          .encode('$head${'a' * (total - head.length - tail.length)}$tail');
    }

    for (final String route in <String>['/auth/google', '/account/delete']) {
      test('POST $route with 8193 bytes answers 413 TOO_LARGE', () async {
        final _Fixture f = await start();
        _expectCode(await f.postRaw(route, jsonOfSize(8193)), 413, 'TOO_LARGE',
            'POST $route, 8193 byte JSON');
      });

      test('POST $route with 8192 bytes is read and judged as a token (401)',
          () async {
        final _Fixture f = await start();
        final List<int> body = jsonOfSize(8192);
        expect(body.length, 8192, reason: 'test builder: 8192 bytes');
        _expectCode(await f.postRaw(route, body), 401, 'BAD_TOKEN',
            'POST $route, exactly 8192 byte JSON');
      });

      test(
          'POST $route with 8193 bytes of non-JSON answers 413, not 400: '
          'the size is judged before parsing', () async {
        final _Fixture f = await start();
        _expectCode(await f.postRaw(route, utf8.encode('x' * 8193)), 413,
            'TOO_LARGE', 'POST $route, 8193 bytes of x');
      });

      test(
          'POST $route with a chunked 8193 byte body (no content-length) '
          'answers 413', () async {
        final _Fixture f = await start();
        _expectCode(await f.postRaw(route, jsonOfSize(8193), chunked: true),
            413, 'TOO_LARGE', 'POST $route, chunked 8193 bytes');
      });

      test('POST $route with a 20000 byte body answers 413', () async {
        final _Fixture f = await start();
        _expectCode(await f.postRaw(route, utf8.encode('y' * 20000)), 413,
            'TOO_LARGE', 'POST $route, 20000 bytes');
      });
    }
  });

  group('429 RATE_LIMITED', () {
    test(
        'the 11th POST in 60 seconds from one address is refused, the 10th '
        'is not', () async {
      final _Fixture f = await start();
      for (int i = 1; i <= 10; i++) {
        final _Res res = await f.signIn('a.b.c', space: false);
        expect(res.status, 401,
            reason: 'request $i of 10 at one instant must be judged as a '
                'token (401), not limited; got ${res.status}: ${res.body}');
      }
      _expectCode(await f.signIn('a.b.c', space: false), 429, 'RATE_LIMITED',
          'the 11th POST to /auth/google inside 60 s');
    });

    test(
        '/auth/google, JSON /account/delete and the form POST are counted '
        'together', () async {
      final _Fixture f = await start();
      for (int i = 0; i < 4; i++) {
        await f.signIn('a.b.c', space: false);
      }
      for (int i = 0; i < 3; i++) {
        await f.deleteJson('a.b.c', space: false);
      }
      for (int i = 0; i < 3; i++) {
        await f.deleteForm(
            credential: 'a.b.c', csrfField: 'k', csrfCookie: 'k', space: false);
      }
      _expectCode(
          await f.deleteJson('a.b.c', space: false),
          429,
          'RATE_LIMITED',
          '11th request after 4 sign-ins, 3 JSON deletes, 3 form posts');
      _expectCode(await f.signIn('a.b.c', space: false), 429, 'RATE_LIMITED',
          'the shared count also refuses /auth/google');
    });

    test('a request refused as RATE_LIMITED never reaches the store', () async {
      final _Fixture f = await start();
      for (int i = 0; i < 10; i++) {
        await f.signIn('a.b.c', space: false);
      }
      _expectCode(await f.signIn(f.token(sub: 'sub-limited'), space: false),
          429, 'RATE_LIMITED', 'valid token as the 11th request');
      expect(f.entries, isEmpty,
          reason: 'a limited request must not sign anyone in');
    });

    test('the window slides: after 60 seconds the address is served again',
        () async {
      final _Fixture f = await start();
      for (int i = 0; i < 10; i++) {
        await f.signIn('a.b.c', space: false);
      }
      expect((await f.signIn('a.b.c', space: false)).status, 429,
          reason: 'setup: limited');
      f.clock.advance(const Duration(seconds: 61));
      final _Res res = await f.signIn(f.token(sub: 'sub-after'), space: false);
      expect(res.status, 200,
          reason: '61 s after the burst the window is empty; got '
              '${res.status}: ${res.body}');
    });

    test('behind a trusted proxy each forwarded address has its own limit',
        () async {
      final _Fixture f = await start(trustedProxies: <String>{'127.0.0.1'});
      Map<String, String> from(String ip) =>
          <String, String>{'X-Forwarded-For': ip};
      for (int i = 0; i < 10; i++) {
        await f.postJson('/auth/google', <String, Object?>{'id_token': 'a.b.c'},
            space: false, headers: from('203.0.113.1'));
      }
      _expectCode(
          await f.postJson(
              '/auth/google', <String, Object?>{'id_token': 'a.b.c'},
              space: false, headers: from('203.0.113.1')),
          429,
          'RATE_LIMITED',
          'forwarded 203.0.113.1, 11th request');
      final _Res other = await f.postJson(
          '/auth/google', <String, Object?>{'id_token': 'a.b.c'},
          space: false, headers: from('203.0.113.2'));
      expect(other.status, 401,
          reason: 'a different forwarded address has its own count (section '
              '7 IP, trusted proxies honoured); got ${other.status}: '
              '${other.body}');
    });

    test(
        'without a trusted proxy X-Forwarded-For is never read, so it '
        'cannot dodge the limit', () async {
      final _Fixture f = await start();
      for (int i = 0; i < 10; i++) {
        await f.postJson('/auth/google', <String, Object?>{'id_token': 'a.b.c'},
            space: false,
            headers: <String, String>{'X-Forwarded-For': '198.51.100.$i'});
      }
      _expectCode(
          await f.postJson(
              '/auth/google', <String, Object?>{'id_token': 'a.b.c'},
              space: false,
              headers: <String, String>{'X-Forwarded-For': '198.51.100.99'}),
          429,
          'RATE_LIMITED',
          'forged forwarded addresses from an untrusted peer');
    });
  });

  group('GET /account/delete, sign-in off', () {
    test('serves an HTML page with no script and no Google origin anywhere',
        () async {
      final _Fixture f = await start(signIn: false);
      final _Res res = await f.get('/account/delete');
      expect(res.status, 200, reason: 'GET /account/delete: ${res.body}');
      expect(res.header('content-type'), _htmlType,
          reason: 'content type of the page');
      expect(res.body.toLowerCase(), isNot(contains('<script')),
          reason: '36.5: with sign-in off the page loads no script; body: '
              '${res.body}');
      expect(res.body, isNot(contains('accounts.google.com')),
          reason: '36.5: with sign-in off no Google origin is referenced');
      expect(res.body.toLowerCase(), isNot(contains('g_id_onload')),
          reason: 'no Google button markup with sign-in off');
      final String csp = res.header('content-security-policy') ?? '';
      expect(csp, isNot(contains('google')),
          reason: '36.5: the page widens its CSP only when sign-in is on; '
              'got "$csp"');
    });

    test('the trailing slash form answers the same bytes', () async {
      final _Fixture f = await start(signIn: false);
      final _Res plain = await f.get('/account/delete');
      final _Res slash = await f.get('/account/delete/');
      expect(slash.status, plain.status,
          reason: '36.5: the trailing-slash form is the same page');
      expect(slash.bodyBytes, plain.bodyBytes,
          reason: '36.5: the trailing-slash form is the same page');
    });

    test(
        'says what an account holds, that deletion is final, the 90 day '
        'records and the support address', () async {
      final _Fixture f = await start(
          signIn: false, contactEmail: 'support-c720@example.invalid');
      final String text = _plain((await f.get('/account/delete')).body);
      expect(text, contains('support-c720@example.invalid'),
          reason: '36.5: the support address (PRIVACY_CONTACT_EMAIL) must '
              'be on the page; text: $text');
      expect(text, contains('/v/'),
          reason: '36.5: names the game records at /v/<id>; text: $text');
      expect(text, contains('90 days'),
          reason: '36.5: records are removed after 90 days; text: $text');
      expect(text.toLowerCase(), contains('name'),
          reason: '36.1.1 in plain words: the page says the account holds '
              'a name; text: $text');
    });

    test('is English by default and Arabic, right to left, with ?lang=ar',
        () async {
      final _Fixture f = await start(signIn: false);
      final _Res en = await f.get('/account/delete');
      expect(en.body, contains('<html lang="en">'),
          reason: '36.5: English by default, like the other pages');
      final _Res ar = await f.get('/account/delete?lang=ar');
      expect(ar.status, 200, reason: 'Arabic page: ${ar.body}');
      expect(ar.body, contains('<html lang="ar" dir="rtl">'),
          reason: '36.5: RTL for Arabic; body starts: '
              '${ar.body.substring(0, min(200, ar.body.length))}');
      expect(RegExp(r'[؀-ۿ]').hasMatch(_plain(ar.body)), isTrue,
          reason: 'the Arabic page must contain Arabic text');
      expect(ar.body.toLowerCase(), isNot(contains('<script')),
          reason: 'no script in Arabic either, sign-in being off');
    });

    test('carries no emoji, em-dash, or editorial placeholder', () async {
      final _Fixture f = await start(signIn: false);
      for (final String path in <String>[
        '/account/delete',
        '/account/delete?lang=ar'
      ]) {
        final String body = (await f.get(path)).body;
        expect(body.contains(String.fromCharCode(0x2014)), isFalse,
            reason: '$path must hold no em-dash');
        expect(
            RegExp(r'[\u{1F1E6}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true)
                .hasMatch(body),
            isFalse,
            reason: '$path must hold no emoji');
        expect(RegExp(r'TODO|TBD|FIXME|\[[A-Z ]+\]').hasMatch(body), isFalse,
            reason: '$path must hold no placeholder');
      }
    });
  });

  group('GET /account/delete, sign-in on', () {
    test(
        'has the Google Identity Services script, the client id, redirect '
        'mode and this page as login_uri', () async {
      final _Fixture f = await start();
      final _Res res = await f.get('/account/delete',
          headers: <String, String>{'host': 'ludo.provefair.app'});
      expect(res.status, 200, reason: 'GET /account/delete: ${res.body}');
      expect(res.body, contains('https://accounts.google.com/gsi/client'),
          reason: '36.5: the GIS script is loaded when sign-in is on');
      expect(res.body, contains(testClientId),
          reason: 'the button needs the client id');
      expect(res.body, contains('redirect'),
          reason: '36.5: redirect mode (data-ux_mode="redirect")');
      expect(
          RegExp(r'data-login_uri="https?://ludo\.provefair\.app/account/delete/?"')
              .hasMatch(res.body),
          isTrue,
          reason: '36.5: data-login_uri is this page\'s absolute URL on the '
              'request\'s host; body: ${res.body}');
    });

    test('widens the CSP by the GIS origins on this page only', () async {
      final _Fixture f = await start();
      final String csp =
          (await f.get('/account/delete')).header('content-security-policy') ??
              '';
      expect(csp, isNotEmpty, reason: 'the page must carry a CSP');
      for (final String directive in <String>[
        'script-src',
        'frame-src',
        'connect-src',
        'style-src',
      ]) {
        final String? part = csp
            .split(';')
            .map((String s) => s.trim())
            .where((String s) => s.startsWith('$directive '))
            .map((String s) => s)
            .firstOrNull;
        expect(part, isNotNull,
            reason: '36.5: the CSP must have a $directive directive; got '
                '"$csp"');
        expect(part, contains('https://accounts.google.com/gsi/'),
            reason: '36.5: $directive must allow https://accounts.google.com/'
                'gsi/; got "$part"');
      }
    });

    test('no other page or route has Google in its CSP or body', () async {
      final _Fixture f = await start();
      for (final String path in <String>[
        '/privacy',
        '/privacy?lang=ar',
        '/health',
        '/auth/config',
      ]) {
        final _Res res = await f.get(path);
        expect(res.header('content-security-policy') ?? '',
            isNot(contains('accounts.google.com')),
            reason: '36.5: only the deletion page widens its CSP; $path did');
        expect(res.body, isNot(contains('accounts.google.com/gsi')),
            reason: 'only the deletion page loads GIS; $path did');
      }
    });

    test(
        'the page\'s own CSP differs from the privacy page\'s only by what '
        'it adds', () async {
      final _Fixture on = await start();
      final String privacy =
          (await on.get('/privacy')).header('content-security-policy') ?? '';
      final String page =
          (await on.get('/account/delete')).header('content-security-policy') ??
              '';
      expect(page.length, greaterThan(privacy.length),
          reason: '36.5: widening adds origins, it never removes any. '
              'privacy CSP: "$privacy"; deletion page CSP: "$page"');
      expect(page, contains('default-src'),
          reason: 'the default-src of the other pages must remain: "$page"');
    });
  });

  group('form POST to /account/delete (36.5)', () {
    Future<void> expectRefused(_Res res, String scenario, _Fixture f,
        {String sub = 'sub-form'}) async {
      expect(res.status, inInclusiveRange(400, 499),
          reason: 'scenario "$scenario": the form POST must be refused with '
              'a 4xx status; got ${res.status}: ${res.body}');
      expect(res.header('content-type'), _htmlType,
          reason: 'scenario "$scenario": the answer is a page, not JSON');
      expect(res.body, isNot(contains('Your account is deleted.')),
          reason: 'scenario "$scenario": a refused request must not claim a '
              'deletion');
      expect(f.accountFile(sub), isNotNull,
          reason: 'scenario "$scenario": the account must still exist');
    }

    Future<_Fixture> withAccount() async {
      final _Fixture f = await start();
      await f.signIn(f.token(sub: 'sub-form'));
      expect(f.accountFile('sub-form'), isNotNull, reason: 'setup: account');
      return f;
    }

    test('without the cookie is refused and deletes nothing', () async {
      final _Fixture f = await withAccount();
      await expectRefused(
          await f.deleteForm(
              credential: f.token(sub: 'sub-form'), csrfField: 'tok-1'),
          'no cookie',
          f);
    });

    test('with a mismatched cookie is refused and deletes nothing', () async {
      final _Fixture f = await withAccount();
      await expectRefused(
          await f.deleteForm(
              credential: f.token(sub: 'sub-form'),
              csrfField: 'tok-1',
              csrfCookie: 'tok-2'),
          'cookie differs from field',
          f);
    });

    test('with the field missing is refused and deletes nothing', () async {
      final _Fixture f = await withAccount();
      await expectRefused(
          await f.deleteForm(
              credential: f.token(sub: 'sub-form'), csrfCookie: 'tok-1'),
          'cookie only, no field',
          f);
    });

    test('with both empty is refused (an empty value is not present)',
        () async {
      final _Fixture f = await withAccount();
      await expectRefused(
          await f.deleteForm(
              credential: f.token(sub: 'sub-form'),
              csrfField: '',
              csrfCookie: ''),
          'empty cookie and empty field',
          f);
    });

    test('with a cookie that only prefixes the field is refused', () async {
      final _Fixture f = await withAccount();
      await expectRefused(
          await f.deleteForm(
              credential: f.token(sub: 'sub-form'),
              csrfField: 'tok-1-and-more',
              csrfCookie: 'tok-1'),
          'cookie is a prefix of the field',
          f);
    });

    test('with a differently named cookie is refused', () async {
      final _Fixture f = await withAccount();
      await expectRefused(
          await f.deleteForm(
              credential: f.token(sub: 'sub-form'),
              csrfField: 'tok-1',
              rawCookie: 'g_csrf=tok-1; session=tok-1'),
          'cookie with another name',
          f);
    });

    test('with the credential missing is refused', () async {
      final _Fixture f = await withAccount();
      await expectRefused(
          await f.deleteForm(csrfField: 'tok-1', csrfCookie: 'tok-1'),
          'no credential field',
          f);
    });

    test('with a good csrf pair but a bad token is refused, not echoed',
        () async {
      final _Fixture f = await withAccount();
      final String bad = withFlippedSignatureByte(f.token(sub: 'sub-form'));
      final _Res res = await f.deleteForm(
          credential: bad, csrfField: 'tok-1', csrfCookie: 'tok-1');
      await expectRefused(res, 'good csrf pair, flipped signature', f);
      for (final String piece in bad.split('.')) {
        expect(res.body, isNot(contains(piece)),
            reason: '36.1.2: the refused credential must not be echoed in '
                'the page; found "$piece"');
      }
    });

    test('with a good csrf pair and a token that fails check 5 is refused',
        () async {
      final _Fixture f = await withAccount();
      await expectRefused(
          await f.deleteForm(
              credential: f.token(sub: 'sub-form', overrides: {'aud': 'x'}),
              csrfField: 'tok-1',
              csrfCookie: 'tok-1'),
          'good csrf pair, wrong aud',
          f);
    });

    test('with a good pair deletes the account and says so', () async {
      final _Fixture f = await withAccount();
      final _Res res = await f.deleteForm(
          credential: f.token(sub: 'sub-form'),
          csrfField: 'tok-1',
          csrfCookie: 'tok-1');
      expect(res.status, 200, reason: 'good form POST: ${res.body}');
      expect(res.header('content-type'), _htmlType,
          reason: 'the answer is a page in the same style');
      expect(_plain(res.body), contains('Your account is deleted.'),
          reason: '36.5: the page says "Your account is deleted."; got '
              '${_plain(res.body)}');
      expect(f.accountFile('sub-form'), isNull,
          reason: 'the account file must be gone');
    });

    test('with a good pair and no account says there was none', () async {
      final _Fixture f = await start();
      final _Res res = await f.deleteForm(
          credential: f.token(sub: 'sub-never'),
          csrfField: 'tok-1',
          csrfCookie: 'tok-1');
      expect(res.status, 200,
          reason: 'good form POST, no account: ${res.body}');
      expect(_plain(res.body),
          contains('There was no account for this Google account.'),
          reason: '36.5: the page says "There was no account for this '
              'Google account."; got ${_plain(res.body)}');
      expect(_plain(res.body), isNot(contains('Your account is deleted.')),
          reason: 'must not claim a deletion that did not happen');
    });

    test('the cookie may sit among other cookies', () async {
      final _Fixture f = await withAccount();
      final _Res res = await f.deleteForm(
          credential: f.token(sub: 'sub-form'),
          csrfField: 'tok-1',
          rawCookie: 'a=b; g_csrf_token=tok-1; c=d');
      expect(res.status, 200,
          reason: 'cookie header "a=b; g_csrf_token=tok-1; c=d" carries the '
              'matching cookie; got ${res.status}: ${res.body}');
      expect(f.accountFile('sub-form'), isNull,
          reason: 'the account must be deleted');
    });

    test(
        'a csrf value with + / = characters, percent-encoded in the form '
        'and raw in the cookie, matches', () async {
      final _Fixture f = await withAccount();
      final _Res res = await f.deleteForm(
          credential: f.token(sub: 'sub-form'),
          csrfField: 'Ab+/=z9',
          rawCookie: 'g_csrf_token=Ab+/=z9');
      expect(res.status, 200,
          reason: 'the form field decodes to Ab+/=z9 and the cookie value '
              'is Ab+/=z9 (everything after the first "="); they are '
              'equal, so the request is accepted; got ${res.status}: '
              '${res.body}');
      expect(f.accountFile('sub-form'), isNull,
          reason: 'the account must be deleted');
    });

    test('a JSON delete needs no cookie and no csrf field', () async {
      final _Fixture f = await withAccount();
      final _Res res = await f.deleteJson(f.token(sub: 'sub-form'));
      expect(res.json, <String, Object?>{'deleted': true},
          reason: '36.5: the cookie rule belongs to the form POST only; the '
              'JSON route of 36.4 has none; got ${res.body}');
    });

    test('GET never deletes anything', () async {
      final _Fixture f = await withAccount();
      await f.get(
          '/account/delete?credential=${Uri.encodeQueryComponent(f.token(sub: 'sub-form'))}&g_csrf_token=a',
          headers: <String, String>{'cookie': 'g_csrf_token=a'});
      expect(f.accountFile('sub-form'), isNotNull,
          reason: 'a GET with credentials in the query must not delete');
    });
  });

  group('the privacy page after section 36', () {
    const String en =
        'Signing in with Google is optional. You can play every game '
        'without it. If you sign in, Google sends us your name, your email '
        'address and an account number. We keep your name and a coded form '
        'of the account number that cannot be turned back into it, so the '
        'game knows you next time. We do not keep your email address: the '
        'server discards it at once, and it never reaches a log or a file. '
        'You can delete your account at any time in the app, or at '
        'ludo.provefair.app/account/delete, and it is gone immediately.';
    const String ar =
        'تسجيل الدخول بحساب Google اختياري، وتقدر تلعب كل الألعاب من دونه.';

    test('carries the optional sign-in section in English, word for word',
        () async {
      final _Fixture f = await start();
      final String text = _plain((await f.get('/privacy')).body);
      expect(text, contains(en),
          reason: 'order 720: the English section, exactly these words; '
              'page text: $text');
    });

    test('carries the optional sign-in section in Arabic', () async {
      final _Fixture f = await start();
      final String text = _plain((await f.get('/privacy?lang=ar')).body);
      expect(text, contains(ar),
          reason: 'order 720: the Arabic section opens with these words; '
              'page text: $text');
      expect(text, contains('ludo.provefair.app/account/delete'),
          reason: 'order 720: the Arabic section names the deletion address');
    });

    test('links to /account/delete as a real anchor in both languages',
        () async {
      final _Fixture f = await start();
      for (final String path in <String>['/privacy', '/privacy?lang=ar']) {
        final String body = (await f.get(path)).body;
        expect(
            body,
            matches(
                RegExp(r'<a\s[^>]*href="/account/delete"[^>]*>', dotAll: true)),
            reason: 'order 720: the link is a real anchor element whose href '
                'is exactly /account/delete on $path');
      }
    });

    test('no longer says there is no sign-in or no email address', () async {
      final _Fixture f = await start();
      final String text = _plain((await f.get('/privacy')).body);
      expect(text, isNot(contains('no sign-in')),
          reason: 'the old statement became untrue with section 36; page '
              'text: $text');
      expect(text, isNot(contains('no email address')),
          reason: 'the old statement became untrue with section 36; page '
              'text: $text');
      expect(text, isNot(contains('Because we hold no account')),
          reason: 'the old paragraph became untrue with section 36; page '
              'text: $text');
      expect(text, isNot(contains('We do not collect personal information')),
          reason: 'order 720: whatever else says there is no personal data '
              'must be made true or removed; a signed-in account keeps a '
              'name. Page text: $text');
    });

    test('still says no account is needed to play', () async {
      final _Fixture f = await start();
      final String text = _plain((await f.get('/privacy')).body);
      expect(text.toLowerCase(), contains('without it'),
          reason: 'the optional sign-in text says every game can be played '
              'without signing in');
    });

    test(
        'the text is the same with sign-in off (the page describes the '
        'server\'s policy, not its configuration)', () async {
      final _Fixture f = await start(signIn: false);
      final String text = _plain((await f.get('/privacy')).body);
      expect(text, contains(en),
          reason: 'order 720 gives one text; page text: $text');
    });
  });
}

// Order 720: section 36, written by the implementer as a first line of
// defence. The independent conformance tests are order 720t's.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ludo_server/ludo_server.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

const String _clientId = 'client-123.apps.example';
const String _salt = 'a-test-salt-of-at-least-32-characters-long';

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _b64Int(BigInt v) {
  final List<int> out = <int>[];
  BigInt rest = v;
  while (rest > BigInt.zero) {
    out.insert(0, (rest & BigInt.from(255)).toInt());
    rest >>= 8;
  }
  return _b64(out);
}

class _Keys {
  _Keys(this.pair);
  final AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> pair;

  static _Keys generate() {
    final FortunaRandom random = FortunaRandom();
    final Random seeder = Random.secure();
    random.seed(
      KeyParameter(
        Uint8List.fromList(
          List<int>.generate(32, (int _) => seeder.nextInt(256)),
        ),
      ),
    );
    final RSAKeyGenerator generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
          random,
        ),
      );
    final AsymmetricKeyPair<PublicKey, PrivateKey> pair =
        generator.generateKeyPair();
    return _Keys(
      AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>(
        pair.publicKey as RSAPublicKey,
        pair.privateKey as RSAPrivateKey,
      ),
    );
  }

  String jwks(String kid) => jsonEncode(<String, Object?>{
        'keys': <Object?>[
          <String, Object?>{
            'kty': 'RSA',
            'kid': kid,
            'alg': 'RS256',
            'use': 'sig',
            'n': _b64Int(pair.publicKey.modulus!),
            'e': _b64Int(pair.publicKey.exponent!),
          },
        ],
      });

  String sign(String input) {
    final RSASigner signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(pair.privateKey));
    return _b64(
      signer.generateSignature(Uint8List.fromList(utf8.encode(input))).bytes,
    );
  }
}

late _Keys _keys;

String _token(
  Clock clock, {
  Map<String, Object?> header = const <String, Object?>{},
  Map<String, Object?> payload = const <String, Object?>{},
  List<String> drop = const <String>[],
}) {
  final int now = clock.now.millisecondsSinceEpoch ~/ 1000;
  final Map<String, Object?> h = <String, Object?>{
    'alg': 'RS256',
    'kid': 'k1',
    'typ': 'JWT',
    ...header,
  };
  final Map<String, Object?> p = <String, Object?>{
    'iss': 'https://accounts.google.com',
    'aud': _clientId,
    'sub': 'sub-unique-1',
    'name': '  Ada Lovelace  ',
    'email': 'unique-address-x@example.invalid',
    'iat': now,
    'exp': now + 3600,
    ...payload,
  };
  drop.forEach(p.remove);
  final String signing =
      '${_b64(utf8.encode(jsonEncode(h)))}.${_b64(utf8.encode(jsonEncode(p)))}';
  return '$signing.${_keys.sign(signing)}';
}

void main() {
  late FakeClock clock;
  late Directory dir;
  late int fetches;
  late WireServer server;
  late HttpClient http;
  late String cacheControl;

  Future<void> boot({bool on = true}) async {
    clock = FakeClock(DateTime.utc(2026, 11, 25, 12));
    dir = Directory.systemTemp.createTempSync('s720_');
    fetches = 0;
    cacheControl = 'public, max-age=3600';
    final RoomRegistry registry =
        RoomRegistry(clock: clock, secure: Random.secure());
    server = WireServer(
      registry: registry,
      rateLimiter: RateLimiter(clock: clock),
      clock: clock,
      googleVerifier: on
          ? GoogleTokenVerifier(
              clientId: _clientId,
              clock: clock,
              fetch: () async {
                fetches++;
                return JwksResponse(
                  _keys.jwks('k1'),
                  cacheControl: cacheControl,
                );
              },
            )
          : null,
      accountStore:
          on ? AccountStore(dir: dir, salt: _salt, clock: clock) : null,
      googleClientId: on ? _clientId : null,
    );
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    http = HttpClient();
  }

  Future<(int, String, HttpHeaders)> send(
    String method,
    String path, {
    String? body,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final HttpClientRequest request = await http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    headers.forEach(request.headers.set);
    if (body != null) {
      request.add(utf8.encode(body));
    }
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return (response.statusCode, text, response.headers);
  }

  Future<(int, String, HttpHeaders)> postToken(String path, String token) =>
      send(
        'POST',
        path,
        body: jsonEncode(<String, Object?>{'id_token': token}),
      );

  Future<(int, String, HttpHeaders)> signIn(String token) => send(
        'POST',
        '/auth/google',
        body: jsonEncode(<String, Object?>{'id_token': token}),
      );

  setUpAll(() => _keys = _Keys.generate());

  void tearDownServer() {
    tearDown(() async {
      http.close(force: true);
      await server.close();
      dir.deleteSync(recursive: true);
    });
  }

  group('sign-in on', () {
    setUp(boot);
    tearDownServer();

    test('config names the client id', () async {
      final (int status, String body, HttpHeaders headers) =
          await send('GET', '/auth/config');
      expect(status, 200);
      expect(
          jsonDecode(body), <String, Object?>{'google_client_id': _clientId});
      expect(headers.contentType.toString(), 'application/json; charset=utf-8');
    });

    test(
        'a good token creates one file with three keys; a second keeps created',
        () async {
      final (int status, String body, _) = await signIn(_token(clock));
      expect(status, 200);
      expect(jsonDecode(body), <String, Object?>{'name': 'Ada Lovelace'});
      final List<FileSystemEntity> files = dir.listSync();
      expect(files, hasLength(1));
      final String name = files.single.uri.pathSegments.last;
      expect(name, matches(RegExp(r'^[0-9a-f]{64}$')));
      final AccountStore probe =
          AccountStore(dir: dir, salt: _salt, clock: clock);
      expect(name, probe.hashOf('sub-unique-1'));
      final Map<String, Object?> first = jsonDecode(
        File(files.single.path).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(first.keys.toSet(), <String>{'name', 'created_ms', 'last_ms'});
      expect(first['created_ms'], first['last_ms']);
      expect(
        (files.single.statSync().mode & 511).toRadixString(8),
        '600',
      );

      clock.advance(const Duration(minutes: 5));
      await signIn(_token(clock));
      final Map<String, Object?> second = jsonDecode(
        File(files.single.path).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(second['created_ms'], first['created_ms']);
      expect(second['last_ms'], isNot(first['last_ms']));
      expect(dir.listSync(), hasLength(1));
    });

    test('delete removes the file, a second delete says false', () async {
      await signIn(_token(clock));
      final (int s1, String b1, _) =
          await postToken('/account/delete', _token(clock));
      expect(s1, 200);
      expect(jsonDecode(b1), <String, Object?>{'deleted': true});
      expect(dir.listSync(), isEmpty);
      final (int _, String b2, _) =
          await postToken('/account/delete', _token(clock));
      expect(jsonDecode(b2), <String, Object?>{'deleted': false});
    });

    final Map<String, String Function()> bad = <String, String Function()>{
      'alg none': () => _token(clock, header: {'alg': 'none'}),
      'alg HS256': () => _token(clock, header: {'alg': 'HS256'}),
      'unknown kid': () => _token(clock, header: {'kid': 'other'}),
      'kid not a string': () => _token(clock, header: {'kid': 5}),
      'wrong iss': () => _token(clock, payload: {'iss': 'evil.example'}),
      'list aud': () => _token(clock, payload: {
            'aud': [_clientId]
          }),
      'wrong aud': () => _token(clock, payload: {'aud': 'someone-else'}),
      'expired past skew': () => _token(clock, payload: {
            'exp': clock.now.millisecondsSinceEpoch ~/ 1000 - 61,
          }),
      'iat in future': () => _token(clock, payload: {
            'iat': clock.now.millisecondsSinceEpoch ~/ 1000 + 61,
          }),
      'missing sub': () => _token(clock, drop: ['sub']),
      'empty sub': () => _token(clock, payload: {'sub': ''}),
      'two parts': () => 'aaa.bbb',
      'four parts': () => 'a.b.c.d',
      'oversize': () => 'a' * 4097,
    };
    for (final MapEntry<String, String Function()> entry in bad.entries) {
      test('refuses ${entry.key}', () async {
        final (int status, String body, _) = await signIn(entry.value());
        expect(status, 401);
        expect(jsonDecode(body), <String, Object?>{'code': 'BAD_TOKEN'});
        expect(dir.listSync(), isEmpty);
      });
    }

    test('refuses a flipped signature byte', () async {
      final List<String> parts = _token(clock).split('.');
      final List<int> sig = base64Url.decode(base64Url.normalize(parts[2]));
      sig[10] ^= 1;
      final (int status, _, _) =
          await signIn('${parts[0]}.${parts[1]}.${_b64(sig)}');
      expect(status, 401);
    });

    test('skew edges are accepted', () async {
      final int now = clock.now.millisecondsSinceEpoch ~/ 1000;
      final (int status, _, _) = await signIn(
        _token(clock, payload: {'exp': now - 59, 'iat': now + 59}),
      );
      expect(status, 200);
    });

    test('name is optional and capped at 40', () async {
      final (_, String none, _) = await signIn(_token(clock, drop: ['name']));
      expect(jsonDecode(none), <String, Object?>{'name': ''});
      final (_, String long, _) =
          await signIn(_token(clock, payload: {'name': 'x' * 60}));
      expect(jsonDecode(long), <String, Object?>{'name': 'x' * 40});
    });

    test('key set: one refetch per 60 s for an unknown kid, max-age honoured',
        () async {
      await signIn(_token(clock));
      expect(fetches, 1);
      await signIn(_token(clock));
      expect(fetches, 1);
      // The first load counts against the same 60 s clock: no refetch yet.
      await signIn(_token(clock, header: {'kid': 'zzz'}));
      expect(fetches, 1);
      clock.advance(const Duration(seconds: 61));
      await signIn(_token(clock, header: {'kid': 'zzz'}));
      expect(fetches, 2);
      await signIn(_token(clock, header: {'kid': 'zzz'}));
      expect(fetches, 2);
      clock.advance(const Duration(seconds: 61));
      await signIn(_token(clock, header: {'kid': 'zzz'}));
      expect(fetches, 3);
      clock.advance(const Duration(hours: 1, seconds: 1));
      await signIn(_token(clock));
      expect(fetches, 4);
    });

    test('400 cases and 413', () async {
      for (final String body in <String>[
        '[]',
        'nope',
        '{}',
        '{"id_token":5}',
        '{"id_token":"x","extra":1}',
      ]) {
        final (int status, String text, _) =
            await send('POST', '/auth/google', body: body);
        expect(status, 400, reason: body);
        expect(jsonDecode(text), <String, Object?>{'code': 'BAD_REQUEST'});
      }
      final (int status, String text, _) = await send(
        'POST',
        '/auth/google',
        body: '{"id_token":"${'a' * 8200}"}',
      );
      expect(status, 413);
      expect(jsonDecode(text), <String, Object?>{'code': 'TOO_LARGE'});
    });

    test('429 on the eleventh POST in 60 s, counted across both routes',
        () async {
      for (int i = 0; i < 5; i++) {
        await send('POST', '/auth/google', body: '{}');
        await send('POST', '/account/delete', body: '{}');
      }
      final (int status, String text, _) =
          await send('POST', '/auth/google', body: '{}');
      expect(status, 429);
      expect(jsonDecode(text), <String, Object?>{'code': 'RATE_LIMITED'});
      clock.advance(const Duration(seconds: 61));
      final (int again, _, _) = await send('POST', '/auth/google', body: '{}');
      expect(again, 400);
    });

    test('form POST needs a cookie equal to the field', () async {
      await signIn(_token(clock));
      const Map<String, String> form = <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
      };
      final String body = 'credential=${_token(clock)}&g_csrf_token=abc';
      final (int none, _, _) =
          await send('POST', '/account/delete', body: body, headers: form);
      expect(none, 400);
      final (int mismatch, _, _) = await send(
        'POST',
        '/account/delete',
        body: body,
        headers: <String, String>{...form, 'cookie': 'g_csrf_token=other'},
      );
      expect(mismatch, 400);
      expect(dir.listSync(), hasLength(1));
      final (int good, String page, HttpHeaders headers) = await send(
        'POST',
        '/account/delete',
        body: body,
        headers: <String, String>{
          ...form,
          'cookie': 'x=1; g_csrf_token=abc',
        },
      );
      expect(good, 200);
      expect(page, contains('Your account is deleted.'));
      expect(
        headers.value('content-security-policy'),
        isNot(contains('google')),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('the page carries the button and a widened policy', () async {
      final (int status, String page, HttpHeaders headers) =
          await send('GET', '/account/delete');
      expect(status, 200);
      expect(page, contains('accounts.google.com/gsi/client'));
      expect(page, contains('data-ux_mode="redirect"'));
      expect(
        page,
        contains(
          'data-login_uri="http://127.0.0.1:${server.port}/account/delete"',
        ),
      );
      expect(
        headers.value('content-security-policy'),
        contains('https://accounts.google.com/gsi/'),
      );
    });
  });

  group('sign-in off', () {
    setUp(() => boot(on: false));
    tearDownServer();

    test('config null, routes answer SIGN_IN_OFF, page has no script',
        () async {
      final (_, String config, _) = await send('GET', '/auth/config');
      expect(jsonDecode(config), <String, Object?>{'google_client_id': null});
      final (int status, String text, _) =
          await send('POST', '/auth/google', body: '{"id_token":"x"}');
      expect(status, 503);
      expect(jsonDecode(text), <String, Object?>{'code': 'SIGN_IN_OFF'});
      final (int d, _, _) =
          await send('POST', '/account/delete', body: '{"id_token":"x"}');
      expect(d, 503);
      final (_, String page, HttpHeaders headers) =
          await send('GET', '/account/delete/');
      expect(page, isNot(contains('<script')));
      expect(page, isNot(contains('google')));
      expect(
        headers.value('content-security-policy'),
        "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; "
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      );
    });
  });

  test('the key set URL rule of 36.2', () {
    expect(parseCertsUrl(null).toString(), googleCertsUrl);
    expect(parseCertsUrl('').toString(), googleCertsUrl);
    expect(parseCertsUrl('https://example.com/c').host, 'example.com');
    expect(parseCertsUrl('http://127.0.0.1:9/c').port, 9);
    expect(parseCertsUrl('http://localhost/c').host, 'localhost');
    for (final String bad in <String>[
      'http://example.com/c',
      'ftp://example.com',
      'file:///etc/passwd',
      'nonsense',
      'http://127.0.0.1.evil.example/c',
    ]) {
      expect(() => parseCertsUrl(bad), throwsFormatException, reason: bad);
    }
  });
}

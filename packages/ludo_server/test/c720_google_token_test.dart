// Proof for docs/PROTOCOL.md section 36.3 and 36.3.1 (order 720t), written
// from the spec and the interface block of order 720 only.
//
// Every check of 36.3 is refused on its own: the token is valid in every
// other respect, so the one fault is the only reason it can be refused. Keys
// are two fixed test key pairs (support/c720_jwt.dart), the key fetcher is
// injected and counts its calls, and time is a FakeClock. Nothing touches the
// network except the two cases that talk to an in-test HttpServer on loopback.
//
// There is no random seed in this file. A failure names its scenario; the
// scenario plus testNow in support/c720_jwt.dart rebuilds the exact token.
//
// Readings the spec leaves open, all taken conservatively:
// - "exp greater than now minus 60 s" is strict: exp == now - 60 is refused.
//   "iat less than now plus 60 s" is strict: iat == now + 60 is refused.
// - The initial fetch of the key set is lazy (the verifier has no start
//   method) and is not asserted to count against the 60 s refetch limit
//   except where a case says so.
// - An unknown kid on a verifier with no cached set at all may cost one or two
//   fetches; only "at most two" is asserted.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ludo_server/ludo_server.dart' show FakeClock;
import 'package:ludo_server/src/google_token.dart';
import 'package:test/test.dart';

import 'support/c720_jwt.dart';

({GoogleTokenVerifier verifier, FakeJwks jwks, FakeClock clock}) _build({
  List<TestKey>? keys,
  String? cacheControl,
}) {
  final FakeClock clock = FakeClock(testNow);
  final FakeJwks jwks = FakeJwks(
    jwkSetJson(keys ?? <TestKey>[keyA]),
    cacheControl: cacheControl,
  );
  final GoogleTokenVerifier verifier = GoogleTokenVerifier(
    clientId: testClientId,
    fetch: jwks.fetch,
    clock: clock,
  );
  return (verifier: verifier, jwks: jwks, clock: clock);
}

Map<String, Object?> _claimsAt(FakeClock clock, {String sub = 's-1'}) =>
    goodClaims(
      sub: sub,
      nowSeconds: clock.now.millisecondsSinceEpoch ~/ 1000,
    );

String _describe(TokenCheck check) => switch (check) {
      TokenOk(:final String sub, :final String name) =>
        'TokenOk(sub: "$sub", name: "$name")',
      TokenBad() => 'TokenBad',
      TokenUnavailable() => 'TokenUnavailable',
    };

Future<void> _expectBad(
  String scenario,
  String token, {
  GoogleTokenVerifier? verifier,
}) async {
  final GoogleTokenVerifier v = verifier ?? _build().verifier;
  final TokenCheck result = await v.verify(token);
  expect(
    result,
    isA<TokenBad>(),
    reason: 'scenario "$scenario": a token that fails one check of 36.3 must '
        'be refused as BAD_TOKEN (TokenBad); got ${_describe(result)}. Token '
        'length ${token.length}.',
  );
}

Future<TokenOk> _expectOk(
  String scenario,
  String token, {
  GoogleTokenVerifier? verifier,
}) async {
  final GoogleTokenVerifier v = verifier ?? _build().verifier;
  final TokenCheck result = await v.verify(token);
  expect(
    result,
    isA<TokenOk>(),
    reason: 'scenario "$scenario": a token that passes every check of 36.3 '
        'must be accepted (TokenOk); got ${_describe(result)}. Token length '
        '${token.length}.',
  );
  return result as TokenOk;
}

void main() {
  group('a good token', () {
    test('is accepted and yields its sub and its name', () async {
      final TokenOk ok = await _expectOk(
        'baseline',
        mintToken(claims: goodClaims(sub: 'sub-baseline', name: 'Ann')),
      );
      expect(ok.sub, 'sub-baseline',
          reason: 'TokenOk.sub must carry the sub claim for the store');
      expect(ok.name, 'Ann', reason: 'TokenOk.name must carry the name claim');
    });

    test('with the plain iss accounts.google.com is accepted', () async {
      await _expectOk(
        'iss without scheme',
        mintToken(
            claims: goodClaims(overrides: {'iss': 'accounts.google.com'})),
      );
    });

    test('with exp and iat as JSON doubles is accepted (a number is a number)',
        () async {
      await _expectOk(
        'double exp and iat',
        mintToken(
          claims: goodClaims(overrides: {
            'exp': (testNowSeconds + 3600).toDouble(),
            'iat': (testNowSeconds - 5).toDouble(),
          }),
        ),
      );
    });

    test('carrying extra claims (email, picture, locale) is accepted',
        () async {
      await _expectOk(
        'extra claims',
        mintToken(
          claims: goodClaims(overrides: {
            'hd': 'example.invalid',
            'nonce': 'n-1',
            'unknown_future_claim': <Object?>[1, 2, 3],
          }),
        ),
      );
    });

    test('of exactly 4096 bytes is accepted (the boundary of check 1)',
        () async {
      final String token = tokenOfLength(4096);
      expect(token.length, 4096, reason: 'test helper must build 4096 bytes');
      await _expectOk('4096 byte token', token);
    });
  });

  group('check 1: size and shape', () {
    test('a token of 4097 bytes with a genuine signature is refused', () async {
      final String token = tokenOfLength(4097);
      expect(token.length, 4097, reason: 'test helper must build 4097 bytes');
      await _expectBad('4097 byte token, otherwise valid', token);
    });

    test('a token of 100000 bytes is refused', () async {
      await _expectBad(
          '100000 byte token', 'a' * 50000 + '.' + 'b' * 49998 + '.c');
    });

    final Map<String, String> shapes = <String, String>{
      'empty string': '',
      'one part': 'abc',
      'two parts': 'abc.def',
      'four parts': 'abc.def.ghi.jkl',
      'empty first part': '.def.ghi',
      'empty middle part': 'abc..ghi',
      'empty signature part': 'abc.def.',
      'only dots': '..',
      'three dots': '...',
      'whitespace only': '   ',
    };
    shapes.forEach((String name, String token) {
      test('$name is refused', () async {
        await _expectBad('shape: $name', token);
      });
    });

    test('a valid token with a fourth empty part is refused', () async {
      await _expectBad('valid token plus trailing dot', '${mintToken()}.');
    });

    test('a valid token with leading or trailing whitespace is refused',
        () async {
      await _expectBad('leading space', ' ${mintToken()}');
      await _expectBad('trailing newline', '${mintToken()}\n');
    });
  });

  group('check 2: the header', () {
    test('alg none with a non-empty signature part is refused', () async {
      await _expectBad(
        'alg none',
        mintToken(header: {'alg': 'none'}, signatureOverride: 'AAAA'),
      );
    });

    test('alg none, correctly signed by the real key, is refused', () async {
      await _expectBad('alg none, genuine RS256 signature',
          mintToken(header: {'alg': 'none'}));
    });

    test('alg HS256 keyed with the public modulus is refused', () async {
      await _expectBad(
        'alg HS256 confusion',
        hs256Token(utf8.encode(jwkSetJson(<TestKey>[keyA]))),
      );
      await _expectBad(
        'alg HS256, HMAC keyed with the modulus text',
        hs256Token(utf8.encode(keyA.jwk['n']! as String)),
      );
    });

    test('alg HS256 on an otherwise genuine RS256 signature is refused',
        () async {
      await _expectBad('alg HS256 label', mintToken(header: {'alg': 'HS256'}));
    });

    final Map<String, Object?> badAlgs = <String, Object?>{
      'rs256 lower case': 'rs256',
      'RS384': 'RS384',
      'RS512': 'RS512',
      'ES256': 'ES256',
      'RS256 with trailing space': 'RS256 ',
      'a number': 256,
      'null': null,
      'a list': <Object?>['RS256'],
    };
    badAlgs.forEach((String name, Object? alg) {
      test('alg $name is refused', () async {
        await _expectBad('alg: $name', mintToken(header: {'alg': alg}));
      });
    });

    test('a missing alg is refused', () async {
      await _expectBad('no alg', mintToken(header: {'alg': absent}));
    });

    test('a missing kid is refused', () async {
      await _expectBad('no kid', mintToken(header: {'kid': absent}));
    });

    test('a kid that is not a string is refused', () async {
      await _expectBad('numeric kid', mintToken(header: {'kid': 1}));
      await _expectBad('null kid', mintToken(header: {'kid': null}));
      await _expectBad(
          'list kid',
          mintToken(header: {
            'kid': [keyA.kid]
          }));
    });

    test('a header that is not JSON is refused', () async {
      final String body = b64url(utf8.encode(jsonEncode(goodClaims())));
      await _expectBad('header is plain text',
          rawToken([b64url(utf8.encode('not json')), body, 'AAAA']));
    });

    test('a header that is a JSON array, string or number is refused',
        () async {
      final String body = b64url(utf8.encode(jsonEncode(goodClaims())));
      for (final String text in <String>['[]', '"RS256"', '42', 'null']) {
        await _expectBad('header is $text',
            rawToken([b64url(utf8.encode(text)), body, 'AAAA']));
      }
    });

    test('a header that is not valid base64url is refused', () async {
      await _expectBad('header with ! characters',
          rawToken(['!!!!', b64url(utf8.encode('{}')), 'AAAA']));
    });
  });

  group('check 3: key and signature', () {
    test('an unknown kid is refused', () async {
      await _expectBad(
        'kid not in the set',
        mintToken(header: {'kid': 'c720-no-such-key'}),
      );
    });

    test('a kid that differs from a real one only in case is refused',
        () async {
      await _expectBad(
          'kid upper cased', mintToken(header: {'kid': 'C720-KEY-A'}));
    });

    test('a flipped signature byte is refused', () async {
      await _expectBad('signature byte 10 flipped',
          withFlippedSignatureByte(mintToken(), index: 10));
      await _expectBad('first signature byte flipped',
          withFlippedSignatureByte(mintToken(), index: 0));
      await _expectBad('last signature byte flipped',
          withFlippedSignatureByte(mintToken(), index: 255));
    });

    test('a signature made by another key under the right kid is refused',
        () async {
      await _expectBad(
        'signed by key B, header names key A',
        mintToken(key: keyA, signingKey: keyB),
      );
    });

    test('a payload changed after signing is refused', () async {
      final List<String> parts = mintToken(
        claims: goodClaims(sub: 'original-sub'),
      ).split('.');
      final String otherPayload = b64url(utf8.encode(
        jsonEncode(goodClaims(sub: 'tampered-sub')),
      ));
      await _expectBad(
        'payload swapped, signature kept',
        '${parts[0]}.$otherPayload.${parts[2]}',
      );
    });

    test('a header changed after signing is refused', () async {
      final List<String> parts = mintToken().split('.');
      final String otherHeader = b64url(utf8.encode(jsonEncode(
        <String, Object?>{'alg': 'RS256', 'kid': keyA.kid, 'typ': 'JWT '},
      )));
      await _expectBad(
        'header swapped, signature kept',
        '$otherHeader.${parts[1]}.${parts[2]}',
      );
    });

    test(
        'a signature that is too short, empty of meaning or not base64url '
        'is refused', () async {
      await _expectBad(
          'signature "AAAA"', mintToken(signatureOverride: 'AAAA'));
      await _expectBad(
          'signature with ! characters', mintToken(signatureOverride: '!!!!'));
    });

    test(
        'a token signed by a key that is not in the set is refused even '
        'under a kid that is', () async {
      await _expectBad(
        'key B signature, kid of key A, set holds only A',
        mintToken(key: keyB, header: {'kid': keyA.kid}),
      );
    });
  });

  group('check 4: iss', () {
    final Map<String, Object?> badIss = <String, Object?>{
      'a different host': 'https://evil.example.invalid',
      'a prefix of the right one': 'accounts.google.co',
      'the right one as a prefix': 'accounts.google.com.evil.invalid',
      'http not https': 'http://accounts.google.com',
      'with a trailing slash': 'https://accounts.google.com/',
      'upper cased': 'ACCOUNTS.GOOGLE.COM',
      'empty': '',
      'a number': 7,
      'a list': <Object?>['accounts.google.com'],
      'null': null,
    };
    badIss.forEach((String name, Object? iss) {
      test('iss $name is refused', () async {
        await _expectBad('iss: $name',
            mintToken(claims: goodClaims(overrides: {'iss': iss})));
      });
    });

    test('a missing iss is refused', () async {
      await _expectBad(
          'no iss', mintToken(claims: goodClaims(overrides: {'iss': absent})));
    });

    test('a payload that is not a JSON object is refused', () async {
      for (final String text in <String>['[]', '"x"', '12', 'null', 'nope']) {
        await _expectBad(
          'payload is $text',
          rawToken([
            b64url(utf8.encode(jsonEncode({'alg': 'RS256', 'kid': keyA.kid}))),
            b64url(utf8.encode(text)),
            'AAAA',
          ]),
        );
      }
    });

    test('a payload that is not JSON but is genuinely signed is refused',
        () async {
      final String head =
          b64url(utf8.encode(jsonEncode({'alg': 'RS256', 'kid': keyA.kid})));
      final String body = b64url(utf8.encode('this is not json'));
      final String sig = b64url(keyA.sign(ascii.encode('$head.$body')));
      await _expectBad('signed plain text payload', '$head.$body.$sig');
    });
  });

  group('check 5: aud', () {
    test('a different client id is refused', () async {
      await _expectBad(
        'aud of another app',
        mintToken(claims: goodClaims(overrides: {'aud': 'other-client'})),
      );
    });

    test('a list aud holding the right id is refused', () async {
      await _expectBad(
        'aud as a one element list',
        mintToken(
            claims: goodClaims(overrides: {
          'aud': [testClientId]
        })),
      );
    });

    test('a list aud holding the right id among others is refused', () async {
      await _expectBad(
        'aud as a two element list',
        mintToken(
            claims: goodClaims(overrides: {
          'aud': [testClientId, 'other']
        })),
      );
    });

    test(
        'an aud that only starts with, ends with or contains the id is '
        'refused', () async {
      for (final String aud in <String>[
        '${testClientId}x',
        'x$testClientId',
        testClientId.toUpperCase(),
        ' $testClientId',
        '$testClientId ',
        '',
      ]) {
        await _expectBad('aud "$aud"',
            mintToken(claims: goodClaims(overrides: {'aud': aud})));
      }
    });

    test('a missing, null or numeric aud is refused', () async {
      await _expectBad(
          'no aud', mintToken(claims: goodClaims(overrides: {'aud': absent})));
      await _expectBad(
          'null aud', mintToken(claims: goodClaims(overrides: {'aud': null})));
      await _expectBad(
          'numeric aud', mintToken(claims: goodClaims(overrides: {'aud': 1})));
    });

    test('azp equal to the id does not stand in for a wrong aud', () async {
      await _expectBad(
        'wrong aud, right azp',
        mintToken(
          claims: goodClaims(
              overrides: {'aud': 'other-client', 'azp': testClientId}),
        ),
      );
    });
  });

  group('check 6: exp and iat against the injected clock', () {
    test('exp 59 seconds in the past is still accepted (the 60 s skew)',
        () async {
      await _expectOk(
        'exp = now - 59',
        mintToken(claims: goodClaims(overrides: {'exp': testNowSeconds - 59})),
      );
    });

    test(
        'exp exactly 60 seconds in the past is refused (strictly greater '
        'than now minus 60)', () async {
      await _expectBad(
        'exp = now - 60',
        mintToken(claims: goodClaims(overrides: {'exp': testNowSeconds - 60})),
      );
    });

    test('exp 61 seconds, an hour and a year in the past are refused',
        () async {
      for (final int back in <int>[61, 3600, 31536000]) {
        await _expectBad(
          'exp = now - $back',
          mintToken(
              claims: goodClaims(overrides: {'exp': testNowSeconds - back})),
        );
      }
    });

    test('exp in the future is accepted', () async {
      await _expectOk(
        'exp = now + 1',
        mintToken(claims: goodClaims(overrides: {'exp': testNowSeconds + 1})),
      );
    });

    test('exp is judged against the injected clock, not the real one',
        () async {
      final built = _build();
      final String token = mintToken(
        claims: goodClaims(overrides: {'exp': testNowSeconds + 120}),
      );
      await _expectOk('before the clock moves', token,
          verifier: built.verifier);
      built.clock.advance(const Duration(seconds: 120 + 59));
      await _expectOk('179 s later, still inside the skew', token,
          verifier: built.verifier);
      built.clock.advance(const Duration(seconds: 1));
      await _expectBad('180 s later, exactly at the skew edge', token,
          verifier: built.verifier);
    });

    test('exp as a string, null or missing is refused', () async {
      await _expectBad(
        'string exp',
        mintToken(
            claims: goodClaims(overrides: {'exp': '${testNowSeconds + 3600}'})),
      );
      await _expectBad(
          'null exp', mintToken(claims: goodClaims(overrides: {'exp': null})));
      await _expectBad(
          'no exp', mintToken(claims: goodClaims(overrides: {'exp': absent})));
    });

    test('iat 59 seconds in the future is accepted', () async {
      await _expectOk(
        'iat = now + 59',
        mintToken(claims: goodClaims(overrides: {'iat': testNowSeconds + 59})),
      );
    });

    test(
        'iat exactly 60 seconds in the future is refused (strictly less '
        'than now plus 60)', () async {
      await _expectBad(
        'iat = now + 60',
        mintToken(claims: goodClaims(overrides: {'iat': testNowSeconds + 60})),
      );
    });

    test('iat far in the future is refused', () async {
      await _expectBad(
        'iat = now + 1 day',
        mintToken(
            claims: goodClaims(overrides: {'iat': testNowSeconds + 86400})),
      );
    });

    test('iat in the past is accepted', () async {
      await _expectOk(
        'iat = now - 1 day',
        mintToken(
            claims: goodClaims(overrides: {'iat': testNowSeconds - 86400})),
      );
    });

    test('iat as a string, null or missing is refused', () async {
      await _expectBad(
        'string iat',
        mintToken(
            claims: goodClaims(overrides: {'iat': '${testNowSeconds - 5}'})),
      );
      await _expectBad(
          'null iat', mintToken(claims: goodClaims(overrides: {'iat': null})));
      await _expectBad(
          'no iat', mintToken(claims: goodClaims(overrides: {'iat': absent})));
    });
  });

  group('check 7: sub', () {
    test('a missing sub is refused', () async {
      await _expectBad(
          'no sub', mintToken(claims: goodClaims(overrides: {'sub': absent})));
    });

    test('an empty sub is refused', () async {
      await _expectBad('empty sub', mintToken(claims: goodClaims(sub: '')));
    });

    test('a sub that is not a string is refused', () async {
      await _expectBad('numeric sub',
          mintToken(claims: goodClaims(overrides: {'sub': 12345})));
      await _expectBad(
          'null sub', mintToken(claims: goodClaims(overrides: {'sub': null})));
      await _expectBad(
          'list sub',
          mintToken(
              claims: goodClaims(overrides: {
            'sub': ['a']
          })));
    });

    test('a sub of 256 characters is refused', () async {
      await _expectBad(
          '256 char sub', mintToken(claims: goodClaims(sub: 's' * 256)));
    });

    test('a sub of 1 and of 255 characters is accepted', () async {
      final TokenOk one = await _expectOk(
          '1 char sub', mintToken(claims: goodClaims(sub: 's')));
      expect(one.sub, 's', reason: 'a one character sub is the lower bound');
      final TokenOk long = await _expectOk(
          '255 char sub', mintToken(claims: goodClaims(sub: 's' * 255)));
      expect(long.sub.length, 255,
          reason: 'a 255 character sub is the upper bound, kept whole');
    });
  });

  group('name is optional', () {
    final Map<String, Object?> yieldsEmpty = <String, Object?>{
      'absent': absent,
      'null': null,
      'a number': 7,
      'a list': <Object?>['Ann'],
      'an object': <String, Object?>{'a': 'b'},
      'empty': '',
      'spaces only': '    ',
      'tabs and newlines only': '\t\n \r',
    };
    yieldsEmpty.forEach((String label, Object? name) {
      test(
          'a name that is $label gives the empty display name, not a '
          'refusal', () async {
        final TokenOk ok = await _expectOk(
          'name: $label',
          mintToken(claims: goodClaims(overrides: {'name': name})),
        );
        expect(ok.name, '',
            reason: 'name $label must give display name "" (36.3), got '
                '"${ok.name}"');
      });
    });
  });

  group('36.3.1: the key set', () {
    test(
        'the first verification fetches the set once and a second '
        'verification reuses it', () async {
      final built = _build();
      await _expectOk('first', mintToken(), verifier: built.verifier);
      await _expectOk('second', mintToken(), verifier: built.verifier);
      await _expectOk('third', mintToken(), verifier: built.verifier);
      expect(built.jwks.calls, 1,
          reason: 'three good tokens inside the cache lifetime must cost one '
              'fetch, got ${built.jwks.calls}');
    });

    test('an unknown kid triggers exactly one refetch and is then refused',
        () async {
      final built = _build();
      await _expectOk('prime the cache', mintToken(), verifier: built.verifier);
      built.clock.advance(const Duration(minutes: 5));
      final int before = built.jwks.calls;
      await _expectBad('unknown kid after 5 minutes',
          mintToken(header: {'kid': 'c720-unknown-1'}),
          verifier: built.verifier);
      expect(built.jwks.calls - before, 1,
          reason: 'an unknown kid must trigger one refetch; fetches went '
              'from $before to ${built.jwks.calls}');
    });

    test(
        'a second unknown kid within 60 s causes no further fetch, for any '
        'kid, for the whole process', () async {
      final built = _build();
      await _expectOk('prime the cache', mintToken(), verifier: built.verifier);
      built.clock.advance(const Duration(minutes: 5));
      await _expectBad(
          'first unknown', mintToken(header: {'kid': 'c720-unknown-1'}),
          verifier: built.verifier);
      final int afterFirst = built.jwks.calls;
      await _expectBad(
          'same unknown again', mintToken(header: {'kid': 'c720-unknown-1'}),
          verifier: built.verifier);
      built.clock.advance(const Duration(seconds: 30));
      await _expectBad('a different unknown kid at +30 s',
          mintToken(header: {'kid': 'c720-unknown-2'}),
          verifier: built.verifier);
      built.clock.advance(const Duration(seconds: 29));
      await _expectBad('a third unknown kid at +59 s',
          mintToken(header: {'kid': 'c720-unknown-3'}),
          verifier: built.verifier);
      expect(built.jwks.calls, afterFirst,
          reason: 'at most one refetch per 60 s for the whole process: calls '
              'after the first unknown kid were $afterFirst, now '
              '${built.jwks.calls}');
    });

    test('after 60 s another unknown kid may refetch again', () async {
      final built = _build();
      await _expectOk('prime the cache', mintToken(), verifier: built.verifier);
      built.clock.advance(const Duration(minutes: 5));
      await _expectBad(
          'first unknown', mintToken(header: {'kid': 'c720-unknown-1'}),
          verifier: built.verifier);
      final int afterFirst = built.jwks.calls;
      built.clock.advance(const Duration(seconds: 61));
      await _expectBad('unknown kid 61 s later',
          mintToken(header: {'kid': 'c720-unknown-2'}),
          verifier: built.verifier);
      expect(built.jwks.calls, afterFirst + 1,
          reason: 'a refetch is allowed again once 60 s have passed since '
              'the last one; calls were $afterFirst, now ${built.jwks.calls}');
    });

    test(
        'a key that appears in the refetched set is then trusted, and the '
        'next token under it costs no fetch', () async {
      final built = _build();
      await _expectOk('key A', mintToken(), verifier: built.verifier);
      built.clock.advance(const Duration(minutes: 5));
      built.jwks.body = jwkSetJson(<TestKey>[keyA, keyB]);
      await _expectOk(
        'key B after rotation',
        mintToken(key: keyB, claims: _claimsAt(built.clock)),
        verifier: built.verifier,
      );
      final int calls = built.jwks.calls;
      await _expectOk(
        'key B again',
        mintToken(key: keyB, claims: _claimsAt(built.clock)),
        verifier: built.verifier,
      );
      expect(built.jwks.calls, calls,
          reason: 'a known kid must not refetch; calls were $calls, now '
              '${built.jwks.calls}');
    });

    test(
        'a key withdrawn from the refetched set stops being trusted after '
        'the refetch', () async {
      final built = _build(keys: <TestKey>[keyA, keyB]);
      await _expectOk('key B while published', mintToken(key: keyB),
          verifier: built.verifier);
      built.clock.advance(const Duration(hours: 2));
      built.jwks.body = jwkSetJson(<TestKey>[keyA]);
      await _expectBad(
        'key B after the set dropped it and the cache expired',
        mintToken(key: keyB, claims: _claimsAt(built.clock)),
        verifier: built.verifier,
      );
    });

    test(
        'an unknown kid with no cached set costs at most two fetches and '
        'is refused', () async {
      final built = _build();
      await _expectBad('first ever token has an unknown kid',
          mintToken(header: {'kid': 'c720-unknown-1'}),
          verifier: built.verifier);
      expect(built.jwks.calls, inInclusiveRange(1, 2),
          reason: 'the first token ever must fetch the set, and an unknown '
              'kid may add one refetch; got ${built.jwks.calls}');
    });

    test('a fetch that fails leaves the cached set in place', () async {
      final built = _build(cacheControl: 'max-age=120');
      await _expectOk('prime', mintToken(), verifier: built.verifier);
      built.clock.advance(const Duration(minutes: 10));
      built.jwks.failure = const SocketException('c720 network down');
      await _expectOk(
        'cache expired, fetch fails, old keys still verify',
        mintToken(claims: _claimsAt(built.clock)),
        verifier: built.verifier,
      );
      expect(built.jwks.calls, greaterThanOrEqualTo(2),
          reason: 'an expired cache must be refreshed, so the verifier must '
              'have tried the fetcher again');
    });

    test(
        'a fetch that fails on an unknown kid leaves the cached set in '
        'place', () async {
      final built = _build();
      await _expectOk('prime', mintToken(), verifier: built.verifier);
      built.clock.advance(const Duration(minutes: 5));
      built.jwks.failure = TimeoutException('c720 slow');
      await _expectBad('unknown kid, refetch fails',
          mintToken(header: {'kid': 'c720-unknown-1'}),
          verifier: built.verifier);
      await _expectOk(
        'known key still verifies afterwards',
        mintToken(claims: _claimsAt(built.clock)),
        verifier: built.verifier,
      );
    });

    test(
        'with no set at all and a failing fetch a well formed token gets '
        'TokenUnavailable, not TokenBad', () async {
      final built = _build();
      built.jwks.failure = const SocketException('c720 network down');
      final TokenCheck result = await built.verifier.verify(mintToken());
      expect(result, isA<TokenUnavailable>(),
          reason: 'no key set could be obtained: the answer is '
              'SIGN_IN_UNAVAILABLE (TokenUnavailable); got '
              '${_describe(result)}');
    });

    test(
        'with no set and a failing fetch, a token that fails check 1 or 2 '
        'is still TokenBad', () async {
      final built = _build();
      built.jwks.failure = const SocketException('c720 network down');
      for (final String token in <String>[
        'a.b',
        mintToken(header: {'alg': 'none'}, signatureOverride: 'AAAA'),
        mintToken(header: {'kid': absent}),
      ]) {
        final TokenCheck result = await built.verifier.verify(token);
        expect(result, isA<TokenBad>(),
            reason: 'checks 1 and 2 come before the key lookup and decide '
                'the answer first; got ${_describe(result)} for a token of '
                'length ${token.length}');
      }
    });

    test('a body that is not a key set counts as no set (TokenUnavailable)',
        () async {
      for (final String body in <String>['not json', '[]', '{"keys": 5}', '']) {
        final built = _build();
        built.jwks.body = body;
        final TokenCheck result = await built.verifier.verify(mintToken());
        expect(result, isA<TokenUnavailable>(),
            reason: 'a fetch that returns "$body" yields no usable key set; '
                'expected TokenUnavailable, got ${_describe(result)}');
      }
    });

    test('once the fetcher recovers, a later token succeeds', () async {
      final built = _build();
      built.jwks.failure = const SocketException('c720 network down');
      await built.verifier.verify(mintToken());
      built.jwks.failure = null;
      built.clock.advance(const Duration(seconds: 61));
      await _expectOk(
          'after recovery', mintToken(claims: _claimsAt(built.clock)),
          verifier: built.verifier);
    });

    test('a JWK that is not RSA, or lacks n or e, is never a trusted key',
        () async {
      final built = _build();
      built.jwks.body = jsonEncode(<String, Object?>{
        'keys': <Object?>[
          <String, Object?>{
            'kty': 'EC',
            'kid': keyA.kid,
            'n': keyA.jwk['n'],
            'e': 'AQAB'
          },
          <String, Object?>{'kty': 'RSA', 'kid': keyA.kid, 'e': 'AQAB'},
          <String, Object?>{'kty': 'RSA', 'kid': keyA.kid, 'n': keyA.jwk['n']},
          'junk',
          5,
        ],
      });
      final TokenCheck result = await built.verifier.verify(mintToken());
      expect(result, isNot(isA<TokenOk>()),
          reason: 'only a kty RSA entry with n and e is a key; a token must '
              'not verify against a malformed entry; got ${_describe(result)}');
    });
  });

  group('36.3.1: max-age', () {
    Future<void> expectRefetchAt({
      required String scenario,
      required String? cacheControl,
      required int lifetimeSeconds,
    }) async {
      final built = _build(cacheControl: cacheControl);
      await _expectOk('$scenario: prime', mintToken(),
          verifier: built.verifier);
      expect(built.jwks.calls, 1, reason: '$scenario: priming costs one fetch');
      built.clock.advance(Duration(seconds: lifetimeSeconds - 1));
      await _expectOk(
        '$scenario: ${lifetimeSeconds - 1} s in',
        mintToken(claims: _claimsAt(built.clock)),
        verifier: built.verifier,
      );
      expect(built.jwks.calls, 1,
          reason: '$scenario: the set must be kept for $lifetimeSeconds s; '
              'it was refetched ${lifetimeSeconds - 1} s in '
              '(Cache-Control: $cacheControl)');
      built.clock.advance(const Duration(seconds: 2));
      await _expectOk(
        '$scenario: ${lifetimeSeconds + 1} s in',
        mintToken(claims: _claimsAt(built.clock)),
        verifier: built.verifier,
      );
      expect(built.jwks.calls, 2,
          reason: '$scenario: after $lifetimeSeconds s the set has expired '
              'and the next verification must refetch it; calls: '
              '${built.jwks.calls} (Cache-Control: $cacheControl)');
    }

    test('max-age=300 inside a longer directive list is honoured', () async {
      await expectRefetchAt(
        scenario: 'max-age 300',
        cacheControl: 'public, max-age=300, must-revalidate',
        lifetimeSeconds: 300,
      );
    });

    test('max-age=7200 is honoured, longer than the default', () async {
      await expectRefetchAt(
        scenario: 'max-age 7200',
        cacheControl: 'max-age=7200',
        lifetimeSeconds: 7200,
      );
    });

    test('no Cache-Control header means one hour', () async {
      await expectRefetchAt(
        scenario: 'absent header',
        cacheControl: null,
        lifetimeSeconds: 3600,
      );
    });

    test('an unreadable max-age means one hour', () async {
      for (final String value in <String>[
        'max-age=abc',
        'max-age=',
        'public',
        'max-age=-5',
        'garbage;;;',
      ]) {
        await expectRefetchAt(
          scenario: 'unreadable "$value"',
          cacheControl: value,
          lifetimeSeconds: 3600,
        );
      }
    });

    test('a max-age over 24 hours is capped at 24 hours', () async {
      await expectRefetchAt(
        scenario: 'max-age 10 days',
        cacheControl: 'public, max-age=864000',
        lifetimeSeconds: 86400,
      );
    });

    test('a max-age of exactly 24 hours is honoured as given', () async {
      await expectRefetchAt(
        scenario: 'max-age 86400',
        cacheControl: 'max-age=86400',
        lifetimeSeconds: 86400,
      );
    });
  });

  group('httpJwksFetcher against a loopback server', () {
    late HttpServer server;
    late Uri url;
    late List<HttpRequest> held;
    String? replyBody;
    int replyStatus = 200;
    String? replyCache;
    bool hang = false;

    setUp(() async {
      held = <HttpRequest>[];
      replyBody = jwkSetJson(<TestKey>[keyA]);
      replyStatus = 200;
      replyCache = 'public, max-age=1234';
      hang = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = Uri.parse('http://127.0.0.1:${server.port}/certs');
      server.listen((HttpRequest request) {
        if (hang) {
          held.add(request);
          return;
        }
        request.response.statusCode = replyStatus;
        if (replyCache != null) {
          request.response.headers.set('cache-control', replyCache!);
        }
        request.response.write(replyBody);
        unawaited(request.response.close());
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('returns the body and the Cache-Control value', () async {
      final JwksResponse response = await httpJwksFetcher(url)();
      expect(response.body, jwkSetJson(<TestKey>[keyA]),
          reason: 'the fetcher must return the response body untouched');
      expect(response.cacheControl, 'public, max-age=1234',
          reason: 'the fetcher must pass the Cache-Control header through');
    });

    test('a response without Cache-Control gives a null cacheControl',
        () async {
      replyCache = null;
      final JwksResponse response = await httpJwksFetcher(url)();
      expect(response.cacheControl, isNull,
          reason: 'no header, no value: the verifier applies the 1 hour '
              'default, not the fetcher');
    });

    test('a non-200 answer throws', () async {
      replyStatus = 503;
      await expectLater(
        httpJwksFetcher(url)(),
        throwsA(anything),
        reason: 'a 503 from the key host is a failed fetch and must throw',
      );
    });

    test('a connection that is refused throws', () async {
      final HttpServer closed =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final Uri dead = Uri.parse('http://127.0.0.1:${closed.port}/certs');
      await closed.close(force: true);
      await expectLater(
        httpJwksFetcher(dead)(),
        throwsA(anything),
        reason: 'nothing listens on $dead; the fetch must throw',
      );
    });

    test('a server that never answers is given up on after about 5 seconds',
        () async {
      hang = true;
      final Stopwatch watch = Stopwatch()..start();
      Object? thrown;
      bool outerGuardFired = false;
      try {
        await httpJwksFetcher(url)().timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            outerGuardFired = true;
            throw StateError('outer guard');
          },
        );
      } catch (error) {
        thrown = error;
      }
      watch.stop();
      expect(outerGuardFired, isFalse,
          reason: 'the fetcher itself must give up after 5 s; it was still '
              'waiting after 20 s');
      expect(thrown, isNotNull,
          reason: 'a fetch that never gets an answer must throw');
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 4000)),
          reason: 'the timeout is 5 s; it gave up after ${watch.elapsed}');
      expect(watch.elapsed, lessThan(const Duration(seconds: 9)),
          reason: 'the timeout is 5 s; it gave up only after ${watch.elapsed}');
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}

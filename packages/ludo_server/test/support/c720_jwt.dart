// Test-only helpers for the section 36 tests (order 720t): two fixed RSA
// key pairs generated once for these tests and used for nothing else, a JWK
// set builder, an RS256 token minter, a counting key fetcher, and the helpers
// the process tests share. Nothing here is imported from `lib/`, except the
// pinned interface names `JwksResponse` and `JwksFetcher`.
//
// Every value is deterministic. A failing case names its scenario, and the
// scenario is enough to rebuild the exact token: the key pair is fixed, the
// clock is a `FakeClock` set to `testNow`, and nothing is drawn from a random
// source except the unique strings the process test prints in its own failure
// message.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ludo_server/src/google_token.dart';
import 'package:pointycastle/export.dart';

/// The OAuth client id every token in these tests names as its audience.
const String testClientId = 'c720-test-client.apps.googleusercontent.com';

/// The instant every in-process test starts at.
final DateTime testNow = DateTime.utc(2026, 11, 25, 12);

/// [testNow] in whole seconds since the epoch, the unit JWT times use.
int get testNowSeconds => testNow.millisecondsSinceEpoch ~/ 1000;

const String _k1N =
    'be20597c32f6e46e0e044a95cc7844f910a0646743b8030b472becf79584'
    'bbc5d48c322f4809ebf9fff49b636eeefdb596f0f57fb9ea9c4c825e76da'
    '74479da5975b8bbd2b24dca348c88e7a1344af7197152dcbf01536a8fed1'
    'd7a355605817682e90757290322a0e42050b07abf19fb822ef32243126ed'
    '709baca586e02eaa5abfd0cee7c3c51b298e3fb24d7df1fd1c8700b33df6'
    'cdb7ecb526a50080b3374336dad53e82358dcf1dfb5473d06fa3c898411d'
    'fedaa3c8bf644e53ca7105c473904919e38fe7ea8dedaadfe8d3e2bbc210'
    '749cf1d6c069c1b81a6e3358975382de441cd30bb0e2d12f65f9315f0941'
    '9dbf2c795019a9dcc4b94be234497a1d';

const String _k1D =
    '5cae7160d989405ea3e794a2447c06877182f69ede4497fb49f5103dbafd'
    'eaf92bbd32039976f8b9347c3db9718d0051a2a490d07445796ed4888f20'
    'bbd96370a30185f3afd1f6da8432fc3d67222ef24d078e7d216a7dec50d7'
    'e36a2446e47a789766655275177727df280d31eeb0493f5e8c42e1a0b24c'
    'c1fda96241870c47b8f4918571e6bb4ca2c1b11397448ea5abf93b549fa3'
    '0e685b7f6d2ad44500e41540bd6e6e6fa579e897e4a9674a54f4cc51d1cf'
    '1ce3769c868ec55a8f4b2eebbf05f4c0d6d26abcaf187af951e7c4be5879'
    'dadd807b1ab30c9d23e0cc33d8cd602e00a908b18c4b566f94ee03a0f570'
    '0df5729ccacb6fc5807c87c511a142d3';

const String _k1P =
    'e1378cea0f7743066d30c0766da10d2fe6bb4f0e191350ecf1675f773af4'
    '2ba05f1eda36b1149834db51ac50636e2e3027a8b3972d94a99696424909'
    '834ed4d3442b9028a7f56962ccca857e89704abb42604e00d9ce8d3365aa'
    'e2be2259cdacbd616f6c0ee41983c66981934d49d79dbc67a7c223862197'
    '3fe7854c80226bcf';

const String _k1Q =
    'd81cf61b2fcb018d1ad66cbbb7aaf0c36ddb3eb8c1ac22e4e39006813064'
    'c14eb30bf509fa4e62548853cd084158a45536697bddbf1b601c79ca752c'
    'd0fc5c015e3d9db61651fda76f8ddb45ba6cf9d8769d97f90e3d36ad4298'
    'aa97bff60eadcd990ffabea93648ee955a86ecb7988762e5fdd92cb5efac'
    '77357718fada9a53';

const String _k2N =
    '948bb2e66de6f10a95e815487fb8565aa4abc5f8ac7404c963941d746378'
    'f695e77da96d800d1fcd09ae72aa12156b01a316310ed04fc2e7972c0734'
    'ef7fb9ab0b55722f30f8d56ded6d8b947adff9f9329d70706c95425140ae'
    'c14f6186fc1e410c8be2aede8a57204a9f448fcd6a641ca12cb628d89cd9'
    'eeb95b30f61dcfa3245045c1e9cd5a8814363f30b89d3e6029fa2f4b8dcb'
    '89c3530b9d88f502bb6ec3c959123833d60973983903ade91fe8a2880141'
    'ba6ff60bc28e5527b49fdee2f55d12f396139fb088e67a42081ccd7a639e'
    'a413fec2220af4901a0f2c49b5c80877595bbc52552559ae0d8f7c649b32'
    '7fb8f2be01364c84dc9d94b428da866f';

const String _k2D =
    '3572d2ab40ee30daeb3777b8ff63b786a3ebbeaf0c762e66bc32c62a63c4'
    '598d749eed809deb9afeaeb61b420081be5ff76b7bb965d0dd43714c8147'
    '55c9b267ce0b2fabb546439d6b29d868539215a2c9c886759d4c53716301'
    'be42aec7e01d8eb05200fd84cb683011499f64d2b7ae4ff2da60acefcbf8'
    '4a825d428fbc0842919832d92caaf7af979adf2d4698d22e49f594dcf0b8'
    '773b2a832591213ac7075ba68a1f29fd39c687c9841652772a2203d47ae8'
    'c6bfb5de5411ef568c210d2df1818c712e4ddae32a1b1ccc7b93f226af2f'
    '47804422cd32f25d6cf71e4f46280c57f54d84be0bce88fb48e1adc69888'
    '7d5e3358adc7eb5c4d363c9b466948d9';

const String _k2P =
    'd11ed4c305b4091b7b0990d54be76a1049437b3ee5bdaeef0ce3aaf1ddc5'
    'c61d938f23e1e26886bc8b389c23b4b36ea78ce38895eef34052853815da'
    '5fe6dbb2ce1e927f02298517bd8a0452cb85331c21c1900567f3b61b3b19'
    'db690714d6e92d2dbcfd1e87c25ec2107bd6e2df270f87471ee73a27ea69'
    '82c4d7d6b6ae57ad';

const String _k2Q =
    'b5d88e905bc3e5ccf734b4c84b05be85bea5f9d109eb180203951b1777af'
    '8293969fc7e44ed78c1907db2007c6f37c1c778c9467e7676ccd55c83e68'
    '18e6079e1362008a2c6c049754308f2b30fe3d8d3d40066ff91e8c2e9bb9'
    '048216c376310b1eb072c964ff2def48008d6ade86811dd36d85475925f8'
    'd27139d33db00a0b';

/// One RSA key pair with the `kid` it is published under.
class TestKey {
  TestKey(this.kid, String n, String d, String p, String q)
      : modulus = BigInt.parse(n, radix: 16),
        _private = RSAPrivateKey(
          BigInt.parse(n, radix: 16),
          BigInt.parse(d, radix: 16),
          BigInt.parse(p, radix: 16),
          BigInt.parse(q, radix: 16),
        );

  final String kid;
  final BigInt modulus;
  final RSAPrivateKey _private;

  /// RSASSA-PKCS1-v1_5 with SHA-256 over [message], left padded to the
  /// modulus length so a short big-endian conversion cannot shorten it.
  Uint8List sign(List<int> message) {
    final RSASigner signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(_private));
    final Uint8List raw =
        signer.generateSignature(Uint8List.fromList(message)).bytes;
    final int size = (modulus.bitLength + 7) ~/ 8;
    if (raw.length >= size) {
      return raw;
    }
    final Uint8List padded = Uint8List(size);
    padded.setRange(size - raw.length, size, raw);
    return padded;
  }

  /// The public half as one entry of a JWK set.
  Map<String, Object?> get jwk => <String, Object?>{
        'kty': 'RSA',
        'alg': 'RS256',
        'use': 'sig',
        'kid': kid,
        'n': b64url(_bigIntBytes(modulus)),
        'e': 'AQAB',
      };
}

Uint8List _bigIntBytes(BigInt value) {
  final int size = (value.bitLength + 7) ~/ 8;
  final Uint8List out = Uint8List(size);
  BigInt rest = value;
  for (int i = size - 1; i >= 0; i--) {
    out[i] = (rest & BigInt.from(0xff)).toInt();
    rest = rest >> 8;
  }
  return out;
}

/// The first test key, published as `c720-key-a`.
final TestKey keyA = TestKey('c720-key-a', _k1N, _k1D, _k1P, _k1Q);

/// The second test key, published as `c720-key-b`. Never in the same set as
/// [keyA] unless a test says so.
final TestKey keyB = TestKey('c720-key-b', _k2N, _k2D, _k2P, _k2Q);

/// Unpadded base64url, the encoding every JWT part uses.
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes an unpadded base64url string.
Uint8List unb64url(String text) {
  final String padded = text + '=' * ((4 - text.length % 4) % 4);
  return Uint8List.fromList(base64Url.decode(padded));
}

/// A JWK set document holding the public halves of [keys].
String jwkSetJson(List<TestKey> keys) => jsonEncode(<String, Object?>{
      'keys': keys.map((TestKey k) => k.jwk).toList(),
    });

/// The claims of a token that passes every check of section 36.3 at
/// [testNow], plus an `email` claim and the other claims Google really sends,
/// all of which the server must ignore. [overrides] replaces or adds a claim;
/// a value of [absent] removes it.
Map<String, Object?> goodClaims({
  String sub = 'sub-default-0001',
  String? name = 'Test Player',
  String email = 'default-player@example.invalid',
  int? nowSeconds,
  Map<String, Object?> overrides = const <String, Object?>{},
}) {
  final int now = nowSeconds ?? testNowSeconds;
  final Map<String, Object?> claims = <String, Object?>{
    'iss': 'https://accounts.google.com',
    'aud': testClientId,
    'azp': testClientId,
    'sub': sub,
    'email': email,
    'email_verified': true,
    'name': name,
    'picture': 'https://lh3.example.invalid/picture-c720',
    'locale': 'xx-c720',
    'iat': now - 5,
    'exp': now + 3600,
  };
  if (name == null) {
    claims.remove('name');
  }
  overrides.forEach((String key, Object? value) {
    if (identical(value, absent)) {
      claims.remove(key);
    } else {
      claims[key] = value;
    }
  });
  return claims;
}

/// Marker value for [goodClaims] and [mintToken]: remove this key.
const Object absent = _Absent();

class _Absent {
  const _Absent();
}

/// Signs a token with [key]. [header] and [claims] default to a valid RS256
/// header naming the key and [goodClaims]. A header or claim value of
/// [absent] removes that key. [signingKey] signs instead of [key] (a wrong
/// signature), [signatureOverride] replaces the signature part as text.
String mintToken({
  TestKey? key,
  Map<String, Object?>? header,
  Map<String, Object?>? claims,
  TestKey? signingKey,
  String? signatureOverride,
}) {
  final TestKey k = key ?? keyA;
  final Map<String, Object?> h = <String, Object?>{
    'alg': 'RS256',
    'kid': k.kid,
    'typ': 'JWT',
  };
  header?.forEach((String name, Object? value) {
    if (identical(value, absent)) {
      h.remove(name);
    } else {
      h[name] = value;
    }
  });
  final String head = b64url(utf8.encode(jsonEncode(h)));
  final String body = b64url(utf8.encode(jsonEncode(claims ?? goodClaims())));
  final String signed = '$head.$body';
  final String signature =
      signatureOverride ?? b64url((signingKey ?? k).sign(ascii.encode(signed)));
  return '$signed.$signature';
}

/// A token whose parts are exactly the given strings joined by dots, for the
/// structural cases where the parts are not meant to be valid.
String rawToken(List<String> parts) => parts.join('.');

/// Flips one bit of the byte at [index] of the decoded signature of
/// [token] and re-encodes it, leaving header and payload untouched.
String withFlippedSignatureByte(String token, {int index = 10}) {
  final List<String> parts = token.split('.');
  final Uint8List signature = unb64url(parts[2]);
  signature[index] ^= 0x01;
  return '${parts[0]}.${parts[1]}.${b64url(signature)}';
}

/// A valid token (kid [keyA]) whose length is exactly [target] bytes, padded
/// with an extra claim the server must ignore. The signature is genuine, so
/// the only reason to refuse it is its size.
String tokenOfLength(int target, {Map<String, Object?>? baseClaims}) {
  final Map<String, Object?> base = baseClaims ?? goodClaims();
  // The signature of a 2048 bit key is always 342 base64url characters, so
  // the length is found with a placeholder signature and only the match is
  // signed for real.
  final String placeholder = 'S' * 342;
  for (int headerPad = 0; headerPad < 3; headerPad++) {
    for (int pad = 0; pad < target; pad++) {
      final Map<String, Object?> claims = Map<String, Object?>.of(base)
        ..['pad'] = 'p' * pad;
      final Map<String, Object?> header = <String, Object?>{
        if (headerPad > 0) 'x': 'h' * (headerPad - 1),
      };
      final int length = mintToken(
        header: header,
        claims: claims,
        signatureOverride: placeholder,
      ).length;
      if (length == target) {
        return mintToken(header: header, claims: claims);
      }
      if (length > target) {
        break;
      }
    }
  }
  throw StateError('could not build a token of exactly $target bytes');
}

/// An HS256 token signed with [secret] as the HMAC key, the classic algorithm
/// confusion attack when the secret is the public key's modulus.
String hs256Token(List<int> secret, {Map<String, Object?>? claims}) {
  final String head = b64url(utf8.encode(
    jsonEncode(<String, Object?>{'alg': 'HS256', 'kid': keyA.kid}),
  ));
  final String body = b64url(utf8.encode(jsonEncode(claims ?? goodClaims())));
  final Uint8List mac = Uint8List.fromList(
    Hmac(sha256, secret).convert(ascii.encode('$head.$body')).bytes,
  );
  return '$head.$body.${b64url(mac)}';
}

/// A key fetcher a test controls. It counts calls, answers [body] with
/// [cacheControl] until [failure] is set, and then throws it.
class FakeJwks {
  FakeJwks(this.body, {this.cacheControl});

  String body;
  String? cacheControl;
  Object? failure;
  int calls = 0;

  Future<JwksResponse> fetch() async {
    calls++;
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
    return JwksResponse(body, cacheControl: cacheControl);
  }
}

/// The environment of a server subprocess, built from scratch. The session
/// environment carries live production endpoints and is never passed down.
Map<String, String> scrubbedEnvironment(Map<String, String> own) {
  final Map<String, String> env = <String, String>{
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    'HOME': Platform.environment['HOME'] ?? Directory.systemTemp.path,
  };
  final String? pubCache = Platform.environment['PUB_CACHE'];
  if (pubCache != null) {
    env['PUB_CACHE'] = pubCache;
  }
  env.addAll(own);
  return env;
}

/// The directory holding `bin/server.dart`, resolved from the package
/// configuration so it is right whatever the runner's working directory is.
Future<String> serverPackageRoot() async {
  final Uri? lib = await Isolate.resolvePackageUri(
    Uri.parse('package:ludo_server/ludo_server.dart'),
  );
  if (lib == null) {
    throw StateError('package:ludo_server/ludo_server.dart did not resolve');
  }
  return File.fromUri(lib).parent.parent.path;
}

/// A `bin/server.dart` process with its output captured.
class ServerProcess {
  ServerProcess._(this._process);

  final Process _process;
  final StringBuffer _out = StringBuffer();
  final StringBuffer _err = StringBuffer();
  final Completer<int> _port = Completer<int>();
  late final Future<void> _drained;
  static final RegExp _listening = RegExp(r'listening on port (\d+)');

  /// Everything written to stdout so far.
  String get stdoutText => _out.toString();

  /// Everything written to stderr so far.
  String get stderrText => _err.toString();

  /// Both streams, stdout first.
  String get allOutput => '$stdoutText\n$stderrText';

  /// Completes with the port from the "listening on port N" line.
  Future<int> get port => _port.future;

  /// Starts the server with exactly [env] (plus the scrub baseline).
  static Future<ServerProcess> start(Map<String, String> env) async {
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', 'bin/server.dart'],
      environment: scrubbedEnvironment(env),
      includeParentEnvironment: false,
      workingDirectory: await serverPackageRoot(),
    );
    final ServerProcess server = ServerProcess._(process);
    final Future<void> outDone =
        process.stdout.transform(utf8.decoder).listen((String chunk) {
      server._out.write(chunk);
      final Match? m = _listening.firstMatch(server._out.toString());
      if (m != null && !server._port.isCompleted) {
        server._port.complete(int.parse(m.group(1)!));
      }
    }).asFuture<void>();
    final Future<void> errDone = process.stderr
        .transform(utf8.decoder)
        .listen(server._err.write)
        .asFuture<void>();
    server._drained = Future.wait<void>(<Future<void>>[outDone, errDone]);
    unawaited(process.exitCode.then((int code) {
      if (!server._port.isCompleted) {
        server._port.completeError(
          StateError('server exited with $code before listening'),
        );
      }
    }));
    // The error above is read by whoever awaits `port`; mark it handled for a
    // test that only waits for the exit.
    unawaited(server._port.future.then<void>((int _) {}, onError: (_) {}));
    return server;
  }

  /// Waits until the process exits on its own, or fails the wait after
  /// [limit]. Returns the exit code once both streams are fully read.
  Future<int> waitForExit(
      {Duration limit = const Duration(seconds: 60)}) async {
    final int code = await _process.exitCode.timeout(
      limit,
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        throw TimeoutException(
          'server did not exit within $limit; stdout: $stdoutText '
          'stderr: $stderrText',
        );
      },
    );
    await _drained;
    return code;
  }

  /// Ends the process with SIGTERM (SIGKILL after a grace) and returns once
  /// both streams are fully read.
  Future<void> stop() async {
    _process.kill(ProcessSignal.sigterm);
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await _drained;
  }

  /// A URL on the running server.
  Future<Uri> uri(String path) async =>
      Uri(scheme: 'http', host: '127.0.0.1', port: await port, path: path);
}

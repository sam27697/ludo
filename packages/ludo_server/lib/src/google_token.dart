// docs/PROTOCOL.md section 36.3: verifying a Google ID token.
//
// The token is decoded into a map and exactly six members are read from it:
// `sub`, `name`, `iss`, `aud`, `exp` and `iat`. Nothing else from that map is
// assigned to a variable, so nothing else can reach a log line, an error, a
// file or a response. This file never prints and never builds an error
// message out of the token or any part of it.
//
// Time comes from the injected `Clock`, the key set from the injected
// `JwksFetcher`; tests use their own key pair and never touch the network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart'
    show
        PublicKeyParameter,
        RSAPublicKey,
        RSASignature,
        RSASigner,
        SHA256Digest;

import 'clock.dart';

/// Where Google publishes its signing keys (section 36.3.1).
const String googleCertsUrl = 'https://www.googleapis.com/oauth2/v3/certs';

/// The most a token may weigh, section 36.3 item 1.
const int _maxTokenBytes = 4096;

/// Section 36.3 item 6: how far either clock may be off.
const int _skewMs = 60 * 1000;

/// Section 36.3.1: cache lifetime when `Cache-Control` says nothing usable,
/// and the most it is ever allowed to be.
const Duration _defaultKeyTtl = Duration(hours: 1);
const Duration _maxKeyTtl = Duration(hours: 24);

/// Section 36.3.1: one refetch for an unknown `kid` per this long.
const Duration _missRefetchEvery = Duration(seconds: 60);

/// A fetched key set and the `Cache-Control` header that came with it.
class JwksResponse {
  JwksResponse(this.body, {this.cacheControl});

  final String body;
  final String? cacheControl;
}

/// Fetches the key set. Throws on any failure.
typedef JwksFetcher = Future<JwksResponse> Function();

/// The real fetch of [url], with the 5 second limit of section 36.3.1. The
/// body is capped at 256 KiB; Google's set is about 1 KiB.
JwksFetcher httpJwksFetcher(Uri url) {
  return () async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      return await _fetchOnce(client, url).timeout(const Duration(seconds: 5));
    } finally {
      client.close(force: true);
    }
  };
}

Future<JwksResponse> _fetchOnce(HttpClient client, Uri url) async {
  final HttpClientRequest request = await client.getUrl(url);
  // A redirect is a failed fetch: it is answered with its 3xx status below.
  request.followRedirects = false;
  final HttpClientResponse response = await request.close();
  if (response.statusCode != 200) {
    throw HttpException('key set fetch answered ${response.statusCode}');
  }
  final BytesBuilder bytes = BytesBuilder(copy: false);
  await for (final List<int> chunk in response) {
    bytes.add(chunk);
    if (bytes.length > 256 * 1024) {
      throw const HttpException('key set is too large');
    }
  }
  return JwksResponse(
    utf8.decode(bytes.takeBytes()),
    cacheControl: response.headers.value(HttpHeaders.cacheControlHeader),
  );
}

/// Section 36.2: the `LUDO_GOOGLE_CERTS_URL` rule. Absent or empty is
/// [googleCertsUrl]; anything else must be `https://`, or `http://` to
/// `127.0.0.1` or `localhost`. Throws a [FormatException] that names the
/// variable and never carries its value.
Uri parseCertsUrl(String? raw) {
  if (raw == null || raw.isEmpty) {
    return Uri.parse(googleCertsUrl);
  }
  final Uri? uri = Uri.tryParse(raw);
  final bool ok = uri != null &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.scheme == 'https' ||
          (uri.scheme == 'http' &&
              (uri.host == '127.0.0.1' || uri.host == 'localhost')));
  if (!ok) {
    throw const FormatException(
      'LUDO_GOOGLE_CERTS_URL must be https://, or http:// to 127.0.0.1 or '
      'localhost',
    );
  }
  return uri;
}

/// What checking a token came to.
sealed class TokenCheck {}

/// Every check of section 36.3 held. [name] is the display name, `""` when
/// the token carried none.
final class TokenOk extends TokenCheck {
  TokenOk(this.sub, this.name);

  final String sub;
  final String name;
}

/// Some check failed: `BAD_TOKEN`.
final class TokenBad extends TokenCheck {}

/// No Google key set could be obtained: `SIGN_IN_UNAVAILABLE`.
final class TokenUnavailable extends TokenCheck {}

final RegExp _tokenShape = RegExp(
  r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$',
);

class GoogleTokenVerifier {
  GoogleTokenVerifier({
    required String clientId,
    required JwksFetcher fetch,
    required Clock clock,
  })  : _clientId = clientId,
        _fetch = fetch,
        _clock = clock;

  final String _clientId;
  final JwksFetcher _fetch;
  final Clock _clock;

  Map<String, RSAPublicKey> _keys = <String, RSAPublicKey>{};
  DateTime? _keysExpire;
  DateTime? _lastAttempt;
  Future<bool>? _inFlight;

  /// Checks [token] against section 36.3, in its order; the first failure
  /// decides. Never throws for a malformed token.
  Future<TokenCheck> verify(String token) async {
    // 1. Size and shape.
    if (utf8.encode(token).length > _maxTokenBytes ||
        !_tokenShape.hasMatch(token)) {
      return TokenBad();
    }
    final List<String> parts = token.split('.');

    // 2. Header.
    final Map<String, Object?>? header = _decodeObject(parts[0]);
    if (header == null) {
      return TokenBad();
    }
    final Object? alg = header['alg'];
    final Object? kid = header['kid'];
    if (alg != 'RS256' || kid is! String) {
      return TokenBad();
    }

    // 3. Key and signature.
    final Uint8List? signature = _decodeBytes(parts[2]);
    if (signature == null) {
      return TokenBad();
    }
    final _KeyLookup lookup = await _keyFor(kid);
    if (lookup.unavailable) {
      return TokenUnavailable();
    }
    final RSAPublicKey? key = lookup.key;
    if (key == null || !_signatureHolds(key, parts, signature)) {
      return TokenBad();
    }

    // 4 to 7. Payload.
    final Map<String, Object?>? payload = _decodeObject(parts[1]);
    if (payload == null) {
      return TokenBad();
    }
    final Object? iss = payload['iss'];
    if (iss != 'accounts.google.com' && iss != 'https://accounts.google.com') {
      return TokenBad();
    }
    final Object? aud = payload['aud'];
    if (aud is! String || aud != _clientId) {
      return TokenBad();
    }
    final int nowMs = _clock.now.millisecondsSinceEpoch;
    final Object? exp = payload['exp'];
    final Object? iat = payload['iat'];
    if (exp is! num || exp * 1000 <= nowMs - _skewMs) {
      return TokenBad();
    }
    if (iat is! num || iat * 1000 >= nowMs + _skewMs) {
      return TokenBad();
    }
    final Object? sub = payload['sub'];
    if (sub is! String || sub.runes.isEmpty || sub.runes.length > 255) {
      return TokenBad();
    }
    return TokenOk(sub, _displayName(payload['name']));
  }

  /// Section 36.1.1: trimmed, at most 40 characters; absent, not a string or
  /// empty after trimming is `""`.
  String _displayName(Object? raw) {
    if (raw is! String) {
      return '';
    }
    final List<int> runes = raw.trim().runes.toList();
    if (runes.length > 40) {
      return String.fromCharCodes(runes.sublist(0, 40)).trim();
    }
    return String.fromCharCodes(runes);
  }

  bool _signatureHolds(
    RSAPublicKey key,
    List<String> parts,
    Uint8List signature,
  ) {
    final BigInt? modulus = key.modulus;
    if (modulus == null || signature.length != (modulus.bitLength + 7) >> 3) {
      return false;
    }
    final RSASigner signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(false, PublicKeyParameter<RSAPublicKey>(key));
    final Uint8List signed =
        Uint8List.fromList(ascii.encode('${parts[0]}.${parts[1]}'));
    try {
      return signer.verifySignature(signed, RSASignature(signature));
    } on ArgumentError {
      // The padding check of a forged signature raises rather than returning
      // false in some pointycastle paths; either way the token is bad.
      return false;
    }
  }

  Map<String, Object?>? _decodeObject(String part) {
    final Uint8List? bytes = _decodeBytes(part);
    if (bytes == null) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Uint8List? _decodeBytes(String part) {
    try {
      return Uint8List.fromList(base64Url.decode(base64Url.normalize(part)));
    } on FormatException {
      return null;
    }
  }

  // --- key set -----------------------------------------------------------

  Future<_KeyLookup> _keyFor(String kid) async {
    final DateTime? expires = _keysExpire;
    if (expires == null || !_clock.now.isBefore(expires)) {
      // Nothing cached, or the cache has outlived its max-age: load. A failed
      // load leaves a stale set in place, and with no set at all nothing can
      // be verified.
      await _refresh();
      if (_keysExpire == null) {
        return const _KeyLookup.unavailable();
      }
    }
    RSAPublicKey? key = _keys[kid];
    if (key != null) {
      return _KeyLookup(key);
    }
    // An unknown kid: a fetch already running is awaited and the set read
    // again; with none running, one starts only when the 60 second window
    // allows it, else the answer is immediate.
    await _refresh();
    key = _keys[kid];
    return _KeyLookup(key);
  }

  /// Section 36.3.1: at most one fetch per 60 seconds for the whole process,
  /// whether it is the first load, an expiry reload or a miss refetch, and
  /// whether or not the last one worked. A caller arriving while a fetch is
  /// running awaits that fetch instead.
  Future<void> _refresh() async {
    final Future<bool>? running = _inFlight;
    if (running != null) {
      await running;
      return;
    }
    final DateTime now = _clock.now;
    final DateTime? last = _lastAttempt;
    if (last != null && now.difference(last) < _missRefetchEvery) {
      return;
    }
    _lastAttempt = now;
    await _load();
  }

  /// One fetch at a time: callers arriving while one is running share it.
  Future<bool> _load() {
    return _inFlight ??= _fetchAndStore().whenComplete(() {
      _inFlight = null;
    });
  }

  Future<bool> _fetchAndStore() async {
    final JwksResponse response;
    try {
      response = await _fetch();
    } on Object catch (error) {
      // A fetch that fails or times out leaves the cached set where it is.
      // Only the error class is kept: no log line names a URL or a body.
      // ignore: avoid_print
      print('account keyset fetch failed error=${error.runtimeType}');
      return false;
    }
    final Map<String, RSAPublicKey>? parsed = _parseKeySet(response.body);
    if (parsed == null || parsed.isEmpty) {
      // ignore: avoid_print
      print('account keyset fetch failed error=unreadable');
      return false;
    }
    _keys = parsed;
    _keysExpire = _clock.now.add(_ttlOf(response.cacheControl));
    return true;
  }

  Duration _ttlOf(String? cacheControl) {
    if (cacheControl == null) {
      return _defaultKeyTtl;
    }
    final RegExpMatch? match =
        RegExp(r'max-age\s*=\s*"?(\d{1,9})"?', caseSensitive: false)
            .firstMatch(cacheControl);
    final int? seconds = match == null ? null : int.tryParse(match.group(1)!);
    if (seconds == null) {
      return _defaultKeyTtl;
    }
    final Duration ttl = Duration(seconds: seconds);
    return ttl > _maxKeyTtl ? _maxKeyTtl : ttl;
  }

  Map<String, RSAPublicKey>? _parseKeySet(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final Object? list = decoded['keys'];
    if (list is! List<Object?>) {
      return null;
    }
    final Map<String, RSAPublicKey> keys = <String, RSAPublicKey>{};
    for (final Object? entry in list) {
      if (entry is! Map<String, Object?> || entry['kty'] != 'RSA') {
        continue;
      }
      final Object? id = entry['kid'];
      final Object? n = entry['n'];
      final Object? e = entry['e'];
      if (id is! String || n is! String || e is! String) {
        continue;
      }
      final Uint8List? nBytes = _decodeBytes(n);
      final Uint8List? eBytes = _decodeBytes(e);
      if (nBytes == null || eBytes == null || nBytes.isEmpty) {
        continue;
      }
      keys[id] = RSAPublicKey(_bigInt(nBytes), _bigInt(eBytes));
    }
    return keys;
  }

  BigInt _bigInt(Uint8List bytes) {
    BigInt value = BigInt.zero;
    for (final int byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }
}

class _KeyLookup {
  const _KeyLookup(this.key) : unavailable = false;
  const _KeyLookup.unavailable()
      : key = null,
        unavailable = true;

  final RSAPublicKey? key;
  final bool unavailable;
}

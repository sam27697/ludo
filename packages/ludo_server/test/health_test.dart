// Tests for `GET /health` against the frozen spec of work order 024. They
// are written from that spec, not from any implementation -- the endpoint,
// the `version` parameter on `WireServer` and the `roomCount` getter on
// `RoomRegistry` do not exist on this branch. That is expected: another
// worker builds the endpoint from the identical spec, on its own branch, and
// the two are merged and run together elsewhere. Until that merge, every
// test here fails at the request (there is no /health route to answer it, a
// GET falls through to the existing 404), and `dart analyze` reports two
// errors for the two frozen-API members this file calls that do not exist
// yet: `WireServer`'s `version` named parameter and `RoomRegistry.roomCount`.
// That is reported in this order's write-up, not worked around.
//
// No existing test file in this package opens a real WebSocket against a
// running `WireServer` (the other tests here are all direct calls against
// `RoomRegistry`, with no socket involved), so case 12 below has no existing
// helper to reuse. The connection helper here is the first one, not a
// second one competing with it.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

const RulesConfig _defaultRules = RulesConfig();

const Set<String> _healthKeys = <String>{
  'status',
  'version',
  'uptime_s',
  'rooms',
};

/// A base64-encoded 16 byte nonce, the shape `Sec-WebSocket-Key` requires.
/// Its value is never checked by anything below; the server is expected to
/// answer `/health` without attempting the handshake at all, so what this
/// looks like past "well-formed enough not to be rejected on shape" does not
/// matter.
const String _websocketKey = 'dGhlIHNhbXBsZSBub25jZQ==';

/// One running `WireServer`, its `FakeClock` and the registry it was built
/// with. `client` is the `HttpClient` a test drives it with; `test/main`'s
/// `tearDown` always closes both, so a failing test never leaks a listening
/// port or an open client connection into the next one.
class _Harness {
  _Harness._(this.clock, this.registry, this.server);

  final FakeClock clock;
  final RoomRegistry registry;
  final WireServer server;

  static _Harness build({String? version}) {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
    final RoomRegistry registry =
        RoomRegistry(clock: clock, secure: Random.secure());
    final RateLimiter rateLimiter = RateLimiter(clock: clock);
    final WireServer server = version == null
        ? WireServer(registry: registry, rateLimiter: rateLimiter, clock: clock)
        : WireServer(
            registry: registry,
            rateLimiter: rateLimiter,
            clock: clock,
            version: version,
          );
    return _Harness._(clock, registry, server);
  }

  Future<void> start() =>
      server.start(address: InternetAddress.loopbackIPv4, port: 0);

  Uri uri(String path) =>
      Uri(scheme: 'http', host: 'localhost', port: server.port, path: path);
}

CreateOk _createRoom(RoomRegistry registry, {required String name}) {
  final CreateResult result =
      registry.createRoom(name: name, players: 2, rules: _defaultRules);
  if (result is! CreateOk) {
    fail('expected CreateOk creating room "$name", got $result');
  }
  return result;
}

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

Future<Map<String, Object?>> _healthJson(
  HttpClient client,
  Uri uri,
) async {
  final HttpClientResponse response = await _send(client, uri);
  final String body = await _bodyOf(response);
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map<String, Object?>) {
    fail(
      'expected GET $uri to return a JSON object, got: '
      '${decoded.runtimeType} ($body)',
    );
  }
  return decoded;
}

void main() {
  late HttpClient client;
  _Harness? active;

  setUp(() {
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    if (active != null) {
      await active!.server.close();
      active = null;
    }
  });

  test('GET /health returns 200 with a JSON content-type', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response =
        await _send(client, harness.uri('/health'));
    await _bodyOf(response);

    expect(
      response.statusCode,
      200,
      reason: 'GET /health on a freshly started server must answer 200',
    );
    final String? contentType = response.headers.value('content-type');
    expect(
      contentType,
      contains('application/json'),
      reason: 'content-type header was "$contentType"',
    );
  });

  test('cache-control on /health is exactly no-store', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response =
        await _send(client, harness.uri('/health'));
    await _bodyOf(response);

    expect(
      response.headers.value('cache-control'),
      'no-store',
      reason: 'cache-control must be exactly "no-store", not a superset '
          'like "no-store, no-cache"',
    );
  });

  test('the body has exactly the four keys status, version, uptime_s, rooms',
      () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final Map<String, Object?> json =
        await _healthJson(client, harness.uri('/health'));

    expect(
      json.keys.toSet(),
      _healthKeys,
      reason: 'an extra or missing key must fail here, not leak quietly '
          'into a client that only checks the keys it expects; got keys '
          '${json.keys.toList()}',
    );
  });

  test('status is the literal string "ok"', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final Map<String, Object?> json =
        await _healthJson(client, harness.uri('/health'));

    expect(json['status'], 'ok');
  });

  test('version echoes the constructor argument', () async {
    final _Harness harness = _Harness.build(version: 'v-test-2026.08.28');
    active = harness;
    await harness.start();

    final Map<String, Object?> json =
        await _healthJson(client, harness.uri('/health'));

    expect(
      json['version'],
      'v-test-2026.08.28',
      reason: 'WireServer was built with version: "v-test-2026.08.28"',
    );
  });

  test('version defaults to "dev" when the constructor omits it', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final Map<String, Object?> json =
        await _healthJson(client, harness.uri('/health'));

    expect(
      json['version'],
      'dev',
      reason: 'WireServer was built with no version argument at all',
    );
  });

  test('uptime_s is 0 right after start and never negative', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final Map<String, Object?> json =
        await _healthJson(client, harness.uri('/health'));

    expect(
      json['uptime_s'],
      isA<int>(),
      reason:
          'uptime_s must be an integer, got ${json['uptime_s'].runtimeType}',
    );
    expect(json['uptime_s'], 0);
    expect(json['uptime_s']! as int, greaterThanOrEqualTo(0));
  });

  test('uptime_s tracks the injected FakeClock in whole seconds', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    harness.clock.advance(const Duration(seconds: 90));

    final Map<String, Object?> json =
        await _healthJson(client, harness.uri('/health'));

    expect(
      json['uptime_s'],
      isA<int>(),
      reason: 'uptime_s must stay an integer after the clock moves',
    );
    expect(
      json['uptime_s'],
      90,
      reason: 'clock was advanced by exactly 90 seconds after start()',
    );
    expect(json['uptime_s']! as int, greaterThanOrEqualTo(0));
  });

  test('rooms is 0 on a fresh registry', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final Map<String, Object?> json =
        await _healthJson(client, harness.uri('/health'));

    expect(json['rooms'], 0);
  });

  test('rooms equals the registry room count after rooms are created',
      () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    _createRoom(harness.registry, name: 'Alice');
    _createRoom(harness.registry, name: 'Bob');
    _createRoom(harness.registry, name: 'Carol');

    final Map<String, Object?> json =
        await _healthJson(client, harness.uri('/health'));

    expect(
      json['rooms'],
      3,
      reason: 'three rooms were created through RoomRegistry.createRoom '
          'and none of them were reaped or left',
    );
  });

  test('the raw body never contains a live room code', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final List<String> codes = <String>[
      _createRoom(harness.registry, name: 'Alice').room.code,
      _createRoom(harness.registry, name: 'Bob').room.code,
      _createRoom(harness.registry, name: 'Carol').room.code,
    ];

    final HttpClientResponse response =
        await _send(client, harness.uri('/health'));
    final String body = await _bodyOf(response);

    for (final String code in codes) {
      expect(
        body.contains(code),
        isFalse,
        reason: 'room code "$code" leaked into the /health body: $body',
      );
    }
  });

  test('POST /health returns 405 with allow: GET and an empty body', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      harness.uri('/health'),
      method: 'POST',
    );
    final String body = await _bodyOf(response);

    expect(response.statusCode, 405, reason: 'POST /health status');
    expect(response.headers.value('allow'), 'GET');
    expect(body, isEmpty, reason: 'POST /health body was "$body"');
  });

  test('DELETE /health also returns 405 with allow: GET and an empty body',
      () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      harness.uri('/health'),
      method: 'DELETE',
    );
    final String body = await _bodyOf(response);

    expect(response.statusCode, 405, reason: 'DELETE /health status');
    expect(response.headers.value('allow'), 'GET');
    expect(body, isEmpty, reason: 'DELETE /health body was "$body"');
  });

  test('/healthz is not the health endpoint', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response =
        await _send(client, harness.uri('/healthz'));
    await _bodyOf(response);

    expect(
      response.statusCode,
      404,
      reason: '/healthz must fall through to the existing non-upgrade '
          '404, not be treated as /health',
    );
  });

  test('/health/ (trailing slash) is not the health endpoint', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response =
        await _send(client, harness.uri('/health/'));
    await _bodyOf(response);

    expect(
      response.statusCode,
      404,
      reason: '/health/ must fall through to the existing non-upgrade '
          '404, not be treated as /health',
    );
  });

  test('/Health (wrong case) is not the health endpoint', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response =
        await _send(client, harness.uri('/Health'));
    await _bodyOf(response);

    expect(
      response.statusCode,
      404,
      reason: '/Health must fall through to the existing non-upgrade '
          '404, not be treated as /health -- the path match is '
          'case-sensitive',
    );
  });

  test('GET /health with WebSocket upgrade headers still answers 200 JSON',
      () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    final HttpClientResponse response = await _send(
      client,
      harness.uri('/health'),
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
      reason: '/health must never upgrade, even with upgrade headers set; '
          'got status ${response.statusCode} with body "$body"',
    );
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      fail('expected a JSON object body, got: $body');
    }
    expect(decoded.keys.toSet(), _healthKeys);
    expect(decoded['status'], 'ok');
  });

  test('a real WebSocket connection to / still works alongside /health',
      () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();

    // Exercise /health first, on the same running server, before opening
    // the socket -- the point of this case is that adding the health route
    // has not broken the pre-existing upgrade path it sits next to.
    final HttpClientResponse healthResponse =
        await _send(client, harness.uri('/health'));
    await _bodyOf(healthResponse);

    final WebSocket socket =
        await WebSocket.connect('ws://127.0.0.1:${harness.server.port}/');
    try {
      expect(
        socket.readyState,
        WebSocket.open,
        reason: 'a plain WebSocket upgrade to / must still succeed after '
            '/health has been added',
      );
    } finally {
      await socket.close();
    }
  });
}

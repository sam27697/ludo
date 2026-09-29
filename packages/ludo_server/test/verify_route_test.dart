// Tests for docs/VERIFY.md section 4 (the routes) and the body-level
// requirements of section 5 (the page), against a real WireServer on an
// ephemeral port, the way test/health_test.dart and
// test/app_links_route_test.dart start one. This file builds its own
// harness (below) rather than editing test/support/wire_harness.dart, per
// the order.
//
// Every "found" fixture is written straight into the registry's own
// VerifyStore with save(), bypassing RoomRegistry/the wire protocol
// entirely -- the order's own instruction, since this file tests the route
// and the page, not how a record gets produced. One fixture's seed field
// deliberately contains "</script><b>": the page must not trust the store,
// so it must escape that content wherever it renders it, exactly as if a
// hostile value had made it into a legitimate record some other way.
//
// A note on "the not-found answer of the row it most resembles" (section
// 4's own words for anything that fails isWellFormedGameId): the spec does
// not pin, for every single malformed path, which of the two not-found
// shapes (the HTML page's or the .json endpoint's) it must take. This file
// resolves that per case, documented at each one: anything with no ".json"
// (or ".JSON") suffix at all resembles the plain page row; anything ending
// in some case-insensitive spelling of ".json" resembles the .json row.
// That is this file's own interpretation, not a literal quote from
// docs/VERIFY.md, and is called out again in this order's final report.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// The exact Content-Security-Policy value docs/VERIFY.md section 4 pins
/// for the HTML page.
const String _expectedCsp = "default-src 'none'; script-src 'self'; "
    "style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
    "frame-ancestors 'none'";

/// A well-formed (16 lowercase hex) id that a fixture record is saved
/// under.
const String _foundId = 'a1b2c3d4e5f60718';

/// A well-formed id that is never saved under -- the "unknown well-formed
/// id" case.
const String _unknownId = 'ffffffffffffffff';

/// A well-formed id whose fixture record's seed deliberately contains a
/// script-closing payload.
const String _xssId = 'deadbeefcafef00d';

String _hexRun(String ch, int n) => List<String>.filled(n, ch).join();

/// A record in the exact shape of docs/VERIFY.md section 1.1. Every value
/// is fabricated (this file never plays a real game); the route and the
/// page only ever render whatever is in the store, so nothing here needs
/// to be cryptographically real.
Map<String, Object?> _fixtureRecord({
  required String gameId,
  required int winner,
  String? seedOverride,
}) {
  return <String, Object?>{
    'format': 1,
    'game_id': gameId,
    'chain_commit': _hexRun('c', 64),
    'chain_index': 0,
    'chain_length': 4096,
    'client_seeds': '0:${seedOverride ?? 'alpha-route-seed'}|1:beta-route-seed',
    'seeds': <Map<String, Object?>>[
      <String, Object?>{
        'seat': 0,
        'seed': seedOverride ?? 'alpha-route-seed',
        'origin': 'player',
      },
      <String, Object?>{
        'seat': 1,
        'seed': 'beta-route-seed',
        'origin': 'server'
      },
    ],
    'rolls': <Map<String, Object?>>[
      <String, Object?>{
        'k': 1,
        'seat': 0,
        'reveal': _hexRun('d', 64),
        'die': 3
      },
      <String, Object?>{
        'k': 2,
        'seat': 1,
        'reveal': _hexRun('e', 64),
        'die': 5
      },
      <String, Object?>{
        'k': 3,
        'seat': 0,
        'reveal': _hexRun('f', 64),
        'die': 1
      },
    ],
    'winner': winner,
    'finished_at': '2026-05-01T00:00:00Z',
  };
}

/// One running WireServer, its FakeClock, registry and VerifyStore. Built
/// fresh per test; nothing here is shared with, or edits, test/support/.
class _Harness {
  _Harness._(this.clock, this.registry, this.verifyStore, this.server);

  final FakeClock clock;
  final RoomRegistry registry;
  final VerifyStore verifyStore;
  final WireServer server;

  static _Harness build({String verifyUrlBase = defaultVerifyUrlBase}) {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 5, 1));
    final MemoryVerifyStore store = MemoryVerifyStore(clock);
    final RoomRegistry registry = RoomRegistry(
      clock: clock,
      secure: Random.secure(),
      verifyStore: store,
      verifyUrlBase: verifyUrlBase,
    );
    final RateLimiter rateLimiter = RateLimiter(clock: clock);
    final WireServer server = WireServer(
      registry: registry,
      rateLimiter: rateLimiter,
      clock: clock,
    );
    return _Harness._(clock, registry, store, server);
  }

  Future<void> start() =>
      server.start(address: InternetAddress.loopbackIPv4, port: 0);

  Uri uri(String path) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path);

  Future<void> close() => server.close();
}

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

/// Extracts the inner text of `<script type="application/json"
/// id="record">...</script>` from [html], reversing the one escaping
/// docs/VERIFY.md section 5 pins for it ("< written as &lt;"), and returns
/// it JSON-decoded.
Map<String, Object?> _decodeEmbeddedRecord(String html) {
  final RegExp pattern = RegExp(
    r'<script type="application/json" id="record">(.*?)</script>',
    dotAll: true,
  );
  final Match? match = pattern.firstMatch(html);
  if (match == null) {
    fail(
      'expected a <script type="application/json" id="record"> element '
      'somewhere in the page; full body: $html',
    );
  }
  final String inner = match.group(1)!;
  final String unescaped = inner.replaceAll('&lt;', '<');
  return jsonDecode(unescaped)! as Map<String, Object?>;
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
      await active!.close();
      active = null;
    }
  });

  group('GET /v/<id>: found', () {
    test(
        '200, text/html; charset=utf-8, cache-control public max-age=300, '
        'nosniff, no-referrer and the pinned CSP', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final Map<String, Object?> record =
          _fixtureRecord(gameId: _foundId, winner: 1);
      harness.verifyStore.save(_foundId, jsonEncode(record));

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-type'),
        'text/html; charset=utf-8',
      );
      expect(response.headers.value('cache-control'), 'public, max-age=300');
      expect(response.headers.value('x-content-type-options'), 'nosniff');
      expect(response.headers.value('referrer-policy'), 'no-referrer');
      expect(response.headers.value('content-security-policy'), _expectedCsp);
      expect(body, isNotEmpty);
    });

    test('the game id, chain_commit, every reveal, and "Seat <winner>" appear',
        () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final Map<String, Object?> record =
          _fixtureRecord(gameId: _foundId, winner: 1);
      harness.verifyStore.save(_foundId, jsonEncode(record));

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      expect(body.contains(_foundId), isTrue,
          reason: 'expected the game id in the page; body: $body');
      expect(body.contains(record['chain_commit']! as String), isTrue,
          reason: 'expected chain_commit in the page; body: $body');
      for (final Map<String, Object?> roll
          in (record['rolls']! as List<Object?>).cast<Map<String, Object?>>()) {
        expect(body.contains(roll['reveal']! as String), isTrue,
            reason: 'expected reveal for k=${roll['k']} in the page; body: '
                '$body');
      }
      expect(body.contains('Seat 1'), isTrue,
          reason: 'expected the winning seat rendered as "Seat 1"; body: '
              '$body');
    });

    test(
        'the retention sentence ("kept for 90 days") appears, and the '
        'forbidden words never appear, case-insensitively', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final Map<String, Object?> record =
          _fixtureRecord(gameId: _foundId, winner: 0);
      harness.verifyStore.save(_foundId, jsonEncode(record));

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);
      final String lower = body.toLowerCase();

      expect(lower.contains('kept for 90 days'), isTrue,
          reason: 'expected the retention sentence somewhere in the page '
              '("This record is kept for 90 days after the game ends."); '
              'body: $body');
      for (final String forbidden in <String>[
        'provably fair',
        'absolutely random',
        'odds',
        'bet ',
        'wager',
      ]) {
        expect(lower.contains(forbidden), isFalse,
            reason: 'the forbidden word/phrase "$forbidden" must never '
                'appear on the page (docs/FAIRNESS.md section 0); body: '
                '$body');
      }
    });

    test(
        'ships <script src="/v/verify.js"> and a <script '
        'type="application/json" id="record"> whose content, JSON-decoded, '
        'equals the record', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final Map<String, Object?> record =
          _fixtureRecord(gameId: _foundId, winner: 1);
      harness.verifyStore.save(_foundId, jsonEncode(record));

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId'));
      final String body = await _bodyOf(response);

      expect(body.contains('<script src="/v/verify.js">'), isTrue,
          reason: 'expected the verify.js script tag; body: $body');
      final Map<String, Object?> decoded = _decodeEmbeddedRecord(body);
      expect(decoded, record);
    });

    test(
        'a seed field containing "</script><b>" is neutralised on the '
        'page, and the embedded record still decodes to the real seed '
        'string (the page must not trust the store)', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      const String hostileSeed = '</script><b>';
      final Map<String, Object?> record = _fixtureRecord(
        gameId: _xssId,
        winner: 0,
        seedOverride: hostileSeed,
      );
      // Written directly with save(), bypassing the registry entirely: this
      // is testing the page, not whether the registry would ever itself
      // produce such a record.
      harness.verifyStore.save(_xssId, jsonEncode(record));

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_xssId'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 200);
      expect(
        body.contains('</script><b>'),
        isFalse,
        reason: 'the literal payload must not survive anywhere in the '
            'rendered page unescaped; body: $body',
      );
      final Map<String, Object?> decoded = _decodeEmbeddedRecord(body);
      expect(decoded, record,
          reason: 'the embedded record must still decode to the exact '
              'original record once its escaping is reversed');
    });
  });

  test(
      'GET /v/<id>.json: found, 200, application/json, '
      'access-control-allow-origin: *, cache-control public max-age=300, '
      'and the body is byte-for-byte the saved string', () async {
    final _Harness harness = _Harness.build();
    active = harness;
    await harness.start();
    final String savedJson = jsonEncode(
      _fixtureRecord(gameId: _foundId, winner: 1),
    );
    harness.verifyStore.save(_foundId, savedJson);

    final HttpClientResponse response =
        await _send(client, harness.uri('/v/$_foundId.json'));
    final String body = await _bodyOf(response);

    expect(response.statusCode, 200);
    expect(response.headers.value('content-type'), 'application/json');
    expect(response.headers.value('access-control-allow-origin'), '*');
    expect(response.headers.value('cache-control'), 'public, max-age=300');
    expect(response.headers.value('x-content-type-options'), 'nosniff');
    expect(response.headers.value('referrer-policy'), 'no-referrer');
    expect(body, savedJson,
        reason: 'the .json answer must be byte-for-byte the exact string '
            'that was saved, not a re-encoding of it');
  });

  group('GET /v/verify.js and /v/verify.py', () {
    test(
        'verify.js: 200, text/javascript; charset=utf-8, cache-control '
        'public max-age=300', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/verify.js'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-type'),
        'text/javascript; charset=utf-8',
      );
      expect(response.headers.value('cache-control'), 'public, max-age=300');
      expect(response.headers.value('x-content-type-options'), 'nosniff');
      expect(response.headers.value('referrer-policy'), 'no-referrer');
      expect(body, verifyJsSource);
    });

    test(
        'verify.py: 200, text/x-python; charset=utf-8, cache-control '
        'public max-age=300', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/verify.py'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-type'),
        'text/x-python; charset=utf-8',
      );
      expect(response.headers.value('cache-control'), 'public, max-age=300');
      expect(response.headers.value('x-content-type-options'), 'nosniff');
      expect(response.headers.value('referrer-policy'), 'no-referrer');
      expect(body, verifyPySource);
    });
  });

  group('GET /v/<id>: not found or malformed', () {
    test(
        'unknown well-formed id, page: 404, text/html; charset=utf-8, '
        'cache-control no-store, mentions no record and 90 days', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_unknownId'));
      final String body = await _bodyOf(response);
      final String lower = body.toLowerCase();

      expect(response.statusCode, 404);
      expect(
        response.headers.value('content-type'),
        'text/html; charset=utf-8',
      );
      expect(response.headers.value('cache-control'), 'no-store');
      expect(response.headers.value('x-content-type-options'), 'nosniff');
      expect(response.headers.value('referrer-policy'), 'no-referrer');
      expect(lower.contains('no record'), isTrue,
          reason: 'expected the not-found page to say there is no record '
              'for this id; body: $body');
      expect(lower.contains('90 days'), isTrue,
          reason: 'expected the not-found page to state the retention '
              'period; body: $body');
    });

    test(
        'unknown well-formed id, .json: 404, application/json, '
        '{"error":"not_found"}, cache-control no-store', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_unknownId.json'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(response.headers.value('content-type'), 'application/json');
      expect(response.headers.value('cache-control'), 'no-store');
      expect(body, '{"error":"not_found"}');
    });

    test(
        'upper-case id (bare, no .json): never touches the store; treated '
        'as the page row -- 404, text/html; charset=utf-8', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      // If this ever touched the store, it would find a real record: the
      // saved id below is the lower-case form of the upper-case one
      // requested.
      harness.verifyStore.save(
        _foundId,
        jsonEncode(_fixtureRecord(gameId: _foundId, winner: 0)),
      );

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/${_foundId.toUpperCase()}'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(
        response.headers.value('content-type'),
        'text/html; charset=utf-8',
      );
      expect(response.headers.value('cache-control'), 'no-store');
      expect(
        body.contains(_foundId),
        isFalse,
        reason: 'an upper-case id must never resolve to the lower-case '
            'record; body: $body',
      );
    });

    test(
        'upper-case id with .json: never touches the store; treated as '
        'the .json row -- 404, application/json, not_found', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      harness.verifyStore.save(
        _foundId,
        jsonEncode(_fixtureRecord(gameId: _foundId, winner: 0)),
      );

      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/${_foundId.toUpperCase()}.json'),
      );
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(response.headers.value('content-type'), 'application/json');
      expect(body, '{"error":"not_found"}');
    });

    test('/v/ (bare, no id): 404, treated as the page row', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(
        response.headers.value('content-type'),
        'text/html; charset=utf-8',
      );
      expect(response.headers.value('cache-control'), 'no-store');
      expect(body, isNotEmpty);
    });

    test('/v/<id>/ (trailing slash): 404, treated as the page row', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      final Map<String, Object?> record =
          _fixtureRecord(gameId: _foundId, winner: 0);
      harness.verifyStore.save(_foundId, jsonEncode(record));

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId/'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(
        response.headers.value('content-type'),
        'text/html; charset=utf-8',
      );
      expect(response.headers.value('cache-control'), 'no-store');
      expect(
        body.contains(record['chain_commit']! as String),
        isFalse,
        reason: 'a trailing slash must never resolve to the saved record; '
            'body: $body',
      );
    });

    test(
        '/v/%2e%2e%2fx (an encoded slash / traversal-shaped path): 404, '
        'treated as the page row', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/%2e%2e%2fx'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(
        response.headers.value('content-type'),
        'text/html; charset=utf-8',
      );
      expect(response.headers.value('cache-control'), 'no-store');
      expect(body, isNotEmpty);
    });

    test(
        '/v/<id>.JSON (wrong case of the extension): 404, treated as the '
        '.json row', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      harness.verifyStore.save(
        _foundId,
        jsonEncode(_fixtureRecord(gameId: _foundId, winner: 0)),
      );

      final HttpClientResponse response =
          await _send(client, harness.uri('/v/$_foundId.JSON'));
      final String body = await _bodyOf(response);

      expect(response.statusCode, 404);
      expect(response.headers.value('content-type'), 'application/json');
      expect(body, '{"error":"not_found"}');
    });
  });

  group('HEAD: same status and headers as GET, empty body', () {
    Future<void> expectHeadMatchesGet(_Harness harness, String path) async {
      final HttpClientResponse getResponse =
          await _send(client, harness.uri(path));
      final String getBody = await _bodyOf(getResponse);

      final HttpClientResponse headResponse =
          await _send(client, harness.uri(path), method: 'HEAD');
      final String headBody = await _bodyOf(headResponse);

      expect(headResponse.statusCode, getResponse.statusCode,
          reason: 'HEAD $path status must match GET $path\'s');
      expect(
        headResponse.headers.value('content-type'),
        getResponse.headers.value('content-type'),
        reason: 'HEAD $path content-type must match GET $path\'s',
      );
      expect(
        headResponse.headers.value('cache-control'),
        getResponse.headers.value('cache-control'),
        reason: 'HEAD $path cache-control must match GET $path\'s',
      );
      expect(headBody, isEmpty,
          reason: 'HEAD $path must answer with an empty body; got '
              '"$headBody" (GET body was "$getBody")');
    }

    test('HEAD /v/<id> (found page)', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      harness.verifyStore.save(
        _foundId,
        jsonEncode(_fixtureRecord(gameId: _foundId, winner: 0)),
      );
      await expectHeadMatchesGet(harness, '/v/$_foundId');
    });

    test('HEAD /v/<id>.json (found json)', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      harness.verifyStore.save(
        _foundId,
        jsonEncode(_fixtureRecord(gameId: _foundId, winner: 0)),
      );
      await expectHeadMatchesGet(harness, '/v/$_foundId.json');
    });

    test('HEAD /v/verify.js', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      await expectHeadMatchesGet(harness, '/v/verify.js');
    });

    test('HEAD /v/<unknown id> (not found page)', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      await expectHeadMatchesGet(harness, '/v/$_unknownId');
    });
  });

  group('POST: 405 with allow: GET, HEAD', () {
    test('POST /v/<id>', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();
      harness.verifyStore.save(
        _foundId,
        jsonEncode(_fixtureRecord(gameId: _foundId, winner: 0)),
      );

      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/$_foundId'),
        method: 'POST',
      );
      final String body = await _bodyOf(response);

      expect(response.statusCode, 405);
      expect(response.headers.value('allow'), 'GET, HEAD');
      expect(body, isEmpty);
    });

    test('POST /v/verify.js', () async {
      final _Harness harness = _Harness.build();
      active = harness;
      await harness.start();

      final HttpClientResponse response = await _send(
        client,
        harness.uri('/v/verify.js'),
        method: 'POST',
      );
      final String body = await _bodyOf(response);

      expect(response.statusCode, 405);
      expect(response.headers.value('allow'), 'GET, HEAD');
      expect(body, isEmpty);
    });
  });
}

// Pins `docs/PROTOCOL.md` section 7's client-IP rule over the real wire:
// "IP" is the immediate TCP peer address unless that peer is listed in the
// server's TRUSTED_PROXIES, in which case it is the leftmost address in
// X-Forwarded-For (the peer address when that header is absent or empty).
// A header from a peer not in the list is never read.
//
// Every case here opens a real WebSocket against a real, running
// `WireServer` through `ServerHarness` (`support/wire_harness.dart`), with
// an `X-Forwarded-For` header set on the upgrade request the way a real
// reverse proxy or a spoofing client would set it -- `dart:io`'s
// `WebSocket.connect` takes `headers` for exactly this. `ServerHarness`
// does not expose a client that can set upgrade headers, so this file
// dials the socket directly rather than through `WireTestClient`; only
// the harness's own `trustedProxies` constructor argument is reused.
//
// Written from the spec quoted in work order 197, not from a reading of
// `lib/src/wire_server.dart`. W5 is expected to fail on today's source for
// the same counted-refusal reason `rate_limit_test.dart`'s R3 documents;
// order 198 fixes it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/wire_harness.dart';

/// The header name a real reverse proxy sets, spelled the way a human
/// would type it. `HttpHeaders` (both sides of this connection) treats
/// header names case-insensitively, and `shelf.Request.headers` is built
/// on top of it, so this casing is not itself part of what any case here
/// tests.
const String _forwardedForHeader = 'X-Forwarded-For';

/// A minimal `create_room` payload that a real client could send and that
/// `RoomRegistry.createRoom` accepts unconditionally: a non-empty name and
/// a valid seat count. What matters to every case in this file is only
/// whether the attempt is admitted by the rate limiter, never anything
/// about the room it produces.
const Map<String, Object?> _validCreateRoomPayload = <String, Object?>{
  'name': 'Probe',
  'players': 2,
};

/// Opens one WebSocket to [uri] with [headers] on the upgrade request,
/// sends a single `create_room` with [_validCreateRoomPayload], reads
/// frames off that socket until either a `room` or an `error` frame
/// arrives (skipping over `seat_assigned`, which precedes `room` on an
/// admitted attempt and never arrives on a refused one), then closes the
/// socket. [id] only has to be well-formed and is never asserted on: every
/// case here asserts on `t` and `d.code`, never on message ids.
Future<Map<String, Object?>> _createRoomOverWire(
  Uri uri, {
  Map<String, String>? headers,
  required String id,
}) async {
  final WebSocket socket = await WebSocket.connect(
    uri.toString(),
    headers: headers,
  );
  try {
    socket.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': 'create_room',
      'id': id,
      'd': _validCreateRoomPayload,
    }));
    final Map<String, Object?> frame = await socket
        .map(
          (Object? raw) => jsonDecode(raw! as String) as Map<String, Object?>,
        )
        .firstWhere(
          (Map<String, Object?> f) => f['t'] == 'room' || f['t'] == 'error',
        )
        .timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TestFailure(
            'expected a "room" or "error" frame answering create_room '
            '(id=$id, headers=$headers) and neither arrived within 3s',
          ),
        );
    return frame;
  } finally {
    if (socket.readyState == WebSocket.open) {
      await socket.close();
    }
  }
}

/// Asserts [frame] is the successful `room` reply to `create_room`.
void _expectRoomAdmitted(Map<String, Object?> frame,
    {required String because}) {
  expect(
    frame['t'],
    'room',
    reason: 'expected create_room to be admitted ($because) but got a '
        '"${frame['t']}" frame instead: ${frame['d']}',
  );
}

/// Asserts [frame] is an `error` frame carrying `RATE_LIMITED`.
void _expectRateLimited(Map<String, Object?> frame, {required String because}) {
  if (frame['t'] != 'error') {
    throw TestFailure(
      'expected create_room to be refused with RATE_LIMITED ($because) but '
      'got a "${frame['t']}" frame instead: ${frame['d']}',
    );
  }
  final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
  expect(
    data['code'],
    'RATE_LIMITED',
    reason: 'expected error code RATE_LIMITED ($because) but got '
        '${data['code']} (message: "${data['message']}")',
  );
}

void main() {
  ServerHarness? active;
  int idCounter = 0;

  String nextId() => 'client-ip-probe-${++idCounter}';

  tearDown(() async {
    if (active != null) {
      await active!.close();
      active = null;
    }
  });

  test(
      'W1: untrusted peer (shipped default) -- X-Forwarded-For is never '
      'read, the loopback peer is the IP for every attempt', () async {
    final ServerHarness harness = ServerHarness.build();
    active = harness;
    await harness.start();

    for (int i = 1; i <= 5; i++) {
      final Map<String, Object?> frame = await _createRoomOverWire(
        harness.wsUri,
        headers: <String, String>{_forwardedForHeader: '203.0.113.1'},
        id: nextId(),
      );
      _expectRoomAdmitted(
        frame,
        because: 'attempt $i, no trusted proxy configured, so the loopback '
            'peer -- not the forged 203.0.113.1 header -- is the IP, and '
            'this is only the ${i}th attempt from that peer',
      );
    }

    final Map<String, Object?> sixth = await _createRoomOverWire(
      harness.wsUri,
      headers: <String, String>{_forwardedForHeader: '203.0.113.2'},
      id: nextId(),
    );
    _expectRateLimited(
      sixth,
      because: 'the sixth attempt claims a different forwarded address '
          '(203.0.113.2), but with no trusted proxy configured the header '
          'must never be read: the real IP is still the loopback peer, '
          'which has now sent six attempts',
    );
  });

  test(
      'W2: trusted peer -- X-Forwarded-For is believed, and scopes the '
      'limit by the forwarded address, not the peer', () async {
    final ServerHarness harness =
        ServerHarness.build(trustedProxies: <String>{'127.0.0.1'});
    active = harness;
    await harness.start();

    for (int i = 1; i <= 5; i++) {
      final Map<String, Object?> frame = await _createRoomOverWire(
        harness.wsUri,
        headers: <String, String>{_forwardedForHeader: '203.0.113.1'},
        id: nextId(),
      );
      _expectRoomAdmitted(
        frame,
        because: 'attempt $i for forwarded address 203.0.113.1, from a '
            'trusted peer, is only the ${i}th for that address',
      );
    }

    final Map<String, Object?> otherAddress = await _createRoomOverWire(
      harness.wsUri,
      headers: <String, String>{_forwardedForHeader: '203.0.113.2'},
      id: nextId(),
    );
    _expectRoomAdmitted(
      otherAddress,
      because: 'a different forwarded address (203.0.113.2) has its own '
          'bucket and has sent nothing yet, even though 203.0.113.1 is '
          'exhausted and both attempts came from the same trusted peer',
    );

    final Map<String, Object?> sixthForFirstAddress = await _createRoomOverWire(
      harness.wsUri,
      headers: <String, String>{_forwardedForHeader: '203.0.113.1'},
      id: nextId(),
    );
    _expectRateLimited(
      sixthForFirstAddress,
      because: '203.0.113.1 has now sent six attempts through a trusted '
          'peer, one past its five-per-hour limit',
    );
  });

  test(
      'W3: trusted peer, multiple forwarded addresses -- the leftmost one '
      'counts', () async {
    final ServerHarness harness =
        ServerHarness.build(trustedProxies: <String>{'127.0.0.1'});
    active = harness;
    await harness.start();

    for (int i = 1; i <= 5; i++) {
      final Map<String, Object?> frame = await _createRoomOverWire(
        harness.wsUri,
        headers: <String, String>{
          _forwardedForHeader: '203.0.113.7, 10.0.0.1',
        },
        id: nextId(),
      );
      _expectRoomAdmitted(
        frame,
        because: 'attempt $i, forwarded as "203.0.113.7, 10.0.0.1" from a '
            'trusted peer: the leftmost address, 203.0.113.7, is the IP, '
            'and this is only the ${i}th attempt for it',
      );
    }

    final Map<String, Object?> sixth = await _createRoomOverWire(
      harness.wsUri,
      headers: <String, String>{_forwardedForHeader: '203.0.113.7'},
      id: nextId(),
    );
    _expectRateLimited(
      sixth,
      because: '203.0.113.7 alone is the same effective IP as '
          '"203.0.113.7, 10.0.0.1" -- the leftmost address is all that '
          'ever counted -- and this is its sixth attempt',
    );
  });

  test(
      'W4: trusted peer, no X-Forwarded-For header -- falls back to the '
      'peer address', () async {
    final ServerHarness harness =
        ServerHarness.build(trustedProxies: <String>{'127.0.0.1'});
    active = harness;
    await harness.start();

    for (int i = 1; i <= 5; i++) {
      final Map<String, Object?> frame = await _createRoomOverWire(
        harness.wsUri,
        id: nextId(),
      );
      _expectRoomAdmitted(
        frame,
        because: 'attempt $i, no X-Forwarded-For header at all, from a '
            'trusted peer: the IP falls back to the peer address, and '
            'this is only the ${i}th attempt from it',
      );
    }

    final Map<String, Object?> sixth = await _createRoomOverWire(
      harness.wsUri,
      id: nextId(),
    );
    _expectRateLimited(
      sixth,
      because: 'the peer address (the fallback IP with no header) has now '
          'sent six attempts',
    );

    final Map<String, Object?> otherAddress = await _createRoomOverWire(
      harness.wsUri,
      headers: <String, String>{_forwardedForHeader: '203.0.113.9'},
      id: nextId(),
    );
    _expectRoomAdmitted(
      otherAddress,
      because: 'forwarded address 203.0.113.9 has its own bucket and has '
          'sent nothing yet, even though the peer address (used when no '
          'header is sent) is exhausted',
    );
  });

  test(
      'W5 (order 198): the realistic retry over the wire -- RED on '
      'today\'s source, which records refused attempts', () async {
    final ServerHarness harness =
        ServerHarness.build(trustedProxies: <String>{'127.0.0.1'});
    active = harness;
    await harness.start();

    // Five admitted attempts, ten minutes apart, exactly as
    // rate_limit_test.dart's R4 spaces them: t0, t0+10, ..., t0+40. The
    // spacing matters here, not just the count -- see the reasoning on
    // the final assertion below for why a same-instant five would not
    // actually exercise the bug this case exists to catch.
    for (int i = 0; i < 5; i++) {
      if (i > 0) {
        harness.clock.advance(const Duration(minutes: 10));
      }
      final Map<String, Object?> frame = await _createRoomOverWire(
        harness.wsUri,
        headers: <String, String>{_forwardedForHeader: '203.0.113.1'},
        id: nextId(),
      );
      _expectRoomAdmitted(
        frame,
        because: 'setting up: admitted attempt ${i + 1} for 203.0.113.1, at '
            'minute ${10 * i} after the first',
      );
    }

    // Three refused attempts -- a host tapping Create while limited --
    // at t0+45, t0+50 and t0+55: after the fifth admitted attempt
    // (t0+40) and before the one-hour mark from the first (t0+60).
    for (int i = 0; i < 3; i++) {
      harness.clock.advance(const Duration(minutes: 5));
      final Map<String, Object?> frame = await _createRoomOverWire(
        harness.wsUri,
        headers: <String, String>{_forwardedForHeader: '203.0.113.1'},
        id: nextId(),
      );
      _expectRateLimited(
        frame,
        because: 'setting up: refused attempt ${i + 1} for 203.0.113.1, '
            'a host tapping Create while limited, at minute '
            '${40 + 5 * (i + 1)} after the first admitted attempt',
      );
    }

    // Elapsed so far: 55 minutes since the first admitted attempt.
    // Advance the remaining 5 minutes so that exactly one hour has
    // passed since it.
    harness.clock.advance(const Duration(minutes: 5));

    final Map<String, Object?> retry = await _createRoomOverWire(
      harness.wsUri,
      headers: <String, String>{_forwardedForHeader: '203.0.113.1'},
      id: nextId(),
    );
    _expectRoomAdmitted(
      retry,
      because: 'docs/PROTOCOL.md section 7: a host who keeps tapping '
          'Create while limited must not push their own wait further '
          'out. One hour has passed since the first of the five admitted '
          'attempts, so it has aged out and this attempt must be '
          'admitted, regardless of the three refused attempts in '
          'between. On today\'s source this is expected to answer '
          'RATE_LIMITED instead: the three refused attempts above were '
          'also recorded (each between 15 and 5 minutes old at this '
          'point) and have not yet aged out, so far more than five '
          'attempts still sit inside the window even after the first '
          'admitted one expires. See work order 197/198.',
    );
  });
}

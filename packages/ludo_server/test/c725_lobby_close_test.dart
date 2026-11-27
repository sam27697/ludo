// Conformance tests for docs/PROTOCOL.md section 37 (X240): a LOBBY that has
// waited 10 minutes since Room.lifetimeStartedAt is closed, whether or not a
// seat is connected, and every socket still in it is told with one
// `room_closed` push. Written from section 37 and its item 5 only.
//
// Everything runs over a real WireServer with real sockets and a FakeClock.
// The sweep is driven by ServerHarness.clock.advance(...) followed by one
// housekeeping pass of the WireServer (`_sweep` below). Section 37 item 2
// puts the frame at "the housekeeping sweep that removes such a room", and
// the WireServer's sweep is a private method on a real one minute timer, so
// a deterministic test needs a public once-only entry point, the way
// `runTurnExpiryOnce()` is for the turn sweep. The one name needed is
// `WireServer.runHousekeepingOnce()`; until it exists `_sweep` fails with a
// message saying so. One test (the last group) waits for the real timer.
//
// Waiting: no sleeps. "Nothing else arrived" is proved with a ping barrier:
// the server answers one socket's frames in order, so every frame queued for
// it before the pong is read before the pong. Section 37 item 2 says the
// socket is not closed, so ping still gets a pong after the room is gone.
//
// Reproduce any failure by name: every message carries the scenario label
// and the clock offsets, the whole run is deterministic (FakeClock, no seed).

import 'dart:convert';
import 'dart:io';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

const Duration _min9s59 = Duration(minutes: 9, seconds: 59);
const Duration _sec1 = Duration(seconds: 1);

/// Sends a ping on [c] and returns every frame that arrived before its pong,
/// in order, pong excluded.
Future<List<Map<String, Object?>>> _drainToPong(
    WireTestClient c, String label) async {
  final String id = c.send('ping', <String, Object?>{});
  final List<Map<String, Object?>> seen = <Map<String, Object?>>[];
  for (int i = 0; i < 12; i++) {
    final Map<String, Object?> f =
        await c.next(timeout: const Duration(seconds: 3));
    if (f['t'] == 'pong' && f['re'] == id) {
      return seen;
    }
    seen.add(f);
  }
  throw TestFailure('[$label] no pong for ping $id after 12 frames; '
      'frames before: ${jsonEncode(seen)}');
}

List<Map<String, Object?>> _closed(List<Map<String, Object?>> frames) =>
    <Map<String, Object?>>[
      for (final Map<String, Object?> f in frames)
        if (f['t'] == 'room_closed') f
    ];

void _expectOneCloseOnly(
    List<Map<String, Object?>> frames, String who, String label) {
  expect(frames.length, 1,
      reason: '[$label] $who must get exactly one frame (room_closed) and '
          'nothing else before the ping barrier; got ${jsonEncode(frames)}');
  final Map<String, Object?> f = frames.single;
  expect(f['t'], 'room_closed',
      reason: '[$label] $who: expected t=room_closed, got ${jsonEncode(f)}');
  expect(f['d'], <String, Object?>{'reason': 'lobby_timeout'},
      reason: '[$label] $who: section 37 item 2 pins d exactly '
          '{"reason":"lobby_timeout"}; got ${jsonEncode(f['d'])}');
  expect(f.containsKey('seq'), isFalse,
      reason:
          '[$label] $who: room_closed carries no seq; got ${jsonEncode(f)}');
  expect(f.containsKey('re'), isFalse,
      reason: '[$label] $who: room_closed carries no re; got ${jsonEncode(f)}');
}

/// One housekeeping pass of the server under test; returns how many rooms it
/// removed. Needs `WireServer.runHousekeepingOnce()` (see the file header).
Future<int> _sweep(ServerHarness h) async {
  final int before = h.registry.roomCount;
  try {
    (h.server as dynamic).runHousekeepingOnce();
  } on NoSuchMethodError {
    throw TestFailure('WireServer has no runHousekeepingOnce(): section 37 '
        'item 2 sends room_closed at the housekeeping sweep, which is only '
        'reachable on a real one minute timer without it. Need a public '
        'synchronous hook running the same pass as the timer.');
  }
  return before - h.registry.roomCount;
}

Future<Map<String, Object?>> _health(ServerHarness h) async {
  final HttpClient http = HttpClient();
  try {
    final HttpClientRequest req = await http
        .getUrl(Uri.parse('http://127.0.0.1:${h.server.port}/health'));
    final HttpClientResponse res = await req.close();
    final String body = await res.transform(utf8.decoder).join();
    expect(res.statusCode, 200, reason: '/health status, body=$body');
    return jsonDecode(body) as Map<String, Object?>;
  } finally {
    http.close(force: true);
  }
}

/// Moves [code]'s room to FINISHED the way rematch_test.dart does.
void _forceFinished(ServerHarness h, String code, {int winner = 0}) {
  final Room? room = h.registry.lookup(code);
  if (room == null) {
    fail('fixture: room $code must exist to be forced FINISHED');
  }
  final engine.GameState base = room.game!;
  room.game = engine.GameState(
    config: base.config,
    tokens: base.tokens,
    currentSeat: winner,
    phase: engine.GamePhase.finished,
    roll: null,
    sixes: 0,
    winner: winner,
    seq: base.seq + 1,
    rngState: base.rngState,
  );
  room.state = RoomState.finished;
}

Future<void> _drainStart(WireTestClient c) async {
  Map<String, Object?> f = await c.next();
  while (f['t'] == 'seat_seed') {
    f = await c.next();
  }
  if (f['t'] != 'game_started') {
    fail('fixture: expected game_started, got ${jsonEncode(f)}');
  }
  final Map<String, Object?> t = await c.next();
  if (t['t'] != 'turn') {
    fail('fixture: expected turn after game_started, got ${jsonEncode(t)}');
  }
}

Future<void> _startGame(WireTestLobby lobby) async {
  lobby.host.client.send('start_game', <String, Object?>{});
  await _drainStart(lobby.host.client);
  await _drainStart(lobby.guest.client);
}

void main() {
  late ServerHarness h;
  final List<WireTestClient> clients = <WireTestClient>[];

  setUp(() async {
    h = ServerHarness.build();
    await h.start();
  });

  tearDown(() async {
    for (final WireTestClient c in clients) {
      await c.close();
    }
    clients.clear();
    await h.close();
  });

  Future<WireTestLobby> lobby2() => buildWireTestLobby(h.wsUri, clients);

  group('section 37 item 1 and 2: the 10 minute LOBBY rule', () {
    test(
        'connected host and guest: alive at 9:59, gone at 10:00; each socket '
        'gets exactly one room_closed and nothing after', () async {
      const String label = 'lobby-2-seats-connected';
      final WireTestLobby lobby = await lobby2();

      h.clock.advance(_min9s59);
      expect((await _sweep(h)), 0,
          reason: '[$label] must not be closed at 9:59 since creation');
      expect(h.registry.lookup(lobby.code), isNotNull,
          reason: '[$label] room must exist at 9:59');
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] no frame may reach the host at 9:59');

      h.clock.advance(_sec1);
      expect((await _sweep(h)), 1,
          reason: '[$label] must be closed at exactly 10:00 with both seats '
              'connected (section 37 item 1)');
      expect(h.registry.lookup(lobby.code), isNull,
          reason: '[$label] room must be gone at 10:00');

      _expectOneCloseOnly(
          await _drainToPong(lobby.host.client, label), 'host', label);
      _expectOneCloseOnly(
          await _drainToPong(lobby.guest.client, label), 'guest', label);

      // Replayed sweep: nothing more is ever sent.
      expect((await _sweep(h)), 0,
          reason: '[$label] second sweep reaps nothing');
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason:
              '[$label] a second sweep must not resend room_closed to host');
      expect(await _drainToPong(lobby.guest.client, label), isEmpty,
          reason:
              '[$label] a second sweep must not resend room_closed to guest');
    });

    test('a lone connected host in a one-seat-filled lobby is told too',
        () async {
      const String label = 'lobby-host-only-connected';
      final WireTestClient host = await WireTestClient.connect(h.wsUri);
      clients.add(host);
      host.send('create_room', <String, Object?>{'name': 'Solo', 'players': 2});
      await host.next(); // seat_assigned
      final String code = ((await host.next())['d']!
          as Map<String, Object?>)['code']! as String;

      h.clock.advance(_min9s59);
      expect((await _sweep(h)), 0, reason: '[$label] alive at 9:59');
      h.clock.advance(_sec1);
      expect((await _sweep(h)), 1, reason: '[$label] closed at 10:00');
      expect(h.registry.lookup(code), isNull);
      _expectOneCloseOnly(await _drainToPong(host, label), 'host', label);
    });

    test('the socket stays open and its seat token is dead afterwards',
        () async {
      const String label = 'detached-socket';
      final WireTestLobby lobby = await lobby2();
      h.clock.advance(const Duration(minutes: 10));
      (await _sweep(h));
      await _drainToPong(lobby.host.client, label);

      expect(await lobby.host.client.nextOrNull(), isNull,
          reason: '[$label] nothing may follow');
      // The socket is open: a ping got a pong in _drainToPong above. A seat
      // action from it must not be accepted as if the seat were alive.
      final String id =
          lobby.host.client.send('start_game', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expect(reply['t'], 'error',
          reason: '[$label] start_game after the close must be an error; '
              'got ${jsonEncode(reply)} (sent id $id)');
      expect(((reply['d']! as Map<String, Object?>)['code']),
          anyOf('BAD_SEAT_TOKEN', 'NO_SUCH_ROOM'),
          reason: '[$label] the dead seat holds no seat: expected '
              'BAD_SEAT_TOKEN (like kicked) or NO_SUCH_ROOM; '
              'got ${jsonEncode(reply)}');
    });

    test('a request for the closed code answers NO_SUCH_ROOM (join and resume)',
        () async {
      const String label = 'closed-code-requests';
      final WireTestLobby lobby = await lobby2();
      h.clock.advance(const Duration(minutes: 10));
      expect((await _sweep(h)), 1);

      final WireTestClient fresh = await WireTestClient.connect(h.wsUri);
      clients.add(fresh);
      fresh.send('join_room', <String, Object?>{
        'install': 'testinstall-00000002',
        'code': lobby.code,
        'name': 'Late',
      });
      expectErrorFrame(await fresh.next(), 'NO_SUCH_ROOM',
          because: '[$label] join_room for closed code ${lobby.code}');

      fresh.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.host.token,
      });
      expectErrorFrame(await fresh.next(), 'NO_SUCH_ROOM',
          because: '[$label] resume for closed code ${lobby.code} with the '
              'old host token (old client reconnect path, section 37 item 3)');
    });

    test('a seat that disconnected before the close is not told, the other is',
        () async {
      const String label = 'one-seat-gone';
      final WireTestLobby lobby = await lobby2();
      h.registry.setConnected(
          code: lobby.code, seatToken: lobby.guest.token, connected: false);
      await lobby.guest.client.close();

      h.clock.advance(const Duration(minutes: 10));
      expect((await _sweep(h)), 1,
          reason: '[$label] the host is still connected, so the 10 minute '
              'LOBBY rule applies at 10:00');
      _expectOneCloseOnly(
          await _drainToPong(lobby.host.client, label), 'host', label);
    });
  });

  group('section 37 item 1: rematch lobby and rooms that left LOBBY', () {
    test('a rematch lobby gets its own 10 minutes from the accepted rematch',
        () async {
      const String label = 'rematch-lobby';
      final WireTestLobby lobby = await lobby2();
      await _startGame(lobby);
      _forceFinished(h, lobby.code);

      h.clock.advance(const Duration(minutes: 5));
      lobby.host.client.send('rematch', <String, Object?>{});
      await receiveType(lobby.host.client, 'room');
      await receiveType(lobby.guest.client, 'room');
      // Drain any other frame the rematch pushed.
      await _drainToPong(lobby.host.client, label);
      await _drainToPong(lobby.guest.client, label);

      // 14:59 since creation, 9:59 since the rematch.
      h.clock.advance(_min9s59);
      expect((await _sweep(h)), 0,
          reason: '[$label] 9:59 after the accepted rematch must be alive '
              '(15:00 would be wrong from the old creation time too)');
      expect(h.registry.lookup(lobby.code), isNotNull);
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] no frame at 9:59 after the rematch');

      h.clock.advance(_sec1);
      expect((await _sweep(h)), 1,
          reason: '[$label] closed at 10:00 after the accepted rematch');
      expect(h.registry.lookup(lobby.code), isNull);
      _expectOneCloseOnly(
          await _drainToPong(lobby.host.client, label), 'host', label);
      _expectOneCloseOnly(
          await _drainToPong(lobby.guest.client, label), 'guest', label);
    });

    test('a rematch lobby is not closed by its first game\'s age', () async {
      const String label = 'rematch-not-from-creation';
      final WireTestLobby lobby = await lobby2();
      await _startGame(lobby);
      _forceFinished(h, lobby.code);
      h.clock.advance(const Duration(minutes: 9));
      lobby.host.client.send('rematch', <String, Object?>{});
      await receiveType(lobby.host.client, 'room');
      await receiveType(lobby.guest.client, 'room');
      h.clock.advance(const Duration(minutes: 2));
      expect((await _sweep(h)), 0,
          reason: '[$label] 11 minutes since creation but only 2 since the '
              'rematch: must be alive');
      expect(h.registry.lookup(lobby.code), isNotNull);
    });

    test(
        'a PLAYING room older than 10 minutes with connected seats is not '
        'closed and nobody is sent room_closed', () async {
      const String label = 'playing-connected';
      final WireTestLobby lobby = await lobby2();
      await _startGame(lobby);

      for (final Duration d in <Duration>[
        const Duration(minutes: 10),
        const Duration(minutes: 9, seconds: 59),
        const Duration(minutes: 40),
      ]) {
        h.clock.advance(d);
        expect((await _sweep(h)), 0,
            reason: '[$label] a PLAYING room with connected seats is never '
                'closed by the lobby rule (clock now +${d.inSeconds}s step)');
        expect(h.registry.lookup(lobby.code), isNotNull);
      }
      final List<Map<String, Object?>> host =
          await _drainToPong(lobby.host.client, label);
      final List<Map<String, Object?>> guest =
          await _drainToPong(lobby.guest.client, label);
      expect(_closed(host), isEmpty,
          reason: '[$label] host got room_closed: ${jsonEncode(host)}');
      expect(_closed(guest), isEmpty,
          reason: '[$label] guest got room_closed: ${jsonEncode(guest)}');
    });
  });

  group('section 37 item 2: the idle rule is unchanged and silent', () {
    test('no connected seat: removed at 10:00 and not at 9:59, nobody to tell',
        () async {
      const String label = 'idle-reap';
      final WireTestLobby lobby = await lobby2();
      // Really disconnect both seats: the sockets close, and the registry
      // is told as well so the outcome does not depend on the server's own
      // close handling having run yet.
      await lobby.host.client.close();
      await lobby.guest.client.close();
      for (final WireTestSeat s in <WireTestSeat>[lobby.host, lobby.guest]) {
        h.registry.setConnected(
            code: lobby.code, seatToken: s.token, connected: false);
      }
      h.clock.advance(_min9s59);
      expect(await _sweep(h), 0, reason: '[$label] alive at 9:59 idle');
      h.clock.advance(_sec1);
      expect(await _sweep(h), 1,
          reason: '[$label] removed at 10:00 with nobody connected');
      expect(h.registry.lookup(lobby.code), isNull);
      // Nobody is attached, so nobody can be told; the sweep must not fail
      // on a room with no sockets (the server stays up and answers).
      final WireTestClient probe = await WireTestClient.connect(h.wsUri);
      clients.add(probe);
      expect(await _drainToPong(probe, label), isEmpty,
          reason: '[$label] the server must still answer after the sweep and '
              'send an unrelated socket nothing');
    });

    test(
        'a PLAYING room with nobody connected is still reaped at 10 minutes '
        'idle, silently', () async {
      const String label = 'playing-idle';
      final WireTestLobby lobby = await lobby2();
      await _startGame(lobby);
      for (final WireTestSeat s in <WireTestSeat>[lobby.host, lobby.guest]) {
        h.registry.setConnected(
            code: lobby.code, seatToken: s.token, connected: false);
      }
      h.clock.advance(_min9s59);
      expect((await _sweep(h)), 0, reason: '[$label] alive at 9:59 idle');
      h.clock.advance(_sec1);
      expect((await _sweep(h)), 1, reason: '[$label] idle reap at 10:00');
      expect(_closed(await _drainToPong(lobby.host.client, label)), isEmpty,
          reason: '[$label] no room_closed outside LOBBY');
    });
  });

  group('section 37 item 4: /health', () {
    test('a server with no rooms reports zeros', () async {
      final Map<String, Object?> body = await _health(h);
      expect(body['rooms'], 0, reason: 'body=${jsonEncode(body)}');
      expect(body['rooms_lobby'], 0, reason: 'body=${jsonEncode(body)}');
      expect(body['rooms_playing'], 0, reason: 'body=${jsonEncode(body)}');
      expect(body['rooms_finished'], 0, reason: 'body=${jsonEncode(body)}');
      expect(body['oldest_lobby_s'], 0,
          reason: 'no LOBBY room: oldest_lobby_s is 0; '
              'body=${jsonEncode(body)}');
    });

    test('per-phase counts and the oldest LOBBY age on a mixed set', () async {
      const String label = 'health-mixed';
      // Oldest: a lobby created now, then 100 s later the rest.
      final WireTestLobby oldLobby = await lobby2();
      h.clock.advance(const Duration(seconds: 100));
      final WireTestLobby youngLobby = await lobby2();
      final WireTestLobby playing = await lobby2();
      await _startGame(playing);
      final WireTestLobby finished = await lobby2();
      await _startGame(finished);
      _forceFinished(h, finished.code);
      final WireTestLobby finished2 = await lobby2();
      await _startGame(finished2);
      _forceFinished(h, finished2.code);
      h.clock.advance(const Duration(seconds: 23));

      final Map<String, Object?> body = await _health(h);
      final String dump = jsonEncode(body);
      expect(body['rooms'], 5, reason: '[$label] total; body=$dump');
      expect(body['rooms_lobby'], 2, reason: '[$label] body=$dump');
      expect(body['rooms_playing'], 1, reason: '[$label] body=$dump');
      expect(body['rooms_finished'], 2, reason: '[$label] body=$dump');
      expect(body['oldest_lobby_s'], 123,
          reason: '[$label] oldest LOBBY is 100 + 23 s old, in whole '
              'seconds; body=$dump');
      expect(body['oldest_lobby_s'], isA<int>());
      expect(oldLobby.code, isNot(youngLobby.code));

      // No code, name or token anywhere in the body.
      for (final String secret in <String>[
        oldLobby.code,
        oldLobby.host.token,
        'Host',
        'Guest',
      ]) {
        if (secret.length > 3) {
          expect(dump.contains(secret), isFalse,
              reason: '[$label] /health must carry aggregates only; found '
                  '"$secret" in $dump');
        }
      }
    });

    test('oldest_lobby_s ignores PLAYING rooms', () async {
      const String label = 'health-oldest';
      final WireTestLobby started = await lobby2();
      await _startGame(started);
      h.clock.advance(const Duration(seconds: 300));
      expect((await _health(h))['oldest_lobby_s'], 0,
          reason: '[$label] only a PLAYING room exists: no LOBBY, so 0');

      await lobby2();
      h.clock.advance(const Duration(seconds: 7));
      expect((await _health(h))['oldest_lobby_s'], 7,
          reason: '[$label] the only LOBBY is 7 s old, not the 307 s of the '
              'PLAYING room');
    });

    test('counts drop when a lobby is closed and the oldest age moves on',
        () async {
      const String label = 'health-after-close';
      await lobby2();
      h.clock.advance(const Duration(minutes: 5));
      final WireTestLobby later = await lobby2();
      h.clock.advance(const Duration(minutes: 5));
      expect(h.registry.reap(), 1,
          reason: '[$label] first lobby is 10:00 old, second is 5:00 old');
      final Map<String, Object?> body = await _health(h);
      final String dump = jsonEncode(body);
      expect(body['rooms'], 1, reason: '[$label] body=$dump');
      expect(body['rooms_lobby'], 1, reason: '[$label] body=$dump');
      expect(body['oldest_lobby_s'], 300,
          reason: '[$label] the survivor ${later.code} is 300 s old; '
              'body=$dump');
    });
  });

  group('section 37 ugly cases', () {
    test(
        'many lobbies closing in one sweep: every socket in every room gets '
        'exactly one frame', () async {
      const String label = 'three-rooms-one-sweep';
      final List<WireTestLobby> rooms = <WireTestLobby>[
        await lobby2(),
        await lobby2(),
        await lobby2(),
      ];
      h.clock.advance(const Duration(minutes: 10));
      expect((await _sweep(h)), 3, reason: '[$label] all three close');
      for (int i = 0; i < rooms.length; i++) {
        _expectOneCloseOnly(await _drainToPong(rooms[i].host.client, label),
            'room#$i host', label);
        _expectOneCloseOnly(await _drainToPong(rooms[i].guest.client, label),
            'room#$i guest', label);
      }
    });

    test(
        'a code closed by the lobby rule rests like any reaped code '
        '(section 32 item 3): not reissued 9:59 after the close', () async {
      const String label = 'code-rest';
      final WireTestLobby lobby = await lobby2();
      h.clock.advance(const Duration(minutes: 10));
      (await _sweep(h));

      h.clock.advance(_min9s59);
      final WireTestClient a = await WireTestClient.connect(h.wsUri);
      clients.add(a);
      a.send('create_room', <String, Object?>{'name': 'Next', 'players': 2});
      await a.next();
      final String during =
          ((await a.next())['d']! as Map<String, Object?>)['code']! as String;
      expect(during, isNot(lobby.code),
          reason: '[$label] code ${lobby.code} must still rest 9:59 after '
              'the close; got it reissued');
    });

    test('the real housekeeping timer delivers room_closed (no hook used)',
        () async {
      const String label = 'real-timer';
      final WireTestLobby lobby = await lobby2();
      h.clock.advance(const Duration(minutes: 10));
      // Waits on the condition (the frame arriving) bounded by one timer
      // period plus slack; no fixed sleep.
      final Map<String, Object?>? frame = await lobby.host.client
          .nextOrNull(timeout: const Duration(seconds: 80));
      expect(frame, isNotNull,
          reason: '[$label] no frame reached the host within 80 s real time '
              'although the fake clock is 10:00 past creation and the '
              'one minute housekeeping timer must have fired');
      expect(frame!['t'], 'room_closed',
          reason: '[$label] got ${jsonEncode(frame)}');
      expect(frame['d'], <String, Object?>{'reason': 'lobby_timeout'});
      expect(h.registry.lookup(lobby.code), isNull,
          reason: '[$label] the room must be gone once the frame arrived');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

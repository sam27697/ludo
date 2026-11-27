// Conformance tests for docs/PROTOCOL.md section 38 (X241): the
// `lobby_closing` push two minutes before the section 37 close, and the
// `ask_start` request a guest sends to nudge the host. Written from section
// 38 item 1 to 4 and the item 6 list only.
//
// Real WireServer, real sockets, FakeClock. The sweep is driven with
// ServerHarness.clock.advance(...) and one WireServer.runHousekeepingOnce()
// pass (the public hook c725 uses). The sweep period is pinned by a constant check.
//
// Waiting: no sleeps. "Nothing else arrived" is proved with a ping barrier:
// the server answers one socket's frames in order, so every frame queued for
// that socket before the pong is read before the pong.
//
// Reproduce any failure by name: every message carries the scenario label
// and the clock offsets. The run is deterministic (FakeClock, no seed).

import 'dart:convert';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

typedef Frame = Map<String, Object?>;

const Duration _sec1 = Duration(seconds: 1);
const Duration _min8 = Duration(minutes: 8);
const Duration _min8Less1 = Duration(minutes: 7, seconds: 59);

/// Sends a ping on [c] and returns every frame that arrived before its pong,
/// in order, pong excluded.
Future<List<Frame>> _drainToPong(WireTestClient c, String label) async {
  final String id = c.send('ping', <String, Object?>{});
  final List<Frame> seen = <Frame>[];
  for (int i = 0; i < 16; i++) {
    final Frame f = await c.next(timeout: const Duration(seconds: 3));
    if (f['t'] == 'pong' && f['re'] == id) {
      return seen;
    }
    seen.add(f);
  }
  throw TestFailure('[$label] no pong for ping $id after 16 frames; '
      'frames before: ${jsonEncode(seen)}');
}

List<Frame> _ofType(List<Frame> frames, String t) => <Frame>[
      for (final Frame f in frames)
        if (f['t'] == t) f
    ];

Future<void> _sweep(ServerHarness h) async {
  h.server.runHousekeepingOnce();
}

/// Asserts [frames] holds exactly one `lobby_closing` and nothing else, with
/// the exact shape of section 38 item 1, and returns its closes_in_s.
int _expectOneClosing(List<Frame> frames, String who, String label,
    {int? closesIn}) {
  expect(frames.length, 1,
      reason: '[$label] $who must get exactly one frame (lobby_closing); '
          'got ${jsonEncode(frames)}');
  final Frame f = frames.single;
  expect(f['t'], 'lobby_closing',
      reason: '[$label] $who: expected lobby_closing, got ${jsonEncode(f)}');
  expect(f.containsKey('seq'), isFalse,
      reason: '[$label] $who: lobby_closing carries no seq: ${jsonEncode(f)}');
  expect(f.containsKey('re'), isFalse,
      reason: '[$label] $who: lobby_closing carries no re: ${jsonEncode(f)}');
  final Object? d = f['d'];
  expect(d, isA<Map<String, Object?>>(),
      reason: '[$label] $who: d must be an object: ${jsonEncode(f)}');
  final Map<String, Object?> m = d! as Map<String, Object?>;
  expect(m.keys.toList(), <String>['closes_in_s'],
      reason: '[$label] $who: d must hold only closes_in_s: ${jsonEncode(f)}');
  expect(m['closes_in_s'], isA<int>(),
      reason: '[$label] $who: closes_in_s must be an int: ${jsonEncode(f)}');
  final int v = m['closes_in_s']! as int;
  expect(v, inInclusiveRange(0, 120),
      reason: '[$label] $who: closes_in_s must be within 0..120: $v');
  if (closesIn != null) {
    expect(v, closesIn,
        reason: '[$label] $who: expected closes_in_s=$closesIn, got $v');
  }
  return v;
}

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
  Frame f = await c.next();
  while (f['t'] == 'seat_seed') {
    f = await c.next();
  }
  if (f['t'] != 'game_started') {
    fail('fixture: expected game_started, got ${jsonEncode(f)}');
  }
  final Frame t = await c.next();
  if (t['t'] != 'turn') {
    fail('fixture: expected turn after game_started, got ${jsonEncode(t)}');
  }
}

Future<void> _startGame(WireTestLobby lobby, String label) async {
  lobby.host.client.send('start_game', <String, Object?>{});
  await _drainStart(lobby.host.client);
  await _drainStart(lobby.guest.client);
  await _drainToPong(lobby.host.client, label);
  await _drainToPong(lobby.guest.client, label);
}

void main() {
  late ServerHarness h;
  final List<WireTestClient> clients = <WireTestClient>[];
  int installCounter = 100;

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

  Future<WireTestLobby> lobby2({String guestName = 'Guest', int players = 2}) =>
      buildWireTestLobby(h.wsUri, clients,
          guestName: guestName, players: players);

  /// Joins one more guest, drains the handshake on every socket in [others].
  Future<WireTestSeat> joinMore(WireTestLobby lobby, String name,
      List<WireTestClient> others, String label) async {
    final WireTestClient c = await WireTestClient.connect(h.wsUri);
    clients.add(c);
    installCounter++;
    c.send('join_room', <String, Object?>{
      'install': 'testinstall-$installCounter'.padRight(20, '0'),
      'code': lobby.code,
      'name': name,
    });
    final Frame sa = await receiveType(c, 'seat_assigned');
    await receiveType(c, 'room');
    final Map<String, Object?> d = sa['d']! as Map<String, Object?>;
    for (final WireTestClient o in others) {
      await _drainToPong(o, label);
    }
    await _drainToPong(c, label);
    return WireTestSeat(
        client: c, seat: d['seat']! as int, token: d['seat_token']! as String);
  }

  /// Resumes [seat] on a fresh socket; returns the socket and every frame
  /// that followed seat_assigned and room up to the ping barrier.
  Future<(WireTestClient, List<Frame>)> resumeSeat(
      WireTestLobby lobby, WireTestSeat seat, String label) async {
    final WireTestClient c = await WireTestClient.connect(h.wsUri);
    clients.add(c);
    c.send('resume', <String, Object?>{
      'code': lobby.code,
      'seat_token': seat.token,
    });
    final Frame sa = await c.next();
    expect(sa['t'], 'seat_assigned',
        reason: '[$label] resume must answer seat_assigned first: '
            '${jsonEncode(sa)}');
    final Frame room = await c.next();
    expect(room['t'], 'room',
        reason: '[$label] then the room snapshot: ${jsonEncode(room)}');
    return (c, await _drainToPong(c, label));
  }

  Future<void> waitSeatDown(String code, int seat, String label) async {
    final DateTime end = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(end)) {
      final Room? r = h.registry.lookup(code);
      if (r != null &&
          !r.seats.firstWhere((Seat s) => s.seat == seat).connected) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('[$label] seat $seat of $code was never marked disconnected '
        'within 3 s of the socket closing');
  }

  Frame errorData(Frame f) => f['d']! as Frame;

  group('section 38 item 1: lobby_closing', () {
    test('not at 7:59; at 8:00 every attached socket gets one frame with 120',
        () async {
      const String label = 'closing-at-8:00';
      final WireTestLobby lobby = await lobby2(players: 3);
      final WireTestSeat third = await joinMore(lobby, 'Third',
          <WireTestClient>[lobby.host.client, lobby.guest.client], label);

      h.clock.advance(_min8Less1);
      await _sweep(h);
      for (final WireTestSeat s in <WireTestSeat>[
        lobby.host,
        lobby.guest,
        third
      ]) {
        expect(await _drainToPong(s.client, label), isEmpty,
            reason: '[$label] seat ${s.seat} got a frame at 7:59; '
                'lobby_closing must not be sent before 8:00');
      }

      h.clock.advance(_sec1);
      await _sweep(h);
      for (final WireTestSeat s in <WireTestSeat>[
        lobby.host,
        lobby.guest,
        third
      ]) {
        _expectOneClosing(
            await _drainToPong(s.client, label), 'seat ${s.seat}', label,
            closesIn: 120);
      }
      expect(h.registry.lookup(lobby.code), isNotNull,
          reason: '[$label] the room is still alive at 8:00');
    });

    test('once only across several sweeps', () async {
      const String label = 'closing-once';
      final WireTestLobby lobby = await lobby2();
      h.clock.advance(_min8);
      await _sweep(h);
      _expectOneClosing(
          await _drainToPong(lobby.host.client, label), 'host', label,
          closesIn: 120);
      _expectOneClosing(
          await _drainToPong(lobby.guest.client, label), 'guest', label,
          closesIn: 120);

      for (int i = 1; i <= 5; i++) {
        h.clock.advance(_sec1);
        await _sweep(h);
        await _sweep(h);
      }
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] host got a second lobby_closing in the 10 '
              'sweeps after 8:00');
      expect(await _drainToPong(lobby.guest.client, label), isEmpty,
          reason: '[$label] guest got a second lobby_closing in the 10 '
              'sweeps after 8:00');
    });

    test('closes_in_s is the whole seconds left at the moment of sending',
        () async {
      const String label = 'closing-late-sweep';
      final WireTestLobby lobby = await lobby2();
      // The first sweep after 8:00 happens at 8:30: 90 s left, not 120.
      h.clock.advance(const Duration(minutes: 8, seconds: 30));
      await _sweep(h);
      _expectOneClosing(
          await _drainToPong(lobby.host.client, label), 'host', label,
          closesIn: 90);

      final WireTestLobby second = await lobby2();
      h.clock.advance(const Duration(minutes: 9, seconds: 59));
      await _sweep(h);
      _expectOneClosing(
          await _drainToPong(second.host.client, label), 'second host', label,
          closesIn: 1);
    });

    test('a late joiner gets the frame once, right after room', () async {
      const String label = 'closing-late-joiner';
      final WireTestLobby lobby = await lobby2(players: 3);
      h.clock.advance(_min8);
      await _sweep(h);
      await _drainToPong(lobby.host.client, label);
      await _drainToPong(lobby.guest.client, label);

      h.clock.advance(const Duration(seconds: 30));
      // 1. A new player joining by code.
      final WireTestClient c = await WireTestClient.connect(h.wsUri);
      clients.add(c);
      c.send('join_room', <String, Object?>{
        'install': 'testinstall-00000777',
        'code': lobby.code,
        'name': 'Late',
      });
      final Frame sa = await c.next();
      expect(sa['t'], 'seat_assigned', reason: '[$label] ${jsonEncode(sa)}');
      final Frame room = await c.next();
      expect(room['t'], 'room', reason: '[$label] ${jsonEncode(room)}');
      final Frame closing = await c.next();
      expect(closing['t'], 'lobby_closing',
          reason: '[$label] the frame must come right after the room '
              'snapshot of a join past 8:00; got ${jsonEncode(closing)}');
      expect((closing['d']! as Frame)['closes_in_s'], 90,
          reason: '[$label] then-current closes_in_s at 8:30 is 90: '
              '${jsonEncode(closing)}');
      expect(closing.containsKey('seq') || closing.containsKey('re'), isFalse,
          reason: '[$label] no seq, no re: ${jsonEncode(closing)}');
      expect(await _drainToPong(c, label), isEmpty,
          reason: '[$label] exactly once for the late joiner');
      // Existing sockets: the joiner's arrival is player_joined only.
      expect(
          _ofType(
              await _drainToPong(lobby.host.client, label), 'lobby_closing'),
          isEmpty,
          reason: '[$label] an attach must not resend lobby_closing to the '
              'host');

      // 2. A resume of the guest on a fresh socket, 10 s later.
      h.clock.advance(const Duration(seconds: 10));
      final WireTestClient g2 = await WireTestClient.connect(h.wsUri);
      clients.add(g2);
      g2.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      expect((await g2.next())['t'], 'seat_assigned');
      expect((await g2.next())['t'], 'room');
      final Frame again = await g2.next();
      expect(again['t'], 'lobby_closing',
          reason: '[$label] resume past 8:00: got ${jsonEncode(again)}');
      expect((again['d']! as Frame)['closes_in_s'], 80,
          reason: '[$label] closes_in_s at 8:40 is 80: ${jsonEncode(again)}');
      expect(await _drainToPong(g2, label), isEmpty,
          reason: '[$label] exactly once for the resumed socket');
    });

    test('an attach before 8:00 gets no lobby_closing', () async {
      const String label = 'no-closing-early-resume';
      final WireTestLobby lobby = await lobby2();
      h.clock.advance(_min8Less1);
      await _sweep(h);
      final (WireTestClient _, List<Frame> after) =
          await resumeSeat(lobby, lobby.guest, label);
      expect(after, isEmpty,
          reason: '[$label] resume at 7:59 must not carry lobby_closing; '
              'got ${jsonEncode(after)}');
    });

    test('a PLAYING room never sends it, nor to a resume', () async {
      const String label = 'playing-no-closing';
      final WireTestLobby lobby = await lobby2();
      await _startGame(lobby, label);
      for (final Duration d in <Duration>[
        _min8,
        const Duration(seconds: 30),
        const Duration(minutes: 1)
      ]) {
        h.clock.advance(d);
        await _sweep(h);
      }
      expect(
          _ofType(
              await _drainToPong(lobby.host.client, label), 'lobby_closing'),
          isEmpty,
          reason: '[$label] host of a PLAYING room got lobby_closing');
      expect(
          _ofType(
              await _drainToPong(lobby.guest.client, label), 'lobby_closing'),
          isEmpty,
          reason: '[$label] guest of a PLAYING room got lobby_closing');
      final (WireTestClient _, List<Frame> after) =
          await resumeSeat(lobby, lobby.guest, label);
      expect(_ofType(after, 'lobby_closing'), isEmpty,
          reason: '[$label] a resume into a PLAYING room past 8:00 must not '
              'carry lobby_closing; got ${jsonEncode(after)}');
    });

    test('a game started after the warning stops any further warning',
        () async {
      const String label = 'start-after-warning';
      final WireTestLobby lobby = await lobby2();
      h.clock.advance(_min8);
      await _sweep(h);
      await _drainToPong(lobby.host.client, label);
      await _drainToPong(lobby.guest.client, label);
      await _startGame(lobby, label);
      h.clock.advance(const Duration(minutes: 5));
      await _sweep(h);
      expect(h.registry.lookup(lobby.code), isNotNull,
          reason: '[$label] a started room is not closed by the lobby rule');
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] nothing after the start');
    });

    test('a rematch resets the flag with lifetimeStartedAt', () async {
      const String label = 'rematch-reset';
      final WireTestLobby lobby = await lobby2();
      // First lifetime: warned at 8:00, then started.
      h.clock.advance(_min8);
      await _sweep(h);
      _expectOneClosing(
          await _drainToPong(lobby.host.client, label), 'host#1', label,
          closesIn: 120);
      await _drainToPong(lobby.guest.client, label);
      await _startGame(lobby, label);
      _forceFinished(h, lobby.code);

      h.clock.advance(const Duration(minutes: 1));
      lobby.host.client.send('rematch', <String, Object?>{});
      await receiveType(lobby.host.client, 'room');
      await receiveType(lobby.guest.client, 'room');
      final List<Frame> hostAfter =
          await _drainToPong(lobby.host.client, label);
      final List<Frame> guestAfter =
          await _drainToPong(lobby.guest.client, label);
      expect(_ofType(hostAfter, 'lobby_closing'), isEmpty,
          reason: '[$label] a fresh rematch lobby is not past 8:00: '
              '${jsonEncode(hostAfter)}');
      expect(_ofType(guestAfter, 'lobby_closing'), isEmpty,
          reason: '[$label] ${jsonEncode(guestAfter)}');

      h.clock.advance(_min8Less1);
      await _sweep(h);
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] 7:59 after the rematch: still no warning');

      h.clock.advance(_sec1);
      await _sweep(h);
      _expectOneClosing(
          await _drainToPong(lobby.host.client, label), 'host#2', label,
          closesIn: 120);
      _expectOneClosing(
          await _drainToPong(lobby.guest.client, label), 'guest#2', label,
          closesIn: 120);
      await _sweep(h);
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] only once in the second lifetime too');
    });

    test('the housekeeping sweep runs at least once a minute', () {
      expect(
          housekeepingInterval, lessThanOrEqualTo(const Duration(seconds: 60)),
          reason: 'section 38 item 1: the push lands between 8:00 and 9:00, '
              'which holds only if the sweep is one pass a minute or faster; '
              'housekeepingInterval is $housekeepingInterval');
      expect(housekeepingInterval, greaterThan(Duration.zero),
          reason: 'housekeepingInterval must be a positive period; '
              'got $housekeepingInterval');
    });
  });

  group('section 38 item 2 and 3: ask_start', () {
    test('a guest ask is delivered to the host and answered ask_start_ok',
        () async {
      const String label = 'ask-delivered';
      final WireTestLobby lobby = await lobby2(guestName: 'Layla', players: 3);
      final WireTestSeat third = await joinMore(lobby, 'Omar',
          <WireTestClient>[lobby.host.client, lobby.guest.client], label);

      final String id =
          lobby.guest.client.send('ask_start', <String, Object?>{});
      final Frame ok = await lobby.guest.client.next();
      expect(ok['t'], 'ask_start_ok', reason: '[$label] ${jsonEncode(ok)}');
      expect(ok['re'], id,
          reason: '[$label] answered with re: ${jsonEncode(ok)}');
      expect(ok['d'], <String, Object?>{'delivered': true, 'next_in_s': 60},
          reason: '[$label] ${jsonEncode(ok)}');

      final List<Frame> host = await _drainToPong(lobby.host.client, label);
      expect(host.length, 1,
          reason: '[$label] host must get exactly start_asked: '
              '${jsonEncode(host)}');
      expect(host.single['t'], 'start_asked',
          reason: '[$label] ${jsonEncode(host)}');
      expect(host.single['d'],
          <String, Object?>{'seat': lobby.guest.seat, 'name': 'Layla'},
          reason: '[$label] asker seat and display name: ${jsonEncode(host)}');
      expect(host.single.containsKey('seq') || host.single.containsKey('re'),
          isFalse,
          reason: '[$label] start_asked has no seq and no re: '
              '${jsonEncode(host)}');

      expect(await _drainToPong(third.client, label), isEmpty,
          reason: '[$label] no frame may reach the other guest');
      expect(await _drainToPong(lobby.guest.client, label), isEmpty,
          reason: '[$label] the asker gets only the reply');
    });

    test('second ask at 59 s is RATE_LIMITED with retry_after_s, 60 s accepted',
        () async {
      const String label = 'cooldown-59-60';
      final WireTestLobby lobby = await lobby2();
      lobby.guest.client.send('ask_start', <String, Object?>{});
      expect((await lobby.guest.client.next())['t'], 'ask_start_ok');
      await _drainToPong(lobby.host.client, label);

      h.clock.advance(const Duration(seconds: 59));
      final String id =
          lobby.guest.client.send('ask_start', <String, Object?>{});
      final Frame err = await lobby.guest.client.next();
      expect(err['t'], 'error', reason: '[$label] ${jsonEncode(err)}');
      expect(err['re'], id, reason: '[$label] ${jsonEncode(err)}');
      expect(errorData(err)['code'], 'RATE_LIMITED',
          reason: '[$label] ask at 59 s: ${jsonEncode(err)}');
      expect(errorData(err)['retry_after_s'], 1,
          reason: '[$label] 1 s left: retry_after_s must be 1: '
              '${jsonEncode(err)}');
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] a refused ask must not push start_asked');

      // A refused ask does not restart the cooldown: 60 s after the FIRST.
      h.clock.advance(_sec1);
      lobby.guest.client.send('ask_start', <String, Object?>{});
      final Frame ok = await lobby.guest.client.next();
      expect(ok['t'], 'ask_start_ok',
          reason: '[$label] ask at exactly 60 s must be accepted: '
              '${jsonEncode(ok)}');
      expect(ok['d'], <String, Object?>{'delivered': true, 'next_in_s': 60});
      expect(
          _ofType(await _drainToPong(lobby.host.client, label), 'start_asked')
              .length,
          1,
          reason: '[$label] accepted ask at 60 s pushes start_asked');

      // The cooldown restarted at the accepted ask.
      h.clock.advance(const Duration(seconds: 59));
      lobby.guest.client.send('ask_start', <String, Object?>{});
      expectErrorFrame(await lobby.guest.client.next(), 'RATE_LIMITED',
          because: '[$label] 59 s after the second accepted ask');
    });

    test('retry_after_s is whole seconds and at least 1 inside the last second',
        () async {
      const String label = 'retry-after-rounding';
      final WireTestLobby lobby = await lobby2();
      lobby.guest.client.send('ask_start', <String, Object?>{});
      await lobby.guest.client.next();

      h.clock.advance(const Duration(seconds: 20));
      lobby.guest.client.send('ask_start', <String, Object?>{});
      Frame err = await lobby.guest.client.next();
      expect(errorData(err)['code'], 'RATE_LIMITED', reason: jsonEncode(err));
      expect(errorData(err)['retry_after_s'], 40,
          reason: '[$label] 40 s left at 20 s: ${jsonEncode(err)}');

      h.clock.advance(const Duration(seconds: 39, milliseconds: 500));
      lobby.guest.client.send('ask_start', <String, Object?>{});
      err = await lobby.guest.client.next();
      expect(errorData(err)['code'], 'RATE_LIMITED',
          reason: '[$label] 0.5 s left: ${jsonEncode(err)}');
      final Object? r = errorData(err)['retry_after_s'];
      expect(r, isA<int>(),
          reason: '[$label] whole seconds: ${jsonEncode(err)}');
      expect(r! as int, greaterThanOrEqualTo(1),
          reason: '[$label] never 0 while still limited: ${jsonEncode(err)}');
    });

    test('the cooldown survives the guest reconnecting', () async {
      const String label = 'cooldown-reconnect';
      final WireTestLobby lobby = await lobby2();
      lobby.guest.client.send('ask_start', <String, Object?>{});
      expect((await lobby.guest.client.next())['t'], 'ask_start_ok');
      await _drainToPong(lobby.host.client, label);

      await lobby.guest.client.close();
      await waitSeatDown(lobby.code, lobby.guest.seat, label);
      h.clock.advance(const Duration(seconds: 10));
      final (WireTestClient g2, List<Frame> _) =
          await resumeSeat(lobby, lobby.guest, label);
      await _drainToPong(lobby.host.client, label);

      g2.send('ask_start', <String, Object?>{});
      final Frame err = await g2.next();
      expect(err['t'], 'error', reason: '[$label] ${jsonEncode(err)}');
      expect(errorData(err)['code'], 'RATE_LIMITED',
          reason: '[$label] a reconnect must not reset the cooldown: '
              '${jsonEncode(err)}');
      expect(errorData(err)['retry_after_s'], 50,
          reason: '[$label] 60 - 10 s: ${jsonEncode(err)}');
      expect(
          _ofType(await _drainToPong(lobby.host.client, label), 'start_asked'),
          isEmpty,
          reason: '[$label] refused ask must not reach the host');
    });

    test('the cooldown is per seat: a second guest is not limited', () async {
      const String label = 'cooldown-per-seat';
      final WireTestLobby lobby = await lobby2(guestName: 'Layla', players: 3);
      final WireTestSeat third = await joinMore(lobby, 'Omar',
          <WireTestClient>[lobby.host.client, lobby.guest.client], label);

      lobby.guest.client.send('ask_start', <String, Object?>{});
      expect((await lobby.guest.client.next())['t'], 'ask_start_ok');
      expect(
          _ofType(await _drainToPong(lobby.host.client, label), 'start_asked')
              .length,
          1);

      h.clock.advance(const Duration(seconds: 5));
      third.client.send('ask_start', <String, Object?>{});
      final Frame ok = await third.client.next();
      expect(ok['t'], 'ask_start_ok',
          reason: '[$label] the second guest 5 s after the first must be '
              'accepted (per seat): ${jsonEncode(ok)}');
      expect(ok['d'], <String, Object?>{'delivered': true, 'next_in_s': 60});
      final List<Frame> host = await _drainToPong(lobby.host.client, label);
      expect(host.length, 1, reason: '[$label] ${jsonEncode(host)}');
      expect(host.single['d'],
          <String, Object?>{'seat': third.seat, 'name': 'Omar'},
          reason: '[$label] ${jsonEncode(host)}');
      expect(await _drainToPong(lobby.guest.client, label), isEmpty,
          reason: '[$label] the first guest must not see the second ask');

      // The first guest is still limited by its own cooldown.
      lobby.guest.client.send('ask_start', <String, Object?>{});
      final Frame err = await lobby.guest.client.next();
      expect(errorData(err)['code'], 'RATE_LIMITED',
          reason: '[$label] ${jsonEncode(err)}');
      expect(errorData(err)['retry_after_s'], 55,
          reason: '[$label] ${jsonEncode(err)}');
    });

    test('host socket down: delivered false, and the cooldown still starts',
        () async {
      const String label = 'host-down';
      final WireTestLobby lobby = await lobby2();
      await lobby.host.client.close();
      await waitSeatDown(lobby.code, lobby.host.seat, label);
      await _drainToPong(lobby.guest.client, label);

      final String id =
          lobby.guest.client.send('ask_start', <String, Object?>{});
      final Frame ok = await lobby.guest.client.next();
      expect(ok['t'], 'ask_start_ok',
          reason: '[$label] a request to an absent host is still accepted: '
              '${jsonEncode(ok)}');
      expect(ok['re'], id);
      expect(ok['d'], <String, Object?>{'delivered': false, 'next_in_s': 60},
          reason: '[$label] ${jsonEncode(ok)}');

      h.clock.advance(const Duration(seconds: 10));
      lobby.guest.client.send('ask_start', <String, Object?>{});
      final Frame err = await lobby.guest.client.next();
      expect(errorData(err)['code'], 'RATE_LIMITED',
          reason: '[$label] the undelivered ask still started the cooldown: '
              '${jsonEncode(err)}');
      expect(errorData(err)['retry_after_s'], 50,
          reason: '[$label] ${jsonEncode(err)}');

      // No store of missed asks: the host returning gets no start_asked.
      final (WireTestClient _, List<Frame> back) =
          await resumeSeat(lobby, lobby.host, label);
      expect(_ofType(back, 'start_asked'), isEmpty,
          reason: '[$label] section 38 item 4: no store of missed asks; the '
              'resuming host got ${jsonEncode(back)}');
    });

    test('a rematch drops the cooldown state', () async {
      const String label = 'cooldown-rematch';
      final WireTestLobby lobby = await lobby2();
      lobby.guest.client.send('ask_start', <String, Object?>{});
      expect((await lobby.guest.client.next())['t'], 'ask_start_ok');
      await _drainToPong(lobby.host.client, label);

      h.clock.advance(_sec1);
      await _startGame(lobby, label);
      _forceFinished(h, lobby.code);
      h.clock.advance(_sec1);
      lobby.host.client.send('rematch', <String, Object?>{});
      await receiveType(lobby.host.client, 'room');
      await receiveType(lobby.guest.client, 'room');
      await _drainToPong(lobby.host.client, label);
      await _drainToPong(lobby.guest.client, label);

      lobby.guest.client.send('ask_start', <String, Object?>{});
      final Frame ok = await lobby.guest.client.next();
      expect(ok['t'], 'ask_start_ok',
          reason: '[$label] 2 s after the first ask but after a rematch: '
              'accepted; got ${jsonEncode(ok)}');
    });
  });

  group('section 38 item 2: the ladder', () {
    test('a socket that holds no seat answers NO_SUCH_ROOM', () async {
      const String label = 'ladder-no-seat';
      final WireTestClient c = await WireTestClient.connect(h.wsUri);
      clients.add(c);
      final String id = c.send('ask_start', <String, Object?>{});
      final Frame f = await c.next();
      expectErrorFrame(f, 'NO_SUCH_ROOM', because: '[$label] no seat');
      expect(f['re'], id, reason: '[$label] answered with re');
    });

    test('a room that left LOBBY answers ROOM_STARTED (PLAYING and FINISHED)',
        () async {
      const String label = 'ladder-started';
      final WireTestLobby lobby = await lobby2();
      await _startGame(lobby, label);
      lobby.guest.client.send('ask_start', <String, Object?>{});
      expectErrorFrame(await lobby.guest.client.next(), 'ROOM_STARTED',
          because: '[$label] PLAYING room');
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] nothing to the host');

      _forceFinished(h, lobby.code);
      lobby.guest.client.send('ask_start', <String, Object?>{});
      expectErrorFrame(await lobby.guest.client.next(), 'ROOM_STARTED',
          because: '[$label] FINISHED room');
    });

    test('the host asking answers BAD_FIELD and pushes nothing', () async {
      const String label = 'ladder-host';
      final WireTestLobby lobby = await lobby2();
      lobby.host.client.send('ask_start', <String, Object?>{});
      expectErrorFrame(await lobby.host.client.next(), 'BAD_FIELD',
          because: '[$label] the host cannot ask itself');
      expect(await _drainToPong(lobby.guest.client, label), isEmpty,
          reason: '[$label] nothing to the guest');
      // The refusal did not start a cooldown for the host seat (it cannot
      // matter), and the guest is still free to ask.
      lobby.guest.client.send('ask_start', <String, Object?>{});
      expect((await lobby.guest.client.next())['t'], 'ask_start_ok');
    });

    test('a lone host (one occupied seat) is refused, never accepted',
        () async {
      const String label = 'ladder-lone-host';
      final WireTestClient host = await WireTestClient.connect(h.wsUri);
      clients.add(host);
      host.send('create_room', <String, Object?>{'name': 'Solo', 'players': 2});
      await receiveType(host, 'room');
      host.send('ask_start', <String, Object?>{});
      final Frame f = await host.next();
      expect(f['t'], 'error',
          reason: '[$label] a lone host must be refused: ${jsonEncode(f)}');
      expect(errorData(f)['code'], anyOf('BAD_FIELD', 'NOT_ENOUGH_PLAYERS'),
          reason: '[$label] the host check (BAD_FIELD) or the seat count '
              '(NOT_ENOUGH_PLAYERS): ${jsonEncode(f)}');
    });

    test('an extra key answers BAD_FIELD and starts no cooldown', () async {
      const String label = 'ladder-extra-key';
      final WireTestLobby lobby = await lobby2();
      for (final Map<String, Object?> d in <Map<String, Object?>>[
        <String, Object?>{'x': 1},
        <String, Object?>{'note': 'please', 'seat': 0},
      ]) {
        lobby.guest.client.send('ask_start', d);
        expectErrorFrame(await lobby.guest.client.next(), 'BAD_FIELD',
            because: '[$label] extra key in ${jsonEncode(d)}');
      }
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] a malformed ask must not reach the host');
      lobby.guest.client.send('ask_start', <String, Object?>{});
      final Frame ok = await lobby.guest.client.next();
      expect(ok['t'], 'ask_start_ok',
          reason: '[$label] refused asks must not start the cooldown: '
              '${jsonEncode(ok)}');
    });

    test('ask_start with a non-object d is refused, nothing delivered',
        () async {
      const String label = 'ladder-non-object';
      final WireTestLobby lobby = await lobby2();
      lobby.guest.client.send('ask_start', <String, Object?>{'': ''});
      final Frame f = await lobby.guest.client.next();
      expect(f['t'], 'error', reason: '[$label] ${jsonEncode(f)}');
      expect(await _drainToPong(lobby.host.client, label), isEmpty,
          reason: '[$label] ${label}: host must see nothing');
    });

    test('no frame of an ask reaches other guests, replays included', () async {
      const String label = 'no-leak';
      final WireTestLobby lobby = await lobby2(players: 4);
      final WireTestSeat b = await joinMore(lobby, 'B',
          <WireTestClient>[lobby.host.client, lobby.guest.client], label);
      final WireTestSeat c = await joinMore(
          lobby,
          'C',
          <WireTestClient>[lobby.host.client, lobby.guest.client, b.client],
          label);

      lobby.guest.client.send('ask_start', <String, Object?>{});
      await lobby.guest.client.next();
      lobby.guest.client.send('ask_start', <String, Object?>{}); // replay
      expectErrorFrame(await lobby.guest.client.next(), 'RATE_LIMITED',
          because: '[$label] replayed ask in the same instant');
      for (final WireTestSeat s in <WireTestSeat>[b, c]) {
        expect(await _drainToPong(s.client, label), isEmpty,
            reason: '[$label] guest seat ${s.seat} got a frame from '
                'someone else\'s ask');
      }
      final List<Frame> host = await _drainToPong(lobby.host.client, label);
      expect(_ofType(host, 'start_asked').length, 1,
          reason: '[$label] the replay must not push a second start_asked: '
              '${jsonEncode(host)}');
    });
  });
}

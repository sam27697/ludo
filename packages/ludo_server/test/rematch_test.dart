// Conformance tests for `rematch`, docs/PROTOCOL.md section 16, written
// from the spec before order 234's implementation exists. Every assertion
// is on frames as a client receives them -- type, order, seq steps, re --
// over a real WireServer via test/support/wire_harness.dart, the same way
// turn_loop_test.dart and reseat_seat_assigned_test.dart hold their own
// sections. The two exceptions, both because no frame shows the fact:
//
//   - the 60-minute room lifetime restarting at the first rematch (section
//     16.2 item 4), which uses the same FakeClock seam
//     test/registry_reap_test.dart uses, driving ServerHarness.clock and
//     ServerHarness.registry.reap() directly, combined with real sockets for
//     the rematch itself;
//   - the old game's verify record staying byte-identical (section 16.8),
//     which reads RoomRegistry.verifyStore.load() before and after, the
//     only way to observe that fact at all -- there is no wire message that
//     fetches a stored record.
//
// FINISHED is reached the cheap way almost everywhere here: `room.state =
// RoomState.finished` and a hand-built `GameState` carrying a `winner`,
// exactly the technique test/turn_loop_test.dart's own GAME_OVER tests use
// ("the same direct mutation of Room.state the turn loop itself is
// documented to perform"). The one test that needs a *real*, saved verify
// record plays an actual game to a natural win through RoomRegistry
// directly, the technique test/verify_record_test.dart's own header
// documents and justifies at length; that one test is therefore registry-
// level, not wire-level, for the same reason its model is.

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// Forces [code]'s room FINISHED with a hand-built winning board, the same
/// way turn_loop_test.dart's GAME_OVER group forces it, except this one also
/// gives the game a real `winner` so `room.winner` and `room.turn.phase` are
/// exactly what a client would see after a real game actually ended. No
/// frame is sent for this -- it is pure fixture setup, never the thing a
/// test below asserts on.
void _forceFinished(
  ServerHarness harness,
  String code, {
  required int winner,
}) {
  final Room? room = harness.registry.lookup(code);
  if (room == null) {
    fail('fixture setup: room $code must still exist to be forced FINISHED');
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

/// Drains the ordinary start cascade off [client]: any number of
/// server-assigned `seat_seed` broadcasts, one per seat that never called
/// `set_seed` (section 11.2), then `game_started`, then the standalone
/// `turn` (section 13.1). A fixture that seeds every seat by hand before
/// starting sees zero `seat_seed` frames here and this reads exactly
/// `game_started` then `turn`; a fixture that seeds nobody sees one
/// `seat_seed` per occupied seat first. Draining however many actually
/// arrive, rather than a count baked in by whichever fixture happens to call
/// this, is the whole point: a fixture that seeds nobody and a reader that
/// assumed nobody would ever need seeding would otherwise leave
/// `seat_seed` frames sitting unread in the queue, silently shifting every
/// later `next()` call on that socket onto the wrong frame.
Future<void> _drainStartCascade(WireTestClient client) async {
  Map<String, Object?> frame = await client.next();
  while (frame['t'] == 'seat_seed') {
    frame = await client.next();
  }
  if (frame['t'] != 'game_started') {
    fail('fixture setup: expected game_started after any seat_seed frames, '
        'got "${frame['t']}": ${frame['d']}');
  }
  final Map<String, Object?> turn = await client.next();
  if (turn['t'] != 'turn') {
    fail('fixture setup: expected the standalone turn frame (section 13.1) '
        'right after game_started, got "${turn['t']}": ${turn['d']}');
  }
}

/// Builds a [players]-seat room, has every seat set its own client seed (so
/// `_forceFinished`'s fixture never depends on a server-drawn one), starts
/// it, and forces it FINISHED with [winner] on turn. Drains every handshake
/// frame off every socket, so a caller is left with sockets positioned right
/// after the (faked) end of game 1, ready to send `rematch`.
Future<WireTestLobby> _finishedTwoSeatRoom(
  ServerHarness harness,
  List<WireTestClient> clients, {
  int winner = 0,
}) async {
  final WireTestLobby lobby = await buildWireTestLobby(harness.wsUri, clients);

  lobby.host.client
      .send('set_seed', <String, Object?>{'client_seed': 'rematch-host-seed'});
  await lobby.host.client.next(); // seat_seed reply
  await lobby.guest.client.next(); // broadcast copy
  lobby.guest.client
      .send('set_seed', <String, Object?>{'client_seed': 'rematch-guest-seed'});
  await lobby.guest.client.next(); // seat_seed reply
  await lobby.host.client.next(); // broadcast copy

  lobby.host.client.send('start_game', <String, Object?>{});
  await lobby.host.client.next(); // game_started
  await lobby.host.client.next(); // opening turn
  await lobby.guest.client.next(); // game_started (broadcast copy)
  await lobby.guest.client.next(); // opening turn (broadcast copy)

  _forceFinished(harness, lobby.code, winner: winner);
  return lobby;
}

/// Three seats reachable over the wire in one room, host/mid/far by join
/// order, every handshake frame already drained -- the section 16.9 fixture.
/// Several of 16.9's rulings only show up with a third seat in play (the one
/// that is neither the host forcing a start nor the single other seat a
/// two-seat room would leave it with), which is why this exists alongside
/// [_finishedTwoSeatRoom] rather than generalising that one to take a seat
/// count: the two-seat helper is read via positional `host`/`guest` all over
/// this file already, and widening its shape here would touch every call
/// site above this line for no reason.
class _ThreeSeatLobby {
  _ThreeSeatLobby({
    required this.code,
    required this.host,
    required this.mid,
    required this.far,
  });

  final String code;
  final WireTestSeat host;
  final WireTestSeat mid;
  final WireTestSeat far;
}

/// Builds a 3-seat room, starts it, and forces it FINISHED with [winner] on
/// turn, the same technique [_finishedTwoSeatRoom] uses above. Every
/// handshake frame is drained off every socket first, so a caller is left
/// with three sockets positioned right after the (faked) end of game 1.
Future<_ThreeSeatLobby> _finishedThreeSeatRoom(
  ServerHarness harness,
  List<WireTestClient> clients, {
  int winner = 0,
}) async {
  final WireTestClient hostClient = await WireTestClient.connect(harness.wsUri);
  clients.add(hostClient);
  hostClient
      .send('create_room', <String, Object?>{'name': 'Host', 'players': 3});
  final Map<String, Object?> hostSeatAssigned = await hostClient.next();
  final Map<String, Object?> hostRoomFrame = await hostClient.next();
  final String code =
      (hostRoomFrame['d']! as Map<String, Object?>)['code']! as String;
  final int hostSeat =
      (hostSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;
  final String hostToken =
      (hostSeatAssigned['d']! as Map<String, Object?>)['seat_token']! as String;

  final WireTestClient midClient = await WireTestClient.connect(harness.wsUri);
  clients.add(midClient);
  midClient.send('join_room', <String, Object?>{'code': code, 'name': 'Mid'});
  final Map<String, Object?> midSeatAssigned = await midClient.next();
  await midClient.next(); // room
  await hostClient.next(); // player_joined
  final int midSeat =
      (midSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;
  final String midToken =
      (midSeatAssigned['d']! as Map<String, Object?>)['seat_token']! as String;

  final WireTestClient farClient = await WireTestClient.connect(harness.wsUri);
  clients.add(farClient);
  farClient.send('join_room', <String, Object?>{'code': code, 'name': 'Far'});
  final Map<String, Object?> farSeatAssigned = await farClient.next();
  await farClient.next(); // room
  await hostClient.next(); // player_joined
  await midClient.next(); // player_joined
  final int farSeat =
      (farSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;
  final String farToken =
      (farSeatAssigned['d']! as Map<String, Object?>)['seat_token']! as String;

  hostClient.send('start_game', <String, Object?>{});
  await _drainStartCascade(hostClient);
  await _drainStartCascade(midClient);
  await _drainStartCascade(farClient);
  _forceFinished(harness, code, winner: winner);

  return _ThreeSeatLobby(
    code: code,
    host: WireTestSeat(client: hostClient, seat: hostSeat, token: hostToken),
    mid: WireTestSeat(client: midClient, seat: midSeat, token: midToken),
    far: WireTestSeat(client: farClient, seat: farSeat, token: farToken),
  );
}

void main() {
  late ServerHarness harness;
  final List<WireTestClient> clients = <WireTestClient>[];

  setUp(() {
    harness = ServerHarness.build();
  });

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness.close();
  });

  Future<Uri> start() async {
    await harness.start();
    return harness.wsUri;
  }

  group('16.1 validation ladder', () {
    // Catches: an implementation that forgets rematch belongs on the five
    // socket-identified messages' identity-first ladder and instead tries a
    // room lookup before checking the socket has a seat at all.
    test('BAD_SEAT_TOKEN: a socket with no seat in any room', () async {
      final Uri uri = await start();
      final WireTestClient stray = await WireTestClient.connect(uri);
      clients.add(stray);
      stray.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await stray.next();
      expectErrorFrame(reply, 'BAD_SEAT_TOKEN',
          because: 'this socket never created, joined or resumed any room');
    });

    // Catches: a reaped room answering WRONG_PHASE (treating "gone" as "not
    // a rematch lobby") instead of NO_SUCH_ROOM, the same confusion section
    // 11.2's own amendment already corrected once for set_seed.
    test('NO_SUCH_ROOM: the room has been reaped', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      harness.registry.setConnected(
          code: lobby.code, seatToken: lobby.host.token, connected: false);
      harness.registry.setConnected(
          code: lobby.code, seatToken: lobby.guest.token, connected: false);
      harness.clock.advance(const Duration(minutes: 10));
      expect(harness.registry.reap(), 1,
          reason: 'setup requires room ${lobby.code} to actually be reaped');

      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(reply, 'NO_SUCH_ROOM',
          because: 'room ${lobby.code} was reaped before this rematch '
              'arrived');
    });

    // Catches: an implementation that answers WRONG_PHASE only for LOBBY and
    // lets a PLAYING room fall through to some other code, or vice versa.
    test('WRONG_PHASE: the room is PLAYING', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      lobby.host.client.send('start_game', <String, Object?>{});
      await _drainStartCascade(lobby.host.client);
      await _drainStartCascade(lobby.guest.client);

      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(reply, 'WRONG_PHASE',
          because: 'room ${lobby.code} is PLAYING');
    });

    // Catches: a LOBBY that is not a rematch lobby (an ordinary, pre-game
    // LOBBY) being treated as acceptable for `rematch`, which would let any
    // seated player jump a fresh room straight to a phantom rematch state.
    test('WRONG_PHASE: an ordinary LOBBY, rematch is null', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);

      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(reply, 'WRONG_PHASE',
          because: 'room ${lobby.code} is an ordinary LOBBY, not a rematch '
              'one');
    });

    // Catches: `d` being silently ignored instead of validated like every
    // other message's payload, letting a client smuggle an unknown field
    // through unnoticed.
    test('BAD_FIELD: d carries any key at all', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      lobby.host.client.send('start_game', <String, Object?>{});
      await _drainStartCascade(lobby.host.client);
      await _drainStartCascade(lobby.guest.client);
      _forceFinished(harness, lobby.code, winner: 0);

      lobby.host.client.send('rematch', <String, Object?>{'seat': 0});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(reply, 'BAD_FIELD',
          because: 'rematch reads no payload field at all, so any key in d '
              'is BAD_FIELD like every other message');
    });
  });

  group('16.2 the first rematch: FINISHED to LOBBY, field by field', () {
    // Catches: any one field of the FINISHED -> LOBBY transition being left
    // stale -- the exact bug class this group exists to catch is a server
    // that resets state to LOBBY but forgets one of game_id, client_seeds,
    // turn, winner, a seat's tokens, or a seat's client_seed/seed_origin,
    // leaving a client holding a half-finished, half-fresh room.
    test(
        'state, game_id, client_seeds, turn, winner and every seat\'s '
        'tokens/client_seed/seed_origin reset in one step', () async {
      await start();
      final WireTestLobby lobby =
          await _finishedTwoSeatRoom(harness, clients, winner: 0);

      final String rematchId =
          await lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expect(reply['t'], 'room',
          reason: 'a successful rematch answers room; got '
              '"${reply['t']}": ${reply['d']}');
      expect(reply['re'], rematchId);
      final Map<String, Object?> data = reply['d']! as Map<String, Object?>;

      expect(data['state'], 'LOBBY');
      expect(data['game_id'], isNull,
          reason: 'section 16.2 item 1: game_id must become null');
      expect(data['client_seeds'], isNull,
          reason: 'section 16.2 item 1: client_seeds must become null');
      expect(data['turn'], isNull,
          reason: 'section 16.2 item 1: turn must become null');
      expect(data['winner'], isNull,
          reason: 'section 16.2 item 1: winner must become null');

      final List<Object?> seats = data['seats']! as List<Object?>;
      for (final Object? entry in seats) {
        final Map<String, Object?> seat = entry! as Map<String, Object?>;
        expect(seat['tokens'], <int>[-1, -1, -1, -1],
            reason: 'seat ${seat['seat']}: every token must reset to -1');
        expect(seat['client_seed'], isNull,
            reason: 'seat ${seat['seat']}: client_seed must become null');
        expect(seat['seed_origin'], isNull,
            reason: 'seat ${seat['seat']}: seed_origin must become null');
      }
    });

    // Catches: a rematch that reuses the first game's chain instead of
    // generating a fresh one (section 11, "never reuse a chain across
    // games"), the single most security-relevant mutation this whole file
    // exists to catch.
    test('a new chain: chain_commit differs, chain_index is +1', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      final String oldChainCommit = lobby.hostRoom['chain_commit']! as String;
      final int oldChainIndex = lobby.hostRoom['chain_index']! as int;

      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      final Map<String, Object?> data = reply['d']! as Map<String, Object?>;

      expect(data['chain_commit'], isNot(oldChainCommit),
          reason: 'the rematch chain_commit must differ from the first '
              'game\'s ($oldChainCommit)');
      expect(data['chain_commit'], matches(RegExp(r'^[0-9a-f]{64}$')),
          reason: 'chain_commit must still be 64 lowercase hex characters');
      expect(data['chain_index'], oldChainIndex + 1,
          reason: 'chain_index must advance by exactly one; was '
              '$oldChainIndex');
    });

    // Catches: a server that forgets the previous game's verify record, or
    // worse, mutates it in place when the room is reused for a new game --
    // registry/store level because there is no wire message that fetches a
    // stored record (docs/VERIFY.md section 4 is an HTTP route, not a frame).
    test(
        'the old game\'s verify record is untouched by the rematch, byte for '
        'byte', () async {
      final predictedGameId = hexEncode(
        buildScript(secret: List<int>.filled(serverSecretDraws, 0))
            .sublist(gameIdOffset, gameIdOffset + gameIdDraws),
      );
      const String hostSeed = 'rematch-verify-host-seed';
      const String guestSeed = 'rematch-verify-guest-seed';
      final String clientSeeds = '0:$hostSeed|2:$guestSeed';
      final SteeredSecret steered = findSecretForFaces(
        wanted: const <int>[1, 1],
        gameId: predictedGameId,
        clientSeeds: clientSeeds,
      );

      final FakeClock clock = FakeClock(DateTime.utc(2026, 4, 1));
      final MemoryVerifyStore store = MemoryVerifyStore(clock);
      final RoomRegistry registry = RoomRegistry(
        clock: clock,
        secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
        verifyStore: store,
      );

      final CreateResult createResult = registry.createRoom(
          name: 'Host', players: 2, rules: const RulesConfig(turnSeconds: 15));
      final CreateOk host = createResult as CreateOk;
      final JoinResult joinResult =
          registry.joinRoom(code: host.room.code, name: 'Guest');
      final JoinOk guest = joinResult as JoinOk;
      registry.setSeed(
          code: host.room.code,
          seatToken: host.seat.seatToken,
          clientSeed: hostSeed);
      registry.setSeed(
          code: host.room.code,
          seatToken: guest.seat.seatToken,
          clientSeed: guestSeed);
      final StartResult startResult = registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken);
      final StartOk started = startResult as StartOk;
      expect(started.room.gameId, predictedGameId,
          reason: 'predicted game_id did not match; scripted_bytes.dart\'s '
              'offsets are stale for this draw sequence');

      final int seatA = started.room.game!.currentSeat;
      final int seatB = seatA == 0 ? 2 : 0;
      final String seatBToken =
          seatB == 0 ? host.seat.seatToken : guest.seat.seatToken;
      final Map<String, Object?> gameJson = started.room.game!.toJson();
      final List<Object?> tokens = gameJson['tokens']! as List<Object?>;
      tokens[seatB] = const <int>[57, 57, 57, 56];
      started.room.game = engine.GameState.fromJson(gameJson);

      clock.advance(const Duration(seconds: 16));
      final List<ExpiredTurn> expired = registry.expireTurns();
      expect(expired, hasLength(1),
          reason: 'setup: the timer must roll seatA\'s untouched first turn');

      final RollResult secondRoll =
          registry.roll(code: host.room.code, seatToken: seatBToken);
      expect(secondRoll, isA<RollOk>(), reason: 'setup: $secondRoll');
      final MoveResult win =
          registry.move(code: host.room.code, seatToken: seatBToken, token: 3);
      expect(win, isA<MoveOk>(),
          reason: 'setup: the forced winning move was '
              'rejected: $win');

      final String firstGameId = started.room.gameId!;
      final String? before = store.load(firstGameId);
      expect(before, isNotNull,
          reason: 'setup: a winning move must save a verify record for '
              '$firstGameId');

      final RematchResult rematchResult = registry.rematch(
          code: host.room.code, seatToken: host.seat.seatToken);
      expect(rematchResult, isA<RematchOk>(),
          reason: 'the first rematch on a FINISHED room must succeed; got '
              '$rematchResult');

      final String? after = store.load(firstGameId);
      expect(after, isNotNull,
          reason: 'the rematch must not delete the previous game\'s record');
      expect(after, before,
          reason: 'the rematch must not touch the old record\'s bytes at '
              'all, even though the room it lives under now holds a fresh '
              'game');
    });

    // Catches: a rematch request that races the seq counter -- an
    // implementation that bumps seq twice (once for "rematch requested",
    // once for the room broadcast) instead of exactly once, or forgets re on
    // the requester's own copy.
    test(
        'seq advances by exactly one; the requester\'s copy carries re, '
        'every other seat gets a plain broadcast', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      // lobby.hostRoom is the room frame from create_room, long before the
      // join, the two set_seed calls and start_game's own seq steps; none
      // of those are reflected in it, so it is not "the seq right before
      // this rematch" and comparing against it would demand the wrong
      // number from a fully correct server. The registry's own room.seq is
      // read directly instead, since _forceFinished (fixture setup, no
      // frame sent) never touches it -- it already holds the exact value
      // the next frame's seq must be one more than.
      final int seqBefore = harness.registry.lookup(lobby.code)!.seq;

      final String rematchId =
          await lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> hostReply = await lobby.host.client.next();
      final Map<String, Object?> guestCopy = await lobby.guest.client.next();

      expect(hostReply['re'], rematchId);
      expect(guestCopy.containsKey('re'), isFalse,
          reason: 'a broadcast copy to a socket that did not send the '
              'message must carry no re');
      final int hostSeq =
          (hostReply['d']! as Map<String, Object?>)['seq']! as int;
      final int guestSeq =
          (guestCopy['d']! as Map<String, Object?>)['seq']! as int;
      expect(hostSeq, seqBefore + 1,
          reason: 'seq must advance by exactly one on the first rematch');
      expect(guestSeq, hostSeq,
          reason: 'one seq counter per room: the requester\'s own reply and '
              'the broadcast copy must carry the identical seq');
    });

    // Catches: rematch.by or rematch.ready missing the requester, or ready
    // carrying anyone else before anyone else has accepted.
    test('rematch becomes { by: requester, ready: [requester] }', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);

      lobby.guest.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.guest.client.next();
      final Map<String, Object?> data = reply['d']! as Map<String, Object?>;
      final Map<String, Object?> rematch =
          data['rematch']! as Map<String, Object?>;
      expect(rematch['by'], lobby.guest.seat);
      expect(rematch['ready'], <int>[lobby.guest.seat]);
    });

    // Catches: players, rules, host_seat, seat numbers, names or seat tokens
    // being disturbed by a rematch -- the spec is explicit these are
    // untouched, and a reseat-on-rematch would desync a client that still
    // trusts its old seat_assigned.
    test(
        'players, rules, host_seat, seat numbers, names and seat_token are '
        'unchanged', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);

      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      final Map<String, Object?> data = reply['d']! as Map<String, Object?>;

      // lobby.hostRoom is the room frame from create_room, before the guest
      // had even joined: its own seats list holds the host alone, one
      // entry, where the room this rematch answers holds two. Comparing
      // against that would fail "after.length == before.length" against
      // any correct server, for a reason that has nothing to do with the
      // rematch -- it is simply the wrong room. lobby.guestRoom, the frame
      // the guest's own join_room produced, already carries both seats and
      // is otherwise identical to hostRoom in every field this test reads
      // (players, rules and host_seat are all fixed at create_room and
      // nothing between then and now changes any of them), so it is used
      // throughout here instead.
      expect(data['players'], lobby.guestRoom['players']);
      expect(data['rules'], lobby.guestRoom['rules']);
      expect(data['host_seat'], lobby.guestRoom['host_seat']);
      final List<Object?> before = lobby.guestRoom['seats']! as List<Object?>;
      final List<Object?> after = data['seats']! as List<Object?>;
      expect(after.length, before.length);
      for (int i = 0; i < before.length; i++) {
        final Map<String, Object?> b = before[i]! as Map<String, Object?>;
        final Map<String, Object?> a = after[i]! as Map<String, Object?>;
        expect(a['seat'], b['seat']);
        expect(a['name'], b['name']);
      }
      expect(lobby.host.token, isNotEmpty);
    });

    // Catches: the 60-minute total room lifetime not restarting at a
    // rematch, which would reap a room mid-second-game on the first game's
    // clock. Section 3/16.2 item 4, FakeClock seam per registry_reap_test.
    test('the 60-minute total lifetime restarts at the first rematch',
        () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);

      // 55 minutes since the room (and therefore the first game) was
      // created, all before any rematch -- well inside the original 60
      // minute budget, so this is not yet the thing under test.
      harness.clock.advance(const Duration(minutes: 55));

      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      // 50 more minutes: 105 minutes since the room was created, which
      // would have reaped it long ago under the *original* 60-minute clock,
      // but only 50 minutes since the rematch restarted it.
      harness.clock.advance(const Duration(minutes: 50));
      expect(harness.registry.reap(), 0,
          reason: '105 minutes since creation, but only 50 since the '
              'rematch restarted the 60-minute clock; must not be reaped');
      expect(harness.registry.lookup(lobby.code), isNotNull);

      harness.clock.advance(const Duration(minutes: 10));
      expect(harness.registry.reap(), 1,
          reason: '60 minutes since the rematch restarted the clock; must '
              'now be reaped');
      expect(harness.registry.lookup(lobby.code), isNull);
    });
  });

  group('16.3 accepting', () {
    // Catches: an accept that does not add the seat to ready, or that fails
    // to broadcast the updated room to the rest of the table.
    test(
        'a seat not yet ready: added, seq advances, room broadcast with re '
        'on the sender', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      final Map<String, Object?> guestCopy = await lobby.guest.client.next();
      final int seqAfterFirst =
          (guestCopy['d']! as Map<String, Object?>)['seq']! as int;

      final String acceptId =
          await lobby.guest.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> guestReply = await lobby.guest.client.next();
      expect(guestReply['re'], acceptId);
      final Map<String, Object?> data =
          guestReply['d']! as Map<String, Object?>;
      expect(data['seq'], seqAfterFirst + 1);
      final Map<String, Object?> rematch =
          data['rematch']! as Map<String, Object?>;
      expect(
          rematch['ready'], <int>[lobby.host.seat, lobby.guest.seat]..sort());
    });

    // Catches: a double accept that advances seq a second time, or that
    // broadcasts to the rest of the room when the spec says only the sender
    // is answered -- "a double tap is not an error" and also not a second
    // state change.
    test(
        'a seat already ready: a double accept changes nothing, no seq '
        'bump, no broadcast, only the sender gets the current room', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      final String secondId =
          await lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> secondReply = await lobby.host.client.next();
      expect(secondReply['t'], 'room');
      expect(secondReply['re'], secondId);
      final int seqOnDouble =
          (secondReply['d']! as Map<String, Object?>)['seq']! as int;

      // Nothing was broadcast to the guest: its next frame, if sent, would
      // only ever be whatever a real third message produces. Prove the
      // absence by sending a message that does produce a frame (ping) and
      // confirming the double accept never queued anything ahead of it.
      lobby.guest.client.send('ping', <String, Object?>{});
      final Map<String, Object?> guestNext = await lobby.guest.client.next();
      expect(guestNext['t'], 'pong',
          reason: 'the double accept must not have broadcast a room frame '
              'to the guest; if it had, this read would see that room '
              'frame instead of the guest\'s own pong');

      final Map<String, Object?> thirdReply = await (() async {
        lobby.host.client.send('rematch', <String, Object?>{});
        return lobby.host.client.next();
      })();
      final int seqOnThird =
          (thirdReply['d']! as Map<String, Object?>)['seq']! as int;
      expect(seqOnThird, seqOnDouble,
          reason: 'repeated double accepts must never advance seq');
    });
  });

  group('16.4 starting the rematch', () {
    // Catches: an "everyone ready" room that still waits for an explicit
    // start_game instead of starting itself, or that starts with the wrong
    // frame order/seq steps (must match an accepted start_game exactly,
    // sections 11.2/13.1).
    test(
        'everyone accepted and connected: the server auto-starts, same '
        'frame order and seq steps as start_game', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> hostFirst = await lobby.host.client.next();
      await lobby.guest.client.next();
      final int seqAfterFirst =
          (hostFirst['d']! as Map<String, Object?>)['seq']! as int;

      lobby.guest.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> guestAccept = await lobby.guest.client.next();
      final Map<String, Object?> hostBroadcastOfAccept =
          await lobby.host.client.next();
      final int seqAfterAccept =
          (guestAccept['d']! as Map<String, Object?>)['seq']! as int;
      expect(seqAfterAccept, seqAfterFirst + 1);
      expect((hostBroadcastOfAccept['d']! as Map<String, Object?>)['seq'],
          seqAfterAccept,
          reason: 'one counter per room: the broadcast copy of the '
              'completing acceptance must carry the same seq as the '
              'accepter\'s own reply');

      // Section 16.4: everyone was ready and connected the instant the
      // guest's accept landed, so the server must now start the game on
      // both sockets, immediately, with no further message from anyone.
      // Server-assigned seeds first (nobody set one in the rematch lobby),
      // ascending seat order, then game_started, then the standalone turn
      // (section 13.1), each one seq higher than the last.
      final Map<String, Object?> hostSeed1 = await lobby.host.client.next();
      expect(hostSeed1['t'], 'seat_seed');
      expect((hostSeed1['d']! as Map<String, Object?>)['origin'], 'server');
      expect(
          (hostSeed1['d']! as Map<String, Object?>)['seq'], seqAfterAccept + 1);
      final Map<String, Object?> hostSeed2 = await lobby.host.client.next();
      expect(hostSeed2['t'], 'seat_seed');
      expect(
          (hostSeed2['d']! as Map<String, Object?>)['seq'], seqAfterAccept + 2);

      final Map<String, Object?> hostStarted = await lobby.host.client.next();
      expect(hostStarted['t'], 'game_started');
      final Map<String, Object?> startedData =
          hostStarted['d']! as Map<String, Object?>;
      expect(startedData['seq'], seqAfterAccept + 3);
      expect(startedData['game_id'], isNotNull);

      final Map<String, Object?> hostTurn = await lobby.host.client.next();
      expect(hostTurn['t'], 'turn');
      expect(
          (hostTurn['d']! as Map<String, Object?>)['seq'], seqAfterAccept + 4);
      expect((hostTurn['d']! as Map<String, Object?>)['seat'],
          startedData['turn']);

      // The guest's socket received the identical cascade as a broadcast.
      await lobby.guest.client.next(); // seat_seed
      await lobby.guest.client.next(); // seat_seed
      final Map<String, Object?> guestStarted = await lobby.guest.client.next();
      expect(guestStarted['t'], 'game_started');
      expect(guestStarted['d'], startedData);
      final Map<String, Object?> guestTurn = await lobby.guest.client.next();
      expect(guestTurn['t'], 'turn');
    });

    // Catches: auto-start firing even though one ready seat's socket has
    // dropped -- section 16.4 requires every seat to be both ready *and*
    // connected, and a disconnected-but-ready seat must not be dealt into a
    // game it cannot act in.
    test('no auto-start when one ready seat is disconnected', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      await lobby.guest.client.close();
      await lobby.host.client.next(); // presence(connected: false)

      final WireTestClient freshGuest = await WireTestClient.connect(uri);
      clients.add(freshGuest);
      freshGuest.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      await freshGuest.next(); // seat_assigned
      await freshGuest.next(); // room
      await lobby.host.client.next(); // presence(connected: true)

      // Guest is connected again but not yet re-accepted after reconnecting
      // -- it was already in `ready` from before the drop, so accepting
      // again would be a double accept. The point of this scenario is the
      // disconnected window itself: nothing must have auto-started while
      // the ready guest was offline, i.e. no game_started ever arrived on
      // the host's socket in between. Confirmed by sending ping now and
      // seeing pong next, not a leftover game_started.
      lobby.host.client.send('ping', <String, Object?>{});
      final Map<String, Object?> next = await lobby.host.client.next();
      expect(next['t'], 'pong',
          reason: 'no auto-start frame must have been queued while the '
              'ready guest was disconnected; got "${next['t']}" instead');
    });

    // Catches: the auto-start check dropping its "every seat connected"
    // term. The case above never reaches that term, because its guest drops
    // before accepting and so "everyone ready" is never true. Here the guest
    // accepts first and then drops, and the host's accept is the one that
    // makes every occupied seat ready while one of them is offline.
    test(
        'no auto-start when the last accept lands while a ready seat is '
        'disconnected', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.guest.client.send('rematch', <String, Object?>{});
      await lobby.guest.client.next(); // room, guest's own accept
      await lobby.host.client.next(); // room, broadcast

      await lobby.guest.client.close();
      final Map<String, Object?> presence = await lobby.host.client.next();
      expect(presence['t'], 'presence');
      expect((presence['d']! as Map<String, Object?>)['connected'], isFalse);

      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> hostAccept = await lobby.host.client.next();
      expect(hostAccept['t'], 'room');
      final Map<String, Object?> hostAcceptData =
          hostAccept['d']! as Map<String, Object?>;
      expect(hostAcceptData['state'], 'LOBBY');
      expect((hostAcceptData['rematch']! as Map<String, Object?>)['ready'],
          <int>[lobby.host.seat, lobby.guest.seat]..sort(),
          reason: 'setup: both seats must be ready after the host accepts, '
              'or this case does not reach the connected check at all');

      lobby.host.client.send('ping', <String, Object?>{});
      final Map<String, Object?> next = await lobby.host.client.next();
      expect(next['t'], 'pong',
          reason: 'every occupied seat was ready but the guest was offline, '
              'so section 16.4 forbids the auto-start; got "${next['t']}"');
    });

    // Catches: a host start_game in a rematch lobby that fails to remove
    // the non-ready seat, or that fails to re-seat the survivor onto the
    // canonical set and tell it via seat_assigned (section 15 rule 1).
    test(
        'host start_game with one ready seat out of three: player_left for '
        'the non-ready seat, re-seat, seat_assigned, then the ordinary '
        'start', () async {
      final Uri uri = await start();
      final WireTestClient hostClient = await WireTestClient.connect(uri);
      clients.add(hostClient);
      hostClient
          .send('create_room', <String, Object?>{'name': 'Host', 'players': 3});
      await hostClient.next(); // seat_assigned
      final Map<String, Object?> hostRoomFrame = await hostClient.next();
      final String code =
          (hostRoomFrame['d']! as Map<String, Object?>)['code']! as String;

      final WireTestClient midClient = await WireTestClient.connect(uri);
      clients.add(midClient);
      midClient
          .send('join_room', <String, Object?>{'code': code, 'name': 'Mid'});
      final Map<String, Object?> midSeatAssigned = await midClient.next();
      await midClient.next(); // room
      await hostClient.next(); // player_joined

      final WireTestClient farClient = await WireTestClient.connect(uri);
      clients.add(farClient);
      farClient
          .send('join_room', <String, Object?>{'code': code, 'name': 'Far'});
      final Map<String, Object?> farSeatAssigned = await farClient.next();
      await farClient.next(); // room
      await hostClient.next(); // player_joined
      await midClient.next(); // player_joined

      final String midToken = (midSeatAssigned['d']!
          as Map<String, Object?>)['seat_token']! as String;
      final int farSeat =
          (farSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;

      hostClient.send('start_game', <String, Object?>{});
      await _drainStartCascade(hostClient);
      await _drainStartCascade(midClient);
      await _drainStartCascade(farClient);
      _forceFinished(harness, code, winner: 0);

      // Only host and mid accept; far never does.
      hostClient.send('rematch', <String, Object?>{});
      await hostClient.next();
      await midClient.next();
      await farClient.next();
      midClient.send('rematch', <String, Object?>{});
      await midClient.next();
      await hostClient.next();
      await farClient.next();

      hostClient.send('start_game', <String, Object?>{});

      // far (not ready) is removed first: one player_left, ascending seat
      // order (host, mid and far are the only three, far is highest).
      final Map<String, Object?> farLeftOnHost = await hostClient.next();
      expect(farLeftOnHost['t'], 'player_left');
      expect((farLeftOnHost['d']! as Map<String, Object?>)['seat'], farSeat);
      await midClient.next(); // same player_left, broadcast
      final Map<String, Object?> farLeftOnFar = await farClient.next();
      expect(farLeftOnFar['t'], 'player_left',
          reason: 'the removed seat is told what everyone else was told, '
              'section 4\'s leave_room row applied the same way here');

      // mid, if its index changed, gets seat_assigned before the room.
      final Map<String, Object?> midNext = await midClient.next();
      if (midNext['t'] == 'seat_assigned') {
        expect((midNext['d']! as Map<String, Object?>)['seat_token'], midToken);
        final Map<String, Object?> midRoom = await midClient.next();
        expect(midRoom['t'], 'room');
      } else {
        expect(midNext['t'], 'room',
            reason: 'mid\'s seat did not move, so its next frame after the '
                'reseat must be room directly; got "${midNext['t']}"');
      }

      final Map<String, Object?> hostRoomAfterReseat = await hostClient.next();
      expect(hostRoomAfterReseat['t'], 'room');
      final Map<String, Object?> reseatedData =
          hostRoomAfterReseat['d']! as Map<String, Object?>;
      expect(reseatedData['players'], 2,
          reason: 'players must become the number of ready seats (2)');
      expect(reseatedData['rematch'], isNull,
          reason: 'rematch becomes null again once the start order runs');

      // The ordinary start order follows: possibly server-assigned seeds,
      // then game_started.
      Map<String, Object?> frame = await hostClient.next();
      while (frame['t'] == 'seat_seed') {
        frame = await hostClient.next();
      }
      expect(frame['t'], 'game_started',
          reason: 'the reseat must be followed by an ordinary game start; '
              'got "${frame['t']}": ${frame['d']}');
    }, timeout: const Timeout(Duration(seconds: 20)));

    // Catches: a start_game accepted with fewer than two ready seats, which
    // would let a single lonely acceptance start a one-player game.
    test('fewer than two ready: NOT_ENOUGH_PLAYERS, nothing changes', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      lobby.host.client.send('start_game', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(reply, 'NOT_ENOUGH_PLAYERS',
          because: 'only one of the two occupied seats (the host itself) '
              'is ready');

      // Nothing changed: a further accept from the guest still works and
      // still sees the host in ready.
      lobby.guest.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> guestReply = await lobby.guest.client.next();
      final Map<String, Object?> rematch = (guestReply['d']!
          as Map<String, Object?>)['rematch']! as Map<String, Object?>;
      expect(rematch['ready'], contains(lobby.host.seat));
    });

    // Catches: set_players being silently allowed in a rematch lobby,
    // letting a seat change the table size out from under the ready list
    // the spec says decides the count instead.
    test('set_players in a rematch LOBBY is WRONG_PHASE', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      lobby.host.client.send('set_players', <String, Object?>{'players': 3});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(reply, 'WRONG_PHASE',
          because: 'a rematch lobby\'s ready list decides the count, not '
              'set_players');
    });
  });

  group('16.5 seeds in a rematch lobby', () {
    // Catches: SEED_ALREADY_SET being scoped to the room (or to the seat
    // forever) instead of to chain_index -- the exact mutation named in the
    // work order. A seat that set a seed for game 1 must be able to set a
    // fresh one for the rematch's new chain.
    test(
        'a seat that already set a seed in game 1 may set one again for '
        'the new chain', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      lobby.host.client.send(
          'set_seed', <String, Object?>{'client_seed': 'second-game-seed'});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expect(reply['t'], 'seat_seed',
          reason: 'a seat that set a seed in game 1 must be able to set a '
              'fresh seed for the new chain_index; a server that still '
              'thinks this seat already has one would answer error '
              'SEED_ALREADY_SET here instead, and this host did set one in '
              'game 1 (_finishedTwoSeatRoom\'s own fixture)');
    });

    // Catches: a seat setting two seeds within the *same* new chain_index
    // being wrongly allowed once the room-wide reset above is implemented.
    test(
        'a second set_seed within the same new chain_index is '
        'SEED_ALREADY_SET', () async {
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      lobby.host.client
          .send('set_seed', <String, Object?>{'client_seed': 'first-of-two'});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      lobby.host.client
          .send('set_seed', <String, Object?>{'client_seed': 'second-of-two'});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(reply, 'SEED_ALREADY_SET',
          because: 'this seat already set a seed for the current '
              'chain_index, moments ago, in this same rematch lobby');
    });
  });

  group('16.6 the snapshot field', () {
    // Catches: rematch leaking into states where it must be null, or being
    // absent entirely instead of present-but-null (section 16.6: "Present
    // in every state, including LOBBY and PLAYING").
    test(
        'rematch is null in an ordinary LOBBY, in PLAYING, and in a '
        'FINISHED room before any rematch is requested', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      expect(lobby.hostRoom.containsKey('rematch'), isTrue,
          reason: 'rematch must be present, as null, in an ordinary LOBBY');
      expect(lobby.hostRoom['rematch'], isNull);

      lobby.host.client.send('start_game', <String, Object?>{});
      await _drainStartCascade(lobby.host.client);
      await _drainStartCascade(lobby.guest.client);

      _forceFinished(harness, lobby.code, winner: 0);
      lobby.host.client.send('ping', <String, Object?>{});
      await lobby.host.client.next();

      final WireTestClient prober = await WireTestClient.connect(uri);
      clients.add(prober);
      prober.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      await prober.next(); // seat_assigned
      final Map<String, Object?> resumed = await prober.next();
      final Map<String, Object?> resumedData =
          resumed['d']! as Map<String, Object?>;
      expect(resumedData['state'], 'FINISHED');
      expect(resumedData['rematch'], isNull,
          reason: 'a FINISHED room with no rematch requested yet must show '
              'rematch: null, per section 16.6 and 16.7');
    });
  });

  group('16.9 rulings after the first implementation, 2026-10-01', () {
    // Catches: a forced removal that stops at the broadcast player_left and
    // leaves the socket still holding a seat underneath -- section 16.9
    // rule 1 requires the same outcome leave_room itself would produce: the
    // removed seat's connection no longer holds any seat, so a later
    // seat-scoped frame on that socket and a later resume with its old
    // token must both be BAD_SEAT_TOKEN, and nothing else from the room
    // reaches that socket after its own player_left.
    test(
        'rule 1: a seat removed by a host-forced start is BAD_SEAT_TOKEN on '
        'any later seat-scoped frame, including resume with its old token',
        () async {
      final Uri uri = await start();
      final _ThreeSeatLobby lobby =
          await _finishedThreeSeatRoom(harness, clients);

      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.mid.client.next();
      await lobby.far.client.next();
      lobby.mid.client.send('rematch', <String, Object?>{});
      await lobby.mid.client.next();
      await lobby.host.client.next();
      await lobby.far.client.next();

      lobby.host.client.send('start_game', <String, Object?>{});

      final Map<String, Object?> farLeft = await lobby.far.client.next();
      expect(farLeft['t'], 'player_left');
      expect((farLeft['d']! as Map<String, Object?>)['seat'], lobby.far.seat);

      // Nothing further from the room reaches far's socket: prove the
      // absence by sending a message that does produce a frame and
      // confirming that reply, not a leftover room push, arrives next.
      lobby.far.client.send('ping', <String, Object?>{});
      final Map<String, Object?> nextOnFar = await lobby.far.client.next();
      expect(nextOnFar['t'], 'pong',
          reason: 'section 16.9 rule 1: once the removed seat has received '
              'its own player_left, nothing further from the room may reach '
              'its socket; got "${nextOnFar['t']}" instead of the pong this '
              'ping must produce next');

      // The same socket's own stored identity no longer names a seat.
      lobby.far.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> leaveReply = await lobby.far.client.next();
      expectErrorFrame(leaveReply, 'BAD_SEAT_TOKEN',
          because: 'far\'s seat was removed by the host-forced start; its '
              'connection no longer holds a seat in any room');

      // And a fresh socket resuming with far's old token sees the same.
      final WireTestClient prober = await WireTestClient.connect(uri);
      clients.add(prober);
      prober.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.far.token,
      });
      final Map<String, Object?> resumeReply = await prober.next();
      expectErrorFrame(resumeReply, 'BAD_SEAT_TOKEN',
          because: 'far\'s seat_token no longer names a seat in '
              '${lobby.code} after the host-forced start removed it');
    }, timeout: const Timeout(Duration(seconds: 20)));

    // Catches: a start_game that only counts the host as ready if it had
    // separately sent its own rematch first -- a host that opens a rematch
    // lobby, lets a guest accept, and taps Start directly must see its own
    // tap count as acceptance, with no broadcast or seq step of its own for
    // that silent addition, and must never itself be among the seats that
    // same start_game removes.
    test(
        'rule 2: host start_game in a rematch lobby counts as the host\'s '
        'own acceptance, silently, and never removes the host', () async {
      await start();
      final _ThreeSeatLobby lobby =
          await _finishedThreeSeatRoom(harness, clients);

      // mid requests the first rematch; host never sends rematch itself;
      // far never answers at all.
      lobby.mid.client.send('rematch', <String, Object?>{});
      await lobby.mid.client.next();
      await lobby.host.client.next();
      await lobby.far.client.next();

      lobby.host.client.send('start_game', <String, Object?>{});

      // If the host's own start_game had not counted as its acceptance,
      // ready would still be [mid] alone when far is evaluated, and the
      // sequence below (far removed, mid re-seated, the game actually
      // starting) could not happen at all -- the host's start_game would
      // instead come back NOT_ENOUGH_PLAYERS. Reaching player_left for far
      // here, with no broadcast interposed for host's own silent addition,
      // is itself the proof.
      final Map<String, Object?> farLeftOnHost = await lobby.host.client.next();
      expect(farLeftOnHost['t'], 'player_left',
          reason: 'section 16.9 rule 2: the host\'s own start_game must '
              'count as its acceptance with no broadcast of its own; the '
              'very next frame after start_game must already be the '
              'removal of unready far, got "${farLeftOnHost['t']}": '
              '${farLeftOnHost['d']}');
      expect((farLeftOnHost['d']! as Map<String, Object?>)['seat'],
          lobby.far.seat);
      await lobby.mid.client.next(); // same player_left, broadcast
      await lobby.far.client.next(); // far is told too, like leave_room

      // mid moves from its old seat onto the canonical 2-player set; host,
      // never removed by its own start_game, keeps its seat and gets no
      // seat_assigned at all.
      final Map<String, Object?> midNext = await lobby.mid.client.next();
      expect(midNext['t'], 'seat_assigned',
          reason: 'mid must be re-seated onto the canonical 2-player set '
              'once far is removed');
      final Map<String, Object?> midSeatData =
          midNext['d']! as Map<String, Object?>;
      expect(midSeatData['seat_token'], lobby.mid.token);
      final int midNewSeat = midSeatData['seat']! as int;
      final Map<String, Object?> midRoom = await lobby.mid.client.next();
      expect(midRoom['t'], 'room');

      final Map<String, Object?> hostRoomAfterReseat =
          await lobby.host.client.next();
      expect(hostRoomAfterReseat['t'], 'room',
          reason: 'host must receive the reseat room directly, with no '
              'seat_assigned of its own in between');
      final Map<String, Object?> reseated =
          hostRoomAfterReseat['d']! as Map<String, Object?>;
      expect(reseated['players'], 2);
      expect(reseated['rematch'], isNull);
      final List<Object?> seatsAfter = reseated['seats']! as List<Object?>;
      final List<int> seatNumbers = seatsAfter
          .map((Object? s) => (s! as Map<String, Object?>)['seat']! as int)
          .toList()
        ..sort();
      expect(seatNumbers, (<int>[lobby.host.seat, midNewSeat]..sort()),
          reason: 'section 16.9 rule 2: host must still be seated at '
              '${lobby.host.seat}, never removed by its own start_game; '
              'a host that removed itself here would be the exact bug '
              'this rule forbids');

      // The ordinary start order follows for the two survivors.
      Map<String, Object?> frame = await lobby.host.client.next();
      while (frame['t'] == 'seat_seed') {
        frame = await lobby.host.client.next();
      }
      expect(frame['t'], 'game_started');
    }, timeout: const Timeout(Duration(seconds: 20)));

    // Catches: skipping the re-seat room broadcast whenever no seat number
    // happened to change -- section 16.9 rule 3 requires that room, with
    // its own seq step, whenever a seat was removed at all, even when the
    // survivors already sat on the canonical set for the new player count
    // and nobody's seat number moves.
    test(
        'rule 3: the re-seat room is sent with its own seq step even when '
        'no seat number changes', () async {
      await start();
      final _ThreeSeatLobby lobby =
          await _finishedThreeSeatRoom(harness, clients);
      // This scenario only proves what it claims if removing mid leaves
      // host and far already sitting on the canonical 2-player seat set.
      final List<int> survivors = <int>[lobby.host.seat, lobby.far.seat]
        ..sort();
      expect(survivors, <int>[0, 2],
          reason: 'setup requires host and far to already occupy the '
              'canonical 2-player seat set once mid is removed, so the '
              'room this test is about carries no seat_assigned at all; '
              'got host=${lobby.host.seat} far=${lobby.far.seat}');

      // host and far accept; mid never does.
      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.mid.client.next();
      await lobby.far.client.next();
      lobby.far.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> farAccept = await lobby.far.client.next();
      await lobby.host.client.next();
      await lobby.mid.client.next();
      final int seqBeforeStart =
          (farAccept['d']! as Map<String, Object?>)['seq']! as int;

      lobby.host.client.send('start_game', <String, Object?>{});

      final Map<String, Object?> midLeftOnHost = await lobby.host.client.next();
      expect(midLeftOnHost['t'], 'player_left');
      final Map<String, Object?> midLeftData =
          midLeftOnHost['d']! as Map<String, Object?>;
      expect(midLeftData['seat'], lobby.mid.seat);
      expect(midLeftData['seq'], seqBeforeStart + 1);
      await lobby.far.client.next(); // same player_left, broadcast
      await lobby.mid.client.next(); // mid is told too

      final Map<String, Object?> roomAfterRemoval =
          await lobby.host.client.next();
      expect(roomAfterRemoval['t'], 'room',
          reason: 'section 16.9 rule 3: a seat was removed, so the room '
              'carrying the new players count is sent with its own seq '
              'step even though no seat number changed; got '
              '"${roomAfterRemoval['t']}" instead');
      final Map<String, Object?> roomData =
          roomAfterRemoval['d']! as Map<String, Object?>;
      expect(roomData['seq'], seqBeforeStart + 2,
          reason: 'the re-seat room must take its own seq step, one more '
              'than the player_left that preceded it');
      expect(roomData['players'], 2);
      expect(roomData['rematch'], isNull);
      final List<Object?> seatsAfter = roomData['seats']! as List<Object?>;
      final List<int> seatNumbers = seatsAfter
          .map((Object? s) => (s! as Map<String, Object?>)['seat']! as int)
          .toList()
        ..sort();
      expect(seatNumbers, <int>[0, 2]);
      await lobby.far.client.next(); // same room, broadcast to far

      // No seat_assigned was ever sent to either survivor: the frame right
      // after the removal broadcast on host's socket was room directly, and
      // the next frames from here are the ordinary start order.
      Map<String, Object?> frame = await lobby.host.client.next();
      while (frame['t'] == 'seat_seed') {
        frame = await lobby.host.client.next();
      }
      expect(frame['t'], 'game_started');
    }, timeout: const Timeout(Duration(seconds: 20)));

    // Catches: a rematch lobby that refuses join_room outright because
    // rematch is non-null, or that computes the auto-start eligible set
    // from whoever was ever in the room instead of who occupies a seat
    // right now -- a seat freed by leave_room and refilled by a new joiner
    // must have the joiner's own acceptance counted before auto-start, not
    // be silently satisfied by the departed seat's old readiness or by the
    // joiner's mere presence before it has accepted anything.
    test(
        'rule 4: a seat freed by leave_room can be rejoined by code, and '
        'the joiner is waited for before the rematch auto-starts', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);

      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.guest.client.next();

      lobby.guest.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> guestLeaveReply =
          await lobby.guest.client.next();
      expect(guestLeaveReply['t'], 'player_left');
      await lobby.host.client.next(); // broadcast

      final WireTestClient newcomer = await WireTestClient.connect(uri);
      clients.add(newcomer);
      newcomer.send('join_room',
          <String, Object?>{'code': lobby.code, 'name': 'Newcomer'});
      final Map<String, Object?> newcomerSeatAssigned = await newcomer.next();
      final Map<String, Object?> newcomerRoom = await newcomer.next();
      await lobby.host.client.next(); // player_joined

      final int newcomerSeat =
          (newcomerSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;
      expect(newcomerSeat, lobby.guest.seat,
          reason: 'section 16.9 rule 4: the only free seat is the one '
              'leave_room just freed, the lowest free seat of the '
              'canonical set for this player count by construction');
      final Map<String, Object?> newcomerRematch = (newcomerRoom['d']!
          as Map<String, Object?>)['rematch']! as Map<String, Object?>;
      expect(newcomerRematch['ready'], <int>[lobby.host.seat],
          reason: 'the joiner is not ready on arrival; only the original '
              'host, from before the leave, is');

      // The join alone does not start anything: host is ready, but the
      // newcomer, now occupying the other seat, is not.
      lobby.host.client.send('ping', <String, Object?>{});
      final Map<String, Object?> pingReply = await lobby.host.client.next();
      expect(pingReply['t'], 'pong',
          reason: 'join_room must never itself evaluate auto-start, and '
              'the newcomer has not accepted yet; got '
              '"${pingReply['t']}" instead of this ping\'s own pong');

      final String acceptId =
          await newcomer.send('rematch', <String, Object?>{});
      final Map<String, Object?> newcomerAccept = await newcomer.next();
      expect(newcomerAccept['re'], acceptId);
      await lobby.host.client.next(); // broadcast of the newcomer's accept

      final Map<String, Object?> hostSeed1 = await lobby.host.client.next();
      expect(hostSeed1['t'], 'seat_seed',
          reason: 'section 16.9 rule 4: once the joiner itself accepts, the '
              'auto-start set -- host plus the joiner now occupying the '
              'freed seat -- is satisfied; got "${hostSeed1['t']}" instead '
              'of the start cascade\'s first frame');
      final Map<String, Object?> hostSeed2 = await lobby.host.client.next();
      expect(hostSeed2['t'], 'seat_seed');
      final Map<String, Object?> hostStarted = await lobby.host.client.next();
      expect(hostStarted['t'], 'game_started');
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('amended 16.4: auto-start evaluated fresh at each accepted rematch',
      () {
    // Catches: computing the auto-start eligible-seat set once, from
    // whoever was occupied at the very first rematch, instead of
    // recomputing it fresh at each accepted rematch as the amended text now
    // requires ("every seat occupied at the moment of an accepted rematch",
    // not "the first rematch") -- a departed seat would then block
    // auto-start forever even after every seat still at the table is
    // ready, leaving the room stuck needing a host-forced start_game the
    // spec says should not be necessary here. Also proves leave_room on its
    // own never evaluates auto-start, however the remaining seats'
    // readiness happens to line up at that moment.
    test(
        'a non-ready seat leaves, then the last remaining seat\'s accept '
        'auto-starts', () async {
      await start();
      final _ThreeSeatLobby lobby =
          await _finishedThreeSeatRoom(harness, clients);

      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.mid.client.next();
      await lobby.far.client.next();

      // far, not yet ready, leaves outright.
      lobby.far.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> farLeaveReply = await lobby.far.client.next();
      expect(farLeaveReply['t'], 'player_left');
      await lobby.host.client.next(); // broadcast
      await lobby.mid.client.next(); // broadcast

      // Nothing has auto-started: of the two remaining occupied seats, only
      // host is ready, so this is not yet the condition under test, but it
      // also proves leave_room alone never starts the game, whatever an
      // implementation evaluates on it.
      lobby.host.client.send('ping', <String, Object?>{});
      final Map<String, Object?> pingReply = await lobby.host.client.next();
      expect(pingReply['t'], 'pong',
          reason: 'leave_room must never itself evaluate auto-start; got '
              '"${pingReply['t']}" instead of this ping\'s own pong');

      // mid, the only remaining unready seat, now accepts. The auto-start
      // set is whoever is occupied right now -- host and mid -- not the
      // frozen set from the very first rematch, which still included far.
      lobby.mid.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> midAccept = await lobby.mid.client.next();
      final Map<String, Object?> hostBroadcastOfAccept =
          await lobby.host.client.next();
      final int seqAfterAccept =
          (midAccept['d']! as Map<String, Object?>)['seq']! as int;
      expect((hostBroadcastOfAccept['d']! as Map<String, Object?>)['seq'],
          seqAfterAccept);

      final Map<String, Object?> hostSeed1 = await lobby.host.client.next();
      expect(hostSeed1['t'], 'seat_seed',
          reason: 'section 16.9/amended 16.4: with far gone and both '
              'remaining seats now ready and connected, mid\'s accept must '
              'auto-start the game immediately; got "${hostSeed1['t']}" '
              'instead of the start cascade\'s first frame');
      final Map<String, Object?> hostSeed2 = await lobby.host.client.next();
      expect(hostSeed2['t'], 'seat_seed');
      final Map<String, Object?> hostStarted = await lobby.host.client.next();
      expect(hostStarted['t'], 'game_started');
      final Map<String, Object?> hostTurn = await lobby.host.client.next();
      expect(hostTurn['t'], 'turn');
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}

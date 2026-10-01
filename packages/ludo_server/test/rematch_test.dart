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
      await lobby.host.client.next(); // game_started
      await lobby.host.client.next(); // opening turn
      await lobby.guest.client.next();
      await lobby.guest.client.next();

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
      await lobby.host.client.next();
      await lobby.host.client.next();
      await lobby.guest.client.next();
      await lobby.guest.client.next();
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
      final Uri uri = await start();
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
      final Uri uri = await start();
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
      final Uri uri = await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      final int seqBefore = lobby.hostRoom['seq']! as int;

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
      final Uri uri = await start();
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
      final Uri uri = await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);

      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      final Map<String, Object?> data = reply['d']! as Map<String, Object?>;

      expect(data['players'], lobby.hostRoom['players']);
      expect(data['rules'], lobby.hostRoom['rules']);
      expect(data['host_seat'], lobby.hostRoom['host_seat']);
      final List<Object?> before = lobby.hostRoom['seats']! as List<Object?>;
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
      final Uri uri = await start();
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
      final Uri uri = await start();
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
      final Uri uri = await start();
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
      final Uri uri = await start();
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

      final int midSeat =
          (midSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;
      final String midToken = (midSeatAssigned['d']!
          as Map<String, Object?>)['seat_token']! as String;
      final int farSeat =
          (farSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;

      hostClient.send('start_game', <String, Object?>{});
      await hostClient.next(); // game_started
      await hostClient.next(); // opening turn
      await midClient.next();
      await midClient.next();
      await farClient.next();
      await farClient.next();
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
      final Uri uri = await start();
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
      final Uri uri = await start();
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
      final Uri uri = await start();
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
      final Uri uri = await start();
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
      final Map<String, Object?> started = await lobby.host.client.next();
      await lobby.host.client.next();
      await lobby.guest.client.next();
      await lobby.guest.client.next();
      expect(started['t'], 'game_started');

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
}

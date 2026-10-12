// Conformance tests for docs/PROTOCOL.md section 18 ("Leaving a table, and
// who is host after"), one test per bullet of rule 6, written from the spec
// before order 314's implementation exists. Every assertion is on frames as
// a client receives them -- type, re, host_seat, seq -- over a real
// WireServer via test/support/wire_harness.dart, the same way
// rematch_test.dart holds its own section (16). FINISHED is reached the
// cheap way rematch_test.dart's own _forceFinished does -- a hand-built
// GameState with a winner, Room.state mutated directly, no frame sent for
// it -- everywhere except the one test that needs a real, saved verify
// record, which plays an actual game to a real win through RoomRegistry
// directly and never opens a socket at all, the same split rematch_test.dart
// draws for the same reason (see its header and its own "the old game's
// verify record is untouched" test). That is bullet 6's rule-4 test below,
// split into two: one wire-level test for the frames themselves, and one
// registry-level test for the byte-identical verify record, because no
// single technique covers both without paying for a 60+ roll natural win.
//
// Section 18's own numbering is reused in the group names below (rule 6's
// bullets are numbered 1-8 in docs/PROTOCOL.md; this file numbers its
// groups the same way).

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// Forces [code]'s room FINISHED with a hand-built winning board, identical
/// in technique to rematch_test.dart's own `_forceFinished` (same file,
/// same justification: "the same direct mutation of Room.state the turn
/// loop itself is documented to perform"). No frame is sent for this -- it
/// is pure fixture setup, never the thing a test below asserts on.
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
/// `set_seed`, then `game_started`, then the standalone `turn` (section
/// 13.1). Identical in behaviour to rematch_test.dart's own
/// `_drainStartCascade`.
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

/// Three seats reachable over the wire in one room, host/mid/far by join
/// order, every handshake frame already drained -- canonical seats 0, 1, 2
/// for a three-player room (docs/PROTOCOL.md section 15 /
/// lib/src/registry.dart's `_seatIndicesFor`), so host is always seat 0.
/// Left in LOBBY; callers that need FINISHED call [_startAndFinish] on it.
class _ThreeSeatLobby {
  _ThreeSeatLobby({
    required this.harness,
    required this.code,
    required this.host,
    required this.mid,
    required this.far,
  });

  final ServerHarness harness;
  final String code;
  final WireTestSeat host;
  final WireTestSeat mid;
  final WireTestSeat far;
}

Future<_ThreeSeatLobby> _buildThreeSeatLobby(
  ServerHarness harness,
  List<WireTestClient> clients,
) async {
  final Uri uri = harness.wsUri;
  final WireTestClient hostClient = await WireTestClient.connect(uri);
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

  final WireTestClient midClient = await WireTestClient.connect(uri);
  clients.add(midClient);
  midClient.send('join_room', <String, Object?>{'code': code, 'name': 'Mid'});
  final Map<String, Object?> midSeatAssigned = await midClient.next();
  await midClient.next(); // room
  await hostClient.next(); // player_joined
  final int midSeat =
      (midSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;
  final String midToken =
      (midSeatAssigned['d']! as Map<String, Object?>)['seat_token']! as String;

  final WireTestClient farClient = await WireTestClient.connect(uri);
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

  return _ThreeSeatLobby(
    harness: harness,
    code: code,
    host: WireTestSeat(client: hostClient, seat: hostSeat, token: hostToken),
    mid: WireTestSeat(client: midClient, seat: midSeat, token: midToken),
    far: WireTestSeat(client: farClient, seat: farSeat, token: farToken),
  );
}

/// Starts [lobby]'s room for real, drains the start cascade off every
/// socket, then forces the room FINISHED the cheap way, with [winner] on
/// turn.
Future<void> _startAndFinish(
  _ThreeSeatLobby lobby, {
  int winner = 0,
}) async {
  lobby.host.client.send('start_game', <String, Object?>{});
  await _drainStartCascade(lobby.host.client);
  await _drainStartCascade(lobby.mid.client);
  await _drainStartCascade(lobby.far.client);
  _forceFinished(lobby.harness, lobby.code, winner: winner);
}

/// A two-seat room, started and forced FINISHED the cheap way -- the
/// bullet-6 fixture. No seat ever calls `set_seed` here: nothing in bullet
/// 6 reads a seed, and the server-assigned fallback (section 11.2) exercises
/// the same `_drainStartCascade` path bullet 7's three-seat fixture already
/// needs, so one path covers both rather than two hand-copies drifting from
/// each other.
Future<WireTestLobby> _finishedTwoSeatLobby(
  ServerHarness harness,
  List<WireTestClient> clients, {
  int winner = 0,
}) async {
  final WireTestLobby lobby =
      await buildWireTestLobby(harness.wsUri, clients, players: 2);
  lobby.host.client.send('start_game', <String, Object?>{});
  await _drainStartCascade(lobby.host.client);
  await _drainStartCascade(lobby.guest.client);
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

  group('bullet 1: the host leaves a LOBBY of three', () {
    test(
        'player_left carries host_seat = the lowest remaining seat; a new '
        'joiner refills the room and the new host\'s start_game is '
        'accepted, the old host\'s is not (it holds no seat)', () async {
      await start();
      final _ThreeSeatLobby lobby =
          await _buildThreeSeatLobby(harness, clients);

      final String leaveId =
          await lobby.host.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> hostReply = await lobby.host.client.next();
      expect(hostReply['t'], 'player_left',
          reason: 'docs/PROTOCOL.md section 18 rule 1/3: leave_room in '
              'LOBBY already frees the seat with a player_left; got '
              '"${hostReply['t']}": ${hostReply['d']}');
      expect(hostReply['re'], leaveId);
      final Map<String, Object?> hostData =
          hostReply['d']! as Map<String, Object?>;
      expect(hostData['seat'], lobby.host.seat);
      expect(hostData['host_seat'], lobby.mid.seat,
          reason: 'section 18 rule 2: every player_left carries host_seat, '
              'the room\'s host after the seat was freed; the host (seat '
              '${lobby.host.seat}) just left a three-seat LOBBY with seats '
              '${lobby.mid.seat} and ${lobby.far.seat} remaining, so '
              'host_seat must be the lowest of those, ${lobby.mid.seat}; '
              'got ${hostData['host_seat']}');

      final Map<String, Object?> midCopy = await lobby.mid.client.next();
      expect(midCopy['t'], 'player_left');
      expect(
          (midCopy['d']! as Map<String, Object?>)['host_seat'], lobby.mid.seat,
          reason: 'section 18 rule 2: the broadcast copy to a remaining '
              'seat must carry the same host_seat as the leaver\'s own '
              'frame');
      final Map<String, Object?> farCopy = await lobby.far.client.next();
      expect(farCopy['t'], 'player_left');
      expect(
          (farCopy['d']! as Map<String, Object?>)['host_seat'], lobby.mid.seat);

      // A new player joins by code and takes the only free canonical seat
      // (the host's old seat 0, since mid and far still hold 1 and 2).
      final WireTestClient newJoiner =
          await WireTestClient.connect(harness.wsUri);
      clients.add(newJoiner);
      newJoiner.send(
          'join_room', <String, Object?>{'code': lobby.code, 'name': 'New'});
      final Map<String, Object?> newJoinerSeatAssigned = await newJoiner.next();
      await newJoiner.next(); // room
      await lobby.mid.client.next(); // player_joined
      await lobby.far.client.next(); // player_joined
      expect((newJoinerSeatAssigned['d']! as Map<String, Object?>)['seat'],
          lobby.host.seat,
          reason: 'the only free canonical seat left in a 3-player room '
              'once ${lobby.mid.seat} and ${lobby.far.seat} are occupied '
              'is the host\'s old seat, ${lobby.host.seat}');

      // The new host (mid) can now start the full room.
      lobby.mid.client.send('start_game', <String, Object?>{});
      final Map<String, Object?> midStartReply = await lobby.mid.client.next();
      expect(midStartReply['t'], isNot('error'),
          reason: 'mid is the host after the hand-on (host_seat = '
              '${lobby.mid.seat}) and every configured seat is filled; '
              'start_game must be accepted, got error: '
              '${midStartReply['d']}');

      // The old host's socket, still open, holds no seat any more: any
      // later seat-scoped message on it is BAD_SEAT_TOKEN, start_game
      // included, whatever the room's own phase now is (section 7: the
      // identity check for these five messages runs before anything else).
      lobby.host.client.send('start_game', <String, Object?>{});
      final Map<String, Object?> oldHostReply = await lobby.host.client.next();
      expectErrorFrame(oldHostReply, 'BAD_SEAT_TOKEN',
          because: 'the old host\'s connection was detached from the room '
              'by its own leave_room; it holds no seat to start anything '
              'with');
    });
  });

  group('bullet 2: a non-host leaves a LOBBY of three', () {
    test('host_seat in the frame is the unchanged host', () async {
      await start();
      final _ThreeSeatLobby lobby =
          await _buildThreeSeatLobby(harness, clients);

      final String leaveId =
          await lobby.mid.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> midReply = await lobby.mid.client.next();
      expect(midReply['t'], 'player_left');
      expect(midReply['re'], leaveId);
      final Map<String, Object?> midData =
          midReply['d']! as Map<String, Object?>;
      expect(midData['seat'], lobby.mid.seat);
      expect(midData['host_seat'], lobby.host.seat,
          reason: 'section 18 rule 2: a non-host leaving must not move '
              'host_seat; the host (seat ${lobby.host.seat}) is still '
              'seated; got ${midData['host_seat']}');

      final Map<String, Object?> hostCopy = await lobby.host.client.next();
      expect((hostCopy['d']! as Map<String, Object?>)['host_seat'],
          lobby.host.seat);
      final Map<String, Object?> farCopy = await lobby.far.client.next();
      expect((farCopy['d']! as Map<String, Object?>)['host_seat'],
          lobby.host.seat);
    });
  });

  group('bullet 3: the last seat leaves a LOBBY', () {
    test('host_seat is -1 on the leaver\'s own frame, re set', () async {
      final Uri uri = await start();
      final WireTestClient soleClient = await WireTestClient.connect(uri);
      clients.add(soleClient);
      soleClient
          .send('create_room', <String, Object?>{'name': 'Solo', 'players': 2});
      await soleClient.next(); // seat_assigned
      await soleClient.next(); // room

      final String leaveId =
          await soleClient.send('leave_room', <String, Object?>{});
      final Map<String, Object?> reply = await soleClient.next();
      expect(reply['t'], 'player_left');
      expect(reply['re'], leaveId,
          reason: 'section 18 rule 3: "host_seat is -1 on the leaver\'s own '
              'frame (re set)"');
      final Map<String, Object?> data = reply['d']! as Map<String, Object?>;
      expect(data['host_seat'], -1,
          reason: 'the last seat just left; no seat remains to be host; got '
              '${data['host_seat']}');
    });
  });

  group(
      'bullet 4: a seat leaves a FINISHED room of three '
      '(split: wire frames, then the registry-level verify record)', () {
    // Wire half: player_left (not presence) to every remaining socket and
    // to the leaver with re; the seat absent from the next room any socket
    // gets; the leaver's later resume and rematch both BAD_SEAT_TOKEN.
    test(
        'player_left to everyone, seat gone from the next room, leaver\'s '
        'resume and rematch both BAD_SEAT_TOKEN', () async {
      await start();
      final _ThreeSeatLobby lobby =
          await _buildThreeSeatLobby(harness, clients);
      await _startAndFinish(lobby, winner: lobby.mid.seat);

      final String leaveId =
          await lobby.far.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> farReply = await lobby.far.client.next();
      expect(farReply['t'], 'player_left',
          reason: 'docs/PROTOCOL.md section 18 rule 3: leave_room in '
              'FINISHED must free the seat exactly as in LOBBY -- a '
              'player_left, not a presence; got "${farReply['t']}": '
              '${farReply['d']}');
      expect(farReply['re'], leaveId);
      final Map<String, Object?> farData =
          farReply['d']! as Map<String, Object?>;
      expect(farData['seat'], lobby.far.seat);
      expect(farData['host_seat'], lobby.host.seat,
          reason: 'the host (seat ${lobby.host.seat}) is unaffected by a '
              'non-host leaving');

      final Map<String, Object?> hostCopy = await lobby.host.client.next();
      expect(hostCopy['t'], 'player_left');
      final Map<String, Object?> midCopy = await lobby.mid.client.next();
      expect(midCopy['t'], 'player_left');

      // The seat is absent from the next room any socket gets: ask with a
      // resume from a remaining seat.
      lobby.host.client.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.host.token,
      });
      await expectSeatAssigned(
        lobby.host.client,
        expectedSeat: lobby.host.seat,
        expectedToken: lobby.host.token,
        because: 'host resumed after far left',
      );
      final Map<String, Object?> roomAfter = await lobby.host.client.next();
      expect(roomAfter['t'], 'room');
      final List<Object?> seatsAfter =
          (roomAfter['d']! as Map<String, Object?>)['seats']! as List<Object?>;
      final bool farStillThere = seatsAfter.any((Object? entry) =>
          (entry! as Map<String, Object?>)['seat'] == lobby.far.seat);
      expect(farStillThere, isFalse,
          reason: 'seat ${lobby.far.seat} must be gone from the room any '
              'socket resumes into after it left; seats: $seatsAfter');

      // The leaver's later resume and rematch are both BAD_SEAT_TOKEN.
      lobby.far.client.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.far.token,
      });
      final Map<String, Object?> farResumeReply = await lobby.far.client.next();
      expectErrorFrame(farResumeReply, 'BAD_SEAT_TOKEN',
          because: 'seat ${lobby.far.seat}\'s token no longer names a seat '
              'in ${lobby.code} after it left a FINISHED room');

      lobby.far.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> farRematchReply =
          await lobby.far.client.next();
      expectErrorFrame(farRematchReply, 'BAD_SEAT_TOKEN',
          because: 'seat ${lobby.far.seat}\'s token no longer names a seat '
              'in ${lobby.code} after it left a FINISHED room');
    });

    // Registry-level half: the verify record of the game that just finished
    // must be byte-identical before and after the leave. No WireServer, no
    // socket, exactly the technique rematch_test.dart's own "the old game's
    // verify record is untouched by the rematch" test uses -- there is no
    // wire message that fetches a stored record, so this is the only way to
    // observe the fact at all. A real natural win needs 60+ rolls
    // (test/turn_loop_test.dart's own header), so this plays a three-seat
    // game to a *real* win the same steered-secret way verify_record_test.dart
    // and rematch_test.dart's own verify-record test do for two seats: seat
    // 0 (on turn first, left exactly as start_game produced it) rolls a
    // non-six and loses the turn with nothing legal to move (every token
    // still in the yard); seat 1 (three tokens already home, one square
    // short) rolls exactly a 1 and wins; seat 2 never acts at all and is the
    // seat that leaves afterward.
    test(
        'the verify record of the finished game is byte-identical before '
        'and after the leave', () {
      final String predictedGameId = hexEncode(
        buildThreeSeatScript(secret: List<int>.filled(serverSecretDraws, 0))
            .sublist(
                threeSeatGameIdOffset, threeSeatGameIdOffset + gameIdDraws),
      );
      const String seedA = 'leave-table-seat0-seed';
      const String seedB = 'leave-table-seat1-seed';
      const String seedC = 'leave-table-seat2-seed';
      final String clientSeeds = '0:$seedA|1:$seedB|2:$seedC';
      final SteeredSecret steered = findSecretForFaces(
        wanted: const <int>[1, 1],
        gameId: predictedGameId,
        clientSeeds: clientSeeds,
      );

      final FakeClock clock = FakeClock(DateTime.utc(2026, 5, 1));
      final MemoryVerifyStore store = MemoryVerifyStore(clock);
      final RoomRegistry registry = RoomRegistry(
        clock: clock,
        secure:
            ScriptedBytesRandom(buildThreeSeatScript(secret: steered.secret)),
        verifyStore: store,
      );

      final CreateResult createResult = registry.createRoom(
        name: 'Seat0',
        players: 3,
        rules: const RulesConfig(turnSeconds: 15),
      );
      final CreateOk host = createResult as CreateOk;
      final JoinResult join1 =
          registry.joinRoom(code: host.room.code, name: 'Seat1');
      final JoinOk mid = join1 as JoinOk;
      final JoinResult join2 =
          registry.joinRoom(code: host.room.code, name: 'Seat2');
      final JoinOk far = join2 as JoinOk;

      registry.setSeed(
          code: host.room.code,
          seatToken: host.seat.seatToken,
          clientSeed: seedA);
      registry.setSeed(
          code: host.room.code,
          seatToken: mid.seat.seatToken,
          clientSeed: seedB);
      registry.setSeed(
          code: host.room.code,
          seatToken: far.seat.seatToken,
          clientSeed: seedC);

      final StartResult startResult = registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken);
      final StartOk started = startResult as StartOk;
      expect(started.room.gameId, predictedGameId,
          reason: 'predicted game_id did not match; test/support/'
              'scripted_bytes.dart\'s three-seat offsets are stale for this '
              'draw sequence');
      expect(started.room.game!.currentSeat, 0,
          reason: 'setup: seat 0 (the host) must be first on turn in a '
              'fresh three-seat game');

      final Map<String, Object?> gameJson = started.room.game!.toJson();
      final List<Object?> tokens = gameJson['tokens']! as List<Object?>;
      tokens[1] = const <int>[57, 57, 57, 56];
      started.room.game = engine.GameState.fromJson(gameJson);

      clock.advance(const Duration(seconds: 16));
      final List<ExpiredTurn> expired = registry.expireTurns();
      expect(expired, hasLength(1),
          reason: 'setup: seat 0\'s untouched first turn must roll and pass '
              'via the timer');

      final RollResult secondRoll =
          registry.roll(code: host.room.code, seatToken: mid.seat.seatToken);
      expect(secondRoll, isA<RollOk>(), reason: 'setup: $secondRoll');
      final MoveResult win = registry.move(
          code: host.room.code, seatToken: mid.seat.seatToken, token: 3);
      expect(win, isA<MoveOk>(),
          reason: 'setup: the forced winning move was rejected: $win');

      final String gameId = started.room.gameId!;
      final String? before = store.load(gameId);
      expect(before, isNotNull,
          reason: 'setup: a winning move must save a verify record for '
              '$gameId');

      final LeaveResult leave = registry.leaveRoom(
          code: host.room.code, seatToken: far.seat.seatToken);
      expect(leave, isA<LeaveOk>(),
          reason: 'leave_room from a seated player in a FINISHED room must '
              'be accepted; got $leave');

      final String? after = store.load(gameId);
      expect(after, isNotNull,
          reason: 'the leave must not delete the finished game\'s verify '
              'record');
      expect(after, before,
          reason: 'section 18 rule 3: "the game\'s record at /v/<game_id> '
              'is not touched"; the leave must not alter the stored '
              'record\'s bytes at all');
    });
  });

  group('bullet 5: the host leaves a FINISHED room', () {
    test('host_seat in the frame is the lowest remaining seat', () async {
      await start();
      final _ThreeSeatLobby lobby =
          await _buildThreeSeatLobby(harness, clients);
      await _startAndFinish(lobby, winner: lobby.far.seat);

      final String leaveId =
          await lobby.host.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> hostReply = await lobby.host.client.next();
      expect(hostReply['t'], 'player_left',
          reason: 'section 18 rule 3: leave_room in FINISHED frees the '
              'seat exactly as in LOBBY; got "${hostReply['t']}": '
              '${hostReply['d']}');
      expect(hostReply['re'], leaveId);
      final Map<String, Object?> hostData =
          hostReply['d']! as Map<String, Object?>;
      expect(hostData['host_seat'], lobby.mid.seat,
          reason: 'section 18 rule 1/2: the host (seat ${lobby.host.seat}) '
              'just left; the lowest remaining seat is ${lobby.mid.seat}; '
              'got ${hostData['host_seat']}');

      final Map<String, Object?> midCopy = await lobby.mid.client.next();
      expect(midCopy['t'], 'player_left');
      expect(
          (midCopy['d']! as Map<String, Object?>)['host_seat'], lobby.mid.seat);
      final Map<String, Object?> farCopy = await lobby.far.client.next();
      expect(farCopy['t'], 'player_left');
      expect(
          (farCopy['d']! as Map<String, Object?>)['host_seat'], lobby.mid.seat);
    });
  });

  group('bullet 6: a FINISHED room of two, one leaves', () {
    test(
        'the other\'s rematch opens a rematch LOBBY; a new joiner by code '
        'takes the freed seat; the joiner\'s rematch starts the game for '
        'both', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await _finishedTwoSeatLobby(harness, clients);

      final String leaveId =
          await lobby.guest.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> guestReply = await lobby.guest.client.next();
      expect(guestReply['t'], 'player_left',
          reason: 'section 18 rule 3: leave_room in FINISHED frees the '
              'seat exactly as in LOBBY; got "${guestReply['t']}": '
              '${guestReply['d']}');
      expect(guestReply['re'], leaveId);
      await lobby.host.client.next(); // broadcast copy

      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> hostRematchReply =
          await lobby.host.client.next();
      expect(hostRematchReply['t'], 'room');
      final Map<String, Object?> hostRematchData =
          hostRematchReply['d']! as Map<String, Object?>;
      expect(hostRematchData['state'], 'LOBBY');
      final Map<String, Object?> rematchField =
          hostRematchData['rematch']! as Map<String, Object?>;
      expect(rematchField['by'], lobby.host.seat);
      expect(rematchField['ready'], <int>[lobby.host.seat],
          reason: 'section 18 rule 4: the first rematch from the remaining '
              'seat opens the rematch LOBBY with only itself ready');

      final WireTestClient newJoiner = await WireTestClient.connect(uri);
      clients.add(newJoiner);
      newJoiner.send(
          'join_room', <String, Object?>{'code': lobby.code, 'name': 'New'});
      final Map<String, Object?> newJoinerReply = await newJoiner.next();
      expect(newJoinerReply['t'], isNot('error'),
          reason: 'section 18 rule 4 / 16.9 rule 4: the freed seat '
              '(${lobby.guest.seat}) must be free for a new joiner by code '
              'to take; got error: ${newJoinerReply['d']}');
      final Map<String, Object?> newJoinerSeatAssigned = newJoinerReply;
      final int newJoinerSeat =
          (newJoinerSeatAssigned['d']! as Map<String, Object?>)['seat']! as int;
      expect(newJoinerSeat, lobby.guest.seat,
          reason: 'the only free canonical seat in a two-player room once '
              'the host holds ${lobby.host.seat} is the seat the guest '
              'just freed, ${lobby.guest.seat}');
      await newJoiner.next(); // room
      await lobby.host.client.next(); // player_joined

      newJoiner.send('rematch', <String, Object?>{});
      final Map<String, Object?> joinerAcceptReply = await newJoiner.next();
      expect(joinerAcceptReply['t'], 'room');

      // Section 16.4: the host first gets the broadcast copy of the
      // accept, both seats ready, before anything the start sends.
      final Map<String, Object?> hostBroadcastOfAccept =
          await lobby.host.client.next();
      expect(hostBroadcastOfAccept['t'], 'room');
      expect(
          ((hostBroadcastOfAccept['d']! as Map<String, Object?>)['rematch']!
              as Map<String, Object?>)['ready'],
          <int>[lobby.host.seat, newJoinerSeat]..sort());

      // Section 16.4: both occupied seats are now ready and connected, so
      // the server starts the game itself, reaching both sockets.
      Map<String, Object?> hostFrame = await lobby.host.client.next();
      while (hostFrame['t'] == 'seat_seed') {
        hostFrame = await lobby.host.client.next();
      }
      expect(hostFrame['t'], 'game_started',
          reason: 'section 18 rule 4 / 16.4: once the joiner accepts, '
              'every occupied seat is ready and connected and the server '
              'must auto-start; got "${hostFrame['t']}": ${hostFrame['d']}');

      Map<String, Object?> joinerFrame = await newJoiner.next();
      while (joinerFrame['t'] == 'seat_seed') {
        joinerFrame = await newJoiner.next();
      }
      expect(joinerFrame['t'], 'game_started',
          reason: 'game_started must reach the joiner\'s own socket too; '
              'got "${joinerFrame['t']}": ${joinerFrame['d']}');
    });
  });

  group(
      'bullet 7: host-forced start removes a non-ready seat '
      '(section 16.4 "Not everyone")', () {
    test('each player_left it sends carries host_seat == the host\'s seat',
        () async {
      await start();
      final _ThreeSeatLobby lobby =
          await _buildThreeSeatLobby(harness, clients);
      await _startAndFinish(lobby, winner: lobby.mid.seat);

      lobby.host.client.send('rematch', <String, Object?>{});
      await lobby.host.client.next();
      await lobby.mid.client.next();
      await lobby.far.client.next();
      lobby.mid.client.send('rematch', <String, Object?>{});
      await lobby.mid.client.next();
      await lobby.host.client.next();
      await lobby.far.client.next();

      // far never accepts; host force-starts with two of the three ready.
      lobby.host.client.send('start_game', <String, Object?>{});
      final Map<String, Object?> farLeftOnHost = await lobby.host.client.next();
      expect(farLeftOnHost['t'], 'player_left');
      final Map<String, Object?> farLeftData =
          farLeftOnHost['d']! as Map<String, Object?>;
      expect(farLeftData['seat'], lobby.far.seat);
      expect(farLeftData['host_seat'], lobby.host.seat,
          reason: 'section 18 rule 7: a host-forced removal\'s player_left '
              'must carry host_seat equal to the host\'s own seat '
              '(${lobby.host.seat}) -- the host is never removed by its '
              'own start_game (16.9 rule 2); got ${farLeftData['host_seat']}');

      final Map<String, Object?> farLeftOnMid = await lobby.mid.client.next();
      expect(farLeftOnMid['t'], 'player_left');
      expect((farLeftOnMid['d']! as Map<String, Object?>)['host_seat'],
          lobby.host.seat);
      final Map<String, Object?> farLeftOnFar = await lobby.far.client.next();
      expect(farLeftOnFar['t'], 'player_left',
          reason: 'the removed seat is told what everyone else was told, '
              'the same way leave_room\'s own row in section 4 applies '
              'here');
      expect((farLeftOnFar['d']! as Map<String, Object?>)['host_seat'],
          lobby.host.seat);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('bullet 8: a socket drops (closed without leave_room) in FINISHED', () {
    test(
        'the others get presence connected:false, the seat stays, and its '
        'resume succeeds', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await _finishedTwoSeatLobby(harness, clients);

      await lobby.guest.client.close();
      final Map<String, Object?> presence = await lobby.host.client.next();
      expect(presence['t'], 'presence',
          reason: 'section 18 rule 3\'s last sentence: "a seat that drops '
              'its socket without leave_room is unchanged: presence"; got '
              '"${presence['t']}": ${presence['d']}');
      final Map<String, Object?> presenceData =
          presence['d']! as Map<String, Object?>;
      expect(presenceData['seat'], lobby.guest.seat);
      expect(presenceData['connected'], isFalse);

      final WireTestClient freshGuest = await WireTestClient.connect(uri);
      clients.add(freshGuest);
      freshGuest.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      await expectSeatAssigned(
        freshGuest,
        expectedSeat: lobby.guest.seat,
        expectedToken: lobby.guest.token,
        because: 'the dropped seat resumes with its still-valid seat_token',
      );
      final Map<String, Object?> resumedRoom = await freshGuest.next();
      expect(resumedRoom['t'], 'room');
      final Map<String, Object?> resumedData =
          resumedRoom['d']! as Map<String, Object?>;
      expect(resumedData['state'], 'FINISHED');
      final List<Object?> seats = resumedData['seats']! as List<Object?>;
      final bool guestStillThere = seats.any((Object? entry) =>
          (entry! as Map<String, Object?>)['seat'] == lobby.guest.seat);
      expect(guestStillThere, isTrue,
          reason: 'section 18 rule 3: only leave_room frees a seat; a '
              'socket drop must leave it in the room, able to resume');
    });
  });
}

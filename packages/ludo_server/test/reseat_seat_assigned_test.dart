// Order 204 -- proof, over the real wire, of `docs/PROTOCOL.md` section 15:
// a `set_players` re-seat tells every connected seat whose number changed,
// via `seat_assigned`, before the `room` that carries the new seating; a
// seat that is not connected learns nothing then and gets it on its next
// `resume` instead, which itself always answers `seat_assigned` then `room`,
// moved seat or not.
//
// Order 203 (another worker, run in parallel, whose code is not visible from
// here) is the one that makes `_handleSetPlayers` and `_handleResume`
// (`lib/src/connection.dart`) actually send `seat_assigned`. On this file's
// own base -- `78724c9`, no 203 -- neither handler sends it at all:
// `_handleSetPlayers` sends only `room` to the caller and broadcasts only
// `room` to everyone else (`connection.dart:569-575`), and `_handleResume`
// sends only `room` (`connection.dart:402-406`). Every test below that reads
// a `seat_assigned` before a `room` is therefore expected to be **red** on
// this base, and the run at the bottom of this file's own commit message
// records exactly which ones and their failure lines. S2 is the one
// scenario that asserts an absence rather than a presence, so it is green on
// both sides of 203's change.
//
// docs/RULES.md section 2/2a and `lib/src/registry.dart:1186-1197`'s
// `_seatIndicesFor` give the canonical seat set `set_players` re-seats onto:
// `[0, 2]` for two players, `[0, 1, 2]` for three, `[0, 1, 2, 3]` for four,
// filled in ascending order of the occupants' *old* seat numbers
// (`registry.dart:788-800`). Every scenario below that predicts which seat
// moves where is predicting that mapping, not guessing it.
import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/engine_search.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// One seat over the wire: the socket that took it, its seat index *at the
/// moment this record was built* (a caller re-seating the room reads the
/// new index off the resulting `seat_assigned`/`room` frames directly rather
/// than trusting this field afterwards), and the seat token that survives a
/// re-seat unchanged (section 15 rule 3).
class _RoomSeat {
  _RoomSeat({required this.client, required this.seat, required this.token});

  final WireTestClient client;
  final int seat;
  final String token;
}

/// A room created with `players: 4` (so every scenario below has room to
/// re-seat within, per section 3: "down to no fewer than the seats
/// currently occupied") with exactly [occupied] of its four seats filled,
/// host first. Every handshake frame each join produces (`seat_assigned`,
/// both `room` frames, and the `player_joined` push every already-connected
/// socket receives) is drained here, so a caller is left with every socket
/// ready for the one message it actually wants to observe.
class _FourSeatRoom {
  _FourSeatRoom({required this.code, required this.seats, required this.seq});

  final String code;

  /// In join order: `seats[0]` is the host.
  final List<_RoomSeat> seats;

  /// The room's own `seq` as of the last handshake frame this builder
  /// itself read -- the host's own `room` frame at creation if [occupied]
  /// was 1, else the last joiner's own `room` reply, which already reflects
  /// that join's own bump (the same value the `player_joined` broadcast to
  /// every earlier seat carried). A caller that samples `seq` again after
  /// its own next action can subtract this to get exactly that action's own
  /// bump, without a second probe connection or a resume this room's own
  /// seats do not otherwise need.
  final int seq;
}

Future<_FourSeatRoom> _buildFourSeatRoom(
  Uri uri,
  List<WireTestClient> clients, {
  required int occupied,
}) async {
  assert(occupied >= 1 && occupied <= 4);
  final List<_RoomSeat> seats = <_RoomSeat>[];

  final WireTestClient hostClient = await WireTestClient.connect(uri);
  clients.add(hostClient);
  hostClient.send('create_room', <String, Object?>{
    'name': 'Seat0',
    'players': 4,
  });
  final Map<String, Object?> hostSeatAssigned = await hostClient.next();
  final Map<String, Object?> hostRoomFrame = await hostClient.next();
  final Map<String, Object?> hostSeatData =
      hostSeatAssigned['d']! as Map<String, Object?>;
  final Map<String, Object?> hostRoomData =
      hostRoomFrame['d']! as Map<String, Object?>;
  final String code = hostRoomData['code']! as String;
  seats.add(_RoomSeat(
    client: hostClient,
    seat: hostSeatData['seat']! as int,
    token: hostSeatData['seat_token']! as String,
  ));
  int seq = hostRoomData['seq']! as int;

  for (int i = 1; i < occupied; i++) {
    final WireTestClient guestClient = await WireTestClient.connect(uri);
    clients.add(guestClient);
    guestClient.send('join_room', <String, Object?>{
      'code': code,
      'name': 'Seat$i',
    });
    final Map<String, Object?> guestSeatAssigned = await guestClient.next();
    final Map<String, Object?> guestRoomFrame = await guestClient.next();
    final Map<String, Object?> guestSeatData =
        guestSeatAssigned['d']! as Map<String, Object?>;
    final Map<String, Object?> guestRoomData =
        guestRoomFrame['d']! as Map<String, Object?>;
    seq = guestRoomData['seq']! as int;
    for (final _RoomSeat existing in seats) {
      await existing.client.next(); // player_joined for the new seat
    }
    seats.add(_RoomSeat(
      client: guestClient,
      seat: guestSeatData['seat']! as int,
      token: guestSeatData['seat_token']! as String,
    ));
  }

  return _FourSeatRoom(code: code, seats: seats, seq: seq);
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

  test(
      'S1: set_players moves the guest, which sees seat_assigned then room; '
      'the host, unmoved, sees only room', () async {
    final Uri uri = await start();
    final _FourSeatRoom room =
        await _buildFourSeatRoom(uri, clients, occupied: 2);
    final _RoomSeat host = room.seats[0];
    final _RoomSeat guest = room.seats[1];
    expect(host.seat, 0,
        reason: 'fixture sanity check: the creator of a 4p '
            'room takes seat 0');
    expect(guest.seat, 1,
        reason: 'fixture sanity check: the second joiner '
            'of a 4p room takes seat 1');

    final String setPlayersId =
        host.client.send('set_players', <String, Object?>{'players': 2});

    // The guest moved: newIndices([0,2]) put the seat that was at index 1
    // (join order 1 of 2) at index 2. Its next frames must be
    // seat_assigned{seat:2, seat_token:<unchanged>}, then room.
    await expectSeatAssigned(
      guest.client,
      expectedSeat: 2,
      expectedToken: guest.token,
      because: 'S1: set_players(2) on a 4p room with seats 0,1 filled must '
          'move seat 1 to seat 2, and tell it so before the room broadcast',
    );
    final Map<String, Object?> guestRoomFrame = await guest.client.next();
    expect(
      guestRoomFrame['t'],
      'room',
      reason: 'S1: the guest\'s seat_assigned must be immediately followed '
          'by the room broadcast carrying the new seating; got '
          '"${guestRoomFrame['t']}": ${guestRoomFrame['d']}',
    );
    final Map<String, Object?> guestRoomData =
        guestRoomFrame['d']! as Map<String, Object?>;
    final List<Object?> guestSeats = guestRoomData['seats']! as List<Object?>;
    expect(
      guestSeats.any(
          (Object? entry) => (entry! as Map<String, Object?>)['seat'] == 2),
      isTrue,
      reason: 'S1: room.seats must carry an entry at seat 2, the guest\'s '
          'new seat; got $guestSeats',
    );
    expect(
      guestSeats.any(
          (Object? entry) => (entry! as Map<String, Object?>)['seat'] == 1),
      isFalse,
      reason: 'S1: room.seats must not carry a stale entry at the guest\'s '
          'old seat 1; got $guestSeats',
    );

    // The host did not move: its next frame is the room reply directly, no
    // seat_assigned before it.
    final Map<String, Object?> hostReply = await host.client.next();
    expect(
      hostReply['t'],
      'room',
      reason: 'S1: the host\'s own seat did not change, so its next frame '
          'after its own set_players must be the room reply directly, with '
          'no seat_assigned ahead of it; got "${hostReply['t']}": '
          '${hostReply['d']}',
    );
    expect(
      hostReply['re'],
      setPlayersId,
      reason: 'S1: the room reply must answer the host\'s own set_players '
          'id; got re=${hostReply['re']}, expected $setPlayersId',
    );
  });

  test(
      'S2: nothing moves when set_players(3) is sent to a room already '
      'holding seats 0,1,2 -- every socket\'s next frame is room, no '
      'seat_assigned anywhere', () async {
    final Uri uri = await start();
    final _FourSeatRoom room =
        await _buildFourSeatRoom(uri, clients, occupied: 3);
    final _RoomSeat host = room.seats[0];
    final _RoomSeat guestA = room.seats[1];
    final _RoomSeat guestB = room.seats[2];
    expect(<int>[host.seat, guestA.seat, guestB.seat], <int>[0, 1, 2],
        reason: 'fixture sanity check: three joiners of a 4p room take '
            'seats 0, 1, 2 in order');

    final String setPlayersId =
        host.client.send('set_players', <String, Object?>{'players': 3});

    final Map<String, Object?> hostReply = await host.client.next();
    expect(
      hostReply['t'],
      'room',
      reason: 'S2: no seat moved (newIndices([0,1,2]) map straight back '
          'onto themselves), so the host\'s next frame must be the room '
          'reply directly; got "${hostReply['t']}": ${hostReply['d']}',
    );
    expect(hostReply['re'], setPlayersId);

    final Map<String, Object?> guestAFrame = await guestA.client.next();
    expect(
      guestAFrame['t'],
      'room',
      reason: 'S2: seat 1 did not move; its next frame must be room, not '
          'seat_assigned; got "${guestAFrame['t']}": ${guestAFrame['d']}',
    );

    final Map<String, Object?> guestBFrame = await guestB.client.next();
    expect(
      guestBFrame['t'],
      'room',
      reason: 'S2: seat 2 did not move; its next frame must be room, not '
          'seat_assigned; got "${guestBFrame['t']}": ${guestBFrame['d']}',
    );
  });

  test(
      'S3: the host seat passes to seat 1 on leave_room, then that new '
      'host\'s own set_players moves itself but not the surviving guest',
      () async {
    final Uri uri = await start();
    final _FourSeatRoom room =
        await _buildFourSeatRoom(uri, clients, occupied: 3);
    final _RoomSeat oldHost = room.seats[0];
    final _RoomSeat newHost = room.seats[1];
    final _RoomSeat stayingGuest = room.seats[2];
    expect(
        <int>[oldHost.seat, newHost.seat, stayingGuest.seat], <int>[0, 1, 2]);

    // Seat 0 leaves voluntarily, in LOBBY: registry.dart's leaveRoom removes
    // it from room.seats and sets room.hostSeat to the lowest surviving seat
    // index (registry.dart:823-827, `room.seats.map((s) => s.seat).reduce
    // (min)`), which for the surviving {1, 2} is seat 1. Seat numbers of the
    // survivors do not change here -- only room.hostSeat does -- so nothing
    // in this step sends a seat_assigned to anyone; that is not this file's
    // claim to test, only the setup this scenario needs.
    final String leaveId =
        oldHost.client.send('leave_room', <String, Object?>{});
    final Map<String, Object?> oldHostReply = await oldHost.client.next();
    expect(oldHostReply['t'], 'player_left');
    expect(oldHostReply['re'], leaveId);

    final Map<String, Object?> newHostLeftBroadcast =
        await newHost.client.next();
    expect(newHostLeftBroadcast['t'], 'player_left');
    final Map<String, Object?> stayingGuestLeftBroadcast =
        await stayingGuest.client.next();
    expect(stayingGuestLeftBroadcast['t'], 'player_left');

    // The new host (seat 1) sets 2 players: ordered by ascending old seat
    // index, {1, 2} become newIndices([0, 2]) = {0, 2}: seat 1 -> 0, seat 2
    // unchanged.
    final String setPlayersId =
        newHost.client.send('set_players', <String, Object?>{'players': 2});

    await expectSeatAssigned(
      newHost.client,
      expectedSeat: 0,
      expectedToken: newHost.token,
      because: 'S3: the new host (formerly seat 1) moves to seat 0 when it '
          'sets 2 players on the surviving {1, 2}',
    );
    final Map<String, Object?> newHostRoomFrame = await newHost.client.next();
    expect(
      newHostRoomFrame['t'],
      'room',
      reason: 'S3: the new host\'s seat_assigned must be immediately '
          'followed by its own room reply; got '
          '"${newHostRoomFrame['t']}": ${newHostRoomFrame['d']}',
    );
    expect(newHostRoomFrame['re'], setPlayersId);
    final Map<String, Object?> newHostRoomData =
        newHostRoomFrame['d']! as Map<String, Object?>;
    expect(
      newHostRoomData['host_seat'],
      0,
      reason: 'S3: the seat that called set_players is host_seat 0 after '
          'the reseat, both because it is still the host and because it '
          'landed at index 0',
    );

    final Map<String, Object?> stayingGuestFrame =
        await stayingGuest.client.next();
    expect(
      stayingGuestFrame['t'],
      'room',
      reason: 'S3: seat 2 did not move (newIndices([0,2])\'s second slot is '
          'still 2), so it must see room directly, not seat_assigned; got '
          '"${stayingGuestFrame['t']}": ${stayingGuestFrame['d']}',
    );
  });

  test(
      'S4: a moved seat that is disconnected gets nothing at the moment of '
      'the reseat and learns its new seat from its next resume', () async {
    final Uri uri = await start();
    final _FourSeatRoom room =
        await _buildFourSeatRoom(uri, clients, occupied: 2);
    final _RoomSeat host = room.seats[0];
    final _RoomSeat guest = room.seats[1];

    await guest.client.close();
    final Map<String, Object?> hostPresence = await host.client.next();
    expect(
      hostPresence['t'],
      'presence',
      reason: 'setup: closing the guest\'s socket must be observed by the '
          'host as a presence(connected: false) push before set_players is '
          'sent, or that push is mistaken later for set_players\' own '
          'reply; got "${hostPresence['t']}": ${hostPresence['d']}',
    );
    final Map<String, Object?> hostPresenceData =
        hostPresence['d']! as Map<String, Object?>;
    expect(hostPresenceData['seat'], guest.seat);
    expect(hostPresenceData['connected'], isFalse);

    final String setPlayersId =
        host.client.send('set_players', <String, Object?>{'players': 2});
    final Map<String, Object?> hostReply = await host.client.next();
    expect(
      hostReply['t'],
      'room',
      reason: 'S4: the host did not move, so its own reply is room '
          'directly; got "${hostReply['t']}": ${hostReply['d']}',
    );
    expect(hostReply['re'], setPlayersId);
    // Nothing else is asserted about the dead socket: it has no queue left
    // to read from, and section 15 rule 1's own text is "a seat that is not
    // connected receives nothing then".

    final WireTestClient freshGuest = await WireTestClient.connect(uri);
    clients.add(freshGuest);
    final String resumeId = freshGuest.send('resume', <String, Object?>{
      'code': room.code,
      'seat_token': guest.token,
    });

    await expectSeatAssigned(
      freshGuest,
      expectedSeat: 2,
      expectedToken: guest.token,
      because: 'S4: the guest moved to seat 2 while disconnected and must '
          'learn that from the seat_assigned its resume answers with',
    );
    final Map<String, Object?> resumedRoom = await freshGuest.next();
    expect(
      resumedRoom['t'],
      'room',
      reason: 'S4: the resume\'s seat_assigned must be immediately followed '
          'by the room snapshot; got "${resumedRoom['t']}": '
          '${resumedRoom['d']}',
    );
    expect(
      resumedRoom['re'],
      resumeId,
      reason: 'S4: the room frame that answers a resume must carry that '
          'resume\'s own id; got re=${resumedRoom['re']}, expected '
          '$resumeId',
    );
  });

  test(
      'S5: resume with nothing moved still answers seat_assigned (the '
      'unchanged seat) then room', () async {
    final Uri uri = await start();
    final _FourSeatRoom room =
        await _buildFourSeatRoom(uri, clients, occupied: 2);
    final _RoomSeat host = room.seats[0];
    final _RoomSeat guest = room.seats[1];

    await guest.client.close();
    await host.client.next(); // presence(connected: false)

    final WireTestClient freshGuest = await WireTestClient.connect(uri);
    clients.add(freshGuest);
    final String resumeId = freshGuest.send('resume', <String, Object?>{
      'code': room.code,
      'seat_token': guest.token,
    });

    await expectSeatAssigned(
      freshGuest,
      expectedSeat: guest.seat,
      expectedToken: guest.token,
      because: 'S5: resume must answer seat_assigned even when the seat '
          'never moved',
    );
    final Map<String, Object?> resumedRoom = await freshGuest.next();
    expect(
      resumedRoom['t'],
      'room',
      reason: 'S5: seat_assigned must be immediately followed by room; got '
          '"${resumedRoom['t']}": ${resumedRoom['d']}',
    );
    expect(resumedRoom['re'], resumeId);
  });

  test(
      'S6: the real proof -- after S1\'s re-seat, the moved seat\'s '
      'original socket can still act on its new seat number once the game '
      'starts', () async {
    // The host's very first roll of a fresh game must leave no legal move,
    // so the turn passes to seat 2 (the guest\'s new seat) on that one roll
    // alone, with no move needed from either seat. Found rather than
    // assumed: docs/RULES.md says only a 6 leaves a legal move on a yard-
    // only board, but this asks the real engine, at maxDepth 1, rather than
    // trusting that reading of the rule text.
    final List<int>? wanted = findFaceSequence(
      seats: const <int>[0, 2],
      maxDepth: 1,
      accepts: (EngineRollStep step, engine.GameState stateAfterRoll) =>
          step.legal.isEmpty,
    );
    expect(
      wanted,
      isNotNull,
      reason: 'test/support/engine_search.dart found no single face, within '
          'its own bound, that leaves a fresh two-seat game with no legal '
          'move for the seat that rolled it',
    );

    // The draw sequence this scenario's setup performs is exactly the one
    // scripted_bytes.dart's own offsets assume: one createRoom (4p, though
    // the player count does not change how many bytes createRoom itself
    // draws), one joinRoom, set_players (draws nothing --
    // registry.dart:761-809 never touches _secure), two set_seed calls
    // (draws nothing), then start_game with both seats already seeded, so
    // only game_id is drawn, at the same gameIdOffset buildScript assumes.
    final List<int> gameIdProbe =
        buildScript(secret: List<int>.filled(serverSecretDraws, 0));
    final String gameId = hexEncode(
        gameIdProbe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
    const String hostSeed = 's6-host-seed';
    const String guestSeed = 's6-guest-seed';
    // Ascending seat index *after* the reseat this scenario drives: host
    // stays 0, guest moves 1 -> 2 (section 15, same mapping S1 proves).
    const String clientSeeds = '0:$hostSeed|2:$guestSeed';

    final SteeredSecret steered = findSecretForFaces(
      wanted: wanted!,
      gameId: gameId,
      clientSeeds: clientSeeds,
    );
    harness = ServerHarness.build(
      secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
    );
    final Uri uri = await start();

    final _FourSeatRoom room =
        await _buildFourSeatRoom(uri, clients, occupied: 2);
    final _RoomSeat host = room.seats[0];
    final _RoomSeat guest = room.seats[1];
    expect(<int>[host.seat, guest.seat], <int>[0, 1]);

    host.client.send('set_players', <String, Object?>{'players': 2});
    await expectSeatAssigned(
      guest.client,
      expectedSeat: 2,
      expectedToken: guest.token,
      because: 'S6 setup: the same reseat S1 proves, replayed here so the '
          'moved seat\'s original socket is the one under test below',
    );
    await guest.client.next(); // room broadcast carrying the new seating
    await host.client.next(); // room reply to the host\'s own set_players

    host.client.send('set_seed', <String, Object?>{'client_seed': hostSeed});
    final Map<String, Object?> hostSeedReply = await host.client.next();
    expect(hostSeedReply['t'], 'seat_seed');
    guest.client.send('set_seed', <String, Object?>{'client_seed': guestSeed});
    final Map<String, Object?> guestSeedReply = await guest.client.next();
    expect(guestSeedReply['t'], 'seat_seed');
    await host.client.next(); // broadcast copy of the guest's own seat_seed

    host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted = await host.client.next();
    expect(hostStarted['t'], 'game_started');
    final Map<String, Object?> startedData =
        hostStarted['d']! as Map<String, Object?>;
    expect(
      startedData['game_id'],
      gameId,
      reason: 'predicted game_id did not match game_started.game_id off '
          'the wire; scripted_bytes.dart\'s draw-order picture no longer '
          'matches registry.dart',
    );
    expect(startedData['turn'], 0,
        reason: 'seats=[0,2]: config.seats.first is 0, so the opening turn '
            'is the host\'s');
    await expectOpeningTurn(host.client, startedData['turn']);

    await guest.client.next(); // guest's own copy of game_started
    await expectOpeningTurn(guest.client, startedData['turn']);

    final String rollId = host.client.send('roll', <String, Object?>{});
    final Map<String, Object?> hostRolled = await host.client.next();
    expect(hostRolled['t'], 'rolled');
    expect(hostRolled['re'], rollId);
    final Map<String, Object?> hostRolledData =
        hostRolled['d']! as Map<String, Object?>;
    expect(
      hostRolledData['legal'],
      isEmpty,
      reason: 'setup requires the steered first roll to leave no legal '
          'move so the turn passes to seat 2 on this one roll alone; got '
          'legal=${hostRolledData['legal']}',
    );
    await guest.client.next(); // broadcast copy of rolled

    final Map<String, Object?> hostTurnPassed = await host.client.next();
    expect(hostTurnPassed['t'], 'turn_passed');
    await guest.client.next(); // broadcast copy of turn_passed

    final Map<String, Object?> hostNextTurn = await host.client.next();
    expect(hostNextTurn['t'], 'turn');
    final Map<String, Object?> hostNextTurnData =
        hostNextTurn['d']! as Map<String, Object?>;
    expect(
      hostNextTurnData['seat'],
      2,
      reason: 'the turn must now belong to seat 2, the guest\'s new seat, '
          'before this test drives its own roll from that seat; got '
          'turn.seat=${hostNextTurnData['seat']}',
    );
    final Map<String, Object?> guestNextTurn = await guest.client.next();
    expect(guestNextTurn['t'], 'turn');

    // THE FINDING this scenario exists to measure: the guest's ORIGINAL
    // socket, which took its seat as seat 1 and was told by seat_assigned
    // (section 15 rule 5) that it is now seat 2, rolls -- and the server,
    // whose own bookkeeping keys this connection by seat token rather than
    // by a seat number the connection cached, must accept it as seat 2's
    // own roll, not refuse it as NOT_YOUR_TURN.
    guest.client.send('roll', <String, Object?>{});
    final Map<String, Object?> guestRoll = await guest.client.next();
    expect(
      guestRoll['t'],
      'rolled',
      reason: 'THE FINDING: seat ${guest.seat} (originally seat 1, moved to '
          'seat 2 by set_players) sent roll on its original socket while '
          'the room said seat 2 was on turn, and got back '
          '"${guestRoll['t']}": ${guestRoll['d']} instead of "rolled"',
    );
    final Map<String, Object?> guestRollData =
        guestRoll['d']! as Map<String, Object?>;
    expect(guestRollData['seat'], 2);
  });

  test(
      'S7: seat_assigned never carries seq, and a re-seat bumps room.seq '
      'by exactly one', () async {
    final Uri uri = await start();
    final _FourSeatRoom room =
        await _buildFourSeatRoom(uri, clients, occupied: 2);
    final _RoomSeat host = room.seats[0];
    final _RoomSeat guest = room.seats[1];
    // room.seq is the guest's own join_room reply's seq (the builder's own
    // last-read room frame), sampled before anything below mutates the room
    // again.
    final int seqBefore = room.seq;

    host.client.send('set_players', <String, Object?>{'players': 2});
    final Map<String, Object?> guestSeatAssigned = await expectSeatAssigned(
      guest.client,
      expectedSeat: 2,
      expectedToken: guest.token,
      because: 'S7: the same reseat S1 proves',
    );
    expect(
      (guestSeatAssigned['d']! as Map<String, Object?>).containsKey('seq'),
      isFalse,
      reason: 'section 5: seat_assigned must never carry seq, moved seat '
          'or not',
    );
    final Map<String, Object?> guestRoomFrame = await guest.client.next();
    final int guestSeqAfter =
        (guestRoomFrame['d']! as Map<String, Object?>)['seq']! as int;
    final Map<String, Object?> hostRoomReply = await host.client.next();
    final int hostSeqAfter =
        (hostRoomReply['d']! as Map<String, Object?>)['seq']! as int;

    expect(
      hostSeqAfter,
      guestSeqAfter,
      reason: 'one seq counter per room: the host\'s own reply and the '
          'guest\'s broadcast copy of the same set_players must carry the '
          'identical seq; got host=$hostSeqAfter guest=$guestSeqAfter',
    );
    expect(
      hostSeqAfter,
      seqBefore + 1,
      reason: 'registry.dart\'s setPlayers bumps room.seq exactly once '
          '(registry.dart:806, `room.seq++`); expected seq to move from '
          '$seqBefore to ${seqBefore + 1}, got $hostSeqAfter',
    );
  });
}

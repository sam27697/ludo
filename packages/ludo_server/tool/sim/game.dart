// The driver shared by every scenario: room creation, joining by code, the
// LOBBY -> PLAYING handshake (set_seed, start_game), the turn loop that
// plays a whole game to a winner by always picking a legal move the server
// itself offered, and the drop/reconnect mechanics `reconnect.dart` and
// `double_drop.dart` build on.
//
// This file speaks only the wire: every field it reads came off a real
// socket, decoded from real JSON, and every action it takes is a message
// docs/PROTOCOL.md section 4 says a client may send. It never decides
// legality, never rolls a die and never advances a turn itself, exactly the
// restriction section 10 puts on a real client.

import 'dart:async';

import 'fairness.dart';
import 'json.dart';
import 'scenario.dart';
import 'wire.dart';

/// One seat in the room: its index, its display name, the seat token that
/// reclaims it, and the socket currently attached to it. [socket] is
/// reassigned, never the [Seat] object itself, when a seat reconnects --
/// every reference to "seat 2" throughout a scenario stays the same [Seat]
/// instance for the seat's whole life, so a caller never has to remember to
/// look up a fresh one after a reconnect.
class Seat {
  Seat(
      {required this.index,
      required this.name,
      required this.token,
      required this.socket});

  final int index;
  final String name;
  final String token;
  SimSocket socket;
}

/// Everything a scenario needs after the LOBBY -> PLAYING handshake to run
/// the turn loop and to verify fairness.
class GameSetup {
  GameSetup({
    required this.code,
    required this.chainCommit,
    required this.hostSeat,
    required this.seats,
    required this.gameId,
    required this.clientSeeds,
    required this.initialTurnSeat,
    required this.allSockets,
  });

  final String code;
  final String chainCommit;
  final int hostSeat;
  final Map<int, Seat> seats;
  final String gameId;
  final String clientSeeds;
  final int initialTurnSeat;

  /// Every socket ever opened during setup, in the order it was opened.
  /// Scenarios append to this same list as they open more (reconnects), so
  /// one `finally` block can close everything regardless of which seat
  /// currently owns which socket.
  final List<SimSocket> allSockets;
}

/// Creates a room for [players] seats on [target], joins the remaining
/// [players] - 1 seats by the room code exactly as a friend with a shared
/// link would, has the host set one player-chosen seed (exercising the
/// `origin: "player"` path) and leaves the rest for the server to assign
/// (`origin: "server"`), then starts the game and drains the resulting
/// `game_started` and `seat_seed` broadcasts off every socket.
Future<GameSetup> setUpGame(Uri target, int players) async {
  final List<SimSocket> allSockets = <SimSocket>[];
  final Map<int, Seat> seats = <int, Seat>{};

  final SimSocket hostSocket = await SimSocket.connect(target, label: 'host');
  allSockets.add(hostSocket);
  await hostSocket.send('create_room', <String, Object?>{
    'name': 'Sim Host',
    'players': players,
  });
  final Frame hostSeatAssigned = await hostSocket.next();
  expectFrameType(hostSeatAssigned, 'seat_assigned',
      because: 'create_room reply 1/2');
  final Frame hostRoom = await hostSocket.next();
  expectFrameType(hostRoom, 'room', because: 'create_room reply 2/2');

  final Map<String, Object?> hostSeatData = frameData(hostSeatAssigned);
  final Map<String, Object?> hostRoomData = frameData(hostRoom);
  final String code = requireString(hostRoomData, 'code', frame: 'room');
  final String chainCommit =
      requireString(hostRoomData, 'chain_commit', frame: 'room');
  final int hostSeatIdx =
      requireInt(hostSeatData, 'seat', frame: 'seat_assigned');
  final String hostToken =
      requireString(hostSeatData, 'seat_token', frame: 'seat_assigned');
  final int hostSeatFromRoom =
      requireInt(hostRoomData, 'host_seat', frame: 'room');
  if (hostSeatFromRoom != hostSeatIdx) {
    throw ScenarioFailure(
      'room.host_seat=$hostSeatFromRoom disagrees with the seat '
      'seat_assigned gave the creating socket ($hostSeatIdx)',
    );
  }

  seats[hostSeatIdx] = Seat(
    index: hostSeatIdx,
    name: 'Sim Host',
    token: hostToken,
    socket: hostSocket,
  );

  for (int i = 1; i < players; i++) {
    final String label = 'guest-$i';
    final SimSocket guestSocket = await SimSocket.connect(target, label: label);
    allSockets.add(guestSocket);

    final List<Seat> previouslyConnected = List<Seat>.of(seats.values);

    await guestSocket.send('join_room', <String, Object?>{
      'code': code,
      'name': 'Sim Guest $i',
    });
    final Frame seatAssigned = await guestSocket.next();
    expectFrameType(seatAssigned, 'seat_assigned',
        because: 'join_room reply 1/2 ($label)');
    final Frame roomFrame = await guestSocket.next();
    expectFrameType(roomFrame, 'room', because: 'join_room reply 2/2 ($label)');

    final Map<String, Object?> seatData = frameData(seatAssigned);
    final Map<String, Object?> roomData = frameData(roomFrame);
    final String guestChainCommit =
        requireString(roomData, 'chain_commit', frame: 'room ($label)');
    if (guestChainCommit != chainCommit) {
      throw ScenarioFailure(
        'room.chain_commit changed between the host\'s room frame '
        '($chainCommit) and $label\'s ($guestChainCommit); '
        'docs/PROTOCOL.md section 11.2 forbids that for the same '
        'chain_index',
      );
    }
    final int seatIdx =
        requireInt(seatData, 'seat', frame: 'seat_assigned ($label)');
    final String token =
        requireString(seatData, 'seat_token', frame: 'seat_assigned ($label)');
    seats[seatIdx] = Seat(
      index: seatIdx,
      name: 'Sim Guest $i',
      token: token,
      socket: guestSocket,
    );

    // Every socket already in the room receives one player_joined push for
    // this new seat (docs/PROTOCOL.md section 5); drain it before moving on
    // so later reads on those sockets see only what a later message
    // actually produces.
    for (final Seat existing in previouslyConnected) {
      final Frame pushed = await existing.socket.next();
      expectFrameType(
        pushed,
        'player_joined',
        because:
            'broadcast of $label joining, observed by seat ${existing.index}',
      );
      final int joinedSeat =
          requireInt(frameData(pushed), 'seat', frame: 'player_joined');
      if (joinedSeat != seatIdx) {
        throw ScenarioFailure(
          'seat ${existing.index} got player_joined for seat $joinedSeat '
          'right after $label (seat $seatIdx) joined',
        );
      }
    }
  }

  // The host sets its own seed -- origin "player" -- and everyone else lets
  // the server assign one at start_game -- origin "server". Exercises both
  // branches of docs/PROTOCOL.md section 11.2 / docs/FAIRNESS.md section 2.2
  // in the same run.
  final String hostSeed =
      'sim-seed-host-${DateTime.now().microsecondsSinceEpoch}';
  await hostSocket.send('set_seed', <String, Object?>{'client_seed': hostSeed});
  for (final Seat seat in seats.values) {
    final Frame pushed = await seat.socket.next();
    expectFrameType(
      pushed,
      'seat_seed',
      because:
          'broadcast of the host\'s set_seed, observed by seat ${seat.index}',
    );
    final int seededSeat =
        requireInt(frameData(pushed), 'seat', frame: 'seat_seed');
    if (seededSeat != hostSeatIdx) {
      throw ScenarioFailure(
        'seat ${seat.index} got seat_seed for seat $seededSeat right '
        'after only the host (seat $hostSeatIdx) called set_seed',
      );
    }
    final String origin =
        requireString(frameData(pushed), 'origin', frame: 'seat_seed');
    if (origin != 'player') {
      throw ScenarioFailure(
        'seat_seed for the host\'s own set_seed carried origin="$origin", '
        'expected "player" per docs/PROTOCOL.md section 11.2',
      );
    }
  }

  await hostSocket.send('start_game', <String, Object?>{});
  final int expectedServerSeeds = players - 1;
  String? gameId;
  String? clientSeeds;
  int? initialTurnSeat;
  for (final Seat seat in seats.values) {
    final Map<String, Object?> started = await _collectStartGameFrames(
      seat.socket,
      expectedServerSeeds: expectedServerSeeds,
    );
    if (seat.index == hostSeatIdx) {
      gameId = requireString(started, 'game_id', frame: 'game_started');
      clientSeeds =
          requireString(started, 'client_seeds', frame: 'game_started');
      initialTurnSeat = requireInt(started, 'turn', frame: 'game_started');
    }
  }

  if (gameId == null || clientSeeds == null || initialTurnSeat == null) {
    throw ScenarioFailure(
        'start_game never produced a game_started frame on the host socket');
  }

  return GameSetup(
    code: code,
    chainCommit: chainCommit,
    hostSeat: hostSeatIdx,
    seats: seats,
    gameId: gameId,
    clientSeeds: clientSeeds,
    initialTurnSeat: initialTurnSeat,
    allSockets: allSockets,
  );
}

/// Reads frames off [socket] until it has seen one `game_started` and
/// exactly [expectedServerSeeds] `seat_seed` frames (the seats that did not
/// call `set_seed` themselves, fixed by the server "at `start_game` for
/// every seat that sent none", docs/PROTOCOL.md section 11.2). Order
/// between the two is not pinned by the protocol, so both are tolerated in
/// either order; anything else arriving here is unexpected and fails.
Future<Map<String, Object?>> _collectStartGameFrames(
  SimSocket socket, {
  required int expectedServerSeeds,
  int maxFrames = 32,
}) async {
  int serverSeedsSeen = 0;
  Map<String, Object?>? started;
  for (int i = 0; i < maxFrames; i++) {
    if (started != null && serverSeedsSeen >= expectedServerSeeds) {
      break;
    }
    final Frame frame = await socket.next();
    final String type = frameType(frame);
    if (type == 'seat_seed') {
      final String origin =
          requireString(frameData(frame), 'origin', frame: 'seat_seed');
      if (origin != 'server') {
        throw ScenarioFailure(
          '[${socket.label}] unexpected extra seat_seed with origin '
          '"$origin" while collecting the server-assigned seeds around '
          'start_game',
        );
      }
      serverSeedsSeen++;
    } else if (type == 'game_started') {
      started = frameData(frame);
    } else {
      throw ScenarioFailure(
        '[${socket.label}] expected only game_started or server seat_seed '
        'frames around start_game, got "$type": ${frameData(frame)}',
      );
    }
  }
  if (started == null) {
    throw ScenarioFailure(
      '[${socket.label}] start_game did not produce a game_started frame '
      'within $maxFrames frames',
    );
  }
  if (serverSeedsSeen != expectedServerSeeds) {
    throw ScenarioFailure(
      '[${socket.label}] expected $expectedServerSeeds server-assigned '
      'seat_seed frames around start_game, saw $serverSeedsSeen',
    );
  }
  return started;
}

/// The result of playing one game to its end.
class PlayResult {
  PlayResult({required this.winner, required this.rollsVerified});
  final int winner;
  final int rollsVerified;
}

/// Plays the turn loop of docs/PROTOCOL.md section 12 to a winner, reading
/// every frame from [observer] (a socket that receives every broadcast in
/// the room, per section 12.3: "broadcast to every connected socket in the
/// room") and sending `roll` or `move` on whichever [seats] entry the
/// frame says is on turn. Every `move` picks the first token in the
/// `legal` list the server itself sent in the `rolled` frame that
/// preceded it -- never a token the simulator decided was legal on its
/// own.
///
/// [onTurnFrame], if given, runs once per `turn` frame received, before
/// this function decides whether to send a `roll` for it, and may mutate
/// [seats] (a reconnect replaces a `Seat`'s `socket`) -- the scenario files
/// use this to drop and reconnect sockets mid-game without duplicating the
/// turn loop itself.
Future<PlayResult> playGame({
  required SimSocket observer,
  required Map<int, Seat> seats,
  required FairnessTracker fairness,
  required int initialTurnSeat,
  Future<void> Function(int turnSeat, int rollsSoFar)? onTurnFrame,
  Duration perFrameTimeout = const Duration(seconds: 20),
  int maxFrames = 20000,
}) async {
  int? rollInFlightForSeat = initialTurnSeat;
  await _seatFor(seats, initialTurnSeat)
      .socket
      .send('roll', <String, Object?>{});

  int? winner;
  int framesRead = 0;
  while (winner == null) {
    framesRead++;
    if (framesRead > maxFrames) {
      throw ScenarioFailure(
        'read $maxFrames frames without reaching game_over; '
        'giving up rather than looping forever',
      );
    }
    final Frame frame = await observer.next(timeout: perFrameTimeout);
    final String type = frameType(frame);
    final Map<String, Object?> d = frameData(frame);
    switch (type) {
      case 'rolled':
        fairness.verifyRolled(d);
        rollInFlightForSeat = null;
        final int seat = requireInt(d, 'seat', frame: 'rolled');
        final List<int> legal = requireIntList(d, 'legal', frame: 'rolled');
        if (legal.isNotEmpty) {
          final int token = legal.first;
          await _seatFor(seats, seat)
              .socket
              .send('move', <String, Object?>{'token': token});
        }
        break;
      case 'turn':
        final int seat = requireInt(d, 'seat', frame: 'turn');
        if (onTurnFrame != null) {
          await onTurnFrame(seat, fairness.rollsVerified);
        }
        if (rollInFlightForSeat != seat) {
          await _seatFor(seats, seat).socket.send('roll', <String, Object?>{});
          rollInFlightForSeat = seat;
        }
        break;
      case 'game_over':
        winner = requireInt(d, 'winner', frame: 'game_over');
        break;
      case 'error':
        throw ScenarioFailure(
          'unexpected error frame during play: ${d['code']}: ${d['message']}',
        );
      case 'moved':
      case 'turn_passed':
      case 'player_left':
      case 'presence':
      case 'seat_seed':
      case 'room':
        // Informational; no client action follows from these on their own.
        break;
      default:
        // Tolerate anything else the protocol may add; this driver only
        // acts on the frame types the turn loop actually needs.
        break;
    }
  }

  return PlayResult(winner: winner, rollsVerified: fairness.rollsVerified);
}

Seat _seatFor(Map<int, Seat> seats, int index) {
  final Seat? seat = seats[index];
  if (seat == null) {
    throw ScenarioFailure('no seat $index in this room\'s seat map');
  }
  return seat;
}

/// Closes [seatIndex]'s current socket hard -- the raw connection, never a
/// `leave_room` message -- exactly the "socket closed hard" of the work
/// order's reconnect scenario, as distinct from the voluntary `leave_room`
/// path of docs/PROTOCOL.md section 4, which frees the seat in LOBBY and
/// would be the wrong test of a mid-game drop.
Future<void> dropSocketOnly(int seatIndex, Map<int, Seat> seats) async {
  await _seatFor(seats, seatIndex).socket.close();
}

/// Reconnects [seatIndex] with a fresh socket, sending `resume` with its
/// stored `code` and `seat_token` (docs/PROTOCOL.md section 8), and
/// replaces the entry in [seats] with the new socket. Verifies the
/// resumed snapshot names the same seat as connected and republishes the
/// same `chain_commit` this room started with.
Future<void> reconnectSeat({
  required int seatIndex,
  required Map<int, Seat> seats,
  required Uri target,
  required String code,
  required String expectedChainCommit,
  required List<SimSocket> allSockets,
  required int attempt,
}) async {
  final Seat old = _seatFor(seats, seatIndex);
  final String label = 'seat-$seatIndex-reconnect-$attempt';
  final SimSocket newSocket = await SimSocket.connect(target, label: label);
  allSockets.add(newSocket);
  await newSocket.send('resume', <String, Object?>{
    'code': code,
    'seat_token': old.token,
  });
  final Frame roomFrame = await newSocket.next();
  expectFrameType(roomFrame, 'room',
      because: 'resume reply for seat $seatIndex');
  final Map<String, Object?> roomData = frameData(roomFrame);

  final String chainCommit = requireString(roomData, 'chain_commit',
      frame: 'room (resume seat $seatIndex)');
  if (chainCommit != expectedChainCommit) {
    throw ScenarioFailure(
      'resume for seat $seatIndex returned chain_commit=$chainCommit, '
      'expected the room\'s original $expectedChainCommit; '
      'docs/PROTOCOL.md section 11.2 forbids it changing',
    );
  }

  final List<Map<String, Object?>> seatRows =
      requireMapList(roomData, 'seats', frame: 'room (resume seat $seatIndex)');
  final Map<String, Object?> myRow = seatRows.firstWhere(
    (Map<String, Object?> row) =>
        requireInt(row, 'seat', frame: 'room.seats entry') == seatIndex,
    orElse: () => throw ScenarioFailure(
      'resumed room snapshot for seat $seatIndex has no entry for that seat',
    ),
  );
  final bool connected =
      requireBool(myRow, 'connected', frame: 'room.seats entry (resume)');
  if (!connected) {
    throw ScenarioFailure(
      'seat $seatIndex resumed but its own row in the room snapshot still '
      'shows connected=false',
    );
  }

  seats[seatIndex] = Seat(
    index: seatIndex,
    name: old.name,
    token: old.token,
    socket: newSocket,
  );
}

/// Drains frames off [socket] until a `game_over` naming [expectedWinner]
/// is found. Used after the turn loop ends to confirm, per the work order,
/// that "every one of the four clients received" the same `game_over` --
/// a socket that was never the scenario's driving observer may have every
/// broadcast of the whole game still sitting in its own queue unread, so
/// this can need to skip a great many frames on a long game; each
/// individual read is still bounded by [perFrame] so a socket that truly
/// never gets the frame fails promptly rather than hanging.
Future<void> assertReceivedGameOver(
  SimSocket socket,
  int expectedWinner, {
  int maxFrames = 20000,
  Duration perFrame = const Duration(seconds: 10),
}) async {
  for (int i = 0; i < maxFrames; i++) {
    final Frame frame = await socket.next(timeout: perFrame);
    if (frameType(frame) == 'game_over') {
      final int winner =
          requireInt(frameData(frame), 'winner', frame: 'game_over');
      if (winner != expectedWinner) {
        throw ScenarioFailure(
          '[${socket.label}] received game_over with winner=$winner but '
          'the driving observer saw winner=$expectedWinner for the same '
          'game',
        );
      }
      return;
    }
  }
  throw ScenarioFailure(
    '[${socket.label}] never received a game_over frame within $maxFrames '
    'frames',
  );
}

// docs/PROTOCOL.md sections 2, 3 and 7; docs/RULES.md section 2.
//
// The registry is the only thing in this package that touches room state.
// Every method here is a pure function of (its own maps, the injected
// clock, the injected random source, and its arguments). Nothing here reads
// a wall clock, opens a socket or parses JSON; those are order 007's job.

import 'dart:math';

import 'package:fair_dice/fair_dice.dart' show DiceChain, hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;

import 'clock.dart';
import 'room.dart';
import 'room_code.dart';
import 'seat_token.dart';

/// Every error this package can hand a caller, one to one with the table in
/// `docs/PROTOCOL.md` section 7. A value is never invented at a call site;
/// every failure path below picks one of these and only these.
enum ProtocolError {
  protocolVersion,
  badType,
  badField,
  tooLarge,
  rateLimited,
  noSuchRoom,
  roomFull,
  roomStarted,
  notHost,
  notEnoughPlayers,
  notYourTurn,
  wrongPhase,
  illegalMove,
  badSeatToken,
  seedAlreadySet,
  gameOver,
  internal,
}

sealed class CreateResult {}

class CreateOk extends CreateResult {
  CreateOk({required this.room, required this.seat});
  final Room room;
  final Seat seat;
}

class CreateFailure extends CreateResult {
  CreateFailure(this.error);
  final ProtocolError error;
}

sealed class JoinResult {}

class JoinOk extends JoinResult {
  JoinOk({required this.room, required this.seat});
  final Room room;
  final Seat seat;
}

class JoinFailure extends JoinResult {
  JoinFailure(this.error);
  final ProtocolError error;
}

sealed class ResumeResult {}

class ResumeOk extends ResumeResult {
  ResumeOk({required this.room, required this.seat, required this.reconnected});
  final Room room;
  final Seat seat;

  /// True when this call flipped the seat from disconnected to connected.
  /// False for a takeover of a seat that was already connected -- the wire
  /// layer uses this to decide whether a `presence` push actually describes
  /// a change, since the registry only advances `seq` on a real flip.
  final bool reconnected;
}

class ResumeFailure extends ResumeResult {
  ResumeFailure(this.error);
  final ProtocolError error;
}

sealed class StartResult {}

class StartOk extends StartResult {
  StartOk({required this.room, required this.serverSeeded});
  final Room room;

  /// Seats that had no `client_seed` when this call ran and were given a
  /// server-drawn one, in ascending seat order, each paired with `room.seq`
  /// at the instant that particular fix happened. `docs/PROTOCOL.md`
  /// section 5 puts `seat_seed` on the list of pushes that carry `seq` and
  /// section 6's `Room.seq` doc calls every such push its own
  /// state-changing call -- so each entry here needs its own `seq`, not the
  /// room's final one once every fix (and the game start itself) has
  /// landed.
  final List<SeededSeat> serverSeeded;
}

class StartFailure extends StartResult {
  StartFailure(this.error);
  final ProtocolError error;
}

/// One seat fixed with a server-drawn seed during a single `start_game`
/// call, paired with the room's `seq` at the moment of that specific fix.
class SeededSeat {
  SeededSeat({required this.seat, required this.seq});
  final Seat seat;
  final int seq;
}

sealed class SetSeedResult {}

class SetSeedOk extends SetSeedResult {
  SetSeedOk({required this.room, required this.seat});
  final Room room;
  final Seat seat;
}

class SetSeedFailure extends SetSeedResult {
  SetSeedFailure(this.error);
  final ProtocolError error;
}

sealed class SetPlayersResult {}

class SetPlayersOk extends SetPlayersResult {
  SetPlayersOk({required this.room});
  final Room room;
}

class SetPlayersFailure extends SetPlayersResult {
  SetPlayersFailure(this.error);
  final ProtocolError error;
}

sealed class LeaveResult {}

class LeaveOk extends LeaveResult {
  LeaveOk({required this.room, required this.seat});
  final Room room;

  /// The seat that left. In LOBBY it has already been removed from
  /// `room.seats`; in PLAYING and FINISHED it is still there, marked
  /// disconnected.
  final Seat seat;
}

class LeaveFailure extends LeaveResult {
  LeaveFailure(this.error);
  final ProtocolError error;
}

const Duration _lobbyIdleTimeout = Duration(minutes: 10);
const Duration _finishedTimeout = Duration(minutes: 10);
const Duration _anyRoomTimeout = Duration(minutes: 60);
const Duration _codeQuarantine = Duration(hours: 24);

const int _minName = 1;
const int _maxName = 24;
const int _minTurnSeconds = 15;
const int _maxTurnSeconds = 120;

/// `docs/PROTOCOL.md` section 11.2/11.3: the server secret a chain is
/// rooted at is 32 bytes, a server-drawn seed handed to a seed-less seat at
/// `start_game` is 16 bytes (32 lowercase hex characters), and `game_id` is
/// 8 bytes (16 lowercase hex characters).
const int _serverSecretBytes = 32;
const int _serverSeedBytes = 16;
const int _gameIdBytes = 8;

const int _minClientSeed = 1;
const int _maxClientSeed = 64;
final RegExp _clientSeedPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// In-memory rooms: creation, codes, seats, seat tokens, lifecycle and
/// reaping. No WebSocket, no HTTP, no timer driven by the wall clock --
/// every decision here is a pure function of this registry's own state plus
/// the `Clock` and `Random` it was built with.
class RoomRegistry {
  RoomRegistry({required Clock clock, required Random secure})
      : _clock = clock,
        _secure = secure;

  final Clock _clock;
  final Random _secure;

  final Map<String, Room> _rooms = <String, Room>{};

  /// Code -> the moment it stops being quarantined (reap time + 24h).
  final Map<String, DateTime> _quarantine = <String, DateTime>{};

  /// Room code -> the moment its LOBBY first had no connected seat. Absent
  /// while at least one seat is connected.
  final Map<String, DateTime> _lobbyIdleSince = <String, DateTime>{};

  /// Room code -> the moment this registry first observed it FINISHED.
  /// There is no field on `Room` for this (the frozen shape has none) and
  /// no method on this registry ever sets `state` to `finished` -- order
  /// 008's turn loop does that by mutating `Room.game` and `Room.state`
  /// directly, the same way it is expected to mutate them for every other
  /// in-play change. This map is populated lazily, the first time `reap()`
  /// sees a room in that state, so the 10 minute FINISHED eviction of
  /// `docs/PROTOCOL.md` section 3 works without a frozen-interface change.
  /// It depends on `reap()` being called reasonably often once a game ends;
  /// this order never drives a room to FINISHED itself, so this path is
  /// unexercised by anything in this order's own scope.
  final Map<String, DateTime> _finishedSince = <String, DateTime>{};

  CreateResult createRoom({
    required String name,
    required int players,
    required RulesConfig rules,
  }) {
    final String? trimmedName = _validName(name);
    if (trimmedName == null) {
      return CreateFailure(ProtocolError.badField);
    }
    if (players != 2 && players != 3 && players != 4) {
      return CreateFailure(ProtocolError.badField);
    }
    if (rules.turnSeconds < _minTurnSeconds ||
        rules.turnSeconds > _maxTurnSeconds) {
      return CreateFailure(ProtocolError.badField);
    }

    final String code = _generateUniqueCode();
    final int hostSeatIndex = _seatIndicesFor(players).first;
    final Seat hostSeat = Seat(
      seat: hostSeatIndex,
      name: trimmedName,
      seatToken: generateSeatToken(_secure),
      connected: true,
    );
    // docs/PROTOCOL.md section 11.1: the chain is built, and its commitment
    // fixed, before this room exists anywhere a `set_seed` could reach it --
    // `_rooms[code] = room` below is the first point at which the code this
    // chain belongs to resolves to anything at all, so no player seed can
    // possibly have been accepted before this line runs.
    final DiceChain chain = DiceChain.build(_drawBytes(_serverSecretBytes));
    final Room room = Room(
      code: code,
      createdAt: _clock.now,
      players: players,
      rules: rules,
      state: RoomState.lobby,
      hostSeat: hostSeatIndex,
      seats: <Seat>[hostSeat],
      game: null,
      chain: chain,
    );
    _rooms[code] = room;
    _refreshIdleTracking(room);
    return CreateOk(room: room, seat: hostSeat);
  }

  JoinResult joinRoom({required String code, required String name}) {
    final Room? room = _rooms[code];
    if (room == null) {
      return JoinFailure(ProtocolError.noSuchRoom);
    }
    if (room.state != RoomState.lobby) {
      return JoinFailure(ProtocolError.roomStarted);
    }
    final String? trimmedName = _validName(name);
    if (trimmedName == null) {
      return JoinFailure(ProtocolError.badField);
    }
    final Set<int> taken = room.seats.map((Seat s) => s.seat).toSet();
    final List<int> free = _seatIndicesFor(room.players)
        .where((int s) => !taken.contains(s))
        .toList();
    if (free.isEmpty) {
      return JoinFailure(ProtocolError.roomFull);
    }
    final Seat seat = Seat(
      seat: free.first,
      name: trimmedName,
      seatToken: generateSeatToken(_secure),
      connected: true,
    );
    room.seats = <Seat>[...room.seats, seat]
      ..sort((Seat a, Seat b) => a.seat.compareTo(b.seat));
    _refreshIdleTracking(room);
    room.seq++;
    return JoinOk(room: room, seat: seat);
  }

  ResumeResult resume({required String code, required String seatToken}) {
    final Room? room = _rooms[code];
    if (room == null) {
      return ResumeFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return ResumeFailure(ProtocolError.badSeatToken);
    }
    final bool reconnected = !seat.connected;
    seat.connected = true;
    _refreshIdleTracking(room);
    if (reconnected) {
      room.seq++;
    }
    return ResumeOk(room: room, seat: seat, reconnected: reconnected);
  }

  StartResult startGame({required String code, required String seatToken}) {
    final Room? room = _rooms[code];
    if (room == null) {
      return StartFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return StartFailure(ProtocolError.badSeatToken);
    }
    if (seat.seat != room.hostSeat) {
      return StartFailure(ProtocolError.notHost);
    }
    if (room.state != RoomState.lobby) {
      return StartFailure(ProtocolError.roomStarted);
    }
    if (room.seats.length != room.players) {
      return StartFailure(ProtocolError.notEnoughPlayers);
    }

    // docs/PROTOCOL.md section 11.2: every seat that sent no `set_seed`
    // gets a server-drawn seed here, before `client_seeds` is frozen. Each
    // of these is its own fixed-seed state change (section 5 puts
    // `seat_seed` on the "carrying seq" list), separate from the state
    // change that is the game starting, so each gets its own `seq`.
    // `room.seats` is already ordered by ascending seat index (the
    // invariant `joinRoom` and `setPlayers` both maintain), so iterating it
    // in place produces the seats in the order `client_seeds` needs.
    final List<SeededSeat> serverSeeded = <SeededSeat>[];
    for (final Seat s in room.seats) {
      if (s.clientSeed == null) {
        s.clientSeed = hexEncode(_drawBytes(_serverSeedBytes));
        s.seedOrigin = 'server';
        room.seq++;
        serverSeeded.add(SeededSeat(seat: s, seq: room.seq));
      }
    }

    room.gameId = hexEncode(_drawBytes(_gameIdBytes));
    room.clientSeeds =
        room.seats.map((Seat s) => '${s.seat}:${s.clientSeed}').join('|');

    final List<int> seatIndices = room.seats.map((Seat s) => s.seat).toList()
      ..sort();
    final engine.GameConfig config = engine.GameConfig(
      seats: seatIndices,
      rules: engine.RulesConfig(
        blocks: room.rules.blocks,
        captureBonus: room.rules.captureBonus,
      ),
      seed: _secureSeed(),
    );
    room.game = engine.newGame(config);
    room.state = RoomState.playing;
    room.seq++;
    return StartOk(room: room, serverSeeded: serverSeeded);
  }

  /// `set_seed`, `docs/PROTOCOL.md` section 11.2. The rejection ladder here
  /// is deliberately not the room-exists / seat-authorised / phase-correct
  /// order every other method in this file uses: room existence still runs
  /// first, but phase then overtakes seat authorisation, per section 11.2's
  /// own table, so a request that is wrong in both ways answers
  /// `WRONG_PHASE` rather than `BAD_SEAT_TOKEN`. A room that no longer
  /// exists at all -- never created, or reaped since -- answers
  /// `NO_SUCH_ROOM`, the same as every other entry point in this file.
  SetSeedResult setSeed({
    required String code,
    required String seatToken,
    required Object? clientSeed,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return SetSeedFailure(ProtocolError.noSuchRoom);
    }
    if (room.state != RoomState.lobby) {
      return SetSeedFailure(ProtocolError.wrongPhase);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return SetSeedFailure(ProtocolError.badSeatToken);
    }
    final String? validSeed = _validClientSeed(clientSeed);
    if (validSeed == null) {
      return SetSeedFailure(ProtocolError.badField);
    }
    if (seat.clientSeed != null) {
      return SetSeedFailure(ProtocolError.seedAlreadySet);
    }
    seat.clientSeed = validSeed;
    seat.seedOrigin = 'player';
    room.seq++;
    return SetSeedOk(room: room, seat: seat);
  }

  /// Changes the configured player count of a LOBBY room and re-seats
  /// everyone already present onto the canonical seat set for the new
  /// count, per `docs/RULES.md` rule 2a and `docs/PROTOCOL.md` section 3.
  ///
  /// Every seat keeps its `name`, its `seatToken`, its `connected` flag and
  /// its `clientSeed`/`seedOrigin` across the re-seat; only the seat index
  /// moves. The seat currently at the lowest index takes the lowest index
  /// of the new set, and so on, preserving join order. Carrying the seed
  /// across matters: `docs/PROTOCOL.md` section 11.3 says a seat's seed
  /// never changes once fixed, and rebuilding a fresh `Seat` here without
  /// its seed would silently erase a fixed one, letting the same occupant
  /// `set_seed` again under a new index and defeating "once per seat".
  SetPlayersResult setPlayers({
    required String code,
    required String seatToken,
    required int players,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return SetPlayersFailure(ProtocolError.noSuchRoom);
    }
    final Seat? callerSeat = _findSeat(room, seatToken);
    if (callerSeat == null) {
      return SetPlayersFailure(ProtocolError.badSeatToken);
    }
    if (room.state != RoomState.lobby) {
      return SetPlayersFailure(ProtocolError.roomStarted);
    }
    if (callerSeat.seat != room.hostSeat) {
      return SetPlayersFailure(ProtocolError.notHost);
    }
    if (players != 2 && players != 3 && players != 4) {
      return SetPlayersFailure(ProtocolError.badField);
    }
    if (players < room.seats.length) {
      return SetPlayersFailure(ProtocolError.notEnoughPlayers);
    }

    final List<int> newIndices = _seatIndicesFor(players);
    final List<Seat> ordered = List<Seat>.of(room.seats)
      ..sort((Seat a, Seat b) => a.seat.compareTo(b.seat));
    final List<Seat> reseated = <Seat>[
      for (int i = 0; i < ordered.length; i++)
        Seat(
          seat: newIndices[i],
          name: ordered[i].name,
          seatToken: ordered[i].seatToken,
          connected: ordered[i].connected,
          clientSeed: ordered[i].clientSeed,
          seedOrigin: ordered[i].seedOrigin,
        ),
    ];

    room.players = players;
    room.seats = reseated;
    room.hostSeat =
        reseated.firstWhere((Seat s) => s.seatToken == seatToken).seat;
    room.seq++;

    return SetPlayersOk(room: room);
  }

  LeaveResult leaveRoom({required String code, required String seatToken}) {
    final Room? room = _rooms[code];
    if (room == null) {
      return LeaveFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return LeaveFailure(ProtocolError.badSeatToken);
    }
    if (room.state == RoomState.lobby) {
      room.seats =
          room.seats.where((Seat s) => s.seatToken != seatToken).toList();
      if (room.hostSeat == seat.seat) {
        room.hostSeat = room.seats.isEmpty
            ? -1
            : room.seats.map((Seat s) => s.seat).reduce(min);
      }
      _refreshIdleTracking(room);
    } else {
      // PLAYING: the seat stays in the game and is later played by the
      // timer, per docs/PROTOCOL.md section 3. FINISHED: nothing left to
      // free. Either way the seat is simply marked not connected.
      seat.connected = false;
    }
    room.seq++;
    return LeaveOk(room: room, seat: seat);
  }

  /// Returns true when this call actually flipped the seat's `connected`
  /// flag, false on any of the three early returns (no such room, no such
  /// seat, or the flag already held the requested value). Existing callers
  /// that predate this return value are free to ignore it; only the wire
  /// layer's presence-broadcast decision needs it.
  bool setConnected({
    required String code,
    required String seatToken,
    required bool connected,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return false;
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return false;
    }
    if (seat.connected == connected) {
      return false;
    }
    seat.connected = connected;
    if (room.state == RoomState.lobby) {
      _refreshIdleTracking(room);
    }
    room.seq++;
    return true;
  }

  int reap() {
    final DateTime now = _clock.now;
    final List<String> toRemove = <String>[];
    for (final Room room in _rooms.values) {
      if (now.difference(room.createdAt) >= _anyRoomTimeout) {
        toRemove.add(room.code);
        continue;
      }
      if (room.state == RoomState.lobby) {
        final DateTime? idleSince = _lobbyIdleSince[room.code];
        if (idleSince != null &&
            now.difference(idleSince) >= _lobbyIdleTimeout) {
          toRemove.add(room.code);
        }
      } else if (room.state == RoomState.finished) {
        final DateTime finishedSince =
            _finishedSince.putIfAbsent(room.code, () => now);
        if (now.difference(finishedSince) >= _finishedTimeout) {
          toRemove.add(room.code);
        }
      }
    }
    for (final String code in toRemove) {
      _rooms.remove(code);
      _lobbyIdleSince.remove(code);
      _finishedSince.remove(code);
      _quarantine[code] = now.add(_codeQuarantine);
    }
    _quarantine.removeWhere(
      (String code, DateTime expiry) => !now.isBefore(expiry),
    );
    return toRemove.length;
  }

  Room? lookup(String code) => _rooms[code];

  /// How many rooms this registry currently holds, including one that has
  /// expired but has not yet been reaped. A getter, not a computation:
  /// no reaping happens as a side effect of reading it.
  int get roomCount => _rooms.length;

  void _refreshIdleTracking(Room room) {
    final bool idle = room.seats.every((Seat s) => !s.connected);
    if (idle) {
      _lobbyIdleSince.putIfAbsent(room.code, () => _clock.now);
    } else {
      _lobbyIdleSince.remove(room.code);
    }
  }

  Seat? _findSeat(Room room, String seatToken) {
    for (final Seat seat in room.seats) {
      if (seat.seatToken == seatToken) {
        return seat;
      }
    }
    return null;
  }

  String _generateUniqueCode() {
    while (true) {
      final String candidate = generateRoomCode(_secure);
      if (_rooms.containsKey(candidate)) {
        continue;
      }
      final DateTime? quarantinedUntil = _quarantine[candidate];
      if (quarantinedUntil != null && _clock.now.isBefore(quarantinedUntil)) {
        continue;
      }
      return candidate;
    }
  }

  int _secureSeed() {
    final int hi = _secure.nextInt(1 << 32);
    final int lo = _secure.nextInt(1 << 32);
    return (hi << 32) | lo;
  }

  /// [n] bytes straight off this registry's CSPRNG. The only source of
  /// randomness for a chain's server secret, a server-drawn seat seed and a
  /// `game_id` -- all three are byte strings with no further structure, so
  /// there is nothing beyond this to draw them with.
  List<int> _drawBytes(int n) =>
      List<int>.generate(n, (int _) => _secure.nextInt(256));
}

/// `docs/PROTOCOL.md` section 11.2: `client_seed` absent, not a string,
/// empty, over 64 characters, or containing anything outside
/// `[A-Za-z0-9_-]` is `BAD_FIELD`. Returns the seed unchanged when valid,
/// null otherwise -- this never trims, lowercases or truncates, because a
/// seed that fails the check is rejected, not repaired.
String? _validClientSeed(Object? raw) {
  if (raw is! String) {
    return null;
  }
  if (raw.length < _minClientSeed || raw.length > _maxClientSeed) {
    return null;
  }
  if (!_clientSeedPattern.hasMatch(raw)) {
    return null;
  }
  return raw;
}

List<int> _seatIndicesFor(int players) {
  switch (players) {
    case 2:
      return const <int>[0, 2];
    case 3:
      return const <int>[0, 1, 2];
    case 4:
      return const <int>[0, 1, 2, 3];
    default:
      throw ArgumentError.value(players, 'players', 'must be 2, 3 or 4');
  }
}

final RegExp _controlCharacter = RegExp(r'[\x00-\x1f\x7f-\x9f]');

/// Returns the trimmed name if it is 1 to 24 characters with no control
/// characters, otherwise null.
String? _validName(String name) {
  final String trimmed = name.trim();
  if (trimmed.length < _minName || trimmed.length > _maxName) {
    return null;
  }
  if (_controlCharacter.hasMatch(trimmed)) {
    return null;
  }
  return trimmed;
}

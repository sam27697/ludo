// docs/PROTOCOL.md sections 2, 3 and 7; docs/RULES.md section 2.
//
// The registry is the only thing in this package that touches room state.
// Every method here is a pure function of (its own maps, the injected
// clock, the injected random source, and its arguments). Nothing here reads
// a wall clock, opens a socket or parses JSON; those are order 007's job.

import 'dart:convert' show jsonEncode;
import 'dart:io' show stderr;
import 'dart:math';

import 'package:fair_dice/fair_dice.dart' show DiceChain, drawDie, hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;

import 'clock.dart';
import 'room.dart';
import 'room_code.dart';
import 'seat_token.dart';
import 'snapshot.dart' show buildRoomSnapshot;
import 'verify_record.dart';
import 'verify_store.dart';

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
  StartOk({
    required this.room,
    required this.serverSeeded,
    required this.gameStartedSeq,
    required this.turnSeq,
    required this.nextDeadlineMs,
    this.removedSeats = const <RemovedSeat>[],
    this.movedSeats = const <Seat>[],
    this.reseatSeq,
    this.reseatRoom,
  });
  final Room room;

  /// `docs/PROTOCOL.md` section 16.4, "Not everyone": every occupied seat
  /// the host's own `start_game` removed for not being ready, in ascending
  /// seat order, each paired with `room.seq` at the instant that specific
  /// removal's own `player_left` was decided -- before the re-seat below and
  /// before the start sequence that follows it. Empty for every start that
  /// is not that one path: an ordinary `start_game` from a plain LOBBY, and
  /// the section 16.4 "Everyone accepted" auto-start, both leave this empty.
  final List<RemovedSeat> removedSeats;

  /// `docs/PROTOCOL.md` section 15 rule 1, reused by section 16.4's re-seat:
  /// seats whose index moved when the remaining, ready seats were re-seated
  /// onto the canonical set for their new count, each the post-reseat `Seat`
  /// (new `seat`, same `seatToken`). Empty whenever [removedSeats] is empty,
  /// and also empty when a removal happened but left every remaining seat's
  /// index exactly where it was.
  final List<Seat> movedSeats;

  /// The `seq` of the `room` snapshot that announces the section 16.4
  /// re-seat, taken the instant that specific state change landed -- before
  /// `gameStartedSeq`, which always follows it. Null when this call removed
  /// no seat at all: either because it is not the section 16.4 "Not
  /// everyone" path, or because it is that path but nobody needed removing
  /// (`docs/PROTOCOL.md` section 16.9 rule 3 -- a host `start_game` with
  /// every occupied seat already ready sends no re-seat `room` of its own).
  final int? reseatSeq;

  /// The `room` snapshot that announces the section 16.4 re-seat, built the
  /// instant the re-seat landed, at [reseatSeq]: LOBBY, the new seating and
  /// `rematch` null. Built here rather than by the caller because by the
  /// time the caller sends it, the start below has already moved `room` on
  /// (server seeds, `game_started`, `turn`), and a snapshot taken then
  /// carries the wrong `seq` and the wrong state. Null exactly when
  /// [reseatSeq] is.
  final Map<String, Object?>? reseatRoom;

  /// Seats that had no `client_seed` when this call ran and were given a
  /// server-drawn one, in ascending seat order, each paired with `room.seq`
  /// at the instant that particular fix happened. `docs/PROTOCOL.md`
  /// section 5 puts `seat_seed` on the list of pushes that carry `seq` and
  /// section 6's `Room.seq` doc calls every such push its own
  /// state-changing call -- so each entry here needs its own `seq`, not the
  /// room's final one once every fix (and the game start itself) has
  /// landed.
  final List<SeededSeat> serverSeeded;

  /// `game_started`'s own `seq`, read the instant this call's own state
  /// change (the room moving to PLAYING) advanced the counter to it -- not
  /// recomputed later from `turnSeq`, and not read back out of `room.seq`
  /// after the counter has moved again for the `turn` frame below.
  final int gameStartedSeq;

  /// `docs/PROTOCOL.md` section 13.1: the standalone `turn` frame that
  /// always follows `game_started` takes the next `seq` after it, one
  /// greater than `game_started`'s own.
  final int turnSeq;

  /// The opening segment's `deadline_ms` for that `turn` frame: what is
  /// left of the segment `_restartSegment` already started earlier in this
  /// same call, read fresh rather than assumed to still be the full
  /// `rules.turnSeconds * 1000` it began at.
  final int nextDeadlineMs;
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

/// One seat removed by the host's own `start_game` in a rematch LOBBY,
/// `docs/PROTOCOL.md` section 16.4 "Not everyone": "every occupied seat that
/// is not ready is removed as if it had sent `leave_room`". [seat] is the
/// seat as it stood immediately before removal, at its pre-reseat index.
class RemovedSeat {
  RemovedSeat({required this.seat, required this.seq});
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

sealed class RollResult {}

/// `roll`, `docs/PROTOCOL.md` section 12.1. Carries everything the wire
/// layer needs to build the `rolled` frame, and -- when the roll ends the
/// turn -- the `turn_passed` and `turn` frames that follow it, without the
/// wire layer recomputing a face, a chain link or a `seq`.
///
/// [events] is `Applied.events` from the engine call this roll made,
/// unmodified: the `Rolled` event it always contains carries the seat, the
/// value and the legal set, and a `TurnEnded`/`TurnBegan` pair is present
/// exactly when the turn passed. [k] and [reveal] have no engine
/// equivalent -- the engine does not know about the dice chain -- so they
/// are carried here explicitly, alongside every `seq` and `deadline_ms`
/// this call decided, each already read from the room's own counter and
/// clock at the instant that specific frame was fixed.
class RollOk extends RollResult {
  RollOk({
    required this.room,
    required this.events,
    required this.k,
    required this.reveal,
    required this.rolledSeq,
    required this.rolledDeadlineMs,
    this.turnPassedSeq,
    this.turnSeq,
    this.nextDeadlineMs,
  });

  final Room room;
  final List<engine.GameEvent> events;

  /// 1-based within this game. `chain.reveal(k)` was read for exactly this
  /// value and no other.
  final int k;

  /// `s[k]`, 64 lowercase hex characters.
  final String reveal;

  final int rolledSeq;

  /// The `rolled` frame's own `deadline_ms`. When the roll leaves a legal
  /// move pending this is a freshly restarted segment (the full
  /// `rules.turnSeconds`); when the roll ends the turn it is what was left
  /// of the segment that was already running, because that segment does not
  /// restart until the `turn` frame below.
  final int rolledDeadlineMs;

  /// Set together, and only, when the roll ended the turn: the `seq` for
  /// `turn_passed` and for the `turn` frame that follows it.
  final int? turnPassedSeq;
  final int? turnSeq;

  /// The freshly restarted segment's `deadline_ms` for the `turn` frame,
  /// set together with [turnSeq].
  final int? nextDeadlineMs;
}

class RollFailure extends RollResult {
  RollFailure(this.error);
  final ProtocolError error;
}

sealed class MoveResult {}

/// `move`, `docs/PROTOCOL.md` section 12.2. Carries everything the wire
/// layer needs to build the `moved` frame and exactly one of `game_over` or
/// `turn`, whichever applies, again without recomputing anything the
/// registry already decided.
class MoveOk extends MoveResult {
  MoveOk({
    required this.room,
    required this.events,
    required this.movedSeq,
    this.gameOverSeq,
    this.verifyUrl,
    this.turnSeq,
    this.nextDeadlineMs,
  });

  final Room room;
  final List<engine.GameEvent> events;
  final int movedSeq;

  /// Set together, and only, when this move won the game.
  final int? gameOverSeq;
  final String? verifyUrl;

  /// Set together, and only, when the game continues: either the turn
  /// passed, or the same seat was granted an extra roll. Section 12.2 sends
  /// a `turn` frame for the seat that now holds the turn either way.
  final int? turnSeq;
  final int? nextDeadlineMs;
}

class MoveFailure extends MoveResult {
  MoveFailure(this.error);
  final ProtocolError error;
}

/// One turn the server's own timer acted on, and the result the wire layer
/// has to publish for it. [roll] and [move] are mutually exclusive and
/// exactly one of them is set: a segment that ran out while the seat still
/// owed a roll produces a [RollOk], one that ran out while it owed a token
/// selection produces a [MoveOk]. Both carry precisely what the matching
/// client-driven path carries, so the wire layer builds the same frames from
/// them and nothing about a timer-played turn is special downstream.
class ExpiredTurn {
  ExpiredTurn({required this.code, required this.seat, this.roll, this.move});

  /// The room this happened in. Carried explicitly because the wire layer
  /// broadcasts by code and should not have to reach into the result.
  final String code;

  /// The seat the server acted for, 0..3.
  final int seat;

  final RollOk? roll;
  final MoveOk? move;
}

sealed class SetPlayersResult {}

class SetPlayersOk extends SetPlayersResult {
  SetPlayersOk({required this.room, required this.movedSeats});
  final Room room;

  /// The seats whose index this call actually changed, each the post-reseat
  /// `Seat` (new `seat`, same `seatToken`), in ascending order of that new
  /// index. `docs/PROTOCOL.md` section 15 rule 1: every one of these that is
  /// still connected is owed its own `seat_assigned` before the `room` that
  /// carries the reseat, and a seat whose index did not change is owed
  /// nothing. Empty when this call left every occupied index exactly where
  /// it was, which happens whenever the new count's canonical set already
  /// agrees with the old one on every occupied slot.
  final List<Seat> movedSeats;
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

sealed class RematchResult {}

/// `rematch`, `docs/PROTOCOL.md` section 16. One result type covers every
/// accepted call: the first `rematch` of a cycle, which reopens the room
/// from FINISHED (section 16.2); an acceptance that does not yet complete
/// the ready set (section 16.3); a double tap from a seat already ready,
/// which changes nothing (section 16.3); and an acceptance that completes
/// the ready set and starts the game itself (section 16.4, "Everyone
/// accepted").
class RematchOk extends RematchResult {
  RematchOk({
    required this.room,
    required this.changed,
    this.autoStart = false,
  });

  final Room room;

  /// False exactly for a double tap from a seat already in `rematch.ready`:
  /// section 16.3 says `seq` does not advance and only the caller is owed
  /// anything for it.
  final bool changed;

  /// True exactly when this call completed the ready set, with every one of
  /// those seats connected -- section 16.4 "Everyone accepted". [room] is
  /// still LOBBY at this point, carrying the now-complete `rematch.ready`:
  /// starting the game itself is deliberately left for the caller to trigger
  /// separately, through [RoomRegistry.startRematchAuto], once it has
  /// already built and sent the `room` snapshot that records this
  /// acceptance. Doing the start here instead, before returning, would mean
  /// [room] was already PLAYING with `rematch` cleared back to null by the
  /// time any caller read it, so the frame meant to announce the acceptance
  /// would describe the game that followed it instead.
  final bool autoStart;
}

class RematchFailure extends RematchResult {
  RematchFailure(this.error);
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
  RoomRegistry({
    required Clock clock,
    required Random secure,
    VerifyStore? verifyStore,
    String verifyUrlBase = defaultVerifyUrlBase,
  })  : _clock = clock,
        _secure = secure,
        verifyStore = verifyStore ?? MemoryVerifyStore(clock),
        _verifyUrlBase = verifyUrlBase;

  final Clock _clock;
  final Random _secure;

  /// docs/VERIFY.md section 3. Where a finished game's record is written at
  /// the moment it is won, and read back for `/v/<game_id>` and
  /// `/v/<game_id>.json`. Defaults to an in-memory store when no caller
  /// supplies one, which is what every existing call site (and every
  /// existing test) gets, unchanged.
  final VerifyStore verifyStore;

  /// docs/VERIFY.md section 3: `verify_url` is `'$_verifyUrlBase${room.gameId}'`.
  final String _verifyUrlBase;

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

    // docs/PROTOCOL.md section 16.4, "Not everyone": a rematch LOBBY (a live
    // `room.rematch`) relaxes "every configured seat filled" into "at least
    // two seats ready", and removes every occupied seat that is not, so
    // `start_game` branches to that path entirely rather than falling
    // through to the ordinary occupancy check below, which would otherwise
    // reject it as NOT_ENOUGH_PLAYERS the moment a single seat had not yet
    // accepted.
    if (room.rematch != null) {
      return _startRematchFromHost(room, room.rematch!);
    }

    if (room.seats.length != room.players) {
      return StartFailure(ProtocolError.notEnoughPlayers);
    }

    return _beginGame(room);
  }

  /// `docs/PROTOCOL.md` section 16.4, "Not everyone": the host's own
  /// `start_game` in a rematch LOBBY that has not auto-started. Removes
  /// every occupied seat that is not ready, re-seats what is left onto the
  /// canonical set for that count, and then runs the same mechanics an
  /// ordinary `start_game` would. `startGame` has already checked that the
  /// caller is the host and the room is in LOBBY; this method does not
  /// re-check either.
  StartResult _startRematchFromHost(Room room, Rematch current) {
    // docs/PROTOCOL.md section 16.9 rule 2: the host's own `start_game`
    // counts as its acceptance if it had not already sent one. Folded in
    // here, before the ready count is checked and before the removal loop
    // below ever runs, with no broadcast and no `seq` step of its own --
    // `room.rematch` itself is not touched, since nothing downstream reads
    // it again before `_beginGame` sets it back to null a few lines from
    // here. The host is therefore never a candidate for removal below, and
    // the host-handover fallback the first version of this method needed
    // for a non-ready host removing itself no longer applies.
    final List<int> effectiveReady = current.ready.contains(room.hostSeat)
        ? current.ready
        : (List<int>.of(current.ready)
          ..add(room.hostSeat)
          ..sort());

    if (effectiveReady.length < 2) {
      return StartFailure(ProtocolError.notEnoughPlayers);
    }

    final Seat hostSeatBefore =
        room.seats.firstWhere((Seat s) => s.seat == room.hostSeat);

    // room.seats is already ascending by seat index, so `keep` and the
    // removals below both come out in ascending order too, exactly what
    // section 16.4 asks for ("ascending seat order, seq +1 each").
    final List<Seat> keep = <Seat>[];
    final List<RemovedSeat> removedSeats = <RemovedSeat>[];
    for (final Seat s in room.seats) {
      if (effectiveReady.contains(s.seat)) {
        keep.add(s);
      } else {
        room.seq++;
        removedSeats.add(RemovedSeat(seat: s, seq: room.seq));
      }
    }

    if (removedSeats.isEmpty) {
      // docs/PROTOCOL.md section 16.9 rule 3: no seat removed means no
      // re-seat `room` and no `seq` step for it -- the start order runs
      // directly on the roster exactly as it already stood.
      return _beginGame(room);
    }

    final int newPlayers = keep.length;
    final List<int> newIndices = _seatIndicesFor(newPlayers);
    final List<Seat> reseated = <Seat>[
      for (int i = 0; i < keep.length; i++)
        Seat(
          seat: newIndices[i],
          name: keep[i].name,
          seatToken: keep[i].seatToken,
          connected: keep[i].connected,
          clientSeed: keep[i].clientSeed,
          seedOrigin: keep[i].seedOrigin,
        ),
    ];
    // docs/PROTOCOL.md section 15 rule 1, reused here per section 16.4.
    final List<Seat> movedSeats = <Seat>[
      for (int i = 0; i < keep.length; i++)
        if (keep[i].seat != newIndices[i]) reseated[i],
    ];

    room.players = newPlayers;
    room.seats = reseated;
    // docs/PROTOCOL.md section 16.9 rule 2: the host was folded into
    // effectiveReady above before the removal loop ran, so hostSeatBefore is
    // always still present in `keep` here.
    room.hostSeat = reseated
        .firstWhere((Seat s) => s.seatToken == hostSeatBefore.seatToken)
        .seat;
    // docs/PROTOCOL.md section 16.9 rule 3: at least one seat removed means
    // the re-seat `room` gets its own `seq` step even when no seat number
    // actually changed.
    // docs/PROTOCOL.md section 16.4: "rematch becomes null again in the
    // room and frames the start sends", and the re-seat room is the first
    // of those frames.
    room.rematch = null;
    room.seq++;
    final int reseatSeq = room.seq;
    final Map<String, Object?> reseatRoom =
        buildRoomSnapshot(room, now: _clock.now);

    return _beginGame(
      room,
      removedSeats: removedSeats,
      movedSeats: movedSeats,
      reseatSeq: reseatSeq,
      reseatRoom: reseatRoom,
    );
  }

  /// The mechanics every path that actually starts a game shares: an
  /// ordinary `start_game` with every configured seat filled, the section
  /// 16.4 "Everyone accepted" rematch auto-start, and the section 16.4
  /// "Not everyone" host-forced rematch start once its own removal and
  /// re-seat above has already landed. Assumes every precondition the
  /// caller's own ladder has already enforced: `room.state` is LOBBY and
  /// `room.seats` is exactly the final roster for the game about to start.
  StartOk _beginGame(
    Room room, {
    List<RemovedSeat> removedSeats = const <RemovedSeat>[],
    List<Seat> movedSeats = const <Seat>[],
    int? reseatSeq,
    Map<String, Object?>? reseatRoom,
  }) {
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
    // docs/PROTOCOL.md section 16.4: "rematch becomes null again in the
    // room and frames the start sends" -- true of every path through here,
    // and a no-op for the ordinary, non-rematch start_game, where this is
    // already null.
    room.rematch = null;
    // docs/PROTOCOL.md section 6: a segment starts, and the full
    // rules.turnSeconds is restored, when a seat's turn begins -- the
    // opening seat's turn begins here, at start_game, along with every
    // other one this call fixes.
    _restartSegment(room);
    room.seq++;
    final int gameStartedSeq = room.seq;
    // docs/PROTOCOL.md section 13.1: a standalone `turn` frame always
    // follows `game_started`, carrying its own `seq` one greater than
    // `game_started`'s, and the opening segment's `deadline_ms` -- what is
    // left of the segment `_restartSegment` just started above, not a
    // second restart of it.
    room.seq++;
    final int turnSeq = room.seq;
    final int nextDeadlineMs = _remainingSegmentMs(room);
    return StartOk(
      room: room,
      serverSeeded: serverSeeded,
      gameStartedSeq: gameStartedSeq,
      turnSeq: turnSeq,
      nextDeadlineMs: nextDeadlineMs,
      removedSeats: removedSeats,
      movedSeats: movedSeats,
      reseatSeq: reseatSeq,
      reseatRoom: reseatRoom,
    );
  }

  /// `rematch`, `docs/PROTOCOL.md` section 16. The ladder here is section
  /// 16.1's own, with room existence and seat authorisation checked first --
  /// the same room-exists / seat-authorised / phase-correct order every
  /// other method in this file uses, and the one section 16.1's table itself
  /// does not fully spell out (it never names the code for "the socket's
  /// stored seat token no longer matches a seat in this room", a state only
  /// reachable here through the section 16.4 host-forced removal below).
  RematchResult rematch({required String code, required String seatToken}) {
    final Room? room = _rooms[code];
    if (room == null) {
      return RematchFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return RematchFailure(ProtocolError.badSeatToken);
    }
    if (room.state == RoomState.playing) {
      return RematchFailure(ProtocolError.wrongPhase);
    }
    if (room.state == RoomState.lobby && room.rematch == null) {
      return RematchFailure(ProtocolError.wrongPhase);
    }

    if (room.state == RoomState.finished) {
      _openRematchLobby(room, seat);
      room.seq++;
      return RematchOk(room: room, changed: true);
    }

    // room.state == RoomState.lobby && room.rematch != null: an accept.
    final Rematch current = room.rematch!;
    if (current.ready.contains(seat.seat)) {
      // docs/PROTOCOL.md section 16.3: a double tap changes nothing.
      return RematchOk(room: room, changed: false);
    }
    final List<int> ready = List<int>.of(current.ready)
      ..add(seat.seat)
      ..sort();
    room.rematch = Rematch(by: current.by, ready: ready);
    room.seq++;

    // docs/PROTOCOL.md section 16.4, as amended, and section 16.9 rule 4:
    // the auto-start set is the seats occupied right now, read fresh off
    // `room.seats` at the instant this accept landed, not a set fixed back
    // when the rematch LOBBY first opened -- a seat that has since left can
    // never go on blocking a start, and a seat that joined since is waited
    // for like any other.
    final List<int> occupied = room.seats.map((Seat s) => s.seat).toList();
    final bool everyoneReady = occupied.every(ready.contains);
    final bool atLeastTwo = occupied.length >= 2;
    final bool everyoneConnected = room.seats.every((Seat s) => s.connected);
    final bool autoStart = everyoneReady && atLeastTwo && everyoneConnected;
    // docs/PROTOCOL.md section 16.4, "Everyone accepted": [room] is handed
    // back here exactly as this accept left it, still LOBBY -- starting the
    // game is the caller's job, through [startRematchAuto], once it has
    // already published this `room` as the frame that records the
    // acceptance. See the long comment on [RematchOk.autoStart].
    return RematchOk(room: room, changed: true, autoStart: autoStart);
  }

  /// `docs/PROTOCOL.md` section 16.4, "Everyone accepted": the exact
  /// mechanics an accepted `start_game` runs, called once the wire layer has
  /// already broadcast the `room` that `rematch` returned with
  /// `RematchOk.autoStart` true. [room] must be that same `Room`, with
  /// nothing else called against this registry in between -- this file is
  /// synchronous throughout, so a caller that does not `await` anything
  /// between the two calls gets exactly that for free.
  StartOk startRematchAuto(Room room) => _beginGame(room);

  /// `docs/PROTOCOL.md` section 16.2: the first `rematch` of a cycle, taking
  /// a FINISHED room back to LOBBY with a fresh chain. Mutates [room] in
  /// place; the caller advances `room.seq` itself once this returns, per the
  /// pattern every other mutating method in this file follows.
  void _openRematchLobby(Room room, Seat requester) {
    room.state = RoomState.lobby;
    room.game = null;
    room.gameId = null;
    room.clientSeeds = null;
    room.rollCount = 0;
    room.rollSeats.clear();
    room.turnSegmentStartedAt = null;
    for (final Seat s in room.seats) {
      s.clientSeed = null;
      s.seedOrigin = null;
    }
    // docs/PROTOCOL.md section 11.3, "never reuse a chain across games":
    // a fresh chain, from a fresh CSPRNG draw, never derived from the chain
    // it replaces.
    room.chainIndex += 1;
    room.chain = DiceChain.build(_drawBytes(_serverSecretBytes));
    room.rematch = Rematch(by: requester.seat, ready: <int>[requester.seat]);
    // docs/PROTOCOL.md section 16.2 item 4: the room's 60-minute total
    // lifetime restarts from this moment.
    room.lifetimeStartedAt = _clock.now;
  }

  /// `roll`, `docs/PROTOCOL.md` section 12.1. The rejection ladder below is
  /// the section's own table, in order, first failure wins: nothing is
  /// touched before a rejection, so a client that retries a rejected roll
  /// gets the `k` it would have had.
  RollResult roll({required String code, required String seatToken}) {
    final Room? room = _rooms[code];
    if (room == null) {
      return RollFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return RollFailure(ProtocolError.badSeatToken);
    }
    if (room.state == RoomState.finished) {
      return RollFailure(ProtocolError.gameOver);
    }
    if (room.state == RoomState.lobby) {
      return RollFailure(ProtocolError.wrongPhase);
    }
    final engine.GameState game = room.game!;
    if (seat.seat != game.currentSeat) {
      return RollFailure(ProtocolError.notYourTurn);
    }
    if (game.phase != engine.GamePhase.awaitRoll) {
      return RollFailure(ProtocolError.wrongPhase);
    }

    // Section 12.1's own rule, and the one thing that must be impossible:
    // "k advances and chain.reveal(k) is read on exactly one code path, the
    // one that has already passed every rejection above." Everything from
    // here on always returns a success result carrying the frame.
    final int k = room.rollCount + 1;
    if (k > room.chain.chainLength) {
      // The N = 4096 chain rollover is out of scope for this order. A game
      // that reaches this point must not silently wrap (chain.reveal would
      // alias an earlier, already-published link) and must not throw an
      // unhandled RangeError out of chain.reveal either. Refuse cleanly:
      // the counter, the chain and the engine are all left untouched, and
      // the caller logs this as docs/PROTOCOL.md section 7 requires for
      // INTERNAL, with the room code and the sequence number.
      return RollFailure(ProtocolError.internal);
    }
    final String reveal = room.chain.reveal(k);
    final int value = drawDie(reveal, room.gameId!, room.clientSeeds!, k, 0);

    final engine.ApplyResult applied =
        engine.apply(game, engine.RollIntention(seat.seat, value));
    if (applied is engine.Rejected) {
      // Unreachable given the ladder above already matches the engine's own
      // ordering for this intention, but the engine's contract is "never
      // throws, every refusal is a Rejected" and this call site honours
      // that rather than assuming: nothing above has touched room state, so
      // this, too, advances nothing.
      return RollFailure(_mapEngineError(applied.error));
    }
    final engine.Applied appliedOk = applied as engine.Applied;
    room.game = appliedOk.state;
    room.rollCount = k;
    // docs/VERIFY.md section 1.2: this is the one code path that sets
    // room.rollCount = k, whether a player rolled or the turn timer did on
    // their behalf (expireTurns() reaches here through this same method) --
    // so appending here, and only here, keeps rollSeats.length == rollCount
    // true without a second place either could drift from the other.
    room.rollSeats.add(seat.seat);

    room.seq++;
    final int rolledSeq = room.seq;

    final bool turnEnded =
        appliedOk.events.whereType<engine.TurnEnded>().isNotEmpty;

    int rolledDeadlineMs;
    int? turnPassedSeq;
    int? turnSeq;
    int? nextDeadlineMs;

    if (!turnEnded) {
      // The roll leaves a legal move pending: the segment restarts now.
      rolledDeadlineMs = _restartSegment(room);
    } else {
      // The turn is about to pass. This rolled frame reports what was left
      // of the segment that was already running; that segment does not
      // restart until the turn frame for the next seat, below -- a moved
      // that ends a turn does not restart it either, by the same rule, and
      // this is a roll's analogue of that.
      rolledDeadlineMs = _remainingSegmentMs(room);
      room.seq++;
      turnPassedSeq = room.seq;
      room.seq++;
      turnSeq = room.seq;
      nextDeadlineMs = _restartSegment(room);
    }

    return RollOk(
      room: room,
      events: appliedOk.events,
      k: k,
      reveal: reveal,
      rolledSeq: rolledSeq,
      rolledDeadlineMs: rolledDeadlineMs,
      turnPassedSeq: turnPassedSeq,
      turnSeq: turnSeq,
      nextDeadlineMs: nextDeadlineMs,
    );
  }

  /// `move`, `docs/PROTOCOL.md` section 12.2. Same ladder shape as [roll],
  /// with `WRONG_PHASE` when the turn is awaiting a roll rather than a move.
  /// [token] has already passed the wire layer's `BAD_FIELD` check (absent,
  /// not an integer, or outside `0..3`) by the time it reaches here -- that
  /// is why this method's own signature takes a plain `int` -- but the range
  /// is re-checked below anyway, the same defence in depth every other
  /// registry call applies to what its own caller already validated.
  MoveResult move({
    required String code,
    required String seatToken,
    required int token,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return MoveFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return MoveFailure(ProtocolError.badSeatToken);
    }
    if (room.state == RoomState.finished) {
      return MoveFailure(ProtocolError.gameOver);
    }
    if (room.state == RoomState.lobby) {
      return MoveFailure(ProtocolError.wrongPhase);
    }
    final engine.GameState game = room.game!;
    if (seat.seat != game.currentSeat) {
      return MoveFailure(ProtocolError.notYourTurn);
    }
    if (game.phase != engine.GamePhase.awaitMove) {
      return MoveFailure(ProtocolError.wrongPhase);
    }
    if (token < 0 || token > 3) {
      return MoveFailure(ProtocolError.badField);
    }

    final engine.ApplyResult applied =
        engine.apply(game, engine.MoveIntention(seat.seat, token));
    if (applied is engine.Rejected) {
      return MoveFailure(_mapEngineError(applied.error));
    }
    final engine.Applied appliedOk = applied as engine.Applied;
    room.game = appliedOk.state;

    room.seq++;
    final int movedSeq = room.seq;

    final bool won = appliedOk.events.whereType<engine.GameWon>().isNotEmpty;

    int? gameOverSeq;
    String? verifyUrl;
    int? turnSeq;
    int? nextDeadlineMs;

    if (won) {
      room.state = RoomState.finished;
      // docs/VERIFY.md section 1: the record is written the moment the game
      // is won, before this method returns the MoveOk that carries
      // verify_url below -- so a client that taps Verify the instant
      // game_over arrives finds the record already there. A failed save
      // (the store throws, or a record for this game_id somehow already
      // exists) must never cost a player a finished game: it is logged to
      // stderr, one line, and play continues exactly as if it had
      // succeeded.
      final int winnerSeat =
          appliedOk.events.whereType<engine.GameWon>().first.seat;
      // buildVerifyRecord and jsonEncode run inside this same try: a throw
      // from either (a rollSeats index, a null gameId) is exactly as
      // recoverable here as a throw from verifyStore.save itself, and must
      // never escape move() and cost the players their finished game.
      try {
        final String recordJson = jsonEncode(
          buildVerifyRecord(
            room,
            winner: winnerSeat,
            finishedAt: _clock.now,
          ),
        );
        final bool saved = verifyStore.save(room.gameId!, recordJson);
        if (!saved) {
          stderr.writeln(
            'verify_record_not_saved game_id=${room.gameId} reason=exists',
          );
        }
      } catch (error) {
        stderr.writeln(
          'verify_record_not_saved game_id=${room.gameId} reason=$error',
        );
      }
      room.seq++;
      gameOverSeq = room.seq;
      verifyUrl = '$_verifyUrlBase${room.gameId}';
    } else {
      // Rule 12 of docs/RULES.md, via the engine's own ExtraRoll/TurnBegan
      // events: either the same seat rolls again or the next seat's turn
      // begins. Section 12.2 sends a `turn` frame either way, and section 6
      // restarts the segment either way.
      room.seq++;
      turnSeq = room.seq;
      nextDeadlineMs = _restartSegment(room);
    }

    return MoveOk(
      room: room,
      events: appliedOk.events,
      movedSeq: movedSeq,
      gameOverSeq: gameOverSeq,
      verifyUrl: verifyUrl,
      turnSeq: turnSeq,
      nextDeadlineMs: nextDeadlineMs,
    );
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
    // docs/PROTOCOL.md section 16.4: "set_players in a rematch LOBBY is
    // WRONG_PHASE: the ready list decides the count." Checked ahead of
    // NOT_HOST, the same precedence `connection.dart`'s own pre-check for
    // this message gives it, since this is "the wrong operation entirely"
    // rather than "the right operation from the wrong seat".
    if (room.rematch != null) {
      return SetPlayersFailure(ProtocolError.wrongPhase);
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
    // docs/PROTOCOL.md section 15 rule 1: compared index by index against
    // `ordered`, which `reseated` was built from one-for-one, so `ordered[i]`
    // is always the same occupant as `reseated[i]`, just at its old index.
    final List<Seat> movedSeats = <Seat>[
      for (int i = 0; i < ordered.length; i++)
        if (ordered[i].seat != newIndices[i]) reseated[i],
    ];

    room.players = players;
    room.seats = reseated;
    room.hostSeat =
        reseated.firstWhere((Seat s) => s.seatToken == seatToken).seat;
    room.seq++;

    return SetPlayersOk(room: room, movedSeats: movedSeats);
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
      // docs/PROTOCOL.md section 16.3: "A seat that does not want to play
      // again sends leave_room, which in LOBBY frees the seat as it always
      // has." A departing seat that had already accepted the rematch must
      // not go on counting as ready once it is gone -- `by` is kept exactly
      // as it was (section 16.6: sticky even once that seat has left).
      final Rematch? current = room.rematch;
      if (current != null && current.ready.contains(seat.seat)) {
        room.rematch = Rematch(
          by: current.by,
          ready: current.ready.where((int s) => s != seat.seat).toList(),
        );
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
      if (now.difference(room.lifetimeStartedAt) >= _anyRoomTimeout) {
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
    // docs/VERIFY.md section 3: retention is enforced here, on the same
    // housekeeping cadence as everything else this method already sweeps,
    // rather than on a timer of its own.
    verifyStore.purgeOlderThan(now.subtract(verifyRetention));
    return toRemove.length;
  }

  /// `docs/RULES.md` section 3.3: a seat that lets its segment run out does
  /// not hold the table. Swept on a fixed cadence by the wire layer, never
  /// by a client frame, and never by anything that reads room state -- the
  /// only side effect of calling this is the turns it plays.
  ///
  /// Rule 15 for a segment that expires in `await_move`: exactly one legal
  /// move is played; where several exist the ascending token index decides;
  /// where none exist the turn already passed under rule 7 and no segment
  /// was ever armed, so there is nothing here to act on.
  ///
  /// Rule 16a for a segment that expires in `await_roll` -- the case rule 14
  /// never named, and the one that actually hung a table, because a seat
  /// that drops before rolling owes an action no other seat can take. The
  /// server rolls for it, through the same [roll] this file already exposes,
  /// so the dice chain advances by exactly one link on exactly one code path
  /// and a timer-drawn die is verifiable the same way every other die is.
  ///
  /// Deliberately not filtered on `seat.connected`: rules 14 and 15 put the
  /// timer on the segment, not on the socket, and a connected player who
  /// walks away hangs the table exactly as hard as a disconnected one.
  List<ExpiredTurn> expireTurns() {
    final List<ExpiredTurn> acted = <ExpiredTurn>[];
    for (final Room room in _rooms.values.toList(growable: false)) {
      if (room.state != RoomState.playing) {
        continue;
      }
      final engine.GameState? game = room.game;
      if (game == null || game.phase == engine.GamePhase.finished) {
        continue;
      }
      if (_remainingSegmentMs(room) > 0) {
        continue;
      }
      // From here on this room's segment has expired and this sweep owes
      // it an action: either an ExpiredTurn is appended below, or one of
      // the branches below calls _declineExpiredSegment, which restarts
      // the segment and logs why, before the loop moves to the next room.
      // Leaving neither behind is exactly the bug this method used to
      // have -- the same declined room re-entering this sweep, and doing
      // nothing, once a second for as long as the room lives.
      final String phase = _turnExpiryPhaseToken(game.phase);
      final Seat? seat = _seatAt(room, game.currentSeat);
      if (seat == null) {
        _declineExpiredSegment(
          room: room,
          seatIndex: game.currentSeat,
          phase: phase,
          reason: 'no_seat',
        );
        continue;
      }
      if (game.phase == engine.GamePhase.awaitRoll) {
        final RollResult result =
            roll(code: room.code, seatToken: seat.seatToken);
        if (result is RollOk) {
          acted.add(
            ExpiredTurn(code: room.code, seat: seat.seat, roll: result),
          );
        } else if (result is RollFailure) {
          _declineExpiredSegment(
            room: room,
            seatIndex: seat.seat,
            phase: phase,
            reason: 'roll_failed',
            error: result.error,
          );
        }
      } else if (game.phase == engine.GamePhase.awaitMove) {
        final List<int> legal = List<int>.of(engine.legalTokens(game))..sort();
        if (legal.isEmpty) {
          _declineExpiredSegment(
            room: room,
            seatIndex: seat.seat,
            phase: phase,
            reason: 'no_legal_tokens',
          );
          continue;
        }
        final MoveResult result = move(
          code: room.code,
          seatToken: seat.seatToken,
          token: legal.first,
        );
        if (result is MoveOk) {
          acted.add(
            ExpiredTurn(code: room.code, seat: seat.seat, move: result),
          );
        } else if (result is MoveFailure) {
          _declineExpiredSegment(
            room: room,
            seatIndex: seat.seat,
            phase: phase,
            reason: 'move_failed',
            error: result.error,
          );
        }
      } else {
        // Not reachable with today's engine.GamePhase (only awaitRoll,
        // awaitMove and finished exist, and finished was filtered above),
        // but expireTurns must stay total if that enum ever grows a phase
        // this method has not been taught to act on.
        _declineExpiredSegment(
          room: room,
          seatIndex: seat.seat,
          phase: phase,
          reason: 'unhandled_phase',
        );
      }
    }
    return acted;
  }

  /// The lower-snake-case phase token the frozen turn-expiry-skipped log
  /// line uses, per `docs/PROTOCOL.md` and order 124 -- never the Dart
  /// enum's own `toString()`.
  String _turnExpiryPhaseToken(engine.GamePhase phase) {
    switch (phase) {
      case engine.GamePhase.awaitRoll:
        return 'await_roll';
      case engine.GamePhase.awaitMove:
        return 'await_move';
      case engine.GamePhase.finished:
        return 'other';
    }
  }

  /// Called from every path through [expireTurns] that has passed the
  /// `_remainingSegmentMs(room) > 0` check and is not adding an
  /// [ExpiredTurn] for [room] to the result. Restarts the segment -- so
  /// this seat gets a fresh full turn budget rather than the sweep
  /// hammering the same expired room again next tick -- and prints exactly
  /// one line in the frozen `turn-expiry skipped` format, with `error=`
  /// appended only when [error] is given.
  void _declineExpiredSegment({
    required Room room,
    required int seatIndex,
    required String phase,
    required String reason,
    ProtocolError? error,
  }) {
    _restartSegment(room);
    final String errorSuffix = error == null ? '' : ' error=${error.name}';
    // ignore: avoid_print
    print('turn-expiry skipped room=${room.code} seat=$seatIndex '
        'phase=$phase reason=$reason$errorSuffix');
  }

  /// The seated player at engine seat index [index], or null when that index
  /// holds nobody. Distinct from [_findSeat], which looks a seat up by its
  /// token; the timer has no token to start from, only the seat the engine
  /// says currently owes an action.
  Seat? _seatAt(Room room, int index) {
    for (final Seat seat in room.seats) {
      if (seat.seat == index) {
        return seat;
      }
    }
    return null;
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

  /// `docs/PROTOCOL.md` section 6: restarts the current turn segment on the
  /// registry's own injected clock and returns the freshly restored
  /// `deadline_ms` (always `rules.turnSeconds * 1000`, since the elapsed
  /// time from a segment that starts this instant is zero).
  int _restartSegment(Room room) {
    room.turnSegmentStartedAt = _clock.now;
    return room.rules.turnSeconds * 1000;
  }

  /// `docs/PROTOCOL.md` section 6: `max(0, turn_seconds * 1000 - elapsed)`
  /// for the segment already running, without restarting it. Zero if no
  /// segment has ever started, which should not happen once a game exists
  /// but is not something this method should throw over.
  int _remainingSegmentMs(Room room) {
    final DateTime? startedAt = room.turnSegmentStartedAt;
    if (startedAt == null) {
      return 0;
    }
    final int budgetMs = room.rules.turnSeconds * 1000;
    final int elapsedMs = _clock.now.difference(startedAt).inMilliseconds;
    final int remaining = budgetMs - elapsedMs;
    return remaining > 0 ? remaining : 0;
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

/// Maps an `engine.EngineError` onto the one `ProtocolError` `docs/PROTOCOL.md`
/// section 7 answers with for it. Only reachable as defence in depth: every
/// call site above already runs the identical ladder before ever calling
/// `engine.apply`, so a live `Rejected` here means that duplication drifted,
/// not that a player found a legitimate way to trigger it.
ProtocolError _mapEngineError(engine.EngineError error) {
  switch (error) {
    case engine.EngineError.notYourTurn:
      return ProtocolError.notYourTurn;
    case engine.EngineError.wrongPhase:
      return ProtocolError.wrongPhase;
    case engine.EngineError.illegalMove:
      return ProtocolError.illegalMove;
    case engine.EngineError.gameFinished:
      return ProtocolError.gameOver;
    case engine.EngineError.seatNotInPlay:
      return ProtocolError.badSeatToken;
    case engine.EngineError.noSuchToken:
      // docs/PROTOCOL.md section 12.2: a token outside 0..3 is BAD_FIELD,
      // the same code the wire layer's own pre-check already answers for
      // it, before rule legality is ever considered.
      return ProtocolError.badField;
    case engine.EngineError.badFace:
      // The server is the only source of a roll's face and always draws one
      // in 1..6; a badFace rejection here means that stopped being true.
      return ProtocolError.internal;
  }
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

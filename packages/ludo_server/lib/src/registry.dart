// docs/PROTOCOL.md sections 2, 3 and 7; docs/RULES.md section 2.
//
// The registry is the only thing in this package that touches room state.
// Every method here is a pure function of (its own maps, the injected
// clock, the injected random source, and its arguments). Nothing here reads
// a wall clock, opens a socket or parses JSON; those are order 007's job.

import 'dart:convert' show jsonEncode, utf8;
import 'dart:io' show stderr;
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fair_dice/fair_dice.dart' show DiceChain, drawDie, hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;

import 'clock.dart';
import 'computer_seat.dart';
import 'envelope.dart' show logSafeError;
import 'grace.dart';
import 'link_id.dart';
import 'room.dart';
import 'room_code.dart';
import 'ruleset.dart';
import 'snapshot.dart'
    show TurnQueueFields, buildRollPayload, queuedBankedSixes, turnQueueFields;
import 'seat_token.dart';
import 'snapshot.dart' show buildRoomSnapshot;
import 'strike_store.dart';
import 'verify_record.dart';
import 'verify_store.dart';
import 'waiting_line.dart';

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

  /// Section 27: the app's build is below the server's minimum. Never a
  /// reply to a frame; sent once, unsolicited, as a socket is refused.
  updateRequired,

  /// Section 28 rule 4: a `kick` named a playing seat whose socket is up.
  /// Section 33 item 8 retired it: no path sends it any more. Kept so the
  /// table of codes stays one to one with what older builds may read.
  notAbsent,

  /// Section 31 item 3: a room already holds 3 open knocks.
  tooManyKnocks,

  /// Section 31 item 4: `answer_knock` named an unknown or closed knock.
  noSuchKnock,

  /// Section 31 item 4: this knocker was refused or timed out in this room.
  knockRefused,

  /// Section 31 item 7: this seat was kicked from this room.
  kicked,

  /// Section 32 item 9: a typed code from a banned device or a blocked IP.
  codeBanned,

  /// Section 33 item 3: `find_game` from a socket that holds a seat.
  alreadySeated,
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

/// Section 31 item 3: the typed code of a room with guest approval on did not
/// seat the caller; it opened [knock], announced by [opened].
class JoinKnocked extends JoinResult {
  JoinKnocked({required this.room, required this.knock, required this.opened});
  final Room room;
  final Knock knock;
  final KnockEvent opened;
}

/// One thing a knock did, with its `seq` already fixed and the snapshots the
/// frames need already built, so a later event of the same call cannot change
/// what an earlier one says. Section 31 items 3, 4 and 5.
sealed class KnockEvent {
  KnockEvent({
    required this.room,
    required this.knock,
    required this.seq,
    required this.hostSeatToken,
    required this.others,
  });

  final Room room;
  final Knock knock;
  final int seq;

  /// The seat token of the room's host at that moment, null when none.
  final String? hostSeatToken;

  /// The `room` snapshot every seated socket but the host is owed at [seq]
  /// (`knocks` empty), because they take no `knock` or `knock_closed`.
  final Map<String, Object?> others;
}

class KnockOpened extends KnockEvent {
  KnockOpened({
    required super.room,
    required super.knock,
    required super.seq,
    required super.hostSeatToken,
    required super.others,
  });
}

class KnockClosed extends KnockEvent {
  KnockClosed({
    required super.room,
    required super.knock,
    required super.seq,
    required super.hostSeatToken,
    required super.others,
    required this.outcome,
    this.ban,
  });

  /// Section 32 item 12: the ban this close's strike fired, for the knocker's
  /// `knock_failed`. Null when none fired.
  final BanInfo? ban;

  /// `accepted`, `rejected`, `timeout`, `full`, `withdrawn` or `switched_off`.
  final String outcome;
}

/// The seating that follows an accepted knock: [seat] took the lowest free
/// seat at [seq]. [snapshot] is the `room` the new seat is sent.
class KnockSeated extends KnockEvent {
  KnockSeated({
    required super.room,
    required super.knock,
    required super.seq,
    required super.hostSeatToken,
    required super.others,
    required this.seat,
    required this.snapshot,
  });
  final Seat seat;
  final Map<String, Object?> snapshot;
}

sealed class AnswerKnockResult {}

class AnswerKnockOk extends AnswerKnockResult {
  AnswerKnockOk({required this.room, required this.events});
  final Room room;
  final List<KnockEvent> events;
}

class AnswerKnockFailure extends AnswerKnockResult {
  AnswerKnockFailure(this.error);
  final ProtocolError error;
}

sealed class SetApprovalResult {}

/// Section 31 item 5. [seq] is the toggle's own step; [hostSnapshot] and
/// [othersSnapshot] are the `room` it is answered and broadcast with, built
/// before the knocks it may have settled ([events]) changed the room again.
class SetApprovalOk extends SetApprovalResult {
  SetApprovalOk({
    required this.room,
    required this.seq,
    required this.hostSnapshot,
    required this.othersSnapshot,
    required this.events,
  });
  final Room room;
  final int seq;
  final Map<String, Object?> hostSnapshot;
  final Map<String, Object?> othersSnapshot;
  final List<KnockEvent> events;
}

class SetApprovalFailure extends SetApprovalResult {
  SetApprovalFailure(this.error);
  final ProtocolError error;
}

sealed class KickLobbyResult {}

/// Section 31 item 6. [seat] is the seat as it stood before removal.
class KickLobbyOk extends KickLobbyResult {
  KickLobbyOk({required this.room, required this.seat, this.ban});
  final Room room;
  final Seat seat;

  /// Section 32 item 12: the ban this kick's strike fired, for the `kicked`
  /// frame. Null when none fired.
  final BanInfo? ban;
}

class KickLobbyFailure extends KickLobbyResult {
  KickLobbyFailure(this.error);
  final ProtocolError error;
}

/// One thing a pass over the waiting line did, section 33 item 4, with its
/// `seq` fixed and the `room` the seated socket is owed already built.
sealed class LineEvent {
  LineEvent({
    required this.ticket,
    required this.room,
    required this.seat,
    required this.seq,
    required this.snapshot,
  });

  /// The ticket that was seated; already out of the line.
  final Ticket ticket;
  final Room room;
  final Seat seat;
  final int seq;
  final Map<String, Object?> snapshot;
}

/// [ticket] took the lowest free seat of a matchable room, `via: "public"`.
class LineSeated extends LineEvent {
  LineSeated({
    required super.ticket,
    required super.room,
    required super.seat,
    required super.seq,
    required super.snapshot,
  });
}

/// "Two strangers and no room": a room was created for the head ticket,
/// which is its host.
class LineRoomCreated extends LineEvent {
  LineRoomCreated({
    required super.ticket,
    required super.room,
    required super.seat,
    required super.seq,
    required super.snapshot,
  });
}

sealed class ResumeResult {}

class ResumeOk extends ResumeResult {
  ResumeOk({
    required this.room,
    required this.seat,
    required this.reconnected,
    this.presenceSeq,
    this.turnSeq,
    this.turnDeadlineMs,
    this.turnGraceMs,
  });
  final Room room;
  final Seat seat;

  /// True when this call flipped the seat from disconnected to connected.
  /// False for a takeover of a seat that was already connected -- the wire
  /// layer uses this to decide whether a `presence` push actually describes
  /// a change, since the registry only advances `seq` on a real flip.
  final bool reconnected;

  /// The `seq` the `presence` push carries: `room.seq` at the instant the
  /// flip landed, before the `turn` below took the next one. Set exactly
  /// when [reconnected] is.
  final int? presenceSeq;

  /// `docs/PROTOCOL.md` section 26 rule 5. Set, together with
  /// [turnDeadlineMs], only when this resume reconnected an away seat that
  /// is on turn with an away-length segment running: the segment was
  /// restarted at the full `rules.turnSeconds * 1000` and the other sockets
  /// are owed a `turn` frame for the seat at this `seq`, right after the
  /// `presence`. `room.seq` equals it, so the resumer's own `room` answer,
  /// built afterwards, carries it too.
  final int? turnSeq;

  /// The restarted segment's `deadline_ms` for that `turn` frame.
  final int? turnDeadlineMs;

  /// Section 29 rule 7: the grace that was still running when the seat came
  /// back, for that `turn` frame's `grace_ms`. Null when none was.
  final int? turnGraceMs;
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

  /// Section 31 item 11 (e): the knocks still open when the game started,
  /// closed `full` after the start's own steps, so their `seq` values follow
  /// the `turn`. Set by the registry; empty when none was open.
  List<KnockEvent> knockEvents = const <KnockEvent>[];
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
    required this.payload,
    required this.after,
    required this.rolledSeq,
    required this.rolledDeadlineMs,
    this.release = false,
    this.turnPassedSeq,
    this.turnSeq,
    this.nextDeadlineMs,
    this.nextGraceMs,
  });

  final Room room;
  final List<engine.GameEvent> events;

  /// Section 28 rule 2 and section 30 rule 2: this roll granted a yard
  /// release (the `rolled` frame carries `release: true`), whether it was
  /// taken at once, offered, or lapsed.
  final bool release;

  /// 1-based within this game. `chain.reveal(k)` was read for exactly this
  /// value and no other.
  final int k;

  /// `s[k]`, 64 lowercase hex characters.
  final String reveal;

  /// The roll's payload from the one draw ([RoomRegistry]'s `_drawRoll`):
  /// the `rolled` frame minus `seq`, `reveal`, `deadline_ms` and `by`, the
  /// same map a `pre` for this roll was (`docs/PROTOCOL.md` section 35).
  final Map<String, Object?> payload;

  /// The engine state this roll left. Frames are built from it and never
  /// from `room.game`, which a retire that took this roll first has already
  /// moved on.
  final engine.GameState after;

  final int rolledSeq;

  /// The `rolled` frame's own `deadline_ms`. When the roll leaves a legal
  /// move pending this is a freshly restarted segment (the full
  /// `rules.turnSeconds`); when the roll ends the turn it is what was left
  /// of the segment that was already running, because that segment does not
  /// restart until the `turn` frame below.
  final int rolledDeadlineMs;

  /// Set only when the roll ended the turn: the `seq` for `turn_passed`,
  /// which precedes the `turn` frame in that case. `docs/PROTOCOL.md`
  /// section 21.3 rule 4: a queued 6 that owes another roll also sends a
  /// `turn` (below) but never a `turn_passed` -- the turn has not passed,
  /// the same seat still holds it -- so this stays null for that case even
  /// though [turnSeq] is set.
  final int? turnPassedSeq;

  /// Set whenever a `turn` frame follows the `rolled`: the turn ended (next
  /// seat), or the roll queued a 6 that owes another roll (same seat,
  /// `await_roll`, section 21.3 rule 4). Null exactly when the roll left a
  /// move pending and nothing else needs announcing beyond the `rolled`
  /// frame itself.
  final int? turnSeq;

  /// The freshly restarted segment's `deadline_ms` for the `turn` frame,
  /// set together with [turnSeq].
  final int? nextDeadlineMs;

  /// Section 29: the `grace_ms` of that `turn` frame, set only when the turn
  /// passed in a 2026-11 room.
  final int? nextGraceMs;
}

class RollFailure extends RollResult {
  RollFailure(this.error);
  final ProtocolError error;
}

sealed class DeclineResult {}

/// `decline_release`, `docs/PROTOCOL.md` section 30 rule 4: everything the
/// wire layer needs for `release_declined`, `turn_passed` and the `turn` of
/// the next seat.
class DeclineOk extends DeclineResult {
  DeclineOk({
    required this.room,
    required this.events,
    required this.declinedSeq,
    required this.turnPassedSeq,
    required this.turnSeq,
    required this.nextDeadlineMs,
    this.nextGraceMs,
  });

  final Room room;
  final List<engine.GameEvent> events;
  final int declinedSeq;
  final int turnPassedSeq;
  final int turnSeq;
  final int nextDeadlineMs;
  final int? nextGraceMs;
}

class DeclineFailure extends DeclineResult {
  DeclineFailure(this.error);
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
    required this.face,
    this.release = false,
    this.sixesGrantedSeq,
    this.seatFinishedSeq,
    this.gameOverSeq,
    this.verifyUrl,
    this.freed = const <FreedSeat>[],
    this.turnPassedSeq,
    this.turnSeq,
    this.nextDeadlineMs,
    this.nextGraceMs,
  });

  final Room room;
  final List<engine.GameEvent> events;
  final int movedSeq;

  /// Section 30 rule 3: set when the move took a shared release that granted
  /// at least one seat a six; the `seq` of `sixes_granted`, which follows
  /// `moved`.
  final int? sixesGrantedSeq;

  /// `docs/PROTOCOL.md` section 21.1: the face this move actually spent --
  /// the caller's own `face`, when it gave one, or `engine.defaultFace` of
  /// the state the move was applied against, when it did not. The engine's
  /// own `Moved` event carries no face (it predates the queue), so this is
  /// fixed here, at the one call site that knows which of the two the
  /// engine used, rather than guessed from `from`/`to` -- a token leaving
  /// the yard moves to progress `0` however large the spent face, so a
  /// `to - from` reconstruction is wrong for exactly that move.
  ///
  /// Null exactly when [release] is true: a yard release spends no face
  /// (`docs/PROTOCOL.md` section 28 rule 2), so there is none to report.
  final int? face;

  /// Section 28 rule 2: this move spent a yard release (rule 11r), not a
  /// face of the queue.
  final bool release;

  /// Section 28 rule 3: set only when this move brought a seat's fourth
  /// token home and the game goes on. `seat_finished` takes this `seq`,
  /// after the `moved` and before the `turn`.
  final int? seatFinishedSeq;

  /// Set together, and only, when this move won the game.
  final int? gameOverSeq;
  final String? verifyUrl;

  /// Section 28 rule 4 "At the end": the retired seats this win freed, in
  /// retirement order, each with the `seq` of its own `player_left`, which
  /// follows `game_over`. Empty unless this move won a 2026-11 game that had
  /// retired seats.
  final List<FreedSeat> freed;

  /// Set only when the move left faces queued that no token could spend:
  /// `docs/PROTOCOL.md` section 21.3 rule 4, "move, only dead faces left".
  /// The `turn_passed` this carries precedes the `turn` frame below.
  final int? turnPassedSeq;

  /// Set together, and only, when the game continues: the turn passed, the
  /// same seat was granted an extra roll, or the same seat keeps spending
  /// faces still in the queue. Section 12.2 and section 21.3 rule 4 both
  /// send a `turn` frame for the seat that now holds the turn, whichever of
  /// the three it is.
  final int? turnSeq;
  final int? nextDeadlineMs;

  /// Section 29: the `grace_ms` of that `turn` frame, set only when the turn
  /// passed in a 2026-11 room.
  final int? nextGraceMs;
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

/// Section 34 item 4: one action the server took for a computer seat. Carries
/// what the matching client-driven path carries, so the wire layer builds the
/// same frames from it, with no `by` key (section 22 marks the timer, and
/// this is not the timer).
class ComputerStep {
  ComputerStep({
    required this.code,
    required this.seat,
    required this.bot,
    this.roll,
    this.move,
  });

  final String code;

  /// The engine seat the server acted for.
  final int seat;

  /// The character of that seat, 1..6.
  final int bot;

  final RollOk? roll;
  final MoveOk? move;
}

sealed class PlayComputerResult {}

/// `play_computer` accepted. [snapshot] is the `room` of the full LOBBY, taken
/// before any seed is fixed; [seeds] are every seat's `seat_seed`, ascending,
/// each at the `seq` of its own fix; [start] is the game start that follows.
class PlayComputerOk extends PlayComputerResult {
  PlayComputerOk({
    required this.room,
    required this.seat,
    required this.snapshot,
    required this.seeds,
    required this.start,
  });

  final Room room;
  final Seat seat;
  final Map<String, Object?> snapshot;
  final List<SeededSeat> seeds;
  final StartOk start;
}

class PlayComputerFailure extends PlayComputerResult {
  PlayComputerFailure(this.error);
  final ProtocolError error;
}

/// One computer seat taken into a LOBBY: [joinedSeq] is the `seq` of its
/// `player_joined`, [seeded] its server seed and the `seq` of that fix, which
/// follows it at once.
class ComputerJoin {
  ComputerJoin({required this.seat, required this.joinedSeq, this.seeded});

  final Seat seat;
  final int joinedSeq;
  final SeededSeat? seeded;
}

sealed class FillComputerResult {}

/// `fill_computer` accepted: the knocks it closed `full` first, then each
/// computer seat in turn, then the start of the game.
class FillComputerOk extends FillComputerResult {
  FillComputerOk({
    required this.room,
    required this.knockEvents,
    required this.joins,
    required this.start,
  });

  final Room room;
  final List<KnockEvent> knockEvents;
  final List<ComputerJoin> joins;
  final StartOk start;
}

class FillComputerFailure extends FillComputerResult {
  FillComputerFailure(this.error);
  final ProtocolError error;
}

/// Section 34 item 6: a computer seat's acceptance of a rematch, the `room`
/// it produced built at the `seq` the accept took.
class ComputerAccept {
  ComputerAccept({
    required this.seat,
    required this.seq,
    required this.snapshot,
  });

  final Seat seat;
  final int seq;
  final Map<String, Object?> snapshot;
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
  LeaveOk({required this.room, required this.seat, this.retire});
  final Room room;

  /// Section 28 rule 4 "left": set exactly when this `leave_room` retired a
  /// playing seat of a 2026-11 game. The wire layer then publishes the
  /// retirement instead of a `presence`.
  final RetireOk? retire;

  /// The seat that left. In LOBBY and FINISHED it has already been removed
  /// from `room.seats`; in PLAYING it is still there, marked disconnected,
  /// per docs/PROTOCOL.md section 3 and section 18.
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

class _Concluded {
  _Concluded({
    required this.gameOverSeq,
    required this.verifyUrl,
    required this.freed,
  });
  final int gameOverSeq;
  final String verifyUrl;
  final List<FreedSeat> freed;
}

/// One retired seat removed from the room when a 2026-11 game ended,
/// `docs/PROTOCOL.md` section 28 rule 4 "At the end". [seat] is the seat as
/// it stood before removal; [seq] is the `seq` of its `player_left` and
/// [hostSeat] the room's host after it was freed.
class FreedSeat {
  FreedSeat({required this.seat, required this.seq, required this.hostSeat});
  final Seat seat;
  final int seq;
  final int hostSeat;
}

sealed class RetireResult {}

/// A seat retired by the server, `docs/PROTOCOL.md` section 28 rule 4.
/// Carries what the wire layer needs to build `seat_retired` and whatever
/// the engine's events add to it, with every `seq` already fixed, in the
/// order the frames go out: `seat_retired` at [retiredSeq], then either a
/// `turn` at [turnSeq], or a `game_over` at [gameOverSeq] followed by one
/// `player_left` per entry of [freed], or nothing.
class RetireOk extends RetireResult {
  RetireOk({
    required this.room,
    required this.seat,
    required this.reason,
    required this.events,
    required this.after,
    required this.retiredSeq,
    required this.hostSeat,
    this.turnSeq,
    this.nextDeadlineMs,
    this.nextGraceMs,
    this.gameOverSeq,
    this.verifyUrl,
    this.freed = const <FreedSeat>[],
    this.ban,
    this.shownRoll,
  });

  final Room room;

  /// `docs/PROTOCOL.md` section 35 item 3: the retired seat had been sent a
  /// `pre` for the roll it owed, so that roll was taken first, as the turn
  /// timer takes it, before the retirement. Its frames (`rolled` with
  /// `by: "timer"`, then the step's) go out ahead of `seat_retired`. Null
  /// when the seat held no `pre`.
  final RollOk? shownRoll;

  /// Section 33 item 6 and section 32 item 12: the ban the strike of a
  /// PLAYING kick fired, for the kicked socket's `kicked` frame. Null when
  /// none fired, and always for `left` and `absent`.
  final BanInfo? ban;

  /// The seat that was retired. Still in `room.seats` unless [freed] holds it.
  final Seat seat;

  /// `"left"`, `"absent"` or `"kicked"`.
  final String reason;

  /// `Applied.events` of the engine's `RetireIntention`, unmodified.
  final List<engine.GameEvent> events;

  /// The engine state this retirement left. Its frames are built from it and
  /// never from `room.game`, which a later retirement of the same sweep has
  /// already moved on.
  final engine.GameState after;
  final int retiredSeq;

  /// `host_seat` after the retirement, changed or not.
  final int hostSeat;

  /// Set, with [nextDeadlineMs], when the retired seat was to act and the
  /// turn went to the next playing seat.
  final int? turnSeq;
  final int? nextDeadlineMs;

  /// Section 29 rule 7: the `grace_ms` of that `turn` frame (a retire of the
  /// seat on turn gives the next seat a grace), set only in a 2026-11 room.
  final int? nextGraceMs;

  /// Set, with [verifyUrl], when the retirement left one playing seat and
  /// the game ended.
  final int? gameOverSeq;
  final String? verifyUrl;
  final List<FreedSeat> freed;
}

class RetireFailure extends RetireResult {
  RetireFailure(this.error);
  final ProtocolError error;
}

/// `docs/PROTOCOL.md` section 28 rule 4: how long a playing seat's socket
/// must have been down, without a break, before the sweep retires it.
const Duration _absentRetireAfter = Duration(milliseconds: 120000);

/// `docs/PROTOCOL.md` section 26 rule 3: the budget of every segment that
/// starts for an away seat. Fixed, not a rules field, the same in every room.
const int _awaySegmentMs = 10000;

/// `docs/PROTOCOL.md` section 3, as amended by C-451. A LOBBY or PLAYING
/// room with no connected seat for this long is reaped.
const Duration _idleTimeout = Duration(minutes: 10);

/// A FINISHED room is reaped this long after the registry first observes it
/// FINISHED.
const Duration _finishedTimeout = Duration(minutes: 10);

/// A LOBBY is closed this long after `Room.lifetimeStartedAt` (creation, or
/// the last accepted rematch) even while a seat stays connected
/// (`docs/PROTOCOL.md` section 37). A room that is PLAYING or FINISHED is not
/// bound by this; see [_maxRoomLifetime].
const Duration _lobbyLifetime = Duration(minutes: 10);

/// The ceiling for any room that is not a LOBBY, measured from
/// `Room.lifetimeStartedAt`. A game being played is never reaped by the
/// 60-minute clock; this is only the backstop for a game that somehow never
/// ends and never goes idle. Six hours covers a four-seat game with two
/// absent seats, whose turns the timer plays at the deployed 90 seconds
/// (about five hours).
const Duration _maxRoomLifetime = Duration(hours: 6);

/// `docs/PROTOCOL.md` section 32 item 3: a reaped room's code rests this long
/// on the server clock before it can be handed out again.
const Duration _codeRest = Duration(minutes: 10);

/// `docs/PROTOCOL.md` section 31 item 4: a knock unanswered this long closes
/// `timeout`; item 3: a room holds at most this many open knocks.
const Duration _knockLifetime = Duration(milliseconds: 60000);
const int _maxOpenKnocks = 3;

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
    String ruleset = ruleset202610,
    Random? linkRandom,
    StrikeStore? strikeStore,
    Random Function()? computerRandom,
  })  : _clock = clock,
        _computerRandomFactory = computerRandom ?? Random.new,
        strikes = strikeStore ?? StrikeStore(clock: clock),
        _secure = secure,
        _linkRandom = linkRandom ?? Random.secure(),
        verifyStore = verifyStore ?? MemoryVerifyStore(clock),
        _verifyUrlBase = verifyUrlBase,
        ruleset = _checkedRuleset(ruleset) {
    line = WaitingLine(clock: clock, random: _linkRandom);
  }

  /// Section 34 items 1 and 4: makes the one non-secret random source of a
  /// room, the first time that room needs one. A fresh `Random()` unless a
  /// test hands in a seeded one. Never the CSPRNG that feeds the dice.
  final Random Function() _computerRandomFactory;

  /// Section 34 item 4: told of every action the sweep takes for a computer
  /// seat, the moment it has taken it. Set by the wire layer, which builds and
  /// sends the frames; unset, [runComputerSeatsOnce] still returns the steps.
  void Function(ComputerStep step)? onComputerAction;

  /// Section 33 items 3 and 4: the one waiting line of this server. Ticket
  /// ids are drawn from the same CSPRNG as link ids, never from [_secure].
  late final WaitingLine line;

  /// `docs/PROTOCOL.md` section 28 rule 1: the ruleset every room created
  /// from here on takes, [ruleset202610], [ruleset202611] or [ruleset202612]. `bin/server.dart`
  /// reads it once from `RULESET` at start; a room copies it at `create_room`
  /// and never looks at this again.
  final String ruleset;

  final Clock _clock;
  final Random _secure;

  /// Section 32 items 7 to 12: the strike ladder and its store. Without a
  /// caller's store, an in-memory one with a random salt.
  final StrikeStore strikes;

  /// Room code -> what the strike ladder needs to know about each socket that
  /// took part in it: keyed by seat token for a seat, by knock id for a knock.
  /// Keyed hashes only, never an install or an IP. Gone with the room.
  final Map<String, Map<String, _StrikeIdentity>> _identities =
      <String, Map<String, _StrikeIdentity>>{};

  /// Room code -> the host's strike key: the keyed hash of the host's IP
  /// (section 32 item 15 (a)), empty when the IP was not known.
  final Map<String, String> _hostKeys = <String, String>{};

  /// Section 31 item 1: the source of link ids and knock ids. A separate
  /// CSPRNG from [_secure] so drawing them never moves a sequence the dice
  /// chain, the codes or the seeds are drawn from.
  final Random _linkRandom;

  /// Link id -> the room it names, for as long as the room lives.
  final Map<String, Room> _roomsByLink = <String, Room>{};

  /// Every link id this process ever issued, so one is never reused even
  /// after its room is reaped.
  /// Section 31 item 12 (d): only as long as they could collide, so an id is
  /// dropped once its time part is more than 2 seconds old.
  final Set<String> _issuedLinkIds = <String>{};

  /// Section 31 item 12 (b): knocks that were open when their room was reaped,
  /// waiting for the wire layer to tell their knockers. See
  /// [drainReapedKnocks].
  final List<Knock> _reapedKnocks = <Knock>[];

  /// Called at the end of [reap] with the knocks it just orphaned, so their
  /// knockers hear `knock_failed` at once rather than at the next sweep.
  /// Set by the wire layer; unset, [drainReapedKnocks] is the only way out.
  void Function(List<Knock> knocks)? onKnocksReaped;

  /// Called at the end of [reap] with the lobbies that sweep closed for
  /// outliving their lifetime, after they are removed and their codes rest,
  /// and in the same synchronous call. The wire layer sets it to tell the
  /// sockets (section 37 item 2); a caller that leaves it null drains
  /// [drainClosedLobbies] itself.
  void Function(List<ClosedLobby> closed)? onLobbiesClosed;

  /// docs/VERIFY.md section 3. Where a finished game's record is written at
  /// the moment it is won, and read back for `/v/<game_id>` and
  /// `/v/<game_id>.json`. Defaults to an in-memory store when no caller
  /// supplies one, which is what every existing call site (and every
  /// existing test) gets, unchanged.
  final VerifyStore verifyStore;

  /// docs/VERIFY.md section 3: `verify_url` is `'$_verifyUrlBase${room.gameId}'`.
  final String _verifyUrlBase;

  final Map<String, Room> _rooms = <String, Room>{};

  /// Code -> the moment it stops resting (reap time + 10 minutes).
  final Map<String, DateTime> _resting = <String, DateTime>{};

  /// Room code -> the moment its room first had no connected seat, in any
  /// state. Absent while at least one seat is connected. A LOBBY and a
  /// PLAYING room are reaped [_idleTimeout] after this moment; the turn
  /// timer playing an absent seat's turns does not touch it.
  final Map<String, DateTime> _idleSince = <String, DateTime>{};

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

  /// `create_room`. [open] is section 33 item 1's flag, fixed for the life
  /// of the room except that a computer seat clears it (section 34).
  CreateResult createRoom({
    required String name,
    required int players,
    required RulesConfig rules,
    String? install,
    String ip = '',
    bool open = false,
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
      via: 'host',
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
      linkId: _generateUniqueLinkId(),
      ruleset: ruleset,
      open: open,
    );
    _rooms[code] = room;
    _roomsByLink[room.linkId] = room;
    _hostKeys[code] = ip.isEmpty ? '' : strikes.key(ip);
    _refreshIdleTracking(room);
    return CreateOk(room: room, seat: hostSeat);
  }

  /// `join_room`, docs/PROTOCOL.md section 3 and section 31 items 2, 3 and 7.
  /// Exactly one of [code] and [link] names the room. [install] and [ip]
  /// identify the caller for the bars; [requestId] and [owner] are kept on a
  /// knock so its close can be answered. The ladder: the room (an unknown or
  /// finished link and an unknown code are `NO_SUCH_ROOM`), `ROOM_STARTED`,
  /// the name, `KICKED`, `ROOM_FULL`, and only then, for a typed code with
  /// approval on, `KNOCK_REFUSED`, `TOO_MANY_KNOCKS` and the knock itself.
  JoinResult joinRoom({
    String? code,
    String? link,
    required String name,
    String? install,
    String ip = '',
    String requestId = '',
    Object? owner,
  }) {
    if ((code == null) == (link == null)) {
      return JoinFailure(ProtocolError.badField);
    }
    final Room? room;
    if (link != null) {
      final Room? byLink = _roomsByLink[link];
      room =
          byLink != null && byLink.state != RoomState.finished ? byLink : null;
    } else {
      room = _rooms[foldRoomCode(code!)];
    }
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
    final String barKey = _barKey(install: install, ip: ip);
    final _StrikeIdentity identity = _StrikeIdentity(
      installKey: install == null ? null : strikes.key(install),
      ipKey: ip.isEmpty ? '' : strikes.key(ip),
    );
    if (room.kickBars.contains(barKey)) {
      return JoinFailure(ProtocolError.kicked);
    }
    final Set<int> taken = room.seats.map((Seat s) => s.seat).toSet();
    final List<int> free = _seatIndicesFor(room.players)
        .where((int s) => !taken.contains(s))
        .toList();
    if (free.isEmpty) {
      return JoinFailure(ProtocolError.roomFull);
    }
    if (link == null && room.guestApproval) {
      if (room.knockBars.contains(barKey)) {
        return JoinFailure(ProtocolError.knockRefused);
      }
      if (room.knocks.length >= _maxOpenKnocks) {
        return JoinFailure(ProtocolError.tooManyKnocks);
      }
      final Knock knock = Knock(
        id: _generateKnockId(room),
        name: trimmedName,
        createdAt: _clock.now,
        barKey: barKey,
        requestId: requestId,
        owner: owner,
      );
      room.knocks.add(knock);
      _identitiesOf(room)[knock.id] = identity;
      room.seq++;
      return JoinKnocked(
        room: room,
        knock: knock,
        opened: KnockOpened(
          room: room,
          knock: knock,
          seq: room.seq,
          hostSeatToken: _hostToken(room),
          others: buildRoomSnapshot(room, now: _clock.now),
        ),
      );
    }
    final Seat seat = Seat(
      seat: free.first,
      name: trimmedName,
      seatToken: generateSeatToken(_secure),
      connected: true,
      via: link != null ? 'link' : 'code',
      barKey: barKey,
    );
    _identitiesOf(room)[seat.seatToken] = identity;
    room.seats = <Seat>[...room.seats, seat]
      ..sort((Seat a, Seat b) => a.seat.compareTo(b.seat));
    _refreshIdleTracking(room);
    room.seq++;
    return JoinOk(room: room, seat: seat);
  }

  /// Section 4's name rule for a name no room holds yet (a ticket of the
  /// waiting line): the trimmed name, or null when it fails.
  String? validDisplayName(String name) => _validName(name);

  /// Section 33 item 2: [room] may take a stranger from the waiting line. It
  /// is open, in LOBBY (a rematch LOBBY counts), has a free seat, holds no
  /// computer seat, and its host seat's socket is connected.
  bool isMatchable(Room room) {
    if (!room.open ||
        room.state != RoomState.lobby ||
        room.hasComputerSeat ||
        _freeSeats(room).isEmpty) {
      return false;
    }
    final Seat? host = _seatAt(room, room.hostSeat);
    return host != null && host.connected;
  }

  /// Section 33 items 2 and 7: the oldest matchable room that does not bar
  /// the device with [install] (else [ip]), or null. Rooms created in the
  /// same instant go in the order they were created.
  Room? matchableRoomFor({required String? install, required String ip}) {
    final String barKey = _barKey(install: install, ip: ip);
    Room? oldest;
    for (final Room room in _rooms.values) {
      if (!isMatchable(room) || room.kickBars.contains(barKey)) {
        continue;
      }
      if (oldest == null || room.createdAt.isBefore(oldest.createdAt)) {
        oldest = room;
      }
    }
    return oldest;
  }

  /// Section 33 items 3 and 5: seats a stranger on the lowest free seat of
  /// [room], `via: "public"`. Refuses, changing nothing, unless [room] is
  /// matchable and does not bar the device: `ROOM_FULL` for a room that is
  /// no longer matchable, `KICKED` for a barred device.
  JoinResult seatPublic(
    Room room, {
    required String name,
    required String install,
    required String ip,
  }) {
    if (!isMatchable(room)) {
      return JoinFailure(ProtocolError.roomFull);
    }
    final String barKey = _barKey(install: install, ip: ip);
    if (room.kickBars.contains(barKey)) {
      return JoinFailure(ProtocolError.kicked);
    }
    final Seat seat = Seat(
      seat: _freeSeats(room).first,
      name: name,
      seatToken: generateSeatToken(_secure),
      connected: true,
      via: 'public',
      barKey: barKey,
    );
    _identitiesOf(room)[seat.seatToken] = _StrikeIdentity(
      installKey: strikes.key(install),
      ipKey: ip.isEmpty ? '' : strikes.key(ip),
    );
    room.seats = <Seat>[...room.seats, seat]
      ..sort((Seat a, Seat b) => a.seat.compareTo(b.seat));
    _refreshIdleTracking(room);
    room.seq++;
    return JoinOk(room: room, seat: seat);
  }

  /// Section 33 item 4: one seating pass over the waiting line. Attached
  /// tickets are served from the head, each into the oldest matchable room
  /// that does not bar it; a ticket no room takes stays where it is and the
  /// ones behind it are still served. When no ticket can be seated and two
  /// or more attached tickets wait, a room is created for the first attached
  /// one (`players` 4, `open`, default rules, that ticket its host), outside
  /// the per-IP creation limit, and the pass goes on. Detached tickets are
  /// passed over and never counted. Each seated ticket leaves the line.
  ///
  /// Every event is returned in the order it happened, its snapshot built at
  /// that moment. Run again with nothing changed, it does nothing.
  List<LineEvent> serveLine() {
    final List<LineEvent> events = <LineEvent>[];
    while (!line.isEmpty) {
      LineEvent? seated;
      for (final Ticket ticket in line.attachedTickets) {
        final Room? room =
            matchableRoomFor(install: ticket.install, ip: ticket.ip);
        if (room == null) {
          continue;
        }
        final JoinResult joined = seatPublic(
          room,
          name: ticket.name,
          install: ticket.install,
          ip: ticket.ip,
        );
        if (joined is! JoinOk) {
          // matchableRoomFor has just said this room takes this ticket; a
          // refusal here means the two checks drifted apart. Say so and leave
          // the ticket where it is.
          // ignore: avoid_print
          print('room=${room.code} type=- id=- seat=- outcome=line_seat_failed '
              'error=${(joined as JoinFailure).error.name}');
          continue;
        }
        line.remove(ticket);
        seated = LineSeated(
          ticket: ticket,
          room: room,
          seat: joined.seat,
          seq: room.seq,
          snapshot: buildRoomSnapshot(
            room,
            now: _clock.now,
            forHost: joined.seat.seat == room.hostSeat,
          ),
        );
        break;
      }
      if (seated != null) {
        events.add(seated);
        continue;
      }
      final List<Ticket> attached = line.attachedTickets;
      if (attached.length < 2) {
        break;
      }
      final Ticket head = attached.first;
      final CreateResult created = createRoom(
        name: head.name,
        players: 4,
        rules: const RulesConfig(),
        install: head.install,
        ip: head.ip,
        open: true,
      );
      if (created is! CreateOk) {
        // The name was checked when the ticket was made and the other
        // arguments are fixed, so this is a drift, not a caller's mistake.
        // ignore: avoid_print
        print('room=- type=- id=- seat=- outcome=line_room_failed '
            'error=${(created as CreateFailure).error.name}');
        break;
      }
      line.remove(head);
      events.add(
        LineRoomCreated(
          ticket: head,
          room: created.room,
          seat: created.seat,
          seq: created.room.seq,
          snapshot: buildRoomSnapshot(
            created.room,
            now: _clock.now,
            forHost: true,
          ),
        ),
      );
    }
    return events;
  }

  /// Section 31 item 11 (e): `start_game` closes every knock still open,
  /// outcome `full`.
  List<KnockEvent> _closeAllKnocksFull(Room room) => <KnockEvent>[
        for (final Knock knock in List<Knock>.of(room.knocks))
          _closeKnock(room, knock, 'full'),
      ];

  /// The room a link id names, for as long as that room lives and is not
  /// FINISHED; null for an unknown, reaped or finished one, and for garbage.
  /// Section 31 items 2 and 9.
  Room? lookupByLink(String link) {
    final Room? room = _roomsByLink[link];
    if (room == null || room.state == RoomState.finished) {
      return null;
    }
    return room;
  }

  /// True while [knockId] is still open in room [code].
  bool hasOpenKnock(String code, String knockId) {
    final Room? room = _rooms[code];
    return room != null && room.knocks.any((Knock k) => k.id == knockId);
  }

  /// `answer_knock`, section 31 item 4. [data] is the message's whole `d`: the
  /// ladder puts `NOT_HOST` and the phase ahead of the payload check, so the
  /// payload is looked at here, in that order: room, seat authorised,
  /// `NOT_HOST`, LOBBY (`WRONG_PHASE`), `knock_id` a string and `accept` a
  /// bool with no other key (`BAD_FIELD`), the knock (`NO_SUCH_KNOCK`).
  AnswerKnockResult answerKnock({
    required String code,
    required String seatToken,
    required Map<String, Object?> data,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return AnswerKnockFailure(ProtocolError.noSuchRoom);
    }
    final Seat? caller = _findSeat(room, seatToken);
    if (caller == null) {
      return AnswerKnockFailure(ProtocolError.badSeatToken);
    }
    if (caller.seat != room.hostSeat) {
      return AnswerKnockFailure(ProtocolError.notHost);
    }
    if (room.state != RoomState.lobby) {
      return AnswerKnockFailure(ProtocolError.wrongPhase);
    }
    final Object? rawId = data['knock_id'];
    final Object? rawAccept = data['accept'];
    if (data.length != 2 || rawId is! String || rawAccept is! bool) {
      return AnswerKnockFailure(ProtocolError.badField);
    }
    Knock? knock;
    for (final Knock k in room.knocks) {
      if (k.id == rawId) {
        knock = k;
        break;
      }
    }
    if (knock == null) {
      return AnswerKnockFailure(ProtocolError.noSuchKnock);
    }
    final List<KnockEvent> events = <KnockEvent>[];
    if (!rawAccept) {
      // Section 33 item 6 (a), replacing section 32 item 7: the one strike
      // source on a knock, and only in a room that is not open.
      final BanInfo? ban =
          room.open ? null : _strike(room, _identitiesOf(room)[knock.id]);
      events.add(_closeKnock(room, knock, 'rejected', bar: true, ban: ban));
    } else {
      _settleKnock(room, knock, events);
    }
    return AnswerKnockOk(room: room, events: events);
  }

  /// `set_guest_approval`, section 31 item 5. Ladder: room, seat authorised,
  /// `NOT_HOST`, then the payload (`enabled` a bool, nothing else), in any
  /// state of a live room.
  SetApprovalResult setGuestApproval({
    required String code,
    required String seatToken,
    required Map<String, Object?> data,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return SetApprovalFailure(ProtocolError.noSuchRoom);
    }
    final Seat? caller = _findSeat(room, seatToken);
    if (caller == null) {
      return SetApprovalFailure(ProtocolError.badSeatToken);
    }
    if (caller.seat != room.hostSeat) {
      return SetApprovalFailure(ProtocolError.notHost);
    }
    final Object? enabled = data['enabled'];
    if (data.length != 1 || enabled is! bool) {
      return SetApprovalFailure(ProtocolError.badField);
    }
    room.guestApproval = enabled;
    room.seq++;
    final int seq = room.seq;
    final DateTime now = _clock.now;
    final Map<String, Object?> hostSnapshot =
        buildRoomSnapshot(room, now: now, forHost: true);
    final Map<String, Object?> othersSnapshot =
        buildRoomSnapshot(room, now: now);
    final List<KnockEvent> events = <KnockEvent>[];
    if (!enabled) {
      // Item 5: open knocks are settled in the order they arrived, seating up
      // to the free seats and closing the rest `switched_off`.
      for (final Knock knock in List<Knock>.of(room.knocks)) {
        if (!room.knocks.any((Knock k) => k.id == knock.id)) {
          continue;
        }
        if (_freeSeats(room).isEmpty || room.state != RoomState.lobby) {
          events.add(_closeKnock(room, knock, 'switched_off'));
        } else {
          _settleKnock(room, knock, events);
        }
      }
    }
    return SetApprovalOk(
      room: room,
      seq: seq,
      hostSnapshot: hostSnapshot,
      othersSnapshot: othersSnapshot,
      events: events,
    );
  }

  /// Closes the knock [knockId] of room [code] as `withdrawn` (its socket
  /// closed or sent `leave_room`). Empty when it is no longer open.
  List<KnockEvent> withdrawKnock(String code, String knockId) {
    final Room? room = _rooms[code];
    if (room == null) {
      return const <KnockEvent>[];
    }
    for (final Knock knock in room.knocks) {
      if (knock.id == knockId) {
        return <KnockEvent>[_closeKnock(room, knock, 'withdrawn')];
      }
    }
    return const <KnockEvent>[];
  }

  /// Closes every knock open for [_knockLifetime] or more on the injected
  /// clock as `timeout`, barring its knocker from the typed-code path. Run by
  /// the wire layer's 1 s sweep.
  List<KnockEvent> expireKnocks() {
    final DateTime now = _clock.now;
    final List<KnockEvent> events = <KnockEvent>[];
    for (final Room room in _rooms.values.toList(growable: false)) {
      for (final Knock knock in List<Knock>.of(room.knocks)) {
        if (now.difference(knock.createdAt) >= _knockLifetime) {
          events.add(_closeKnock(room, knock, 'timeout', bar: true));
        }
      }
    }
    return events;
  }

  /// Accepts [knock]: seats it on the lowest free seat, or closes it `full`
  /// when none is free. Appends what happened to [events].
  void _settleKnock(Room room, Knock knock, List<KnockEvent> events) {
    final List<int> free = _freeSeats(room);
    if (free.isEmpty) {
      events.add(_closeKnock(room, knock, 'full'));
      return;
    }
    events.add(_closeKnock(room, knock, 'accepted'));
    final Seat seat = Seat(
      seat: free.first,
      name: knock.name,
      seatToken: generateSeatToken(_secure),
      connected: true,
      via: 'approved',
      barKey: knock.barKey,
    );
    final _StrikeIdentity? knockIdentity = _identitiesOf(room)[knock.id];
    if (knockIdentity != null) {
      _identitiesOf(room)[seat.seatToken] = knockIdentity;
    }
    room.seats = <Seat>[...room.seats, seat]
      ..sort((Seat a, Seat b) => a.seat.compareTo(b.seat));
    _refreshIdleTracking(room);
    room.seq++;
    final DateTime now = _clock.now;
    events.add(
      KnockSeated(
        room: room,
        knock: knock,
        seq: room.seq,
        hostSeatToken: _hostToken(room),
        others: buildRoomSnapshot(room, now: now),
        seat: seat,
        snapshot: buildRoomSnapshot(
          room,
          now: now,
          forHost: seat.seat == room.hostSeat,
        ),
      ),
    );
  }

  KnockClosed _closeKnock(
    Room room,
    Knock knock,
    String outcome, {
    bool bar = false,
    BanInfo? ban,
  }) {
    room.knocks.removeWhere((Knock k) => k.id == knock.id);
    if (bar) {
      room.knockBars.add(knock.barKey);
    }
    room.seq++;
    return KnockClosed(
      room: room,
      knock: knock,
      seq: room.seq,
      hostSeatToken: _hostToken(room),
      others: buildRoomSnapshot(room, now: _clock.now),
      outcome: outcome,
      ban: ban,
    );
  }

  List<int> _freeSeats(Room room) {
    final Set<int> taken = room.seats.map((Seat s) => s.seat).toSet();
    return _seatIndicesFor(room.players)
        .where((int s) => !taken.contains(s))
        .toList();
  }

  String? _hostToken(Room room) {
    final Seat? host = _seatAt(room, room.hostSeat);
    return host?.seatToken;
  }

  Map<String, _StrikeIdentity> _identitiesOf(Room room) =>
      _identities.putIfAbsent(room.code, () => <String, _StrikeIdentity>{});

  /// Records a strike against [target] from [room]'s host (section 32 item
  /// 7). A socket that sent no `install` cannot be struck. Returns the ban the
  /// strike fired, or null.
  BanInfo? _strike(Room room, _StrikeIdentity? target) {
    final String? installKey = target?.installKey;
    if (target == null || installKey == null) {
      return null;
    }
    final String hostKey = _hostKeys[room.code] ?? '';
    // Item 15 (a): a host with no known IP, or the struck socket's own IP,
    // is not a distinct host and records nothing.
    if (hostKey.isEmpty || hostKey == target.ipKey) {
      return null;
    }
    return strikes.recordStrike(
      installKey: installKey,
      hostKey: hostKey,
      ipKey: target.ipKey,
    );
  }

  /// Section 32 item 9: the ban that stops a typed code from this [install]
  /// and [ip], or null. Asked before the lookup, so a banned caller learns
  /// nothing about whether a room exists.
  BanInfo? codeBan({String? install, required String ip}) => strikes.banFor(
        installKey: install == null ? null : strikes.key(install),
        ipKey: ip.isEmpty ? null : strikes.key(ip),
      );

  /// Section 32 item 11: the strike store's housekeeping, on the one-second
  /// sweep.
  void sweepStrikes() => strikes.sweep();

  /// Section 31 item 7: the SHA-256 (hex) of the `install` when there is one,
  /// otherwise of the IP. The two are prefixed apart so one string can never
  /// stand for the other.
  String _barKey({String? install, required String ip}) {
    final String basis = install != null ? 'i:$install' : 'p:$ip';
    return sha256.convert(utf8.encode(basis)).toString();
  }

  /// `kick` in LOBBY, section 31 item 6. [data] is the whole `d`. Ladder:
  /// room, seat authorised, `NOT_HOST`, LOBBY (`WRONG_PHASE`), `seat` an int
  /// 0..3 and no other key (`BAD_FIELD`), then the host's own seat and an
  /// empty seat (`ILLEGAL_MOVE`). The seat is freed as `leave_room` frees it
  /// and its install or IP is barred from the room.
  KickLobbyResult kickLobby({
    required String code,
    required String seatToken,
    required Map<String, Object?> data,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return KickLobbyFailure(ProtocolError.noSuchRoom);
    }
    final Seat? caller = _findSeat(room, seatToken);
    if (caller == null) {
      return KickLobbyFailure(ProtocolError.badSeatToken);
    }
    if (caller.seat != room.hostSeat) {
      return KickLobbyFailure(ProtocolError.notHost);
    }
    if (room.state != RoomState.lobby) {
      return KickLobbyFailure(ProtocolError.wrongPhase);
    }
    final Object? rawSeat = data['seat'];
    if (data.length != 1 || rawSeat is! int || rawSeat < 0 || rawSeat > 3) {
      return KickLobbyFailure(ProtocolError.badField);
    }
    final Seat? target = _seatAt(room, rawSeat);
    if (target == null || target.seat == room.hostSeat) {
      return KickLobbyFailure(ProtocolError.illegalMove);
    }
    final String? key = target.barKey;
    if (key != null) {
      room.kickBars.add(key);
    }
    final BanInfo? ban = _kickStrike(room, target);
    _removeLobbySeat(room, target);
    room.seq++;
    return KickLobbyOk(room: room, seat: target, ban: ban);
  }

  /// Section 33 item 6 (b), replacing section 32 item 7: the host's kick, in
  /// LOBBY or in PLAYING, of a seat taken by typed code or by an accepted
  /// knock is a strike, and only while the room is not open. A `public`,
  /// `link` or `bot` seat never is. Returns the ban it fired, or null.
  BanInfo? _kickStrike(Room room, Seat target) {
    if (room.open) {
      return null;
    }
    if (target.via != 'code' && target.via != 'approved') {
      return null;
    }
    return _strike(room, _identitiesOf(room)[target.seatToken]);
  }

  /// Frees [seat] of a LOBBY or FINISHED room the way `leave_room` does.
  void _removeLobbySeat(Room room, Seat seat) {
    room.seats =
        room.seats.where((Seat s) => s.seatToken != seat.seatToken).toList();
    if (room.hostSeat == seat.seat) {
      room.hostSeat = room.seats.isEmpty
          ? -1
          : room.seats.map((Seat s) => s.seat).reduce(min);
    }
    final Rematch? current = room.rematch;
    if (current != null && current.ready.contains(seat.seat)) {
      room.rematch = Rematch(
        by: current.by,
        ready: current.ready.where((int s) => s != seat.seat).toList(),
      );
    }
    _refreshIdleTracking(room);
  }

  ResumeResult resume({required String code, required String seatToken}) {
    final Room? room = _rooms[foldRoomCode(code)];
    if (room == null) {
      return ResumeFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return ResumeFailure(ProtocolError.badSeatToken);
    }
    final bool reconnected = !seat.connected;
    final bool humanWasHere = _anyHumanConnected(room);
    seat.connected = true;
    if (!humanWasHere && seat.bot == null) {
      // Section 34 item 4: the pace of a waiting computer seat restarts here.
      room.humanBackAt = _clock.now;
    }
    // Section 28 rule 4: a resume that reconnects the seat ends the absence
    // count; a later drop starts a new one.
    seat.absentSince = null;
    // docs/PROTOCOL.md section 26 rule 2: a seat reconnected at any point of
    // the turn that would have made it away is not made away by that turn.
    seat.connectedThisTurn = true;
    _refreshIdleTracking(room);
    int? presenceSeq;
    int? turnSeq;
    int? turnDeadlineMs;
    int? turnGraceMs;
    if (reconnected) {
      room.seq++;
      presenceSeq = room.seq;
      // Section 26 rule 5: a reconnect always clears away. Only a seat on
      // turn with the short segment running has anything to restart; one
      // whose running segment is already a full one keeps counting down.
      seat.away = false;
      final engine.GameState? game = room.game;
      if (room.state == RoomState.playing &&
          game != null &&
          game.currentSeat == seat.seat &&
          room.turnSegmentMs == _awaySegmentMs) {
        // Section 29 rule 7: inside a grace the restarted segment keeps the
        // grace's end, and the pushed `turn` carries what is left of it.
        final int graceLeftMs = room.graceLeftMs(_clock.now);
        turnDeadlineMs = _restartSegment(
          room,
          graceMs: graceLeftMs > 0 ? graceLeftMs : null,
        );
        turnGraceMs = graceLeftMs > 0 ? graceLeftMs : null;
        room.seq++;
        turnSeq = room.seq;
      }
    }
    return ResumeOk(
      room: room,
      seat: seat,
      reconnected: reconnected,
      presenceSeq: presenceSeq,
      turnSeq: turnSeq,
      turnDeadlineMs: turnDeadlineMs,
      turnGraceMs: turnGraceMs,
    );
  }

  StartResult startGame({required String code, required String seatToken}) {
    final StartResult result = _startGame(code: code, seatToken: seatToken);
    if (result is StartOk) {
      result.knockEvents = _closeAllKnocksFull(result.room);
    }
    return result;
  }

  StartResult _startGame({required String code, required String seatToken}) {
    final Room? room = _rooms[code];
    if (room == null) {
      return StartFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return StartFailure(ProtocolError.badSeatToken);
    }
    if (room.state == RoomState.finished) {
      return StartFailure(ProtocolError.gameOver);
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
          via: keep[i].via,
          barKey: keep[i].barKey,
          bot: keep[i].bot,
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
      // docs/RULES.md rules 11a and 21, the 2026-10-15 ruling: every server
      // room plays blocks off and homeBonus on, regardless of what was
      // requested at create_room; only captureBonus comes from room.rules.
      // docs/PROTOCOL.md section 21.3 rule 5: every room also plays the
      // roll queue -- it is not a toggle on the wire, and nothing here ever
      // sets it to false.
      rules: engine.RulesConfig(
        blocks: false,
        captureBonus: room.rules.captureBonus,
        rollQueue: true,
        homeBonus: true,
        // docs/PROTOCOL.md section 28 rule 1: the yard release and the
        // places played out are the 2026-11 ruleset, and only it. The room
        // took its ruleset at create_room, so a rematch plays the same one.
        yardRelease: room.isRuleset202611,
        playOut: room.isRuleset202611,
        // Section 30 rule 1: the shared release is the 2026-12 ruleset, and
        // only it; every config of the room, rematches included, has it.
        sharedRelease: room.isRuleset202612,
      ),
      seed: _secureSeed(),
    );
    room.game = engine.newGame(config);
    room.state = RoomState.playing;
    room.queuedBankedCount = 0;
    room.queuedBankedSeat = -1;
    // docs/PROTOCOL.md section 23 rule 3: game_started sets every seat's
    // timer_steps to 0, in the first game and in every rematch.
    for (final Seat s in room.seats) {
      s.timerSteps = 0;
      // Section 26 rule 1: game_started makes every seat not away, in the
      // first game and in every rematch.
      s.away = false;
    }
    _noteTurnOwner(room, null);
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
    final bool autoStart = rematchAutoStartHolds(room);
    // docs/PROTOCOL.md section 16.4, "Everyone accepted": [room] is handed
    // back here exactly as this accept left it, still LOBBY -- starting the
    // game is the caller's job, through [startRematchAuto], once it has
    // already published this `room` as the frame that records the
    // acceptance. See the long comment on [RematchOk.autoStart].
    return RematchOk(room: room, changed: true, autoStart: autoStart);
  }

  /// `docs/PROTOCOL.md` section 16.4's "Everyone accepted" condition, read
  /// fresh off [room] at this instant: [room] is a rematch LOBBY, every
  /// occupied seat is in `rematch.ready`, at least two seats are occupied,
  /// and every one of them is connected. The one predicate behind the accept
  /// path in [rematch] and, since section 16.9 rule 5, the evaluation after a
  /// `resume` and after a `leave_room`. Pure: it changes nothing.
  bool rematchAutoStartHolds(Room room) {
    final Rematch? current = room.rematch;
    if (room.state != RoomState.lobby || current == null) {
      return false;
    }
    final bool everyoneReady =
        room.seats.every((Seat s) => current.ready.contains(s.seat));
    final bool atLeastTwo = room.seats.length >= 2;
    final bool everyoneConnected = room.seats.every((Seat s) => s.connected);
    return everyoneReady && atLeastTwo && everyoneConnected;
  }

  /// `docs/PROTOCOL.md` section 16.4, "Everyone accepted": the exact
  /// mechanics an accepted `start_game` runs, called once the wire layer has
  /// already broadcast the `room` that `rematch` returned with
  /// `RematchOk.autoStart` true, or, since section 16.9 rule 5, once
  /// [rematchAutoStartHolds] is true after a `resume` or a `leave_room`.
  /// [room] must be that same `Room`, with
  /// nothing else called against this registry in between -- this file is
  /// synchronous throughout, so a caller that does not `await` anything
  /// between the two calls gets exactly that for free.
  StartOk startRematchAuto(Room room) {
    final StartOk result = _beginGame(room);
    result.knockEvents = _closeAllKnocksFull(room);
    return result;
  }

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
    room.releases.clear();
    room.declined.clear();
    room.lapsed.clear();
    room.queuedBankedCount = 0;
    room.queuedBankedSeat = -1;
    room.grants.clear();
    room.turnSegmentStartedAt = null;
    room.turnGraceEndsAt = null;
    for (final Seat s in room.seats) {
      s.clientSeed = null;
      s.seedOrigin = null;
      // docs/PROTOCOL.md section 23 rule 3: a rematch LOBBY reads 0.
      s.timerSteps = 0;
    }
    // docs/PROTOCOL.md section 11.3, "never reuse a chain across games":
    // a fresh chain, from a fresh CSPRNG draw, never derived from the chain
    // it replaces.
    room.chainIndex += 1;
    room.chain = DiceChain.build(_drawBytes(_serverSecretBytes));
    room.rematch = Rematch(by: requester.seat, ready: <int>[requester.seat]);
    // docs/PROTOCOL.md section 16.2 item 4: the room's lifetime clock (the
    // LOBBY's 60 minutes, and the 6-hour ceiling of a game that follows)
    // restarts from this moment.
    room.lifetimeStartedAt = _clock.now;
    // The FINISHED stamp belonged to the game that just ended.
    _finishedSince.remove(room.code);
  }

  /// `roll`, `docs/PROTOCOL.md` section 12.1. The rejection ladder below is
  /// the section's own table, in order, first failure wins: nothing is
  /// touched before a rejection, so a client that retries a rejected roll
  /// gets the `k` it would have had.
  ///
  /// `docs/PROTOCOL.md` section 23 rule 3: an accepted roll resets the
  /// seat's `timerSteps` to 0, and a rejected one changes nothing.
  /// [expireTurns] calls this same method for the timer and puts the count
  /// back one higher afterwards (rule 2), so there is one accept path.
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
    final _RollDraw draw = _drawRoll(room, seat, commit: true);
    final engine.EngineError? refused = draw.refused;
    if (refused != null) {
      // Unreachable given the ladder above already matches the engine's own
      // ordering for this intention, but the engine's contract is "never
      // throws, every refusal is a Rejected" and this call site honours
      // that rather than assuming: _drawRoll touches no room state when the
      // engine refuses, so this, too, advances nothing.
      return RollFailure(_mapEngineError(refused));
    }
    final engine.Applied appliedOk = draw.applied!;
    final String reveal = draw.reveal;

    room.seq++;
    final int rolledSeq = room.seq;

    final bool turnEnded =
        appliedOk.events.whereType<engine.TurnEnded>().isNotEmpty;
    // docs/PROTOCOL.md section 21.3 rule 4: a queued 6 that owes another
    // roll keeps the same seat in `await_roll` and still needs its own
    // `turn` frame -- the uniform "a turn segment began" signal 13.1
    // already established for the start of a game, now reused for the
    // start of every roll segment, not only the first.
    final bool extraRollGranted =
        appliedOk.events.whereType<engine.ExtraRoll>().isNotEmpty;

    int rolledDeadlineMs;
    int? turnPassedSeq;
    int? turnSeq;
    int? nextDeadlineMs;
    int? nextGraceMs;

    if (!turnEnded && !extraRollGranted) {
      // The roll leaves a legal move pending: the segment restarts now.
      rolledDeadlineMs = _restartSegment(room);
    } else {
      // Either the turn is about to pass, or the same seat owes another
      // roll at once. In both cases this `rolled` frame reports what was
      // left of the segment that was already running; that segment does
      // not restart until the `turn` frame below -- a moved that leaves the
      // same seat to act does not restart it either, by the same rule, and
      // this is a roll's analogue of that.
      rolledDeadlineMs = _remainingSegmentMs(room);
      if (turnEnded) {
        room.seq++;
        turnPassedSeq = room.seq;
      }
      room.seq++;
      turnSeq = room.seq;
      _noteTurnOwner(room, seat.seat);
      nextGraceMs = _graceFor(room, appliedOk.events, seat.seat);
      nextDeadlineMs = _restartSegment(room, graceMs: nextGraceMs);
    }

    return RollOk(
      room: room,
      events: appliedOk.events,
      k: k,
      reveal: reveal,
      payload: draw.payload!,
      after: appliedOk.state,
      rolledSeq: rolledSeq,
      rolledDeadlineMs: rolledDeadlineMs,
      release: draw.release,
      turnPassedSeq: turnPassedSeq,
      turnSeq: turnSeq,
      nextDeadlineMs: nextDeadlineMs,
      nextGraceMs: nextGraceMs,
    );
  }

  /// Section 12.1 steps 1 to 4, the one draw of a roll: reads `chain.reveal(k)`
  /// for `k = rollCount + 1`, draws the face with `drawDie`, applies
  /// `RollIntention` with the engine's `apply`, and builds the roll's payload
  /// ([buildRollPayload]) from what the engine returned. The caller has run
  /// the whole ladder of [roll] and checked `k` against the chain's length.
  ///
  /// With [commit] true this is [roll]'s own step: the room takes the new
  /// engine state, the roll counter, the roll's seat and its release marks.
  /// With [commit] false it is section 35's `pre`: nothing on [room] or
  /// [seat] is written. `engine.apply` is pure (a `GameState` is immutable
  /// and `apply` returns a new one), so the state it returns is simply
  /// dropped; `chain.reveal` and `drawDie` only read. The same link, face and
  /// engine call therefore give the same payload when the roll is committed.
  ///
  /// An engine refusal returns [_RollDraw.refused] and touches nothing,
  /// committing or not.
  _RollDraw _drawRoll(Room room, Seat seat, {required bool commit}) {
    final engine.GameState game = room.game!;
    final int k = room.rollCount + 1;
    final String reveal = room.chain.reveal(k);
    final int value = drawDie(reveal, room.gameId!, room.clientSeeds!, k, 0);
    final engine.ApplyResult applied =
        engine.apply(game, engine.RollIntention(seat.seat, value));
    if (applied is engine.Rejected) {
      return _RollDraw.refused(k: k, reveal: reveal, refused: applied.error);
    }
    final engine.Applied appliedOk = applied as engine.Applied;
    final bool releaseRoll = _grantedRelease(game, appliedOk);
    final engine.Rolled event =
        appliedOk.events.whereType<engine.Rolled>().single;
    final TurnQueueFields afterFields = turnQueueFields(appliedOk.state);
    final Map<String, Object?> payload = buildRollPayload(
      seat: event.seat,
      value: event.value,
      legal: event.legal,
      k: k,
      queue: afterFields.queue,
      legalByFace: afterFields.legalByFace,
      release: releaseRoll,
      offer: afterFields.offer,
    );
    if (commit) {
      room.game = appliedOk.state;
      _noteQueuedBanked(room, appliedOk.events);
      room.rollCount = k;
      seat.timerSteps = 0;
      // docs/VERIFY.md section 1.2: this is the one code path that sets
      // room.rollCount = k, whether a player rolled or the turn timer did on
      // their behalf (expireTurns() reaches here through roll()) -- so
      // appending here, and only here, keeps rollSeats.length == rollCount
      // true without a second place either could drift from the other.
      room.rollSeats.add(seat.seat);
      // docs/PROTOCOL.md section 28 rule 2 and section 30 rule 7: the roll
      // numbers whose roll granted a yard release, lapses included, for the
      // verify record. Under 2026-11 the engine's YardReleased event is the
      // source; under 2026-12 it is emitted when the release is taken, so
      // the roll is read off the state it left behind instead.
      if (releaseRoll) {
        room.releases.add(k);
        // Section 30 rule 7: a release roll that raised no offer was a lapse.
        if (game.config.rules.sharedRelease &&
            !appliedOk.state.releaseOffered) {
          room.lapsed.add(k);
        }
      }
    }
    return _RollDraw(
      k: k,
      reveal: reveal,
      applied: appliedOk,
      release: releaseRoll,
      payload: payload,
    );
  }

  /// Section 35 item 3: [seat] was sent a `pre` for the roll it owes now, and
  /// that roll has not been taken.
  bool _holdsPre(Room room, Seat seat) {
    final engine.GameState? game = room.game;
    return game != null &&
        room.state == RoomState.playing &&
        game.phase == engine.GamePhase.awaitRoll &&
        game.currentSeat == seat.seat &&
        room.preGameId != null &&
        room.preGameId == room.gameId &&
        room.preSeat == seat.seat &&
        room.preK == room.rollCount + 1;
  }

  /// Section 30 rule 5: keeps `room.queuedBankedCount` equal to what the
  /// `SixesQueued` event of the step that began the current turn said, read by
  /// `queuedBankedSixes` like every frame built from events, so the pushed
  /// frames and a reconnect's frame share one source. Called after every
  /// engine step. The count is dropped when the owning seat rolled, the turn
  /// ended, the game was won, or the turn moved off that seat.
  void _noteQueuedBanked(Room room, List<engine.GameEvent> events) {
    final engine.GameState? game = room.game;
    if (game == null) {
      room.queuedBankedSeat = -1;
      room.queuedBankedCount = 0;
      return;
    }
    final int queued = queuedBankedSixes(events, game.currentSeat);
    final bool over = events.whereType<engine.GameWon>().isNotEmpty;
    if (queued > 0 && !over) {
      room.queuedBankedSeat = game.currentSeat;
      room.queuedBankedCount = queued;
      return;
    }
    final int owner = room.queuedBankedSeat;
    final bool ownerRolled = events
        .whereType<engine.Rolled>()
        .any((engine.Rolled r) => r.seat == owner);
    final bool turnEnded = events.whereType<engine.TurnEnded>().isNotEmpty;
    if (over || ownerRolled || turnEnded || game.currentSeat != owner) {
      room.queuedBankedSeat = -1;
      room.queuedBankedCount = 0;
    }
  }

  /// True when the roll [applied] to [before] granted a yard release. Without
  /// `sharedRelease` that is the engine's `YardReleased` event. With it the
  /// event comes only when the release is taken, so the roll is an offer
  /// (`releaseOffered` in the state it left) or a lapse (the seat's drought
  /// stood at 9, every token in the yard, and a non-6 came up, which ends
  /// the turn with nothing to release).
  bool _grantedRelease(engine.GameState before, engine.Applied applied) {
    if (!before.config.rules.sharedRelease) {
      return applied.events.whereType<engine.YardReleased>().isNotEmpty;
    }
    if (applied.state.releaseOffered) {
      return true;
    }
    final engine.Rolled rolled =
        applied.events.whereType<engine.Rolled>().single;
    final int seat = rolled.seat;
    return rolled.value != 6 &&
        before.drought[seat] == 9 &&
        before.tokens[seat].every((int p) => p == -1) &&
        applied.events.whereType<engine.TurnEnded>().isNotEmpty;
  }

  /// `decline_release`, `docs/PROTOCOL.md` section 30 rule 4. The ladder is
  /// [roll]'s own (room, seat, game over, lobby, turn), then `WRONG_PHASE`
  /// when no offer is pending, which is every room below 2026-12 too.
  /// Nothing is touched before a rejection. The engine answers with
  /// `ReleaseDeclined`, `TurnEnded` and the next seat's `TurnBegan`.
  DeclineResult declineRelease({
    required String code,
    required String seatToken,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return DeclineFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return DeclineFailure(ProtocolError.badSeatToken);
    }
    if (room.state == RoomState.finished) {
      return DeclineFailure(ProtocolError.gameOver);
    }
    if (room.state == RoomState.lobby) {
      return DeclineFailure(ProtocolError.wrongPhase);
    }
    final engine.GameState game = room.game!;
    if (seat.seat != game.currentSeat) {
      return DeclineFailure(ProtocolError.notYourTurn);
    }
    if (game.phase != engine.GamePhase.awaitMove || !game.releaseOffered) {
      return DeclineFailure(ProtocolError.wrongPhase);
    }

    final engine.ApplyResult applied =
        engine.apply(game, engine.DeclineIntention(seat.seat));
    if (applied is engine.Rejected) {
      return DeclineFailure(_mapEngineError(applied.error));
    }
    final engine.Applied appliedOk = applied as engine.Applied;
    room.game = appliedOk.state;
    _noteQueuedBanked(room, appliedOk.events);
    seat.timerSteps = 0;
    // The offering roll is the last one rolled: nothing rolls while an offer
    // is pending.
    room.declined.add(room.rollCount);

    room.seq++;
    final int declinedSeq = room.seq;
    room.seq++;
    final int turnPassedSeq = room.seq;
    room.seq++;
    final int turnSeq = room.seq;
    _noteTurnOwner(room, seat.seat);
    final int? graceMs = _graceFor(room, appliedOk.events, seat.seat);
    final int nextDeadlineMs = _restartSegment(room, graceMs: graceMs);
    return DeclineOk(
      room: room,
      events: appliedOk.events,
      declinedSeq: declinedSeq,
      turnPassedSeq: turnPassedSeq,
      turnSeq: turnSeq,
      nextDeadlineMs: nextDeadlineMs,
      nextGraceMs: graceMs,
    );
  }

  /// `move`, `docs/PROTOCOL.md` section 12.2 and section 21.1. Same ladder
  /// shape as [roll], with `WRONG_PHASE` when the turn is awaiting a roll
  /// rather than a move. [token] and [face] have already passed the wire
  /// layer's own `BAD_FIELD` checks (absent or the wrong type, [token]
  /// outside `0..3`, [face] outside `1..6`) by the time either reaches
  /// here -- that is why this method's own signature takes a plain `int`
  /// for [token] -- but both ranges are re-checked below anyway, the same
  /// defence in depth every other registry call applies to what its own
  /// caller already validated. [face] null means "the default face"; this
  /// file never picks one itself, it only forwards the caller's choice (or
  /// its absence) to `engine.MoveIntention`, which is the one thing that
  /// decides whether a given face is legal for this move at all.
  ///
  /// `docs/PROTOCOL.md` section 23 rule 3: an accepted move resets the
  /// seat's `timerSteps` to 0, and a rejected one changes nothing.
  /// [expireTurns] calls this same method for the timer and puts the count
  /// back one higher afterwards (rule 2).
  MoveResult move({
    required String code,
    required String seatToken,
    required int token,
    int? face,
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

    final engine.ApplyResult applied = engine.apply(
      game,
      engine.MoveIntention(seat.seat, token, face: face),
    );
    if (applied is engine.Rejected) {
      return MoveFailure(_mapEngineError(applied.error));
    }
    final engine.Applied appliedOk = applied as engine.Applied;
    room.game = appliedOk.state;
    _noteQueuedBanked(room, appliedOk.events);
    seat.timerSteps = 0;

    // docs/PROTOCOL.md section 21.1: the face this move spent. `face` is
    // the caller's own choice when it gave one -- the engine has already
    // rejected a `face` that was not in `game.queue`, so a successful apply
    // means this is exactly what it spent. Absent, the engine spent
    // `defaultFace(game)` (ENGINE_API.md section 10.4), read here off the
    // same pre-move `game` the engine itself read it from, never
    // recomputed from any legality rule of this file's own.
    final int? faceSpent =
        game.releaseOwed ? null : face ?? engine.defaultFace(game)!;
    // docs/PROTOCOL.md section 28 rule 2: a move made while a release was
    // owed spent the release, not a face. Read off the pre-move state, the
    // same one the engine read it from.
    final bool releaseSpent = game.releaseOwed;

    room.seq++;
    final int movedSeq = room.seq;

    final bool won = appliedOk.events.whereType<engine.GameWon>().isNotEmpty;

    // Section 30 rule 3 and rule 7: a taken shared release is followed by
    // `sixes_granted` when it granted anyone a six, ahead of the pass.
    int? sixesGrantedSeq;
    final List<engine.SixesBanked> banked =
        appliedOk.events.whereType<engine.SixesBanked>().toList();
    if (banked.isNotEmpty) {
      room.seq++;
      sixesGrantedSeq = room.seq;
    }
    if (game.releaseOffered) {
      room.grants.add(<String, Object?>{
        'k': room.rollCount,
        'seats': banked.isEmpty ? <int>[] : List<int>.of(banked.single.seats),
      });
    }

    int? gameOverSeq;
    String? verifyUrl;
    List<FreedSeat> freed = const <FreedSeat>[];
    int? seatFinishedSeq;
    int? turnPassedSeq;
    int? turnSeq;
    int? nextDeadlineMs;
    int? nextGraceMs;

    if (won) {
      final int winnerSeat =
          appliedOk.events.whereType<engine.GameWon>().first.seat;
      final _Concluded concluded = _concludeGame(room, winnerSeat);
      gameOverSeq = concluded.gameOverSeq;
      verifyUrl = concluded.verifyUrl;
      freed = concluded.freed;
    } else {
      // docs/PROTOCOL.md section 28 rule 3: a move that brought a seat's
      // fourth token home with the game going on is followed by
      // `seat_finished`, then by the `turn` for the next playing seat.
      if (appliedOk.events.whereType<engine.SeatFinished>().isNotEmpty) {
        room.seq++;
        seatFinishedSeq = room.seq;
      }
      // docs/PROTOCOL.md section 21.3 rule 4: a move that leaves only dead
      // faces in the queue gets its own `turn_passed` (reason
      // `no_legal_move`), ahead of the `turn` below, exactly as a `roll`
      // that passes the turn does. The engine's own `TurnEnded` event is
      // how it tells us which of the four non-winning rows this move
      // landed on; every one of them still ends with a `turn` frame
      // (section 12.2 and section 21.3 rule 4), so that part stays
      // unconditional.
      final bool turnEnded =
          appliedOk.events.whereType<engine.TurnEnded>().isNotEmpty;
      if (turnEnded) {
        room.seq++;
        turnPassedSeq = room.seq;
      }
      room.seq++;
      turnSeq = room.seq;
      _noteTurnOwner(room, seat.seat);
      nextGraceMs = _graceFor(room, appliedOk.events, seat.seat);
      nextDeadlineMs = _restartSegment(room, graceMs: nextGraceMs);
    }

    return MoveOk(
      room: room,
      events: appliedOk.events,
      movedSeq: movedSeq,
      face: faceSpent,
      release: releaseSpent,
      sixesGrantedSeq: sixesGrantedSeq,
      seatFinishedSeq: seatFinishedSeq,
      gameOverSeq: gameOverSeq,
      verifyUrl: verifyUrl,
      freed: freed,
      turnPassedSeq: turnPassedSeq,
      turnSeq: turnSeq,
      nextDeadlineMs: nextDeadlineMs,
      nextGraceMs: nextGraceMs,
    );
  }

  /// The one place a game is concluded, whichever intention concluded it (a
  /// move that won, or, under 2026-11, a retirement that left one playing
  /// seat). `docs/VERIFY.md` section 1: the record is written the moment the
  /// game is won, before the caller returns the result that carries
  /// `verify_url`, so a client that taps Verify the instant `game_over`
  /// arrives finds the record already there. A failed save (the store
  /// throws, or a record for this game_id somehow already exists) must never
  /// cost a player a finished game: it is logged to stderr, one line, and
  /// play continues exactly as if it had succeeded -- except for the link: a
  /// record that is not there must not be promised, so `verify_url` goes out
  /// empty and a client shows no "Check the rolls" (docs/PROTOCOL.md section
  /// 11.2).
  ///
  /// Section 28 rule 4 "At the end": once `game_over` has its `seq`, every
  /// retired seat is freed, in retirement order, one `seq` each. The record
  /// is built first, so it still lists every seat that played.
  _Concluded _concludeGame(Room room, int winnerSeat) {
    room.state = RoomState.finished;
    // buildVerifyRecord and jsonEncode run inside this same try: a throw
    // from either (a rollSeats index, a null gameId) is exactly as
    // recoverable here as a throw from verifyStore.save itself, and must
    // never escape and cost the players their finished game.
    bool recordSaved = false;
    try {
      final String recordJson = jsonEncode(
        buildVerifyRecord(
          room,
          winner: winnerSeat,
          finishedAt: _clock.now,
        ),
      );
      recordSaved = verifyStore.save(room.gameId!, recordJson);
      if (!recordSaved) {
        stderr.writeln(
          'verify_record_not_saved game_id=${room.gameId} reason=exists',
        );
      }
    } catch (error) {
      stderr.writeln(
        'verify_record_not_saved game_id=${room.gameId} '
        'reason=${logSafeError(error)}',
      );
    }
    room.seq++;
    final int gameOverSeq = room.seq;
    final String verifyUrl = recordSaved ? '$_verifyUrlBase${room.gameId}' : '';

    final List<FreedSeat> freed = <FreedSeat>[];
    if (room.isRuleset202611) {
      for (final int retiredIndex in room.game!.retired) {
        final Seat? gone = _seatAt(room, retiredIndex);
        if (gone == null) {
          continue;
        }
        room.seats = room.seats.where((Seat s) => !identical(s, gone)).toList();
        if (room.hostSeat == gone.seat) {
          room.hostSeat = room.seats.isEmpty
              ? -1
              : room.seats.map((Seat s) => s.seat).reduce(min);
        }
        room.seq++;
        freed.add(
          FreedSeat(seat: gone, seq: room.seq, hostSeat: room.hostSeat),
        );
      }
      _refreshIdleTracking(room);
    }
    return _Concluded(
      gameOverSeq: gameOverSeq,
      verifyUrl: verifyUrl,
      freed: freed,
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
    if (room.state == RoomState.finished) {
      return SetSeedFailure(ProtocolError.gameOver);
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
    if (room.state == RoomState.finished) {
      return SetPlayersFailure(ProtocolError.gameOver);
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
          via: ordered[i].via,
          barKey: ordered[i].barKey,
          bot: ordered[i].bot,
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

  /// `leave_room`, docs/PROTOCOL.md section 4, section 16.3 and section 18.
  LeaveResult leaveRoom({required String code, required String seatToken}) {
    final Room? room = _rooms[code];
    if (room == null) {
      return LeaveFailure(ProtocolError.noSuchRoom);
    }
    final Seat? seat = _findSeat(room, seatToken);
    if (seat == null) {
      return LeaveFailure(ProtocolError.badSeatToken);
    }
    if (room.state == RoomState.playing) {
      final engine.GameState? game = room.game;
      if (room.isRuleset202611 &&
          game != null &&
          game.phase != engine.GamePhase.finished &&
          _isPlayingSeat(game, seat.seat)) {
        // docs/PROTOCOL.md section 28 rule 4 "left": under 2026-11 a playing
        // seat that leaves is retired, not left to the timer. The leaver's
        // `seat_retired` replaces the `presence` of the branch below, so
        // there is one `seq` step for the whole call, taken by the retire.
        final RetireResult retired = _retire(room, seat, 'left');
        if (retired is RetireFailure) {
          return LeaveFailure(retired.error);
        }
        _reapIfOrphaned(room);
        return LeaveOk(
          room: room,
          seat: seat,
          retire: retired as RetireOk,
        );
      }
      // PLAYING: the seat stays in the game and is later played by the
      // timer, per docs/PROTOCOL.md section 3. The seat is simply marked
      // not connected. Under 2026-11 this is a finished or retired seat,
      // whose leaving changes nothing in the game (section 28 rule 3).
      seat.connected = false;
      seat.absentSince ??= _clock.now;
      _refreshIdleTracking(room);
    } else {
      // LOBBY and FINISHED: frees the seat, per docs/PROTOCOL.md section 3
      // and section 18 rules 1-3.
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
    }
    room.seq++;
    _reapIfOrphaned(room);
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
    final bool humanWasHere = _anyHumanConnected(room);
    seat.connected = connected;
    if (connected && !humanWasHere && seat.bot == null) {
      // Section 34 item 4: the pace of a waiting computer seat restarts here.
      room.humanBackAt = _clock.now;
    }
    // Section 28 rule 4: the absence count starts at the flip whose
    // `presence` the caller broadcasts next, and ends with the reconnect.
    seat.absentSince = connected ? null : _clock.now;
    _refreshIdleTracking(room);
    room.seq++;
    return true;
  }

  /// `kick` in PLAYING, `docs/PROTOCOL.md` section 33 item 8, replacing
  /// section 28 rule 4 "kicked": the host retires any playing seat, connected
  /// or not. [data] is the message's whole `d`, because the ladder puts
  /// `NOT_HOST` and the phase check ahead of the payload check, so the
  /// payload is only looked at here, in that order: room exists, seat
  /// authorised, `NOT_HOST`, state not PLAYING (`WRONG_PHASE`; the LOBBY kick
  /// is [kickLobby], section 31 item 6), `seat` an int 0..3 and no other key
  /// (`BAD_FIELD`), then the host's own seat, an empty seat, a finished seat
  /// or a retired seat (`ILLEGAL_MOVE`).
  ///
  /// On acceptance the seat is barred from the room as a lobby kick bars it
  /// (item 7), struck when item 6 says so, and its token is dead: no
  /// `resume` finds it again. It stays in `seats`, as any retired seat does,
  /// until `game_over` frees it.
  RetireResult kick({
    required String code,
    required String seatToken,
    required Map<String, Object?> data,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return RetireFailure(ProtocolError.noSuchRoom);
    }
    final Seat? caller = _findSeat(room, seatToken);
    if (caller == null) {
      return RetireFailure(ProtocolError.badSeatToken);
    }
    if (caller.seat != room.hostSeat) {
      return RetireFailure(ProtocolError.notHost);
    }
    final engine.GameState? game = room.game;
    if (room.state != RoomState.playing ||
        game == null ||
        game.phase == engine.GamePhase.finished) {
      return RetireFailure(ProtocolError.wrongPhase);
    }
    final Object? rawSeat = data['seat'];
    if (data.length != 1 || rawSeat is! int || rawSeat < 0 || rawSeat > 3) {
      return RetireFailure(ProtocolError.badField);
    }
    final Seat? target = _seatAt(room, rawSeat);
    if (target == null ||
        target.seat == room.hostSeat ||
        !_isPlayingSeat(game, rawSeat)) {
      return RetireFailure(ProtocolError.illegalMove);
    }
    final RetireResult retired = _retire(room, target, 'kicked');
    if (retired is! RetireOk) {
      return retired;
    }
    target.tokenDead = true;
    final String? key = target.barKey;
    if (key != null) {
      room.kickBars.add(key);
    }
    final BanInfo? ban = _kickStrike(room, target);
    _reapIfOrphaned(room);
    return RetireOk(
      room: retired.room,
      seat: retired.seat,
      reason: retired.reason,
      events: retired.events,
      after: retired.after,
      retiredSeq: retired.retiredSeq,
      hostSeat: retired.hostSeat,
      turnSeq: retired.turnSeq,
      nextDeadlineMs: retired.nextDeadlineMs,
      nextGraceMs: retired.nextGraceMs,
      gameOverSeq: retired.gameOverSeq,
      verifyUrl: retired.verifyUrl,
      freed: retired.freed,
      ban: ban,
      shownRoll: retired.shownRoll,
    );
  }

  /// The absent half of the turn timer's 1 s sweep, `docs/PROTOCOL.md`
  /// section 28 rule 4 "absent": retires every playing seat of a 2026-11
  /// game whose socket has been down for [_absentRetireAfter] without a
  /// break, measured on the injected clock from `Seat.absentSince`. Each
  /// retirement is handed to [publish] the moment it is made, in the order it
  /// was done, so its frames are built and sent before the next one changes
  /// the game. A seat whose socket went down longest ago goes first (ties by
  /// seat index); the game is looked at again after each retirement, since the
  /// last one before a win ends it.
  ///
  /// A room is isolated from the others: a throw while retiring in one room,
  /// or from [publish], goes to [onError] with the room code and the seat
  /// being retired (null when no seat was chosen yet), and the sweep goes on
  /// with the next room. What that room had already retired was published.
  ///
  /// A disconnected playing seat with no stamp (its flag was cleared by
  /// something other than [setConnected], [leaveRoom] or [resume]) is
  /// stamped now, so the count never starts late and never starts at all
  /// only by accident; a connected one has any stamp cleared.
  void retireAbsentSeats({
    required void Function(RetireOk retired) publish,
    required void Function(String code, int? seat, Object error, StackTrace st)
        onError,
  }) {
    final DateTime now = _clock.now;
    for (final Room room in _rooms.values.toList(growable: false)) {
      if (!room.isRuleset202611 || room.state != RoomState.playing) {
        continue;
      }
      int? dueSeat;
      try {
        while (true) {
          dueSeat = null;
          final engine.GameState? game = room.game;
          if (game == null || game.phase == engine.GamePhase.finished) {
            break;
          }
          Seat? due;
          for (final Seat seat in room.seats) {
            if (!_isPlayingSeat(game, seat.seat)) {
              continue;
            }
            if (seat.connected) {
              seat.absentSince = null;
              continue;
            }
            final DateTime since = seat.absentSince ??= now;
            if (now.difference(since) < _absentRetireAfter) {
              continue;
            }
            if (due == null || since.isBefore(due.absentSince!)) {
              due = seat;
            }
          }
          if (due == null) {
            break;
          }
          dueSeat = due.seat;
          final RetireResult result = _retire(room, due, 'absent');
          if (result is RetireOk) {
            publish(result);
          } else {
            // _retire refuses only a state it cannot apply. Say so, and stop
            // working on this room for this sweep rather than retry forever.
            // ignore: avoid_print
            print('retire skipped room=${room.code} seat=${due.seat} '
                'reason=absent error=${(result as RetireFailure).error.name}');
            break;
          }
        }
        _reapIfOrphaned(room);
      } catch (error, stack) {
        onError(room.code, dueSeat, error, stack);
      }
    }
  }

  /// A seat is playing (`docs/ENGINE_API.md` section 12.1) when it is in the
  /// game's seats and in neither `placings` nor `retired`.
  bool _isPlayingSeat(engine.GameState game, int seat) =>
      game.config.seats.contains(seat) &&
      !game.placings.contains(seat) &&
      !game.retired.contains(seat);

  /// The one place a seat is retired, whichever of the three reasons caused
  /// it. The caller has already decided that it may be: the seat is playing
  /// in a PLAYING 2026-11 room. Everything that follows is the engine's, read
  /// off its events (`docs/ENGINE_API.md` section 12.4), never derived from a
  /// state difference.
  RetireResult _retire(Room room, Seat seat, String reason) {
    final engine.GameState before = room.game!;
    // A retirement that would leave no playing seat has no `game_over` to
    // announce (the engine ends such a game without `GameWon`). A running
    // game always has two playing seats or more, so this is a guard, and it
    // refuses before anything is touched.
    final int playing =
        before.config.seats.where((int s) => _isPlayingSeat(before, s)).length;
    if (playing < 2) {
      return RetireFailure(ProtocolError.internal);
    }
    // docs/PROTOCOL.md section 35 item 3: a seat that was shown the face of
    // the roll it owes does not take that face away with it. The roll is
    // taken first, through [roll], exactly as [expireTurns] takes it (the
    // timer's step count included), so the next roll is a link no device has
    // seen. A roll never ends a game, so the retirement below always runs.
    RollOk? shownRoll;
    if (_holdsPre(room, seat)) {
      final int stepsBefore = seat.timerSteps;
      final RollResult taken = roll(code: room.code, seatToken: seat.seatToken);
      if (taken is RollFailure) {
        // Nothing was touched: the roll and the retirement are refused
        // together rather than retiring a seat over a face it was shown.
        return RetireFailure(taken.error);
      }
      seat.timerSteps = stepsBefore + 1;
      shownRoll = taken as RollOk;
    }
    final engine.GameState game = room.game!;
    final int previousTurnOwner = game.currentSeat;
    final engine.ApplyResult applied =
        engine.apply(game, engine.RetireIntention(seat.seat));
    if (applied is engine.Rejected) {
      return RetireFailure(_mapEngineError(applied.error));
    }
    final engine.Applied appliedOk = applied as engine.Applied;
    room.game = appliedOk.state;
    _noteQueuedBanked(room, appliedOk.events);
    if (reason == 'left' || reason == 'kicked') {
      // The leaver's socket is gone from the room (the wire layer detaches
      // it); the seat stays, as `connected: false`. No `presence` is sent for
      // it: `seat_retired` is the only frame, and takes the only `seq`.
      // Section 33 item 8: a kicked seat's socket, when it has one, is
      // detached the same way and holds no seat afterwards.
      seat.connected = false;
      seat.absentSince ??= _clock.now;
    }
    _refreshIdleTracking(room);
    room.seq++;
    final int retiredSeq = room.seq;

    if (room.hostSeat == seat.seat) {
      room.hostSeat = _hostAfterRetire(room);
    }
    final int hostSeat = room.hostSeat;

    final bool won = appliedOk.events.whereType<engine.GameWon>().isNotEmpty;
    final bool turnBegan =
        appliedOk.events.whereType<engine.TurnBegan>().isNotEmpty;

    int? turnSeq;
    int? nextDeadlineMs;
    int? nextGraceMs;
    int? gameOverSeq;
    String? verifyUrl;
    List<FreedSeat> freed = const <FreedSeat>[];
    if (won) {
      final _Concluded concluded = _concludeGame(
        room,
        appliedOk.events.whereType<engine.GameWon>().first.seat,
      );
      gameOverSeq = concluded.gameOverSeq;
      verifyUrl = concluded.verifyUrl;
      freed = concluded.freed;
    } else if (turnBegan) {
      room.seq++;
      turnSeq = room.seq;
      _noteTurnOwner(room, previousTurnOwner);
      nextGraceMs = _graceFor(room, appliedOk.events, previousTurnOwner);
      nextDeadlineMs = _restartSegment(room, graceMs: nextGraceMs);
    }

    return RetireOk(
      room: room,
      seat: seat,
      reason: reason,
      events: appliedOk.events,
      after: appliedOk.state,
      retiredSeq: retiredSeq,
      hostSeat: hostSeat,
      turnSeq: turnSeq,
      nextDeadlineMs: nextDeadlineMs,
      nextGraceMs: nextGraceMs,
      gameOverSeq: gameOverSeq,
      verifyUrl: verifyUrl,
      freed: freed,
      shownRoll: shownRoll,
    );
  }

  /// `docs/PROTOCOL.md` section 28 rule 4 "The host": the lowest seat that is
  /// still playing, else the lowest seat still connected, else -1.
  int _hostAfterRetire(Room room) {
    final engine.GameState game = room.game!;
    final List<int> playing = <int>[
      for (final Seat s in room.seats)
        if (_isPlayingSeat(game, s.seat)) s.seat,
    ]..sort();
    if (playing.isNotEmpty) {
      return playing.first;
    }
    final List<int> connected = <int>[
      for (final Seat s in room.seats)
        if (s.connected) s.seat,
    ]..sort();
    return connected.isEmpty ? -1 : connected.first;
  }

  /// `play_computer`, section 34 item 2. [players] is 2 or 4 and [clientSeed],
  /// when given, passes section 11.2's shape; anything else is `BAD_FIELD`
  /// before a room exists. The room is made as `create_room` makes it (not
  /// open, default rules), the caller seated as host, every other seat taken
  /// by a computer seat, and the game started. Every seat's seed is fixed
  /// after the `room` of the full LOBBY, in ascending seat order: the host's
  /// own when it gave one, a server-drawn seed for every other seat.
  PlayComputerResult playComputer({
    required String name,
    required int players,
    required Object? clientSeed,
    String? install,
    String ip = '',
  }) {
    if (players != 2 && players != 4) {
      return PlayComputerFailure(ProtocolError.badField);
    }
    String? hostSeed;
    if (clientSeed != null) {
      hostSeed = _validClientSeed(clientSeed);
      if (hostSeed == null) {
        return PlayComputerFailure(ProtocolError.badField);
      }
    }
    final CreateResult created = createRoom(
      name: name,
      players: players,
      rules: const RulesConfig(),
      install: install,
      ip: ip,
    );
    if (created is! CreateOk) {
      return PlayComputerFailure((created as CreateFailure).error);
    }
    final Room room = created.room;
    final Seat host = created.seat;
    _seatComputers(room, seedAtOnce: false);
    final Map<String, Object?> snapshot =
        buildRoomSnapshot(room, now: _clock.now, forHost: true);
    final List<SeededSeat> seeds = <SeededSeat>[];
    for (final Seat seat in room.seats) {
      if (seat.seat == host.seat && hostSeed != null) {
        seat.clientSeed = hostSeed;
        seat.seedOrigin = 'player';
        room.seq++;
        seeds.add(SeededSeat(seat: seat, seq: room.seq));
      } else {
        seeds.add(_seedFromServer(room, seat));
      }
    }
    final StartOk start = _beginGame(room);
    return PlayComputerOk(
      room: room,
      seat: host,
      snapshot: snapshot,
      seeds: seeds,
      start: start,
    );
  }

  /// `fill_computer`, section 34 item 3. [data] is the message's whole `d`.
  /// The ladder: room, seat authorised, `NOT_HOST`, LOBBY (`WRONG_PHASE`), any
  /// payload key (`BAD_FIELD`), then `WRONG_PHASE` unless the room is open,
  /// has a free seat and [fillWaitMs] have passed. On acceptance the room is
  /// no longer open, its open knocks close `full`, each free seat (lowest
  /// first) takes a computer seat with its server seed, and the game starts
  /// as `start_game` starts it.
  FillComputerResult fillComputer({
    required String code,
    required String seatToken,
    required Map<String, Object?> data,
  }) {
    final Room? room = _rooms[code];
    if (room == null) {
      return FillComputerFailure(ProtocolError.noSuchRoom);
    }
    final Seat? caller = _findSeat(room, seatToken);
    if (caller == null) {
      return FillComputerFailure(ProtocolError.badSeatToken);
    }
    if (caller.seat != room.hostSeat) {
      return FillComputerFailure(ProtocolError.notHost);
    }
    if (room.state != RoomState.lobby) {
      return FillComputerFailure(ProtocolError.wrongPhase);
    }
    if (data.isNotEmpty) {
      return FillComputerFailure(ProtocolError.badField);
    }
    if (!room.open ||
        _freeSeats(room).isEmpty ||
        fillMsLeft(room, _clock.now) > 0) {
      return FillComputerFailure(ProtocolError.wrongPhase);
    }
    room.open = false;
    final List<KnockEvent> knockEvents = _closeAllKnocksFull(room);
    final List<ComputerJoin> joins = _seatComputers(room, seedAtOnce: true);
    final StartResult started = room.rematch != null
        ? _startRematchFromHost(room, room.rematch!)
        : _beginGame(room);
    if (started is StartFailure) {
      return FillComputerFailure(started.error);
    }
    return FillComputerOk(
      room: room,
      knockEvents: knockEvents,
      joins: joins,
      start: started as StartOk,
    );
  }

  /// Takes a computer seat for every free seat of [room], lowest first, each
  /// with a character drawn without replacement from the room's random source
  /// among those not already in the room. With [seedAtOnce] each seat's
  /// server seed is fixed right after its join (section 34 item 1); without,
  /// the caller fixes the seeds later. A seat joining a rematch LOBBY has
  /// accepted the rematch already.
  List<ComputerJoin> _seatComputers(Room room, {required bool seedAtOnce}) {
    final List<int> free = _freeSeats(room);
    final Set<int> taken = <int>{
      for (final Seat seat in room.seats)
        if (seat.bot != null) seat.bot!,
    };
    final List<int> bots = drawComputerCharacters(
        _computerRandomFor(room), free.length,
        taken: taken);
    final List<ComputerJoin> joins = <ComputerJoin>[];
    for (int i = 0; i < free.length; i++) {
      final Seat seat = Seat(
        seat: free[i],
        name: computerName(bots[i]),
        seatToken: generateSeatToken(_secure),
        connected: true,
        via: 'bot',
        bot: bots[i],
      );
      room.seats = <Seat>[...room.seats, seat]
        ..sort((Seat a, Seat b) => a.seat.compareTo(b.seat));
      room.seq++;
      final int joinedSeq = room.seq;
      final Rematch? current = room.rematch;
      if (current != null) {
        room.rematch = Rematch(
          by: current.by,
          ready: <int>[...current.ready, seat.seat]..sort(),
        );
      }
      joins.add(
        ComputerJoin(
          seat: seat,
          joinedSeq: joinedSeq,
          seeded: seedAtOnce ? _seedFromServer(room, seat) : null,
        ),
      );
    }
    _refreshIdleTracking(room);
    return joins;
  }

  /// Fixes [seat]'s seed with a server-drawn one, one `seq` step.
  SeededSeat _seedFromServer(Room room, Seat seat) {
    seat.clientSeed = hexEncode(_drawBytes(_serverSeedBytes));
    seat.seedOrigin = 'server';
    room.seq++;
    return SeededSeat(seat: seat, seq: room.seq);
  }

  Random _computerRandomFor(Room room) =>
      room.computerRandom ??= _computerRandomFactory();

  bool _anyHumanConnected(Room room) =>
      room.seats.any((Seat s) => s.bot == null && s.connected);

  /// Section 34 item 6: every computer seat of the rematch LOBBY [room] that
  /// has not accepted yet accepts now, in seat order, one `seq` step and one
  /// `room` each. Called by the wire layer after it has sent the frames of the
  /// human's own `rematch`, so those carry the state the human left. Empty
  /// outside a rematch LOBBY.
  List<ComputerAccept> acceptComputerSeats(Room room) {
    final Rematch? current = room.rematch;
    if (room.state != RoomState.lobby || current == null) {
      return const <ComputerAccept>[];
    }
    final List<ComputerAccept> accepts = <ComputerAccept>[];
    for (final Seat seat in room.seats) {
      final Rematch now = room.rematch!;
      if (seat.bot == null || now.ready.contains(seat.seat)) {
        continue;
      }
      room.rematch = Rematch(
        by: now.by,
        ready: <int>[...now.ready, seat.seat]..sort(),
      );
      room.seq++;
      accepts.add(
        ComputerAccept(
          seat: seat,
          seq: room.seq,
          snapshot: buildRoomSnapshot(room, now: _clock.now),
        ),
      );
    }
    return accepts;
  }

  /// Section 34 item 4, the sweep the binary runs every 100 ms on the real
  /// clock and a test calls after moving a fake one. For each PLAYING room
  /// whose seat on turn is a computer seat it schedules the decision owed (a
  /// pace drawn from the room's random source, counted from the later of the
  /// frame that left the seat to act, the end of a grace and the moment a
  /// human socket last came back to a room with none), and takes the action
  /// once the pace has run out on the injected clock. At most one action per
  /// room per call; every room is looked at, in creation order. Computer seats
  /// act only while a human socket is connected to the room. Each step is
  /// handed to [onComputerAction] as it is taken, and returned.
  List<ComputerStep> runComputerSeatsOnce() {
    final List<ComputerStep> steps = <ComputerStep>[];
    final DateTime now = _clock.now;
    for (final Room room in _rooms.values.toList(growable: false)) {
      ComputerStep? step;
      try {
        step = _computerStepFor(room, now);
      } catch (error, stack) {
        // ignore: avoid_print
        print('room=${room.code} type=computer id=- seat=- '
            'outcome=computer_step_failed error=${logSafeError(error)}\n$stack');
        continue;
      }
      if (step == null) {
        continue;
      }
      steps.add(step);
      final void Function(ComputerStep step)? notify = onComputerAction;
      if (notify == null) {
        continue;
      }
      try {
        notify(step);
      } catch (error, stack) {
        // ignore: avoid_print
        print('room=${room.code} type=computer id=- seat=${step.seat} '
            'outcome=computer_publish_failed error=${logSafeError(error)}\n$stack');
      }
    }
    return steps;
  }

  ComputerStep? _computerStepFor(Room room, DateTime now) {
    if (room.state != RoomState.playing || !room.hasComputerSeat) {
      return null;
    }
    final engine.GameState? game = room.game;
    if (game == null || game.phase == engine.GamePhase.finished) {
      return null;
    }
    final Seat? seat = _seatAt(room, game.currentSeat);
    final int? bot = seat?.bot;
    if (seat == null || bot == null) {
      room.computerBase = null;
      room.computerDueAt = null;
      return null;
    }
    // Waiting, not acting: with no human socket here the pace restarts from
    // the reconnect, so nothing is scheduled meanwhile.
    final DateTime? segmentStart = room.turnSegmentStartedAt;
    if (segmentStart == null || !_anyHumanConnected(room)) {
      room.computerBase = null;
      room.computerDueAt = null;
      return null;
    }
    DateTime base = segmentStart;
    final DateTime? graceEnd = room.turnGraceEndsAt;
    if (graceEnd != null && graceEnd.isAfter(base)) {
      base = graceEnd;
    }
    final DateTime? back = room.humanBackAt;
    if (back != null && back.isAfter(base)) {
      base = back;
    }
    DateTime? due = room.computerDueAt;
    if (due == null || room.computerBase != base) {
      due = base.add(
        Duration(milliseconds: drawComputerPaceMs(_computerRandomFor(room))),
      );
      room.computerBase = base;
      room.computerDueAt = due;
    }
    if (now.isBefore(due)) {
      return null;
    }
    final ComputerAction? action = decideComputerAction(game);
    if (action == null) {
      room.computerBase = null;
      room.computerDueAt = null;
      return null;
    }
    room.computerBase = null;
    room.computerDueAt = null;
    switch (action) {
      case ComputerRoll():
        final RollResult result =
            roll(code: room.code, seatToken: seat.seatToken);
        if (result is! RollOk) {
          _logComputerRefused(
              room, seat, 'roll', (result as RollFailure).error);
          return null;
        }
        return ComputerStep(
          code: room.code,
          seat: seat.seat,
          bot: bot,
          roll: result,
        );
      case ComputerMove():
        final MoveResult result = move(
          code: room.code,
          seatToken: seat.seatToken,
          token: action.token,
          face: action.face,
        );
        if (result is! MoveOk) {
          _logComputerRefused(
              room, seat, 'move', (result as MoveFailure).error);
          return null;
        }
        return ComputerStep(
          code: room.code,
          seat: seat.seat,
          bot: bot,
          move: result,
        );
    }
  }

  void _logComputerRefused(
    Room room,
    Seat seat,
    String type,
    ProtocolError error,
  ) {
    // ignore: avoid_print
    print('room=${room.code} type=$type id=computer seat=${seat.seat} '
        'outcome=computer_refused error=${error.name}');
  }

  /// Section 34 item 6: a room with a computer seat and no human seat left
  /// (every human left, was freed or was retired) is reaped at once. A human
  /// seat whose socket is merely down still counts: a seat survives its
  /// socket, and the idle rule reaps that room after ten minutes.
  void _reapIfOrphaned(Room room) {
    if (!room.hasComputerSeat || _hasLiveHuman(room)) {
      return;
    }
    if (_rooms[room.code] == null) {
      return;
    }
    _removeRoom(room.code, _clock.now);
  }

  bool _hasLiveHuman(Room room) {
    final engine.GameState? game = room.game;
    return room.seats.any(
      (Seat s) =>
          s.bot == null &&
          !s.tokenDead &&
          !(game != null && game.retired.contains(s.seat)),
    );
  }

  /// Removes every room one of whose state's rules says it is over, and
  /// returns how many were removed (`docs/PROTOCOL.md` section 3, as amended
  /// by C-451):
  ///
  /// - LOBBY: no connected seat for [_idleTimeout], or [_lobbyLifetime] (10
  ///   minutes, section 37) since `Room.lifetimeStartedAt` even with a seat
  ///   connected. A room closed by the lifetime is recorded for
  ///   [drainClosedLobbies] so the wire layer can tell its sockets.
  /// - PLAYING: no connected seat for [_idleTimeout]. No lifetime shorter
  ///   than [_maxRoomLifetime] applies, and the turn timer playing for
  ///   absent seats is not a connection.
  /// - FINISHED: [_finishedTimeout] after the registry first observes it
  ///   FINISHED. The stamp belongs to one finished game: a room seen in any
  ///   other state loses it, so a rematch's game gets its own.
  /// - Any state but LOBBY: [_maxRoomLifetime] since
  ///   `Room.lifetimeStartedAt`, whatever else is true.
  int reap() {
    final DateTime now = _clock.now;
    final List<String> toRemove = <String>[];
    for (final Room room in _rooms.values) {
      final Duration lifetime = now.difference(room.lifetimeStartedAt);
      switch (room.state) {
        case RoomState.lobby:
          _finishedSince.remove(room.code);
          final DateTime? idleSince = _idleSince[room.code];
          final bool idleOut =
              idleSince != null && now.difference(idleSince) >= _idleTimeout;
          if (idleOut) {
            // Section 37 item 2: the idle rule goes first and is silent.
            toRemove.add(room.code);
          } else if (lifetime >= _lobbyLifetime) {
            _closedLobbies.add(ClosedLobby(
              code: room.code,
              seatTokens: <String>[
                for (final Seat s in room.seats)
                  if (s.connected) s.seatToken,
              ],
            ));
            toRemove.add(room.code);
          }
        case RoomState.playing:
          _finishedSince.remove(room.code);
          final DateTime? idleSince = _idleSince[room.code];
          if (lifetime >= _maxRoomLifetime ||
              (idleSince != null &&
                  now.difference(idleSince) >= _idleTimeout)) {
            toRemove.add(room.code);
          }
        case RoomState.finished:
          final DateTime finishedSince =
              _finishedSince.putIfAbsent(room.code, () => now);
          if (lifetime >= _maxRoomLifetime ||
              now.difference(finishedSince) >= _finishedTimeout) {
            toRemove.add(room.code);
          }
      }
    }
    for (final String code in toRemove) {
      _removeRoom(code, now);
    }
    _resting.removeWhere(
      (String code, DateTime expiry) => !now.isBefore(expiry),
    );
    // docs/VERIFY.md section 3: retention is enforced here, on the same
    // housekeeping cadence as everything else this method already sweeps,
    // rather than on a timer of its own.
    verifyStore.purgeOlderThan(now.subtract(verifyRetention));
    final void Function(List<Knock> knocks)? notify = onKnocksReaped;
    if (notify != null && _reapedKnocks.isNotEmpty) {
      notify(drainReapedKnocks());
    }
    final void Function(List<ClosedLobby> closed)? announce = onLobbiesClosed;
    if (announce != null && _closedLobbies.isNotEmpty) {
      announce(drainClosedLobbies());
    }
    return toRemove.length;
  }

  /// Drops the room [code] and everything the registry keeps about it, and
  /// rests its code (section 32 item 3). Open knocks go to
  /// [drainReapedKnocks].
  void _removeRoom(String code, DateTime now) {
    final Room? gone = _rooms.remove(code);
    if (gone != null) {
      _roomsByLink.remove(gone.linkId);
      _reapedKnocks.addAll(gone.knocks);
      gone.knocks.clear();
    }
    _idleSince.remove(code);
    _finishedSince.remove(code);
    _identities.remove(code);
    _hostKeys.remove(code);
    _resting[code] = now.add(_codeRest);
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
      if (seat != null && seat.bot != null) {
        // Section 34 item 4: the turn timer never acts for a computer seat;
        // the computer sweep does, on its own pace.
        continue;
      }
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
        final int stepsBefore = seat.timerSteps;
        final RollResult result =
            roll(code: room.code, seatToken: seat.seatToken);
        if (result is RollOk) {
          // docs/PROTOCOL.md section 23 rule 2: the timer's own step adds
          // one; roll() reset the count as it does for a client's roll.
          seat.timerSteps = stepsBefore + 1;
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
        final int stepsBefore = seat.timerSteps;
        final MoveResult result = move(
          code: room.code,
          seatToken: seat.seatToken,
          token: legal.first,
        );
        if (result is MoveOk) {
          // Section 23 rule 2, as for the roll above.
          seat.timerSteps = stepsBefore + 1;
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
  /// this seat gets a fresh turn budget, its own under section 26 rule 3,
  /// rather than the sweep
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

  final List<ClosedLobby> _closedLobbies = <ClosedLobby>[];

  /// The lobbies [reap] closed for outliving [_lobbyLifetime] since the last
  /// call, oldest first, and forgets them. The wire layer announces each
  /// with `room_closed` (section 37 item 2).
  List<ClosedLobby> drainClosedLobbies() {
    final List<ClosedLobby> out = List<ClosedLobby>.of(_closedLobbies);
    _closedLobbies.clear();
    return out;
  }

  /// Rooms in LOBBY (section 37 item 4).
  int get lobbyRoomCount => _countIn(RoomState.lobby);

  /// Rooms in PLAYING.
  int get playingRoomCount => _countIn(RoomState.playing);

  /// Rooms in FINISHED.
  int get finishedRoomCount => _countIn(RoomState.finished);

  int _countIn(RoomState state) =>
      _rooms.values.where((Room r) => r.state == state).length;

  /// Whole seconds since `lifetimeStartedAt` of the oldest LOBBY room, 0
  /// when there is none.
  int get oldestLobbyAgeSeconds {
    final DateTime now = _clock.now;
    int oldest = 0;
    for (final Room room in _rooms.values) {
      if (room.state != RoomState.lobby) {
        continue;
      }
      final int age = now.difference(room.lifetimeStartedAt).inSeconds;
      if (age > oldest) {
        oldest = age;
      }
    }
    return oldest;
  }

  void _refreshIdleTracking(Room room) {
    // Section 34 item 4: a computer seat is always connected and holds no
    // socket, so only the human seats say whether the room is idle.
    final bool idle =
        room.seats.every((Seat s) => s.bot != null || !s.connected);
    if (idle) {
      _idleSince.putIfAbsent(room.code, () => _clock.now);
    } else {
      _idleSince.remove(room.code);
    }
  }

  /// `docs/PROTOCOL.md` section 26 rule 2, the one place it is applied.
  /// Called after the engine has moved the turn and before the new segment
  /// is started: [previous] is the seat that held it, or null when a game
  /// is just starting. When the turn did change hands, [previous] becomes
  /// away if it was not connected for any of the turn that just ended, and
  /// the seat now on turn has its connection noted as its turn begins. The
  /// same seat acting again (an extra roll, a six, faces left) is still the
  /// same turn and touches nothing.
  void _noteTurnOwner(Room room, int? previous) {
    final int current = room.game!.currentSeat;
    if (previous == current) {
      return;
    }
    if (previous != null) {
      final Seat? ended = _seatAt(room, previous);
      if (ended != null && !ended.connectedThisTurn) {
        ended.away = true;
      }
    }
    final Seat? began = _seatAt(room, current);
    if (began != null) {
      began.connectedThisTurn = began.connected;
    }
  }

  /// `docs/PROTOCOL.md` section 6 and section 26 rule 3: restarts the
  /// current turn segment on the registry's own injected clock, with the
  /// budget of the seat it is for, and returns the freshly restored
  /// `deadline_ms` (that budget, since the elapsed time from a segment that
  /// starts this instant is zero, and a grace delays the count, never the
  /// value). [graceMs], section 29, is the grace the segment starts with:
  /// its budget counts from `now + graceMs`. Null starts a segment with no
  /// grace.
  int _restartSegment(Room room, {int? graceMs}) {
    final engine.GameState? game = room.game;
    final Seat? onTurn = game == null ? null : _seatAt(room, game.currentSeat);
    room.turnSegmentMs = onTurn != null && onTurn.away
        ? _awaySegmentMs
        : room.rules.turnSeconds * 1000;
    final DateTime now = _clock.now;
    room.turnSegmentStartedAt = now;
    room.turnGraceEndsAt =
        graceMs == null ? null : now.add(Duration(milliseconds: graceMs));
    return room.turnSegmentMs;
  }

  /// Section 29 rules 1 and 2: the grace of the `turn` frame the step that
  /// produced [events] ends with, for the seat [actor] whose turn it ended.
  /// Null under 2026-10, and whenever that `turn` is not a pass.
  int? _graceFor(Room room, List<engine.GameEvent> events, int actor) =>
      room.isRuleset202611 ? graceForStep(events, actor) : null;

  /// `docs/PROTOCOL.md` section 6: `max(0, budget - elapsed)` for the
  /// segment already running, without restarting it, where the budget is the
  /// one that segment started with (`Room.turnSegmentMs`) and elapsed counts
  /// from the end of its grace (section 29 rule 3). Zero if no segment has
  /// ever started, which should not happen once a game exists but is not
  /// something this method should throw over.
  int _remainingSegmentMs(Room room) => room.segmentRemainingMs(_clock.now);

  /// The live seat holding [seatToken]. Section 33 item 8: the token of a
  /// seat kicked in PLAYING is dead, so that seat is never found by it.
  Seat? _findSeat(Room room, String seatToken) {
    for (final Seat seat in room.seats) {
      if (seat.seatToken == seatToken && !seat.tokenDead) {
        return seat;
      }
    }
    return null;
  }

  String _generateUniqueCode() {
    // Section 32 item 2: the lowest code in order that no live room holds and
    // that is not resting.
    for (int index = 0;; index++) {
      final String candidate = roomCodeForIndex(index);
      if (_rooms.containsKey(candidate)) {
        continue;
      }
      final DateTime? restingUntil = _resting[candidate];
      if (restingUntil != null && _clock.now.isBefore(restingUntil)) {
        continue;
      }
      return candidate;
    }
  }

  /// The knocks whose room was reaped since the last call, each to be closed
  /// `timeout` towards its knocker; nobody is barred (section 31 item 12 b).
  List<Knock> drainReapedKnocks() {
    final List<Knock> out = List<Knock>.of(_reapedKnocks);
    _reapedKnocks.clear();
    return out;
  }

  String _generateUniqueLinkId() {
    final int nowSeconds = _clock.now.millisecondsSinceEpoch ~/ 1000;
    _issuedLinkIds.removeWhere((String id) {
      final int? issued = int.tryParse(id.split('-').first, radix: 36);
      return issued != null && issued < nowSeconds - 2;
    });
    for (int attempt = 0; attempt < 1000; attempt++) {
      final String candidate = generateLinkId(_linkRandom, _clock.now);
      if (_issuedLinkIds.add(candidate)) {
        return candidate;
      }
    }
    throw StateError('could not draw an unused link id');
  }

  /// A knock id: 16 characters of `[a-z0-9]`, unique among [room]'s open
  /// knocks.
  String _generateKnockId(Room room) {
    while (true) {
      final StringBuffer buffer = StringBuffer();
      for (int i = 0; i < 16; i++) {
        buffer
            .write(linkIdAlphabet[_linkRandom.nextInt(linkIdAlphabet.length)]);
      }
      final String candidate = buffer.toString();
      if (!room.knocks.any((Knock k) => k.id == candidate)) {
        return candidate;
      }
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

String _checkedRuleset(String value) {
  if (!isKnownRuleset(value)) {
    throw ArgumentError.value(
      value,
      'ruleset',
      'must be $ruleset202610, $ruleset202611 or $ruleset202612',
    );
  }
  return value;
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

/// What the strike ladder holds about one socket that joined or knocked:
/// keyed hashes only (section 32 item 11). [ipKey] is empty when the socket's
/// IP was not known.
class _StrikeIdentity {
  _StrikeIdentity({required this.installKey, required this.ipKey});
  final String? installKey;
  final String ipKey;
}

/// What [RoomRegistry]'s `_drawRoll` produced: the link it read, and either
/// the engine's step with the payload built from it, or the engine's refusal.
class _RollDraw {
  _RollDraw({
    required this.k,
    required this.reveal,
    required engine.Applied this.applied,
    required this.release,
    required Map<String, Object?> this.payload,
  }) : refused = null;

  _RollDraw.refused({
    required this.k,
    required this.reveal,
    required engine.EngineError this.refused,
  })  : applied = null,
        release = false,
        payload = null;

  final int k;
  final String reveal;
  final engine.Applied? applied;
  final bool release;
  final Map<String, Object?>? payload;
  final engine.EngineError? refused;
}

/// `docs/PROTOCOL.md` section 35 item 1: the `pre` owed to the socket holding
/// [seatToken] in room [code], or null when it is owed none. It is owed one
/// exactly when the room is PLAYING, that seat is a human seat on turn and the
/// game awaits its roll: the payload of the `rolled` its `roll` would produce
/// now, from `_drawRoll` without committing. Pure: nothing on the room, the
/// seat, the roll counter, the chain or the engine is written, so two calls in
/// a row give the same map. What was handed out is recorded separately, by
/// [recordPreSent], once a copy carrying it has gone to an open socket.
///
/// A top-level function of this library, not a member of [RoomRegistry], so
/// that it reaches the registry's private state and stays out of the
/// package's public surface (`lib/ludo_server.dart` exports this file with
/// `show`).
Map<String, Object?>? peekPre(
  RoomRegistry registry, {
  required String code,
  required String seatToken,
}) {
  final Room? room = registry._rooms[code];
  if (room == null || room.state != RoomState.playing) {
    return null;
  }
  final Seat? seat = registry._findSeat(room, seatToken);
  if (seat == null || seat.bot != null) {
    return null;
  }
  final engine.GameState? game = room.game;
  if (game == null ||
      game.phase != engine.GamePhase.awaitRoll ||
      game.currentSeat != seat.seat) {
    return null;
  }
  if (room.rollCount + 1 > room.chain.chainLength) {
    // `roll` refuses this roll with INTERNAL before reading a link, so there
    // is no face to show either.
    return null;
  }
  return registry._drawRoll(room, seat, commit: false).payload;
}

/// Section 35 item 3: records that the seat holding [seatToken] in room
/// [code] was sent the `pre` of roll [k] of the current game. Called by the
/// socket layer only after a copy carrying that `pre` was handed to an open
/// socket. This record is how a retirement of that seat knows to take the
/// roll first. Writes nothing unless [k] is still the roll that seat owes.
/// Kept out of the package's public surface like [peekPre].
void recordPreSent(
  RoomRegistry registry, {
  required String code,
  required String seatToken,
  required int k,
}) {
  final Room? room = registry._rooms[code];
  if (room == null || room.gameId == null || k != room.rollCount + 1) {
    return;
  }
  final Seat? seat = registry._findSeat(room, seatToken);
  if (seat == null || seat.bot != null) {
    return;
  }
  room.preGameId = room.gameId;
  room.preSeat = seat.seat;
  room.preK = k;
}

/// A lobby [RoomRegistry.reap] closed for outliving its lifetime: its code
/// and the seat tokens that had a connected socket when it went.
class ClosedLobby {
  const ClosedLobby({required this.code, required this.seatTokens});

  final String code;
  final List<String> seatTokens;
}

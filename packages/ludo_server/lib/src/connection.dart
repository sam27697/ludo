// One WebSocket, from upgrade to close. This is where the section 7
// validation ladder actually runs, in the order the spec fixes it:
//
//     size, JSON parse, v, t, id shape, rate limit,
//     room exists, seat authorised, phase correct, payload fields,
//     rule legality
//
// The first five steps are generic and happen once per frame, in
// `handleFrame` below, before any message type is even known beyond `t`.
// The rest are per message type, in the `_handleXxx` methods, and mostly
// delegate to `RoomRegistry`, which already enforces room-exists,
// seat-authorised and phase-correct in that order internally for every
// call it exposes -- that ordering is the registry's own and this file does
// not re-derive it, only consumes the result.
//
// One nuance worth writing down, because the ladder text puts "payload
// fields" *after* "room exists": a `code` or `seat_token` whose JSON type is
// wrong (not a string at all) is rejected immediately as `BAD_FIELD`, because
// there is no way to attempt a room lookup with a non-string value. A `code`
// that *is* a string but the wrong shape (wrong length, a character outside
// the alphabet) is deliberately **not** pre-validated here: it is handed to
// the registry exactly as received, so a malformed code and a well-formed
// but nonexistent code both come back `NO_SUCH_ROOM`. That is the whole
// point of putting rate limiting and room lookup ahead of payload
// validation in the first place -- a client fuzzing codes must not be able
// to tell "badly shaped" from "shaped fine but nobody's home".
//
// `start_game`, `set_players`, `set_seed`, `leave_room`, `roll` and `move`
// carry no room code and no seat token in their payload; the socket's own
// stored identity (set on a successful `create_room`, `join_room` or
// `resume`) is the only source of either. A connection with no stored
// identity gets `BAD_SEAT_TOKEN` for any of these -- the table has no
// separate code for "this socket is not in a room at all", and a socket
// with no seat is exactly a socket for which no seat token can be
// authorised.
//
// `set_seed` is the one message here whose own ladder, `docs/PROTOCOL.md`
// section 11.2, is not room-exists / seat-authorised / phase-correct in the
// usual order: room existence still runs first, but phase then overtakes
// seat authorisation. `_handleSetSeed` below still resolves a socket with no
// stored identity at all as `BAD_SEAT_TOKEN` first, because there is no room
// to look up in that case; once identity exists, a room that does not exist
// or has been reaped answers `NO_SUCH_ROOM`, and only once a live room is
// found does phase overtake seat authorisation exactly as section 11.2
// orders it.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'clock.dart';
import 'envelope.dart';
import 'rate_limit.dart';
import 'registry.dart';
import 'room.dart';
import 'snapshot.dart';

/// `docs/PROTOCOL.md` section 7.1: the four close codes, and the only four
/// this file ever passes to a socket close. The `web_socket` package
/// underneath `web_socket_channel` accepts only 1000 or 3000-4999
/// (`checkCloseCode`); the RFC 6455 application codes this file used to send
/// -- 1008 and 1009 -- are correct on the wire and outside that range, so the
/// library rejected them, and it did so from deep inside a callback nothing
/// here was holding a future for: `channel.sink.close()` completed normally
/// regardless, and the socket was simply never closed. These four are inside
/// the accepted range and each is tied to exactly one call site below; no
/// other code is invented at a call site for any other reason.
const int closeCodeTooLarge = 4001;
const int closeCodeProtocolVersion = 4002;
const int closeCodeRateLimited = 4003;
const int closeCodeSeatTakenOver = 4004;

/// The exact rule `package:web_socket`'s `checkCloseCode` enforces
/// (`package:web_socket/src/utils.dart`), duplicated here so [Connection]
/// can apply it to itself before ever calling into that library. See the
/// long comment on [Connection.close] for why duplicating it, rather than
/// observing the library's own reaction to a bad call, is the only way this
/// file can see a close fail.
bool _isValidCloseCode(int code) =>
    code == 1000 || (code >= 3000 && code <= 4999);

/// The exact rule `package:web_socket`'s `checkCloseReason` enforces: at
/// most 123 bytes once UTF-8 encoded, the limit RFC 6455 puts on the close
/// frame's reason field.
bool _isValidCloseReason(String reason) => utf8.encode(reason).length <= 123;

/// What a `Connection` needs from the rest of the server to do anything that
/// crosses socket boundaries: registering itself against a room so a
/// broadcast can find it, and sending a broadcast to everyone (or everyone
/// else) currently attached to a room.
abstract class RoomHub {
  /// Adds [conn] to the set of sockets attached to [code]. If another
  /// connection is already attached to that room holding the same seat
  /// token, it is removed and returned -- the takeover of
  /// `docs/PROTOCOL.md` section 8 point 6, "a second socket presenting a
  /// valid seat_token for a seat that is already connected takes over the
  /// seat". Returns null when there was nothing to take over.
  Connection? attach({required String code, required Connection conn});

  /// Removes [conn] from whichever room it was attached to, if any. Safe to
  /// call on a connection that was never attached, or already detached.
  void detach(Connection conn);

  /// Sends one push to every socket currently attached to [code], except
  /// [exceptConn] if given.
  void broadcast({
    required String code,
    required String type,
    required Map<String, Object?> data,
    Connection? exceptConn,
  });
}

/// One WebSocket connection and the seat it may or may not currently hold.
/// A seat survives its socket (`docs/PROTOCOL.md` section 8): closing this
/// connection never calls `leaveRoom`, only `setConnected(..., false)`.
class Connection {
  Connection({
    required this.channel,
    required this.ip,
    required this.registry,
    required this.rateLimiter,
    required this.clock,
    required this.hub,
    required this.random,
  });

  final WebSocketChannel channel;
  final String ip;
  final RoomRegistry registry;
  final RateLimiter rateLimiter;
  final Clock clock;
  final RoomHub hub;
  final Random random;

  /// Set on a successful `create_room`, `join_room` or `resume`; cleared on
  /// a voluntary `leave_room` or when this socket is displaced by a resume
  /// takeover from elsewhere. Read, not trusted blindly: every registry call
  /// still re-validates `seatToken` against the room's live seats.
  String? roomCode;
  String? seatToken;

  bool _closed = false;

  bool get _hasIdentity => roomCode != null && seatToken != null;

  /// Entry point for one raw frame off the wire, text or binary. Implements
  /// the first five ladder steps; hands a validated envelope to [_dispatch]
  /// for the rest.
  Future<void> handleFrame(Object rawFrame) async {
    final List<int> bytes =
        rawFrame is String ? utf8.encode(rawFrame) : rawFrame as List<int>;

    // Step 1: size, before anything is parsed. An oversized frame is never
    // handed to jsonDecode.
    if (bytes.length > maxFrameBytes) {
      _log(type: '-', id: '-', outcome: 'TOO_LARGE');
      _sendError(ProtocolError.tooLarge, re: null);
      await close(code: closeCodeTooLarge, reason: 'TOO_LARGE');
      return;
    }

    final String text = rawFrame is String ? rawFrame : utf8.decode(bytes);

    // Steps 2 to 6: JSON parse, v, t, id shape, d presence.
    final EnvelopeResult parsed = parseEnvelope(text);
    if (parsed is EnvelopeError) {
      _log(
        type: '-',
        id: parsed.re ?? '-',
        outcome: wireErrorCode(parsed.error),
      );
      _sendError(parsed.error, re: parsed.re);
      if (parsed.closeConnection) {
        // The only ladder step below frame-size that closes the connection
        // is an unsupported `v` (envelope.dart sets `closeConnection: true`
        // only for `ProtocolError.protocolVersion`), so this is always the
        // 4002 case of docs/PROTOCOL.md section 7.1, never a code invented
        // for whatever `parsed.error` happens to hold.
        await close(
            code: closeCodeProtocolVersion,
            reason: wireErrorCode(parsed.error));
      }
      return;
    }
    final ParsedEnvelope envelope = (parsed as EnvelopeOk).envelope;

    // Step 7: the blanket per-connection rate limit. Every message type
    // pays this, including ping.
    final MessageRateOutcome rate = rateLimiter.recordMessage(this);
    if (rate == MessageRateOutcome.limited ||
        rate == MessageRateOutcome.mustClose) {
      _log(type: envelope.type, id: envelope.id, outcome: 'RATE_LIMITED');
      _sendError(ProtocolError.rateLimited, re: envelope.id);
      if (rate == MessageRateOutcome.mustClose) {
        await close(code: closeCodeRateLimited, reason: 'RATE_LIMITED');
      }
      return;
    }

    await _dispatch(envelope);
  }

  Future<void> _dispatch(ParsedEnvelope envelope) async {
    switch (envelope.type) {
      case 'ping':
        _handlePing(envelope);
      case 'create_room':
        _handleCreateRoom(envelope);
      case 'join_room':
        _handleJoinRoom(envelope);
      case 'resume':
        // Async, unlike every other arm here: it may close a displaced
        // socket. wire_server.dart's `_pump` awaits `handleFrame` before
        // reading the next frame off this socket specifically so two frames
        // are never processed concurrently against this connection's
        // mutable seat identity; failing to await here punches a hole in
        // that on the one path that reassigns identity mid-flight, and it
        // was also why a bad close code below used to surface as an
        // unhandled asynchronous error nobody was holding.
        await _handleResume(envelope);
      case 'start_game':
        _handleStartGame(envelope);
      case 'set_players':
        _handleSetPlayers(envelope);
      case 'set_seed':
        _handleSetSeed(envelope);
      case 'leave_room':
        _handleLeaveRoom(envelope);
      case 'roll':
        _handleRoll(envelope);
      case 'move':
        _handleMove(envelope);
      default:
        // Unreachable: parseEnvelope already rejected anything outside
        // knownMessageTypes as BAD_TYPE.
        throw StateError('unexpected message type ${envelope.type}');
    }
  }

  void _handlePing(ParsedEnvelope envelope) {
    if (envelope.data.isNotEmpty) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    _send(type: 'pong', data: const <String, Object?>{}, re: envelope.id);
    _log(type: envelope.type, id: envelope.id, outcome: 'ok');
  }

  void _handleCreateRoom(ParsedEnvelope envelope) {
    if (!rateLimiter.recordCreateRoom(ip)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }

    const Set<String> allowedKeys = <String>{'name', 'players', 'rules'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final Object? rawName = envelope.data['name'];
    if (rawName is! String) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final Object? rawPlayers = envelope.data['players'];
    if (rawPlayers is! int) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final RulesConfig? rules = _parseRules(envelope.data['rules']);
    if (rules == null && envelope.data.containsKey('rules')) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final CreateResult result = registry.createRoom(
      name: rawName,
      players: rawPlayers,
      rules: rules ?? const RulesConfig(),
    );

    if (result is CreateFailure) {
      _reject(envelope, result.error);
      return;
    }
    final CreateOk ok = result as CreateOk;

    roomCode = ok.room.code;
    seatToken = ok.seat.seatToken;
    hub.attach(code: ok.room.code, conn: this);

    _send(
      type: 'seat_assigned',
      data: buildSeatAssigned(ok.seat),
      re: null,
    );
    _send(
      type: 'room',
      data: buildRoomSnapshot(ok.room, now: clock.now),
      re: envelope.id,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: ok.seat.seat,
      seq: ok.room.seq,
    );
  }

  void _handleJoinRoom(ParsedEnvelope envelope) {
    if (!rateLimiter.recordJoinOrResume(ip)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }

    const Set<String> allowedKeys = <String>{'code', 'name'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final Object? rawCode = envelope.data['code'];
    final Object? rawName = envelope.data['name'];
    if (rawCode is! String || rawName is! String) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final JoinResult result = registry.joinRoom(code: rawCode, name: rawName);
    if (result is JoinFailure) {
      _reject(envelope, result.error, room: rawCode);
      return;
    }
    final JoinOk ok = result as JoinOk;

    roomCode = ok.room.code;
    seatToken = ok.seat.seatToken;
    hub.attach(code: ok.room.code, conn: this);

    _send(type: 'seat_assigned', data: buildSeatAssigned(ok.seat), re: null);
    _send(
      type: 'room',
      data: buildRoomSnapshot(ok.room, now: clock.now),
      re: envelope.id,
    );
    hub.broadcast(
      code: ok.room.code,
      type: 'player_joined',
      data: buildPlayerJoined(ok.seat, ok.room.seq),
      exceptConn: this,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: ok.seat.seat,
      seq: ok.room.seq,
    );
  }

  Future<void> _handleResume(ParsedEnvelope envelope) async {
    if (!rateLimiter.recordJoinOrResume(ip)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }

    const Set<String> allowedKeys = <String>{'code', 'seat_token'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final Object? rawCode = envelope.data['code'];
    final Object? rawToken = envelope.data['seat_token'];
    if (rawCode is! String || rawToken is! String) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final ResumeResult result =
        registry.resume(code: rawCode, seatToken: rawToken);
    if (result is ResumeFailure) {
      _reject(envelope, result.error, room: rawCode);
      return;
    }
    final ResumeOk ok = result as ResumeOk;

    roomCode = ok.room.code;
    seatToken = ok.seat.seatToken;
    final Connection? displaced = hub.attach(code: ok.room.code, conn: this);

    _send(
      type: 'room',
      data: buildRoomSnapshot(ok.room, now: clock.now),
      re: envelope.id,
    );
    // A takeover -- this socket resuming a seat that was already connected,
    // handled below via `displaced` -- flips nothing on the seat itself, and
    // the registry only moves `seq` on a real flip (registry.dart's own
    // `reconnected` local). Broadcasting `presence` anyway would put a `seq`
    // on the wire the room already used, which after respec 1 reads to a
    // client as a repeat rather than an advance and triggers a needless
    // resume against a merely flapping socket.
    if (ok.reconnected) {
      hub.broadcast(
        code: ok.room.code,
        type: 'presence',
        data: buildPresence(ok.seat.seat, true, ok.room.seq),
        exceptConn: this,
      );
    }
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: ok.seat.seat,
      seq: ok.room.seq,
    );

    if (displaced != null) {
      displaced.roomCode = null;
      displaced.seatToken = null;
      displaced._sendError(ProtocolError.badSeatToken, re: null);
      await displaced.close(
          code: closeCodeSeatTakenOver, reason: 'BAD_SEAT_TOKEN');
    }
  }

  void _handleStartGame(ParsedEnvelope envelope) {
    // docs/PROTOCOL.md section 7: the identity check runs before payload
    // validation for the five socket-identified messages, because checking
    // it costs nothing and touches nothing, and a socket in no room gets
    // BAD_SEAT_TOKEN whatever its payload looks like.
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    // docs/PROTOCOL.md section 7: phase correct precedes payload fields in
    // the ladder, and the registry call below is where that check normally
    // lives. A lookup is a read, not a mutation, so it can run ahead of the
    // payload check exactly like the identity check just above did. When
    // the room has vanished entirely (reaped since this socket's last
    // successful call) there is no phase to read here; the registry call
    // below still answers NO_SUCH_ROOM in that case, so skipping straight to
    // the payload check loses nothing.
    final Room? liveRoom = registry.lookup(roomCode!);
    if (liveRoom != null && liveRoom.state != RoomState.lobby) {
      _reject(envelope, ProtocolError.roomStarted);
      return;
    }
    if (envelope.data.isNotEmpty) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final StartResult result =
        registry.startGame(code: roomCode!, seatToken: seatToken!);
    if (result is StartFailure) {
      _reject(envelope, result.error);
      return;
    }
    final StartOk ok = result as StartOk;

    // docs/PROTOCOL.md section 11.2: each server-drawn seed handed out here
    // is its own fixed-seed broadcast, at the `seq` that fix itself
    // carried, sent before `game_started` since its `seq` values are all
    // earlier. Every socket attached to the room gets exactly one copy,
    // including the host's -- there is no single actor for this event to
    // answer with `re`, unlike an accepted `set_seed`.
    for (final SeededSeat seeded in ok.serverSeeded) {
      hub.broadcast(
        code: ok.room.code,
        type: 'seat_seed',
        data: buildSeatSeed(
          seat: seeded.seat.seat,
          clientSeed: seeded.seat.clientSeed!,
          origin: seeded.seat.seedOrigin!,
          seq: seeded.seq,
        ),
      );
    }

    final Map<String, Object?> data =
        buildGameStarted(ok.room, ok.gameStartedSeq);

    _send(type: 'game_started', data: data, re: envelope.id);
    hub.broadcast(
      code: ok.room.code,
      type: 'game_started',
      data: data,
      exceptConn: this,
    );

    // docs/PROTOCOL.md section 13.1: a standalone `turn` frame always
    // follows `game_started`, announcing the opening segment the same way
    // every later one is announced, at its own seq one greater than
    // `game_started`'s.
    final Map<String, Object?> turnData = buildTurn(
      seat: ok.room.game!.currentSeat,
      deadlineMs: ok.nextDeadlineMs,
      seq: ok.turnSeq,
    );
    _sendAndBroadcast(
      room: ok.room.code,
      type: 'turn',
      data: turnData,
      re: envelope.id,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seq: ok.turnSeq,
    );
  }

  void _handleSetPlayers(ParsedEnvelope envelope) {
    // docs/PROTOCOL.md section 7: identity before payload for the five
    // socket-identified messages.
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    // docs/PROTOCOL.md section 7: phase correct precedes payload fields;
    // see the matching comment in _handleStartGame for why a lookup here is
    // safe to run ahead of the payload check.
    final Room? liveRoom = registry.lookup(roomCode!);
    if (liveRoom != null && liveRoom.state != RoomState.lobby) {
      _reject(envelope, ProtocolError.roomStarted);
      return;
    }
    const Set<String> allowedKeys = <String>{'players'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final Object? rawPlayers = envelope.data['players'];
    if (rawPlayers is! int) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final SetPlayersResult result = registry.setPlayers(
      code: roomCode!,
      seatToken: seatToken!,
      players: rawPlayers,
    );
    if (result is SetPlayersFailure) {
      _reject(envelope, result.error);
      return;
    }
    final SetPlayersOk ok = result as SetPlayersOk;
    final Map<String, Object?> data =
        buildRoomSnapshot(ok.room, now: clock.now);

    _send(type: 'room', data: data, re: envelope.id);
    hub.broadcast(
      code: ok.room.code,
      type: 'room',
      data: data,
      exceptConn: this,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seq: ok.room.seq,
    );
  }

  /// `set_seed`, `docs/PROTOCOL.md` section 11.2. Unlike the five
  /// socket-identified messages above, this one's own ladder checks room
  /// existence, then phase, before seat authorisation, so a request wrong
  /// in both phase and seat answers `WRONG_PHASE`, and a request against a
  /// room that never existed or has been reaped answers `NO_SUCH_ROOM`
  /// regardless of what else is wrong with it. A socket with no stored
  /// identity at all has no room to look up, so that case is still resolved
  /// first, as `BAD_SEAT_TOKEN` -- the table's "socket holds no seat" row,
  /// read literally, is exactly this socket. `RoomRegistry.setSeed` re-runs
  /// the same ladder itself (room-exists, then phase, then seat, then
  /// field, then already-set) as defence in depth, the same way every other
  /// registry call re-validates what this file already checked.
  void _handleSetSeed(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final Room? liveRoom = registry.lookup(roomCode!);
    if (liveRoom == null) {
      _reject(envelope, ProtocolError.noSuchRoom);
      return;
    }
    if (liveRoom.state != RoomState.lobby) {
      _reject(envelope, ProtocolError.wrongPhase);
      return;
    }
    final bool seated =
        liveRoom.seats.any((Seat s) => s.seatToken == seatToken);
    if (!seated) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }

    const Set<String> allowedKeys = <String>{'client_seed'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final SetSeedResult result = registry.setSeed(
      code: roomCode!,
      seatToken: seatToken!,
      clientSeed: envelope.data['client_seed'],
    );
    if (result is SetSeedFailure) {
      _reject(envelope, result.error);
      return;
    }
    final SetSeedOk ok = result as SetSeedOk;
    final Map<String, Object?> data = buildSeatSeed(
      seat: ok.seat.seat,
      clientSeed: ok.seat.clientSeed!,
      origin: ok.seat.seedOrigin!,
      seq: ok.room.seq,
    );

    _send(type: 'seat_seed', data: data, re: envelope.id);
    hub.broadcast(
      code: ok.room.code,
      type: 'seat_seed',
      data: data,
      exceptConn: this,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: ok.seat.seat,
      seq: ok.room.seq,
    );
  }

  void _handleLeaveRoom(ParsedEnvelope envelope) {
    // docs/PROTOCOL.md section 7: identity before payload for the five
    // socket-identified messages.
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    if (envelope.data.isNotEmpty) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final LeaveResult result =
        registry.leaveRoom(code: roomCode!, seatToken: seatToken!);
    if (result is LeaveFailure) {
      _reject(envelope, result.error);
      return;
    }
    final LeaveOk ok = result as LeaveOk;
    final bool stillSeated =
        ok.room.seats.any((Seat s) => s.seatToken == seatToken);
    final String code = ok.room.code;
    final int seatIndex = ok.seat.seat;

    hub.detach(this);
    roomCode = null;
    seatToken = null;

    final Map<String, Object?> data = stillSeated
        ? buildPresence(seatIndex, false, ok.room.seq)
        : buildPlayerLeft(seatIndex, ok.room.seq);
    final String pushType = stillSeated ? 'presence' : 'player_left';

    _send(type: pushType, data: data, re: envelope.id);
    hub.broadcast(code: code, type: pushType, data: data, exceptConn: this);
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: code,
      seat: seatIndex,
      seq: ok.room.seq,
    );
  }

  /// `roll`, `docs/PROTOCOL.md` section 12.1. `_hasIdentity` is the
  /// section 7 identity-before-payload check every one of the five
  /// socket-identified messages gets; `_turnLadderError` is section 12.1's
  /// own table from "the room does not exist" down through "the turn is
  /// awaiting a move, not a roll" -- run here, ahead of the payload check,
  /// exactly as section 7's "phase correct" precedes "payload fields", even
  /// though `roll`'s only payload rule is that `d` is empty.
  void _handleRoll(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final Room? liveRoom = registry.lookup(roomCode!);
    final ProtocolError? ladderError =
        _turnLadderError(liveRoom, seatToken!, engine.GamePhase.awaitRoll);
    if (ladderError != null) {
      _reject(envelope, ladderError, room: roomCode);
      return;
    }
    if (envelope.data.isNotEmpty) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final RollResult result =
        registry.roll(code: roomCode!, seatToken: seatToken!);
    if (result is RollFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    _publishRoll(envelope, result as RollOk);
  }

  /// `move`, `docs/PROTOCOL.md` section 12.2. Same shape as [_handleRoll],
  /// with `awaitMove` as the phase this message needs to find the turn in,
  /// and with `token`'s own `BAD_FIELD` check -- absent, not an integer, or
  /// outside `0..3` -- run after the ladder and before `registry.move`,
  /// which is what lets that call's own signature take a plain `int`
  /// rather than the `Object?` every payload field starts life as.
  void _handleMove(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final Room? liveRoom = registry.lookup(roomCode!);
    final ProtocolError? ladderError =
        _turnLadderError(liveRoom, seatToken!, engine.GamePhase.awaitMove);
    if (ladderError != null) {
      _reject(envelope, ladderError, room: roomCode);
      return;
    }

    const Set<String> allowedKeys = <String>{'token'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    final Object? rawToken = envelope.data['token'];
    if (rawToken is! int || rawToken < 0 || rawToken > 3) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final MoveResult result = registry.move(
      code: roomCode!,
      seatToken: seatToken!,
      token: rawToken,
    );
    if (result is MoveFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    _publishMove(envelope, result as MoveOk);
  }

  /// `docs/PROTOCOL.md` section 12.1/12.2: the ladder `roll` and `move`
  /// share, from "the room does not exist" through "the turn is awaiting a
  /// move [or a roll], not a roll [or a move]" -- everything above the
  /// payload check, so it can run before that check the same way
  /// `_handleStartGame` and `_handleSetPlayers` peek the room for their own
  /// phase check ahead of theirs. `awaitingPhase` is `awaitRoll` for `roll`
  /// and `awaitMove` for `move`. Returns null when nothing in the ladder
  /// rejects; `registry.roll`/`registry.move` re-run every one of these
  /// checks themselves once called, the same defence in depth every other
  /// registry method gets from this file.
  ProtocolError? _turnLadderError(
    Room? room,
    String callerSeatToken,
    engine.GamePhase awaitingPhase,
  ) {
    if (room == null) {
      return ProtocolError.noSuchRoom;
    }
    Seat? seat;
    for (final Seat candidate in room.seats) {
      if (candidate.seatToken == callerSeatToken) {
        seat = candidate;
        break;
      }
    }
    if (seat == null) {
      return ProtocolError.badSeatToken;
    }
    if (room.state == RoomState.finished) {
      return ProtocolError.gameOver;
    }
    if (room.state == RoomState.lobby) {
      return ProtocolError.wrongPhase;
    }
    final engine.GameState game = room.game!;
    if (seat.seat != game.currentSeat) {
      return ProtocolError.notYourTurn;
    }
    if (game.phase != awaitingPhase) {
      return ProtocolError.wrongPhase;
    }
    return null;
  }

  /// Builds and sends every frame `RoomRegistry.roll` decided on, in the
  /// order section 12.1 fixes: `rolled` always, then `turn_passed` and
  /// `turn` together, exactly when the roll ended the turn. `re` is set on
  /// every one of them for this socket's own copy, and on none of them for
  /// anyone else's, per section 12.3.
  void _publishRoll(ParsedEnvelope envelope, RollOk ok) {
    final engine.Rolled rolledEvent =
        ok.events.whereType<engine.Rolled>().single;
    final Map<String, Object?> rolledData = buildRolled(
      seat: rolledEvent.seat,
      value: rolledEvent.value,
      legal: rolledEvent.legal,
      deadlineMs: ok.rolledDeadlineMs,
      k: ok.k,
      reveal: ok.reveal,
      seq: ok.rolledSeq,
    );
    _sendAndBroadcast(
      room: ok.room.code,
      type: 'rolled',
      data: rolledData,
      re: envelope.id,
    );

    final List<engine.TurnEnded> turnEndedEvents =
        ok.events.whereType<engine.TurnEnded>().toList();
    if (turnEndedEvents.isEmpty) {
      _log(
        type: envelope.type,
        id: envelope.id,
        outcome: 'ok',
        room: ok.room.code,
        seat: rolledEvent.seat,
        seq: ok.rolledSeq,
      );
      return;
    }

    final engine.TurnEnded turnEnded = turnEndedEvents.single;
    final Map<String, Object?> passedData = buildTurnPassed(
      seat: turnEnded.seat,
      reason: _wireTurnEndReason(turnEnded.reason),
      seq: ok.turnPassedSeq!,
    );
    _sendAndBroadcast(
      room: ok.room.code,
      type: 'turn_passed',
      data: passedData,
      re: envelope.id,
    );

    final Map<String, Object?> turnData = buildTurn(
      seat: ok.room.game!.currentSeat,
      deadlineMs: ok.nextDeadlineMs!,
      seq: ok.turnSeq!,
    );
    _sendAndBroadcast(
      room: ok.room.code,
      type: 'turn',
      data: turnData,
      re: envelope.id,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: rolledEvent.seat,
      seq: ok.turnSeq,
    );
  }

  /// Builds and sends every frame `RoomRegistry.move` decided on: `moved`
  /// always, then exactly one of `game_over` or `turn`, per section 12.2.
  void _publishMove(ParsedEnvelope envelope, MoveOk ok) {
    final engine.Moved movedEvent = ok.events.whereType<engine.Moved>().single;
    final List<Map<String, Object?>> captured = <Map<String, Object?>>[
      for (final engine.Captured c in ok.events.whereType<engine.Captured>())
        <String, Object?>{'seat': c.seat, 'token': c.token},
    ];
    final bool extraRoll = ok.events.whereType<engine.ExtraRoll>().isNotEmpty;
    final Map<String, Object?> movedData = buildMoved(
      seat: movedEvent.seat,
      token: movedEvent.token,
      from: movedEvent.from,
      to: movedEvent.to,
      captured: captured,
      extraRoll: extraRoll,
      seq: ok.movedSeq,
    );
    _sendAndBroadcast(
      room: ok.room.code,
      type: 'moved',
      data: movedData,
      re: envelope.id,
    );

    final List<engine.GameWon> wonEvents =
        ok.events.whereType<engine.GameWon>().toList();
    if (wonEvents.isNotEmpty) {
      final engine.GameWon won = wonEvents.single;
      final Map<String, Object?> overData = buildGameOver(
        winner: won.seat,
        verifyUrl: ok.verifyUrl!,
        seq: ok.gameOverSeq!,
      );
      _sendAndBroadcast(
        room: ok.room.code,
        type: 'game_over',
        data: overData,
        re: envelope.id,
      );
      _log(
        type: envelope.type,
        id: envelope.id,
        outcome: 'ok',
        room: ok.room.code,
        seat: movedEvent.seat,
        seq: ok.gameOverSeq,
      );
      return;
    }

    final Map<String, Object?> turnData = buildTurn(
      seat: ok.room.game!.currentSeat,
      deadlineMs: ok.nextDeadlineMs!,
      seq: ok.turnSeq!,
    );
    _sendAndBroadcast(
      room: ok.room.code,
      type: 'turn',
      data: turnData,
      re: envelope.id,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: movedEvent.seat,
      seq: ok.turnSeq,
    );
  }

  /// `docs/PROTOCOL.md` section 12.3: every frame in section 12 is
  /// broadcast to every connected socket in the room including the sender,
  /// and the sender's own copy is the only one that carries `re`.
  void _sendAndBroadcast({
    required String room,
    required String type,
    required Map<String, Object?> data,
    required String re,
  }) {
    _send(type: type, data: data, re: re);
    hub.broadcast(code: room, type: type, data: data, exceptConn: this);
  }

  /// The wire string for `engine.TurnEndReason`, `docs/PROTOCOL.md` section
  /// 5's `turn_passed.reason`.
  String _wireTurnEndReason(engine.TurnEndReason reason) =>
      wireTurnEndReason(reason);

  /// `rules`, the wire-level object of `docs/PROTOCOL.md` section 4. Called
  /// unconditionally by `_handleCreateRoom`, key present or not: a missing
  /// key and an explicit JSON `null` both arrive here as a Dart `null`, and
  /// this method cannot tell them apart from the value alone, so it returns
  /// null for both. Telling them apart is the caller's job, via
  /// `containsKey` -- a genuinely absent key falls back to
  /// `const RulesConfig()`, while an explicit `null` is rejected as
  /// `BAD_FIELD` right alongside every other wrong JSON type: not a `Map`
  /// any more than a string or a number is, any key outside
  /// `blocks`/`capture_bonus`/`turn_seconds`, or one of those keys present
  /// at the wrong type. An unknown key here is exactly what stops two
  /// clients from silently disagreeing about the rules they think they are
  /// playing, and a present-but-null `rules` gets no special exemption from
  /// that.
  RulesConfig? _parseRules(Object? raw) {
    if (raw is! Map<String, Object?>) {
      return null;
    }
    const Set<String> allowedKeys = <String>{
      'blocks',
      'capture_bonus',
      'turn_seconds',
    };
    if (!raw.keys.every(allowedKeys.contains)) {
      return null;
    }
    bool blocks = const RulesConfig().blocks;
    if (raw.containsKey('blocks')) {
      final Object? v = raw['blocks'];
      if (v is! bool) {
        return null;
      }
      blocks = v;
    }
    bool captureBonus = const RulesConfig().captureBonus;
    if (raw.containsKey('capture_bonus')) {
      final Object? v = raw['capture_bonus'];
      if (v is! bool) {
        return null;
      }
      captureBonus = v;
    }
    int turnSeconds = const RulesConfig().turnSeconds;
    if (raw.containsKey('turn_seconds')) {
      final Object? v = raw['turn_seconds'];
      if (v is! int) {
        return null;
      }
      turnSeconds = v;
    }
    return RulesConfig(
      blocks: blocks,
      captureBonus: captureBonus,
      turnSeconds: turnSeconds,
    );
  }

  void _reject(ParsedEnvelope envelope, ProtocolError error, {String? room}) {
    _sendError(error, re: envelope.id);
    final String? effectiveRoom = room ?? roomCode;
    // docs/PROTOCOL.md section 7: INTERNAL is logged with the room code and
    // the sequence number, in addition to the fields every outcome gets.
    final int? seq = error == ProtocolError.internal && effectiveRoom != null
        ? registry.lookup(effectiveRoom)?.seq
        : null;
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: wireErrorCode(error),
      room: effectiveRoom,
      seq: seq,
    );
  }

  /// A push with no `re`, for the hub to deliver to a socket that did not
  /// send the message this push describes.
  void sendPush({required String type, required Map<String, Object?> data}) {
    _send(type: type, data: data, re: null);
  }

  void _sendError(ProtocolError error, {required String? re}) {
    _send(
      type: 'error',
      data: errorPayload(error, defaultErrorMessage(error)),
      re: re,
    );
  }

  void _send({
    required String type,
    required Map<String, Object?> data,
    required String? re,
  }) {
    if (_closed) {
      return;
    }
    final String id = generateMessageId(random);
    channel.sink.add(
      encodeEnvelope(type: type, id: id, data: data, re: re),
    );
  }

  /// One structured line per event to stdout. Never a seat token, never a
  /// display name.
  void _log({
    required String type,
    required String id,
    required String outcome,
    String? room,
    int? seat,
    int? seq,
  }) {
    final StringBuffer line = StringBuffer()
      ..write('room=')
      ..write(room ?? roomCode ?? '-')
      ..write(' type=')
      ..write(type)
      ..write(' id=')
      ..write(id)
      ..write(' seat=')
      ..write(seat?.toString() ?? '-')
      ..write(' outcome=')
      ..write(outcome);
    if (seq != null) {
      line.write(' seq=');
      line.write(seq);
    }
    // ignore: avoid_print
    print(line.toString());
  }

  /// Called by the socket layer when the underlying connection has gone
  /// away, however it went away: a clean close, a network drop, or a
  /// takeover from `_handleResume`. Never calls `leaveRoom` -- a dropped
  /// socket is not a voluntary leave, `docs/PROTOCOL.md` section 8.
  void handleDisconnect() {
    hub.detach(this);
    rateLimiter.forget(this);
    if (roomCode != null && seatToken != null) {
      // A takeover already cleared this connection's identity before
      // closing it (`_handleResume`), so a socket that reaches here with a
      // non-null identity is a genuine drop, not the losing side of a
      // takeover. `setConnected` reports whether it actually flipped the
      // flag -- false when the seat was already marked disconnected, or the
      // room or seat is gone -- and only a real flip gets broadcast: a
      // `presence` with no change behind it would carry a `seq` the room
      // already used.
      final bool flipped = registry.setConnected(
        code: roomCode!,
        seatToken: seatToken!,
        connected: false,
      );
      final Room? room = registry.lookup(roomCode!);
      Seat? seat;
      for (final Seat candidate in room?.seats ?? const <Seat>[]) {
        if (candidate.seatToken == seatToken) {
          seat = candidate;
          break;
        }
      }
      if (room != null && seat != null) {
        if (flipped) {
          hub.broadcast(
            code: room.code,
            type: 'presence',
            data: buildPresence(seat.seat, false, room.seq),
          );
        }
        _log(
          type: '-',
          id: '-',
          outcome: 'disconnect',
          room: room.code,
          seat: seat.seat,
          seq: room.seq,
        );
      } else {
        // The room was reaped, or this seat is no longer in it, in the
        // window between this socket's last successful call and the
        // disconnect reaching here. There is no `presence` to broadcast --
        // nothing is listening in a room that no longer exists, and a seat
        // that is not there cannot be marked disconnected -- but the event
        // still gets one structured line like every other outcome, rather
        // than vanishing from the log.
        _log(
          type: '-',
          id: '-',
          outcome: 'disconnect_room_gone',
          room: roomCode,
        );
      }
    }
    _closed = true;
  }

  /// Closes the underlying socket with [code] and [reason], one of the four
  /// pinned pairs in `docs/PROTOCOL.md` section 7.1.
  ///
  /// This used to await `channel.sink.close()` and then, after a delay,
  /// treat a still-null `channel.closeCode` as proof the close had not
  /// reached the peer. Measured directly against this stack
  /// (`shelf_web_socket` 3.0.0 over `web_socket_channel` 3.0.3 over
  /// `package:web_socket` 1.0.1): `channel.closeCode` is set in exactly one
  /// place in that whole chain, `AdapterWebSocketChannel`'s handler for a
  /// `CloseReceived` event, and `CloseReceived` is only ever produced from a
  /// close code the *peer* sent. A close this side initiates never
  /// populates it -- not eventually, not on success, not on failure -- for
  /// a reason specific to this implementation: `IOWebSocket.close` closes
  /// its own `_events` controller (`unawaited(_events.close())`) before it
  /// awaits the real `dart:io` close, so by the time any close frame could
  /// round-trip back from the peer, this side's own event stream has
  /// already told itself it is done and the incoming `CloseReceived` case
  /// is never reached. Confirmed with a live client on both branches: a
  /// close with a valid code that the client demonstrably received left
  /// `channel.closeCode` null for the full three seconds measured, exactly
  /// as null as a close with an invalid code that the client never received
  /// at all. `channel.sink.done` and `channel.stream`'s own "done" event
  /// were checked too, on the theory that closing the sink might at least
  /// signal locally: both resolve the same way regardless of whether the
  /// peer ever saw anything, because `GuaranteeChannel` (the
  /// `stream_channel` type backing this channel) fires its own local "done"
  /// the instant the sink is closed, as a bookkeeping guarantee, not as a
  /// report from the network. None of the three carries one bit of
  /// information about whether the close reached the peer.
  ///
  /// The actual failure this order exists to catch -- `checkCloseCode`
  /// throwing on 1008 and 1009, which is where this whole defect started --
  /// throws from inside an `onDone` callback that
  /// `AdapterWebSocketChannel`'s constructor registers on the channel
  /// before `Connection` is ever handed the channel, so it runs in whatever
  /// zone was current at that registration, not whatever zone is current
  /// when this method runs later. `runZonedGuarded` wrapped around this
  /// call does not catch it, and neither does
  /// `Isolate.current.addErrorListener` -- both were tried against a live
  /// reproduction of the 1009 case and neither saw the error; it reaches
  /// only the root zone's default uncaught-error printer. There is no
  /// future, stream, or zone hook available to code in this position that
  /// observes that failure after the fact.
  ///
  /// What is available is the input to it. `checkCloseCode` and
  /// `checkCloseReason` are pure functions of the `code` and `reason` this
  /// method is called with, and both of those come from a short, fixed set
  /// this file owns outright: the four constants above, and the literal
  /// reason strings each call site passes. So the fix is to run the same
  /// two checks ourselves, synchronously, before ever handing anything to
  /// the library: that is strictly more information than the delayed
  /// `closeCode` probe ever carried (which was none, on either branch), and
  /// it is available immediately rather than guessed at two seconds later.
  /// A rejection here is logged as `close_failed` and the library is never
  /// called, since calling it with input already known to be invalid could
  /// only reproduce the unobservable failure this comment describes. The
  /// `try`/`catch` around the real call stays as defence in depth for a
  /// failure that surfaces through the awaited future by some other path --
  /// a different library version, a different transport -- though none is
  /// known today.
  Future<void> close({required int code, required String reason}) async {
    _closed = true;
    if (!_isValidCloseCode(code) || !_isValidCloseReason(reason)) {
      _log(
        type: '-',
        id: '-',
        outcome: 'close_failed code=$code reason=$reason '
            'error=invalid close code or reason, not sent to the peer',
      );
      return;
    }
    try {
      await channel.sink.close(code, reason);
    } catch (error) {
      _log(
        type: '-',
        id: '-',
        outcome: 'close_failed code=$code reason=$reason error=$error',
      );
    }
  }
}

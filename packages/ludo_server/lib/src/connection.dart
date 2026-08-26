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
// `start_game`, `set_players`, `leave_room`, `roll` and `move` carry no room
// code and no seat token in their payload; the socket's own stored identity
// (set on a successful `create_room`, `join_room` or `resume`) is the only
// source of either. A connection with no stored identity gets
// `BAD_SEAT_TOKEN` for any of these -- the table has no separate code for
// "this socket is not in a room at all", and a socket with no seat is
// exactly a socket for which no seat token can be authorised.

import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'clock.dart';
import 'envelope.dart';
import 'rate_limit.dart';
import 'registry.dart';
import 'room.dart';
import 'snapshot.dart';

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
      await close(code: 1009, reason: 'TOO_LARGE');
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
        await close(code: 1008, reason: wireErrorCode(parsed.error));
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
        await close(code: 1008, reason: 'RATE_LIMITED');
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
        _handleResume(envelope);
      case 'start_game':
        _handleStartGame(envelope);
      case 'set_players':
        _handleSetPlayers(envelope);
      case 'leave_room':
        _handleLeaveRoom(envelope);
      case 'roll':
      case 'move':
        // Out of scope for this order: there is no turn loop yet. Every
        // syntactically valid roll/move from an authorised seat in a live
        // room answers WRONG_PHASE, deliberately, until order 008 lands the
        // turn loop. Because "phase correct" precedes "payload fields" in
        // the ladder, the payload (e.g. move's "token") is never even
        // inspected here.
        _handleRollOrMove(envelope);
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
      data: buildRoomSnapshot(ok.room),
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
    _send(type: 'room', data: buildRoomSnapshot(ok.room), re: envelope.id);
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

    _send(type: 'room', data: buildRoomSnapshot(ok.room), re: envelope.id);
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
      await displaced.close(code: 1008, reason: 'BAD_SEAT_TOKEN');
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
    final Map<String, Object?> data =
        buildGameStarted(ok.room.game!, ok.room.seq);

    _send(type: 'game_started', data: data, re: envelope.id);
    hub.broadcast(
      code: ok.room.code,
      type: 'game_started',
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

  void _handleSetPlayers(ParsedEnvelope envelope) {
    // docs/PROTOCOL.md section 7: identity before payload for the five
    // socket-identified messages.
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
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
    final Map<String, Object?> data = buildRoomSnapshot(ok.room);

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

  void _handleRollOrMove(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final Room? room = registry.lookup(roomCode!);
    if (room == null) {
      _reject(envelope, ProtocolError.noSuchRoom, room: roomCode);
      return;
    }
    final bool seated = room.seats.any((Seat s) => s.seatToken == seatToken);
    if (!seated) {
      _reject(envelope, ProtocolError.badSeatToken, room: roomCode);
      return;
    }
    // No turn loop yet: order 008. This is deliberate, not forgotten.
    _reject(envelope, ProtocolError.wrongPhase, room: roomCode);
  }

  /// `rules`, the wire-level object of `docs/PROTOCOL.md` section 4. Absent
  /// entirely is fine (defaults apply, and that case never reaches this
  /// method: the caller only calls it when the key is present). Present but
  /// the wrong JSON type -- including an explicit JSON `null`, which is not
  /// a `Map` any more than a string or a number is -- or with any key
  /// outside `blocks`/`capture_bonus`/`turn_seconds`, or with one of those
  /// keys present at the wrong type, is `BAD_FIELD`. An unknown key here is
  /// exactly what stops two clients from silently disagreeing about the
  /// rules they think they are playing, and a present-but-null `rules` gets
  /// no special exemption from that.
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
      }
    }
    _closed = true;
  }

  Future<void> close({int? code, String? reason}) async {
    _closed = true;
    await channel.sink.close(code, reason);
  }
}

// docs/PROTOCOL.md section 1 and 7. The envelope every message wears, both
// directions, and the codes an error frame is allowed to carry. This file
// knows nothing about rooms, seats or the registry: it is the generic shape
// that sits underneath every message type, plus the fixed vocabulary of
// error codes from section 7's table.
//
// Errors are not reinvented here. `ProtocolError` already exists in
// `registry.dart`, one to one with the section 7 table, and it is frozen.
// This file only maps that enum onto the wire string and back, and defines
// the pieces of ladder validation that do not need the registry at all:
// frame size, JSON parse, `v`, `t`, `id` shape and `d` presence.

import 'dart:convert';
import 'dart:math';

import 'registry.dart' show ProtocolError;

/// `docs/PROTOCOL.md` section 1: "Maximum frame size is 8192 bytes."
const int maxFrameBytes = 8192;

const int _minIdLength = 8;
const int _maxIdLength = 64;

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// Length and alphabet only, per section 1: "Opaque, 8 to 64 characters,
/// `[A-Za-z0-9_-]`."
bool isWellFormedMessageId(String candidate) {
  if (candidate.length < _minIdLength || candidate.length > _maxIdLength) {
    return false;
  }
  return _idPattern.hasMatch(candidate);
}

/// The wire string for every `ProtocolError`, exactly the table in
/// `docs/PROTOCOL.md` section 7. A code is never spelled out at a call site;
/// everything that needs one calls this.
String wireErrorCode(ProtocolError error) {
  switch (error) {
    case ProtocolError.protocolVersion:
      return 'PROTOCOL_VERSION';
    case ProtocolError.badType:
      return 'BAD_TYPE';
    case ProtocolError.badField:
      return 'BAD_FIELD';
    case ProtocolError.tooLarge:
      return 'TOO_LARGE';
    case ProtocolError.rateLimited:
      return 'RATE_LIMITED';
    case ProtocolError.noSuchRoom:
      return 'NO_SUCH_ROOM';
    case ProtocolError.roomFull:
      return 'ROOM_FULL';
    case ProtocolError.roomStarted:
      return 'ROOM_STARTED';
    case ProtocolError.notHost:
      return 'NOT_HOST';
    case ProtocolError.notEnoughPlayers:
      return 'NOT_ENOUGH_PLAYERS';
    case ProtocolError.notYourTurn:
      return 'NOT_YOUR_TURN';
    case ProtocolError.wrongPhase:
      return 'WRONG_PHASE';
    case ProtocolError.illegalMove:
      return 'ILLEGAL_MOVE';
    case ProtocolError.badSeatToken:
      return 'BAD_SEAT_TOKEN';
    case ProtocolError.seedAlreadySet:
      return 'SEED_ALREADY_SET';
    case ProtocolError.gameOver:
      return 'GAME_OVER';
    case ProtocolError.internal:
      return 'INTERNAL';
    case ProtocolError.updateRequired:
      return 'UPDATE_REQUIRED';
    case ProtocolError.notAbsent:
      return 'NOT_ABSENT';
    case ProtocolError.tooManyKnocks:
      return 'TOO_MANY_KNOCKS';
    case ProtocolError.noSuchKnock:
      return 'NO_SUCH_KNOCK';
    case ProtocolError.knockRefused:
      return 'KNOCK_REFUSED';
    case ProtocolError.kicked:
      return 'KICKED';
    case ProtocolError.codeBanned:
      return 'CODE_BANNED';
    case ProtocolError.alreadySeated:
      return 'ALREADY_SEATED';
  }
}

/// A parsed, envelope-shape-valid inbound message. Nothing below `d`'s own
/// object-ness has been validated yet; that is each message type's own
/// allow-list, applied by `connection.dart`.
class ParsedEnvelope {
  ParsedEnvelope({
    required this.type,
    required this.id,
    required this.data,
  });

  final String type;
  final String id;
  final Map<String, Object?> data;
}

sealed class EnvelopeResult {}

class EnvelopeOk extends EnvelopeResult {
  EnvelopeOk(this.envelope);
  final ParsedEnvelope envelope;
}

/// A ladder failure below the frame-size step. [closeConnection] is true
/// only for `PROTOCOL_VERSION` (`TOO_LARGE` is handled separately, before
/// JSON is even attempted, because the point is to never hand an oversized
/// frame to `jsonDecode`). [re] is the id to answer with, and it is only ever
/// an `id` that itself passed the shape check -- section 7: "`re` on an
/// outbound frame is only ever an `id` that passed the `id` shape check." A
/// server reply never echoes an unvalidated string back into a field the
/// envelope rules constrain, so a client cannot use the `v` or `t` failure
/// paths to smuggle an oversized or out-of-alphabet value into `re`.
class EnvelopeError extends EnvelopeResult {
  EnvelopeError({
    required this.error,
    required this.closeConnection,
    this.re,
  });

  final ProtocolError error;
  final bool closeConnection;
  final String? re;
}

/// Every message type this server recognises today, section 4. `roll` and
/// `move` are recognised but answered with `WRONG_PHASE` until order 008
/// builds the turn loop; they are still valid `t` values, not `BAD_TYPE`.
const Set<String> knownMessageTypes = <String>{
  'create_room',
  'join_room',
  'resume',
  'start_game',
  'set_players',
  'set_seed',
  'leave_room',
  'ping',
  'roll',
  'move',
  'rematch',
  'game_log',
  'emote',
  'decline_release',
  'answer_knock',
  'set_guest_approval',
  // Section 33 items 3 and 4: the waiting line.
  'find_game',
  'cancel_find',
};

/// `docs/PROTOCOL.md` section 28 rule 4: `kick` exists only on a server that
/// plays the 2026-11 ruleset. On any other it is as unknown as it always was.
const String kickMessageType = 'kick';

/// Steps 2 through 6 of the section 7 ladder: JSON parse, `v`, `t`, `id`
/// shape, `d` presence. Step 1 (frame size) happens before this is ever
/// called, on the raw bytes, because an oversized frame must never reach
/// `jsonDecode`.
EnvelopeResult parseEnvelope(String text, {bool kickKnown = false}) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return EnvelopeError(error: ProtocolError.badField, closeConnection: false);
  }

  if (decoded is! Map<String, Object?>) {
    return EnvelopeError(error: ProtocolError.badField, closeConnection: false);
  }
  final Map<String, Object?> envelope = decoded;

  // Recovered only for correlation, and only when it already passes the `id`
  // shape check -- section 7: "`re` on an outbound frame is only ever an
  // `id` that passed the `id` shape check." A `v` or `t` failure must not
  // become a channel for reflecting an arbitrary, unvalidated client string
  // into `re`; a well-formed id benefits from being echoed, and nothing else
  // does.
  final Object? rawId = envelope['id'];
  final String? recoveredId =
      rawId is String && isWellFormedMessageId(rawId) ? rawId : null;

  final Object? v = envelope['v'];
  if (v is! int || v != 1) {
    return EnvelopeError(
      error: ProtocolError.protocolVersion,
      closeConnection: true,
      re: recoveredId,
    );
  }

  final Object? t = envelope['t'];
  if (t is! String ||
      !(knownMessageTypes.contains(t) || (kickKnown && t == kickMessageType))) {
    return EnvelopeError(
      error: ProtocolError.badType,
      closeConnection: false,
      re: recoveredId,
    );
  }

  if (rawId is! String || !isWellFormedMessageId(rawId)) {
    return EnvelopeError(error: ProtocolError.badField, closeConnection: false);
  }

  final Object? d = envelope['d'];
  if (d is! Map<String, Object?>) {
    return EnvelopeError(
      error: ProtocolError.badField,
      closeConnection: false,
      re: rawId,
    );
  }

  return EnvelopeOk(ParsedEnvelope(type: t, id: rawId, data: d));
}

/// Builds the JSON text of an outgoing envelope. [re] is the id being
/// answered, omitted for an unsolicited push.
String encodeEnvelope({
  required String type,
  required String id,
  required Map<String, Object?> data,
  String? re,
}) {
  final Map<String, Object?> envelope = <String, Object?>{
    'v': 1,
    't': type,
    'id': id,
    'd': data,
    if (re != null) 're': re,
  };
  return jsonEncode(envelope);
}

/// Builds the `d` payload of an `error` message, section 7.
///
/// [ban] is section 32 item 12's `ban` object, carried only by `CODE_BANNED`.
Map<String, Object?> errorPayload(
  ProtocolError error,
  String message, {
  Map<String, Object?>? ban,
}) {
  return <String, Object?>{
    'code': wireErrorCode(error),
    'message': message,
    if (ban != null) 'ban': ban,
  };
}

/// A short, non-sensitive human string for each error code. Never carries a
/// seat token, a display name or a room code -- those belong in the log
/// line, not in a message a client could show verbatim.
String defaultErrorMessage(ProtocolError error) {
  switch (error) {
    case ProtocolError.protocolVersion:
      return 'unsupported protocol version';
    case ProtocolError.badType:
      return 'unknown message type';
    case ProtocolError.badField:
      return 'a field is missing, the wrong type, out of range, or unknown';
    case ProtocolError.tooLarge:
      return 'frame exceeds the maximum size';
    case ProtocolError.rateLimited:
      return 'rate limit exceeded';
    case ProtocolError.noSuchRoom:
      return 'no such room';
    case ProtocolError.roomFull:
      return 'room is full';
    case ProtocolError.roomStarted:
      return 'room is not in the lobby';
    case ProtocolError.notHost:
      return 'only the host may do that';
    case ProtocolError.notEnoughPlayers:
      return 'not every seat is filled';
    case ProtocolError.notYourTurn:
      return 'it is not your turn';
    case ProtocolError.wrongPhase:
      return 'wrong phase for that action';
    case ProtocolError.illegalMove:
      return 'that move is not legal';
    case ProtocolError.badSeatToken:
      return 'seat token does not match a live seat';
    case ProtocolError.seedAlreadySet:
      return 'this seat has already set a seed';
    case ProtocolError.gameOver:
      return 'the game is over';
    case ProtocolError.internal:
      return 'internal error';
    case ProtocolError.updateRequired:
      return 'this version of the app is too old for this server';
    case ProtocolError.notAbsent:
      return 'that seat is connected';
    case ProtocolError.tooManyKnocks:
      return 'too many people are waiting to join this room';
    case ProtocolError.noSuchKnock:
      return 'no such request to join';
    case ProtocolError.knockRefused:
      return 'the host did not accept your request to join';
    case ProtocolError.kicked:
      return 'you were removed from this room';
    case ProtocolError.codeBanned:
      return 'joining by code is paused for this device or network';
    case ProtocolError.alreadySeated:
      return 'this connection already holds a seat';
  }
}

/// A fresh id for a server-originated message, section 1: "server-generated
/// for server to client". 16 CSPRNG bytes, base64url, unpadded -- 22
/// characters, well inside the 8 to 64 range and drawn from the same
/// alphabet the id shape check requires.
String generateMessageId(Random random) {
  final List<int> bytes =
      List<int>.generate(16, (int _) => random.nextInt(256));
  final String encoded = base64Url.encode(bytes);
  final int padStart = encoded.indexOf('=');
  return padStart == -1 ? encoded : encoded.substring(0, padStart);
}

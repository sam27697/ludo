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
import 'emote.dart';
import 'envelope.dart';
import 'rate_limit.dart';
import 'registry.dart';
import 'room.dart';
import 'room_code.dart';
import 'ruleset.dart';
import 'snapshot.dart';
import 'strike_store.dart' show BanInfo;
import 'waiting_line.dart';

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

/// Section 27 rule 4: the app's build is below the server's minimum.
const int closeCodeUpdateRequired = 4005;

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

  /// Sends one push to whichever socket, if any, is currently attached to
  /// [code] holding [seatToken]. A no-op when no attached socket holds that
  /// token: the seat is not connected, or nothing under this process ever
  /// attached for it. `docs/PROTOCOL.md` section 15 rule 1 -- the seat a
  /// `set_players` reseat moved is not necessarily the caller's own, so the
  /// caller's connection needs a way to reach that other seat's socket
  /// directly, addressed by the one thing that never changes across a
  /// reseat, without the registry ever having to hold a socket itself.
  void sendToSeatToken({
    required String code,
    required String seatToken,
    required String type,
    required Map<String, Object?> data,
  });

  /// `docs/PROTOCOL.md` section 16.9 rule 1: detaches whichever socket, if
  /// any, is currently attached to [code] holding [seatToken], and returns
  /// that connection -- null when no attached socket holds that token. Used
  /// when a seat is removed out from under a connection that is not the
  /// caller's own, the host-forced rematch start of section 16.4 "Not
  /// everyone": that seat's socket, if connected, has already been sent its
  /// own `player_left` by the time this is called, and this is what stops
  /// it from being delivered anything further for this room, exactly as
  /// `leave_room` already does for the connection that sends it, except
  /// that connection here is someone else's, so the caller clears its
  /// identity itself once this returns it.
  Connection? detachSeatToken(
      {required String code, required String seatToken});
}

/// `docs/PROTOCOL.md` section 28 rule 4 "At the end": once the `player_left`
/// of every retired seat a finished game freed has been broadcast, none of
/// those seats' sockets is owed anything more from the room. Detaches
/// whichever socket still holds each [freed] seat and clears its identity,
/// the same as section 16.9 rule 1 does for a seat removed by a forced
/// rematch start. A seat whose socket is already gone is skipped.
void detachFreedSeats(RoomHub hub, String code, List<FreedSeat> freed) {
  for (final FreedSeat gone in freed) {
    final Connection? conn = hub.detachSeatToken(
      code: code,
      seatToken: gone.seat.seatToken,
    );
    conn?.roomCode = null;
    conn?.seatToken = null;
  }
}

/// `docs/PROTOCOL.md` section 31 item 3: `expires_ms` of a fresh knock, and
/// the 60 s a knock lives.
const int knockLifetimeMs = 60000;

/// `install`, section 31 item 2: 16 to 64 characters of `[A-Za-z0-9_-]`.
final RegExp _installPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// Section 31 item 12 (b): tells the knocker of each knock whose room was
/// reaped that it timed out, and clears its pending state.
void failReapedKnocks(List<Knock> knocks) {
  for (final Knock knock in knocks) {
    final Object? owner = knock.owner;
    if (owner is! Connection) {
      continue;
    }
    if (owner.pendingKnockId == knock.id) {
      owner.pendingKnockId = null;
      owner.pendingKnockRoom = null;
    }
    owner._send(
      type: 'knock_failed',
      data: <String, Object?>{'knock_id': knock.id, 'outcome': 'timeout'},
      re: null,
    );
  }
}

/// Sends one push to every connected seat of [room] but [exceptToken], one
/// seat at a time, so a `room` can differ for the host.
void sendToSeatsExcept(
  RoomHub hub,
  Room room, {
  required String? exceptToken,
  required String type,
  required Map<String, Object?> data,
}) {
  for (final Seat seat in room.seats) {
    if (seat.seatToken == exceptToken || !seat.connected) {
      continue;
    }
    hub.sendToSeatToken(
      code: room.code,
      seatToken: seat.seatToken,
      type: type,
      data: data,
    );
  }
}

/// Publishes what knocks did, in order, section 31 items 3 to 5:
///
/// - opened: `knock` to the host with its `seq`, the same `seq` as a `room`
///   to every other seat;
/// - closed: `knock_closed` to the host and a `room` to every other seat at
///   the close's `seq`, and `knock_failed` to the knocker (then `ROOM_FULL`
///   for `full` and `switched_off`), which holds no seat; an accepted knock
///   sends the knocker nothing here, its seat follows;
/// - seated: `seat_assigned` then `room` to the knocker, now attached to the
///   room, and `player_joined` to everyone else.
///
/// [requester] is the host socket whose message caused these, and
/// [requesterRe] the id its own copy of the host frames answers. A knocker
/// that is [knockerRequester] gets [knockerRe] on its `knock_failed`. The
/// knocker that is [silentKnocker] (a socket moving on, item 12 a) is sent
/// nothing: only the host hears of the close.
void publishKnockEvents(
  RoomHub hub,
  List<KnockEvent> events, {
  Connection? requester,
  String? requesterRe,
  Connection? knockerRequester,
  String? knockerRe,
  Connection? silentKnocker,
}) {
  for (final KnockEvent event in events) {
    final String code = event.room.code;
    final String? hostToken = event.hostSeatToken;
    void toHost(String type, Map<String, Object?> data) {
      if (hostToken == null) {
        return;
      }
      if (requester != null &&
          requesterRe != null &&
          requester.seatToken == hostToken) {
        requester._send(type: type, data: data, re: requesterRe);
        return;
      }
      hub.sendToSeatToken(
        code: code,
        seatToken: hostToken,
        type: type,
        data: data,
      );
    }

    switch (event) {
      case KnockOpened():
        toHost('knock', <String, Object?>{
          'knock_id': event.knock.id,
          'name': event.knock.name,
          'expires_ms': knockLifetimeMs,
          'seq': event.seq,
        });
        sendToSeatsExcept(
          hub,
          event.room,
          exceptToken: hostToken,
          type: 'room',
          data: event.others,
        );
      case KnockClosed():
        toHost('knock_closed', <String, Object?>{
          'knock_id': event.knock.id,
          'outcome': event.outcome,
          'seq': event.seq,
        });
        sendToSeatsExcept(
          hub,
          event.room,
          exceptToken: hostToken,
          type: 'room',
          data: event.others,
        );
        final Object? owner = event.knock.owner;
        if (owner is Connection) {
          if (owner.pendingKnockId == event.knock.id) {
            owner.pendingKnockId = null;
            owner.pendingKnockRoom = null;
          }
          if (event.outcome != 'accepted' && !identical(owner, silentKnocker)) {
            owner._send(
              type: 'knock_failed',
              data: <String, Object?>{
                'knock_id': event.knock.id,
                'outcome': event.outcome,
                if (event.ban != null) 'ban': event.ban!.toJson(),
              },
              re: identical(owner, knockerRequester) ? knockerRe : null,
            );
            if (event.outcome == 'full' || event.outcome == 'switched_off') {
              owner._sendError(
                ProtocolError.roomFull,
                re: event.knock.requestId.isEmpty
                    ? null
                    : event.knock.requestId,
              );
            }
          }
        }
      case KnockSeated():
        final Object? owner = event.knock.owner;
        if (owner is Connection) {
          owner.roomCode = code;
          owner.seatToken = event.seat.seatToken;
          hub.attach(code: code, conn: owner);
          owner._send(
            type: 'seat_assigned',
            data: buildSeatAssigned(event.seat),
            re: null,
          );
          owner._send(
            type: 'room',
            data: event.snapshot,
            re: event.knock.requestId.isEmpty ? null : event.knock.requestId,
          );
          hub.broadcast(
            code: code,
            type: 'player_joined',
            data: buildPlayerJoined(event.seat, event.seq),
            exceptConn: owner,
          );
        }
    }
  }
}

/// Section 33 item 4: drops every ticket detached for 30 000 ms or more, one
/// log line each. Run by the one-second sweep, and before a `find_game` is
/// answered so a ticket at exactly 30 000 ms is never re-attached.
void expireWaitingLine(RoomRegistry registry) {
  final int gone = registry.line.expire();
  for (int i = 0; i < gone; i++) {
    // ignore: avoid_print
    print('room=- type=- id=- seat=- outcome=ticket_expired');
  }
}

/// Section 33 item 4: one seating pass over the waiting line, published.
/// A seated socket gets `seat_assigned` then `room`, neither with `re`, and
/// the room it joined gets `player_joined`, as a link join; the head ticket
/// of a "two strangers" room gets `seat_assigned` then `room` as its host.
/// Then every attached ticket whose position is not the one it was last told
/// gets a fresh `queued` (same ticket, no `re`, no `seq`).
void serveWaitingLine(RoomRegistry registry, RoomHub hub) {
  if (registry.line.isEmpty) {
    return;
  }
  for (final LineEvent event in registry.serveLine()) {
    final String code = event.room.code;
    final Object? owner = event.ticket.owner;
    final Connection? conn = owner is Connection ? owner : null;
    if (conn != null) {
      conn.roomCode = code;
      conn.seatToken = event.seat.seatToken;
      hub.attach(code: code, conn: conn);
      conn._send(
        type: 'seat_assigned',
        data: buildSeatAssigned(event.seat),
        re: null,
      );
      conn._send(type: 'room', data: event.snapshot, re: null);
    }
    switch (event) {
      case LineSeated():
        hub.broadcast(
          code: code,
          type: 'player_joined',
          data: buildPlayerJoined(event.seat, event.seq),
          exceptConn: conn,
        );
        // ignore: avoid_print
        print('room=$code type=- id=- seat=${event.seat.seat} '
            'outcome=line_seated via=public seq=${event.seq}');
      case LineRoomCreated():
        // ignore: avoid_print
        print('room=$code type=- id=- seat=${event.seat.seat} '
            'outcome=line_room_created players=${event.room.players} '
            'open=${event.room.open} seq=${event.seq}');
    }
  }
  for (final Ticket ticket in registry.line.takePositionChanges()) {
    final Object? owner = ticket.owner;
    if (owner is Connection) {
      owner._send(
        type: 'queued',
        data: <String, Object?>{
          'ticket': ticket.id,
          'position': ticket.toldPosition,
        },
        re: null,
      );
    }
  }
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
    this.clientBuild = 0,
  });

  final WebSocketChannel channel;
  final String ip;
  final RoomRegistry registry;
  final RateLimiter rateLimiter;
  final Clock clock;
  final RoomHub hub;
  final Random random;

  /// The build the upgrade request's header carried, section 27 rule 2; `0`
  /// when it was absent or unreadable. Informational: only the log line
  /// [refuseUpdateRequired] writes reads it.
  final int clientBuild;

  /// True once [refuseUpdateRequired] has run. A refused socket's inbound
  /// frames are drained and dropped by [handleFrame].
  bool _refused = false;

  /// Set on a successful `create_room`, `join_room` or `resume`; cleared on
  /// a voluntary `leave_room` or when this socket is displaced by a resume
  /// takeover from elsewhere. Read, not trusted blindly: every registry call
  /// still re-validates `seatToken` against the room's live seats.
  String? roomCode;
  String? seatToken;

  /// Section 31 item 3: the open knock this socket made, and the room it is
  /// waiting at. Null when none. At most one at a time.
  String? pendingKnockId;
  String? pendingKnockRoom;

  bool _closed = false;

  bool get _hasIdentity => roomCode != null && seatToken != null;

  /// Section 33 item 3: this socket holds a live seat. An identity whose room
  /// was reaped, or whose seat was freed or kicked, holds none.
  bool get _holdsSeat {
    if (!_hasIdentity) {
      return false;
    }
    final Room? room = registry.lookup(roomCode!);
    return room != null &&
        room.seats.any((Seat s) => s.seatToken == seatToken && !s.tokenDead);
  }

  /// Entry point for one raw frame off the wire, text or binary. Implements
  /// the first five ladder steps; hands a validated envelope to [_dispatch]
  /// for the rest.
  Future<void> handleFrame(Object rawFrame) async {
    // Section 27 rule 4: nothing a refused socket sends is processed, logged
    // against a room, or counted against a rate limit.
    if (_refused) {
      return;
    }
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

    // Steps 2 to 6: JSON parse, v, t, id shape, d presence.
    String? text;
    try {
      text = rawFrame is String ? rawFrame : utf8.decode(bytes);
    } on FormatException {
      text = null;
    }
    final EnvelopeResult parsed = text == null
        ? EnvelopeError(
            error: ProtocolError.badField,
            closeConnection: false,
          )
        : parseEnvelope(
            text,
            // Section 31 item 11 (e2): `kick` is a known type everywhere; the
            // PLAYING kick of section 28 is gated by ruleset in
            // `_handleKick`, which answers BAD_TYPE as before.
            kickKnown: true,
          );
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

    // Section 33 item 4: whatever this message changed (a room created or
    // reopened, a seat freed, a host back, a ticket made or dropped), the
    // line is served from its head. A pass that finds nothing to do changes
    // nothing, so running it after every message is the same as running it
    // after the ones that matter.
    try {
      serveWaitingLine(registry, hub);
    } catch (error, stack) {
      // ignore: avoid_print
      print('room=- type=${envelope.type} id=${envelope.id} seat=- '
          'outcome=line_pass_failed error=$error\n$stack');
    }
  }

  /// Section 27 rule 4. Sends the one `UPDATE_REQUIRED` error, with no `re`
  /// and the minimum in `min_build`, logs the refusal, and closes with
  /// [closeCodeUpdateRequired]. Called by the socket layer before any
  /// inbound frame is read; every frame that arrives afterwards is dropped.
  Future<void> refuseUpdateRequired({required int minBuild}) async {
    _refused = true;
    final Map<String, Object?> data = errorPayload(
      ProtocolError.updateRequired,
      defaultErrorMessage(ProtocolError.updateRequired),
    )..['min_build'] = minBuild;
    _send(type: 'error', data: data, re: null);
    _log(
      type: '-',
      id: '-',
      outcome: '${wireErrorCode(ProtocolError.updateRequired)} '
          'build=$clientBuild',
    );
    await close(
      code: closeCodeUpdateRequired,
      reason: wireErrorCode(ProtocolError.updateRequired),
    );
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
      case 'decline_release':
        _handleDeclineRelease(envelope);
      case 'rematch':
        _handleRematch(envelope);
      case 'game_log':
        _handleGameLog(envelope);
      case 'emote':
        _handleEmote(envelope);
      case 'kick':
        _handleKick(envelope);
      case 'answer_knock':
        _handleAnswerKnock(envelope);
      case 'set_guest_approval':
        _handleSetGuestApproval(envelope);
      case 'find_game':
        _handleFindGame(envelope);
      case 'cancel_find':
        _handleCancelFind(envelope);
      case 'play_computer':
        _handlePlayComputer(envelope);
      case 'fill_computer':
        _handleFillComputer(envelope);
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
    // Section 33 item 4: a queued socket that creates a room leaves the line.
    _dropOwnTicket();
    if (!rateLimiter.recordCreateRoom(ip)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }
    _withdrawOwnKnock();

    const Set<String> allowedKeys = <String>{
      'name',
      'players',
      'rules',
      'install',
      'open',
    };
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    // Section 32 item 6: `install` is optional on `create_room`, with
    // section 31 item 2's shape.
    final Object? rawCreateInstall = envelope.data['install'];
    if (envelope.data.containsKey('install') &&
        (rawCreateInstall is! String ||
            !_installPattern.hasMatch(rawCreateInstall))) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    // Section 33 item 1: `open` is optional, absent means false, and
    // anything but a bool is a malformed field.
    final Object? rawOpen = envelope.data['open'];
    if (envelope.data.containsKey('open') && rawOpen is! bool) {
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
      install: rawCreateInstall is String ? rawCreateInstall : null,
      ip: ip,
      open: rawOpen == true,
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
    // Section 33 item 4: a queued socket that joins a room leaves the line.
    _dropOwnTicket();
    if (!rateLimiter.recordJoinOrResume(ip)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }

    // Section 31 item 2: the room is named by `code` or by `link`, never both
    // and never neither; `install` may ride on either.
    const Set<String> allowedKeys = <String>{'code', 'link', 'name', 'install'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final bool hasCode = envelope.data.containsKey('code');
    final bool hasLink = envelope.data.containsKey('link');
    final Object? rawCode = envelope.data['code'];
    final Object? rawLink = envelope.data['link'];
    final Object? rawName = envelope.data['name'];
    final Object? rawInstall = envelope.data['install'];
    if (hasCode == hasLink ||
        rawName is! String ||
        (hasCode && rawCode is! String) ||
        (hasLink && rawLink is! String)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    if (envelope.data.containsKey('install') &&
        (rawInstall is! String || !_installPattern.hasMatch(rawInstall))) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    // Section 32 item 6: a join by `code` requires `install`; a `link` join
    // keeps it optional.
    if (hasCode && !envelope.data.containsKey('install')) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    // The typed code as the log and the lookup see it: folded, and only when
    // it is well-formed, so a probe string never reaches a log line.
    final String? foldedCode = hasCode ? foldRoomCode(rawCode as String) : null;
    final String logRoom =
        foldedCode != null && isWellFormedRoomCode(foldedCode)
            ? foldedCode
            : '-';

    if (hasCode) {
      // Section 32 item 5: the typed-code window, after payload validation and
      // before the ban check.
      if (!rateLimiter.recordTypedCode(ip)) {
        _reject(envelope, ProtocolError.rateLimited, room: '-');
        return;
      }
      // Section 32 item 9: a ban answers before the lookup, whether the room
      // exists or not.
      final BanInfo? ban = registry.codeBan(
        install: rawInstall as String,
        ip: ip,
      );
      if (ban != null) {
        _reject(envelope, ProtocolError.codeBanned, room: '-', ban: ban);
        return;
      }
    }

    // Section 31 item 3: one open knock per socket. A knock whose room is
    // gone (reaped before its minute ran out) no longer counts.
    final String? pendingId = pendingKnockId;
    if (pendingId != null) {
      if (registry.hasOpenKnock(pendingKnockRoom!, pendingId)) {
        _reject(envelope, ProtocolError.rateLimited);
        return;
      }
      pendingKnockId = null;
      pendingKnockRoom = null;
    }

    final String? install = rawInstall is String ? rawInstall : null;
    final JoinResult result = registry.joinRoom(
      code: hasCode ? rawCode as String : null,
      link: hasLink ? rawLink as String : null,
      name: rawName,
      install: install,
      ip: ip,
      requestId: envelope.id,
      owner: this,
    );
    if (result is JoinFailure) {
      // A link is never logged, and never stands in for the room code.
      _reject(envelope, result.error, room: logRoom);
      return;
    }
    if (result is JoinKnocked) {
      pendingKnockId = result.knock.id;
      pendingKnockRoom = result.room.code;
      _send(
        type: 'knock_pending',
        data: <String, Object?>{
          'knock_id': result.knock.id,
          'expires_ms': knockLifetimeMs,
        },
        re: envelope.id,
      );
      publishKnockEvents(hub, <KnockEvent>[result.opened]);
      _log(
        type: envelope.type,
        id: envelope.id,
        outcome: 'ok knock_opened knock=${result.knock.id}',
        room: result.room.code,
        seq: result.opened.seq,
      );
      return;
    }
    final JoinOk ok = result as JoinOk;

    roomCode = ok.room.code;
    seatToken = ok.seat.seatToken;
    hub.attach(code: ok.room.code, conn: this);

    _send(type: 'seat_assigned', data: buildSeatAssigned(ok.seat), re: null);
    _send(
      type: 'room',
      data: _snapshotFor(ok.room),
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
      outcome: 'ok via=${ok.seat.via}',
      room: ok.room.code,
      seat: ok.seat.seat,
      seq: ok.room.seq,
    );
  }

  /// Section 31 item 12 (a): a socket that moves on to `create_room` or
  /// `resume` closes its open knock `withdrawn` first, so an accept can never
  /// re-home it.
  void _withdrawOwnKnock() {
    final String? knockId = pendingKnockId;
    if (knockId == null) {
      return;
    }
    final String knockRoom = pendingKnockRoom!;
    pendingKnockId = null;
    pendingKnockRoom = null;
    publishKnockEvents(
      hub,
      registry.withdrawKnock(knockRoom, knockId),
      silentKnocker: this,
    );
  }

  /// Section 33 item 4: drops the ticket this socket holds, if any. Returns
  /// whether it held one. The positions behind it are told by the pass that
  /// follows the message.
  bool _dropOwnTicket() {
    final Ticket? ticket = registry.line.ticketOf(this);
    if (ticket == null) {
      return false;
    }
    registry.line.remove(ticket);
    return true;
  }

  /// `find_game`, section 33 item 3. The ladder: the per-IP `join_room`
  /// limit (`RATE_LIMITED`), a seat already held (`ALREADY_SEATED`), then,
  /// after this socket's open knock is withdrawn and any ticket it holds is
  /// dropped, the payload: `name` as section 4, `install` required with
  /// section 31 item 2's shape, `ticket` an optional string, nothing else
  /// (`BAD_FIELD`). No ban and no typed-code window apply.
  ///
  /// A matchable room that does not bar the device seats the caller at once,
  /// `via: "public"` (`seat_assigned`, then `room` with `re`, `player_joined`
  /// to the room). Otherwise the caller holds a ticket: the one it named, in
  /// its old place, when that is still held for the same `install`, else a
  /// new one at the tail; it is answered by `queued` with `re`.
  void _handleFindGame(ParsedEnvelope envelope) {
    if (!rateLimiter.recordJoinOrResume(ip)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }
    if (_holdsSeat) {
      _reject(envelope, ProtocolError.alreadySeated);
      return;
    }
    _withdrawOwnKnock();
    _dropOwnTicket();

    const Set<String> allowedKeys = <String>{'name', 'install', 'ticket'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField, room: '-');
      return;
    }
    final Object? rawName = envelope.data['name'];
    final String? name =
        rawName is String ? registry.validDisplayName(rawName) : null;
    if (name == null) {
      _reject(envelope, ProtocolError.badField, room: '-');
      return;
    }
    final Object? rawInstall = envelope.data['install'];
    if (rawInstall is! String || !_installPattern.hasMatch(rawInstall)) {
      _reject(envelope, ProtocolError.badField, room: '-');
      return;
    }
    final Object? rawTicket = envelope.data['ticket'];
    if (envelope.data.containsKey('ticket') && rawTicket is! String) {
      _reject(envelope, ProtocolError.badField, room: '-');
      return;
    }

    expireWaitingLine(registry);
    // An unknown, expired or mismatched ticket is a fresh find_game: null
    // here, and nothing in the line changed.
    final Ticket? held = rawTicket is String
        ? registry.line.reattach(
            id: rawTicket,
            install: rawInstall,
            name: name,
            ip: ip,
            owner: this,
          )
        : null;

    final Room? room = registry.matchableRoomFor(install: rawInstall, ip: ip);
    if (room != null) {
      final JoinResult result = registry.seatPublic(
        room,
        name: name,
        install: rawInstall,
        ip: ip,
      );
      if (result is JoinOk) {
        if (held != null) {
          registry.line.remove(held);
        }
        roomCode = result.room.code;
        seatToken = result.seat.seatToken;
        hub.attach(code: result.room.code, conn: this);
        _send(
          type: 'seat_assigned',
          data: buildSeatAssigned(result.seat),
          re: null,
        );
        _send(type: 'room', data: _snapshotFor(result.room), re: envelope.id);
        hub.broadcast(
          code: result.room.code,
          type: 'player_joined',
          data: buildPlayerJoined(result.seat, result.room.seq),
          exceptConn: this,
        );
        _log(
          type: envelope.type,
          id: envelope.id,
          outcome: 'ok seated via=public',
          room: result.room.code,
          seat: result.seat.seat,
          seq: result.room.seq,
        );
        return;
      }
      // matchableRoomFor has just said this room takes this device; say that
      // the two checks drifted apart and queue the caller instead.
      _log(
        type: envelope.type,
        id: envelope.id,
        outcome: 'seat_public_failed '
            'error=${wireErrorCode((result as JoinFailure).error)}',
        room: room.code,
      );
    }

    final Ticket ticket = held ??
        registry.line.enqueue(
          name: name,
          install: rawInstall,
          ip: ip,
          owner: this,
        );
    final int position = registry.line.positionOf(ticket);
    ticket.toldPosition = position;
    _send(
      type: 'queued',
      data: <String, Object?>{'ticket': ticket.id, 'position': position},
      re: envelope.id,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok queued position=$position '
          '${held != null ? 'reattached' : 'new'}',
      room: '-',
    );
  }

  /// `play_computer`, section 34 item 2. The ladder: a seat already held
  /// (`ALREADY_SEATED`), the per-IP creation limit (`RATE_LIMITED`, as
  /// `create_room`), then the payload: `name` as section 4, `players` 2 or 4,
  /// `install` as section 31 item 2, `client_seed` as `set_seed`, nothing
  /// else (`BAD_FIELD`). A ticket or an open knock this socket holds is
  /// dropped first. The caller gets `seat_assigned`, `room` (with `re`),
  /// every `seat_seed`, then `game_started` and the first `turn`.
  void _handlePlayComputer(ParsedEnvelope envelope) {
    if (_holdsSeat) {
      _reject(envelope, ProtocolError.alreadySeated);
      return;
    }
    _dropOwnTicket();
    if (!rateLimiter.recordCreateRoom(ip)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }
    _withdrawOwnKnock();

    const Set<String> allowedKeys = <String>{
      'name',
      'players',
      'install',
      'client_seed',
    };
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    final Object? rawInstall = envelope.data['install'];
    if (envelope.data.containsKey('install') &&
        (rawInstall is! String || !_installPattern.hasMatch(rawInstall))) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    final Object? rawName = envelope.data['name'];
    final Object? rawPlayers = envelope.data['players'];
    if (rawName is! String || rawPlayers is! int) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    final Object? rawSeed = envelope.data['client_seed'];
    if (envelope.data.containsKey('client_seed') && rawSeed is! String) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final PlayComputerResult result = registry.playComputer(
      name: rawName,
      players: rawPlayers,
      clientSeed: rawSeed,
      install: rawInstall is String ? rawInstall : null,
      ip: ip,
    );
    if (result is PlayComputerFailure) {
      _reject(envelope, result.error);
      return;
    }
    final PlayComputerOk ok = result as PlayComputerOk;

    roomCode = ok.room.code;
    seatToken = ok.seat.seatToken;
    hub.attach(code: ok.room.code, conn: this);
    _send(type: 'seat_assigned', data: buildSeatAssigned(ok.seat), re: null);
    _send(type: 'room', data: ok.snapshot, re: envelope.id);
    for (final SeededSeat seeded in ok.seeds) {
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
    _publishStart(
      envelope,
      ok.start,
      unsolicited: true,
      logName: envelope.type,
    );
  }

  /// `fill_computer`, section 34 item 3. Identity first, like the other
  /// socket-identified messages; the registry runs the rest of the ladder.
  /// The host's copy of the first frame it is sent carries `re`.
  void _handleFillComputer(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final FillComputerResult result = registry.fillComputer(
      code: roomCode!,
      seatToken: seatToken!,
      data: envelope.data,
    );
    if (result is FillComputerFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    final FillComputerOk ok = result as FillComputerOk;
    final String code = ok.room.code;

    publishKnockEvents(
      hub,
      ok.knockEvents,
      requester: this,
      requesterRe: envelope.id,
    );
    bool answered = ok.knockEvents.isNotEmpty;
    for (final ComputerJoin join in ok.joins) {
      final Map<String, Object?> joined =
          buildPlayerJoined(join.seat, join.joinedSeq);
      if (answered) {
        hub.broadcast(code: code, type: 'player_joined', data: joined);
      } else {
        answered = true;
        _sendAndBroadcast(
          room: code,
          type: 'player_joined',
          data: joined,
          re: envelope.id,
        );
      }
      final SeededSeat? seeded = join.seeded;
      if (seeded != null) {
        hub.broadcast(
          code: code,
          type: 'seat_seed',
          data: buildSeatSeed(
            seat: seeded.seat.seat,
            clientSeed: seeded.seat.clientSeed!,
            origin: seeded.seat.seedOrigin!,
            seq: seeded.seq,
          ),
        );
      }
    }
    _publishStart(
      envelope,
      ok.start,
      unsolicited: true,
      logName: envelope.type,
    );
  }

  /// `cancel_find`, section 33 item 4: drops this socket's ticket and is
  /// answered by `find_cancelled` with `re`, also when it held none. `d`
  /// must be empty.
  void _handleCancelFind(ParsedEnvelope envelope) {
    if (envelope.data.isNotEmpty) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    final bool held = _dropOwnTicket();
    _send(
      type: 'find_cancelled',
      data: const <String, Object?>{},
      re: envelope.id,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: held ? 'ok ticket_dropped' : 'ok no_ticket',
    );
  }

  /// `answer_knock`, section 31 item 4. Identity first, like the other
  /// socket-identified messages; the registry runs the rest of the ladder.
  /// The host's own copy of each frame its answer caused carries `re`.
  void _handleAnswerKnock(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final AnswerKnockResult result = registry.answerKnock(
      code: roomCode!,
      seatToken: seatToken!,
      data: envelope.data,
    );
    if (result is AnswerKnockFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    final AnswerKnockOk ok = result as AnswerKnockOk;
    publishKnockEvents(
      hub,
      ok.events,
      requester: this,
      requesterRe: envelope.id,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok knock=${ok.events.first.knock.id} '
          '${(ok.events.first as KnockClosed).outcome}',
      room: ok.room.code,
      seq: ok.events.last.seq,
    );
  }

  /// `set_guest_approval`, section 31 item 5. Answered by `room` with `re`,
  /// the same `room` going to every other seat at the same `seq`; knocks it
  /// settled follow, one frame set each.
  void _handleSetGuestApproval(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final SetApprovalResult result = registry.setGuestApproval(
      code: roomCode!,
      seatToken: seatToken!,
      data: envelope.data,
    );
    if (result is SetApprovalFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    final SetApprovalOk ok = result as SetApprovalOk;
    _send(type: 'room', data: ok.hostSnapshot, re: envelope.id);
    sendToSeatsExcept(
      hub,
      ok.room,
      exceptToken: seatToken,
      type: 'room',
      data: ok.othersSnapshot,
    );
    publishKnockEvents(hub, ok.events);
    if (ok.events.isNotEmpty) {
      // The answer above described the room as the toggle left it; the knocks
      // it settled moved the room on. The host is owed the room as it ends,
      // at that final `seq` (a state description, not a new step).
      _send(type: 'room', data: _snapshotFor(ok.room), re: null);
    }
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok guest_approval=${ok.room.guestApproval}',
      room: ok.room.code,
      seq: ok.events.isEmpty ? ok.seq : ok.events.last.seq,
    );
  }

  /// The `room` this socket is sent for [room]: the host's own copy lists the
  /// open knocks, every other seat's does not (section 31 item 3).
  Map<String, Object?> _snapshotFor(Room room) {
    bool isHost = false;
    for (final Seat seat in room.seats) {
      if (seat.seatToken == seatToken && seat.seat == room.hostSeat) {
        isHost = true;
        break;
      }
    }
    return buildRoomSnapshot(room, now: clock.now, forHost: isHost);
  }

  /// A `room` to every socket of [room] but this one. With no knock open it
  /// is one broadcast of one snapshot, as ever; with knocks open the host's
  /// copy is the one that lists them.
  void _broadcastRoomToOthers(Room room) {
    if (room.knocks.isEmpty) {
      hub.broadcast(
        code: room.code,
        type: 'room',
        data: buildRoomSnapshot(room, now: clock.now),
        exceptConn: this,
      );
      return;
    }
    for (final Seat seat in room.seats) {
      if (seat.seatToken == seatToken || !seat.connected) {
        continue;
      }
      hub.sendToSeatToken(
        code: room.code,
        seatToken: seat.seatToken,
        type: 'room',
        data: buildRoomSnapshot(
          room,
          now: clock.now,
          forHost: seat.seat == room.hostSeat,
        ),
      );
    }
  }

  Future<void> _handleResume(ParsedEnvelope envelope) async {
    // Section 33 item 4: a queued socket that resumes a seat leaves the line.
    _dropOwnTicket();
    if (!rateLimiter.recordJoinOrResume(ip)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }
    _withdrawOwnKnock();

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

    // docs/PROTOCOL.md section 15 rule 2 (section 8 rule 4): every resume
    // gets its own `seat_assigned` before the `room`, on this socket,
    // whether or not the seat's number ever moved while it was away --
    // including a takeover of a seat that was already connected (section 8
    // rule 6, `displaced` below). The client takes its seat from this, never
    // from what it stored before sending `resume`.
    _send(
      type: 'seat_assigned',
      data: buildSeatAssigned(ok.seat),
      re: null,
    );
    _send(
      type: 'room',
      data: _snapshotFor(ok.room),
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
        data: buildPresence(ok.seat.seat, true, ok.presenceSeq!),
        exceptConn: this,
      );
    }
    // docs/PROTOCOL.md section 26 rule 5: an away seat that came back on
    // turn restarted its segment at the full budget, and the other sockets
    // are owed the `turn` that says so, after the `presence` and at the next
    // `seq`. The resuming socket is owed nothing: its `room` above was built
    // after both and already carries the restarted segment.
    if (ok.turnSeq != null) {
      final TurnQueueFields fields = turnQueueFields(ok.room.game!);
      hub.broadcast(
        code: ok.room.code,
        type: 'turn',
        data: buildTurn(
          seat: ok.room.game!.currentSeat,
          deadlineMs: ok.turnDeadlineMs!,
          seq: ok.turnSeq!,
          phase: fields.phase,
          queue: fields.queue,
          value: fields.value,
          legal: fields.legal,
          legalByFace: fields.legalByFace,
          release: fields.release,
          offer: fields.offer,
          // Section 30 rule 5: the count the room stored from the engine's
          // `SixesQueued` for this turn, none once the seat has rolled.
          banked: ok.room.isRuleset202612 &&
                  ok.room.queuedBankedSeat == ok.room.game!.currentSeat
              ? ok.room.queuedBankedCount
              : null,
          graceMs: ok.turnGraceMs,
        ),
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

    // docs/PROTOCOL.md section 16.9 rule 5: the resume's own frames are all
    // out; if this seat's return completed a rematch LOBBY, start it now. The
    // takeover of an already connected seat is evaluated too, the predicate
    // decides. `displaced` is detached by `hub.attach` above, so it is not
    // sent the start.
    _startRematchIfReady(envelope, ok.room.code);

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
    if (liveRoom != null) {
      if (liveRoom.state == RoomState.finished) {
        _reject(envelope, ProtocolError.gameOver);
        return;
      }
      if (liveRoom.state != RoomState.lobby) {
        _reject(envelope, ProtocolError.roomStarted);
        return;
      }
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
    _publishStart(envelope, result as StartOk);
  }

  /// docs/PROTOCOL.md section 16.9 rule 5: after a `resume` or an accepted
  /// `leave_room`, starts the rematch when [RoomRegistry.rematchAutoStartHolds]
  /// holds for the room [code] as it stands now. [envelope] is the message that
  /// caused the evaluation; its type is named in the log line. A no-op in any room that is
  /// not a rematch LOBBY, so the first LOBBY, PLAYING and FINISHED are
  /// untouched. Nothing is awaited between the check and the start.
  void _startRematchIfReady(ParsedEnvelope envelope, String code) {
    final Room? room = registry.lookup(code);
    if (room == null || !registry.rematchAutoStartHolds(room)) {
      return;
    }
    _publishStart(
      envelope,
      registry.startRematchAuto(room),
      unsolicited: true,
    );
  }

  /// Every frame a successful start decided on, in order: `docs/PROTOCOL.md`
  /// section 16.4's host-forced removal and re-seat, if this start came from
  /// that path, then section 11.2's server-drawn `seat_seed`s, then
  /// `game_started`, then section 13.1's standalone `turn`. Shared by
  /// [_handleStartGame] and the section 16.4 "Everyone accepted" auto-start
  /// inside [_handleRematch], so the one client message that triggered this
  /// -- a `start_game` or a `rematch` -- is the `id` every frame in the burst
  /// answers with `re` on this socket's own copy.
  ///
  /// [unsolicited] is the section 16.9 rule 5 start, triggered by a `resume`
  /// or a `leave_room` and answering no request: [envelope] is then only the
  /// trigger, named in the log line, and no frame carries `re` on any socket.
  /// Every frame goes through `hub.broadcast` to every attached socket, the
  /// resuming one included; a `leave_room` socket is already detached and
  /// gets nothing. Such a start is always the plain section 16.4 "Everyone
  /// accepted" one, so the removal and re-seat steps below are empty for it.
  void _publishStart(
    ParsedEnvelope envelope,
    StartOk ok, {
    bool unsolicited = false,
    String? logName,
  }) {
    final String? re = unsolicited ? null : envelope.id;
    void emit(String type, Map<String, Object?> data) {
      if (unsolicited) {
        hub.broadcast(code: ok.room.code, type: type, data: data);
        return;
      }
      _send(type: type, data: data, re: re);
      hub.broadcast(
        code: ok.room.code,
        type: type,
        data: data,
        exceptConn: this,
      );
    }

    // docs/PROTOCOL.md section 16.4, "Not everyone": every occupied seat
    // this start removed for not being ready, ascending seat order, one
    // `player_left` each at its own seq, before anything else this start
    // does. Section 18 rule 2: each carries `host_seat`. Empty, and
    // therefore a no-op, for every start that did not come through that
    // path.
    for (final RemovedSeat removed in ok.removedSeats) {
      _sendAndBroadcast(
        room: ok.room.code,
        type: 'player_left',
        data: buildPlayerLeft(removed.seat.seat, ok.room.hostSeat, removed.seq),
        re: re,
      );
      // docs/PROTOCOL.md section 16.9 rule 1: that was the last thing this
      // removed seat's own socket, if it was connected, is owed from this
      // room -- detach it here, the same way `_handleLeaveRoom` detaches a
      // seat that leaves by its own hand, except this one is not the
      // connection currently running this call.
      final Connection? removedConn = hub.detachSeatToken(
        code: ok.room.code,
        seatToken: removed.seat.seatToken,
      );
      removedConn?.roomCode = null;
      removedConn?.seatToken = null;
    }

    // docs/PROTOCOL.md section 15 rule 1, reused by section 16.4's re-seat:
    // seat_assigned to every connected seat whose number this start just
    // changed, then the room that carries the new seating -- the caller's
    // own copy before its own room reply, everyone else's connected moved
    // seat before the room broadcast. Null `reseatSeq` means this start did
    // not remove or re-seat anyone, so there is nothing to announce here.
    if (ok.reseatSeq != null) {
      final Map<String, Object?> reseatRoom = ok.reseatRoom!;
      for (final Seat moved in ok.movedSeats) {
        if (moved.seatToken == seatToken) {
          _send(
              type: 'seat_assigned', data: buildSeatAssigned(moved), re: null);
        }
      }
      _send(type: 'room', data: reseatRoom, re: re);
      for (final Seat moved in ok.movedSeats) {
        if (moved.seatToken == seatToken || !moved.connected) {
          continue;
        }
        hub.sendToSeatToken(
          code: ok.room.code,
          seatToken: moved.seatToken,
          type: 'seat_assigned',
          data: buildSeatAssigned(moved),
        );
      }
      hub.broadcast(
        code: ok.room.code,
        type: 'room',
        data: reseatRoom,
        exceptConn: this,
      );
    }

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

    emit('game_started', data);

    // docs/PROTOCOL.md section 13.1: a standalone `turn` frame always
    // follows `game_started`, announcing the opening segment the same way
    // every later one is announced, at its own seq one greater than
    // `game_started`'s. Section 21.3 rule 1: every `turn` frame carries
    // `phase` and `queue`; the opening one is always `await_roll` with an
    // empty queue, since nobody has rolled yet.
    final TurnQueueFields openingFields = turnQueueFields(ok.room.game!);
    final Map<String, Object?> turnData = buildTurn(
      seat: ok.room.game!.currentSeat,
      deadlineMs: ok.nextDeadlineMs,
      seq: ok.turnSeq,
      phase: openingFields.phase,
      queue: openingFields.queue,
    );
    emit('turn', turnData);
    publishKnockEvents(hub, ok.knockEvents);
    _log(
      type: logName ??
          (unsolicited ? 'rematch_auto_start_${envelope.type}' : envelope.type),
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
    if (liveRoom != null) {
      if (liveRoom.state == RoomState.finished) {
        _reject(envelope, ProtocolError.gameOver);
        return;
      }
      if (liveRoom.state != RoomState.lobby) {
        _reject(envelope, ProtocolError.roomStarted);
        return;
      }
      // docs/PROTOCOL.md section 16.4: "set_players in a rematch LOBBY is
      // WRONG_PHASE: the ready list decides the count."
      if (liveRoom.rematch != null) {
        _reject(envelope, ProtocolError.wrongPhase);
        return;
      }
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
    final Map<String, Object?> data = _snapshotFor(ok.room);

    // docs/PROTOCOL.md section 15 rule 1: every connected seat whose number
    // this call actually changed gets its own `seat_assigned` before the
    // `room` that carries the new seating reaches it -- the caller's own
    // copy before its `room` reply below, everyone else's connected moved
    // seat before the `room` broadcast that follows. A moved seat that is
    // not connected gets nothing here; it learns its new number on `resume`
    // (rule 2, `_handleResume`).
    for (final Seat moved in ok.movedSeats) {
      if (moved.seatToken == seatToken) {
        _send(
          type: 'seat_assigned',
          data: buildSeatAssigned(moved),
          re: null,
        );
      }
    }
    _send(type: 'room', data: data, re: envelope.id);
    for (final Seat moved in ok.movedSeats) {
      if (moved.seatToken == seatToken || !moved.connected) {
        continue;
      }
      hub.sendToSeatToken(
        code: ok.room.code,
        seatToken: moved.seatToken,
        type: 'seat_assigned',
        data: buildSeatAssigned(moved),
      );
    }
    _broadcastRoomToOthers(ok.room);
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
    if (liveRoom.state == RoomState.finished) {
      _reject(envelope, ProtocolError.gameOver);
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

  /// `leave_room`, docs/PROTOCOL.md section 4, section 16.3 and section 18.
  void _handleLeaveRoom(ParsedEnvelope envelope) {
    // Section 31 item 4: `leave_room` withdraws this socket's open knock. A
    // socket with no seat is answered by the `knock_failed` that closes it.
    final String? knockId = pendingKnockId;
    if (knockId != null && envelope.data.isEmpty) {
      final String knockRoom = pendingKnockRoom!;
      pendingKnockId = null;
      pendingKnockRoom = null;
      final List<KnockEvent> closed =
          registry.withdrawKnock(knockRoom, knockId);
      publishKnockEvents(
        hub,
        closed,
        knockerRequester: this,
        knockerRe: envelope.id,
      );
      if (!_hasIdentity) {
        if (closed.isEmpty) {
          _reject(envelope, ProtocolError.badSeatToken);
        } else {
          _log(
            type: envelope.type,
            id: envelope.id,
            outcome: 'ok knock_withdrawn knock=$knockId',
            room: knockRoom,
            seq: closed.last.seq,
          );
        }
        return;
      }
    }
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
    final RetireOk? retire = ok.retire;
    if (retire != null) {
      _publishLeaveRetire(envelope, retire);
      return;
    }
    final bool stillSeated =
        ok.room.seats.any((Seat s) => s.seatToken == seatToken);
    final String code = ok.room.code;
    final int seatIndex = ok.seat.seat;

    hub.detach(this);
    roomCode = null;
    seatToken = null;

    final Map<String, Object?> data = stillSeated
        ? buildPresence(seatIndex, false, ok.room.seq)
        : buildPlayerLeft(seatIndex, ok.room.hostSeat, ok.room.seq);
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

    // docs/PROTOCOL.md section 16.9 rule 5: the `player_left` is sent and
    // broadcast; if the seats still occupied are now all ready and connected,
    // start the rematch. This socket is detached above, so the start never
    // reaches it.
    _startRematchIfReady(envelope, code);
  }

  /// `leave_room` that retired a playing seat, `docs/PROTOCOL.md` section 28
  /// rule 4 "left". The leaver's socket is detached first, so it is sent the
  /// one `seat_retired` (with `re`) and nothing that follows it; the rest of
  /// the room is sent every frame the retirement decided on.
  void _publishLeaveRetire(ParsedEnvelope envelope, RetireOk retire) {
    final String code = retire.room.code;
    hub.detach(this);
    roomCode = null;
    seatToken = null;

    final List<OutFrame> frames = buildRetireFrames(retire);
    // Section 35 item 3: a roll the leaver was shown goes out ahead of
    // `seat_retired`; the leaver's own answer is still that one frame.
    final OutFrame retired =
        frames.firstWhere((OutFrame frame) => frame.type == 'seat_retired');
    _send(type: retired.type, data: retired.data, re: envelope.id);
    for (final OutFrame frame in frames) {
      hub.broadcast(code: code, type: frame.type, data: frame.data);
    }
    detachFreedSeats(hub, code, retire.freed);
    _logRetire(envelope.type, envelope.id, retire);
  }

  /// `kick`, `docs/PROTOCOL.md` section 33 item 8 (which replaces section 28
  /// rule 4 "kicked"). Identity first, like the other socket-identified
  /// messages; the registry runs the rest of the ladder in the section's own
  /// order (`NOT_HOST`, `WRONG_PHASE`, `BAD_FIELD`, `ILLEGAL_MOVE`). Answered
  /// on the host's socket
  /// by the `seat_retired` broadcast with `re`; the frames that follow it
  /// (a `turn`, or `game_over` and its `player_left`s) carry `re` on this
  /// socket's copy too, as every burst a request causes does.
  bool get _playingKickKnown =>
      registry.ruleset == ruleset202611 || registry.ruleset == ruleset202612;

  void _handleKick(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(
        envelope,
        _playingKickKnown ? ProtocolError.badSeatToken : ProtocolError.badType,
      );
      return;
    }
    // Section 31 item 6 and item 11 (e2): in LOBBY the same message frees the
    // seat, on every ruleset.
    if (registry.lookup(roomCode!)?.state == RoomState.lobby) {
      _handleKickLobby(envelope);
      return;
    }
    // Section 28 rule 4: the PLAYING kick exists only on a 2026-11 or later
    // server; on any other it is as unknown as it always was.
    if (!_playingKickKnown) {
      _reject(envelope, ProtocolError.badType);
      return;
    }
    final RetireResult result = registry.kick(
      code: roomCode!,
      seatToken: seatToken!,
      data: envelope.data,
    );
    if (result is RetireFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    final RetireOk ok = result as RetireOk;
    final List<OutFrame> frames = buildRetireFrames(ok);
    // Section 33 item 8: the kicked seat's socket, when it has one, is
    // detached first; it gets the `seat_retired`, then `kicked` (with `ban`
    // when the kick's strike fired one), and nothing that follows.
    final Connection? kickedConn = hub.detachSeatToken(
      code: ok.room.code,
      seatToken: ok.seat.seatToken,
    );
    if (kickedConn != null) {
      kickedConn.roomCode = null;
      kickedConn.seatToken = null;
      // Section 35 item 3: a roll the kicked seat was shown is published
      // ahead of `seat_retired`; the kicked socket is sent `seat_retired`.
      final OutFrame retired =
          frames.firstWhere((OutFrame frame) => frame.type == 'seat_retired');
      kickedConn._send(
        type: retired.type,
        data: retired.data,
        re: null,
      );
      kickedConn._send(
        type: 'kicked',
        data: <String, Object?>{
          if (ok.ban != null) 'ban': ok.ban!.toJson(),
        },
        re: null,
      );
    }
    for (final OutFrame frame in frames) {
      _sendAndBroadcast(
        room: ok.room.code,
        type: frame.type,
        data: frame.data,
        re: envelope.id,
      );
    }
    detachFreedSeats(hub, ok.room.code, ok.freed);
    _logRetire(envelope.type, envelope.id, ok);
  }

  /// `kick` in LOBBY, section 31 item 6. The kicked socket is detached first,
  /// so it is sent `kicked` (no `seq`) and nothing that follows; every other
  /// socket gets the `player_left`, the host's copy with `re`.
  void _handleKickLobby(ParsedEnvelope envelope) {
    final KickLobbyResult result = registry.kickLobby(
      code: roomCode!,
      seatToken: seatToken!,
      data: envelope.data,
    );
    if (result is KickLobbyFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    final KickLobbyOk ok = result as KickLobbyOk;
    final String code = ok.room.code;
    final Connection? kickedConn = hub.detachSeatToken(
      code: code,
      seatToken: ok.seat.seatToken,
    );
    if (kickedConn != null) {
      kickedConn.roomCode = null;
      kickedConn.seatToken = null;
      kickedConn._send(
        type: 'kicked',
        data: <String, Object?>{
          if (ok.ban != null) 'ban': ok.ban!.toJson(),
        },
        re: null,
      );
    }
    _sendAndBroadcast(
      room: code,
      type: 'player_left',
      data: buildPlayerLeft(ok.seat.seat, ok.room.hostSeat, ok.room.seq),
      re: envelope.id,
    );
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok seat_kicked',
      room: code,
      seat: ok.seat.seat,
      seq: ok.room.seq,
    );
    _startRematchIfReady(envelope, code);
  }

  /// One structured line for a retirement the request [type] caused.
  void _logRetire(String type, String id, RetireOk ok) {
    _log(
      type: type,
      id: id,
      outcome: 'ok seat_retired reason=${ok.reason}',
      room: ok.room.code,
      seat: ok.seat.seat,
      seq: ok.gameOverSeq ?? ok.turnSeq ?? ok.retiredSeq,
    );
  }

  /// `rematch`, `docs/PROTOCOL.md` section 16.1. Identity-first, like the
  /// five socket-identified messages: a socket in no room gets
  /// `BAD_SEAT_TOKEN` whatever else is true. The phase checks that follow
  /// are section 16.1's own table, run here ahead of the payload check
  /// (`d` must be empty) the same way every other phase-gated message in
  /// this file runs its own phase check ahead of its payload check.
  /// `registry.rematch` re-runs the room-exists and seat-authorised steps
  /// itself as defence in depth, the same as every other call in this file.
  void _handleRematch(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final Room? liveRoom = registry.lookup(roomCode!);
    if (liveRoom == null) {
      _reject(envelope, ProtocolError.noSuchRoom);
      return;
    }
    if (liveRoom.state == RoomState.playing) {
      _reject(envelope, ProtocolError.wrongPhase);
      return;
    }
    if (liveRoom.state == RoomState.lobby && liveRoom.rematch == null) {
      _reject(envelope, ProtocolError.wrongPhase);
      return;
    }
    if (envelope.data.isNotEmpty) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final RematchResult result =
        registry.rematch(code: roomCode!, seatToken: seatToken!);
    if (result is RematchFailure) {
      _reject(envelope, result.error);
      return;
    }
    final RematchOk ok = result as RematchOk;
    final Map<String, Object?> data = _snapshotFor(ok.room);

    if (!ok.changed) {
      // docs/PROTOCOL.md section 16.3: a double tap from a seat already
      // ready changes nothing -- seq does not advance, and only the sender
      // gets the current room, with re.
      _send(type: 'room', data: data, re: envelope.id);
      _log(
        type: envelope.type,
        id: envelope.id,
        outcome: 'ok',
        room: ok.room.code,
        seq: ok.room.seq,
      );
      return;
    }

    _send(type: 'room', data: data, re: envelope.id);
    _broadcastRoomToOthers(ok.room);

    // Section 34 item 6: every computer seat accepts at once, in seat order,
    // after the human's own frames. These carry no `re`: no request of theirs
    // is being answered.
    final List<ComputerAccept> accepts = registry.acceptComputerSeats(ok.room);
    for (final ComputerAccept accept in accepts) {
      hub.broadcast(code: ok.room.code, type: 'room', data: accept.snapshot);
    }

    if (ok.autoStart ||
        (accepts.isNotEmpty && registry.rematchAutoStartHolds(ok.room))) {
      // docs/PROTOCOL.md section 16.4, "Everyone accepted": the room above
      // is the one that recorded the completing acceptance, already on the
      // wire to every socket -- only now does the server start the game
      // itself, through the exact mechanics an accepted start_game would
      // use. `startRematchAuto` is called here, not inside `registry.rematch`
      // itself, precisely so that `data` above is built from the room as the
      // accept left it (still LOBBY, `rematch.ready` complete) and never
      // from whatever state starting the game would have already moved it
      // to by the time this method got a result back.
      _publishStart(envelope, registry.startRematchAuto(ok.room));
      return;
    }
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seq: ok.room.seq,
    );
  }

  /// `game_log`, `docs/PROTOCOL.md` section 17. The current game's frames
  /// on request from a seated socket in PLAYING or FINISHED. Ladder:
  /// rate limit (2 per minute per connection), identity/room exists,
  /// seat authorised, phase (LOBBY -> WRONG_PHASE), and payload (d must
  /// be an empty object, anything else is BAD_FIELD).
  void _handleGameLog(ParsedEnvelope envelope) {
    if (!rateLimiter.recordGameLog(this)) {
      _reject(envelope, ProtocolError.rateLimited);
      return;
    }
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final Room? liveRoom = registry.lookup(roomCode!);
    if (liveRoom == null) {
      _reject(envelope, ProtocolError.noSuchRoom, room: roomCode);
      return;
    }
    Seat? seat;
    for (final Seat candidate in liveRoom.seats) {
      if (candidate.seatToken == seatToken) {
        seat = candidate;
        break;
      }
    }
    if (seat == null) {
      _reject(envelope, ProtocolError.badSeatToken, room: liveRoom.code);
      return;
    }
    if (liveRoom.state == RoomState.lobby) {
      _reject(envelope, ProtocolError.wrongPhase, room: liveRoom.code);
      return;
    }
    if (envelope.data.isNotEmpty) {
      _reject(envelope, ProtocolError.badField, room: liveRoom.code);
      return;
    }

    _publishGameLog(envelope, liveRoom, seat);
  }

  /// `emote`, `docs/PROTOCOL.md` section 25. Ladder after the blanket
  /// limit: identity, room, seat, payload, cadence. Any seated socket may
  /// send in any room state (LOBBY, PLAYING and FINISHED, rule 9), on its
  /// turn or not; section 19.2 does not apply to it. An admitted
  /// emote changes no room state, so there is no registry call, no `seq`
  /// and nothing for the game log: the sender gets the push with `re`, every
  /// other socket the same push without it.
  void _handleEmote(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final Room? liveRoom = registry.lookup(roomCode!);
    if (liveRoom == null) {
      _reject(envelope, ProtocolError.noSuchRoom, room: roomCode);
      return;
    }
    Seat? seat;
    for (final Seat candidate in liveRoom.seats) {
      if (candidate.seatToken == seatToken) {
        seat = candidate;
        break;
      }
    }
    if (seat == null) {
      _reject(envelope, ProtocolError.badSeatToken, room: liveRoom.code);
      return;
    }
    final Object? emote = envelope.data['emote'];
    if (envelope.data.length != 1 ||
        emote is! String ||
        !emoteIds.contains(emote)) {
      _reject(envelope, ProtocolError.badField, room: liveRoom.code);
      return;
    }
    final List<DateTime> admitted =
        liveRoom.emoteAdmits.putIfAbsent(seat.seatToken, () => <DateTime>[]);
    if (!admitEmote(admitted, clock.now)) {
      _reject(envelope, ProtocolError.rateLimited, room: liveRoom.code);
      return;
    }

    final Map<String, Object?> data = <String, Object?>{
      'seat': seat.seat,
      'emote': emote,
    };
    _sendAndBroadcast(
        room: liveRoom.code, type: 'emote', data: data, re: envelope.id);
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: liveRoom.code,
    );
  }

  void _publishGameLog(
    ParsedEnvelope envelope,
    Room room,
    Seat seat,
  ) {
    final String gameId = room.gameId ?? '';
    final List<List<Map<String, Object?>>> chunks;
    if (room.gameLog.isEmpty) {
      chunks = <List<Map<String, Object?>>>[<Map<String, Object?>>[]];
    } else {
      int targetParts = 1;
      List<List<Map<String, Object?>>>? packed;
      for (int i = 0; i < 10; i++) {
        packed = _packGameLog(
          entries: room.gameLog,
          gameId: gameId,
          requestId: envelope.id,
          targetParts: targetParts,
        );
        if (packed == null) {
          break;
        }
        if (packed.length == targetParts) {
          break;
        }
        targetParts = packed.length;
      }
      if (packed == null) {
        _reject(envelope, ProtocolError.internal, room: room.code);
        return;
      }
      chunks = packed;
    }

    final int partsCount = chunks.length;
    for (int p = 0; p < partsCount; p++) {
      final int bytes = _measurePartBytes(
        gameId: gameId,
        part: p + 1,
        parts: partsCount,
        frames: chunks[p],
        requestId: envelope.id,
      );
      if (bytes > maxFrameBytes) {
        _reject(envelope, ProtocolError.internal, room: room.code);
        return;
      }
    }

    for (int p = 0; p < partsCount; p++) {
      if (_closed) {
        return;
      }
      final Map<String, Object?> partData = <String, Object?>{
        'game_id': gameId,
        'part': p + 1,
        'parts': partsCount,
        'frames': chunks[p],
      };
      final String messageId = generateMessageId(random);
      final String text = encodeEnvelope(
        type: 'game_log',
        id: messageId,
        data: partData,
        re: envelope.id,
      );
      channel.sink.add(text);
    }

    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: room.code,
      seat: seat.seat,
      seq: room.seq,
    );
  }

  List<List<Map<String, Object?>>>? _packGameLog({
    required List<Map<String, Object?>> entries,
    required String gameId,
    required String requestId,
    required int targetParts,
  }) {
    final List<List<Map<String, Object?>>> chunks =
        <List<Map<String, Object?>>>[];
    List<Map<String, Object?>> currentChunk = <Map<String, Object?>>[];
    int currentPart = 1;

    for (final Map<String, Object?> entry in entries) {
      final List<Map<String, Object?>> candidate = <Map<String, Object?>>[
        ...currentChunk,
        entry,
      ];
      final int bytes = _measurePartBytes(
        gameId: gameId,
        part: currentPart,
        parts: targetParts,
        frames: candidate,
        requestId: requestId,
      );
      if (bytes <= maxFrameBytes) {
        currentChunk.add(entry);
      } else {
        if (currentChunk.isEmpty) {
          return null;
        }
        chunks.add(currentChunk);
        currentChunk = <Map<String, Object?>>[entry];
        currentPart++;
        final int singleBytes = _measurePartBytes(
          gameId: gameId,
          part: currentPart,
          parts: targetParts,
          frames: currentChunk,
          requestId: requestId,
        );
        if (singleBytes > maxFrameBytes) {
          return null;
        }
      }
    }
    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk);
    }
    return chunks;
  }

  int _measurePartBytes({
    required String gameId,
    required int part,
    required int parts,
    required List<Map<String, Object?>> frames,
    required String requestId,
  }) {
    final Map<String, Object?> data = <String, Object?>{
      'game_id': gameId,
      'part': part,
      'parts': parts,
      'frames': frames,
    };
    const String placeholderId = '0123456789012345678901';
    final String text = encodeEnvelope(
      type: 'game_log',
      id: placeholderId,
      data: data,
      re: requestId,
    );
    return utf8.encode(text).length;
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

    // docs/PROTOCOL.md section 21.1: `move` gains an optional `face`,
    // checked at the same ladder position as `token` -- a malformed field
    // is not an illegal move, whichever of the two it is.
    const Set<String> allowedKeys = <String>{'token', 'face'};
    if (!envelope.data.keys.every(allowedKeys.contains)) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    final Object? rawToken = envelope.data['token'];
    if (rawToken is! int || rawToken < 0 || rawToken > 3) {
      _reject(envelope, ProtocolError.badField);
      return;
    }
    int? face;
    if (envelope.data.containsKey('face')) {
      final Object? rawFace = envelope.data['face'];
      // Section 28 rule 2: with a release owed the release check comes
      // before the range check, so any integer is passed on and the engine
      // answers it ILLEGAL_MOVE; only a non-integer is a malformed field.
      final bool releaseOwed = liveRoom!.game!.releaseOwed;
      if (rawFace is! int || (!releaseOwed && (rawFace < 1 || rawFace > 6))) {
        _reject(envelope, ProtocolError.badField);
        return;
      }
      face = rawFace;
    }

    final MoveResult result = registry.move(
      code: roomCode!,
      seatToken: seatToken!,
      token: rawToken,
      face: face,
    );
    if (result is MoveFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    _publishMove(envelope, result as MoveOk);
  }

  /// `decline_release`, `docs/PROTOCOL.md` section 30 rule 4. The ladder is
  /// `roll`'s own, then `WRONG_PHASE` when no offer is pending, then the
  /// payload check (`d` is empty), the same position `roll` gives it.
  void _handleDeclineRelease(ParsedEnvelope envelope) {
    if (!_hasIdentity) {
      _reject(envelope, ProtocolError.badSeatToken);
      return;
    }
    final Room? liveRoom = registry.lookup(roomCode!);
    ProtocolError? ladderError =
        _turnLadderError(liveRoom, seatToken!, engine.GamePhase.awaitMove);
    if (ladderError == null && !liveRoom!.game!.releaseOffered) {
      ladderError = ProtocolError.wrongPhase;
    }
    if (ladderError != null) {
      _reject(envelope, ladderError, room: roomCode);
      return;
    }
    if (envelope.data.isNotEmpty) {
      _reject(envelope, ProtocolError.badField);
      return;
    }

    final DeclineResult result =
        registry.declineRelease(code: roomCode!, seatToken: seatToken!);
    if (result is DeclineFailure) {
      _reject(envelope, result.error, room: roomCode);
      return;
    }
    final DeclineOk ok = result as DeclineOk;
    for (final OutFrame frame in buildDeclineFrames(ok)) {
      _sendAndBroadcast(
        room: ok.room.code,
        type: frame.type,
        data: frame.data,
        re: envelope.id,
      );
    }
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: ok.events.whereType<engine.ReleaseDeclined>().single.seat,
      seq: ok.turnSeq,
    );
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
  /// order section 21.3 rule 4 fixes (replacing section 12.1 for every room,
  /// since every room plays the queue): `rolled` always, carrying the
  /// queue after the roll and, when a move is now pending, `legal_by_face`;
  /// then, exactly when [ok] set them, `turn_passed` and/or a `turn` for
  /// whichever seat holds the segment next -- the same seat, owing another
  /// roll after a queued 6, or the next seat once the turn has passed. `re`
  /// is set on every one of them for this socket's own copy, and on none of
  /// them for anyone else's, per section 12.3.
  void _publishRoll(ParsedEnvelope envelope, RollOk ok) {
    final engine.Rolled rolledEvent =
        ok.events.whereType<engine.Rolled>().single;
    for (final OutFrame frame in buildRollFrames(ok)) {
      _sendAndBroadcast(
        room: ok.room.code,
        type: frame.type,
        data: frame.data,
        re: envelope.id,
      );
    }
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: rolledEvent.seat,
      seq: ok.turnSeq ?? ok.rolledSeq,
    );
  }

  /// Builds and sends every frame `RoomRegistry.move` decided on: `moved`
  /// always, carrying the face it spent (or `release: true`, section 28 rule
  /// 2), then exactly one of `game_over` (and the `player_left` of every
  /// retired seat it freed, section 28 rule 4), `seat_finished` and `turn`,
  /// `turn_passed` and `turn`, or a bare `turn` -- section 12.2 and section
  /// 21.3 rule 4, which replaces it for every room since every room plays
  /// the queue.
  void _publishMove(ParsedEnvelope envelope, MoveOk ok) {
    final engine.Moved movedEvent = ok.events.whereType<engine.Moved>().single;
    for (final OutFrame frame in buildMoveFrames(ok)) {
      _sendAndBroadcast(
        room: ok.room.code,
        type: frame.type,
        data: frame.data,
        re: envelope.id,
      );
    }
    detachFreedSeats(hub, ok.room.code, ok.freed);
    _log(
      type: envelope.type,
      id: envelope.id,
      outcome: 'ok',
      room: ok.room.code,
      seat: movedEvent.seat,
      seq: ok.gameOverSeq ?? ok.turnSeq,
    );
  }

  /// `docs/PROTOCOL.md` section 12.3: every frame in section 12 is
  /// broadcast to every connected socket in the room including the sender,
  /// and the sender's own copy is the only one that carries `re`.
  void _sendAndBroadcast({
    required String room,
    required String type,
    required Map<String, Object?> data,
    required String? re,
  }) {
    _send(type: type, data: data, re: re);
    hub.broadcast(code: room, type: type, data: data, exceptConn: this);
  }

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
  ///
  /// `blocks` is accepted and type-checked since 2026-10-15 (Sam's ruling,
  /// `docs/PROTOCOL.md` section 4 and `docs/RULES.md` rule 21) but then
  /// discarded: every room is created with blocks off regardless of what
  /// was sent, so `RulesConfig` here has no field to carry the value into.
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
    if (raw.containsKey('blocks')) {
      final Object? v = raw['blocks'];
      if (v is! bool) {
        return null;
      }
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
      captureBonus: captureBonus,
      turnSeconds: turnSeconds,
    );
  }

  void _reject(
    ParsedEnvelope envelope,
    ProtocolError error, {
    String? room,
    BanInfo? ban,
  }) {
    _sendError(error, re: envelope.id, ban: ban);
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

  void _sendError(ProtocolError error, {required String? re, BanInfo? ban}) {
    _send(
      type: 'error',
      data: errorPayload(error, defaultErrorMessage(error), ban: ban?.toJson()),
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
    final Map<String, Object?> out = _withPre(type, data) ?? data;
    final String id = generateMessageId(random);
    channel.sink.add(
      encodeEnvelope(type: type, id: id, data: out, re: re),
    );
  }

  /// `docs/PROTOCOL.md` section 35 item 1: this socket's own copy of a `turn`
  /// frame, or of a `room` snapshot whose `turn` object, says the game awaits
  /// this socket's seat's roll gets `pre`, the payload of the `rolled` that
  /// roll would produce now. The registry decides from the live room whether
  /// it is owed (a human seat on turn, `await_roll`); the frame's own `seat`
  /// and `phase`, and a snapshot's `code` and `k`, must say the same, so a
  /// copy describing an earlier moment gets none. [data] is never changed:
  /// it is the map every other socket and `room.gameLog` hold. Null when
  /// this copy carries no `pre`.
  Map<String, Object?>? _withPre(String type, Map<String, Object?> data) {
    final String? code = roomCode;
    final String? token = seatToken;
    if (code == null || token == null) {
      return null;
    }
    final Map<String, Object?>? turn;
    if (type == 'turn') {
      turn = data;
    } else if (type == 'room') {
      final Object? snapshotTurn = data['turn'];
      turn = snapshotTurn is Map<String, Object?> ? snapshotTurn : null;
    } else {
      return null;
    }
    if (turn == null || turn['phase'] != 'await_roll') {
      return null;
    }
    final Room? room = registry.lookup(code);
    final engine.GameState? game = room?.game;
    if (room == null || game == null || turn['seat'] != game.currentSeat) {
      return null;
    }
    if (type == 'room' &&
        (data['code'] != code || turn['k'] != room.rollCount)) {
      return null;
    }
    final Seat? own = _ownSeat(room, token);
    if (own == null || own.seat != turn['seat']) {
      return null;
    }
    final Map<String, Object?>? pre =
        registry.preRollFor(code: code, seatToken: token);
    if (pre == null) {
      return null;
    }
    return withRollerPre(type: type, data: data, pre: pre);
  }

  Seat? _ownSeat(Room room, String token) {
    for (final Seat seat in room.seats) {
      if (seat.seatToken == token && !seat.tokenDead) {
        return seat;
      }
    }
    return null;
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
    // Section 33 item 4: a ticket outlives its socket, detached, for 30 s.
    if (registry.line.detach(this) != null) {
      _log(type: '-', id: '-', outcome: 'disconnect ticket_detached');
    }
    // Section 31 item 4: a knock does not outlive its socket. Done after
    // `_closed`, so nothing is written to the socket that just went.
    final String? knockId = pendingKnockId;
    if (knockId != null) {
      final String knockRoom = pendingKnockRoom!;
      pendingKnockId = null;
      pendingKnockRoom = null;
      final List<KnockEvent> closed =
          registry.withdrawKnock(knockRoom, knockId);
      publishKnockEvents(hub, closed);
      if (closed.isNotEmpty) {
        _log(
          type: '-',
          id: '-',
          outcome: 'disconnect knock_withdrawn knock=$knockId',
          room: knockRoom,
          seq: closed.last.seq,
        );
      }
    }
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

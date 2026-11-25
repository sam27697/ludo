// The seam between the protocol engine (RoomConnection) and a screen.
//
// RoomConnection speaks futures and raw frames and is proved against a fake
// transport with no server. A Flutter screen needs something it can hold in
// a build method: a listenable object with a current state and no throwing
// methods, because these methods are wired straight to button handlers and
// an exception out of a button handler is a crash on a player's phone.
//
// This is the room controller. It opens and re-opens a RoomConnection,
// caches the seat and seat token a reconnect needs, and reduces every
// state-changing push docs/PROTOCOL.md section 5 lists -- the three lobby
// deltas and every game delta -- so a screen holding this controller can
// render a live board from `room` alone. A `seq` gap, on any of them, is no
// longer a flag left for the UI to notice: it resynchronises itself in
// place on the open socket (`_beginResync`, docs/PROTOCOL.md section 6) and
// comes back with the server's own snapshot.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../code_ban_notice.dart';
import '../install_id.dart';
import '../session_memory.dart';
import 'connection.dart';
import 'frame.dart';
import 'snapshot.dart';
import 'transport.dart';

/// The lifecycle a [RoomController] moves through. There is no path back to
/// [idle]: once a room has been created or joined, the controller has a
/// history worth keeping (the room, the seat, the seat token), and every
/// later state carries that history forward instead of discarding it.
enum RoomPhase { idle, connecting, connected, closed, failed }

/// C-520 A3. How one quick-message send ended.
///
/// admitted: the server's copy came back. refused: the server answered with
/// an error frame ([ProtocolErrorException]). failed: anything else (not
/// connected, disposed, closed, timeout).
enum EmoteOutcome { admitted, refused, failed }

/// docs/PROTOCOL.md section 31 item 4: where this phone's own knock stands.
enum KnockPhase {
  none,
  pending,
  accepted,
  rejected,
  timedOut,
  full,
  withdrawn,
  switchedOff,
}

/// This phone's own knock on a room that has guest approval on. [knockId] is
/// null in [KnockPhase.none]. [expiresAtMs] is the device clock at the
/// `knock_pending` plus its `expires_ms`; it is null unless the phase is
/// [KnockPhase.pending]. The server alone decides when a knock ends.
class KnockState {
  const KnockState({
    this.phase = KnockPhase.none,
    this.knockId,
    this.expiresAtMs,
  });

  final KnockPhase phase;
  final String? knockId;
  final int? expiresAtMs;
}

/// docs/PROTOCOL.md section 33 item 3: this phone's place in the waiting
/// line, from the latest `queued`. [position] is 1 at the head of the line.
class QueueState {
  const QueueState({required this.ticket, required this.position});

  final String ticket;
  final int position;
}

/// docs/PROTOCOL.md section 5's "Carrying seq" list: every frame type this
/// controller reduces. `error`, `pong` and `seat_assigned` are not on it.
const Set<String> _stateChangingTypes = <String>{
  'room',
  'player_joined',
  'player_left',
  'presence',
  'seat_seed',
  'game_started',
  'rolled',
  'moved',
  'turn_passed',
  'turn',
  'game_over',
  'seat_finished',
  'seat_retired',
  'sixes_granted',
  'release_declined',
  'knock',
  'knock_closed',
};

/// The production automatic-reconnect schedule: five attempts, the delay
/// before each one doubling until the last step. Passed to
/// [RoomController] by `defaultRoomControllerFactory`
/// (lib/src/server_config.dart), the only place in lib/ that uses it.
const List<Duration> kAutoReconnectDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
];

/// The three codes rule 2 (`_failFromRequest`) produces from something other
/// than the server naming a protocol error: a transport that would not open,
/// a request that timed out, and a connection that closed under a request.
/// Every other code -- every server protocol code and the client's own
/// `'protocol'` -- is not retryable.
const Set<String> _retryableErrorCodes = <String>{
  'transport',
  'timeout',
  'closed',
};

/// E1: the four codes the server answers `roll()` or `move()` with when the
/// request itself was fine but raced the server's own state and lost --
/// something that was true when this client sent it and stopped being true
/// before the server read it. None of these is a fault to recover from: the
/// frames already arriving on the same open socket carry the truth, and a
/// player who sees them a moment later is not looking at anything broken.
const Set<String> _rejectedIntentionCodes = <String>{
  // the turn had already passed to someone else, most often the second of
  // two taps inside one round trip, or a tap that lands as the turn timer
  // plays the move for this player instead
  'NOT_YOUR_TURN',
  // the phase had already moved on, the same race as above seen from a
  // request that named the wrong step rather than the wrong player
  'WRONG_PHASE',
  // the board had already moved on: a move sent against a legal-move list
  // this client had not yet been told was stale
  'ILLEGAL_MOVE',
  // the game had already finished before this request arrived
  'GAME_OVER',
};

/// S1: the two codes the server answers `start_game` with when the request
/// itself was fine but raced the server's own state and lost -- something
/// that was true when this client sent it and stopped being true before the
/// server read it. Neither is a fault to recover from: the frames already
/// arriving on the same open socket carry the truth -- `game_started` if the
/// race went the other way, `player_left` if a seat emptied first -- and a
/// host who sees them a moment later is not looking at anything broken. Its
/// own set, not [_rejectedIntentionCodes] (S3): `setPlayers`, `roll` and
/// `move` are untouched by it.
const Set<String> _startGameRejectedCodes = <String>{
  // the room had already left the lobby, most often the second of two taps
  // on Start inside one round trip
  'ROOM_STARTED',
  // a seat emptied -- a friend leaving -- between the host tapping Start and
  // the server reading the request
  'NOT_ENOUGH_PLAYERS',
};

/// The two codes [setPlayers] can be refused with that are a race, not a
/// fault: something that was true when this client sent the request and
/// stopped being true before the server read it. `NOT_ENOUGH_PLAYERS` here
/// is a friend joining between the tap and the server reading it -- the
/// `room` broadcast that join produces already carries the truth. Its own
/// set, not [_startGameRejectedCodes]: `setPlayers` never follows itself
/// with `start_game`, so a `setPlayers` caller decides that for itself.
const Set<String> _setPlayersRejectedCodes = <String>{
  'NOT_ENOUGH_PLAYERS',
  'ROOM_STARTED',
};

/// The five codes [RoomController.kick] can be refused with that the host
/// can read off the room and act on: not the host, not in play, a bad seat,
/// a seat that is not a playing one, a seat whose socket is up. Each leaves
/// the connection as it was. docs/PROTOCOL.md section 28 rule 4.
const Set<String> _hostRequestSoftCodes = <String>{
  'NO_SUCH_KNOCK',
  'NOT_HOST',
  'WRONG_PHASE',
  'BAD_FIELD',
};

const Set<String> _kickRejectedCodes = <String>{
  'NOT_HOST',
  'WRONG_PHASE',
  'BAD_FIELD',
  'ILLEGAL_MOVE',
  'NOT_ABSENT',
};

/// C-669 R4: the `error` codes a `leave_room` can come back with that say the
/// server holds no seat for this phone any more. `NO_SUCH_ROOM`: the room is
/// gone (reaped, or never the one this socket sat in). `BAD_SEAT_TOKEN`: the
/// socket has no seat in a room, or the token matches none (a leave already
/// processed, a takeover). Every other code `leave_room` can draw
/// (PROTOCOL_VERSION, BAD_TYPE, BAD_FIELD, TOO_LARGE, RATE_LIMITED, and the
/// INTERNAL or engine refusal of a retire) means the frame was not processed.
const Set<String> _leaveGoneCodes = <String>{'NO_SUCH_ROOM', 'BAD_SEAT_TOKEN'};

/// Holds the one [RoomConnection] a lobby screen is driving at any moment,
/// re-creates it across a drop, and exposes the whole thing as a
/// [ChangeNotifier] with no method that ever throws.
class RoomController extends ChangeNotifier {
  RoomController({
    required this.serverUrl,
    required TransportConnector connect,
    List<Duration> autoReconnectDelays = const <Duration>[],
    DateTime Function()? clock,
  }) : _connect = connect, // ignore: prefer_initializing_formals
       _clock = clock ?? DateTime.now,
       autoReconnectDelays = List<Duration>.unmodifiable(autoReconnectDelays) {
    // Read or make the install id now, so the first join already has it.
    unawaited(installId());
  }

  /// The address every connection this controller opens is opened against.
  final Uri serverUrl;

  final TransportConnector _connect;

  /// The device clock, injected by tests; read only to stamp a knock.
  final DateTime Function() _clock;

  /// The bounded backoff schedule an automatic sequence (C5, C10) follows.
  /// An unmodifiable copy of whatever was passed in. Empty means automatic
  /// reconnection is off: no timer is ever created and this controller
  /// behaves exactly as it did before this field existed.
  final List<Duration> autoReconnectDelays;

  RoomPhase _phase = RoomPhase.idle;
  RoomSnapshot? _room;
  RoomSnapshot? _lastFinished;
  ({int seat, String reason})? _lastRetirement;

  /// The last non-null seat and seat token this controller has ever seen,
  /// from any connection. Rule 5: never cleared except by [dispose], because
  /// a seat token is the capability to reclaim a seat and a `reconnect()`
  /// opens a brand new [RoomConnection] that starts with a null seat token
  /// of its own.
  int? _cachedSeat;
  int? _seatMovedFrom;
  String? _cachedSeatToken;

  KnockState _knock = const KnockState();
  bool _wasKicked = false;

  /// docs/PROTOCOL.md section 35 ruling 7 (f): set by a `seat_retired` naming
  /// this phone's own seat. Final whatever the `seq` gap: from then on no gap
  /// starts a resync and no `resume` is sent for the seat.
  bool _selfRetired = false;

  /// Section 35 item 5: my roll in flight. [_preThrown] is the `pre` a die tap
  /// sent `roll` under, until [_landPre] shows it; [_preConnection] is the
  /// socket it was sent on. Once my `rolled` for that `k` arrives while the
  /// die is still in the air, it and every state-changing frame after it
  /// wait in [_heldFrames] for the landing, so the table changes in the
  /// order the server sent it and the face lands at a fixed time after the
  /// tap. [_landedPre] is the one shown and not yet confirmed by its
  /// `rolled`; [_preEchoes] marks that `rolled` once it arrives, so the
  /// screen does not play it a second time.
  PreRoll? _preThrown;
  RoomConnection? _preConnection;
  Timer? _preLandTimer;
  bool _holdingFrames = false;
  final List<Frame> _heldFrames = <Frame>[];
  PreRoll? _landedPre;
  final Expando<bool> _preEchoes = Expando<bool>('pre echo');

  /// Section 32 item 12: the `ban` a `CODE_BANNED` error, a rejecting
  /// `knock_failed` or a `kicked` frame carried, or null.
  CodeBan? _ban;

  /// Section 33: the waiting line. [_queue] is the latest `queued`;
  /// [_queueWanted] is true from [findGame] until a seat arrives, the line is
  /// left, or the line fails for good. [_queueGeneration] moves on every time
  /// the line ends, so an attempt that was opening a socket for an earlier
  /// line drops it instead of attaching it.
  QueueState? _queue;
  bool _queueWanted = false;
  String? _queueName;
  int _queueGeneration = 0;
  Timer? _queueRetryTimer;
  int _queueRetryIndex = 0;
  bool _cancelInFlight = false;
  bool _computerInFlight = false;

  /// The last link join, kept so the lobby's own retry (which can only call
  /// [joinRoom]) repeats a link join as a link join. See [joinRoom].
  String? _retryLink;

  bool _hasDesynced = false;
  String? _errorCode;
  String? _errorMessage;

  /// True between a seq gap starting a resync (`_beginResync`) and that
  /// resync's `resume` reply landing or failing. While true, every
  /// state-changing push changes nothing: the snapshot the resync gets back
  /// is what re-bases the client, not whatever arrived in the meantime.
  bool _resyncInFlight = false;

  RoomConnection? _connection;
  StreamSubscription<Frame>? _frameSub;
  final StreamController<Frame> _framesController =
      StreamController<Frame>.broadcast();
  final List<Frame> _gameTranscript = <Frame>[];
  bool _hasOpenedTranscript = false;
  String? _transcriptGameId;

  bool _disposed = false;

  /// Set by an unsolicited `error` frame (C3) or a reconnect attempt --
  /// automatic or manual -- failing with a non-retryable code (C3). Cleared
  /// only when [phase] next reaches [RoomPhase.connected]. Gates [_eligible]
  /// only; it has no getter of its own.
  bool _blocked = false;

  /// Set by an unsolicited `BAD_SEAT_TOKEN` error frame: the server closed
  /// this socket because a newer one resumed the same seat (4004). Cleared
  /// wherever [_blocked] is cleared on reaching [RoomPhase.connected].
  /// [leave] and [dispose] leave it as it is.
  bool _seatTakenOver = false;

  /// Set by an unsolicited `UPDATE_REQUIRED` error frame (docs/PROTOCOL.md
  /// section 27 rule 6): the server refused this build. One-way, for the life
  /// of the controller; nothing clears it, because a reconnect with the same
  /// build would be refused again.
  bool _updateRequired = false;

  /// True once [leave] has been called, ever. One-way, like [_disposed].
  bool _leftCalled = false;

  /// C-316 rule 4: true when Play again was tapped offline and should send
  /// rematch as soon as the resume succeeds.
  bool _sendRematchOnResume = false;

  /// The timer for the next scheduled automatic attempt, while one is
  /// pending. Null the rest of the time, including while an attempt opened
  /// by that timer is in flight.
  Timer? _reconnectTimer;

  /// True from the moment an automatic sequence starts (C5, C10) until it
  /// ends: an attempt lands in [RoomPhase.connected], a retryable failure
  /// exhausts [autoReconnectDelays], a non-retryable failure blocks it, or
  /// [leave] / [dispose] cuts it short. At most one sequence is ever running.
  bool _sequenceRunning = false;

  /// The index into [autoReconnectDelays] the next scheduled attempt, if
  /// any, will use.
  int _nextDelayIndex = 0;

  RoomPhase get phase => _phase;
  RoomSnapshot? get room => _room;

  /// C-310 rule 1: the snapshot as it stood in FINISHED for the current room,
  /// preserved across a rematch LOBBY until the new game starts.
  RoomSnapshot? get lastFinished => _lastFinished;

  /// The most recent `seat_retired` this controller reduced in the current
  /// game: who, and why (`left`, `absent` or `kicked`). The screen words the
  /// notice from it. Null until one arrives, and cleared by the next
  /// `game_started` and by opening another room.
  ({int seat, String reason})? get lastRetirement => _lastRetirement;
  int? get seat => _cachedSeat;

  /// C-592 D1: the seat this player held before the server moved it to a
  /// different one, or null. It stays until [clearSeatMoved].
  int? get seatMovedFrom => _seatMovedFrom;

  /// C-592 D1: the screen has told the player about the move.
  void clearSeatMoved() {
    _seatMovedFrom = null;
  }

  String? get seatToken => _cachedSeatToken;
  bool get hasDesynced => _hasDesynced;

  /// C-555 D1: true exactly while a resync's `resume` is out on the open
  /// socket. A screen draws a turning mark on it and takes no second tap.
  bool get isResyncing => _resyncInFlight;

  /// C-547 rule 1: true after another phone took this seat over, until the
  /// phase next reaches [RoomPhase.connected]. Screens draw the takeover card
  /// instead of the connection-lost card, with no Reconnect.
  bool get seatTakenOver => _seatTakenOver;

  /// Section 27 rule 6: true once the server has refused this build of the
  /// app. Screens draw the update card instead of anything else, and it
  /// outranks [seatTakenOver]. No reconnect, automatic or manual, follows.
  bool get updateRequired => _updateRequired;

  /// Section 31 item 4: this phone's own knock. [KnockPhase.none] unless a
  /// typed-code join met a room with guest approval on.
  KnockState get knockState => _knock;

  /// Section 31 item 6: set when the host removed this phone from a lobby
  /// (a `kicked` frame); cleared by the next join. Section 33 item 8: the
  /// same frame in a game in play sets it too.
  bool get wasKicked => _wasKicked;

  /// docs/PROTOCOL.md section 35 item 1: the roll in hand for my seat, the
  /// `pre` the server sent with my `await_roll` turn. Null when it is not my
  /// turn to roll, when the server sent none (an older server, a resume that
  /// has not answered), and from the moment my `rolled` for that `k` is
  /// applied or the turn moves on.
  PreRoll? get pre {
    if (_holdingFrames) {
      // My `rolled` for it has arrived and waits for the die to land.
      return null;
    }
    if (_selfRetired) {
      // My seat is out of the game: there is no roll of mine to show.
      return null;
    }
    if (_hasDesynced) {
      // A frame went missing: the turn this `pre` rode may have moved on
      // already. Nothing is in hand until the resync's snapshot says so.
      return null;
    }
    final RoomSnapshot? room = _room;
    final int? mySeat = _cachedSeat;
    final TurnState? turn = room?.turn;
    if (room == null ||
        mySeat == null ||
        turn == null ||
        room.state != RoomState.playing ||
        turn.seat != mySeat ||
        turn.phase != TurnPhase.awaitRoll) {
      return null;
    }
    final PreRoll? inHand = turn.pre;
    return inHand != null && inHand.seat == mySeat ? inHand : null;
  }

  /// Section 35 item 5: true for the `rolled` that confirms a roll of mine
  /// already shown from its `pre`. Applied here for its `seq`, and nothing on
  /// screen is to change for it.
  bool isPreEcho(Frame frame) => _preEchoes[frame] ?? false;

  /// The code ban the server last told this controller about, exactly as
  /// sent; null when the last answer carried none or it was unreadable.
  CodeBan? get ban => _ban;
  String? get errorCode => _errorCode;
  String? get errorMessage => _errorMessage;

  /// Section 33 item 3: this phone's place in the waiting line, or null when
  /// it is not in the line. Every `queued` replaces it and notifies.
  QueueState? get queueState => _queue;

  /// True while this phone wants a seat from the line and has none yet:
  /// from [findGame] until a seat arrives, [cancelFind] is answered,
  /// [playComputer] is sent, or the line fails for good.
  bool get inQueue => _queueWanted;

  /// True while the line's socket is down and the next attempt to re-attach
  /// the ticket waits on [autoReconnectDelays].
  bool get queueReconnecting => _queueRetryTimer != null;

  /// True exactly while a sequence's timer is scheduled and has neither
  /// fired nor been cancelled (C9). False while an attempt is in flight, and
  /// false when there is no sequence at all.
  bool get autoReconnectPending => _reconnectTimer != null;

  bool get isHost =>
      _room != null && _cachedSeat != null && _room!.hostSeat == _cachedSeat;

  /// C4: whether this controller may start, or continue, an automatic
  /// reconnect sequence right now.
  bool get _eligible =>
      autoReconnectDelays.isNotEmpty &&
      _room != null &&
      _cachedSeatToken != null &&
      _room!.state != RoomState.finished &&
      !_leftCalled &&
      !_disposed &&
      !_blocked &&
      !_updateRequired;

  /// Every inbound frame, in arrival order, forwarded from whichever
  /// [RoomConnection] is current. A broadcast controller of its own, not the
  /// connection's stream handed straight out, precisely so a listener
  /// attached before a drop keeps receiving frames from the connection
  /// [reconnect] opens afterwards.
  Stream<Frame> get frames => _framesController.stream;

  /// C-293 rule 1: every frame delivered from the most recent `game_started`
  /// onward, in arrival order. Empty before any `game_started`. An
  /// unmodifiable view; adding to it throws.
  List<Frame> get gameTranscript =>
      UnmodifiableListView<Frame>(_gameTranscript);

  /// Both rules toggles on by default, matching [RoomToggles]'s own
  /// defaults. Forwarded to [RoomConnection.createRoom] as `toggles`; never
  /// as `rules`, and never carrying a turn timer.
  ///
  /// [open] is section 33 item 1's flag, always sent: true lets the server
  /// seat strangers from the waiting line.
  Future<void> createRoom({
    required String name,
    required int players,
    RoomToggles toggles = const RoomToggles(),
    bool open = false,
  }) {
    return _openFresh(
      gate: _phase == RoomPhase.idle || _phase == RoomPhase.failed,
      request: (RoomConnection connection) {
        // Section 32 item 6: the install id rides on create_room when it is
        // known, which it is from app start and controller construction on.
        // Creating a room never waits for it: the field is optional here.
        return connection.createRoom(
          name: name,
          players: players,
          toggles: toggles,
          install: installIdIfReady(),
          open: open,
        );
      },
    );
  }

  /// A typed code. Sends `install`. With guest approval on, the answer may be
  /// a knock instead of a seat: see [knockState].
  ///
  /// An empty [code] repeats the last [joinByLink] instead, when there was
  /// one: the lobby screen can only retry through this method, and an empty
  /// code is never a valid typed one.
  Future<void> joinRoom({required String code, required String name}) {
    final String? retry = _retryLink;
    if (code.isEmpty && retry != null) {
      return joinByLink(link: retry, name: name);
    }
    return _join(<String, Object?>{'code': code, 'name': name});
  }

  /// A tapped room link (section 31 item 2): [link] is the link id from
  /// `/r/<link id>`. Seats at once, whatever guest approval says. Sends
  /// `install`.
  Future<void> joinByLink({required String link, required String name}) {
    if (_disposed || !_canJoin) {
      return Future<void>.value();
    }
    _retryLink = link;
    return _join(<String, Object?>{'link': link, 'name': name});
  }

  /// A join may start from idle or failed, and from closed once the host
  /// removed this phone: the next join is how it learns whether it is barred.
  bool get _canJoin =>
      _phase == RoomPhase.idle ||
      _phase == RoomPhase.failed ||
      (_phase == RoomPhase.closed && _wasKicked);

  Future<void> _join(Map<String, Object?> fields) {
    return _openFresh(
      gate: _canJoin,
      isJoin: true,
      request: (RoomConnection connection) async {
        // Section 32 item 6: a typed code always carries the install id, so
        // it is waited for; a link join sends it when it is already known.
        final String? install = fields.containsKey('code')
            ? (installIdIfReady() ?? await installId())
            : installIdIfReady();
        final Frame reply = await connection.request(
          'join_room',
          <String, Object?>{...fields, 'install': ?install},
        );
        if (reply.type == 'knock_pending') {
          _noteKnockPending(reply);
          return null;
        }
        if (reply.type != 'room') {
          throw FrameFormatException('expected room, got ${reply.type}');
        }
        return RoomSnapshot.fromJson(reply.data);
      },
    );
  }

  void _noteKnockPending(Frame reply) {
    final String? id = _asString(reply.data, 'knock_id');
    final int? expiresMs = _asInt(reply.data, 'expires_ms');
    if (id == null || expiresMs == null) {
      throw const FrameFormatException('knock_pending');
    }
    _knock = KnockState(
      phase: KnockPhase.pending,
      knockId: id,
      expiresAtMs: _clock().millisecondsSinceEpoch + expiresMs,
    );
  }

  /// Section 33 item 3: asks the server for a seat among strangers. The
  /// answer is a seat at once (then [room] is set and [phase] is
  /// [RoomPhase.connected], as after a join) or a place in the line
  /// ([queueState]); while in the line [phase] stays [RoomPhase.connecting].
  /// A seat from the line arrives later as `seat_assigned` and `room`.
  ///
  /// A socket that drops while in the line is reopened on
  /// [autoReconnectDelays] and `find_game` is sent again with the held
  /// `ticket`, so the server puts this phone back in its old place. When the
  /// schedule is used up (or empty), the line fails as a transport failure
  /// would. A refusal (`RATE_LIMITED`, `ALREADY_SEATED`, `BAD_FIELD`) ends the
  /// line and lands in [RoomPhase.failed] with [errorCode] set.
  ///
  /// Accepted only from a controller that holds no room, from
  /// [RoomPhase.idle] or [RoomPhase.failed], and not already in the line.
  Future<void> findGame({required String name}) async {
    if (_disposed ||
        _room != null ||
        _queueWanted ||
        _computerInFlight ||
        !(_phase == RoomPhase.idle || _phase == RoomPhase.failed)) {
      return;
    }
    _queueWanted = true;
    _queueName = name;
    _queue = null;
    _queueRetryIndex = 0;
    _knock = const KnockState();
    _wasKicked = false;
    _ban = null;
    _errorCode = null;
    _errorMessage = null;
    _phase = RoomPhase.connecting;
    notifyListeners();
    await _sendFindGame();
  }

  /// One attempt at the line: a fresh socket, then `find_game` with the held
  /// ticket when there is one.
  Future<void> _sendFindGame() async {
    final int generation = _queueGeneration;
    final RoomConnection connection = RoomConnection(
      url: serverUrl,
      connect: _connect,
    );
    try {
      await connection.open();
    } catch (_) {
      // The connector rejected: the server is unreachable right now. The
      // line's own backoff decides what follows.
      if (!_disposed && generation == _queueGeneration) {
        _onQueueSocketLost('transport');
      }
      return;
    }
    if (_disposed || generation != _queueGeneration) {
      unawaited(connection.close());
      return;
    }
    _attach(connection);
    final String install = installIdIfReady() ?? await installId();
    if (_disposed ||
        generation != _queueGeneration ||
        !identical(_connection, connection)) {
      return;
    }
    try {
      final Frame reply = await connection.findGame(
        name: _queueName ?? '',
        install: install,
        ticket: _queue?.ticket,
      );
      if (_disposed || generation != _queueGeneration) {
        return;
      }
      switch (reply.type) {
        case 'room':
          _seatFromLine(RoomSnapshot.fromJson(reply.data));
        case 'queued':
          // [_handleFrame] records every `queued` and notifies; an answer at
          // all means the line is attached again, so the backoff restarts.
          _queueRetryIndex = 0;
        default:
          throw FrameFormatException(
            'expected room or queued, got ${reply.type}',
          );
      }
    } on ProtocolErrorException catch (error) {
      if (_disposed || generation != _queueGeneration) {
        return;
      }
      _endQueue();
      _failFromRequest(error);
    } on RequestTimeoutException {
      _onQueueRequestLost(generation, connection, 'timeout');
    } on ConnectionClosedException {
      _onQueueRequestLost(generation, connection, 'closed');
    } on Object catch (error) {
      // A reply that does not decode: not a verdict the line can retry.
      if (_disposed || generation != _queueGeneration) {
        return;
      }
      _endQueue();
      _failFromRequest(error);
    }
  }

  void _onQueueRequestLost(
    int generation,
    RoomConnection connection,
    String code,
  ) {
    if (_disposed ||
        generation != _queueGeneration ||
        !identical(_connection, connection)) {
      return;
    }
    _dropConnection();
    _onQueueSocketLost(code);
  }

  /// The line's socket went (or would not open). The ticket stays held on
  /// the server for 30 seconds, so the next attempt waits on the usual
  /// schedule and re-sends it. With the schedule used up the line fails with
  /// [code], so the window that shows it closes with a notice.
  void _onQueueSocketLost(String code) {
    if (_disposed || !_queueWanted || _cancelInFlight) {
      return;
    }
    if (_queueRetryIndex >= autoReconnectDelays.length) {
      _endQueue();
      _fail(code, '');
      return;
    }
    final Duration delay = autoReconnectDelays[_queueRetryIndex];
    _queueRetryIndex++;
    _phase = RoomPhase.connecting;
    _queueRetryTimer?.cancel();
    _queueRetryTimer = Timer(delay, () {
      _queueRetryTimer = null;
      if (_disposed || !_queueWanted) {
        return;
      }
      unawaited(_sendFindGame());
    });
    notifyListeners();
  }

  /// Ends the line on this side: no ticket, no retry, and any attempt still
  /// opening a socket for it drops that socket.
  void _endQueue() {
    _queueWanted = false;
    _queue = null;
    _queueGeneration++;
    _queueRetryTimer?.cancel();
    _queueRetryTimer = null;
  }

  /// A seat from the line, at once or later: the same landing as a join.
  void _seatFromLine(RoomSnapshot snapshot) {
    _endQueue();
    _room = snapshot;
    _clearLastFinished();
    _lastRetirement = null;
    _selfRetired = false;
    _phase = RoomPhase.connected;
    _blocked = false;
    _seatTakenOver = false;
    _errorCode = null;
    _errorMessage = null;
    _syncSeatCache();
    notifyListeners();
  }

  /// Section 33 item 4: leaves the line. Completes once the server answered
  /// `find_cancelled`; [phase] is then [RoomPhase.idle] again. A seat that
  /// the server gave before it read the cancel stands: [room] is set and the
  /// line is over all the same. With the line's socket down there is nothing
  /// to send: the server never seats a detached ticket and drops it after
  /// 30 seconds, so the line simply ends here.
  Future<void> cancelFind() async {
    if (_disposed || !_queueWanted || _cancelInFlight) {
      return;
    }
    _queueRetryTimer?.cancel();
    _queueRetryTimer = null;
    final RoomConnection? connection = _connection;
    if (connection != null && connection.isOpen) {
      _cancelInFlight = true;
      try {
        await connection.cancelFind();
      } on ProtocolErrorException {
        // The socket is closed just below either way, which detaches the
        // ticket; a detached ticket is never seated and expires on its own.
      } on RequestTimeoutException {
        // As above.
      } on ConnectionClosedException {
        // As above: the ticket is already detached.
      } finally {
        _cancelInFlight = false;
      }
      if (_disposed || _room != null) {
        return;
      }
    }
    _endQueue();
    _dropConnection();
    _phase = RoomPhase.idle;
    _errorCode = null;
    _errorMessage = null;
    notifyListeners();
  }

  /// Section 34 item 2: a new room against computer seats, [players] 2 or 4,
  /// with this phone as host. Sent on the line's socket when it is open (the
  /// server drops the ticket itself, so no `cancel_find` goes first),
  /// otherwise on a fresh one. The `room` answer lands as a create does; the
  /// seeds, `game_started` and the first `turn` follow and are reduced as
  /// any push. The `client_seed` is a fresh one of the `set_seed` shape.
  Future<void> playComputer({
    required String name,
    required int players,
  }) async {
    if (_disposed || _room != null || _computerInFlight || _cancelInFlight) {
      return;
    }
    if (!(_phase == RoomPhase.idle ||
        _phase == RoomPhase.failed ||
        (_phase == RoomPhase.connecting && _queueWanted))) {
      return;
    }
    _computerInFlight = true;
    _endQueue();
    _errorCode = null;
    _errorMessage = null;
    _phase = RoomPhase.connecting;
    notifyListeners();
    try {
      RoomConnection? connection = _connection;
      if (connection == null || !connection.isOpen) {
        final RoomConnection fresh = RoomConnection(
          url: serverUrl,
          connect: _connect,
        );
        if (!await _openAndAttach(fresh)) {
          return;
        }
        connection = fresh;
      }
      try {
        final String install = installIdIfReady() ?? await installId();
        final RoomSnapshot snapshot = await connection.playComputer(
          name: name,
          players: players,
          install: install,
          clientSeed: newMessageId(),
        );
        if (_disposed) {
          return;
        }
        _room = snapshot;
        _clearLastFinished();
        _lastRetirement = null;
        _selfRetired = false;
        _phase = RoomPhase.connected;
        _blocked = false;
        _seatTakenOver = false;
        _errorCode = null;
        _errorMessage = null;
        _syncSeatCache();
        notifyListeners();
      } catch (error) {
        _failFromRequest(error);
      }
    } finally {
      _computerInFlight = false;
    }
  }

  /// R: resumes a seat this controller never held, using a room code and
  /// seat token that survived a process kill (order 172's store) rather than
  /// ones this controller ever learned from a live connection of its own.
  /// Never throws, like every other method on this class.
  ///
  /// R2: accepted only from a controller that has never touched a room --
  /// not disposed, [leave] never called, [room] still null -- and only from
  /// [RoomPhase.idle] or [RoomPhase.failed]. Otherwise a no-op that changes
  /// nothing and does not notify.
  Future<void> resumeRoom({
    required String code,
    required int seat,
    required String seatToken,
  }) async {
    if (_disposed ||
        _leftCalled ||
        _room != null ||
        !(_phase == RoomPhase.idle || _phase == RoomPhase.failed)) {
      return;
    }

    _phase = RoomPhase.connecting;
    notifyListeners();

    final RoomConnection connection = RoomConnection(
      url: serverUrl,
      connect: _connect,
    );
    final bool opened = await _openAndAttach(connection);
    if (!opened) {
      // R3: an open failure is failed / 'transport', exactly as today --
      // _openAndAttach already did that.
      return;
    }

    try {
      final RoomSnapshot snapshot = await connection.resume(
        code: code,
        seatToken: seatToken,
      );
      if (_disposed) {
        return;
      }
      // R4: the snapshot itself carries no "your seat" field, but the server
      // now sends seat_assigned before the room reply to a resume
      // (docs/PROTOCOL.md section 15) whenever it moves this seat.
      // RoomConnection records that seat_assigned on itself the moment it
      // decodes the frame (connection.dart's _handleIncomingText), ahead of
      // and independent of anything this controller's own frame
      // subscription does with it, so connection.seat already carries it by
      // the time the awaited resume() above completes. Rule 5: that live
      // value, when there is one, is the truth about this seat, even over
      // the seat this call itself was given -- a resume from a stale record
      // moved while it was away must not overwrite the server's own
      // correction with what is now stale. Only when the connection never
      // saw a seat_assigned (an older server, or nothing moved) does this
      // fall back to the resumeRoom argument.
      _room = snapshot;
      _recordLastFinished(snapshot);
      _writeCachedSeat(connection.seat ?? seat);
      _cachedSeatToken = seatToken;
      _phase = RoomPhase.connected;
      _blocked = false;
      _seatTakenOver = false;
      _errorCode = null;
      _errorMessage = null;
      notifyListeners();
    } catch (error) {
      // R5: every code arrives verbatim in errorCode; room, seat and
      // seatToken are left exactly as they were before this call (null on a
      // fresh controller); G3, no sequence starts.
      _failFromRequest(error);
    }
  }

  /// Shared body of [createRoom] and [joinRoom]: both are accepted only from
  /// [RoomPhase.idle] or [RoomPhase.failed], both open a fresh connection and
  /// send one request, and both handle its outcome identically.
  Future<void> _openFresh({
    required bool gate,
    required Future<RoomSnapshot?> Function(RoomConnection connection) request,
    bool isJoin = false,
  }) async {
    if (_disposed || !gate) {
      return;
    }
    if (isJoin) {
      _knock = const KnockState();
      _wasKicked = false;
      _ban = null;
    }
    _phase = RoomPhase.connecting;
    notifyListeners();

    final RoomConnection connection = RoomConnection(
      url: serverUrl,
      connect: _connect,
    );
    final bool opened = await _openAndAttach(connection);
    if (!opened) {
      return;
    }

    try {
      final RoomSnapshot? snapshot = await request(connection);
      if (_disposed) {
        return;
      }
      if (snapshot == null) {
        // A knock: no seat yet. The phase stays connecting and
        // [knockState] says why; the server's next frame decides.
        notifyListeners();
        return;
      }
      _room = snapshot;
      _clearLastFinished();
      _lastRetirement = null;
      _selfRetired = false;
      _phase = RoomPhase.connected;
      _blocked = false;
      _seatTakenOver = false;
      _errorCode = null;
      _errorMessage = null;
      _syncSeatCache();
      notifyListeners();
    } catch (error) {
      _failFromRequest(error);
    }
  }

  /// Accepted only when [phase] is [RoomPhase.closed] or [RoomPhase.failed]
  /// and both [room] and [seatToken] are present; otherwise a no-op that
  /// changes nothing and does not notify. Opens a *new* connection and sends
  /// `resume` with the cached room code and seat token.
  ///
  /// This is a manual attempt (C8): it cancels any pending automatic timer
  /// and ends the running sequence, if there is one, before it does anything
  /// else. Its own outcome stands on its own -- a retryable failure here does
  /// not schedule another attempt -- and a later drop of the connection this
  /// call opens starts a fresh sequence, per C5. When [autoReconnectDelays]
  /// is empty there is never a timer or a sequence to cancel, so this method
  /// does exactly what it always has.
  Future<void> reconnect() async {
    final RoomSnapshot? room = _room;
    final String? token = _cachedSeatToken;
    if (_disposed ||
        _updateRequired ||
        _seatTakenOver ||
        !(_phase == RoomPhase.closed || _phase == RoomPhase.failed) ||
        room == null ||
        token == null) {
      return;
    }
    _cancelAutoReconnect();
    await _attemptReconnect(automatic: false, room: room, token: token);
  }

  /// C-555 D1: what the lobby's Resync does. With the phase [RoomPhase.closed]
  /// or [RoomPhase.failed] this is [reconnect]. With the phase
  /// [RoomPhase.connected], a room, a cached seat token and no resync in
  /// flight it is `_beginResync` on the socket already open, never a second
  /// transport. Every other case changes nothing and returns at once.
  /// Completes when the resync it started has settled -- the room re-based,
  /// a verdict from the server, or a failure that is not a verdict -- or at
  /// once when it started nothing.
  Future<void> resync() async {
    // C-637 D2: a seat another phone has taken is never resumed from here.
    if (_disposed || _seatTakenOver) {
      return;
    }
    if (_phase == RoomPhase.closed || _phase == RoomPhase.failed) {
      await reconnect();
      return;
    }
    final RoomSnapshot? room = _room;
    if (_phase != RoomPhase.connected ||
        room == null ||
        _cachedSeatToken == null ||
        _connection == null ||
        _resyncInFlight) {
      return;
    }
    _beginResync(room);
    if (!_resyncInFlight) {
      return;
    }
    final Completer<void> settled = Completer<void>();
    _resyncSettled = settled;
    void onChange() {
      if (!_resyncInFlight && !settled.isCompleted) {
        settled.complete();
      }
    }

    addListener(onChange);
    // _beginResync raises the flag after its own notification, so a screen
    // drawing the turning mark is told here.
    notifyListeners();
    try {
      await settled.future;
    } finally {
      removeListener(onChange);
      if (identical(_resyncSettled, settled)) {
        _resyncSettled = null;
      }
    }
  }

  /// The wait [resync] is holding, completed by [dispose] so a screen that
  /// goes away mid-resync does not leave its caller waiting forever.
  Completer<void>? _resyncSettled;

  /// The body every reconnect attempt runs, manual or automatic: phase to
  /// [RoomPhase.connecting], open a new [RoomConnection], send `resume` with
  /// the cached room code and seat token. [automatic] governs only what
  /// happens after a failure (C7, C8); the attempt itself is identical
  /// either way, and is the same body [reconnect] has always run.
  Future<void> _attemptReconnect({
    required bool automatic,
    required RoomSnapshot room,
    required String token,
  }) async {
    _phase = RoomPhase.connecting;
    notifyListeners();

    final RoomConnection connection = RoomConnection(
      url: serverUrl,
      connect: _connect,
    );
    final bool opened = await _openAndAttach(connection);
    if (!opened) {
      _sendRematchOnResume = false;
      _afterReconnectAttemptFailure(automatic);
      return;
    }

    try {
      final RoomSnapshot snapshot = await connection.resume(
        code: room.code,
        seatToken: token,
      );
      if (_disposed) {
        return;
      }
      _room = snapshot;
      _landedPre = null;
      _recordLastFinished(snapshot);
      _phase = RoomPhase.connected;
      _blocked = false;
      _seatTakenOver = false;
      _hasDesynced = false;
      _errorCode = null;
      _errorMessage = null;
      _syncSeatCache();
      notifyListeners();
      if (automatic) {
        // A later drop starts a fresh sequence from autoReconnectDelays[0].
        _cancelAutoReconnect();
      }
      if (_sendRematchOnResume) {
        _sendRematchOnResume = false;
        await rematch();
      }
    } catch (error) {
      _sendRematchOnResume = false;
      _failFromRequest(error);
      _afterReconnectAttemptFailure(automatic);
    }
  }

  /// What C7 and C8 say happens after a reconnect attempt -- manual or
  /// automatic -- lands in [RoomPhase.failed]. A non-retryable code blocks
  /// the controller (C3) regardless of which kind of attempt this was. Only
  /// an automatic attempt ever schedules another one, and only when the
  /// sequence it belongs to is still running: [leave] or [dispose] may have
  /// ended it while this attempt was in flight, and that is not undone here.
  void _afterReconnectAttemptFailure(bool automatic) {
    if (_disposed) {
      return;
    }
    final bool retryable = _retryableErrorCodes.contains(_errorCode);
    if (!retryable) {
      _blocked = true;
    }
    if (!automatic) {
      return;
    }
    if (!_sequenceRunning) {
      return;
    }
    if (!retryable) {
      _sequenceRunning = false;
      return;
    }
    if (_nextDelayIndex < autoReconnectDelays.length) {
      _scheduleNextAttempt();
    } else {
      _sequenceRunning = false;
    }
  }

  /// C5, C10: begins a fresh sequence. [immediate] runs the first attempt at
  /// once, with no delay (C10); otherwise the first attempt waits for
  /// `autoReconnectDelays[0]` (C5).
  void _startSequence({required bool immediate}) {
    _sequenceRunning = true;
    _nextDelayIndex = 0;
    if (immediate) {
      unawaited(_runAutomaticAttempt());
    } else {
      _scheduleNextAttempt();
    }
  }

  /// Schedules the next automatic attempt for `autoReconnectDelays[
  /// _nextDelayIndex]` and advances the index past it. N1: this is always a
  /// false-to-true transition of [autoReconnectPending] (the timer is null
  /// at every call site that reaches this), so the notification that
  /// follows is never an empty one under N2.
  void _scheduleNextAttempt() {
    final Duration delay = autoReconnectDelays[_nextDelayIndex];
    _nextDelayIndex++;
    _reconnectTimer = Timer(delay, _onReconnectTimerFired);
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// C7: what a pending timer's firing does. N1: clearing [_reconnectTimer]
  /// is always a true-to-false transition of [autoReconnectPending] (a timer
  /// only exists here because it just fired). When the sequence goes on to
  /// an attempt, [_attemptReconnect]'s own notify -- reached synchronously,
  /// before control returns to the event loop -- carries that change; when
  /// it does not (no longer eligible, or the phase moved on while this timer
  /// was pending), nothing else notifies, so this does.
  void _onReconnectTimerFired() {
    _reconnectTimer = null;
    if (!_eligible ||
        !(_phase == RoomPhase.closed || _phase == RoomPhase.failed)) {
      _sequenceRunning = false;
      if (!_disposed) {
        notifyListeners();
      }
      return;
    }
    unawaited(_runAutomaticAttempt());
  }

  /// Runs one automatic attempt. [_eligible] guarantees [room] and
  /// [seatToken] are non-null at every call site that reaches this.
  Future<void> _runAutomaticAttempt() async {
    final RoomSnapshot? room = _room;
    final String? token = _cachedSeatToken;
    if (room == null || token == null) {
      // Not reachable while _eligible held at the call site, kept only so
      // this never dereferences a null defensively rather than by contract.
      _sequenceRunning = false;
      return;
    }
    await _attemptReconnect(automatic: true, room: room, token: token);
  }

  /// Cancels any pending automatic timer and ends the running sequence, if
  /// there is one. A no-op, both here and at every call site, when
  /// [autoReconnectDelays] is empty: nothing ever schedules a timer in that
  /// case, so there is never anything to cancel.
  ///
  /// N1: called from [reconnect], [onAppResumed] and [leave]. The first two
  /// always go on, in the same synchronous stretch, to a notify of their own
  /// -- reached before control returns to the event loop -- that carries
  /// this change along with theirs. [leave] does not: when the connection it
  /// is tearing down is still set, it awaits `leaveRoom()` before its own
  /// notify, and control returns to the event loop in between. So this
  /// notifies here itself, and only when [autoReconnectPending] actually
  /// changed (N2): a timer was pending and no longer is, or there was
  /// nothing to cancel and nothing changes.
  void _cancelAutoReconnect() {
    final bool wasPending = _reconnectTimer != null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sequenceRunning = false;
    if (wasPending && !_disposed) {
      notifyListeners();
    }
  }

  /// C10: the foreground hook. Never throws. A no-op unless this controller
  /// is eligible (C4) and [phase] is [RoomPhase.closed] or
  /// [RoomPhase.failed] -- which also covers "an attempt is already in
  /// flight", since that leaves [phase] at [RoomPhase.connecting].
  void onAppResumed() {
    if (!_eligible ||
        !(_phase == RoomPhase.closed || _phase == RoomPhase.failed)) {
      return;
    }
    _cancelAutoReconnect();
    _startSequence(immediate: true);
  }

  /// Host-only. Forwards to the connection when [phase] is
  /// [RoomPhase.connected] and is a silent no-op otherwise. Replaces [room]
  /// with the snapshot the server answers with.
  Future<void> setPlayers(int players) async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      final RoomSnapshot snapshot = await connection.setPlayers(players);
      if (_disposed) {
        return;
      }
      _room = snapshot;
      notifyListeners();
    } catch (error) {
      _failFromSetPlayers(error);
    }
  }

  /// Host-only, in a game. docs/PROTOCOL.md section 33 item 8 (replacing
  /// section 28 rule 4's case): asks the server to retire any playing seat,
  /// connected, away or a computer's. An older server still refuses a seat
  /// whose socket is up with `NOT_ABSENT`, which is passed back like any
  /// other refusal below. Null when the server
  /// answered with `seat_retired`, which [_reduceSeatRetired] applies like
  /// any other push (this method changes nothing itself). The error code
  /// when the server refused with one of [_kickRejectedCodes]; the
  /// connection stays up and the host's screen words the refusal. Any other
  /// failure goes to [_failFromInRoomRequest] as every other request's does.
  /// A silent no-op returning null when not connected, as [setPlayers].
  Future<String?> kick(int seat) async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return null;
    }
    try {
      await connection.kick(seat);
      return null;
    } catch (error) {
      if (error is ProtocolErrorException &&
          _kickRejectedCodes.contains(error.code)) {
        return error.code;
      }
      _failFromInRoomRequest(error);
      return null;
    }
  }

  /// Host-only, LOBBY only (section 31 item 4). Accepts or rejects the knock
  /// [knockId]. The result arrives as `knock_closed` and, on accept,
  /// `player_joined`, applied like any push. A race the server answers with
  /// `NO_SUCH_KNOCK`, `NOT_HOST`, `WRONG_PHASE` or `BAD_FIELD` leaves the
  /// connection up and is read from [errorCode]. A silent no-op when not
  /// connected.
  Future<void> answerKnock(String knockId, {required bool accept}) async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      await connection.request('answer_knock', <String, Object?>{
        'knock_id': knockId,
        'accept': accept,
      });
    } catch (error) {
      _failFromHostRequest(error);
    }
  }

  /// Host-only, any state of a live room (section 31 item 5). The answer is
  /// the `room` broadcast, the requester's copy carrying `re`; it is applied
  /// here exactly as [rematch] applies its own. A silent no-op when not
  /// connected.
  Future<void> setGuestApproval(bool on) async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      final Frame frame = await connection.request(
        'set_guest_approval',
        <String, Object?>{'enabled': on},
      );
      if (_disposed) {
        return;
      }
      final RoomSnapshot? room = _room;
      if (room != null && frame.type == 'room') {
        final int? seqValue = frame.seq;
        if (seqValue != null && seqValue <= room.seq) {
          return;
        }
        _applyRoomFrame(frame, room);
      }
    } catch (error) {
      _failFromHostRequest(error);
    }
  }

  /// Section 34 item 3: host only, in an open LOBBY with a free seat once
  /// its wait has run out ([RoomSnapshot.fillMs] 0). The fill arrives as
  /// pushes (`knock_closed`, `player_joined`, `seat_seed`, `game_started`)
  /// reduced like any other; a `room` answer is applied as [setGuestApproval]
  /// applies its own. A refusal goes the way of every host request. A silent
  /// no-op when not connected.
  ///
  /// Completes with the refusal code when the server refused with one the
  /// host can act on (kept in [errorCode] too, as for every host request);
  /// null when the request was accepted, when nothing was sent, and when the
  /// connection was lost under it.
  Future<String?> fillComputer() async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return null;
    }
    try {
      final Frame frame = await connection.fillComputer();
      if (_disposed) {
        return null;
      }
      final RoomSnapshot? room = _room;
      if (room != null && frame.type == 'room') {
        final int? seqValue = frame.seq;
        if (seqValue != null && seqValue <= room.seq) {
          return null;
        }
        _applyRoomFrame(frame, room);
      }
      return null;
    } catch (error) {
      _failFromHostRequest(error);
      if (error is ProtocolErrorException &&
          _hostRequestSoftCodes.contains(error.code)) {
        return error.code;
      }
      return null;
    }
  }

  /// A host request refused for a race or a rights reason does not end the
  /// connection: the code lands in [errorCode] and listeners are told. Any
  /// other failure is an in-room failure as for every other request.
  void _failFromHostRequest(Object error) {
    if (error is ProtocolErrorException &&
        _hostRequestSoftCodes.contains(error.code)) {
      _errorCode = error.code;
      _errorMessage = error.message;
      notifyListeners();
      return;
    }
    _failFromInRoomRequest(error);
  }

  /// Host-only. Forwards to the connection when [phase] is
  /// [RoomPhase.connected] and is a silent no-op otherwise. The reply is a
  /// plain frame, not a snapshot; it is not parsed as one and changes
  /// nothing here. The `game_started` and `turn` frames that follow reach
  /// [frames] like every other frame and, when they are contiguous, are
  /// reduced exactly as they would be if this controller had never asked for
  /// them.
  Future<void> startGame() async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      await connection.startGame();
    } catch (error) {
      _failFromStartGame(error);
    }
  }

  /// C-246 rule 1: forwards `rematch` to the connection when [phase] is
  /// [RoomPhase.connected] and is a silent no-op otherwise, from any seat --
  /// opening a fresh LOBBY from FINISHED, or accepting one already open.
  /// PROTOCOL 16.2/16.3: the answer to `rematch` is the `room` broadcast,
  /// and the requester's own copy of it carries `re` set to this request's
  /// id. That is exactly the shape [_reduceRoom] ignores (the request path
  /// already owns every `room` that answers one of this controller's own
  /// requests), so nobody else applies it; this method does, through
  /// [_applyRoomFrame], the same seq-check-decode-apply body [_reduceRoom]
  /// itself uses for an unsolicited push.
  ///
  /// Unlike [roll], [move], [startGame] and [setPlayers], there is no
  /// race-code carve-out here: every failure, whatever the code, routes
  /// straight through [_failFromInRoomRequest], the same in-room request
  /// failure path those methods fall through to once their own races are
  /// ruled out. C-246's own rule 8 is the screen's to read, not this
  /// method's: a `NO_SUCH_ROOM` answer and every other code both land here
  /// in [RoomPhase.failed] with [errorCode] set, and it is GameScreen that
  /// decides a `NO_SUCH_ROOM` failure still shows the end card while every
  /// other code falls through to the ordinary connection-lost body.
  ///
  /// PROTOCOL 16.3: from a seat already ready, `rematch` changes nothing on
  /// the server and the reply it gets back carries the room's current
  /// `seq`, not a newer one. [_applyRoomFrame]'s gap check reads anything
  /// other than `room.seq + 1` as a resync, which that reply is not -- it is
  /// the same room this controller already holds. A reply whose `seq` is
  /// not newer than [_room]'s own is this method's to drop before
  /// [_applyRoomFrame] ever sees it: no resync, no notify. A genuinely newer
  /// `seq`, applied in sequence or with a real gap behind it, still goes
  /// through [_applyRoomFrame] exactly as before.
  Future<void> rematch() async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      final Frame frame = await connection.rematch();
      if (_disposed) {
        return;
      }
      final RoomSnapshot? room = _room;
      if (room != null) {
        final int? seqValue = frame.seq;
        if (seqValue != null && seqValue <= room.seq) {
          return;
        }
        _applyRoomFrame(frame, room);
      }
    } catch (error) {
      _failFromInRoomRequest(error);
    }
  }

  /// C-316 rule 4: tapping Play again offline starts the same reconnect
  /// the connection-lost card's Reconnect starts, and sends `rematch` once
  /// the resume succeeds.
  Future<void> reconnectAndRematch() async {
    if (_disposed || _updateRequired || _seatTakenOver) {
      return;
    }
    if (_phase == RoomPhase.connected) {
      await rematch();
      return;
    }
    final RoomSnapshot? room = _room;
    final String? token = _cachedSeatToken;
    if (room == null || token == null) {
      return;
    }
    _sendRematchOnResume = true;
    if (_phase == RoomPhase.connecting) {
      return;
    }
    _cancelAutoReconnect();
    await _attemptReconnect(automatic: false, room: room, token: token);
  }

  /// Forwards to the connection when [phase] is [RoomPhase.connected] and is
  /// a silent no-op otherwise. The reply is a plain frame, not a snapshot; it
  /// is not parsed as one and changes nothing here. The `rolled` frame that
  /// follows reaches [frames] like every other frame and is what actually
  /// moves the turn forward.
  ///
  /// docs/PROTOCOL.md section 35 item 5: with a [pre] in hand, `roll` still
  /// goes out at once, and [landAfter] later the roll lands from that `pre`:
  /// the turn becomes what its `rolled` will say and [frames] carries a
  /// `rolled` built from it (never recorded in [gameTranscript]), so a screen
  /// plays the landing exactly as it plays a `rolled` from the server. The
  /// server's own `rolled`, whenever it comes, is then only checked against
  /// it ([isPreEcho]); one that differs is the truth and starts one resync.
  /// Without a `pre`, [landAfter] is unused and nothing changes from before.
  Future<void> roll({Duration landAfter = Duration.zero}) async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    final PreRoll? inHand = _preThrown == null && !_holdingFrames ? pre : null;
    if (inHand != null) {
      _preThrown = inHand;
      _preConnection = connection;
      _preLandTimer?.cancel();
      _preLandTimer = Timer(landAfter, _landPre);
    }
    try {
      await connection.roll();
    } catch (error) {
      if (inHand != null &&
          error is ProtocolErrorException &&
          _rejectedIntentionCodes.contains(error.code)) {
        // The roll shown from `pre` was not taken on this request. The face
        // is still the one the server publishes for that `k` (section 35
        // item 3), but the turn it leads to is the server's to say, so the
        // table is fetched again rather than left on a guess.
        unawaited(resync());
        return;
      }
      _failFromRollOrMove(error);
    }
  }

  /// Section 35 item 5: the die thrown under [_preThrown] lands. Shows the
  /// roll from its `pre` when the table still holds that turn on the socket
  /// the roll went out on, then lets through, in order, every frame held
  /// back since my `rolled` arrived. On any other table the `pre` is stale
  /// and nothing is shown from it: the held frames go on as if they had just
  /// arrived, or, when the socket they came on is gone, go with it.
  void _landPre() {
    _preLandTimer = null;
    final PreRoll? thrown = _preThrown;
    final RoomConnection? thrownOn = _preConnection;
    _preThrown = null;
    _preConnection = null;
    if (thrown == null || _disposed) {
      return;
    }
    final bool sameSocket =
        _phase == RoomPhase.connected &&
        thrownOn != null &&
        identical(_connection, thrownOn);
    final RoomSnapshot? room = _room;
    final TurnState? turn = room?.turn;
    final bool stillInHand =
        room != null &&
        turn != null &&
        room.state == RoomState.playing &&
        turn.seat == thrown.seat &&
        turn.phase == TurnPhase.awaitRoll &&
        turn.pre?.k == thrown.k;
    if (!sameSocket) {
      _holdingFrames = false;
      _heldFrames.clear();
      return;
    }
    if (_resyncInFlight || _selfRetired || !stillInHand) {
      _releaseHeldFrames();
      return;
    }
    final int deadlineMs = turn.segmentMs ?? room.rules.turnSeconds * 1000;
    final Map<String, Object?> data = thrown.rolledData(deadlineMs: deadlineMs);
    _room = room.copyWith(
      turn: _rolledTurn(
        data,
        room,
        seat: thrown.seat,
        value: thrown.value,
        legal: thrown.legal,
        deadlineMs: deadlineMs,
        k: thrown.k,
      ),
      recentRolls: _appendRecentRoll(room.recentRolls, thrown.k, thrown.value),
      recentRollSeats: _appendRecentRollSeat(room.recentRollSeats, thrown.seat),
      lastSpentFace: null,
    );
    _landedPre = thrown;
    if (!_framesController.isClosed) {
      _framesController.add(
        Frame(type: 'rolled', id: newMessageId(), data: data),
      );
    }
    notifyListeners();
    if (_heldFrames.isEmpty) {
      _holdingFrames = false;
      return;
    }
    // The landing reaches the screen before the frames that came after it.
    Timer.run(() {
      if (_disposed || !identical(_connection, thrownOn)) {
        _holdingFrames = false;
        _heldFrames.clear();
        return;
      }
      _releaseHeldFrames();
    });
  }

  /// Hands the frames held behind a landing on, in order, each through
  /// [_handleFrame] as if it had just arrived.
  void _releaseHeldFrames() {
    _holdingFrames = false;
    if (_heldFrames.isEmpty) {
      return;
    }
    final List<Frame> held = List<Frame>.of(_heldFrames);
    _heldFrames.clear();
    for (final Frame frame in held) {
      if (_disposed) {
        return;
      }
      _handleFrame(frame);
    }
  }

  /// True when [frame] is to wait for the landing of my roll in the air:
  /// my `rolled` for the thrown `k`, and every state-changing frame after
  /// it until the landing lets them through.
  bool _holdForLanding(Frame frame) {
    if (!_stateChangingTypes.contains(frame.type)) {
      return false;
    }
    if (!_holdingFrames) {
      final PreRoll? thrown = _preThrown;
      if (thrown == null ||
          frame.type != 'rolled' ||
          _asInt(frame.data, 'seat') != thrown.seat ||
          _asInt(frame.data, 'k') != thrown.k) {
        return false;
      }
      _holdingFrames = true;
    }
    _heldFrames.add(frame);
    return true;
  }

  /// Forgets every roll of mine in the air or shown and not yet confirmed,
  /// with the frames held for it: the seat, the socket or the room under it
  /// is gone.
  void _dropPreState() {
    _preLandTimer?.cancel();
    _preLandTimer = null;
    _preThrown = null;
    _preConnection = null;
    _landedPre = null;
    _holdingFrames = false;
    _heldFrames.clear();
  }

  /// docs/PROTOCOL.md section 30 rule 4: declines the pending shared release.
  /// Sent exactly like [roll]; the `release_declined` broadcast that answers
  /// it is what changes the room.
  Future<void> declineRelease() async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      await connection.declineRelease();
    } catch (error) {
      _failFromRollOrMove(error);
    }
  }

  /// Forwards to the connection when [phase] is [RoomPhase.connected] and is
  /// a silent no-op otherwise. The reply is a plain frame, not a snapshot; it
  /// is not parsed as one and changes nothing here. The `moved` frame that
  /// follows reaches [frames] like every other frame and is what actually
  /// moves the token.
  ///
  /// `token` is passed through to [RoomConnection.move] exactly as given and
  /// is not validated here: not its range, not `turn.legal`, not whose turn
  /// it is. The server is authoritative and answers `ILLEGAL_MOVE`,
  /// `NOT_YOUR_TURN` or `WRONG_PHASE` when it is wrong; checking any of that
  /// here would be a second implementation of the rules the server already
  /// owns. A screen may grey a button out, but that is the screen's business,
  /// not this method's.
  ///
  /// `face`, docs/PROTOCOL.md section 21.1: the queued face this move
  /// spends, forwarded to [RoomConnection.move] exactly as given. Null means
  /// the server spends `defaultFace`.
  Future<void> move(int token, {int? face}) async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      await connection.move(token, face: face);
    } catch (error) {
      _failFromRollOrMove(error);
    }
  }

  /// C-478 D4: sends one quick-message id. True when the server's copy came
  /// back. False, silently, when not connected, disposed, or on any error
  /// (RATE_LIMITED, a timeout, a closed connection). Unlike [roll] and
  /// [move] this never goes through [_failFromRollOrMove]: a refused
  /// message blocks nothing and starts no reconnect.
  ///
  /// C-520 A3: defined through [sendEmoteOutcome].
  Future<bool> sendEmote(String id) async {
    return (await sendEmoteOutcome(id)) == EmoteOutcome.admitted;
  }

  /// C-520 A3. [sendEmote] with the reason it did not go through: refused
  /// only when the server answered the `emote` with an error frame, whatever
  /// its code. Not connected, disposed, a closed connection and a timeout
  /// are all [EmoteOutcome.failed]; the reconnect UI owns those.
  Future<EmoteOutcome> sendEmoteOutcome(String id) async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return EmoteOutcome.failed;
    }
    try {
      await connection.emote(id);
      return EmoteOutcome.admitted;
    } on ProtocolErrorException {
      return EmoteOutcome.refused;
    } catch (_) {
      return EmoteOutcome.failed;
    }
  }

  /// C-304 rule 1: fetches the server's game log for the current game.
  /// Forwards directly to the current connection's [gameLog].
  Future<List<Frame>> fetchGameLog() {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return Future<List<Frame>>.error(const ConnectionClosedException());
    }
    return connection.gameLog();
  }

  /// Sends `leave_room` best-effort (its outcome, success or failure, is
  /// never surfaced as an error: this controller is on its way out either
  /// way), closes the connection, and sets [phase] to [RoomPhase.closed].
  /// Never throws even if the socket had already died.
  ///
  /// C-669 R4: completes with whether the server heard the leave, that is,
  /// whether the `leave_room` request was answered by its reply, or by an
  /// `error` whose code says the seat or the room is already gone
  /// ([_leaveGoneCodes]): the server then holds nothing for this phone, and
  /// the caller may throw the key away. Any other `error` (BAD_FIELD,
  /// RATE_LIMITED, INTERNAL, the engine's refusals of the retire a leave
  /// can cause) means the server did not process the leave and still holds
  /// the seat. False too when there was no live connection to send it on,
  /// the request timed out, or the connection ended first: the server then
  /// still holds the seat as a dropped one, and the caller must not throw
  /// away the key to it. Also false on a controller that was already
  /// disposed.
  Future<bool> leave() async {
    if (_disposed) {
      return false;
    }
    _leftCalled = true;
    _sendRematchOnResume = false;
    _endQueue();
    _cancelAutoReconnect();
    _clearLastFinished();
    _knock = const KnockState();
    final RoomConnection? connection = _connection;
    _connection = null;
    unawaited(_frameSub?.cancel());
    _frameSub = null;
    bool delivered = false;
    if (connection != null) {
      try {
        await connection.leaveRoom();
        delivered = true;
      } on ProtocolErrorException catch (e) {
        delivered = _leaveGoneCodes.contains(e.code);
      } catch (_) {
        // Best-effort. The socket may already be gone; that is not this
        // method's problem to report, only the caller's to know.
      }
      // _connection was already nulled above, so dispose() -- if it ran
      // while leaveRoom() was in flight -- found nothing to close. This
      // connection is this method's alone to close either way, disposed or
      // not: closing it touches no ChangeNotifier state and is not the
      // mutation the disposed guard below exists to skip.
      unawaited(connection.close());
    }
    if (_disposed) {
      return delivered;
    }
    _phase = RoomPhase.closed;
    notifyListeners();
    return delivered;
  }

  @override
  void dispose() {
    _disposed = true;
    _dropPreState();
    _sendRematchOnResume = false;
    _queueRetryTimer?.cancel();
    _queueRetryTimer = null;
    final Completer<void>? resyncWait = _resyncSettled;
    if (resyncWait != null && !resyncWait.isCompleted) {
      resyncWait.complete();
    }
    _cancelAutoReconnect();
    _clearLastFinished();
    unawaited(_frameSub?.cancel());
    _frameSub = null;
    unawaited(_connection?.close());
    _connection = null;
    if (!_framesController.isClosed) {
      unawaited(_framesController.close());
    }
    super.dispose();
  }

  /// Opens [connection], and on success cancels any previous frame
  /// subscription, makes [connection] the current one, forwards its frames,
  /// and watches for it ending on its own. On failure, maps the connector's
  /// rejection to the `'transport'` error and returns false. Never throws.
  Future<bool> _openAndAttach(RoomConnection connection) async {
    try {
      await connection.open();
    } catch (_) {
      // The connector's future rejected: the server is unreachable. Rule 2.
      _fail('transport', '');
      return false;
    }
    if (_disposed) {
      unawaited(connection.close());
      return false;
    }
    _attach(connection);
    return true;
  }

  /// Makes an open [connection] the current one: forwards its frames and
  /// watches for it ending on its own.
  void _attach(RoomConnection connection) {
    _dropPreState();
    unawaited(_frameSub?.cancel());
    final RoomConnection? previous = _connection;
    _connection = connection;
    if (previous != null) {
      // Whatever this controller was holding before is superseded now.
      // It is already closed in every path that reaches here (the gate on
      // every caller of this method only allows it from idle, closed or
      // failed), so this is cleanup, not a live disconnect.
      unawaited(previous.close());
    }

    _frameSub = connection.frames.listen(_handleFrame);
    unawaited(
      connection.done.then((_) {
        if (_disposed || !identical(_connection, connection)) {
          // Superseded by a later connection, or torn down by leave() or
          // dispose() before this fired: not "ended on its own".
          return;
        }
        if (_seatTakenOver) {
          // C-637 D1: the takeover already closed this phone's side and set
          // the phase; this is that close arriving, nothing left to change.
          return;
        }
        if (_queueWanted && _room == null) {
          // Section 33 item 4: the ticket waits 30 seconds for this phone
          // to come back with it; the line's own backoff does that.
          _connection = null;
          unawaited(_frameSub?.cancel());
          _frameSub = null;
          _onQueueSocketLost('closed');
          return;
        }
        if (_knock.phase == KnockPhase.pending) {
          // The socket went while a knock was open: the server closes that
          // knock as withdrawn, and this phone holds no seat to resume.
          _knock = KnockState(
            phase: KnockPhase.withdrawn,
            knockId: _knock.knockId,
          );
        }
        _phase = RoomPhase.closed;
        notifyListeners();
        // C5: the current connection ended on its own. If eligible and no
        // sequence is already running, that is a drop starting one.
        if (_eligible && !_sequenceRunning) {
          _startSequence(immediate: false);
        }
      }),
    );
    _syncSeatCache();
  }

  /// Rule 5: seat and seat token are read through from the live connection
  /// while there is one, and the last non-null value either has ever
  /// produced is what the public getters expose from then on, even after
  /// that connection is gone.
  void _syncSeatCache() {
    final RoomConnection? connection = _connection;
    if (connection == null) {
      return;
    }
    final int? liveSeat = connection.seat;
    if (liveSeat != null) {
      _writeCachedSeat(liveSeat);
    }
    final String? liveToken = connection.seatToken;
    if (liveToken != null) {
      _cachedSeatToken = liveToken;
    }
  }

  /// The one writer of [_cachedSeat]. A change from one non-null seat to a
  /// different non-null seat records the old one in [seatMovedFrom]; the
  /// same seat again, or a first seat, records nothing.
  void _writeCachedSeat(int? next) {
    final int? previous = _cachedSeat;
    if (previous != null && next != null && previous != next) {
      _seatMovedFrom = previous;
    }
    _cachedSeat = next;
  }

  /// C-310 rule 1: records the snapshot when it becomes FINISHED.
  /// C-316 rule 2: keeps the snapshot as it stood at game end for the same
  /// gameId, preserving the finished seat list across later player leaves.
  void _recordLastFinished(RoomSnapshot snapshot) {
    if (snapshot.state == RoomState.finished) {
      if (_lastFinished == null || _lastFinished!.gameId != snapshot.gameId) {
        _lastFinished = snapshot;
      }
    }
  }

  /// C-310 rule 1: clears the finished snapshot when a new game starts, on
  /// leaving the room, or when joining or creating another room.
  void _clearLastFinished() {
    _lastFinished = null;
  }

  /// C-445 D1, D2: a `room` snapshot of a PLAYING or FINISHED game is how a
  /// phone that was away learns which game the room is in now; it never
  /// sees that game's `game_started`. When the snapshot names a game other
  /// than the one the open transcript belongs to, the transcript is
  /// cleared and re-keyed to the snapshot's game, so the old game's frames
  /// never read as the new game's record (the transcript then holds no
  /// `game_started` and the stats fall back to the server's `game_log`).
  /// A snapshot of the same game appends as any other frame. A transcript
  /// never opened (a relaunch) is left alone. A PLAYING snapshot of a game
  /// other than the held finished one also drops that finished snapshot,
  /// as a live start does; a FINISHED one is recorded by
  /// [_recordLastFinished] as before.
  void _noteSnapshotGame(Frame frame) {
    final String? state = _asString(frame.data, 'state');
    final String? gameId = _asString(frame.data, 'game_id');
    if (gameId == null || (state != 'PLAYING' && state != 'FINISHED')) {
      return;
    }
    if (_hasOpenedTranscript && gameId != _transcriptGameId) {
      _transcriptGameId = gameId;
      _gameTranscript.clear();
    }
    if (state == 'PLAYING' &&
        _lastFinished != null &&
        _lastFinished!.gameId != gameId) {
      _clearLastFinished();
    }
  }

  /// Every frame the current connection produces, including every one this
  /// controller's reducer ignores. Recorded into [gameTranscript] from
  /// `game_started` onward, forwarded to [frames] unconditionally, then
  /// handed to the reducer when it is one of the types docs/PROTOCOL.md
  /// section 5 marks as carrying `seq`.
  void _handleFrame(Frame frame) {
    if (_holdForLanding(frame)) {
      return;
    }
    if (frame.type == 'room') {
      _noteSnapshotGame(frame);
    }
    if (frame.type == 'game_started') {
      final String? gameId = _asString(frame.data, 'game_id');
      if (!_hasOpenedTranscript || gameId != _transcriptGameId) {
        _hasOpenedTranscript = true;
        _transcriptGameId = gameId;
        _gameTranscript.clear();
      }
      _gameTranscript.add(frame);
    } else if (_hasOpenedTranscript) {
      // A quick message is chatter, not game record (section 25.5): it is
      // not in the server's game_log and must not be in this transcript.
      if (frame.type != 'game_log' && frame.type != 'emote') {
        _gameTranscript.add(frame);
      }
    }
    if (!_framesController.isClosed) {
      _framesController.add(frame);
    }
    _syncSeatCache();
    if (frame.type == 'error' && frame.re == null) {
      // C3: an error frame the server sent unprompted, not a reply to
      // anything this controller asked. Section 7.1: the server sends
      // exactly this before every close it initiates for cause, including
      // 4004 -- a newer socket of the same player taking this seat over --
      // and retrying that one would make two phones of one player fight
      // over the seat forever.
      _blocked = true;
      if (frame.data['code'] == 'UPDATE_REQUIRED' && !_updateRequired) {
        _updateRequired = true;
        notifyListeners();
      }
      if (frame.data['code'] == 'BAD_SEAT_TOKEN') {
        // C-637 D1: this phone no longer holds the seat, so the connection
        // is closed here and now rather than when the server's close
        // arrives. No listener ever sees a connected phase with the seat
        // taken, and nothing can send for it in between.
        // C-637 D3: no resync state outlives the takeover.
        _seatTakenOver = true;
        _phase = RoomPhase.closed;
        _hasDesynced = false;
        _resyncInFlight = false;
        final RoomConnection? taken = _connection;
        if (taken != null) {
          unawaited(taken.close());
        }
        notifyListeners();
      }
    }
    if (frame.type == 'knock_failed') {
      _onKnockFailed(frame);
      return;
    }
    if (frame.type == 'kicked') {
      _onKicked(frame);
      return;
    }
    if (frame.type == 'room' &&
        frame.re == null &&
        _room == null &&
        _knock.phase == KnockPhase.pending) {
      _onKnockAccepted(frame);
      return;
    }
    if (frame.type == 'queued') {
      _onQueued(frame);
      return;
    }
    if (frame.type == 'room' &&
        frame.re == null &&
        _room == null &&
        _queueWanted) {
      // Section 33 item 4: a seat from the line, `seat_assigned` (already
      // recorded by the connection) then this `room`.
      final RoomSnapshot decoded;
      try {
        decoded = RoomSnapshot.fromJson(frame.data);
      } on SnapshotFormatException {
        return;
      }
      _seatFromLine(decoded);
      return;
    }
    if (_stateChangingTypes.contains(frame.type)) {
      _reduce(frame);
    }
  }

  /// Section 33 items 3 and 4: the answer to `find_game` and every later
  /// change of place. Ignored once the line is over.
  void _onQueued(Frame frame) {
    if (!_queueWanted || _room != null) {
      return;
    }
    final String? ticket = _asString(frame.data, 'ticket');
    final int? position = _asInt(frame.data, 'position');
    if (ticket == null || ticket.isEmpty || position == null || position < 1) {
      return;
    }
    _queue = QueueState(ticket: ticket, position: position);
    notifyListeners();
  }

  /// Section 31 item 4 and ruling (d): the knocker's seat arrives as
  /// `seat_assigned` (already recorded by the connection) and an unsolicited
  /// `room`. That `room` is the first snapshot this phone holds.
  void _onKnockAccepted(Frame frame) {
    final RoomSnapshot decoded;
    try {
      decoded = RoomSnapshot.fromJson(frame.data);
    } on SnapshotFormatException {
      return;
    }
    _room = decoded;
    _clearLastFinished();
    _lastRetirement = null;
    _selfRetired = false;
    _knock = KnockState(phase: KnockPhase.accepted, knockId: _knock.knockId);
    _phase = RoomPhase.connected;
    _blocked = false;
    _seatTakenOver = false;
    _errorCode = null;
    _errorMessage = null;
    _syncSeatCache();
    notifyListeners();
  }

  /// Section 31 item 4: the knock ended without a seat. The socket holds
  /// nothing, so it is closed and the phase goes back to idle; [knockState]
  /// says how it ended. `full` and `switched_off` are the cases the server
  /// answers with `ROOM_FULL`, and [errorCode] carries it.
  void _onKnockFailed(Frame frame) {
    if (_knock.phase != KnockPhase.pending) {
      return;
    }
    final String? id = _asString(frame.data, 'knock_id');
    final KnockPhase? outcome = switch (_asString(frame.data, 'outcome')) {
      'rejected' => KnockPhase.rejected,
      'timeout' => KnockPhase.timedOut,
      'full' => KnockPhase.full,
      'withdrawn' => KnockPhase.withdrawn,
      'switched_off' => KnockPhase.switchedOff,
      _ => null,
    };
    if (id == null || id != _knock.knockId || outcome == null) {
      return;
    }
    _knock = KnockState(phase: outcome, knockId: id);
    _ban = outcome == KnockPhase.rejected
        ? CodeBan.tryParse(frame.data['ban'])
        : null;
    _dropConnection();
    _phase = RoomPhase.idle;
    final bool noSeat =
        outcome == KnockPhase.full || outcome == KnockPhase.switchedOff;
    _errorCode = noSeat ? 'ROOM_FULL' : null;
    _errorMessage = noSeat ? '' : null;
    notifyListeners();
  }

  /// Section 31 item 6: the host removed this phone from the lobby. The seat
  /// and its token are dead on the server, so both are forgotten here, no
  /// resume is ever tried, and [wasKicked] says why.
  void _onKicked(Frame frame) {
    _wasKicked = true;
    _dropPreState();
    _ban = CodeBan.tryParse(frame.data['ban']);
    _blocked = true;
    _cancelAutoReconnect();
    _cachedSeatToken = null;
    _writeCachedSeat(null);
    _hasDesynced = false;
    _resyncInFlight = false;
    _knock = const KnockState();
    _dropConnection();
    // Session memory never offers a resume for a seat the host removed.
    unawaited(SessionMemory.clearSeat());
    _phase = RoomPhase.closed;
    notifyListeners();
  }

  /// Closes and forgets the current connection without a `leave_room`.
  void _dropConnection() {
    _dropPreState();
    final RoomConnection? connection = _connection;
    _connection = null;
    unawaited(_frameSub?.cancel());
    _frameSub = null;
    if (connection != null) {
      unawaited(connection.close());
    }
  }

  /// Host side, section 31 item 3: a knock opened. Same `seq` rule as every
  /// state-changing push.
  void _reduceKnock(Frame frame, RoomSnapshot room) {
    final String? id = _asString(frame.data, 'knock_id');
    final String? name = _asString(frame.data, 'name');
    final int? expiresMs = _asInt(frame.data, 'expires_ms');
    final int? seqValue = frame.seq;
    if (id == null || name == null || expiresMs == null || seqValue == null) {
      return;
    }
    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }
    final List<Knock> knocks = <Knock>[
      for (final Knock k in room.knocks)
        if (k.id != id) k,
      Knock(id: id, name: name, expiresMs: expiresMs),
    ];
    _room = room.copyWith(knocks: knocks, seq: seqValue);
    notifyListeners();
  }

  /// Host side, section 31 item 4: a knock closed, whatever the outcome.
  void _reduceKnockClosed(Frame frame, RoomSnapshot room) {
    final String? id = _asString(frame.data, 'knock_id');
    final int? seqValue = frame.seq;
    if (id == null || seqValue == null) {
      return;
    }
    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }
    _room = room.copyWith(
      knocks: <Knock>[
        for (final Knock k in room.knocks)
          if (k.id != id) k,
      ],
      seq: seqValue,
    );
    notifyListeners();
  }

  /// The order of checks a state-changing push goes through, normative and
  /// unconditional: a resync already running or no room held yet both leave
  /// the frame changing nothing here, before any per-type rule ever runs.
  void _reduce(Frame frame) {
    // Section 35 ruling 7 (f): my own seat's retire for a kick or a leave is
    // final whatever came before it, a resync in flight included. Any other
    // retire of my seat (`absent`, met by a socket that came back) is reduced
    // like any seat's, gap check included, and the watching view goes on.
    if (frame.type == 'seat_retired' &&
        _cachedSeat != null &&
        _asInt(frame.data, 'seat') == _cachedSeat &&
        (frame.data['reason'] == 'kicked' || frame.data['reason'] == 'left')) {
      _reduceOwnRetire(frame);
      return;
    }
    if (_resyncInFlight) {
      return;
    }
    final RoomSnapshot? room = _room;
    if (room == null) {
      return;
    }
    switch (frame.type) {
      case 'room':
        _reduceRoom(frame, room);
      case 'player_joined':
        _reducePlayerJoined(frame, room);
      case 'player_left':
        _reducePlayerLeft(frame, room);
      case 'presence':
        _reducePresence(frame, room);
      case 'seat_seed':
        _reduceSeatSeed(frame, room);
      case 'game_started':
        _reduceGameStarted(frame, room);
      case 'rolled':
        _reduceRolled(frame, room);
      case 'moved':
        _reduceMoved(frame, room);
      case 'turn_passed':
        _reduceTurnPassed(frame, room);
      case 'turn':
        _reduceTurn(frame, room);
      case 'game_over':
        _reduceGameOver(frame, room);
      case 'seat_finished':
        _reduceSeatFinished(frame, room);
      case 'seat_retired':
        _reduceSeatRetired(frame, room);
      case 'sixes_granted':
        _reduceSixesGranted(frame, room);
      case 'release_declined':
        _reduceReleaseDeclined(frame, room);
      case 'knock':
        _reduceKnock(frame, room);
      case 'knock_closed':
        _reduceKnockClosed(frame, room);
    }
  }

  /// A server-initiated `room` push, `re` null: the request path already
  /// owns every `room` that answers `createRoom`, `joinRoom`, `resume` or
  /// `setPlayers`, including this controller's own resync, so a `room` here
  /// with `re` set is not this reducer's business -- `rematch`'s own reply
  /// is also `re` set, and [rematch] applies that one itself, directly,
  /// through the same [_applyRoomFrame] body this reducer falls through to
  /// below.
  void _reduceRoom(Frame frame, RoomSnapshot room) {
    if (frame.re != null) {
      return;
    }
    _applyRoomFrame(frame, room);
  }

  /// The seq-check-decode-apply body shared by [_reduceRoom] (an
  /// unsolicited `room` push) and [rematch] (the `room` that answers this
  /// controller's own `rematch` request): a seq gap resynchronises exactly
  /// as any other state-changing push does, a decode failure is treated the
  /// same as any other malformed frame -- caught, no state change, no
  /// rethrow -- and a frame that decodes cleanly replaces [room] and
  /// notifies once.
  void _applyRoomFrame(Frame frame, RoomSnapshot room) {
    final int? seqValue = frame.seq;
    if (seqValue == null) {
      return;
    }
    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }
    final RoomSnapshot decoded;
    try {
      decoded = RoomSnapshot.fromJson(frame.data);
    } on SnapshotFormatException {
      return;
    }
    _room = decoded;
    _landedPre = null;
    _recordLastFinished(decoded);
    _hasDesynced = false;
    notifyListeners();
  }

  /// `{seat, name}`. The server's own seats list holds only occupied seats
  /// (registry.dart:395-409) and broadcasts `player_joined` to every other
  /// client (connection.dart:355-360), so a join naming a seat this client
  /// has never seen is the ordinary case, not a contrived one: that seat is
  /// added, not ignored. It gets the defaults the server's snapshot builder
  /// gives a freshly joined lobby seat (snapshot.dart:52-56): `connected:
  /// true`, four `-1` tokens, no client seed, no seed origin. The frame
  /// itself carries nothing else. The list is kept sorted by seat
  /// index afterwards, matching the server's own sort on every join
  /// (registry.dart:408-409). When the seat is already present, this is the
  /// original rule's behaviour: its name becomes the pushed name and its
  /// connected becomes true.
  void _reducePlayerJoined(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final String? nameValue = _asString(frame.data, 'name');
    final int? seqValue = frame.seq;
    if (seatValue == null || nameValue == null || seqValue == null) {
      return;
    }
    // Section 34 item 1: a computer seat's join names its character.
    final int? botValue = _asInt(frame.data, 'bot');
    final int? bot = botValue != null && botValue >= 1 && botValue <= 6
        ? botValue
        : null;

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final int index = room.seats.indexWhere(
      (SeatState s) => s.seat == seatValue,
    );
    final List<SeatState> seats = List<SeatState>.from(room.seats);
    if (index == -1) {
      seats.add(
        SeatState(
          seat: seatValue,
          name: nameValue,
          connected: true,
          tokens: const <int>[-1, -1, -1, -1],
          clientSeed: null,
          seedOrigin: null,
          via: bot != null ? SeatVia.bot : SeatVia.unknown,
          bot: bot,
        ),
      );
      seats.sort((SeatState a, SeatState b) => a.seat.compareTo(b.seat));
    } else {
      seats[index] = seats[index].copyWith(name: nameValue, connected: true);
    }
    _room = room.copyWith(seats: seats, seq: seqValue);
    notifyListeners();
  }

  /// `{seat, host_seat}`: that seat is removed from `room.seats`.
  /// C-316 rule 1: sets `hostSeat` from `host_seat` when carried as an int in
  /// -1..3; absent leaves `hostSeat` as it was. Any other value is treated as
  /// a malformed frame (no state change). A seat absent from `room.seats` is
  /// ignored entirely, ahead of the gap check, matching the behaviour
  /// `presence` has always had. A leaving seat that was in `rematch.ready` is
  /// taken out of it (C-607); `by` is kept as it was. A rematch that does
  /// not list the leaver is passed through unchanged, since `copyWith` now
  /// treats an explicit null as a clear.
  void _reducePlayerLeft(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final int? seqValue = frame.seq;
    if (seatValue == null || seqValue == null) {
      return;
    }

    final int hostSeat;
    if (frame.data.containsKey('host_seat')) {
      final Object? rawHost = frame.data['host_seat'];
      if (rawHost is! int || rawHost < -1 || rawHost > 3) {
        return;
      }
      hostSeat = rawHost;
    } else {
      hostSeat = room.hostSeat;
    }

    final int index = room.seats.indexWhere(
      (SeatState s) => s.seat == seatValue,
    );
    if (index == -1) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final List<SeatState> seats = List<SeatState>.from(room.seats)
      ..removeAt(index);
    // The server drops a departing seat from `rematch.ready` and sends only
    // this frame (section 16.6), so the phone drops the mark too; `by` stays.
    final RematchState? rematch = room.rematch;
    final RematchState? nextRematch =
        rematch != null && rematch.ready.contains(seatValue)
        ? RematchState(
            by: rematch.by,
            ready: <int>[
              for (final int s in rematch.ready)
                if (s != seatValue) s,
            ],
          )
        : rematch;
    _room = room.copyWith(
      seats: seats,
      hostSeat: hostSeat,
      rematch: nextRematch,
      seq: seqValue,
    );
    notifyListeners();
  }

  /// `{seat, connected}`: that seat's connected is set. Absent seat: ignored
  /// entirely, ahead of the gap check.
  void _reducePresence(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final Object? connectedRaw = frame.data['connected'];
    final bool? connectedValue = connectedRaw is bool ? connectedRaw : null;
    final int? seqValue = frame.seq;
    if (seatValue == null || connectedValue == null || seqValue == null) {
      return;
    }
    final int index = room.seats.indexWhere(
      (SeatState s) => s.seat == seatValue,
    );
    if (index == -1) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final List<SeatState> seats = List<SeatState>.from(room.seats);
    seats[index] = seats[index].copyWith(connected: connectedValue);
    _room = room.copyWith(seats: seats, seq: seqValue);
    notifyListeners();
  }

  /// `{seat, client_seed, origin}`. `origin` is `"player"` or `"server"`;
  /// any other value is malformed. That seat's `clientSeed` and
  /// `seedOrigin` are set; nothing else changes. Absent seat: ignored
  /// entirely, ahead of the gap check.
  void _reduceSeatSeed(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final String? clientSeedValue = _asString(frame.data, 'client_seed');
    final String? originRaw = _asString(frame.data, 'origin');
    final int? seqValue = frame.seq;
    if (seatValue == null ||
        clientSeedValue == null ||
        originRaw == null ||
        seqValue == null) {
      return;
    }
    final SeedOrigin origin;
    switch (originRaw) {
      case 'player':
        origin = SeedOrigin.player;
      case 'server':
        origin = SeedOrigin.server;
      default:
        return;
    }

    final int index = room.seats.indexWhere(
      (SeatState s) => s.seat == seatValue,
    );
    if (index == -1) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final List<SeatState> seats = List<SeatState>.from(room.seats);
    seats[index] = seats[index].copyWith(
      clientSeed: clientSeedValue,
      seedOrigin: origin,
    );
    _room = room.copyWith(seats: seats, seq: seqValue);
    notifyListeners();
  }

  /// `{turn, game_id, client_seeds}`. Sets `state` to playing, `gameId`,
  /// `clientSeeds`, and the first `turn`. `deadlineMs` is the whole
  /// `turnSeconds` segment, not zero: docs/PROTOCOL.md section 14.2 requires
  /// `turn` to be non-null the moment a room is in PLAYING, and that alone
  /// is why this reducer cannot leave it unset or zeroed. The standalone
  /// `turn` frame the protocol also sends immediately after `game_started`
  /// (docs/PROTOCOL.md section 13.1) arrives microseconds later and
  /// overwrites this value with the server's own; that is the expected
  /// case, not a fallback this reducer is covering for. `k` is 0, section
  /// 6's "0 from game_started until the first roll". `turn` here is a
  /// room-level field, not an index into a seat, so the absent-seat rule
  /// does not apply to it: that rule only guards a frame field literally
  /// named `seat`.
  ///
  /// C-649: `rematch` is set to null here. PROTOCOL 16.4 and 16.6 make it
  /// non-null only in a rematch LOBBY, and the rematch LOBBY this frame
  /// leaves still carries `{by, ready}`; keeping it made the next end card
  /// read "my seat is ready" and hide Play again.
  void _reduceGameStarted(Frame frame, RoomSnapshot room) {
    final int? turnSeat = _asInt(frame.data, 'turn');
    final String? gameId = _asString(frame.data, 'game_id');
    final String? clientSeeds = _asString(frame.data, 'client_seeds');
    final int? seqValue = frame.seq;
    if (turnSeat == null ||
        gameId == null ||
        clientSeeds == null ||
        seqValue == null) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final TurnState turn = TurnState(
      seat: turnSeat,
      phase: TurnPhase.awaitRoll,
      deadlineMs: room.rules.turnSeconds * 1000,
      k: 0,
      value: null,
      legal: null,
      sixes: null,
      segmentMs: room.rules.turnSeconds * 1000,
    );
    _room = room.copyWith(
      state: RoomState.playing,
      gameId: gameId,
      clientSeeds: clientSeeds,
      turn: turn,
      rematch: null,
      seq: seqValue,
      recentRolls: const <(int k, int face)>[],
      recentRollSeats: const <int>[],
      placings: const <int>[],
      retired: const <int>[],
    );
    _clearLastFinished();
    _lastRetirement = null;
    _selfRetired = false;
    notifyListeners();
  }

  /// `{seat, deadline_ms}`. Sets `turn` to a fresh await-roll segment for
  /// `seat`, carrying `k` forward from the turn it replaces: section 6
  /// defines `turn.k` as the rolls made so far and a turn beginning makes no
  /// roll. Absent seat: ignored entirely, ahead of the gap check.
  ///
  /// A null `room.turn` is not a special case: `k` falls back to `0`, and
  /// that is applied the same as any other segment, not treated as an error
  /// and not ignored. A `turn` frame arriving with no prior turn on the room
  /// still begins a turn and still makes no roll, so section 6's "rolls made
  /// so far" is still zero. This holds whether the null came from a fresh
  /// snapshot that never carried a turn or from anywhere else `room.turn` can
  /// be null; this reducer does not distinguish those cases and neither does
  /// the rule.
  ///
  /// docs/PROTOCOL.md section 21.3 ruling 1 (C-362 A2): `phase`, present,
  /// is `await_roll` or `await_move`; any other value is malformed and the
  /// whole frame is ignored, the same as a missing `seat` or `deadline_ms`
  /// above. Absent `phase` is today's frame and behaves exactly as before:
  /// `await_roll`, no `value`/`legal`/`legal_by_face`. `queue` is read
  /// whenever present, on every phase; `value`, `legal` and `legal_by_face`
  /// are only ever read under `await_move`, because that is the only phase
  /// the wire carries them in.
  void _reduceTurn(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final int? deadlineMs = _asInt(frame.data, 'deadline_ms');
    final int? seqValue = frame.seq;
    if (seatValue == null || deadlineMs == null || seqValue == null) {
      return;
    }

    final TurnPhase phase;
    if (frame.data.containsKey('phase')) {
      final Object? phaseRaw = frame.data['phase'];
      if (phaseRaw == 'await_roll') {
        phase = TurnPhase.awaitRoll;
      } else if (phaseRaw == 'await_move') {
        phase = TurnPhase.awaitMove;
      } else {
        return;
      }
    } else {
      phase = TurnPhase.awaitRoll;
    }

    if (!room.seats.any((SeatState s) => s.seat == seatValue)) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final List<int> queue = _asIntList(frame.data, 'queue') ?? const <int>[];
    final int? value = phase == TurnPhase.awaitMove
        ? _asInt(frame.data, 'value')
        : null;
    final List<int>? legal = phase == TurnPhase.awaitMove
        ? _asIntList(frame.data, 'legal')
        : null;
    final List<FaceLegal>? legalByFace = phase == TurnPhase.awaitMove
        ? _asFaceLegalList(frame.data, 'legal_by_face')
        : null;

    final TurnState turn = TurnState(
      seat: seatValue,
      phase: phase,
      deadlineMs: deadlineMs,
      k: room.turn?.k ?? 0,
      value: value,
      legal: legal,
      sixes: null,
      queue: queue,
      legalByFace: legalByFace,
      segmentMs: _asInt(frame.data, 'segment_ms') ?? deadlineMs,
      release: frame.data['release'] == true,
      offer: frame.data['offer'] == true && phase == TurnPhase.awaitMove,
      banked: _asInt(frame.data, 'banked'),
      graceMs: _asInt(frame.data, 'grace_ms'),
      pre: phase == TurnPhase.awaitRoll ? frame.pre : null,
    );
    // Section 30 rule 5: the sixes banked for this seat are in the queue now,
    // so the count held on the seat goes back to 0.
    final List<SeatState> seats = room.seats
        .map(
          (SeatState s) =>
              s.seat == seatValue && s.banked != 0 ? s.copyWith(banked: 0) : s,
        )
        .toList(growable: false);
    _room = room.copyWith(turn: turn, seats: seats, seq: seqValue);
    notifyListeners();
  }

  /// `{seat, value, legal, deadline_ms, k}`. `reveal` ships on the wire and
  /// is not required and not stored: nothing in this client verifies the
  /// chain yet. An empty `legal` is legal input, stored as an empty list.
  /// Absent seat: ignored entirely, ahead of the gap check.
  ///
  /// docs/PROTOCOL.md section 21.3 ruling 3 (C-362 A3): `queue` and
  /// `legal_by_face` are read whenever present. When `queue` is present, the
  /// roll owes another roll -- `await_roll`, confirmed by the `turn` that
  /// follows -- exactly when `legal_by_face` is absent; otherwise a move is
  /// pending, `await_move`, same as today. When `queue` is absent this is a
  /// server with no roll queue and the phase is `await_move` exactly as
  /// before this order. `value` and `legal` are unconditional fields of this
  /// frame on every server, queue or not, and are stored exactly as they
  /// arrived regardless of which phase this resolves to. `recentRolls`
  /// records every rolled face, queue or not.
  void _reduceRolled(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final int? value = _asInt(frame.data, 'value');
    final List<int>? legal = _asIntList(frame.data, 'legal');
    final int? deadlineMs = _asInt(frame.data, 'deadline_ms');
    final int? k = _asInt(frame.data, 'k');
    final int? seqValue = frame.seq;
    if (seatValue == null ||
        value == null ||
        legal == null ||
        deadlineMs == null ||
        k == null ||
        seqValue == null) {
      return;
    }

    if (!room.seats.any((SeatState s) => s.seat == seatValue)) {
      return;
    }

    // Section 35 item 5: the `rolled` of a roll already shown from its `pre`.
    // It is marked before anything else, so the screen never plays it as a
    // new roll, whichever way it is applied below.
    final PreRoll? landed = _landedPre;
    _landedPre = null;
    final bool echo =
        landed != null && seatValue == landed.seat && k == landed.k;
    if (echo) {
      _preEchoes[frame] = true;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    if (echo) {
      _room = room.copyWith(seq: seqValue);
      if (!landed.sameRollAs(frame.data)) {
        // Ruling 7 (e): the `rolled` is the truth. One resync, no error.
        unawaited(resync());
      }
      return;
    }

    final TurnState turn = _rolledTurn(
      frame.data,
      room,
      seat: seatValue,
      value: value,
      legal: legal,
      deadlineMs: deadlineMs,
      k: k,
    );
    _room = room.copyWith(
      turn: turn,
      seq: seqValue,
      recentRolls: _appendRecentRoll(room.recentRolls, k, value),
      recentRollSeats: _appendRecentRollSeat(room.recentRollSeats, seatValue),
      lastSpentFace: null,
    );
    notifyListeners();
  }

  /// The turn a `rolled` with [data] leaves (section 21.3 ruling 3, section
  /// 28 rule 2, section 30 rule 2): what [_reduceRolled] applies for the
  /// server's frame and [_landPre] for a roll shown from its `pre`.
  TurnState _rolledTurn(
    Map<String, Object?> data,
    RoomSnapshot room, {
    required int seat,
    required int value,
    required List<int> legal,
    required int deadlineMs,
    required int k,
  }) {
    final List<int>? queueRaw = _asIntList(data, 'queue');
    final List<FaceLegal>? legalByFace = _asFaceLegalList(
      data,
      'legal_by_face',
    );
    // Section 28 rule 2: a roll that grants a yard release has no
    // `legal_by_face` and a non-empty `legal`, and the server is in
    // await_move with nothing to spend a face on. A lapse is the same frame
    // with `legal: []` and reads as any roll-queue roll with no legal move.
    final bool release = data['release'] == true;
    final bool releaseOwed = release && legal.isNotEmpty;
    final TurnPhase phase = releaseOwed
        ? TurnPhase.awaitMove
        : (queueRaw == null
              ? TurnPhase.awaitMove
              : (legalByFace != null
                    ? TurnPhase.awaitMove
                    : TurnPhase.awaitRoll));
    final List<int> queue = queueRaw ?? const <int>[];

    final bool movePending =
        phase == TurnPhase.awaitMove &&
        (legal.isNotEmpty ||
            (legalByFace?.any((FaceLegal f) => f.tokens.isNotEmpty) ?? false));
    final int? segmentMs =
        _asInt(data, 'segment_ms') ??
        (movePending ? deadlineMs : room.turn?.segmentMs);

    return TurnState(
      seat: seat,
      phase: phase,
      deadlineMs: deadlineMs,
      k: k,
      value: releaseOwed ? null : value,
      legal: legal,
      sixes: null,
      queue: queue,
      legalByFace: releaseOwed ? null : legalByFace,
      segmentMs: segmentMs,
      release: release,
      offer: releaseOwed && data['offer'] == true,
    );
  }

  /// `{seat, token, from, to, captured, extra_roll}`. The moving seat's
  /// token becomes `to`; `from` is not checked against the current value,
  /// because a disagreement there is a desync `seq` already catches. Each
  /// `captured` entry names a seat whose token becomes `-1`; an entry naming
  /// a seat absent from `room.seats` is skipped and the rest of the frame
  /// still applies, the one place this per-entry skip replaces the
  /// whole-frame ignore. The moving seat itself absent from `room.seats`
  /// still ignores the whole frame, ahead of the gap check. `turn`, when
  /// present, returns to await-roll with `value`, `legal` and `sixes`
  /// cleared and `seat`, `deadlineMs` and `k` kept; `extra_roll` is required
  /// so a malformed frame is caught and is otherwise not acted on.
  ///
  /// docs/PROTOCOL.md section 21.1, 21.3 (C-362 A4): `face`, the spent
  /// face, is optional and, when present, is kept on
  /// [RoomSnapshot.lastSpentFace] so the screen can read the face a move
  /// just spent. The intermediate `turn` this method builds is unchanged by
  /// it, and stays today's placeholder (`await_roll`, `value`/`legal`
  /// cleared): the real phase, `queue` and `legal_by_face` are what the
  /// `turn` push that follows carries (A2), per the 21.3 frame-order table.
  /// A `moved` with no `face` (no roll queue) leaves `lastSpentFace` exactly
  /// as it was.
  void _reduceMoved(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final int? token = _asInt(frame.data, 'token');
    final int? from = _asInt(frame.data, 'from');
    final int? to = _asInt(frame.data, 'to');
    final int? seqValue = frame.seq;
    final Object? extraRollRaw = frame.data['extra_roll'];
    final bool? extraRoll = extraRollRaw is bool ? extraRollRaw : null;
    if (seatValue == null ||
        token == null ||
        from == null ||
        to == null ||
        seqValue == null ||
        extraRoll == null) {
      return;
    }

    final Object? capturedRaw = frame.data['captured'];
    if (capturedRaw is! List) {
      return;
    }
    final List<(int, int)> captured = <(int, int)>[];
    for (final Object? entry in capturedRaw) {
      if (entry is! Map<String, Object?>) {
        return;
      }
      final int? capturedSeat = _asInt(entry, 'seat');
      final int? capturedToken = _asInt(entry, 'token');
      if (capturedSeat == null || capturedToken == null) {
        return;
      }
      captured.add((capturedSeat, capturedToken));
    }

    if (!room.seats.any((SeatState s) => s.seat == seatValue)) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final int? face = _asInt(frame.data, 'face');

    final List<SeatState> seats = List<SeatState>.from(room.seats);
    final int moverIndex = seats.indexWhere(
      (SeatState s) => s.seat == seatValue,
    );
    final List<int> moverTokens = List<int>.from(seats[moverIndex].tokens);
    moverTokens[token] = to;
    seats[moverIndex] = seats[moverIndex].copyWith(tokens: moverTokens);

    for (final (int capturedSeat, int capturedToken) in captured) {
      final int capturedIndex = seats.indexWhere(
        (SeatState s) => s.seat == capturedSeat,
      );
      if (capturedIndex == -1) {
        continue;
      }
      final List<int> tokens = List<int>.from(seats[capturedIndex].tokens);
      tokens[capturedToken] = -1;
      seats[capturedIndex] = seats[capturedIndex].copyWith(tokens: tokens);
    }

    final TurnState? currentTurn = room.turn;
    final TurnState? turn = currentTurn == null
        ? null
        : TurnState(
            seat: currentTurn.seat,
            phase: TurnPhase.awaitRoll,
            deadlineMs: currentTurn.deadlineMs,
            k: currentTurn.k,
            value: null,
            legal: null,
            sixes: null,
            segmentMs: currentTurn.segmentMs,
            settling: true,
          );

    final RoomSnapshot updated = turn == null
        ? room.copyWith(seats: seats, seq: seqValue)
        : room.copyWith(seats: seats, turn: turn, seq: seqValue);
    _room = face == null ? updated : updated.copyWith(lastSpentFace: face);
    notifyListeners();
  }

  /// `{seat, reason}`. `reason` is `"no_legal_move"` or `"three_sixes"`; any
  /// other value is malformed. Clears `turn` the same way `moved` does,
  /// without changing whose turn it is: the `turn` frame that follows does
  /// that. Absent seat: ignored entirely, ahead of the gap check.
  void _reduceTurnPassed(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final String? reasonValue = _asString(frame.data, 'reason');
    final int? seqValue = frame.seq;
    if (seatValue == null || reasonValue == null || seqValue == null) {
      return;
    }
    if (reasonValue != 'no_legal_move' &&
        reasonValue != 'three_sixes' &&
        reasonValue != 'released') {
      return;
    }

    if (!room.seats.any((SeatState s) => s.seat == seatValue)) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final TurnState? currentTurn = room.turn;
    final TurnState? turn = currentTurn == null
        ? null
        : TurnState(
            seat: currentTurn.seat,
            phase: TurnPhase.awaitRoll,
            deadlineMs: currentTurn.deadlineMs,
            k: currentTurn.k,
            value: null,
            legal: null,
            sixes: null,
            segmentMs: currentTurn.segmentMs,
            settling: true,
          );

    _room = turn == null
        ? room.copyWith(seq: seqValue)
        : room.copyWith(turn: turn, seq: seqValue);
    notifyListeners();
  }

  /// docs/PROTOCOL.md section 30 rule 3: `{seats, seq}`. The listed seats each
  /// hold one more banked six until their own `turn` moves it to the queue.
  /// The frame names no `seat` of its own; a missing `seats` list is treated
  /// as none granted, and the sequence is still checked.
  void _reduceSixesGranted(Frame frame, RoomSnapshot room) {
    final int? seqValue = frame.seq;
    if (seqValue == null) {
      return;
    }
    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }
    final List<int> granted = _asIntList(frame.data, 'seats') ?? const <int>[];
    final List<SeatState> seats = room.seats
        .map(
          (SeatState s) =>
              granted.contains(s.seat) ? s.copyWith(banked: s.banked + 1) : s,
        )
        .toList(growable: false);
    _room = room.copyWith(seats: seats, seq: seqValue);
    notifyListeners();
  }

  /// docs/PROTOCOL.md section 30 rule 4: `{seat, seq}`. The offer is over; the
  /// turn is cleared the way `turn_passed` clears it, ahead of the pass and
  /// the `turn` frame that follow.
  void _reduceReleaseDeclined(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final int? seqValue = frame.seq;
    if (seatValue == null || seqValue == null) {
      return;
    }
    if (!room.seats.any((SeatState s) => s.seat == seatValue)) {
      return;
    }
    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }
    final TurnState? currentTurn = room.turn;
    final TurnState? turn = currentTurn == null
        ? null
        : TurnState(
            seat: currentTurn.seat,
            phase: TurnPhase.awaitRoll,
            deadlineMs: currentTurn.deadlineMs,
            k: currentTurn.k,
            value: null,
            legal: null,
            sixes: null,
            segmentMs: currentTurn.segmentMs,
            settling: true,
          );
    _room = turn == null
        ? room.copyWith(seq: seqValue)
        : room.copyWith(turn: turn, seq: seqValue);
    notifyListeners();
  }

  /// `{winner, verify_url}`. Sets `state` to finished and `winner`.
  /// `verify_url` is required so a malformed frame is caught, and is
  /// stored on the snapshot for the finished-board verify control. If
  /// `turn` is present its `phase` becomes finished with `value`, `legal`
  /// and `sixes` cleared and `seat`, `deadlineMs` and `k` kept, per
  /// docs/PROTOCOL.md sections 14.1 and 14.2: a finished game's `turn` is
  /// not null. `winner` here is a room-level field, not an index into a
  /// seat, so the absent-seat rule does not apply to it: that rule only
  /// guards a frame field literally named `seat`.
  void _reduceGameOver(Frame frame, RoomSnapshot room) {
    final int? winnerValue = _asInt(frame.data, 'winner');
    final String? verifyUrl = _asString(frame.data, 'verify_url');
    final int? seqValue = frame.seq;
    if (winnerValue == null || verifyUrl == null || seqValue == null) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    // Section 28 rule 3: `placings` and `retired` are given together under
    // `2026-11` and absent under `2026-10`; absent reads as empty.
    final List<int> placings = _asIntList(frame.data, 'placings') ?? <int>[];
    final List<int> retired = _asIntList(frame.data, 'retired') ?? <int>[];

    final TurnState? currentTurn = room.turn;
    final TurnState? turn = currentTurn == null
        ? null
        : TurnState(
            seat: currentTurn.seat,
            phase: TurnPhase.finished,
            deadlineMs: currentTurn.deadlineMs,
            k: currentTurn.k,
            value: null,
            legal: null,
            sixes: null,
            segmentMs: currentTurn.segmentMs,
          );

    _room = turn == null
        ? room.copyWith(
            state: RoomState.finished,
            winner: winnerValue,
            verifyUrl: verifyUrl,
            placings: placings,
            retired: retired,
            seq: seqValue,
          )
        : room.copyWith(
            state: RoomState.finished,
            winner: winnerValue,
            verifyUrl: verifyUrl,
            turn: turn,
            placings: placings,
            retired: retired,
            seq: seqValue,
          );
    _recordLastFinished(_room!);
    notifyListeners();
  }

  /// `{seat, place}`, docs/PROTOCOL.md section 28 rule 3: a seat brought its
  /// fourth token home and the game goes on. The seat joins [placings]. It
  /// stays in `seats`, and the `turn` frame that follows names the next
  /// playing seat. A `place` other than the number of finished seats plus
  /// one means this client missed or invented a finish, so it resynchronises
  /// like a gap does. Absent seat: ignored entirely, ahead of the gap check.
  void _reduceSeatFinished(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final int? place = _asInt(frame.data, 'place');
    final int? seqValue = frame.seq;
    if (seatValue == null || place == null || seqValue == null) {
      return;
    }

    if (!room.seats.any((SeatState s) => s.seat == seatValue)) {
      return;
    }

    if (seqValue != room.seq + 1 || place != room.placings.length + 1) {
      _beginResync(room);
      return;
    }

    _room = room.copyWith(
      placings: <int>[...room.placings, seatValue],
      seq: seqValue,
    );
    notifyListeners();
  }

  /// `{seat, reason, host_seat}`, docs/PROTOCOL.md section 28 rule 4: a
  /// playing seat left, was absent too long or was kicked. The seat joins
  /// [retired] and stays in `seats`; `host_seat` is the value after the
  /// change, -1 when nobody is left to host. Nothing else changes here: the
  /// `turn` or `game_over` that follows, when there is one, does the rest.
  /// `reason` is kept as the server sent it for [lastRetirement]. Absent
  /// seat: ignored entirely, ahead of the gap check.
  void _reduceSeatRetired(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final String? reason = _asString(frame.data, 'reason');
    final int? hostSeat = _asInt(frame.data, 'host_seat');
    final int? seqValue = frame.seq;
    if (seatValue == null ||
        reason == null ||
        hostSeat == null ||
        seqValue == null ||
        hostSeat < -1 ||
        hostSeat > 3) {
      return;
    }

    if (!room.seats.any((SeatState s) => s.seat == seatValue)) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    _room = room.copyWith(
      retired: <int>[...room.retired, seatValue],
      hostSeat: hostSeat,
      seq: seqValue,
    );
    _lastRetirement = (seat: seatValue, reason: reason);
    notifyListeners();
  }

  /// docs/PROTOCOL.md section 33 item 8 and section 35 ruling 7 (f): a
  /// `seat_retired` naming my own seat. The departing socket is not sent the
  /// frames between its last one and this, so a gap here is expected and is
  /// not a desync: the retire is applied as it stands, nothing resyncs, and
  /// no gap after it starts a `resume` (the `kicked` that follows a host's
  /// removal ends the connection).
  void _reduceOwnRetire(Frame frame) {
    final RoomSnapshot? room = _room;
    final int? seatValue = _asInt(frame.data, 'seat');
    final String? reason = _asString(frame.data, 'reason');
    final int? hostSeat = _asInt(frame.data, 'host_seat');
    final int? seqValue = frame.seq;
    if (room == null ||
        seatValue == null ||
        reason == null ||
        hostSeat == null ||
        seqValue == null ||
        hostSeat < -1 ||
        hostSeat > 3) {
      return;
    }
    _selfRetired = true;
    _dropPreState();
    _room = room.copyWith(
      retired: room.retired.contains(seatValue)
          ? room.retired
          : <int>[...room.retired, seatValue],
      hostSeat: hostSeat,
      seq: seqValue > room.seq ? seqValue : room.seq,
    );
    _lastRetirement = (seat: seatValue, reason: reason);
    notifyListeners();
  }

  /// A gap on any state-changing push resynchronises this controller on its
  /// own open socket rather than leaving it to the caller. `hasDesynced` is
  /// set and a listener notified first, unconditionally, so a screen can
  /// show the round trip. `resume` is sent only when there is something to
  /// ask with: a live connection, [RoomPhase.connected], and a cached seat
  /// token. This is `resume` on the connection already open, never
  /// `reconnect()` -- `reconnect()` opens a second transport, and the
  /// server's own `attach` only displaces a *different* socket resuming the
  /// same seat (wire_server.dart:415), so a second transport is both slower
  /// and the one path that can get the still-working socket displaced.
  /// Single-flight matters for the same reason: `recordJoinOrResume` allows
  /// 20 join-or-resume messages per IP per minute (rate_limit.dart:15-16,
  /// 75-79), and a burst of missed frames each firing its own `resume` would
  /// spend that budget in seconds.
  ///
  /// This `resume` is one the player never asked for and cannot see, so its
  /// failure must not be treated the way a request the player made is
  /// treated. Only a `ProtocolErrorException` -- the server answering with
  /// an `error` frame, naming a code -- is routed through
  /// `_failFromRequest`: that is the server deliberately refusing this seat
  /// on this socket, and there is nothing to gain by sitting in `connected`
  /// and asking again on the next gapped frame. Every other error --
  /// `ConnectionClosedException`, `RequestTimeoutException`,
  /// `FrameFormatException`, anything else -- leaves the phase, the error
  /// fields and the connection untouched. A `resume` that merely times out
  /// on a socket that is still perfectly alive must not be the thing that
  /// closes that socket; the ordinary lifecycle (`connection.done` in
  /// `_openAndAttach`) already sets `RoomPhase.closed` if and when the
  /// transport actually ends, and beating it there with a `failed` this
  /// resync invented would both lie about what happened and duplicate work
  /// the lifecycle already does. `_resyncInFlight` is still cleared on every
  /// path, unconditionally: `_reduce` returns early while it is set, so a
  /// failure that left it set would stop this controller reducing any frame
  /// at all, forever. `hasDesynced` is left `true` on the non-fatal paths on
  /// purpose -- the desync that started this resync has not been resolved,
  /// only the attempt to resolve it has failed, and the next gapped frame
  /// will try again.
  void _beginResync(RoomSnapshot room) {
    if (_seatTakenOver || _selfRetired) {
      // C-637 D3: a late gapped frame must not raise the desync state again.
      // Section 35 ruling 7 (f): nor one after this seat's own retire, which
      // is final; its token is dead and no `resume` is sent for it.
      return;
    }
    _hasDesynced = true;
    notifyListeners();

    final RoomConnection? connection = _connection;
    final String? token = _cachedSeatToken;
    if (connection == null || _phase != RoomPhase.connected || token == null) {
      return;
    }

    _resyncInFlight = true;
    connection
        .resume(code: room.code, seatToken: token)
        .then(
          (RoomSnapshot snapshot) {
            if (_disposed || _seatTakenOver) {
              // C-637 D3: a reply that lands after the takeover re-bases
              // nothing.
              return;
            }
            _resyncInFlight = false;
            _room = snapshot;
            _landedPre = null;
            _recordLastFinished(snapshot);
            _hasDesynced = false;
            notifyListeners();
          },
          onError: (Object error) {
            if (_disposed || _seatTakenOver) {
              return;
            }
            _resyncInFlight = false;
            if (error is ProtocolErrorException) {
              _failFromRequest(error);
              return;
            }
            // Every other error -- a timeout on a socket that is still
            // alive, the transport ending on its own, a malformed reply --
            // is not a verdict from the server and is not this method's to
            // act on. Leave the phase, the error fields and the connection
            // exactly as they are; notify only because _resyncInFlight
            // changing is itself an observable state a screen may render on.
            notifyListeners();
          },
        );
  }

  /// E1: what [roll] and [move] do with a caught error, ahead of everything
  /// else. A rejected intention (_rejectedIntentionCodes) changes nothing:
  /// [phase] stays [RoomPhase.connected], the connection this request ran on
  /// stays the current one, and the frames already arriving on it are what
  /// re-bases this controller, not this method. E2: every other failure --
  /// including a [ProtocolErrorException] carrying any other code -- falls
  /// through to [_failFromInRoomRequest] exactly as it did on `449fc30`.
  void _failFromRollOrMove(Object error) {
    if (error is ProtocolErrorException &&
        _rejectedIntentionCodes.contains(error.code)) {
      return;
    }
    _failFromInRoomRequest(error);
  }

  /// S1: what [startGame] does with a caught error, ahead of everything
  /// else. A rejected code ([_startGameRejectedCodes]) changes nothing:
  /// [phase] stays [RoomPhase.connected], the connection this request ran on
  /// stays the current one, and the frames already arriving on it -- the
  /// truth this race left behind -- are what this controller reduces, not
  /// this method. S2: every other failure -- including a
  /// [ProtocolErrorException] carrying any other code -- falls through to
  /// [_failFromInRoomRequest] exactly as it did on `24e9d8b`.
  void _failFromStartGame(Object error) {
    if (error is ProtocolErrorException &&
        _startGameRejectedCodes.contains(error.code)) {
      return;
    }
    _failFromInRoomRequest(error);
  }

  /// What [setPlayers] does with a caught error, ahead of everything else,
  /// mirroring [_failFromStartGame]. A rejected code
  /// ([_setPlayersRejectedCodes]) changes nothing: [phase] stays
  /// [RoomPhase.connected], the connection this request ran on stays the
  /// current one, and the `room` broadcast the race already produced is what
  /// this controller reduces, not this method. Every other failure --
  /// including a [ProtocolErrorException] carrying any other code -- falls
  /// through to [_failFromInRoomRequest].
  void _failFromSetPlayers(Object error) {
    if (error is ProtocolErrorException &&
        _setPlayersRejectedCodes.contains(error.code)) {
      return;
    }
    _failFromInRoomRequest(error);
  }

  /// G1: what [setPlayers], [startGame] and, past E1, [roll] and [move] do
  /// with a failure. [_failFromRequest] first, exactly as every one of them
  /// did before G existed; then, if that landed this controller in
  /// [RoomPhase.failed] with a retryable code and it is eligible (C4) with no
  /// sequence already running, starts one exactly as C5 does: a single timer
  /// for `autoReconnectDelays[0]`, then C7 as written. G2: the
  /// `_sequenceRunning` guard here is the same one C5's `connection.done`
  /// handler reads, so whichever of the two sees a dead socket first is the
  /// one that starts the sequence, and the other finds it already running.
  void _failFromInRoomRequest(Object error) {
    _failFromRequest(error);
    if (_disposed || _phase != RoomPhase.failed) {
      return;
    }
    if (!_retryableErrorCodes.contains(_errorCode)) {
      return;
    }
    if (!_eligible || _sequenceRunning) {
      return;
    }
    _startSequence(immediate: false);
  }

  /// Maps an error caught from a request made on an already-open connection
  /// to one of the codes in rule 2, closes and drops that connection so a
  /// later retry does not leak it, and lands in [RoomPhase.failed].
  void _failFromRequest(Object error) {
    final String code;
    final String message;
    if (error is ProtocolErrorException) {
      code = error.code;
      message = error.message;
      if (code == 'CODE_BANNED') {
        _ban = CodeBan.tryParse(error.frame.data['ban']);
      }
    } else if (error is RequestTimeoutException) {
      code = 'timeout';
      message = '';
    } else if (error is ConnectionClosedException) {
      code = 'closed';
      message = '';
    } else if (error is FrameFormatException) {
      code = 'protocol';
      message = '';
    } else {
      // Not one of the five rows rule 2 pins. RoomConnection's request
      // methods are documented to throw only the four types handled above;
      // this branch exists solely so rule 1 ("no method on this class ever
      // throws") holds even if that contract is ever broken elsewhere.
      // 'protocol' is the closest existing code and is reused rather than
      // inventing a sixth one.
      code = 'protocol';
      message = '';
    }
    _fail(code, message);
  }

  void _fail(String code, String message) {
    if (_disposed) {
      return;
    }
    _dropPreState();
    final RoomConnection? connection = _connection;
    _connection = null;
    unawaited(_frameSub?.cancel());
    _frameSub = null;
    if (connection != null) {
      unawaited(connection.close());
    }
    _phase = RoomPhase.failed;
    _errorCode = code;
    _errorMessage = message;
    notifyListeners();
  }
}

// --- delta field parsing -----------------------------------------------
//
// Every one of these reads a single field and returns null both when it is
// missing and when its runtime type does not match, so a caller cannot tell
// "absent" from "wrong type" apart -- docs/PROTOCOL.md's frozen declaration
// treats both as the same malformed frame. None of these throws.

int? _asInt(Map<String, Object?> data, String key) {
  final Object? value = data[key];
  return value is int ? value : null;
}

String? _asString(Map<String, Object?> data, String key) {
  final Object? value = data[key];
  return value is String ? value : null;
}

List<int>? _asIntList(Map<String, Object?> data, String key) {
  final Object? value = data[key];
  if (value is! List) {
    return null;
  }
  final List<int> result = <int>[];
  for (final Object? element in value) {
    if (element is! int) {
      return null;
    }
    result.add(element);
  }
  return result;
}

/// docs/PROTOCOL.md section 21.1, `legal_by_face`: `[{"face": int, "tokens":
/// [int]}]`. Missing or wrong-shaped, at any level, reads as null the same
/// as every other helper in this section -- a caller cannot tell "absent"
/// from "wrong type" apart here either.
List<FaceLegal>? _asFaceLegalList(Map<String, Object?> data, String key) {
  final Object? value = data[key];
  if (value is! List) {
    return null;
  }
  final List<FaceLegal> result = <FaceLegal>[];
  for (final Object? element in value) {
    if (element is! Map<String, Object?>) {
      return null;
    }
    final int? face = _asInt(element, 'face');
    final List<int>? tokens = _asIntList(element, 'tokens');
    if (face == null || tokens == null) {
      return null;
    }
    result.add(FaceLegal(face: face, tokens: tokens));
  }
  return result;
}

/// Last three `(k, face)` pairs from contiguous `rolled` frames. Oldest
/// drops off the front when a fourth arrives.
List<(int k, int face)> _appendRecentRoll(
  List<(int k, int face)> current,
  int k,
  int face,
) {
  final List<(int k, int face)> next = List<(int k, int face)>.from(current)
    ..add((k, face));
  const int limit = 3;
  return next.length <= limit ? next : next.sublist(next.length - limit);
}

/// C-601: the seat that rolled, kept beside [_appendRecentRoll] with the
/// same three-entry limit so the two lists stay the same length.
List<int> _appendRecentRollSeat(List<int> current, int seat) {
  final List<int> next = List<int>.from(current)..add(seat);
  const int limit = 3;
  return next.length <= limit ? next : next.sublist(next.length - limit);
}

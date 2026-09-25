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

import 'package:flutter/foundation.dart';

import 'connection.dart';
import 'frame.dart';
import 'snapshot.dart';
import 'transport.dart';

/// The lifecycle a [RoomController] moves through. There is no path back to
/// [idle]: once a room has been created or joined, the controller has a
/// history worth keeping (the room, the seat, the seat token), and every
/// later state carries that history forward instead of discarding it.
enum RoomPhase { idle, connecting, connected, closed, failed }

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

/// Holds the one [RoomConnection] a lobby screen is driving at any moment,
/// re-creates it across a drop, and exposes the whole thing as a
/// [ChangeNotifier] with no method that ever throws.
class RoomController extends ChangeNotifier {
  RoomController({
    required this.serverUrl,
    required TransportConnector connect,
    List<Duration> autoReconnectDelays = const <Duration>[],
  }) : _connect = connect, // ignore: prefer_initializing_formals
       autoReconnectDelays = List<Duration>.unmodifiable(autoReconnectDelays);

  /// The address every connection this controller opens is opened against.
  final Uri serverUrl;

  final TransportConnector _connect;

  /// The bounded backoff schedule an automatic sequence (C5, C10) follows.
  /// An unmodifiable copy of whatever was passed in. Empty means automatic
  /// reconnection is off: no timer is ever created and this controller
  /// behaves exactly as it did before this field existed.
  final List<Duration> autoReconnectDelays;

  RoomPhase _phase = RoomPhase.idle;
  RoomSnapshot? _room;

  /// The last non-null seat and seat token this controller has ever seen,
  /// from any connection. Rule 5: never cleared except by [dispose], because
  /// a seat token is the capability to reclaim a seat and a `reconnect()`
  /// opens a brand new [RoomConnection] that starts with a null seat token
  /// of its own.
  int? _cachedSeat;
  String? _cachedSeatToken;

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

  bool _disposed = false;

  /// Set by an unsolicited `error` frame (C3) or a reconnect attempt --
  /// automatic or manual -- failing with a non-retryable code (C3). Cleared
  /// only when [phase] next reaches [RoomPhase.connected]. Gates [_eligible]
  /// only; it has no getter of its own.
  bool _blocked = false;

  /// True once [leave] has been called, ever. One-way, like [_disposed].
  bool _leftCalled = false;

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
  int? get seat => _cachedSeat;
  String? get seatToken => _cachedSeatToken;
  bool get hasDesynced => _hasDesynced;
  String? get errorCode => _errorCode;
  String? get errorMessage => _errorMessage;

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
      !_blocked;

  /// Every inbound frame, in arrival order, forwarded from whichever
  /// [RoomConnection] is current. A broadcast controller of its own, not the
  /// connection's stream handed straight out, precisely so a listener
  /// attached before a drop keeps receiving frames from the connection
  /// [reconnect] opens afterwards.
  Stream<Frame> get frames => _framesController.stream;

  Future<void> createRoom({required String name, required int players}) {
    return _openFresh(
      gate: _phase == RoomPhase.idle || _phase == RoomPhase.failed,
      request: (RoomConnection connection) =>
          connection.createRoom(name: name, players: players),
    );
  }

  Future<void> joinRoom({required String code, required String name}) {
    return _openFresh(
      gate: _phase == RoomPhase.idle || _phase == RoomPhase.failed,
      request: (RoomConnection connection) =>
          connection.joinRoom(code: code, name: name),
    );
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
      // R4: the snapshot carries no "your seat" field and the server sends
      // no seat_assigned on a resume (docs/PROTOCOL.md section 6), so the
      // seat travels with the token this call was given, not with whatever
      // _syncSeatCache() would otherwise read off the connection.
      _room = snapshot;
      _cachedSeat = seat;
      _cachedSeatToken = seatToken;
      _phase = RoomPhase.connected;
      _blocked = false;
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
    required Future<RoomSnapshot> Function(RoomConnection connection) request,
  }) async {
    if (_disposed || !gate) {
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
      return;
    }

    try {
      final RoomSnapshot snapshot = await request(connection);
      if (_disposed) {
        return;
      }
      _room = snapshot;
      _phase = RoomPhase.connected;
      _blocked = false;
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
        !(_phase == RoomPhase.closed || _phase == RoomPhase.failed) ||
        room == null ||
        token == null) {
      return;
    }
    _cancelAutoReconnect();
    await _attemptReconnect(automatic: false, room: room, token: token);
  }

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
      _phase = RoomPhase.connected;
      _blocked = false;
      _hasDesynced = false;
      _errorCode = null;
      _errorMessage = null;
      _syncSeatCache();
      notifyListeners();
      if (automatic) {
        // A later drop starts a fresh sequence from autoReconnectDelays[0].
        _cancelAutoReconnect();
      }
    } catch (error) {
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
  /// _nextDelayIndex]` and advances the index past it.
  void _scheduleNextAttempt() {
    final Duration delay = autoReconnectDelays[_nextDelayIndex];
    _nextDelayIndex++;
    _reconnectTimer = Timer(delay, _onReconnectTimerFired);
  }

  /// C7: what a pending timer's firing does.
  void _onReconnectTimerFired() {
    _reconnectTimer = null;
    if (!_eligible ||
        !(_phase == RoomPhase.closed || _phase == RoomPhase.failed)) {
      _sequenceRunning = false;
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
  void _cancelAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sequenceRunning = false;
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
      _failFromInRoomRequest(error);
    }
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
      _failFromInRoomRequest(error);
    }
  }

  /// Forwards to the connection when [phase] is [RoomPhase.connected] and is
  /// a silent no-op otherwise. The reply is a plain frame, not a snapshot; it
  /// is not parsed as one and changes nothing here. The `rolled` frame that
  /// follows reaches [frames] like every other frame and is what actually
  /// moves the turn forward.
  Future<void> roll() async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      await connection.roll();
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
  Future<void> move(int token) async {
    final RoomConnection? connection = _connection;
    if (_disposed || _phase != RoomPhase.connected || connection == null) {
      return;
    }
    try {
      await connection.move(token);
    } catch (error) {
      _failFromRollOrMove(error);
    }
  }

  /// Sends `leave_room` best-effort (its outcome, success or failure, is
  /// never surfaced as an error: this controller is on its way out either
  /// way), closes the connection, and sets [phase] to [RoomPhase.closed].
  /// Never throws even if the socket had already died.
  Future<void> leave() async {
    if (_disposed) {
      return;
    }
    _leftCalled = true;
    _cancelAutoReconnect();
    final RoomConnection? connection = _connection;
    _connection = null;
    unawaited(_frameSub?.cancel());
    _frameSub = null;
    if (connection != null) {
      try {
        await connection.leaveRoom();
      } catch (_) {
        // Best-effort. The socket may already be gone; that is not this
        // method's problem to report.
      }
      // _connection was already nulled above, so dispose() -- if it ran
      // while leaveRoom() was in flight -- found nothing to close. This
      // connection is this method's alone to close either way, disposed or
      // not: closing it touches no ChangeNotifier state and is not the
      // mutation the disposed guard below exists to skip.
      unawaited(connection.close());
    }
    if (_disposed) {
      return;
    }
    _phase = RoomPhase.closed;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAutoReconnect();
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
    return true;
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
      _cachedSeat = liveSeat;
    }
    final String? liveToken = connection.seatToken;
    if (liveToken != null) {
      _cachedSeatToken = liveToken;
    }
  }

  /// Every frame the current connection produces, including every one this
  /// controller's reducer ignores. Forwarded to [frames] unconditionally and
  /// first, then handed to the reducer when it is one of the types
  /// docs/PROTOCOL.md section 5 marks as carrying `seq`.
  void _handleFrame(Frame frame) {
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
    }
    if (_stateChangingTypes.contains(frame.type)) {
      _reduce(frame);
    }
  }

  /// The order of checks a state-changing push goes through, normative and
  /// unconditional: a resync already running or no room held yet both leave
  /// the frame changing nothing here, before any per-type rule ever runs.
  void _reduce(Frame frame) {
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
    }
  }

  /// A server-initiated `room` push, `re` null: the request path already
  /// owns every `room` that answers `createRoom`, `joinRoom`, `resume` or
  /// `setPlayers`, including this controller's own resync, so a `room` here
  /// with `re` set is not this reducer's business. A decode failure is
  /// treated the same as any other malformed frame: caught, no state
  /// change, no rethrow.
  void _reduceRoom(Frame frame, RoomSnapshot room) {
    final int? seqValue = frame.seq;
    if (seqValue == null) {
      return;
    }
    if (frame.re != null) {
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
        ),
      );
      seats.sort((SeatState a, SeatState b) => a.seat.compareTo(b.seat));
    } else {
      seats[index] = seats[index].copyWith(name: nameValue, connected: true);
    }
    _room = room.copyWith(seats: seats, seq: seqValue);
    notifyListeners();
  }

  /// `{seat}`: that seat is removed from `room.seats`. A seat absent from
  /// `room.seats` is ignored entirely, ahead of the gap check, matching the
  /// behaviour `presence` has always had.
  void _reducePlayerLeft(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final int? seqValue = frame.seq;
    if (seatValue == null || seqValue == null) {
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

    final List<SeatState> seats = List<SeatState>.from(room.seats)
      ..removeAt(index);
    _room = room.copyWith(seats: seats, seq: seqValue);
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
    );
    _room = room.copyWith(
      state: RoomState.playing,
      gameId: gameId,
      clientSeeds: clientSeeds,
      turn: turn,
      seq: seqValue,
      recentRolls: const <(int k, int face)>[],
    );
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
  void _reduceTurn(Frame frame, RoomSnapshot room) {
    final int? seatValue = _asInt(frame.data, 'seat');
    final int? deadlineMs = _asInt(frame.data, 'deadline_ms');
    final int? seqValue = frame.seq;
    if (seatValue == null || deadlineMs == null || seqValue == null) {
      return;
    }

    if (!room.seats.any((SeatState s) => s.seat == seatValue)) {
      return;
    }

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final TurnState turn = TurnState(
      seat: seatValue,
      phase: TurnPhase.awaitRoll,
      deadlineMs: deadlineMs,
      k: room.turn?.k ?? 0,
      value: null,
      legal: null,
      sixes: null,
    );
    _room = room.copyWith(turn: turn, seq: seqValue);
    notifyListeners();
  }

  /// `{seat, value, legal, deadline_ms, k}`. `reveal` ships on the wire and
  /// is not required and not stored: nothing in this client verifies the
  /// chain yet. An empty `legal` is legal input, stored as an empty list.
  /// Absent seat: ignored entirely, ahead of the gap check.
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

    if (seqValue != room.seq + 1) {
      _beginResync(room);
      return;
    }

    final TurnState turn = TurnState(
      seat: seatValue,
      phase: TurnPhase.awaitMove,
      deadlineMs: deadlineMs,
      k: k,
      value: value,
      legal: legal,
      sixes: null,
    );
    _room = room.copyWith(
      turn: turn,
      seq: seqValue,
      recentRolls: _appendRecentRoll(room.recentRolls, k, value),
    );
    notifyListeners();
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
          );

    _room = turn == null
        ? room.copyWith(seats: seats, seq: seqValue)
        : room.copyWith(seats: seats, turn: turn, seq: seqValue);
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
    if (reasonValue != 'no_legal_move' && reasonValue != 'three_sixes') {
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
          );

    _room = turn == null
        ? room.copyWith(
            state: RoomState.finished,
            winner: winnerValue,
            verifyUrl: verifyUrl,
            seq: seqValue,
          )
        : room.copyWith(
            state: RoomState.finished,
            winner: winnerValue,
            verifyUrl: verifyUrl,
            turn: turn,
            seq: seqValue,
          );
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
            if (_disposed) {
              return;
            }
            _resyncInFlight = false;
            _room = snapshot;
            _hasDesynced = false;
            notifyListeners();
          },
          onError: (Object error) {
            if (_disposed) {
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

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

/// Holds the one [RoomConnection] a lobby screen is driving at any moment,
/// re-creates it across a drop, and exposes the whole thing as a
/// [ChangeNotifier] with no method that ever throws.
class RoomController extends ChangeNotifier {
  RoomController({required this.serverUrl, required TransportConnector connect})
    : _connect = connect; // ignore: prefer_initializing_formals

  /// The address every connection this controller opens is opened against.
  final Uri serverUrl;

  final TransportConnector _connect;

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

  RoomPhase get phase => _phase;
  RoomSnapshot? get room => _room;
  int? get seat => _cachedSeat;
  String? get seatToken => _cachedSeatToken;
  bool get hasDesynced => _hasDesynced;
  String? get errorCode => _errorCode;
  String? get errorMessage => _errorMessage;

  bool get isHost =>
      _room != null && _cachedSeat != null && _room!.hostSeat == _cachedSeat;

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
  Future<void> reconnect() async {
    final RoomSnapshot? room = _room;
    final String? token = _cachedSeatToken;
    if (_disposed ||
        !(_phase == RoomPhase.closed || _phase == RoomPhase.failed) ||
        room == null ||
        token == null) {
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
      final RoomSnapshot snapshot = await connection.resume(
        code: room.code,
        seatToken: token,
      );
      if (_disposed) {
        return;
      }
      _room = snapshot;
      _phase = RoomPhase.connected;
      _hasDesynced = false;
      _errorCode = null;
      _errorMessage = null;
      _syncSeatCache();
      notifyListeners();
    } catch (error) {
      _failFromRequest(error);
    }
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
      _failFromRequest(error);
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
      _failFromRequest(error);
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
      unawaited(connection.close());
    }
    _phase = RoomPhase.closed;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
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
  /// `turnSeconds` segment, not zero: docs/PROTOCOL.md section 13.1 says the
  /// first seat's turn begins here and section 6 says a segment starts at
  /// the full duration, and section 13.1 also says the standalone `turn`
  /// frame the protocol otherwise sends next is not yet implemented on the
  /// server, so this is the one frame that must already leave a board
  /// renderable. `k` is 0, section 6's "0 from game_started until the first
  /// roll". The named seat absent from `room.seats` ignores the frame
  /// entirely, ahead of the gap check.
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

    if (!room.seats.any((SeatState s) => s.seat == turnSeat)) {
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
    );
    notifyListeners();
  }

  /// `{seat, deadline_ms}`. Sets `turn` to a fresh await-roll segment for
  /// `seat`, carrying `k` forward from the turn it replaces: section 6
  /// defines `turn.k` as the rolls made so far and a turn beginning makes no
  /// roll. Absent seat: ignored entirely, ahead of the gap check.
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
    _room = room.copyWith(turn: turn, seq: seqValue);
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
  /// `verify_url` is required so a malformed frame is caught and is
  /// otherwise not stored; nothing renders it yet. If `turn` is present its
  /// `phase` becomes finished with `value`, `legal` and `sixes` cleared and
  /// `seat`, `deadlineMs` and `k` kept, per docs/PROTOCOL.md sections 14.1
  /// and 14.2: a finished game's `turn` is not null. The named winner
  /// absent from `room.seats` ignores the frame entirely, ahead of the gap
  /// check.
  void _reduceGameOver(Frame frame, RoomSnapshot room) {
    final int? winnerValue = _asInt(frame.data, 'winner');
    final String? verifyUrl = _asString(frame.data, 'verify_url');
    final int? seqValue = frame.seq;
    if (winnerValue == null || verifyUrl == null || seqValue == null) {
      return;
    }

    if (!room.seats.any((SeatState s) => s.seat == winnerValue)) {
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
            seq: seqValue,
          )
        : room.copyWith(
            state: RoomState.finished,
            winner: winnerValue,
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
            _failFromRequest(error);
          },
        );
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

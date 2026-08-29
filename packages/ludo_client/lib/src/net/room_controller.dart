// The seam between the protocol engine (RoomConnection) and a screen.
//
// RoomConnection speaks futures and raw frames and is proved against a fake
// transport with no server. A Flutter screen needs something it can hold in
// a build method: a listenable object with a current state and no throwing
// methods, because these methods are wired straight to button handlers and
// an exception out of a button handler is a crash on a player's phone.
//
// This is a lobby controller. It opens and re-opens a RoomConnection, caches
// the seat and seat token a reconnect needs, applies the three lobby deltas
// to the snapshot it holds, and detects when it has missed a delta it cannot
// place. It does not reduce a single game delta: `rolled`, `moved`, `turn`,
// `turn_passed`, `game_started`, `game_over` and `seat_seed` reach `frames`
// exactly as they arrived and change nothing here. That reducer is a
// different order's job, against a screen that actually renders a board.

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
  /// [frames] like every other game delta and are this controller's business
  /// not to touch.
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
  /// first, then handed to the lobby-delta reducer.
  void _handleFrame(Frame frame) {
    if (!_framesController.isClosed) {
      _framesController.add(frame);
    }
    _syncSeatCache();
    switch (frame.type) {
      case 'player_joined':
        _applyPlayerJoined(frame);
      case 'player_left':
        _applyPlayerLeft(frame);
      case 'presence':
        _applyPresence(frame);
      default:
        // Every game delta, and anything this controller does not
        // recognise, is out of scope: it reaches `frames` above and changes
        // nothing else.
        break;
    }
  }

  /// `{seat, name}`, rule 6: that seat's name becomes the pushed name and its
  /// connected becomes true.
  void _applyPlayerJoined(Frame frame) {
    final RoomSnapshot? room = _room;
    if (room == null) {
      return;
    }
    final Object? seatValue = frame.data['seat'];
    final Object? nameValue = frame.data['name'];
    final int? seqValue = frame.seq;
    if (seatValue is! int || nameValue is! String || seqValue == null) {
      return;
    }
    final int index = room.seats.indexWhere(
      (SeatState s) => s.seat == seatValue,
    );
    if (index == -1) {
      return;
    }
    if (seqValue != room.seq + 1) {
      _hasDesynced = true;
    }
    final List<SeatState> seats = List<SeatState>.from(room.seats);
    seats[index] = seats[index].copyWith(name: nameValue, connected: true);
    _room = room.copyWith(seats: seats, seq: seqValue);
    notifyListeners();
  }

  /// `{seat}`, rule 6: that seat is removed from `room.seats`.
  void _applyPlayerLeft(Frame frame) {
    final RoomSnapshot? room = _room;
    if (room == null) {
      return;
    }
    final Object? seatValue = frame.data['seat'];
    final int? seqValue = frame.seq;
    if (seatValue is! int || seqValue == null) {
      return;
    }
    final int index = room.seats.indexWhere(
      (SeatState s) => s.seat == seatValue,
    );
    if (index == -1) {
      return;
    }
    if (seqValue != room.seq + 1) {
      _hasDesynced = true;
    }
    final List<SeatState> seats = List<SeatState>.from(room.seats)
      ..removeAt(index);
    _room = room.copyWith(seats: seats, seq: seqValue);
    notifyListeners();
  }

  /// `{seat, connected}`, rule 6: that seat's connected is set.
  void _applyPresence(Frame frame) {
    final RoomSnapshot? room = _room;
    if (room == null) {
      return;
    }
    final Object? seatValue = frame.data['seat'];
    final Object? connectedValue = frame.data['connected'];
    final int? seqValue = frame.seq;
    if (seatValue is! int || connectedValue is! bool || seqValue == null) {
      return;
    }
    final int index = room.seats.indexWhere(
      (SeatState s) => s.seat == seatValue,
    );
    if (index == -1) {
      return;
    }
    if (seqValue != room.seq + 1) {
      _hasDesynced = true;
    }
    final List<SeatState> seats = List<SeatState>.from(room.seats);
    seats[index] = seats[index].copyWith(connected: connectedValue);
    _room = room.copyWith(seats: seats, seq: seqValue);
    notifyListeners();
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

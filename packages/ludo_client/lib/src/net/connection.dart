// docs/PROTOCOL.md sections 1, 2, 4, 5, 7 and 8. The protocol engine: it
// drives a WireTransport, turns each client-to-server message into a typed
// method, matches a reply back to the request that caused it by id/re, and
// surfaces every inbound frame as a stream. It holds the seat token and the
// highest seq observed, and nothing else; no board, no seat list, no turn.
//
// This file has no platform socket import of any kind. It talks only to the
// WireTransport interface in transport.dart, which is what lets it be proved
// under `flutter test` with a fake transport and no server. The real socket
// adapter is a separate file, written against the same interface.

import 'dart:async';

import 'frame.dart';
import 'snapshot.dart';
import 'transport.dart';

/// The server answered a request with an `error` frame.
/// docs/PROTOCOL.md section 7.
class ProtocolErrorException implements Exception {
  const ProtocolErrorException(this.code, this.message, this.frame);

  /// The wire's `d.code`, one of the codes in section 7. Never invented here:
  /// whatever the server sent is what this carries, including a code this
  /// client does not recognise.
  final String code;

  /// The wire's `d.message`. Empty string when absent or not a string, never
  /// null, because a caller logging it should not have to guard it.
  final String message;

  /// The error frame exactly as received.
  final Frame frame;
}

/// The transport ended while this request was outstanding, or a request was
/// made on a connection that is not open.
class ConnectionClosedException implements Exception {
  const ConnectionClosedException();
}

/// No reply arrived within the connection's `requestTimeout`.
class RequestTimeoutException implements Exception {
  const RequestTimeoutException(this.type);

  /// The `t` of the request that went unanswered.
  final String type;
}

/// One pending `request()` call: the completer a reply resolves and the
/// timer that fires if none arrives.
class _PendingRequest {
  _PendingRequest({required this.completer, required this.timer});

  final Completer<Frame> completer;
  final Timer timer;
}

/// The lifecycle a single [RoomConnection] instance moves through. There is
/// no path back to [idle] once a transport has been obtained: a connection
/// that has been open and then closed does not reopen. A failed connection
/// attempt does return to [idle], because that is the one failure
/// [TransportConnector] documents as worth retrying.
enum _ConnState { idle, connecting, open, closed }

class RoomConnection {
  // The public parameter names `connect` and `requestTimeout` are pinned by
  // the frozen declaration block; they cannot become `_connect` and
  // `_requestTimeout`, which is why these cannot be initializing formals.
  RoomConnection({
    required this.url,
    required TransportConnector connect,
    Duration requestTimeout = const Duration(seconds: 10),
  }) : _connect = connect, // ignore: prefer_initializing_formals
       _requestTimeout = requestTimeout; // ignore: prefer_initializing_formals

  /// The address [open] will connect to.
  final Uri url;

  final TransportConnector _connect;
  final Duration _requestTimeout;

  _ConnState _state = _ConnState.idle;
  WireTransport? _transport;
  StreamSubscription<String>? _incomingSubscription;

  final StreamController<Frame> _framesController =
      StreamController<Frame>.broadcast();
  final Map<String, _PendingRequest> _pending = <String, _PendingRequest>{};
  final Completer<void> _doneCompleter = Completer<void>();

  /// True once [open] has completed successfully, for the lifetime of this
  /// instance. Distinct from [_state] so that [done] can tell "never
  /// connected" apart from "connected and now closed".
  bool _opened = false;

  int? _lastSeq;
  int? _seat;
  String? _seatToken;

  /// True between a successful [open] and the transport ending, by either
  /// end.
  bool get isOpen => _state == _ConnState.open;

  /// The highest `seq` seen on any inbound frame, or null before the first
  /// frame that carries one.
  int? get lastSeq => _lastSeq;

  /// This client's own seat, from `seat_assigned`, or null before one
  /// arrives.
  int? get seat => _seat;

  /// This client's seat token, from `seat_assigned`, or null before one
  /// arrives.
  String? get seatToken => _seatToken;

  /// Every inbound frame, in arrival order, including frames that also
  /// completed a pending request. Broadcast; late subscribers miss what
  /// already arrived. Closes when the connection does, and never emits an
  /// error.
  Stream<Frame> get frames => _framesController.stream;

  /// Completes when the connection is over, by either end, and never with an
  /// error. Completes immediately if [open] was never called successfully.
  Future<void> get done =>
      _opened ? _doneCompleter.future : Future<void>.value();

  /// Opens the transport via the connector. Throws whatever the connector
  /// throws if it cannot connect. Calling it on an already-open connection
  /// throws [StateError].
  Future<void> open() async {
    if (_state != _ConnState.idle) {
      throw StateError('RoomConnection.open: already open or already closed');
    }
    _state = _ConnState.connecting;
    final WireTransport transport;
    try {
      transport = await _connect(url);
    } catch (_) {
      if (_state == _ConnState.connecting) {
        _state = _ConnState.idle;
      }
      rethrow;
    }
    if (_state == _ConnState.closed) {
      // close() ran while the connect attempt was in flight. This transport
      // is now unwanted; do not wire it up, just let it go.
      unawaited(transport.close());
      return;
    }
    _transport = transport;
    _state = _ConnState.open;
    _opened = true;
    _incomingSubscription = transport.incoming.listen(
      _handleIncomingText,
      onError: (Object _, StackTrace _) {},
    );
    unawaited(transport.done.then((_) => _finishClosing()));
  }

  /// Closes the transport. Idempotent. Every outstanding request completes
  /// with [ConnectionClosedException].
  Future<void> close() async {
    final WireTransport? transport = _transport;
    _finishClosing();
    if (transport != null) {
      await transport.close();
    }
  }

  void _finishClosing() {
    if (_state == _ConnState.closed) {
      return;
    }
    _state = _ConnState.closed;
    unawaited(_incomingSubscription?.cancel());
    final List<_PendingRequest> outstanding = _pending.values.toList();
    _pending.clear();
    for (final _PendingRequest pending in outstanding) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(const ConnectionClosedException());
      }
    }
    if (!_framesController.isClosed) {
      unawaited(_framesController.close());
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  void _handleIncomingText(String text) {
    final Frame frame;
    try {
      frame = Frame.decode(text);
    } on FrameFormatException {
      // Rule: a malformed inbound frame is dropped and the connection
      // survives it. It never reaches `frames` and is never acted on.
      return;
    }

    final int? seq = frame.seq;
    if (seq != null && (_lastSeq == null || seq > _lastSeq!)) {
      _lastSeq = seq;
    }

    if (frame.type == 'seat_assigned') {
      final Object? seatValue = frame.data['seat'];
      final Object? tokenValue = frame.data['seat_token'];
      if (seatValue is int &&
          seatValue >= 0 &&
          seatValue <= 3 &&
          tokenValue is String) {
        _seat = seatValue;
        _seatToken = tokenValue;
      }
    }

    if (!_framesController.isClosed) {
      _framesController.add(frame);
    }

    final String? re = frame.re;
    if (re == null) {
      return;
    }
    final _PendingRequest? pending = _pending.remove(re);
    if (pending == null) {
      return;
    }
    pending.timer.cancel();
    if (pending.completer.isCompleted) {
      return;
    }
    if (frame.type == 'error') {
      final Object? codeValue = frame.data['code'];
      final Object? messageValue = frame.data['message'];
      final String code = codeValue is String ? codeValue : '';
      final String message = messageValue is String ? messageValue : '';
      pending.completer.completeError(
        ProtocolErrorException(code, message, frame),
      );
    } else {
      pending.completer.complete(frame);
    }
  }

  /// Sends `{v:1, t:type, id:<fresh>, d:data}` and completes with the frame
  /// whose `re` equals that `id`.
  ///
  /// Completes with [ProtocolErrorException] when that frame is an `error`,
  /// with [RequestTimeoutException] after `requestTimeout`, and with
  /// [ConnectionClosedException] if the connection ends first or was never
  /// open.
  Future<Frame> request(String type, Map<String, Object?> data) async {
    if (_state != _ConnState.open || _transport == null) {
      throw const ConnectionClosedException();
    }
    final String id = newMessageId();
    final Frame frame = Frame(type: type, id: id, data: data);
    final String text = frame.encode();

    final Completer<Frame> completer = Completer<Frame>();
    final Timer timer = Timer(_requestTimeout, () {
      final _PendingRequest? pending = _pending.remove(id);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(RequestTimeoutException(type));
      }
    });
    // Registered before send() so a transport that replies synchronously
    // (as a fake in a test may) always finds a match.
    _pending[id] = _PendingRequest(completer: completer, timer: timer);
    _transport!.send(text);
    return completer.future;
  }

  Future<RoomSnapshot> createRoom({
    required String name,
    required int players,
    RulesConfig? rules,
  }) async {
    final Map<String, Object?> data = <String, Object?>{
      'name': name,
      'players': players,
      if (rules != null) 'rules': rules.toJson(),
    };
    final Frame frame = await request('create_room', data);
    return _asRoomSnapshot(frame);
  }

  Future<RoomSnapshot> joinRoom({
    required String code,
    required String name,
  }) async {
    final Frame frame = await request('join_room', <String, Object?>{
      'code': code,
      'name': name,
    });
    return _asRoomSnapshot(frame);
  }

  Future<RoomSnapshot> resume({
    required String code,
    required String seatToken,
  }) async {
    final Frame frame = await request('resume', <String, Object?>{
      'code': code,
      'seat_token': seatToken,
    });
    return _asRoomSnapshot(frame);
  }

  Future<RoomSnapshot> setPlayers(int players) async {
    final Frame frame = await request('set_players', <String, Object?>{
      'players': players,
    });
    return _asRoomSnapshot(frame);
  }

  Future<Frame> setSeed(String clientSeed) {
    return request('set_seed', <String, Object?>{'client_seed': clientSeed});
  }

  Future<Frame> startGame() {
    return request('start_game', const <String, Object?>{});
  }

  Future<Frame> roll() {
    return request('roll', const <String, Object?>{});
  }

  Future<Frame> move(int token) {
    return request('move', <String, Object?>{'token': token});
  }

  Future<Frame> leaveRoom() {
    return request('leave_room', const <String, Object?>{});
  }

  Future<Frame> ping() {
    return request('ping', const <String, Object?>{});
  }

  RoomSnapshot _asRoomSnapshot(Frame frame) {
    if (frame.type != 'room') {
      throw FrameFormatException('expected room, got ${frame.type}');
    }
    return RoomSnapshot.fromJson(frame.data);
  }
}

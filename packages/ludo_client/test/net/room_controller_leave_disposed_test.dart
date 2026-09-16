// Order 150: proves the rule every other async method on RoomController
// already obeys, applied to leave().
//
//   A controller that was disposed while leave() was awaiting must not be
//   mutated or notified when leave() resumes. leave() must complete
//   normally, without throwing, without calling notifyListeners(), and
//   without writing phase.
//
// and the half that must keep working, asserted in the same file so a fix
// cannot buy the first half by breaking this one:
//
//   A controller that is NOT disposed must, after leave(), have phase ==
//   RoomPhase.closed, must have notified its listeners exactly once, must
//   have cancelled its frame subscription and must have closed its
//   connection.
//
// This file is deliberately independent of test/net/room_controller_test.dart
// (out of scope: read-only) and of test/net/connection_test.dart and
// test/net/room_controller_game_test.dart (also out of scope, read-only). It
// reuses only test/net/fake_transport.dart, the shared seam, and rebuilds the
// small amount of wire-level scaffolding (a minimal room snapshot, a queueing
// TransportConnector double) that room_controller_test.dart also builds for
// itself, in the same shapes, so a reader who knows that file recognises this
// one immediately.
//
// Every case here is a plain test(), never testWidgets(): pumpEventQueue()
// is used directly, which is only safe outside the widget-test pump cycle.
//
// The point of control for the mid-await case is the outstanding leave_room
// request: leave() is called, pumped until leave_room has actually gone out
// on the wire and is unanswered, then dispose() runs, and only after that is
// the reply pushed so leave()'s single await actually resumes post-disposal.
// This is checked directly (the last sent frame decodes to type leave_room)
// rather than assumed from timing.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers ------------------------------------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

/// A server push or reply, encoded exactly as Frame.decode expects.
String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot --------------

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = false,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  int hostSeat = 0,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
  'host_seat': hostSeat,
  'players': 4,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    _seatJson(hostSeat, name: 'Sam', connected: true),
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
};

// --- a TransportConnector test double that hands out queued transports -----

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

/// Drives a controller through a successful createRoom() and returns it
/// already in phase connected, with a live connection and frame
/// subscription: the starting state every case below needs.
Future<(RoomController, FakeTransport, _Connector)>
_connectedController() async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);

  final Future<void> future = controller.createRoom(name: 'Sam', players: 4);
  await pumpEventQueue();
  final String createId = _decode(transport.sentRaw.last)['id']! as String;
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(type: 'room', re: createId, data: _roomJson(seq: 1)),
  );
  await future;
  return (controller, transport, connector);
}

void main() {
  group('leave(): the disposed-mid-await rule and the not-disposed rule it '
      'must not break', () {
    test('a controller disposed while leave() is still awaiting the '
        'leave_room reply completes leave() normally, does not notify, and '
        'does not change phase', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController();

      final RoomPhase phaseBeforeLeave = controller.phase;
      expect(
        phaseBeforeLeave,
        RoomPhase.connected,
        reason:
            'fixture is broken: the controller must be connected before '
            'leave() is called',
      );

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      final Future<void> leaveFuture = controller.leave();
      await pumpEventQueue();

      expect(
        transport.sentRaw,
        isNotEmpty,
        reason:
            'fixture is broken: leave() must already have sent something '
            'before dispose() runs',
      );
      final Map<String, Object?> sentLeaveRoom = _decode(
        transport.sentRaw.last,
      );
      expect(
        sentLeaveRoom['t'],
        'leave_room',
        reason:
            'fixture is broken: the point of control for this case must '
            'be the outstanding leave_room request, got '
            '${transport.sentRaw.last}',
      );
      final String leaveRoomId = sentLeaveRoom['id']! as String;

      // The point of control: leave() is parked on `await
      // connection.leaveRoom()` with the request already on the wire and
      // not yet answered. Dispose now, then answer, so leave() resumes
      // strictly after disposal.
      controller.dispose();

      transport.pushText(
        _frame(
          type: 'player_left',
          re: leaveRoomId,
          data: <String, Object?>{'seat': 0, 'seq': 2},
        ),
      );

      Object? caughtError;
      try {
        await leaveFuture;
      } catch (error) {
        caughtError = error;
      }

      expect(
        caughtError,
        isNull,
        reason:
            'leave() must complete normally when the controller was '
            'disposed while it was awaiting the leave_room reply; it '
            'threw instead: $caughtError',
      );
      expect(
        notifyCount,
        0,
        reason:
            'a disposed controller must not be notified when leave() '
            'resumes; notifyListeners() fired $notifyCount time(s)',
      );
      expect(
        controller.phase,
        phaseBeforeLeave,
        reason:
            'a disposed controller must not have its phase mutated when '
            'leave() resumes; phase is ${controller.phase}, was '
            '$phaseBeforeLeave immediately before dispose()',
      );
    });

    test('the ordinary not-disposed path: leave() cancels the frame '
        'subscription immediately, sends leave_room, closes the connection, '
        'sets phase=closed and notifies exactly once', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController();
      addTearDown(controller.dispose);

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      final Future<void> leaveFuture = controller.leave();

      // leave() cancels the frame subscription synchronously, before its
      // first await, so a push that lands on the still-open transport
      // while leave_room is outstanding must not reach frames.
      final List<Frame> framesAfterLeaveCalled = <Frame>[];
      controller.frames.listen(framesAfterLeaveCalled.add);

      await pumpEventQueue();
      expect(
        transport.sentRaw,
        isNotEmpty,
        reason: 'fixture is broken: leave() must have sent leave_room',
      );
      final Map<String, Object?> sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'leave_room');
      final String id = sent['id']! as String;

      transport.pushText(
        _frame(
          type: 'presence',
          data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 2},
        ),
      );
      await pumpEventQueue();
      expect(
        framesAfterLeaveCalled,
        isEmpty,
        reason:
            'the frame subscription must already be cancelled once '
            'leave() has been called: an unrelated push that arrives '
            'before the leave_room reply must not reach frames, got '
            '$framesAfterLeaveCalled',
      );

      transport.pushText(
        _frame(
          type: 'player_left',
          re: id,
          data: <String, Object?>{'seat': 0, 'seq': 3},
        ),
      );
      await expectLater(leaveFuture, completes);

      expect(controller.phase, RoomPhase.closed);
      expect(
        notifyCount,
        1,
        reason: 'leave() must notify exactly once, got $notifyCount',
      );
      expect(
        transport.closeCalls,
        isNotEmpty,
        reason: 'leave() must close the underlying connection',
      );
    });

    test('leave() on an already-disposed controller is a no-op: no throw, no '
        'notify, phase left exactly as dispose() left it', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController();

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.dispose();
      await pumpEventQueue();
      final RoomPhase phaseAfterDispose = controller.phase;
      final int notifyCountAfterDispose = notifyCount;

      late Future<void> future;
      expect(() => future = controller.leave(), returnsNormally);
      await expectLater(future, completes);

      expect(
        controller.phase,
        phaseAfterDispose,
        reason:
            'leave() on an already-disposed controller must not change '
            'phase; it is now ${controller.phase}, was '
            '$phaseAfterDispose right after dispose()',
      );
      expect(
        notifyCount,
        notifyCountAfterDispose,
        reason:
            'leave() on an already-disposed controller must not notify; '
            'notifyListeners() fired ${notifyCount - notifyCountAfterDispose} '
            'more time(s) than it had already fired by dispose()',
      );
    });

    test('leave() when there is no connection at all (idle, never connected): '
        'no throw, phase becomes closed, notifies exactly once, opens no '
        'transport', () async {
      final _Connector connector = _Connector();
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      expect(
        controller.phase,
        RoomPhase.idle,
        reason: 'fixture is broken: the controller must start idle',
      );

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      late Future<void> future;
      expect(() => future = controller.leave(), returnsNormally);
      await expectLater(future, completes);

      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'leave() must set phase to closed even with no connection to '
            'close, got ${controller.phase}',
      );
      expect(
        notifyCount,
        1,
        reason:
            'leave() must notify exactly once even when idle, got '
            '$notifyCount',
      );
      expect(
        connector.calls,
        isEmpty,
        reason: 'leave() must never open a transport',
      );
    });
  });
}

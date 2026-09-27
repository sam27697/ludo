// Proof for docs/PROTOCOL.md section 15 ("A seat number can change in the
// lobby") and order 206's goal 2 (a refused set_players must not wreck the
// lobby), written from that section and from
// work/ludo/orders/206-lobby-start-with-present.md, against RoomController
// as it stands on this branch (78724c9), before order 206 has touched it.
//
// Built the way test/net/room_controller_resume_room_test.dart is built: a
// fake TransportConnector hands out FakeTransport instances
// (test/net/fake_transport.dart, read-only), frames are pushed with
// pushText, and every claim about what the controller sent is made by
// decoding FakeTransport.sentRaw, never by trusting that "a message was
// sent". The helpers below (_frame, _roomJson, _seatJson, _Connector) are
// private copies for this file, not imports of any other test file's own
// private helpers.
//
// C4 and C5 run inside fakeAsync (package:fake_async), the house pattern
// used by room_controller_resume_room_test.dart's own R-6: an async
// operation is started and its result captured with unawaited() rather than
// a direct await, because a fakeAsync callback must stay synchronous, and
// FakeAsync.flushMicrotasks()/elapse() drive it to completion. This is what
// lets "no reconnect sequence started" be checked by actually letting fake
// time pass, rather than asserted at the instant of the failure alone. C1,
// C2, C3 and C6 need no scheduled delay and use plain async/await with
// pumpEventQueue(), matching room_controller_resume_room_test.dart's R-1.
//
// Ids at the start of each test name are order 205's own (C1..C6).

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://order-205-reseat-test.invalid/ws';

/// A short, distinctive schedule, matching the pattern
/// test/net/room_controller_resume_room_test.dart uses: an attempt landing
/// at the wrong cumulative delay against this list is unambiguous.
const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 3),
  Duration(seconds: 7),
];

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-205-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers ------------------------------------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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
  bool connected = true,
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
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats':
      seats ??
      <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam', connected: true)],
  'turn': null,
  'winner': null,
  'seq': seq,
};

// --- a TransportConnector test double that records and queues ----------

/// Hands out queued [FakeTransport]s, one per call, in order. Records every
/// url it was called with so a test can assert exactly how many times a
/// connection was ever attempted.
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

RoomController _newController(
  _Connector connector, {
  List<Duration> autoReconnectDelays = const <Duration>[],
}) => RoomController(
  serverUrl: Uri.parse(_testUrl),
  connect: connector.call,
  autoReconnectDelays: autoReconnectDelays,
);

void main() {
  // --- C1: control -----------------------------------------------------
  test('C1 (control): joined as seat 1; the server pushes seat_assigned '
      '{seat: 2, seat_token: <same>} then a room: controller.seat == 2 '
      'afterwards, seatToken unchanged, phase still connected', () async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    addTearDown(controller.dispose);

    final Future<void> joinFuture = controller.joinRoom(
      code: 'K7M2QP',
      name: 'Sam',
    );
    await pumpEventQueue();
    final String joinId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 1, 'seat_token': 'tok-c1'},
      ),
    );
    transport.pushText(
      _frame(type: 'room', re: joinId, data: _roomJson(hostSeat: 0, seq: 1)),
    );
    await joinFuture;

    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'fixture is broken: joinRoom must have succeeded before this '
          'test pushes a mid-connection seat_assigned',
    );
    expect(controller.seat, 1);
    expect(controller.seatToken, 'tok-c1');

    // The re-seat this test measures: a seat_assigned that moves this
    // client's own seat number, immediately followed by the room that
    // carries the new seating (re: null, a broadcast, seq == room.seq +
    // 1 so RoomController._reduceRoom applies it directly rather than
    // treating it as a gap and starting its own resync).
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 2, 'seat_token': 'tok-c1'},
      ),
    );
    transport.pushText(
      _frame(type: 'room', data: _roomJson(hostSeat: 0, seq: 2)),
    );
    await pumpEventQueue();

    expect(
      controller.seat,
      2,
      reason:
          'C1: a mid-connection seat_assigned must update the cached '
          'seat; RoomController._handleFrame already calls '
          '_syncSeatCache() for every inbound frame, including this one, '
          'so this is the control case the order says may already be '
          'green on this base',
    );
    expect(
      controller.seatToken,
      'tok-c1',
      reason:
          'docs/PROTOCOL.md section 15 rule 3: the seat token never '
          'changes, only the seat number does',
    );
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: 'C1: a re-seat must not by itself change the phase',
    );
  });

  // --- C2: rule 5 on resume ---------------------------------------------
  test('C2 (rule 5 on resume): resumeRoom(seat: 1); the server answers '
      'seat_assigned {seat: 2, seat_token: t} (re null) then room (re = the '
      'resume id): controller.seat must end at 2', () async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    addTearDown(controller.dispose);

    const String code = 'K7M2QP';
    const String token = 'tok-c2';

    final Future<void> future = controller.resumeRoom(
      code: code,
      seat: 1,
      seatToken: token,
    );
    await pumpEventQueue();
    final String id = _idOf(transport.sentRaw.last);
    expect(_typeOf(transport.sentRaw.last), 'resume');

    // docs/PROTOCOL.md section 15 rule 2: resume is answered with
    // seat_assigned, then room, on the resuming socket. Here the seat
    // moved while this seat was away: the server's seat_assigned carries
    // 2, not the 1 this call was given.
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 2, 'seat_token': token},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: id,
        data: _roomJson(code: code, hostSeat: 0, seq: 1),
      ),
    );
    await future;

    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'fixture is broken: resumeRoom must have succeeded before this '
          'test asserts on its seat',
    );
    expect(
      controller.seat,
      2,
      reason:
          'docs/PROTOCOL.md section 15 rule 5: a client treats every '
          'seat_assigned as the truth about its own seat, at any point '
          'in the connection, including the seat it passed to resume. '
          'The server answered seat_assigned{seat: 2} before the room '
          'reply to resumeRoom(seat: 1, seatToken: "$token"), so '
          'controller.seat must be 2, not the stale resumeRoom argument '
          '1. room_controller.dart\'s resumeRoom currently does '
          '"_cachedSeat = seat;" unconditionally after the await '
          '(the "R4" comment, ~line 283), which overwrites whatever '
          '_syncSeatCache already read from the live connection.',
    );
    expect(
      controller.seatToken,
      token,
      reason: 'the seat token must be unchanged by the re-seat',
    );
  });

  // --- C3: no seat_assigned on resume (older server) ---------------------
  test(
    'C3: resumeRoom where the server sends no seat_assigned (an older '
    'server): controller.seat is the resumeRoom argument, as today',
    () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      const String code = 'K7M2QP';
      const int seat = 3;
      const String token = 'tok-c3';

      final Future<void> future = controller.resumeRoom(
        code: code,
        seat: seat,
        seatToken: token,
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      expect(_typeOf(transport.sentRaw.last), 'resume');

      // No seat_assigned at all: only the room reply.
      transport.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(code: code, hostSeat: 0, seq: 1),
        ),
      );
      await future;

      expect(controller.phase, RoomPhase.connected);
      expect(
        controller.seat,
        seat,
        reason:
            'C3: with no seat_assigned at all (an older server), '
            'controller.seat must still be the resumeRoom argument, $seat',
      );
      expect(controller.seatToken, token);
    },
  );

  // --- C4: setPlayers refused NOT_ENOUGH_PLAYERS -------------------------
  test('C4: setPlayers(2) answered NOT_ENOUGH_PLAYERS: phase stays connected, '
      'errorCode null, no reconnect sequence started', () {
    fakeAsync((FakeAsync async) {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(
        connector,
        autoReconnectDelays: _delays,
      );

      unawaited(controller.joinRoom(code: 'K7M2QP', name: 'Sam'));
      async.flushMicrotasks();
      final String joinId = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok-c4'},
        ),
      );
      transport.pushText(
        _frame(type: 'room', re: joinId, data: _roomJson(hostSeat: 0, seq: 1)),
      );
      async.flushMicrotasks();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: joinRoom must have succeeded before this '
            'test calls setPlayers against it',
      );

      unawaited(controller.setPlayers(2));
      async.flushMicrotasks();
      expect(
        _typeOf(transport.sentRaw.last),
        'set_players',
        reason:
            'fixture is broken: setPlayers(2) must have sent a '
            'set_players frame',
      );
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'NOT_ENOUGH_PLAYERS',
            'message':
                'a friend left between the tap and the server '
                'reading it',
          },
        ),
      );
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'C4: order 206\'s _setPlayersRejectedCodes must make a '
            'set_players refused with NOT_ENOUGH_PLAYERS leave phase '
            'connected, mirroring _startGameRejectedCodes; got '
            '${controller.phase}',
      );
      expect(
        controller.errorCode,
        isNull,
        reason:
            'C4: errorCode must stay null after a refused set_players; '
            'got ${controller.errorCode}',
      );

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C4: a refused set_players must never start an automatic '
            'reconnect sequence, however long fake time elapses',
      );
      expect(
        connector.calls.length,
        1,
        reason:
            'C4: no reconnect sequence means the connector must never be '
            'called a second time',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- C5: setPlayers refused ROOM_STARTED -------------------------------
  test('C5: setPlayers(2) answered ROOM_STARTED: phase stays connected, '
      'errorCode null, no reconnect sequence started', () {
    fakeAsync((FakeAsync async) {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(
        connector,
        autoReconnectDelays: _delays,
      );

      unawaited(controller.joinRoom(code: 'K7M2QP', name: 'Sam'));
      async.flushMicrotasks();
      final String joinId = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok-c5'},
        ),
      );
      transport.pushText(
        _frame(type: 'room', re: joinId, data: _roomJson(hostSeat: 0, seq: 1)),
      );
      async.flushMicrotasks();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: joinRoom must have succeeded before this '
            'test calls setPlayers against it',
      );

      unawaited(controller.setPlayers(2));
      async.flushMicrotasks();
      expect(
        _typeOf(transport.sentRaw.last),
        'set_players',
        reason:
            'fixture is broken: setPlayers(2) must have sent a '
            'set_players frame',
      );
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'ROOM_STARTED',
            'message': 'the second of two taps on the same request',
          },
        ),
      );
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'C5: order 206\'s _setPlayersRejectedCodes must make a '
            'set_players refused with ROOM_STARTED leave phase '
            'connected too; got ${controller.phase}',
      );
      expect(
        controller.errorCode,
        isNull,
        reason:
            'C5: errorCode must stay null after a refused set_players; '
            'got ${controller.errorCode}',
      );

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C5: a refused set_players must never start an automatic '
            'reconnect sequence, however long fake time elapses',
      );
      expect(
        connector.calls.length,
        1,
        reason:
            'C5: no reconnect sequence means the connector must never be '
            'called a second time',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- C6: setPlayers refused BAD_FIELD ----------------------------------
  test('C6: setPlayers(2) answered BAD_FIELD fails exactly as any other '
      'in-room request failure does today, through _failFromInRoomRequest: '
      'phase failed, errorCode verbatim, room left as it was, no reconnect '
      'sequence (BAD_FIELD is not in _retryableErrorCodes)', () {
    fakeAsync((FakeAsync async) {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(
        connector,
        autoReconnectDelays: _delays,
      );

      unawaited(controller.joinRoom(code: 'K7M2QP', name: 'Sam'));
      async.flushMicrotasks();
      final String joinId = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok-c6'},
        ),
      );
      transport.pushText(
        _frame(type: 'room', re: joinId, data: _roomJson(hostSeat: 0, seq: 1)),
      );
      async.flushMicrotasks();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: joinRoom must have succeeded before this '
            'test calls setPlayers against it',
      );
      final int? seatBefore = controller.seat;
      final String? seatTokenBefore = controller.seatToken;

      unawaited(controller.setPlayers(2));
      async.flushMicrotasks();
      expect(
        _typeOf(transport.sentRaw.last),
        'set_players',
        reason:
            'fixture is broken: setPlayers(2) must have sent a '
            'set_players frame',
      );
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'BAD_FIELD',
            'message': 'players must be 2, 3 or 4',
          },
        ),
      );
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'C6: today, _failFromInRoomRequest has no special case for '
            'setPlayers and lands any non-retryable code in '
            'RoomPhase.failed via _failFromRequest; got '
            '${controller.phase}',
      );
      expect(
        controller.errorCode,
        'BAD_FIELD',
        reason: 'C6: the server code must arrive in errorCode verbatim',
      );
      expect(
        controller.room,
        isNotNull,
        reason:
            'C6: _fail (reached through _failFromRequest) never clears '
            '_room; the room held before the failed request must still '
            'be held',
      );
      expect(controller.room?.code, 'K7M2QP');
      expect(
        controller.seat,
        seatBefore,
        reason: 'C6: seat must be unchanged by a failed in-room request',
      );
      expect(controller.seatToken, seatTokenBefore);

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C6: BAD_FIELD is not in _retryableErrorCodes, so no '
            'automatic sequence may ever start for it',
      );
      expect(
        connector.calls.length,
        1,
        reason:
            'C6: no reconnect sequence means the connector must never be '
            'called a second time',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });
}

// Proof for order 170 section R (RoomController.resumeRoom), written from
// THE CONTRACT copied verbatim into work/ludo/orders/173-prove-resume-room-
// and-seat-record.md (R1..R5), and from nothing else. Where a case would
// need to assume something the contract leaves silent, that is called out at
// the case rather than guessed at.
//
// Built the way test/net/room_controller_auto_reconnect_test.dart is built:
// a fake TransportConnector hands out FakeTransport instances
// (test/net/fake_transport.dart, read-only), frames are pushed with
// pushText, and every claim about what the controller sent is made by
// decoding FakeTransport.sentRaw, never by trusting that "a message was
// sent". The helpers below (_frame, _roomJson, _seatJson, _turnJson,
// _Connector) are private copies for this file, not imports of any other
// test file's own private helpers.
//
// Cases that depend on a scheduled delay (R-6, R-8) run inside fakeAsync
// (package:fake_async), following the house pattern: an async operation is
// started and its result captured with unawaited()/unwaited futures rather
// than a direct await, because a fakeAsync callback must stay synchronous,
// and FakeAsync.flushMicrotasks()/elapse() drive it to completion. Cases
// that need no scheduled delay use plain async/await with pumpEventQueue(),
// the pattern test/net/room_controller_test.dart uses.
//
// Attempts are counted by counting connector calls, never by reading
// `phase`, per house convention. Every case builds its own controller.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomSnapshot;
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://order-173-resume-test.invalid/ws';

/// A short, distinctive schedule, matching the pattern
/// test/net/room_controller_auto_reconnect_test.dart uses: an attempt
/// landing at the wrong cumulative delay against this list is unambiguous.
const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 3),
  Duration(seconds: 7),
];

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-173-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers ------------------------------------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
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
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double that records and queues ----------

/// Hands out queued [FakeTransport]s, one per call, in order. Records every
/// url it was called with so a test can assert exactly how many times a
/// connection was ever attempted. [rejectNextWith] makes exactly the next
/// call reject instead, to exercise the connector-rejects path ('transport')
/// without touching any transport at all.
class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];
  Object? _rejectNextWith;

  void enqueue(FakeTransport transport) => _queue.add(transport);

  void rejectNextWith(Object error) => _rejectNextWith = error;

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_rejectNextWith != null) {
      final Object error = _rejectNextWith!;
      _rejectNextWith = null;
      throw error;
    }
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

// --- controller construction ------------------------------------------

RoomController _newController(
  _Connector connector, {
  List<Duration> autoReconnectDelays = const <Duration>[],
}) => RoomController(
  serverUrl: Uri.parse(_testUrl),
  connect: connector.call,
  autoReconnectDelays: autoReconnectDelays,
);

/// Drives [controller] through a successful joinRoom(), for the one gate
/// case (R-4, "with a room already held") that needs a controller already
/// holding a room through a path other than resumeRoom itself.
Future<void> _joinRoom(
  RoomController controller,
  FakeTransport transport, {
  required String code,
  required int seat,
}) async {
  final Future<void> future = controller.joinRoom(code: code, name: 'Sam');
  await pumpEventQueue();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': seat, 'seat_token': 'tok-join-$seat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(code: code, hostSeat: 0),
    ),
  );
  await future;
}

void main() {
  // --- R-1 success. --------------------------------------------------------
  test('R-1 success: resumeRoom sends exactly one resume frame with the given '
      'code and seat token, no join_room, and a valid PLAYING snapshot lands '
      'connected', () async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    addTearDown(controller.dispose);

    const String code = 'K7M2QP';
    const int seat = 2;
    const String token = 'tok-r1-success';

    final Future<void> future = controller.resumeRoom(
      code: code,
      seat: seat,
      seatToken: token,
    );
    await pumpEventQueue();

    expect(
      transport.sentRaw,
      hasLength(1),
      reason:
          'R3: resumeRoom must send exactly one frame before the reply '
          'arrives; got ${transport.sentRaw}',
    );
    final Map<String, Object?> sent = _decode(transport.sentRaw.single);
    expect(
      sent['t'],
      'resume',
      reason:
          'R3: the frame resumeRoom sends must be resume, not join_room; '
          'got t=${sent['t']}',
    );
    expect(
      sent['d'],
      equals(<String, Object?>{'code': code, 'seat_token': token}),
      reason:
          'the resume frame must carry exactly the code and seat token '
          'resumeRoom was called with; got d=${sent['d']}',
    );

    final String id = sent['id']! as String;
    transport.pushText(
      _frame(
        type: 'room',
        re: id,
        data: _roomJson(
          code: code,
          state: 'PLAYING',
          hostSeat: 0,
          turn: _turnJson(
            seat: seat,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
          seq: 3,
        ),
      ),
    );
    await future;

    expect(controller.phase, RoomPhase.connected);
    expect(controller.room?.code, code);
    expect(
      controller.seat,
      seat,
      reason:
          'R4: seat must equal the resumeRoom argument, not a cached '
          'value from the wire',
    );
    expect(controller.seatToken, token);
    expect(controller.errorCode, isNull);
  });

  // --- R-2 notify ordering (R4). --------------------------------------------
  test(
    'R-2 notify ordering (R4): at the first notification where phase is '
    'connected, room, seat and seatToken are already the final values',
    () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final List<(RoomPhase, RoomSnapshot?, int?, String?)> records =
          <(RoomPhase, RoomSnapshot?, int?, String?)>[];
      controller.addListener(() {
        records.add((
          controller.phase,
          controller.room,
          controller.seat,
          controller.seatToken,
        ));
      });

      const String code = 'K7M2QP';
      const int seat = 1;
      const String token = 'tok-r2-order';

      final Future<void> future = controller.resumeRoom(
        code: code,
        seat: seat,
        seatToken: token,
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(code: code, hostSeat: 0, seq: 4),
        ),
      );
      await future;

      final int firstConnectedIndex = records.indexWhere(
        (record) => record.$1 == RoomPhase.connected,
      );
      expect(
        firstConnectedIndex,
        isNot(-1),
        reason:
            'resumeRoom must notify at least once with phase connected; '
            'recorded phases: ${records.map((r) => r.$1).toList()}',
      );
      final (
        RoomPhase phase,
        RoomSnapshot? room,
        int? recordedSeat,
        String? recordedSeatToken,
      ) = records[firstConnectedIndex];
      expect(phase, RoomPhase.connected);
      expect(
        room?.code,
        code,
        reason:
            'R4: room must already be the answered snapshot at the first '
            'connected notification',
      );
      expect(
        room?.seq,
        4,
        reason:
            'R4: room must already be the answered snapshot (seq 4), not '
            'some intermediate value, at the first connected notification',
      );
      expect(
        recordedSeat,
        seat,
        reason:
            'R4: seat must already equal the resumeRoom argument at the '
            'first connected notification, got $recordedSeat',
      );
      expect(
        recordedSeatToken,
        token,
        reason:
            'R4: seatToken must already equal the resumeRoom argument at '
            'the first connected notification, got $recordedSeatToken',
      );
    },
  );

  // --- R-3 isHost. -----------------------------------------------------------
  test(
    'R-3 isHost: true when the snapshot host_seat equals the resumed seat',
    () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final Future<void> future = controller.resumeRoom(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok-host-true',
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(code: 'K7M2QP', hostSeat: 2, seq: 1),
        ),
      );
      await future;

      expect(
        controller.isHost,
        isTrue,
        reason: 'host_seat (2) equals the resumed seat (2)',
      );
    },
  );

  test('R-3 isHost: false when the snapshot host_seat differs from the resumed '
      'seat', () async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    addTearDown(controller.dispose);

    final Future<void> future = controller.resumeRoom(
      code: 'K7M2QP',
      seat: 2,
      seatToken: 'tok-host-false',
    );
    await pumpEventQueue();
    final String id = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'room',
        re: id,
        data: _roomJson(code: 'K7M2QP', hostSeat: 0, seq: 1),
      ),
    );
    await future;

    expect(
      controller.isHost,
      isFalse,
      reason: 'host_seat (0) differs from the resumed seat (2)',
    );
  });

  // --- R-4 gates (R2), one case each. ---------------------------------------
  test(
    'R-4 gates (R2): resumeRoom after leave() has been called is a no-op',
    () async {
      final _Connector connector = _Connector();
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      await controller.leave();
      final int callsBefore = connector.calls.length;
      final int notifyBefore = notifyCount;

      await controller.resumeRoom(
        code: 'K7M2QP',
        seat: 1,
        seatToken: 'tok-after-leave',
      );

      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'R2: leave() having been called must make resumeRoom a no-op '
            'that opens no connection',
      );
      expect(
        notifyCount,
        notifyBefore,
        reason: 'R2: resumeRoom after leave() must not notify',
      );
      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'resumeRoom must not have changed phase away from what leave() '
            'set it to',
      );
    },
  );

  test('R-4 gates (R2): resumeRoom after dispose() must not throw and stays a '
      'no-op', () async {
    final _Connector connector = _Connector();
    final RoomController controller = _newController(connector);
    int notifyCount = 0;
    controller.addListener(() => notifyCount++);
    controller.dispose();
    final int callsBefore = connector.calls.length;
    final int notifyBefore = notifyCount;

    late Future<void> future;
    expect(
      () => future = controller.resumeRoom(
        code: 'K7M2QP',
        seat: 1,
        seatToken: 'tok-after-dispose',
      ),
      returnsNormally,
      reason: 'R1: resumeRoom must never throw, including after dispose()',
    );
    await expectLater(
      future,
      completes,
      reason:
          'R1: the returned future must complete normally even after '
          'dispose()',
    );

    expect(
      connector.calls.length,
      callsBefore,
      reason:
          'R2: a disposed controller must never open a connection from '
          'resumeRoom',
    );
    expect(
      notifyCount,
      notifyBefore,
      reason: 'R2: resumeRoom on a disposed controller must not notify',
    );
  });

  test('R-4 gates (R2): a second resumeRoom call while the first is still '
      'connecting is a no-op', () async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    addTearDown(controller.dispose);
    int notifyCount = 0;
    controller.addListener(() => notifyCount++);

    final Future<void> first = controller.resumeRoom(
      code: 'K7M2QP',
      seat: 2,
      seatToken: 'tok-first',
    );
    expect(
      controller.phase,
      RoomPhase.connecting,
      reason:
          'fixture is broken: the first resumeRoom call must already be '
          'connecting, synchronously, before this test fires the second',
    );
    final int callsAfterFirstStart = connector.calls.length;
    final int notifyAfterFirstStart = notifyCount;

    final Future<void> second = controller.resumeRoom(
      code: 'ZZZZZZ',
      seat: 3,
      seatToken: 'tok-second',
    );

    expect(
      connector.calls.length,
      callsAfterFirstStart,
      reason:
          'R2: a second resumeRoom call while phase is connecting must '
          'not open a connection',
    );
    expect(
      notifyCount,
      notifyAfterFirstStart,
      reason:
          'R2: a second resumeRoom call while connecting must not '
          'notify',
    );

    await pumpEventQueue();
    final String id = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'room',
        re: id,
        data: _roomJson(code: 'K7M2QP', hostSeat: 2, seq: 1),
      ),
    );
    await first;
    await second;

    expect(
      transport.sentRaw,
      hasLength(1),
      reason:
          'R2: the no-op second call must never have put anything on the '
          'wire',
    );
    expect(controller.phase, RoomPhase.connected);
    expect(
      controller.seat,
      2,
      reason:
          'the accepted first call, not the rejected second, must be '
          'what landed',
    );
    expect(controller.seatToken, 'tok-first');
  });

  test('R-4 gates (R2): resumeRoom with a room already held (after a '
      'successful joinRoom) is a no-op', () async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    addTearDown(controller.dispose);

    await _joinRoom(controller, transport, code: 'K7M2QP', seat: 0);
    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'fixture is broken: joinRoom must have succeeded before this '
          'test calls resumeRoom against an already-held room',
    );

    int notifyCount = 0;
    controller.addListener(() => notifyCount++);
    final int callsBefore = connector.calls.length;
    final RoomSnapshot? roomBefore = controller.room;
    final int? seatBefore = controller.seat;

    await controller.resumeRoom(
      code: 'ANOTHR',
      seat: 3,
      seatToken: 'tok-should-not-land',
    );

    expect(
      connector.calls.length,
      callsBefore,
      reason:
          'R2: a controller already holding a room must make resumeRoom '
          'a no-op that opens no connection',
    );
    expect(
      notifyCount,
      0,
      reason: 'R2: resumeRoom with a room already held must not notify',
    );
    expect(
      controller.room,
      same(roomBefore),
      reason:
          'R2: resumeRoom with a room already held must change '
          'nothing',
    );
    expect(controller.seat, seatBefore);
  });

  test('R-4 gates (R2): resumeRoom while phase is failed with a room still '
      'held (roll() answered BAD_SEAT_TOKEN) is a no-op', () async {
    // R2's phase clause alone already rejects resumeRoom out of connected,
    // so a controller that merely holds a room through joinRoom never
    // reaches the room == null clause: it is still connected, and the
    // phase check above rejects it first. The room clause only decides
    // anything at phase failed with room non-null, which needs an
    // in-room request to fail without joinRoom's own room being cleared
    // (order 170 E2/G1: roll() answered a non-retryable code such as
    // BAD_SEAT_TOKEN goes through _failFromRequest, landing failed while
    // room, seat and seatToken are left exactly as they were).
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    addTearDown(controller.dispose);

    await _joinRoom(controller, transport, code: 'K7M2QP', seat: 0);
    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'fixture is broken: joinRoom must have succeeded before this '
          'test fails an in-room request against it',
    );

    final Future<void> rollFuture = controller.roll();
    await pumpEventQueue();
    final String rollId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'error',
        re: rollId,
        data: <String, Object?>{
          'code': 'BAD_SEAT_TOKEN',
          'message': 'no such seat',
        },
      ),
    );
    await rollFuture;

    expect(
      controller.phase,
      RoomPhase.failed,
      reason:
          'fixture is broken: roll() answered BAD_SEAT_TOKEN must have '
          'landed the controller in failed before this test calls '
          'resumeRoom against it',
    );
    expect(
      controller.room,
      isNotNull,
      reason:
          'fixture is broken: a failed in-room request must leave room '
          'exactly as it was, not clear it, or this case is not '
          'exercising the room clause at all',
    );

    int notifyCount = 0;
    controller.addListener(() => notifyCount++);
    final int callsBefore = connector.calls.length;
    final RoomSnapshot? roomBefore = controller.room;
    final int? seatBefore = controller.seat;
    final String? seatTokenBefore = controller.seatToken;

    await controller.resumeRoom(
      code: 'ANOTHR',
      seat: 3,
      seatToken: 'tok-should-not-land-either',
    );

    expect(
      connector.calls.length,
      callsBefore,
      reason:
          'R2: phase failed with a room still held must make resumeRoom '
          'a no-op that opens no connection; the room clause, not the '
          'phase clause, is what must be doing the rejecting here',
    );
    expect(
      notifyCount,
      0,
      reason:
          'R2: resumeRoom rejected by the room clause while failed must '
          'not notify',
    );
    expect(
      controller.room,
      same(roomBefore),
      reason: 'R2: the rejected call must change nothing about the held room',
    );
    expect(
      controller.room?.code,
      'K7M2QP',
      reason:
          'the room from the joinRoom that is still held must remain the '
          'joined one, not the resumeRoom argument code ANOTHR',
    );
    expect(controller.seat, seatBefore);
    expect(
      controller.seat,
      0,
      reason:
          'seat must remain the joinRoom seat, not the resumeRoom '
          'argument seat 3',
    );
    expect(controller.seatToken, seatTokenBefore);
    expect(
      controller.seatToken,
      'tok-join-0',
      reason:
          'seatToken must remain the joinRoom token, not the resumeRoom '
          "argument token 'tok-should-not-land-either'",
    );
  });

  // --- R-5 open failure (R3). ------------------------------------------------
  test('R-5 open failure (R3): the connector rejects, resumeRoom lands failed '
      "/ 'transport' with room, seat and seatToken all null", () async {
    final _Connector connector = _Connector();
    connector.rejectNextWith(Exception('R-5 connector refuses'));
    final RoomController controller = _newController(connector);
    addTearDown(controller.dispose);

    await controller.resumeRoom(code: 'K7M2QP', seat: 2, seatToken: 'tok-r5');

    expect(controller.phase, RoomPhase.failed);
    expect(controller.errorCode, 'transport');
    expect(controller.room, isNull);
    expect(controller.seat, isNull);
    expect(controller.seatToken, isNull);
  });

  // --- R-6 refusals (R5), table-driven. ---------------------------------
  for (final String code in <String>['BAD_SEAT_TOKEN', 'NO_SUCH_ROOM']) {
    test('R-6 refusals (R5): resume answered $code lands failed / $code '
        'verbatim, room/seat/seatToken null, and no automatic sequence ever '
        'starts (G3)', () {
      fakeAsync((FakeAsync async) {
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = _newController(
          connector,
          autoReconnectDelays: _delays,
        );

        unawaited(
          controller.resumeRoom(
            code: 'K7M2QP',
            seat: 2,
            seatToken: 'tok-r6-$code',
          ),
        );
        async.flushMicrotasks();
        final String id = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(
            type: 'error',
            re: id,
            data: <String, Object?>{'code': code, 'message': 'refused'},
          ),
        );
        async.flushMicrotasks();

        expect(controller.phase, RoomPhase.failed);
        expect(
          controller.errorCode,
          code,
          reason: 'R5: the server code must arrive in errorCode verbatim',
        );
        expect(controller.room, isNull);
        expect(controller.seat, isNull);
        expect(controller.seatToken, isNull);

        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();

        expect(
          controller.autoReconnectPending,
          isFalse,
          reason:
              'G3: resumeRoom failing must never start an automatic '
              'sequence, however long a minute of fake time elapses',
        );
        expect(
          connector.calls.length,
          1,
          reason:
              'G3: no automatic sequence means the connector must never '
              'be called a second time',
        );

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  }

  // --- R-7 retry from failed. -------------------------------------------
  test(
    'R-7 retry from failed: after an open failure, a second resumeRoom is '
    'accepted, succeeds, and lands connected with the argument\'s seat',
    () async {
      final _Connector connector = _Connector();
      connector.rejectNextWith(Exception('R-7 first attempt refused'));
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      await controller.resumeRoom(
        code: 'K7M2QP',
        seat: 2,
        seatToken: 'tok-r7-first',
      );
      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: the first resumeRoom must have failed '
            'before this test retries it',
      );
      expect(controller.errorCode, 'transport');

      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);

      final Future<void> second = controller.resumeRoom(
        code: 'K7M2QP',
        seat: 3,
        seatToken: 'tok-r7-second',
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(code: 'K7M2QP', hostSeat: 0, seq: 1),
        ),
      );
      await second;

      expect(controller.phase, RoomPhase.connected);
      expect(controller.seat, 3);
      expect(controller.seatToken, 'tok-r7-second');
      expect(controller.errorCode, isNull);
    },
  );

  // --- R-8 then a drop (R4 equivalence). ---------------------------------
  test('R-8 then a drop (R4 equivalence): after resumeRoom succeeds, a drop '
      'starts an automatic sequence whose resume carries the same code and '
      'seat token', () {
    fakeAsync((FakeAsync async) {
      final _Connector connector = _Connector();
      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      final RoomController controller = _newController(
        connector,
        autoReconnectDelays: _delays,
      );

      unawaited(
        controller.resumeRoom(code: 'K7M2QP', seat: 2, seatToken: 'tok-r8'),
      );
      async.flushMicrotasks();
      final String id1 = _idOf(transport1.sentRaw.last);
      transport1.pushText(
        _frame(
          type: 'room',
          re: id1,
          data: _roomJson(code: 'K7M2QP', hostSeat: 0, seq: 1),
        ),
      );
      async.flushMicrotasks();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: resumeRoom must have succeeded before '
            'this test drops the connection',
      );

      final int callsBefore = connector.calls.length;
      transport1.endFromFarSide();
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'R4: a controller that got its seat through resumeRoom must '
            'be eligible for automatic reconnection exactly like one '
            'that got it through joinRoom (C4/C5)',
      );

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      async.elapse(_delays[0]);
      async.flushMicrotasks();

      expect(
        connector.calls.length,
        callsBefore + 1,
        reason: 'C7: exactly one new attempt at delays[0]',
      );
      final Map<String, Object?> sent = _decode(transport2.sentRaw.first);
      expect(sent['t'], 'resume');
      expect(
        sent['d'],
        equals(<String, Object?>{'code': 'K7M2QP', 'seat_token': 'tok-r8'}),
        reason:
            'R4: the automatic attempt\'s resume must carry the same '
            'code and seat token resumeRoom was given, got d=${sent['d']}',
      );

      final String id2 = sent['id']! as String;
      transport2.pushText(
        _frame(
          type: 'room',
          re: id2,
          data: _roomJson(code: 'K7M2QP', hostSeat: 0, seq: 2),
        ),
      );
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.connected);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- R-9 then reconnect() (R4 equivalence). -----------------------------
  test('R-9 then reconnect() (R4 equivalence): after resumeRoom succeeds and a '
      'drop, a manual reconnect() sends resume with the same code and seat '
      'token', () {
    fakeAsync((FakeAsync async) {
      final _Connector connector = _Connector();
      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      final RoomController controller = _newController(connector);

      unawaited(
        controller.resumeRoom(code: 'K7M2QP', seat: 1, seatToken: 'tok-r9'),
      );
      async.flushMicrotasks();
      final String id1 = _idOf(transport1.sentRaw.last);
      transport1.pushText(
        _frame(
          type: 'room',
          re: id1,
          data: _roomJson(code: 'K7M2QP', hostSeat: 0, seq: 1),
        ),
      );
      async.flushMicrotasks();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: resumeRoom must have succeeded before '
            'this test drops the connection',
      );

      transport1.endFromFarSide();
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C1: empty autoReconnectDelays means no automatic timer is '
            'ever armed',
      );

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      unawaited(controller.reconnect());
      async.flushMicrotasks();

      final Map<String, Object?> sent = _decode(transport2.sentRaw.first);
      expect(sent['t'], 'resume');
      expect(
        sent['d'],
        equals(<String, Object?>{'code': 'K7M2QP', 'seat_token': 'tok-r9'}),
        reason:
            "R4: reconnect()'s resume must carry the same code and seat "
            "token resumeRoom was given, got d=${sent['d']}",
      );

      final String id2 = sent['id']! as String;
      transport2.pushText(
        _frame(
          type: 'room',
          re: id2,
          data: _roomJson(code: 'K7M2QP', hostSeat: 0, seq: 2),
        ),
      );
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.connected);

      controller.dispose();
      async.flushMicrotasks();
    });
  });
}

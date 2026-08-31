// Conformance tests for the game-state reducer that docs/ludo/orders/090
// adds to lib/src/net/room_controller.dart, written from docs/PROTOCOL.md
// and from the frozen declaration block shared with that order, against no
// implementation of room_controller.dart the author of this file has read.
// A second worker is writing the reducer, blind, from the same frozen
// block, at the same time.
//
// Every clause below is labelled with the paragraph of the declaration it
// proves: D1 (vocabulary), D2 (the order of checks), D3 (rules shared by
// every D4 row), D4 (the reducer itself, frame by frame), D5 (the resync)
// and D6 (sixes is never derived). Assertions are made only on the public
// surface: controller.room, controller.hasDesynced, controller.phase,
// controller.frames, and the bytes in FakeTransport.sentRaw.
//
// The three lobby deltas' own reduction rules (player_joined, player_left,
// presence) are proved in room_controller_test.dart and are out of scope
// here. What is new about them in this file is only D2 step 6: a gap no
// longer applies the delta, it triggers a resync instead.

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
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
  return 'game-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers ------------------------------------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

int _resumeCount(FakeTransport transport) => transport.sentRaw
    .where((String raw) => _decode(raw)['t'] == 'resume')
    .length;

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
  String name = 'Sam',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
  String? clientSeed,
  String? seedOrigin,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': clientSeed,
  'seed_origin': seedOrigin,
};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
  int? value,
  List<int>? legal,
  int? sixes,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'sixes': ?sixes,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
  int turnSeconds = 45,
  String? gameId,
  String? clientSeeds,
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
    'turn_seconds': turnSeconds,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': gameId,
  'client_seeds': clientSeeds,
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double that records and queues ----------

/// Hands out queued [FakeTransport]s, one per call, in order. Records every
/// url it was called with so a test can assert how many times (and prove no
/// more than that) a connection was ever attempted. [rejectNextWith] makes
/// exactly the next call reject instead, to build a phase=failed fixture for
/// the G1/G2 no-op tests without ever handing out a transport at all.
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

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

/// Builds a controller, drives it through a successful createRoom(), and
/// returns it already in phase connected with room, seat and seatToken all
/// populated, at [seq] with [seats] (defaulting to a single occupied seat 0).
Future<(RoomController, FakeTransport, _Connector)> _connectedController({
  int hostSeat = 0,
  String code = 'K7M2QP',
  int players = 4,
  String state = 'LOBBY',
  int turnSeconds = 45,
  String? gameId,
  String? clientSeeds,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);

  final Future<void> future = controller.createRoom(
    name: 'Sam',
    players: players,
  );
  await pumpEventQueue();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': hostSeat, 'seat_token': 'tok-$hostSeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        code: code,
        players: players,
        hostSeat: hostSeat,
        state: state,
        turnSeconds: turnSeconds,
        gameId: gameId,
        clientSeeds: clientSeeds,
        seats: seats,
        turn: turn,
        winner: winner,
        seq: seq,
      ),
    ),
  );
  await future;
  return (controller, transport, connector);
}

/// Pushes [type]/[data] on [transport] and drains the event queue.
Future<void> _push(
  FakeTransport transport,
  String type,
  Map<String, Object?> data,
) async {
  transport.pushText(_frame(type: type, data: data));
  await pumpEventQueue();
}

/// The synchronous twin of [_connectedController], for use inside a
/// `fakeAsync` body where `await` cannot be used: drives the same
/// createRoom() handshake, but advances the zone with [async.flushMicrotasks]
/// instead of awaiting futures. Needed for the F1 test that has to let a real
/// ten-second request timeout elapse without an actual wall-clock wait.
(RoomController, FakeTransport, _Connector) _connectedControllerInFakeAsync(
  FakeAsync async, {
  int seq = 1,
  List<Map<String, Object?>>? seats,
}) {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);

  unawaitedFuture(controller.createRoom(name: 'Sam', players: 4));
  async.flushMicrotasks();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(seq: seq, seats: seats),
    ),
  );
  async.flushMicrotasks();
  return (controller, transport, connector);
}

/// Asserts that pushing [type]/[data] on the current, already-connected
/// controller changes nothing: room stays the same object, hasDesynced
/// stays false, no resume is sent, nothing notifies, and the frame still
/// reaches frames. Used for every "malformed" case (D2 step 4) and every
/// "seat absent" case (D3), both of which land on the same observable
/// outcome from a black-box view except for what advances seq, which each
/// call site checks for itself.
Future<void> _expectNoOp(
  RoomController controller,
  FakeTransport transport,
  String type,
  Map<String, Object?> data, {
  required String reason,
}) async {
  final Object? roomBefore = controller.room;
  final bool desyncBefore = controller.hasDesynced;
  final int resumesBefore = _resumeCount(transport);
  int notifyCount = 0;
  void listener() => notifyCount++;
  controller.addListener(listener);
  final List<Frame> log = <Frame>[];
  final sub = controller.frames.listen(log.add);

  await _push(transport, type, data);

  expect(identical(controller.room, roomBefore), isTrue, reason: reason);
  expect(
    controller.hasDesynced,
    desyncBefore,
    reason: '$reason (hasDesynced must not change)',
  );
  expect(
    _resumeCount(transport),
    resumesBefore,
    reason: '$reason (must not attempt a resync)',
  );
  expect(notifyCount, 0, reason: '$reason (must not notify)');
  expect(
    log.map((Frame f) => f.type),
    contains(type),
    reason: '$reason (must still reach frames)',
  );

  controller.removeListener(listener);
  await sub.cancel();
}

// ===========================================================================
// Declaration G. roll() and RoomController.move(int) do not exist on the
// branch this file is written against: a second worker is adding them, blind,
// from the identical frozen block. Calling controller.roll() or
// controller.move(n) directly here would fail `flutter analyze` with
// undefined_method and stop the whole file from compiling, hiding the D1
// through D6 coverage above it.
//
// Order 100 wrote these tests blind, before RoomController had roll() or
// move(). To keep the file analysing on that base it carried a small
// extension forwarding both names through `dynamic`, so the cases failed at
// runtime with NoSuchMethodError instead of failing to compile. Order 099
// landed the real methods, Dart resolves a declared instance member ahead of
// an extension member of the same name, and the extension became dead code
// the analyzer flagged as unused_element. Removed here by the master on
// merging the pair. Every case below now calls the real methods, and every
// one of them passes against an implementation this file's author never read.

// --- phase fixtures shared by G1 clause 1's and G2 clause 3's four phases --

/// Phase idle: no connection has ever been attempted. There is no transport
/// at all, so the "wire" a no-op is checked against is [_Connector.calls]
/// staying empty rather than any [FakeTransport].
Future<(RoomController, FakeTransport?, _Connector)> _idlePhaseFixture() async {
  final _Connector connector = _Connector();
  final RoomController controller = _newController(connector);
  expect(controller.phase, RoomPhase.idle, reason: 'fixture is broken');
  return (controller, null, connector);
}

/// Phase connecting: createRoom() is in flight and has not been answered.
Future<(RoomController, FakeTransport?, _Connector)>
_connectingPhaseFixture() async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  unawaitedFuture(controller.createRoom(name: 'Sam', players: 4));
  expect(controller.phase, RoomPhase.connecting, reason: 'fixture is broken');
  return (controller, transport, connector);
}

/// Finishes the createRoom() a connecting-phase fixture started, so it does
/// not leak a pending request/timer into a later test (standing lesson 9).
Future<void> _finishConnectingFixture(FakeTransport transport) async {
  final String id = _idOf(transport.sentRaw.first);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: _roomJson(seq: 1)));
  await pumpEventQueue();
}

/// Phase closed: the transport died on its own, with nothing outstanding.
Future<(RoomController, FakeTransport?, _Connector)>
_closedPhaseFixture() async {
  final (
    RoomController controller,
    FakeTransport transport,
    _Connector connector,
  ) = await _connectedController(
    seq: 1,
  );
  transport.endFromFarSide();
  await pumpEventQueue();
  expect(controller.phase, RoomPhase.closed, reason: 'fixture is broken');
  return (controller, transport, connector);
}

/// Phase failed: the connector itself rejected, so no transport was ever
/// handed out at all.
Future<(RoomController, FakeTransport?, _Connector)>
_failedPhaseFixture() async {
  final _Connector connector = _Connector();
  connector.rejectNextWith(Exception('boom'));
  final RoomController controller = _newController(connector);
  await controller.createRoom(name: 'Sam', players: 4);
  expect(controller.phase, RoomPhase.failed, reason: 'fixture is broken');
  return (controller, null, connector);
}

/// Asserts that calling [action] on [controller] was a silent no-op: no new
/// bytes on [transport]'s wire when a transport exists at all, no new
/// connection attempt through [connector] either way, no listener fired, and
/// the call itself does not throw. The one assertion this cannot make in
/// phases idle and failed is "the wire is empty", because neither phase ever
/// had a wire to begin with; [connector.calls] not growing is the equivalent
/// guarantee for those two, since it proves no transport was opened to send
/// on regardless.
Future<void> _expectGameIntentionNoOp(
  RoomController controller,
  _Connector connector, {
  FakeTransport? transport,
  required Future<void> Function() action,
  required String reason,
}) async {
  final RoomPhase phaseBefore = controller.phase;
  final int sentBefore = transport?.sentRaw.length ?? 0;
  final int callsBefore = connector.calls.length;
  int notifyCount = 0;
  void listener() => notifyCount++;
  controller.addListener(listener);

  await expectLater(action(), completes, reason: '$reason (must not throw)');

  expect(controller.phase, phaseBefore, reason: reason);
  expect(
    transport?.sentRaw.length ?? 0,
    sentBefore,
    reason: '$reason (the wire must stay exactly as it was)',
  );
  expect(
    connector.calls.length,
    callsBefore,
    reason: '$reason (must not open a new connection)',
  );
  expect(notifyCount, 0, reason: '$reason (must not notify)');
  controller.removeListener(listener);
}

void main() {
  // ======================================================================
  // D2. The order of checks.
  // ======================================================================
  group('D2 step 1: frames is unconditional and first', () {
    test(
      'a state-changing push this reducer ends up ignoring as malformed '
      'still reaches frames, exactly once, before anything else is decided',
      () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController(seq: 1);
        addTearDown(controller.dispose);
        final List<Frame> log = <Frame>[];
        controller.frames.listen(log.add);

        // Missing 'value', required for rolled: malformed under D2 step 4.
        await _push(transport, 'rolled', <String, Object?>{
          'seat': 0,
          'legal': <int>[0],
          'deadline_ms': 1000,
          'k': 1,
          'seq': 2,
        });

        expect(
          log.where((Frame f) => f.type == 'rolled'),
          hasLength(1),
          reason:
              'expected the malformed rolled frame to reach frames exactly '
              'once regardless of the reducer dropping it; got '
              '${log.map((f) => f.type).toList()}',
        );
      },
    );
  });

  group('D2 step 2: a resync in flight makes every push inert', () {
    test('a second, contiguous push arriving while a resync is outstanding '
        'changes nothing, notifies nothing, and does not itself trigger a '
        'second resume; only the frame reaches frames', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);

      // First: a gap, which starts a resync (D5) and is not resolved yet.
      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 50,
      });
      expect(controller.hasDesynced, isTrue);
      expect(
        _resumeCount(transport),
        1,
        reason: 'fixture is broken: the initial gap must have started a resync',
      );
      final Object? roomDuringResync = controller.room;

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final List<Frame> log = <Frame>[];
      controller.frames.listen(log.add);

      // Second: contiguous against room.seq (still 1, since the gap was
      // never applied), which would ordinarily be step 7's happy path.
      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': true,
        'seq': 2,
      });

      expect(
        identical(controller.room, roomDuringResync),
        isTrue,
        reason:
            'a frame arriving while a resync is in flight must change '
            'nothing even though it is contiguous (D2 step 2 precedes '
            'step 7)',
      );
      expect(controller.room!.seq, 1, reason: 'seq must not have advanced');
      expect(
        _resumeCount(transport),
        1,
        reason: 'a second resume must not have been sent',
      );
      expect(notifyCount, 0);
      expect(log.map((f) => f.type), contains('presence'));
    });
  });

  group('D2 step 3: room == null', () {
    test('a state-changing push arriving before any room snapshot has ever '
        'been received changes nothing but still reaches frames', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      final List<Frame> log = <Frame>[];
      controller.frames.listen(log.add);

      final Future<void> createFuture = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      await pumpEventQueue();
      expect(controller.room, isNull, reason: 'fixture is broken');

      // Attached only after createRoom's own connecting-phase notify, so it
      // counts only what the push below does.
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': true,
        'seq': 2,
      });

      expect(controller.room, isNull);
      expect(notifyCount, 0);
      expect(log.map((f) => f.type), contains('presence'));

      // Finish the createRoom() the fixture started, so it does not leak
      // a pending timer/request into a later test.
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok'},
        ),
      );
      transport.pushText(_frame(type: 'room', re: id, data: _roomJson(seq: 1)));
      await createFuture;
    });
  });

  group('D2 step 4: malformed', () {
    test('a frame with no int seq at all is malformed', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      await _expectNoOp(controller, transport, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      }, reason: 'a frame with no seq field at all must be malformed');
    });

    test('a frame whose seq is a string, not an int, is malformed', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      await _expectNoOp(controller, transport, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
        'seq': '2',
      }, reason: 'a frame whose seq is a String must be malformed');
    });
  });

  group('D2 precedence', () {
    test('a frame that is both malformed and gapped takes the malformed path: '
        'no resync is attempted and hasDesynced stays false (step 4 before '
        'step 6)', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);

      // seq 999 against room.seq 1 is a gap; 'value' missing makes it
      // also malformed for rolled.
      await _expectNoOp(
        controller,
        transport,
        'rolled',
        <String, Object?>{
          'seat': 0,
          'legal': <int>[0],
          'deadline_ms': 1000,
          'k': 1,
          'seq': 999,
        },
        reason:
            'a frame that is both malformed and gapped must take the '
            'malformed path and must not set hasDesynced or attempt a '
            'resync',
      );
    });

    test('a room reply carrying re that is also gapped takes the ignore path: '
        'no resync is attempted and hasDesynced stays false (step 5 before '
        'step 6)', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      final Object? roomBefore = controller.room;
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final List<Frame> log = <Frame>[];
      controller.frames.listen(log.add);

      // re is set (as if answering some earlier request this test does
      // not care about matching) and seq 999 is a gap against room.seq 1.
      transport.pushText(
        _frame(
          type: 'room',
          re: 'some-unrelated-id-00000000',
          data: _roomJson(seq: 999),
        ),
      );
      await pumpEventQueue();

      expect(identical(controller.room, roomBefore), isTrue);
      expect(controller.hasDesynced, isFalse);
      expect(_resumeCount(transport), 0);
      expect(notifyCount, 0);
      expect(log.map((f) => f.type), contains('room'));
    });
  });

  // ======================================================================
  // D3. Rules that apply to every reducer rule in D4.
  // ======================================================================
  group('D3: the absent-seat rule', () {
    Future<(RoomController, FakeTransport)> setup() async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
      );
      return (controller, transport);
    }

    test('seat_seed naming a seat absent from room.seats is ignored entirely: '
        'no state change, no seq advance, no notify', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      await _expectNoOp(controller, transport, 'seat_seed', <String, Object?>{
        'seat': 3,
        'client_seed': 'x',
        'origin': 'player',
        'seq': 2,
      }, reason: 'seat_seed for an absent seat must be ignored entirely');
    });

    test(
      'rolled naming a seat absent from room.seats is ignored entirely',
      () async {
        final (RoomController controller, FakeTransport transport) =
            await setup();
        addTearDown(controller.dispose);
        await _expectNoOp(controller, transport, 'rolled', <String, Object?>{
          'seat': 3,
          'value': 4,
          'legal': <int>[0],
          'deadline_ms': 1000,
          'k': 1,
          'seq': 2,
        }, reason: 'rolled for an absent seat must be ignored entirely');
      },
    );

    test(
      'turn naming a seat absent from room.seats is ignored entirely',
      () async {
        final (RoomController controller, FakeTransport transport) =
            await setup();
        addTearDown(controller.dispose);
        await _expectNoOp(controller, transport, 'turn', <String, Object?>{
          'seat': 3,
          'deadline_ms': 1000,
          'seq': 2,
        }, reason: 'turn for an absent seat must be ignored entirely');
      },
    );

    test(
      'turn_passed naming a seat absent from room.seats is ignored entirely',
      () async {
        final (RoomController controller, FakeTransport transport) =
            await setup();
        addTearDown(controller.dispose);
        await _expectNoOp(
          controller,
          transport,
          'turn_passed',
          <String, Object?>{'seat': 3, 'reason': 'no_legal_move', 'seq': 2},
          reason: 'turn_passed for an absent seat must be ignored entirely',
        );
      },
    );

    test("moved naming a moving seat absent from room.seats is ignored "
        'entirely, not just the captured entries', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      await _expectNoOp(controller, transport, 'moved', <String, Object?>{
        'seat': 3,
        'token': 0,
        'from': -1,
        'to': 0,
        'captured': <Object?>[],
        'extra_roll': false,
        'seq': 2,
      }, reason: "moved for an absent moving seat must be ignored entirely");
    });

    test('moved captured entry naming an absent seat is skipped, but the rest '
        'of the frame still applies -- the one per-entry exception to the '
        'whole-frame absent-seat rule', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
      );
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      await _push(transport, 'moved', <String, Object?>{
        'seat': 0,
        'token': 2,
        'from': 5,
        'to': 9,
        'captured': <Map<String, Object?>>[
          <String, Object?>{'seat': 1, 'token': 1},
          <String, Object?>{'seat': 3, 'token': 0}, // seat 3 does not exist
        ],
        'extra_roll': false,
        'seq': 2,
      });

      final seat0 = controller.room!.seats.firstWhere((s) => s.seat == 0);
      final seat1 = controller.room!.seats.firstWhere((s) => s.seat == 1);
      expect(
        seat0.tokens[2],
        9,
        reason: 'the moving seat must still be applied',
      );
      expect(
        seat1.tokens[1],
        -1,
        reason: 'the valid captured entry must still be applied',
      );
      expect(
        controller.room!.seq,
        2,
        reason:
            'a captured entry naming an absent seat must not turn the '
            'whole frame into a no-op: seq must still advance',
      );
      expect(notifyCount, greaterThan(0));
    });

    // game_started and game_over are outside the whole-frame absent-seat
    // rule above: neither indexes into room.seats to modify one seat. Both
    // set room-level fields only -- state, gameId, clientSeeds, winner and
    // the room's own turn -- so a stale seats list that happens to lack the
    // named seat must not turn either frame into a no-op. Order 095's
    // narrowing of the rule, proved here rather than assumed.
    test('game_started whose turn names a seat absent from room.seats is '
        'applied in full: state, gameId, clientSeeds and a fresh turn are all '
        'set, and seq advances', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        turnSeconds: 90,
        seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
      );
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      await _push(transport, 'game_started', <String, Object?>{
        'turn': 3, // seat 3 is absent from room.seats above
        'game_id': 'c' * 16,
        'client_seeds': '0:seed',
        'seq': 2,
      });

      expect(controller.room!.state.toString(), contains('playing'));
      expect(controller.room!.gameId, 'c' * 16);
      expect(controller.room!.clientSeeds, '0:seed');
      final turn = controller.room!.turn;
      expect(
        turn,
        isNotNull,
        reason:
            'game_started must set a fresh turn even for a seat '
            'absent from room.seats',
      );
      expect(turn!.seat, 3);
      expect(turn.phase.toString(), contains('awaitRoll'));
      expect(
        turn.deadlineMs,
        90000,
        reason:
            'deadlineMs must be rules.turnSeconds (90) * 1000, not '
            'the 45000 default and not 0',
      );
      expect(turn.k, 0);
      expect(turn.value, isNull);
      expect(turn.legal, isNull);
      expect(turn.sixes, isNull);
      expect(
        controller.room!.seq,
        2,
        reason:
            'a seat absent from room.seats must not turn '
            'game_started into a no-op: seq must still advance',
      );
      expect(notifyCount, greaterThan(0));
    });

    test('game_over whose winner names a seat absent from room.seats is '
        'applied in full: state and winner are set, a non-null turn moves to '
        'phase finished, and seq advances', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        state: 'PLAYING',
        seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
        turn: _turnJson(
          seat: 1,
          phase: 'await_move',
          deadlineMs: 800,
          k: 12,
          value: 5,
          legal: <int>[3],
        ),
      );
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      await _push(transport, 'game_over', <String, Object?>{
        'winner': 3, // seat 3 is absent from room.seats above
        'verify_url': 'https://provefair.app/v/abc',
        'seq': 2,
      });

      expect(controller.room!.state.toString(), contains('finished'));
      expect(
        controller.room!.winner,
        3,
        reason:
            'winner must be set even for a seat absent from '
            'room.seats',
      );
      final turn = controller.room!.turn!;
      expect(turn.phase.toString(), contains('finished'));
      expect(turn.value, isNull);
      expect(turn.legal, isNull);
      expect(turn.sixes, isNull);
      expect(turn.seat, 1, reason: 'seat is kept, not cleared');
      expect(turn.deadlineMs, 800, reason: 'deadlineMs is kept');
      expect(turn.k, 12, reason: 'k is kept');
      expect(
        controller.room!.seq,
        2,
        reason:
            'a seat absent from room.seats must not turn game_over '
            'into a no-op: seq must still advance',
      );
      expect(notifyCount, greaterThan(0));
    });
  });

  // ======================================================================
  // D2 step 6 (change from today): a gap no longer applies the delta, for
  // every state-changing type, lobby deltas included. This is also where
  // D8's superseded test would have lived; the replacement lives in
  // room_controller_test.dart per that order's instruction, and this group
  // proves the same rule for the remaining, newly-reduced types.
  // ======================================================================
  group('D2 step 6: a gap resyncs instead of applying the delta', () {
    for (final String type in <String>[
      'player_joined',
      'player_left',
      'presence',
    ]) {
      test('$type at a seq that is a gap does not apply, sets hasDesynced, '
          'and attempts exactly one resync', () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seq: 1,
          seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
        );
        addTearDown(controller.dispose);
        final Map<String, Object?> data = switch (type) {
          'player_joined' => <String, Object?>{
            'seat': 1,
            'name': 'Bob',
            'seq': 40,
          },
          'player_left' => <String, Object?>{'seat': 0, 'seq': 40},
          'presence' => <String, Object?>{
            'seat': 0,
            'connected': false,
            'seq': 40,
          },
          _ => throw StateError('unreachable'),
        };

        await _push(transport, type, data);

        expect(controller.hasDesynced, isTrue);
        expect(
          controller.room!.seats.length,
          1,
          reason: '$type must not have been applied on a gap',
        );
        expect(
          controller.room!.seq,
          1,
          reason: 'seq must not advance on a gap',
        );
        expect(_resumeCount(transport), 1);
      });
    }
  });

  // ======================================================================
  // D4. The reducer, frame by frame. Malformed-field coverage.
  // ======================================================================
  group('D4 required fields: wrong type or missing leaves state untouched', () {
    Future<(RoomController, FakeTransport)> setup({
      List<Map<String, Object?>>? seats,
    }) async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        seats:
            seats ??
            <Map<String, Object?>>[
              _seatJson(0, name: 'Sam'),
              _seatJson(1, name: 'Bob'),
            ],
      );
      return (controller, transport);
    }

    Future<void> checkField(
      RoomController controller,
      FakeTransport transport,
      String type,
      Map<String, Object?> valid,
      String field,
      Object? wrongTyped,
    ) async {
      final Map<String, Object?> withWrongType = Map<String, Object?>.from(
        valid,
      )..[field] = wrongTyped;
      await _expectNoOp(
        controller,
        transport,
        type,
        withWrongType,
        reason: '$type.$field of the wrong runtime type must be malformed',
      );

      final Map<String, Object?> withMissing = Map<String, Object?>.from(valid)
        ..remove(field);
      await _expectNoOp(
        controller,
        transport,
        type,
        withMissing,
        reason: '$type.$field missing entirely must be malformed',
      );
    }

    test('room: an undecodable snapshot is treated as malformed, not '
        'rethrown', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      final Map<String, Object?> bad = _roomJson(seq: 2)..remove('code');
      await _expectNoOp(
        controller,
        transport,
        'room',
        bad,
        reason:
            'a room push whose snapshot fails to decode must be treated as '
            'malformed under D2 step 4, caught, not rethrown',
      );
    });

    test('seat_seed: seat, client_seed, origin', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      final Map<String, Object?> valid = <String, Object?>{
        'seat': 0,
        'client_seed': 'abc',
        'origin': 'player',
        'seq': 2,
      };
      await checkField(
        controller,
        transport,
        'seat_seed',
        valid,
        'seat',
        'zero',
      );
      await checkField(
        controller,
        transport,
        'seat_seed',
        valid,
        'client_seed',
        123,
      );
      await checkField(controller, transport, 'seat_seed', valid, 'origin', 7);
    });

    test('seat_seed: origin outside {player, server} is malformed, not just '
        'the wrong runtime type', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      await _expectNoOp(controller, transport, 'seat_seed', <String, Object?>{
        'seat': 0,
        'client_seed': 'abc',
        'origin': 'robot',
        'seq': 2,
      }, reason: 'origin must be exactly "player" or "server"');
    });

    test('game_started: turn, game_id, client_seeds', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      final Map<String, Object?> valid = <String, Object?>{
        'turn': 0,
        'game_id': 'a' * 16,
        'client_seeds': '0:seed|1:seed',
        'seq': 2,
      };
      await checkField(
        controller,
        transport,
        'game_started',
        valid,
        'turn',
        'zero',
      );
      await checkField(
        controller,
        transport,
        'game_started',
        valid,
        'game_id',
        7,
      );
      await checkField(
        controller,
        transport,
        'game_started',
        valid,
        'client_seeds',
        7,
      );
    });

    test('turn: seat, deadline_ms', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      final Map<String, Object?> valid = <String, Object?>{
        'seat': 0,
        'deadline_ms': 1000,
        'seq': 2,
      };
      await checkField(controller, transport, 'turn', valid, 'seat', 'zero');
      await checkField(
        controller,
        transport,
        'turn',
        valid,
        'deadline_ms',
        'soon',
      );
    });

    test('rolled: seat, value, legal, deadline_ms, k', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      final Map<String, Object?> valid = <String, Object?>{
        'seat': 0,
        'value': 4,
        'legal': <int>[0, 1],
        'deadline_ms': 1000,
        'k': 1,
        'reveal': 'b' * 64,
        'seq': 2,
      };
      await checkField(controller, transport, 'rolled', valid, 'seat', 'zero');
      await checkField(controller, transport, 'rolled', valid, 'value', 'six');
      await checkField(
        controller,
        transport,
        'rolled',
        valid,
        'deadline_ms',
        'soon',
      );
      await checkField(controller, transport, 'rolled', valid, 'k', 'one');

      // legal wrong shape: not a list at all.
      await _expectNoOp(
        controller,
        transport,
        'rolled',
        Map<String, Object?>.from(valid)..['legal'] = 'not-a-list',
        reason: 'rolled.legal that is not a list must be malformed',
      );
      // legal wrong shape: a list with a non-int element.
      await _expectNoOp(
        controller,
        transport,
        'rolled',
        Map<String, Object?>.from(valid)..['legal'] = <Object?>[0, 'bad'],
        reason: 'rolled.legal containing a non-int element must be malformed',
      );
      // legal missing entirely.
      await _expectNoOp(
        controller,
        transport,
        'rolled',
        Map<String, Object?>.from(valid)..remove('legal'),
        reason: 'rolled.legal missing entirely must be malformed',
      );
    });

    test('moved: seat, token, from, to, extra_roll, captured', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      final Map<String, Object?> valid = <String, Object?>{
        'seat': 0,
        'token': 1,
        'from': 3,
        'to': 4,
        'captured': <Object?>[],
        'extra_roll': false,
        'seq': 2,
      };
      await checkField(controller, transport, 'moved', valid, 'seat', 'zero');
      await checkField(controller, transport, 'moved', valid, 'token', 'one');
      await checkField(controller, transport, 'moved', valid, 'from', 'x');
      await checkField(controller, transport, 'moved', valid, 'to', 'x');
      await checkField(
        controller,
        transport,
        'moved',
        valid,
        'extra_roll',
        'yes',
      );

      // captured wrong shape: not a list.
      await _expectNoOp(
        controller,
        transport,
        'moved',
        Map<String, Object?>.from(valid)..['captured'] = 'not-a-list',
        reason: 'moved.captured that is not a list must be malformed',
      );
      // captured wrong shape: an element missing 'token'.
      await _expectNoOp(
        controller,
        transport,
        'moved',
        Map<String, Object?>.from(valid)
          ..['captured'] = <Object?>[
            <String, Object?>{'seat': 1},
          ],
        reason:
            'a captured entry missing token must make the whole frame '
            'malformed',
      );
      // captured wrong shape: an element whose seat is the wrong type.
      await _expectNoOp(
        controller,
        transport,
        'moved',
        Map<String, Object?>.from(valid)
          ..['captured'] = <Object?>[
            <String, Object?>{'seat': 'one', 'token': 0},
          ],
        reason:
            'a captured entry whose seat is the wrong type must make the '
            'whole frame malformed',
      );
    });

    test('turn_passed: seat, reason', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      final Map<String, Object?> valid = <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
        'seq': 2,
      };
      await checkField(
        controller,
        transport,
        'turn_passed',
        valid,
        'seat',
        'zero',
      );
      await checkField(
        controller,
        transport,
        'turn_passed',
        valid,
        'reason',
        7,
      );
    });

    test('turn_passed: reason outside {no_legal_move, three_sixes} is '
        'malformed', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      await _expectNoOp(controller, transport, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'boredom',
        'seq': 2,
      }, reason: 'reason must be exactly no_legal_move or three_sixes');
    });

    test('game_over: winner, verify_url', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      final Map<String, Object?> valid = <String, Object?>{
        'winner': 0,
        'verify_url': 'https://provefair.app/v/abc',
        'seq': 2,
      };
      await checkField(
        controller,
        transport,
        'game_over',
        valid,
        'winner',
        'x',
      );
      await checkField(
        controller,
        transport,
        'game_over',
        valid,
        'verify_url',
        7,
      );
    });
  });

  // ======================================================================
  // D4. Positive reducer behaviour, per row.
  // ======================================================================
  group('D4: room push (re null)', () {
    test('replaces room wholly, clears hasDesynced, notifies', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      // Get hasDesynced to true first via an unrelated gap.
      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 40,
      });
      expect(controller.hasDesynced, isTrue);
      // Resolve that resync so a second gap-triggered resync is not
      // still in flight and masking this test (D2 step 2).
      final Map<String, Object?> sentResume = _decode(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'room',
          re: sentResume['id']! as String,
          data: _roomJson(seq: 40),
        ),
      );
      await pumpEventQueue();
      expect(controller.hasDesynced, isFalse);

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      await _push(
        transport,
        'room',
        _roomJson(code: 'ZZZZZZ', players: 3, seq: 41),
      );

      expect(controller.room!.code, 'ZZZZZZ');
      expect(controller.room!.players, 3);
      expect(controller.room!.seq, 41);
      expect(controller.hasDesynced, isFalse);
      expect(notifyCount, greaterThan(0));
    });
  });

  group('D4: seat_seed', () {
    for (final String origin in <String>['player', 'server']) {
      test("sets clientSeed and seedOrigin ($origin) on the named seat and "
          'nothing else', () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seq: 1,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam'),
            _seatJson(1, name: 'Bob'),
          ],
        );
        addTearDown(controller.dispose);
        int notifyCount = 0;
        controller.addListener(() => notifyCount++);

        await _push(transport, 'seat_seed', <String, Object?>{
          'seat': 1,
          'client_seed': 'bob-seed',
          'origin': origin,
          'seq': 2,
        });

        final seat1 = controller.room!.seats.firstWhere((s) => s.seat == 1);
        expect(seat1.clientSeed, 'bob-seed');
        expect(
          seat1.seedOrigin.toString(),
          contains(origin == 'player' ? 'player' : 'server'),
        );
        final seat0 = controller.room!.seats.firstWhere((s) => s.seat == 0);
        expect(seat0.clientSeed, isNull, reason: 'only the named seat changes');
        expect(controller.room!.seq, 2);
        expect(notifyCount, greaterThan(0));
      });
    }
  });

  group('D4: game_started', () {
    test(
      'sets state to playing, gameId, clientSeeds, and a fresh turn whose '
      'deadlineMs is turnSeconds * 1000 -- not the 45000 default and not 0 '
      '-- for a room whose rules.turnSeconds is not the default 45',
      () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController(seq: 1, turnSeconds: 90);
        addTearDown(controller.dispose);
        int notifyCount = 0;
        controller.addListener(() => notifyCount++);

        await _push(transport, 'game_started', <String, Object?>{
          'turn': 0,
          'game_id': 'b' * 16,
          'client_seeds': '0:seed',
          'seq': 2,
        });

        expect(controller.room!.state.toString(), contains('playing'));
        expect(controller.room!.gameId, 'b' * 16);
        expect(controller.room!.clientSeeds, '0:seed');
        final turn = controller.room!.turn;
        expect(turn, isNotNull);
        expect(turn!.seat, 0);
        expect(turn.phase.toString(), contains('awaitRoll'));
        expect(
          turn.deadlineMs,
          90000,
          reason:
              'deadlineMs must be rules.turnSeconds (90) * 1000 = 90000, '
              'not the 45000 default and not 0',
        );
        expect(turn.k, 0);
        expect(turn.value, isNull);
        expect(turn.legal, isNull);
        expect(turn.sixes, isNull);
        expect(controller.room!.seq, 2);
        expect(notifyCount, greaterThan(0));
      },
    );
  });

  group('D4: turn', () {
    test(
      'sets seat, phase awaitRoll, deadlineMs from the frame, carries k '
      'forward from the turn it replaces, and clears value/legal/sixes',
      () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seq: 1,
          state: 'PLAYING',
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam'),
            _seatJson(1, name: 'Bob'),
          ],
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 500,
            k: 7,
            value: 6,
            legal: <int>[0, 1],
          ),
        );
        addTearDown(controller.dispose);

        await _push(transport, 'turn', <String, Object?>{
          'seat': 1,
          'deadline_ms': 45000,
          'seq': 2,
        });

        final turn = controller.room!.turn!;
        expect(turn.seat, 1);
        expect(turn.phase.toString(), contains('awaitRoll'));
        expect(turn.deadlineMs, 45000);
        expect(
          turn.k,
          7,
          reason:
              'k must be carried forward from the turn this replaces, '
              'not reset to 0',
        );
        expect(turn.value, isNull);
        expect(turn.legal, isNull);
        expect(turn.sixes, isNull);
      },
    );
  });

  group('D4: rolled', () {
    test('sets phase awaitMove and copies seat/value/deadlineMs/k/legal; '
        'sixes stays null even for value: 6', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1, state: 'PLAYING');
      addTearDown(controller.dispose);

      await _push(transport, 'rolled', <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[0, 2],
        'deadline_ms': 12000,
        'k': 3,
        'reveal': 'c' * 64,
        'seq': 2,
      });

      final turn = controller.room!.turn!;
      expect(turn.seat, 0);
      expect(turn.phase.toString(), contains('awaitMove'));
      expect(turn.value, 6);
      expect(turn.legal, <int>[0, 2]);
      expect(turn.deadlineMs, 12000);
      expect(turn.k, 3);
      expect(
        turn.sixes,
        isNull,
        reason:
            'D6: every TurnState this reducer builds sets sixes to null, '
            'including a rolled value of exactly 6',
      );
    });

    test('an empty legal list is stored as an empty list, not null', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1, state: 'PLAYING');
      addTearDown(controller.dispose);

      await _push(transport, 'rolled', <String, Object?>{
        'seat': 0,
        'value': 5,
        'legal': <int>[],
        'deadline_ms': 12000,
        'k': 3,
        'reveal': 'c' * 64,
        'seq': 2,
      });

      final turn = controller.room!.turn!;
      expect(turn.legal, isNotNull);
      expect(turn.legal, isEmpty);
    });
  });

  group('D4: moved', () {
    test(
      "sets the moving seat's token, applies captures, and returns the "
      'turn to a no-decision-pending state, keeping seat/deadlineMs/k',
      () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seq: 1,
          state: 'PLAYING',
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam'),
            _seatJson(1, name: 'Bob'),
          ],
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 9000,
            k: 4,
            value: 3,
            legal: <int>[2],
          ),
        );
        addTearDown(controller.dispose);

        await _push(transport, 'moved', <String, Object?>{
          'seat': 0,
          'token': 2,
          'from': 40,
          'to': 43,
          'captured': <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 3},
          ],
          'extra_roll': false,
          'seq': 2,
        });

        final seat0 = controller.room!.seats.firstWhere((s) => s.seat == 0);
        final seat1 = controller.room!.seats.firstWhere((s) => s.seat == 1);
        expect(seat0.tokens[2], 43);
        expect(seat1.tokens[3], -1);

        final turn = controller.room!.turn!;
        expect(turn.phase.toString(), contains('awaitRoll'));
        expect(turn.value, isNull);
        expect(turn.legal, isNull);
        expect(turn.sixes, isNull);
        expect(turn.seat, 0, reason: 'seat is kept, not cleared');
        expect(turn.deadlineMs, 9000, reason: 'deadlineMs is kept');
        expect(turn.k, 4, reason: 'k is kept');
      },
    );

    test("from is not checked against the seat's current token position: a "
        "mismatch does not stop the move from applying", () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        state: 'PLAYING',
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[10, -1, -1, -1]),
        ],
      );
      addTearDown(controller.dispose);

      await _push(transport, 'moved', <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 999, // does not match the seat's actual token position (10)
        'to': 15,
        'captured': <Object?>[],
        'extra_roll': false,
        'seq': 2,
      });

      expect(
        controller.room!.seats.single.tokens[0],
        15,
        reason:
            'a from mismatch is not this reducer\'s business to reject; '
            'the move must still apply',
      );
    });

    test(
      'if room.turn is null, the turn is left null and only tokens change',
      () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController(seq: 1);
        addTearDown(controller.dispose);
        expect(controller.room!.turn, isNull, reason: 'fixture is broken');

        await _push(transport, 'moved', <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': -1,
          'to': 0,
          'captured': <Object?>[],
          'extra_roll': false,
          'seq': 2,
        });

        expect(controller.room!.turn, isNull);
        expect(controller.room!.seats.single.tokens[0], 0);
      },
    );
  });

  group('D4: turn_passed', () {
    test(
      'clears value/legal/sixes and sets phase awaitRoll, keeping '
      'seat/deadlineMs/k, and does not itself change whose turn it is',
      () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seq: 1,
          state: 'PLAYING',
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 500,
            k: 2,
            value: 1,
            legal: <int>[],
          ),
        );
        addTearDown(controller.dispose);

        await _push(transport, 'turn_passed', <String, Object?>{
          'seat': 0,
          'reason': 'no_legal_move',
          'seq': 2,
        });

        final turn = controller.room!.turn!;
        expect(turn.phase.toString(), contains('awaitRoll'));
        expect(turn.value, isNull);
        expect(turn.legal, isNull);
        expect(turn.sixes, isNull);
        expect(
          turn.seat,
          0,
          reason:
              'turn_passed must not change whose turn it is; the following '
              'turn frame does that',
        );
        expect(turn.deadlineMs, 500);
        expect(turn.k, 2);
      },
    );

    test('if room.turn is null, nothing changes but the seq', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      expect(controller.room!.turn, isNull, reason: 'fixture is broken');
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      await _push(transport, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'three_sixes',
        'seq': 2,
      });

      expect(controller.room!.turn, isNull);
      expect(controller.room!.seq, 2);
      expect(notifyCount, greaterThan(0));
    });
  });

  group('D4: game_over', () {
    test('sets state finished and winner, and turns a non-null turn into '
        'phase finished, clearing value/legal/sixes and keeping '
        'seat/deadlineMs/k', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        state: 'PLAYING',
        turn: _turnJson(
          seat: 1,
          phase: 'await_move',
          deadlineMs: 800,
          k: 12,
          value: 5,
          legal: <int>[3],
        ),
      );
      addTearDown(controller.dispose);

      await _push(transport, 'game_over', <String, Object?>{
        'winner': 1,
        'verify_url': 'https://provefair.app/v/xyz',
        'seq': 2,
      });

      expect(controller.room!.state.toString(), contains('finished'));
      expect(controller.room!.winner, 1);
      final turn = controller.room!.turn!;
      expect(turn.phase.toString(), contains('finished'));
      expect(turn.value, isNull);
      expect(turn.legal, isNull);
      expect(turn.sixes, isNull);
      expect(turn.seat, 1);
      expect(turn.deadlineMs, 800);
      expect(turn.k, 12);
    });

    test(
      'if room.turn is null, game_over still sets state and winner',
      () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController(seq: 1);
        addTearDown(controller.dispose);
        expect(controller.room!.turn, isNull, reason: 'fixture is broken');

        await _push(transport, 'game_over', <String, Object?>{
          'winner': 0,
          'verify_url': 'https://provefair.app/v/xyz',
          'seq': 2,
        });

        expect(controller.room!.state.toString(), contains('finished'));
        expect(controller.room!.winner, 0);
        expect(controller.room!.turn, isNull);
      },
    );
  });

  // ======================================================================
  // D5. The resync.
  // ======================================================================
  group('D5: single-flight, proved by counting', () {
    test('five gapped deltas in a row produce exactly one resume on the wire', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);

      for (int i = 0; i < 5; i++) {
        await _push(transport, 'presence', <String, Object?>{
          'seat': 0,
          'connected': i.isEven,
          'seq': 500 + i,
        });
      }

      expect(
        _resumeCount(transport),
        1,
        reason:
            'five gapped deltas in a row must produce exactly one resume, '
            'got ${transport.sentRaw.where((r) => _decode(r)['t'] == 'resume').length}',
      );
      expect(controller.hasDesynced, isTrue);
    });
  });

  group('D5 step 2: the three stop conditions', () {
    test('stop condition: phase is not connected (mid reconnect(): room is '
        'still the snapshot cached from before the drop, but the new '
        "connection's own resume has not yet answered) -- hasDesynced is set "
        'for the gap, but no resume is sent for it and no additional '
        'transport is opened', () async {
      final (
        RoomController controller,
        FakeTransport transport1,
        _Connector connector,
      ) = await _connectedController(
        seq: 1,
      );
      addTearDown(controller.dispose);

      transport1.endFromFarSide();
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.closed, reason: 'fixture is broken');

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      final Future<void> reconnectFuture = controller.reconnect();
      await pumpEventQueue();
      expect(
        controller.phase,
        RoomPhase.connecting,
        reason:
            "fixture is broken: reconnect()'s own resume must not have "
            'been answered yet',
      );
      final int callsBefore = connector.calls.length;
      final int resumesBefore = _resumeCount(transport2);

      // A gapped delta arrives on the new, already-open transport before
      // reconnect()'s own resume reply does.
      await _push(transport2, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 999,
      });

      expect(
        controller.hasDesynced,
        isTrue,
        reason: 'D5 step 1 runs regardless of the stop condition',
      );
      expect(
        _resumeCount(transport2),
        resumesBefore,
        reason:
            'no resume may be sent for the gap while phase is not '
            'connected',
      );
      expect(connector.calls.length, callsBefore);

      // Resolve the outstanding reconnect() so it does not leak.
      final String id = _idOf(transport2.sentRaw.first);
      transport2.pushText(
        _frame(type: 'room', re: id, data: _roomJson(seq: 1)),
      );
      await reconnectFuture;
    });

    test('stop condition: the cached seat token is null (a room arrived '
        'without seat_assigned ever having been sent) -- hasDesynced is set, '
        'but no resume is sent and no new transport is opened', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final Future<void> createFuture = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      // No seat_assigned pushed at all.
      transport.pushText(_frame(type: 'room', re: id, data: _roomJson(seq: 1)));
      await createFuture;

      expect(
        controller.phase,
        RoomPhase.connected,
        reason: 'fixture is broken',
      );
      expect(
        controller.seatToken,
        isNull,
        reason: 'fixture is broken: no seat_assigned was ever sent',
      );

      final int callsBefore = connector.calls.length;
      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 999,
      });

      expect(controller.hasDesynced, isTrue);
      expect(_resumeCount(transport), 0);
      expect(connector.calls.length, callsBefore);
    });

    test(
      'the literal third condition, "no live connection", could not be '
      'triggered independently of the two above through the public '
      'surface; see this file\'s final report for why, rather than '
      'guessing at an internal field to poke',
      () {},
      skip:
          'ambiguity: reported in the final message, not invented around; '
          'see D5 step 2, condition "no live connection"',
    );
  });

  group('D5: resync success adopts the returned snapshot wholly', () {
    test('the resulting room reflects the resync snapshot, not the ignored '
        'delta -- a field the delta would have set differently is instead '
        'whatever the snapshot says, proving "resynced" rather than '
        '"applied the delta despite the gap"', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        connector,
      ) = await _connectedController(
        seq: 1,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', connected: true),
        ],
      );
      addTearDown(controller.dispose);
      final int callsBefore = connector.calls.length;

      // The ignored delta says seat 0 becomes disconnected.
      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 999,
      });
      expect(controller.hasDesynced, isTrue);
      expect(_resumeCount(transport), 1);

      final Map<String, Object?> sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'resume');
      expect(
        sent['d'],
        equals(<String, Object?>{
          'code': controller.room!.code,
          'seat_token': controller.seatToken,
        }),
      );

      // The resync snapshot disagrees with the delta: seat 0 is (still)
      // connected: true, and seq is far beyond both the delta's 999 and
      // the room's stale 1.
      transport.pushText(
        _frame(
          type: 'room',
          re: sent['id']! as String,
          data: _roomJson(
            seats: <Map<String, Object?>>[
              _seatJson(0, name: 'Sam', connected: true),
            ],
            seq: 1200,
          ),
        ),
      );
      await pumpEventQueue();

      expect(controller.hasDesynced, isFalse);
      expect(
        controller.room!.seats.single.connected,
        isTrue,
        reason:
            'the snapshot said connected: true; a client that instead '
            'shows false applied the ignored delta rather than resyncing',
      );
      expect(controller.room!.seq, 1200);
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'the resync must go out on the current, already-open '
            'connection, never opening a new transport',
      );
    });
  });

  group('D5: resync failure', () {
    test('a resume answered with an error routes through the same failure '
        'path as setPlayers/startGame, and hasDesynced is left true', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);

      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 999,
      });
      final String id = _idOf(transport.sentRaw.last);

      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'BAD_SEAT_TOKEN',
            'message': 'no such seat',
          },
        ),
      );
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'BAD_SEAT_TOKEN');
      expect(
        controller.hasDesynced,
        isTrue,
        reason: 'a failed resync must leave hasDesynced true',
      );
    });
  });

  // ======================================================================
  // F1 (order 098). A background resync's failure does not drive the
  // phase, with one exception: an error the server sent on purpose. Proved
  // from the outside, against the frozen declaration shared with order 096,
  // never against room_controller.dart itself.
  // ======================================================================
  group('F1: a background resync failure is fatal only when the server '
      'refuses the resume', () {
    test('the resume answered with an error frame is fatal: phase becomes '
        'failed, the error code is the server\'s own code verbatim, and the '
        'connection is closed', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);

      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 999,
      });
      expect(
        _resumeCount(transport),
        1,
        reason: 'fixture is broken: the gap must have started a resync',
      );
      final String id = _idOf(transport.sentRaw.last);

      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'NO_SUCH_ROOM',
            'message': 'this room no longer exists',
          },
        ),
      );
      await pumpEventQueue();

      expect(controller.phase, RoomPhase.failed);
      expect(
        controller.errorCode,
        'NO_SUCH_ROOM',
        reason:
            "the server's own error code must reach errorCode verbatim, "
            'exactly as it does for a player-initiated request',
      );
      expect(
        transport.isClosed,
        isTrue,
        reason:
            'a fatal background-resync failure must close the '
            'connection, unchanged from a player-initiated request '
            'failure',
      );
    });

    test('the transport ending while the background resume is outstanding '
        'closes the phase rather than failing it: hasDesynced stays true and '
        'no error code is set', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);

      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 999,
      });
      expect(
        _resumeCount(transport),
        1,
        reason: 'fixture is broken: the gap must have started a resync',
      );
      final String? errorCodeBefore = controller.errorCode;

      transport.endFromFarSide();
      await pumpEventQueue();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'the ordinary connection.done lifecycle, not the resync\'s '
            'own failure path, must decide the phase when the socket '
            'itself dies while a background resume is outstanding',
      );
      expect(
        controller.hasDesynced,
        isTrue,
        reason: 'a non-fatal resync failure must never clear hasDesynced',
      );
      expect(
        controller.errorCode,
        errorCodeBefore,
        reason:
            'the outstanding resume completing with '
            'ConnectionClosedException must not itself set an error '
            'code',
      );
      expect(
        controller.errorCode,
        isNot('closed'),
        reason:
            "errorCode == 'closed' is what a *request*-driven "
            'ConnectionClosedException maps to through _failFromRequest '
            '(see room_controller_test.dart); a background resync '
            'failing the same way must never reach that mapping',
      );
    });

    test('the resume timing out on a transport that stays open leaves the '
        'controller connected: the connection is untouched, hasDesynced '
        'stays true, and no error code is set', () {
      fakeAsync((FakeAsync async) {
        final (RoomController controller, FakeTransport transport, _) =
            _connectedControllerInFakeAsync(async, seq: 1);

        transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 999},
          ),
        );
        async.flushMicrotasks();
        expect(
          controller.hasDesynced,
          isTrue,
          reason: 'fixture is broken: the gap must have started a resync',
        );
        expect(
          _resumeCount(transport),
          1,
          reason: 'fixture is broken: the gap must have started a resync',
        );

        // The frozen declaration exposes no way to configure or discover
        // the real request timeout; two hours of fake time is generous
        // enough to exceed any plausible value, and the resume is never
        // answered.
        async.elapse(const Duration(hours: 2));
        async.flushMicrotasks();

        expect(
          controller.phase,
          RoomPhase.connected,
          reason:
              'a timed-out background resume must not touch the phase '
              'of a socket that is still alive',
        );
        expect(
          transport.isClosed,
          isFalse,
          reason:
              'a timed-out background resume must not close a socket '
              'that is still alive',
        );
        expect(controller.hasDesynced, isTrue);
        expect(
          controller.errorCode,
          isNull,
          reason: 'a timed-out background resume must not set an error code',
        );

        controller.dispose();
      });
    });

    test('after a non-fatal resync failure, the controller still reduces '
        'frames: a well-formed contiguous delta pushed afterwards still '
        'changes room, proving _resyncInFlight was cleared rather than left '
        'set and silently freezing every future frame', () {
      fakeAsync((FakeAsync async) {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = _connectedControllerInFakeAsync(
          async,
          seq: 1,
          seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
        );

        transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 999},
          ),
        );
        async.flushMicrotasks();
        expect(
          _resumeCount(transport),
          1,
          reason: 'fixture is broken: the gap must have started a resync',
        );

        // Non-fatal failure: the resume times out, never answered.
        async.elapse(const Duration(hours: 2));
        async.flushMicrotasks();
        expect(
          controller.phase,
          RoomPhase.connected,
          reason: 'fixture is broken: a timeout must not fail the phase',
        );
        expect(
          controller.room!.seats.length,
          1,
          reason:
              'fixture is broken: the original gapped delta must still '
              'not have been applied',
        );

        // room.seq is still 1 (the gapped delta at seq 999 was never
        // applied), so seq 2 is contiguous.
        transport.pushText(
          _frame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 1, 'name': 'Bob', 'seq': 2},
          ),
        );
        async.flushMicrotasks();

        expect(
          controller.room!.seats.length,
          2,
          reason:
              'a contiguous delta pushed after a non-fatal resync '
              'failure must still be reduced; a controller that left '
              '_resyncInFlight set would silently ignore this frame '
              'forever',
        );
        expect(controller.room!.seq, 2);

        controller.dispose();
      });
    });

    test('single-flight survives a non-fatal failure: after a timed-out '
        'resume, a later gapped delta produces a new resume on the wire', () {
      fakeAsync((FakeAsync async) {
        final (RoomController controller, FakeTransport transport, _) =
            _connectedControllerInFakeAsync(async, seq: 1);

        transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 999},
          ),
        );
        async.flushMicrotasks();
        expect(
          _resumeCount(transport),
          1,
          reason: 'fixture is broken: the gap must have started a resync',
        );

        async.elapse(const Duration(hours: 2));
        async.flushMicrotasks();
        expect(
          controller.phase,
          RoomPhase.connected,
          reason: 'fixture is broken: a timeout must not fail the phase',
        );

        transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{'seat': 0, 'connected': true, 'seq': 1000},
          ),
        );
        async.flushMicrotasks();

        expect(
          _resumeCount(transport),
          2,
          reason:
              'a later gap must produce a fresh resume once the earlier '
              'one has failed; the controller must not have locked '
              'itself out of ever resyncing again',
        );

        controller.dispose();
      });
    });
  });

  group('D5 step 6: disposed while the resume is outstanding', () {
    test('the controller does nothing at all: no exception, and phase is not '
        'flipped to failed by the outstanding request completing after '
        'dispose', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);

      await _push(transport, 'presence', <String, Object?>{
        'seat': 0,
        'connected': false,
        'seq': 999,
      });
      expect(_resumeCount(transport), 1, reason: 'fixture is broken');
      final RoomPhase phaseBeforeDispose = controller.phase;

      expect(controller.dispose, returnsNormally);
      // dispose() closes the connection, which completes the outstanding
      // resume's request with ConnectionClosedException; let that settle.
      await pumpEventQueue();

      expect(
        controller.phase,
        phaseBeforeDispose,
        reason:
            'D5 step 6: a controller disposed while the resume was '
            'outstanding must do nothing at all when it later resolves, '
            'including not landing in phase failed',
      );
    });
  });

  // ======================================================================
  // D6. sixes is never derived.
  // ======================================================================
  group('D6: sixes', () {
    test(
      'a room snapshot carrying a non-null sixes decodes with it intact',
      () async {
        final (RoomController controller, _, _) = await _connectedController(
          seq: 1,
          state: 'PLAYING',
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 100,
            k: 5,
            sixes: 2,
          ),
        );
        addTearDown(controller.dispose);

        expect(controller.room!.turn!.sixes, 2);
      },
    );
  });

  // ======================================================================
  // G1. RoomController.roll(). See the extension _PendingGameIntentions
  // above main() for why controller.roll() compiles on a branch that does
  // not yet declare it.
  // ======================================================================
  group('G1: RoomController.roll()', () {
    test('clause 2: puts exactly one roll request on the wire, with t="roll" '
        'and the empty d docs/PROTOCOL.md section 4 specifies, while '
        'connected', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      final int sentBefore = transport.sentRaw.length;

      final Future<void> future = controller.roll();
      await pumpEventQueue();

      final List<Map<String, Object?>> rollFrames = transport.sentRaw
          .skip(sentBefore)
          .map(_decode)
          .where((Map<String, Object?> m) => m['t'] == 'roll')
          .toList();
      expect(
        rollFrames,
        hasLength(1),
        reason:
            'roll() must put exactly one roll request on the wire, got '
            '${transport.sentRaw.skip(sentBefore).toList()}',
      );
      expect(
        rollFrames.single['d'],
        equals(<String, Object?>{}),
        reason: 'docs/PROTOCOL.md section 4: roll carries an empty d',
      );

      // Resolve it so nothing is left outstanding at the end of the body
      // (standing lesson 9).
      final String id = rollFrames.single['id']! as String;
      transport.pushText(_frame(type: 'pong', re: id));
      await expectLater(future, completes);
    });

    test('clause 1: is a silent no-op in phase idle, sending nothing at all '
        'and notifying no listener', () async {
      final (
        RoomController controller,
        FakeTransport? transport,
        _Connector connector,
      ) = await _idlePhaseFixture();
      addTearDown(controller.dispose);

      await _expectGameIntentionNoOp(
        controller,
        connector,
        transport: transport,
        action: controller.roll,
        reason: 'G1 clause 1: roll() must be a silent no-op in phase idle',
      );
    });

    test('clause 1: is a silent no-op in phase connecting, sending nothing at '
        'all and notifying no listener', () async {
      final (
        RoomController controller,
        FakeTransport? transport,
        _Connector connector,
      ) = await _connectingPhaseFixture();
      addTearDown(controller.dispose);

      await _expectGameIntentionNoOp(
        controller,
        connector,
        transport: transport,
        action: controller.roll,
        reason:
            'G1 clause 1: roll() must be a silent no-op in phase '
            'connecting',
      );

      await _finishConnectingFixture(transport!);
    });

    test('clause 1: is a silent no-op in phase closed, sending nothing at all '
        'and notifying no listener', () async {
      final (
        RoomController controller,
        FakeTransport? transport,
        _Connector connector,
      ) = await _closedPhaseFixture();
      addTearDown(controller.dispose);

      await _expectGameIntentionNoOp(
        controller,
        connector,
        transport: transport,
        action: controller.roll,
        reason: 'G1 clause 1: roll() must be a silent no-op in phase closed',
      );
    });

    test('clause 1: is a silent no-op in phase failed, sending nothing at all '
        'and notifying no listener', () async {
      final (
        RoomController controller,
        FakeTransport? transport,
        _Connector connector,
      ) = await _failedPhaseFixture();
      addTearDown(controller.dispose);

      await _expectGameIntentionNoOp(
        controller,
        connector,
        transport: transport,
        action: controller.roll,
        reason: 'G1 clause 1: roll() must be a silent no-op in phase failed',
      );
    });

    test('clause 1: after dispose(), roll() sends nothing at all and does not '
        'throw', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      final int sentBefore = transport.sentRaw.length;

      controller.dispose();

      late Future<void> future;
      expect(
        () => future = controller.roll(),
        returnsNormally,
        reason: 'roll() after dispose() must not throw synchronously',
      );
      await expectLater(future, completes);
      expect(
        transport.sentRaw.length,
        sentBefore,
        reason: 'roll() after dispose() must send nothing at all',
      );
    });

    test("clause 3: the reply frame is discarded -- room stays the identical "
        'snapshot it was before, seq does not move, and no listener fires for '
        'the reply itself', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      final Object? roomBefore = controller.room;
      final int seqBefore = controller.room!.seq;
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      final Future<void> future = controller.roll();
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      // 'pong' is a real docs/PROTOCOL.md section 5 type, carries no seq,
      // and is not one of D4's reducer types, so it is inert on the
      // ordinary frame path too: any change observed here can only be
      // attributed to roll() itself trying to parse its own reply as a
      // snapshot.
      transport.pushText(_frame(type: 'pong', re: id));
      await expectLater(future, completes);

      expect(
        identical(controller.room, roomBefore),
        isTrue,
        reason: 'G1 clause 3: the reply must not be parsed as a snapshot',
      );
      expect(
        controller.room!.seq,
        seqBefore,
        reason: 'G1 clause 3: the reply must not advance seq',
      );
      expect(
        notifyCount,
        0,
        reason: 'G1 clause 3: the reply itself must not notify',
      );
    });

    test('clause 4: a request that fails drives the phase to failed and sets '
        'errorCode/errorMessage verbatim, pinned the way the D5: resync '
        'failure group above pins its own', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);

      final Future<void> future = controller.roll();
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'WRONG_PHASE',
            'message': 'a move is pending',
          },
        ),
      );

      await expectLater(
        future,
        completes,
        reason: 'roll() must never throw, even on a server error',
      );
      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'WRONG_PHASE');
      expect(controller.errorMessage, 'a move is pending');
    });
  });

  // ======================================================================
  // G2. RoomController.move(int token).
  // ======================================================================
  group('G2: RoomController.move(int token)', () {
    test('clause 2: puts exactly one move request on the wire, carrying '
        '{"token": n} for an n that is not 0, while connected', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      const int chosenToken = 3;
      final int sentBefore = transport.sentRaw.length;

      final Future<void> future = controller.move(chosenToken);
      await pumpEventQueue();

      final List<Map<String, Object?>> moveFrames = transport.sentRaw
          .skip(sentBefore)
          .map(_decode)
          .where((Map<String, Object?> m) => m['t'] == 'move')
          .toList();
      expect(
        moveFrames,
        hasLength(1),
        reason:
            'move() must put exactly one move request on the wire, got '
            '${transport.sentRaw.skip(sentBefore).toList()}',
      );
      expect(
        moveFrames.single['d'],
        equals(<String, Object?>{'token': chosenToken}),
        reason:
            'docs/PROTOCOL.md section 4: move carries {"token": n}, and '
            'chosenToken is $chosenToken specifically so a hardcoded 0 '
            'cannot satisfy this assertion',
      );

      final String id = moveFrames.single['id']! as String;
      transport.pushText(_frame(type: 'pong', re: id));
      await expectLater(future, completes);
    });

    test('clause 3: is a silent no-op in phase connecting, sending nothing at '
        'all and notifying no listener', () async {
      final (
        RoomController controller,
        FakeTransport? transport,
        _Connector connector,
      ) = await _connectingPhaseFixture();
      addTearDown(controller.dispose);

      await _expectGameIntentionNoOp(
        controller,
        connector,
        transport: transport,
        action: () => controller.move(1),
        reason:
            'G2 clause 3: move() must be a silent no-op in phase '
            'connecting',
      );

      await _finishConnectingFixture(transport!);
    });

    test('clause 3: is a silent no-op in phase failed, sending nothing at all '
        'and notifying no listener', () async {
      final (
        RoomController controller,
        FakeTransport? transport,
        _Connector connector,
      ) = await _failedPhaseFixture();
      addTearDown(controller.dispose);

      await _expectGameIntentionNoOp(
        controller,
        connector,
        transport: transport,
        action: () => controller.move(1),
        reason: 'G2 clause 3: move() must be a silent no-op in phase failed',
      );
    });

    test(
      'clause 1: a token that is not in the current turn\'s legal list is '
      'still sent unchanged -- the controller performs no legality check',
      () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seq: 1,
          state: 'PLAYING',
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 9000,
            k: 4,
            value: 3,
            legal: <int>[2],
          ),
        );
        addTearDown(controller.dispose);
        const int illegalToken = 1;
        final int sentBefore = transport.sentRaw.length;

        final Future<void> future = controller.move(illegalToken);
        await pumpEventQueue();

        final List<Map<String, Object?>> moveFrames = transport.sentRaw
            .skip(sentBefore)
            .map(_decode)
            .where((Map<String, Object?> m) => m['t'] == 'move')
            .toList();
        expect(
          moveFrames,
          hasLength(1),
          reason:
              'G2 clause 1: a token outside legal ([2]) must still reach '
              'the wire unchanged',
        );
        expect(moveFrames.single['d'], equals(<String, Object?>{'token': 1}));

        final String id = moveFrames.single['id']! as String;
        transport.pushText(_frame(type: 'pong', re: id));
        await expectLater(future, completes);
      },
    );

    test('clause 1: a token outside 0..3 is still sent unchanged -- the '
        'controller performs no range check', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        state: 'PLAYING',
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 9000,
          k: 4,
          value: 3,
          legal: <int>[0, 1, 2, 3],
        ),
      );
      addTearDown(controller.dispose);
      const int outOfRangeToken = 99;
      final int sentBefore = transport.sentRaw.length;

      final Future<void> future = controller.move(outOfRangeToken);
      await pumpEventQueue();

      final List<Map<String, Object?>> moveFrames = transport.sentRaw
          .skip(sentBefore)
          .map(_decode)
          .where((Map<String, Object?> m) => m['t'] == 'move')
          .toList();
      expect(
        moveFrames,
        hasLength(1),
        reason:
            'G2 clause 1: a token outside 0..3 must still reach the wire '
            'unchanged',
      );
      expect(moveFrames.single['d'], equals(<String, Object?>{'token': 99}));

      final String id = moveFrames.single['id']! as String;
      transport.pushText(_frame(type: 'pong', re: id));
      await expectLater(future, completes);
    });

    test(
      "clause 1: a move sent while another seat holds the turn is still "
      'sent unchanged -- the controller does not check whose turn it is',
      () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seq: 1,
          hostSeat: 0,
          state: 'PLAYING',
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam'),
            _seatJson(1, name: 'Bob'),
          ],
          turn: _turnJson(
            seat: 1, // not this client's own seat (0)
            phase: 'await_move',
            deadlineMs: 9000,
            k: 4,
            value: 3,
            legal: <int>[0],
          ),
        );
        addTearDown(controller.dispose);
        expect(controller.seat, 0, reason: 'fixture is broken');
        final int sentBefore = transport.sentRaw.length;

        final Future<void> future = controller.move(0);
        await pumpEventQueue();

        final List<Map<String, Object?>> moveFrames = transport.sentRaw
            .skip(sentBefore)
            .map(_decode)
            .where((Map<String, Object?> m) => m['t'] == 'move')
            .toList();
        expect(
          moveFrames,
          hasLength(1),
          reason:
              'G2 clause 1: a move issued while seat 1 holds the turn must '
              'still reach the wire from seat 0 unchanged; the server, not '
              'this controller, answers NOT_YOUR_TURN',
        );
        expect(moveFrames.single['d'], equals(<String, Object?>{'token': 0}));

        final String id = moveFrames.single['id']! as String;
        transport.pushText(_frame(type: 'pong', re: id));
        await expectLater(future, completes);
      },
    );

    test('clause 4: a request that fails drives the phase to failed and sets '
        'errorCode/errorMessage verbatim, pinned the way the D5: resync '
        'failure group above pins its own', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);

      final Future<void> future = controller.move(0);
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'ILLEGAL_MOVE',
            'message': 'token not in legal',
          },
        ),
      );

      await expectLater(
        future,
        completes,
        reason: 'move() must never throw, even on a server error',
      );
      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'ILLEGAL_MOVE');
      expect(controller.errorMessage, 'token not in legal');
    });
  });

  // ======================================================================
  // G3. The ordering guarantee, and its one limit: no de-duplication, no
  // in-flight guard.
  // ======================================================================
  group('G3: ordering, no de-duplication, no in-flight guard', () {
    test(
      'two roll() calls issued back to back both reach the wire, in call '
      'order, as two distinct requests; the second is not suppressed',
      () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController(seq: 1);
        final int sentBefore = transport.sentRaw.length;

        final Future<void> first = controller.roll();
        final Future<void> second = controller.roll();
        await pumpEventQueue();

        final List<Map<String, Object?>> rollFrames = transport.sentRaw
            .skip(sentBefore)
            .map(_decode)
            .where((Map<String, Object?> m) => m['t'] == 'roll')
            .toList();
        expect(
          rollFrames,
          hasLength(2),
          reason:
              'G3: two roll() calls in flight at once must be two requests '
              'on the wire; a length of 1 would mean de-duplication or an '
              'in-flight guard the declaration explicitly forbids, got '
              '${transport.sentRaw.skip(sentBefore).toList()}',
        );
        expect(
          rollFrames[0]['id'],
          isNot(rollFrames[1]['id']),
          reason:
              'the two requests must be distinct messages, not one id '
              'replayed twice',
        );

        // Neither request is ever answered here; dispose from inside the
        // body (standing lesson 9) rather than only via addTearDown, so no
        // pending request/timer survives past this test.
        controller.dispose();
        await pumpEventQueue();
        unawaitedFuture(first);
        unawaitedFuture(second);
      },
    );
  });

  // ======================================================================
  // G4. The null starting turn, frozen by the master as the rule rather
  // than merely observed. No implementation change is permitted for G4;
  // this pins behaviour the reducer already has.
  // ======================================================================
  group('G4: the null starting turn', () {
    test('a standalone turn frame whose gap check passes, naming a seat '
        'present in room.seats, arriving while room.turn is null, is applied '
        'as a fresh await-roll segment with k == 0 -- not ignored and not a '
        'desync', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
      );
      addTearDown(controller.dispose);
      expect(controller.room!.turn, isNull, reason: 'fixture is broken');
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      await _push(transport, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 24680,
        'seq': 2, // room.seq (1) + 1: the gap check passes
      });

      final turn = controller.room!.turn;
      expect(
        turn,
        isNotNull,
        reason:
            'G4: a turn frame arriving while room.turn is null must be '
            'applied, not ignored',
      );
      expect(turn!.seat, 1);
      expect(turn.phase.toString(), contains('awaitRoll'));
      expect(
        turn.deadlineMs,
        24680,
        reason: "deadlineMs must be exactly the frame's own deadline_ms",
      );
      expect(
        turn.k,
        0,
        reason:
            'G4: k of a fresh segment computed from a null starting turn '
            'is 0 -- it is not omitted, not an error, and does not '
            'trigger a resync',
      );
      expect(turn.value, isNull);
      expect(turn.legal, isNull);
      expect(turn.sixes, isNull);
      expect(controller.room!.seq, 2);
      expect(
        controller.hasDesynced,
        isFalse,
        reason: 'G4: a null starting turn must not raise hasDesynced',
      );
      expect(notifyCount, greaterThan(0));
    });

    test('the same frame while room.turn is non-null carries that turn\'s own '
        'k forward instead of resetting it to 0', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seq: 1,
        state: 'PLAYING',
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 500,
          k: 7,
          value: 6,
          legal: <int>[0, 1],
        ),
      );
      addTearDown(controller.dispose);

      await _push(transport, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 13579,
        'seq': 2,
      });

      final turn = controller.room!.turn!;
      expect(turn.seat, 1);
      expect(turn.deadlineMs, 13579);
      expect(
        turn.k,
        7,
        reason:
            'G4: k must be carried forward from the turn this frame '
            'replaces, chosen as 7 (not 0) so a hardcoded 0 could not '
            'satisfy both this case and the null-starting-turn case '
            'above',
      );
    });
  });
}

/// A fire-and-forget helper for the fakeAsync F1 tests, which cannot use
/// `await`: kept as a named function (rather than package:pedantic's
/// unawaited, not a dependency here) purely so `dart format`/the
/// unawaited_futures lint has something unambiguous to see was deliberate.
void unawaitedFuture(Future<void> future) {}

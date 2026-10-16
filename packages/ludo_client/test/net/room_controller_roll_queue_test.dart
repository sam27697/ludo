// Acceptance tests for Part A of
// work/ludo/orders/C-362-roll-queue-client.md (A1 to A7) as reduced by
// lib/src/net/room_controller.dart, driven through a FakeTransport the way
// test/net/room_controller_game_test.dart drives frames. Written from the
// contract and from docs/PROTOCOL.md sections 5, 12, 14 and 21, against no
// implementation of room_controller.dart the author of this file has read.
// A second worker (order 362) is writing that reducer, blind, from the same
// contract, at the same time.
//
// Cases are labelled M1 to M11, matching
// work/ludo/orders/363-roll-queue-client-model-tests.md.
//
// The contract leaves two names to the implementer and pins them here,
// because the order says they are now part of the contract:
//   - the type holding one `legal_by_face` entry is `FaceLegal`, with
//     fields `face` and `tokens`;
//   - A4's spent face lives on `RoomSnapshot.lastSpentFace`, an `int?`,
//     null until a `moved` carrying `face` arrives and reset to null only
//     by the next `rolled` -- not by the `turn` frame that follows a
//     `moved`, which the contract does not list among the things that
//     clear it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'roll-queue-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

// --- fixture builders ---------------------------------------------------

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

/// docs/PROTOCOL.md section 21.1: `{"face": int, "tokens": [int]}`.
Map<String, Object?> _faceLegalJson(int face, List<int> tokens) =>
    <String, Object?>{'face': face, 'tokens': tokens};

/// The snapshot's `turn` object (nested in a `room` reply, no `seq` of its
/// own). [phase] null reproduces a turn object with no `phase` key at all,
/// for M2.
Map<String, Object?> _turnJson({
  required int seat,
  String? phase,
  required int deadlineMs,
  required int k,
  int? value,
  List<int>? legal,
  int? sixes,
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'phase': ?phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'sixes': ?sixes,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
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

/// A `rolled` push's `d`, docs/PROTOCOL.md section 21.1/21.3: `queue` is
/// the queue after the roll, `legal_by_face` only when a move is pending.
Map<String, Object?> _rolledJson({
  required int seat,
  required int value,
  required List<int> legal,
  required int deadlineMs,
  required int k,
  required int seq,
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': deadlineMs,
  'k': k,
  'reveal': 'b' * 64,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
  'seq': seq,
};

/// A `moved` push's `d`, docs/PROTOCOL.md section 21.1: `face` is the face
/// spent.
Map<String, Object?> _movedJson({
  required int seat,
  required int token,
  required int from,
  required int to,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  required bool extraRoll,
  int? face,
  required int seq,
}) => <String, Object?>{
  'seat': seat,
  'token': token,
  'from': from,
  'to': to,
  'captured': captured,
  'extra_roll': extraRoll,
  'face': ?face,
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

/// Builds a controller, drives it through createRoom(), and lands it
/// connected with the given room shape at [seq]. Defaults to a two-seat
/// PLAYING room with no turn, which every case below overrides as needed.
Future<(RoomController, FakeTransport, _Connector)> _connectedController({
  int hostSeat = 0,
  String state = 'PLAYING',
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);

  final Future<void> future = controller.createRoom(name: 'Sam', players: 4);
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
        hostSeat: hostSeat,
        state: state,
        seats: seats,
        turn: turn,
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

/// Asserts that pushing [type]/[data] changes nothing observable: `room`
/// stays the same object, `seq` does not advance, nothing notifies, and the
/// frame still reaches [RoomController.frames]. Used for M3 (an
/// unrecognised `turn.phase` is ignored like any other malformed frame).
Future<void> _expectNoOp(
  RoomController controller,
  FakeTransport transport,
  String type,
  Map<String, Object?> data, {
  required String reason,
}) async {
  final Object? roomBefore = controller.room;
  final int seqBefore = controller.room!.seq;
  int notifyCount = 0;
  void listener() => notifyCount++;
  controller.addListener(listener);
  final List<Frame> log = <Frame>[];
  final sub = controller.frames.listen(log.add);

  await _push(transport, type, data);

  expect(identical(controller.room, roomBefore), isTrue, reason: reason);
  expect(
    controller.room!.seq,
    seqBefore,
    reason: '$reason (seq must not advance)',
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

void main() {
  final List<Map<String, Object?>> seatsAB = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ];

  // ==========================================================================
  // M1
  // ==========================================================================
  group('M1: turn with phase await_move carries queue, value, legal, '
      'legal_by_face', () {
    test('reduces to awaitMove with all five fields carried', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seats: seatsAB,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 500, k: 1),
        seq: 1,
      );
      addTearDown(controller.dispose);

      await _push(transport, 'turn', <String, Object?>{
        ..._turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 9000,
          k: 1,
          value: 6,
          legal: <int>[0, 2],
          queue: <int>[6, 3],
          legalByFace: <Map<String, Object?>>[
            _faceLegalJson(6, <int>[0, 2]),
            _faceLegalJson(3, <int>[1]),
          ],
        ),
        'seq': 2,
      });

      final TurnState turn = controller.room!.turn!;
      expect(turn.phase, TurnPhase.awaitMove);
      expect(turn.value, 6);
      expect(turn.legal, <int>[0, 2]);
      expect(turn.deadlineMs, 9000);
      expect(turn.queue, <int>[6, 3]);
      expect(turn.legalByFace, isNotNull);
      expect(turn.legalByFace, hasLength(2));
      expect(turn.legalByFace![0].face, 6, reason: 'wire order must be kept');
      expect(turn.legalByFace![0].tokens, <int>[0, 2]);
      expect(turn.legalByFace![1].face, 3);
      expect(turn.legalByFace![1].tokens, <int>[1]);
    });
  });

  // ==========================================================================
  // M2
  // ==========================================================================
  group('M2: turn with no phase reduces exactly as today', () {
    test(
      'awaitRoll, value and legal null, queue [], legalByFace null',
      () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seats: seatsAB,
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 500,
            k: 3,
            value: 5,
            legal: <int>[0],
          ),
          seq: 1,
        );
        addTearDown(controller.dispose);

        // No 'phase' key, no 'queue' key, no 'legal_by_face' key: the
        // pre-queue wire shape.
        await _push(transport, 'turn', <String, Object?>{
          'seat': 1,
          'deadline_ms': 45000,
          'seq': 2,
        });

        final TurnState turn = controller.room!.turn!;
        expect(turn.seat, 1);
        expect(turn.phase, TurnPhase.awaitRoll);
        expect(turn.value, isNull);
        expect(turn.legal, isNull);
        expect(
          turn.queue,
          isNotNull,
          reason: 'A1: queue is const [] when the wire sends none, not null',
        );
        expect(turn.queue, isEmpty);
        expect(turn.legalByFace, isNull);
      },
    );
  });

  // ==========================================================================
  // M3
  // ==========================================================================
  group('M3: turn with an unrecognised phase token is ignored', () {
    test('state and seq unchanged for "await_moving"', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seats: seatsAB,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 500, k: 1),
        seq: 1,
      );
      addTearDown(controller.dispose);

      await _expectNoOp(
        controller,
        transport,
        'turn',
        <String, Object?>{
          'seat': 0,
          'deadline_ms': 9000,
          'phase': 'await_moving',
          'seq': 2,
        },
        reason:
            'an unrecognised turn.phase must be ignored like any other '
            'malformed frame',
      );
    });

    test('any other unknown token is ignored the same way', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seats: seatsAB,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 500, k: 1),
        seq: 1,
      );
      addTearDown(controller.dispose);

      await _expectNoOp(
        controller,
        transport,
        'turn',
        <String, Object?>{
          'seat': 0,
          'deadline_ms': 9000,
          'phase': 'finished', // valid TurnPhase value, but not a value
          // docs/PROTOCOL.md section 21.1 lists for the pushed turn frame
          // ("await_roll" or "await_move" only)
          'seq': 2,
        },
        reason:
            'phase "finished" is not one of the two the pushed turn '
            'frame may carry (docs/PROTOCOL.md 21.3 ruling 1) and must be '
            'ignored the same way',
      );
    });
  });

  // ==========================================================================
  // M4
  // ==========================================================================
  group('M4: rolled with queue and no legal_by_face', () {
    test(
      'phase awaitRoll, value 6, queue [6], recentRolls gains the 6',
      () async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectedController(
          seats: seatsAB,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 500, k: 0),
          seq: 1,
        );
        addTearDown(controller.dispose);

        await _push(
          transport,
          'rolled',
          _rolledJson(
            seat: 0,
            value: 6,
            legal: const <int>[],
            deadlineMs: 45000,
            k: 1,
            queue: <int>[6],
            seq: 2,
          ),
        );

        final TurnState turn = controller.room!.turn!;
        expect(turn.phase, TurnPhase.awaitRoll);
        expect(turn.value, 6);
        expect(turn.queue, <int>[6]);
        expect(controller.room!.recentRolls.last, (
          1,
          6,
        ), reason: 'recentRolls must still record every rolled face');
      },
    );
  });

  // ==========================================================================
  // M5
  // ==========================================================================
  group('M5: rolled with queue and legal_by_face', () {
    test('awaitMove, both carried in wire order', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seats: seatsAB,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 500, k: 1),
        seq: 1,
      );
      addTearDown(controller.dispose);

      await _push(
        transport,
        'rolled',
        _rolledJson(
          seat: 0,
          value: 3,
          legal: <int>[1],
          deadlineMs: 45000,
          k: 2,
          queue: <int>[6, 3],
          legalByFace: <Map<String, Object?>>[
            _faceLegalJson(6, <int>[0, 2]),
            _faceLegalJson(3, <int>[1]),
          ],
          seq: 2,
        ),
      );

      final TurnState turn = controller.room!.turn!;
      expect(turn.phase, TurnPhase.awaitMove);
      expect(turn.queue, <int>[6, 3]);
      expect(turn.legalByFace, hasLength(2));
      expect(turn.legalByFace![0].face, 6);
      expect(turn.legalByFace![0].tokens, <int>[0, 2]);
      expect(turn.legalByFace![1].face, 3);
      expect(turn.legalByFace![1].tokens, <int>[1]);
    });
  });

  // ==========================================================================
  // M6
  // ==========================================================================
  group('M6: rolled with no queue at all', () {
    test("today's reduction: awaitMove, value, legal; queue [], "
        'legalByFace null', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seats: seatsAB,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 500, k: 1),
        seq: 1,
      );
      addTearDown(controller.dispose);

      await _push(
        transport,
        'rolled',
        _rolledJson(
          seat: 0,
          value: 4,
          legal: <int>[0, 2],
          deadlineMs: 45000,
          k: 2,
          seq: 2,
        ),
      );

      final TurnState turn = controller.room!.turn!;
      expect(turn.phase, TurnPhase.awaitMove);
      expect(turn.value, 4);
      expect(turn.legal, <int>[0, 2]);
      expect(
        turn.queue,
        isNotNull,
        reason: 'A1: queue is const [] when the wire sends none, not null',
      );
      expect(turn.queue, isEmpty);
      expect(turn.legalByFace, isNull);
    });
  });

  // ==========================================================================
  // M7, M8
  // ==========================================================================
  group('M7: moved with face sets lastSpentFace', () {
    test('lastSpentFace == 3; the following turn (same seat, await_move, '
        'queue [6]) sets the new queue and legalByFace, and does not itself '
        'clear lastSpentFace', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seats: seatsAB,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 9000,
          k: 5,
          value: 6,
          legal: <int>[0, 2],
          queue: <int>[6, 3],
          legalByFace: <Map<String, Object?>>[
            _faceLegalJson(6, <int>[0, 2]),
            _faceLegalJson(3, <int>[1]),
          ],
        ),
        seq: 1,
      );
      addTearDown(controller.dispose);

      await _push(
        transport,
        'moved',
        _movedJson(
          seat: 0,
          token: 1,
          from: 20,
          to: 23,
          extraRoll: false,
          face: 3,
          seq: 2,
        ),
      );

      expect(
        controller.room!.lastSpentFace,
        3,
        reason: 'a moved carrying face must set lastSpentFace to it',
      );

      await _push(transport, 'turn', <String, Object?>{
        ..._turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 9000,
          k: 5,
          value: 6,
          legal: <int>[0, 2],
          queue: <int>[6],
          legalByFace: <Map<String, Object?>>[
            _faceLegalJson(6, <int>[0, 2]),
          ],
        ),
        'seq': 3,
      });

      final TurnState turn = controller.room!.turn!;
      expect(turn.phase, TurnPhase.awaitMove);
      expect(turn.seat, 0);
      expect(turn.queue, <int>[6]);
      expect(turn.legalByFace, hasLength(1));
      expect(turn.legalByFace!.single.face, 6);
      expect(
        controller.room!.lastSpentFace,
        3,
        reason:
            'the contract lists only the next rolled as clearing '
            'lastSpentFace; the turn frame that follows a moved must not '
            'clear it',
      );
    });
  });

  group('M8: the next rolled resets lastSpentFace to null', () {
    test('after a moved with face, a rolled clears lastSpentFace', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        seats: seatsAB,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 9000,
          k: 5,
          value: 6,
          legal: <int>[0, 2],
          queue: <int>[6],
          legalByFace: <Map<String, Object?>>[
            _faceLegalJson(6, <int>[0, 2]),
          ],
        ),
        seq: 1,
      );
      addTearDown(controller.dispose);

      await _push(
        transport,
        'moved',
        _movedJson(
          seat: 0,
          token: 1,
          from: 20,
          to: 26,
          extraRoll: false,
          face: 6,
          seq: 2,
        ),
      );
      expect(controller.room!.lastSpentFace, 6, reason: 'fixture is broken');

      await _push(
        transport,
        'rolled',
        _rolledJson(
          seat: 1,
          value: 5,
          legal: <int>[0],
          deadlineMs: 45000,
          k: 6,
          seq: 3,
        ),
      );

      expect(
        controller.room!.lastSpentFace,
        isNull,
        reason: 'the next rolled, for any seat, must clear lastSpentFace',
      );
    });
  });

  // ==========================================================================
  // M9
  // ==========================================================================
  group('M9: move(token, face: ...) puts face on the wire only when given', () {
    test('move(2, face: 6) sends {"token": 2, "face": 6}', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seats: seatsAB, seq: 1);
      addTearDown(controller.dispose);

      final Future<void> future = controller.move(2, face: 6);
      await pumpEventQueue();
      final Map<String, Object?> sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'move');
      expect(sent['d'], equals(<String, Object?>{'token': 2, 'face': 6}));

      transport.pushText(_frame(type: 'moved', re: sent['id']! as String));
      await future;
    });

    test('move(2) sends {"token": 2} with no face key', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seats: seatsAB, seq: 1);
      addTearDown(controller.dispose);

      final Future<void> future = controller.move(2);
      await pumpEventQueue();
      final Map<String, Object?> sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'move');
      expect(
        sent['d'],
        equals(<String, Object?>{'token': 2}),
        reason: 'face absent must not put a face key on the wire at all',
      );

      transport.pushText(_frame(type: 'moved', re: sent['id']! as String));
      await future;
    });
  });

  // ==========================================================================
  // M11
  // ==========================================================================
  group(
    'M11: a full scripted queue turn, frame by frame per PROTOCOL 21.3',
    () {
      test(
        '6 (rolled + turn), 3 (rolled), move face 6 (moved + turn await_move), '
        'move face 3 (moved + turn next seat): every intermediate state '
        'checked',
        () async {
          final (
            RoomController controller,
            FakeTransport transport,
            _,
          ) = await _connectedController(
            seats: seatsAB,
            turn: _turnJson(
              seat: 0,
              phase: 'await_roll',
              deadlineMs: 45000,
              k: 0,
            ),
            seq: 1,
          );
          addTearDown(controller.dispose);

          // Step 1: roll, a 6 owing another roll -- rolled (seq 2).
          await _push(
            transport,
            'rolled',
            _rolledJson(
              seat: 0,
              value: 6,
              legal: const <int>[],
              deadlineMs: 45000,
              k: 1,
              queue: <int>[6],
              seq: 2,
            ),
          );
          {
            final TurnState turn = controller.room!.turn!;
            expect(turn.phase, TurnPhase.awaitRoll, reason: 'step 1');
            expect(turn.queue, <int>[6], reason: 'step 1');
            expect(controller.room!.recentRolls.last, (1, 6), reason: 'step 1');
          }

          // ... then turn (same seat, await_roll), seq 3.
          await _push(transport, 'turn', <String, Object?>{
            ..._turnJson(
              seat: 0,
              phase: 'await_roll',
              deadlineMs: 45000,
              k: 1,
              queue: <int>[6],
            ),
            'seq': 3,
          });
          {
            final TurnState turn = controller.room!.turn!;
            expect(turn.seat, 0, reason: 'step 2');
            expect(turn.phase, TurnPhase.awaitRoll, reason: 'step 2');
            expect(turn.queue, <int>[6], reason: 'step 2');
          }

          // Step 2: roll, a move pending -- rolled only (seq 4): queue [6, 3],
          // legal_by_face for both faces.
          await _push(
            transport,
            'rolled',
            _rolledJson(
              seat: 0,
              value: 3,
              legal: <int>[1],
              deadlineMs: 45000,
              k: 2,
              queue: <int>[6, 3],
              legalByFace: <Map<String, Object?>>[
                _faceLegalJson(6, <int>[0, 2]),
                _faceLegalJson(3, <int>[1]),
              ],
              seq: 4,
            ),
          );
          {
            final TurnState turn = controller.room!.turn!;
            expect(turn.phase, TurnPhase.awaitMove, reason: 'step 3');
            expect(turn.queue, <int>[6, 3], reason: 'step 3');
            expect(turn.legalByFace, hasLength(2), reason: 'step 3');
            expect(turn.legalByFace![0].face, 6, reason: 'step 3');
            expect(turn.legalByFace![1].face, 3, reason: 'step 3');
          }

          // Step 3: move face 6 -- moved (seq 5) with face: 6.
          await _push(
            transport,
            'moved',
            _movedJson(
              seat: 0,
              token: 0,
              from: 10,
              to: 16,
              extraRoll: false,
              face: 6,
              seq: 5,
            ),
          );
          expect(
            controller.room!.lastSpentFace,
            6,
            reason: 'step 4: moved with face 6 spent',
          );

          // ... then turn (same seat, await_move), seq 6: queue now [3].
          await _push(transport, 'turn', <String, Object?>{
            ..._turnJson(
              seat: 0,
              phase: 'await_move',
              deadlineMs: 45000,
              k: 2,
              value: 3,
              legal: <int>[1],
              queue: <int>[3],
              legalByFace: <Map<String, Object?>>[
                _faceLegalJson(3, <int>[1]),
              ],
            ),
            'seq': 6,
          });
          {
            final TurnState turn = controller.room!.turn!;
            expect(turn.seat, 0, reason: 'step 5');
            expect(turn.phase, TurnPhase.awaitMove, reason: 'step 5');
            expect(turn.queue, <int>[3], reason: 'step 5');
            expect(turn.legalByFace, hasLength(1), reason: 'step 5');
            expect(turn.legalByFace!.single.face, 3, reason: 'step 5');
          }

          // Step 4: move face 3 -- moved (seq 7) with face: 3, queue empty.
          await _push(
            transport,
            'moved',
            _movedJson(
              seat: 0,
              token: 1,
              from: 5,
              to: 8,
              extraRoll: false,
              face: 3,
              seq: 7,
            ),
          );
          expect(
            controller.room!.lastSpentFace,
            3,
            reason: 'step 6: moved with face 3 spent',
          );

          // ... then turn (next seat), seq 8: a fresh await_roll with an
          // empty queue.
          await _push(transport, 'turn', <String, Object?>{
            ..._turnJson(
              seat: 1,
              phase: 'await_roll',
              deadlineMs: 45000,
              k: 2,
              queue: const <int>[],
            ),
            'seq': 8,
          });
          {
            final TurnState turn = controller.room!.turn!;
            expect(
              turn.seat,
              1,
              reason: 'step 7: turn passed to the next seat',
            );
            expect(turn.phase, TurnPhase.awaitRoll, reason: 'step 7');
            expect(turn.queue, isEmpty, reason: 'step 7');
          }
        },
      );
    },
  );
}

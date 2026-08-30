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
/// more than that) a connection was ever attempted.
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
}

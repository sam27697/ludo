// Proof for order 170's E: a rejected intention -- roll() or move() answered
// with one of exactly NOT_YOUR_TURN, WRONG_PHASE, ILLEGAL_MOVE, GAME_OVER --
// must not disconnect the player. Written from THE CONTRACT in
// work/ludo/orders/171-prove-rejections-and-request-failure-sequence.md,
// clauses E1 through E3, copied verbatim from order 170, and from nothing
// else. Where a case would need to assume something the contract leaves
// silent, that is called out at the case rather than guessed at.
//
// Built the way test/net/room_controller_game_test.dart and
// test/net/room_controller_auto_reconnect_test.dart are built: a fake
// TransportConnector hands out FakeTransport instances
// (test/net/fake_transport.dart, read-only), frames are pushed with
// pushText, and every claim about what the controller sent is made by
// decoding FakeTransport.sentRaw. The helpers below are private copies for
// this file, not imports of either other file's own private helpers -- ,
// neither file exports anything a test could import.
//
// Every case that depends on a delay runs inside fakeAsync
// (package:fake_async), following the house pattern at
// test/net/connection_test.dart:887-940. Every other case runs on plain
// async/await, following room_controller_game_test.dart's
// _connectedController.
//
// This file is written to run, unmodified, against packages/ludo_client on
// 449fc30 (order 170 not yet landed): every case marked RED below is
// expected to fail there, for a reason that names the contract clause it
// violates, and every case marked GREEN or a control is expected to pass
// there already.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://order-171-e-test.invalid/ws';

/// order 170's E1 set, in the order the contract states them.
const List<String> _raceCodes = <String>[
  'NOT_YOUR_TURN',
  'WRONG_PHASE',
  'ILLEGAL_MOVE',
  'GAME_OVER',
];

/// A short, distinctive schedule for E-C3, the one case in this file that
/// needs autoReconnectDelays non-empty.
const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 5),
  Duration(seconds: 20),
];

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-171e-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  String name = 'Sam',
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
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

// --- controller construction ------------------------------------------

RoomController _newController(
  _Connector connector, {
  List<Duration> autoReconnectDelays = const <Duration>[],
}) => RoomController(
  serverUrl: Uri.parse(_testUrl),
  connect: connector.call,
  autoReconnectDelays: autoReconnectDelays,
);

/// Builds a controller, drives it through a successful createRoom(), and
/// returns it already in phase connected with room, seat and seatToken all
/// populated, at [seq] with [state] and [seats] (defaulting to a single
/// occupied seat 0).
Future<(RoomController, FakeTransport, _Connector)> _connectedController({
  int hostSeat = 0,
  String code = 'K7M2QP',
  int players = 4,
  String state = 'LOBBY',
  List<Map<String, Object?>>? seats,
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
        seats: seats,
        seq: seq,
      ),
    ),
  );
  await future;
  return (controller, transport, connector);
}

/// The fakeAsync twin of [_connectedController], for E-C3, the one case that
/// needs a fake clock: a fakeAsync callback must stay synchronous (the house
/// pattern at test/net/connection_test.dart:887-940), so this drives the
/// same createRoom() handshake with [async.flushMicrotasks] instead of
/// awaiting futures.
(RoomController, FakeTransport, _Connector) _connectedControllerSync(
  FakeAsync async, {
  List<Duration> autoReconnectDelays = const <Duration>[],
  int hostSeat = 0,
  int seq = 1,
}) {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(
    connector,
    autoReconnectDelays: autoReconnectDelays,
  );

  unawaited(controller.createRoom(name: 'Sam', players: 4));
  async.flushMicrotasks();
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
      data: _roomJson(hostSeat: hostSeat, seq: seq),
    ),
  );
  async.flushMicrotasks();

  return (controller, transport, connector);
}

void main() {
  // ==========================================================================
  // E-R1..E-R4 (RED on base): roll() rejected with each of the four race
  // codes.
  // ==========================================================================
  for (int i = 0; i < _raceCodes.length; i++) {
    final String code = _raceCodes[i];
    test('E-R${i + 1}: roll() rejected $code (E1) leaves phase connected, does '
        'not close the current connection, opens no new connection, and the '
        'connection keeps reducing a contiguous push afterwards', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = await _connectedController(
        state: 'PLAYING',
      );
      addTearDown(controller.dispose);

      final Future<void> future = controller.roll();
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{'code': code, 'message': 'race: $code'},
        ),
      );
      await expectLater(
        future,
        completes,
        reason: 'roll() must never throw, even on a rejected intention',
      );

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'E1: $code is a rejected intention, a race with the server\'s '
            'state, not a fault; phase must stay connected',
      );
      expect(
        controller.errorCode,
        isNull,
        reason: 'E1: $code must not set errorCode',
      );
      expect(
        controller.errorMessage,
        isNull,
        reason: 'E1: $code must not set errorMessage',
      );
      expect(
        transport.isClosed,
        isFalse,
        reason: 'E1: $code must not close the current connection',
      );
      expect(
        connector.calls.length,
        1,
        reason:
            'E1: $code must not open a new connection; the current one '
            'stays current',
      );

      final int seqBefore = controller.room!.seq;
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 4,
            'legal': <int>[0, 1],
            'deadline_ms': 9000,
            'k': 0,
            'seq': seqBefore + 1,
          },
        ),
      );
      await pumpEventQueue();

      expect(
        controller.room!.seq,
        seqBefore + 1,
        reason:
            'E1: "the current connection ... stays the current '
            'connection (frames that arrive on it afterwards are '
            'forwarded to frames and reduced exactly as before)" -- '
            'room.seq must have advanced on the contiguous push',
      );
      expect(
        controller.room!.turn?.seat,
        0,
        reason:
            'E1: the rolled push after the rejection must have been '
            'reduced into room.turn, proving the connection is really '
            'still live, not merely "phase says connected"',
      );
    });
  }

  // ==========================================================================
  // E-M1..E-M4 (RED on base): move() rejected with each of the four race
  // codes.
  // ==========================================================================
  for (int i = 0; i < _raceCodes.length; i++) {
    final String code = _raceCodes[i];
    test('E-M${i + 1}: move() rejected $code (E1) leaves phase connected, does '
        'not close the current connection, opens no new connection, and the '
        'connection keeps reducing a contiguous push afterwards', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = await _connectedController(
        state: 'PLAYING',
      );
      addTearDown(controller.dispose);

      final Future<void> future = controller.move(2);
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{'code': code, 'message': 'race: $code'},
        ),
      );
      await expectLater(
        future,
        completes,
        reason: 'move() must never throw, even on a rejected intention',
      );

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'E1: $code is a rejected intention, a race with the server\'s '
            'state, not a fault; phase must stay connected',
      );
      expect(
        controller.errorCode,
        isNull,
        reason: 'E1: $code must not set errorCode',
      );
      expect(
        controller.errorMessage,
        isNull,
        reason: 'E1: $code must not set errorMessage',
      );
      expect(
        transport.isClosed,
        isFalse,
        reason: 'E1: $code must not close the current connection',
      );
      expect(
        connector.calls.length,
        1,
        reason:
            'E1: $code must not open a new connection; the current one '
            'stays current',
      );

      final int seqBefore = controller.room!.seq;
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 2,
            'from': -1,
            'to': 5,
            'captured': <Object?>[],
            'extra_roll': false,
            'seq': seqBefore + 1,
          },
        ),
      );
      await pumpEventQueue();

      expect(
        controller.room!.seq,
        seqBefore + 1,
        reason:
            'E1: the current connection must still be reducing frames '
            'after the rejection -- room.seq must have advanced on the '
            'contiguous push',
      );
      expect(
        controller.room!.seats.first.tokens[2],
        5,
        reason:
            'E1: the moved push after the rejection must have been '
            'reduced, proving the connection is really still live',
      );
    });
  }

  // ==========================================================================
  // E-D (RED on base): the double tap on roll, as a player produces it.
  // ==========================================================================
  test('E-D: two roll() calls back to back -- the first accepted and followed '
      'by a rolled push, the second answered WRONG_PHASE -- leave the '
      'connection connected, the rolled push reduced, and a subsequent '
      'move() request still reaches the wire on the same transport', () async {
    final (
      RoomController controller,
      FakeTransport transport,
      _Connector connector,
    ) = await _connectedController(
      state: 'PLAYING',
    );
    addTearDown(controller.dispose);

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
          'fixture is broken: two roll() calls back to back must both '
          'reach the wire (G3 of the game test pins this)',
    );
    final String id1 = rollFrames[0]['id']! as String;
    final String id2 = rollFrames[1]['id']! as String;

    // The first tap: the server accepts it (a plain reply, discarded, not
    // parsed) and follows it with a rolled push, contiguous against room.seq.
    transport.pushText(_frame(type: 'roll', re: id1));
    final int seqBefore = controller.room!.seq;
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 5,
          'legal': <int>[1],
          'deadline_ms': 9000,
          'k': 0,
          'seq': seqBefore + 1,
        },
      ),
    );
    // The second tap: the race the server's state has already resolved.
    transport.pushText(
      _frame(
        type: 'error',
        re: id2,
        data: <String, Object?>{
          'code': 'WRONG_PHASE',
          'message': 'a roll is already pending',
        },
      ),
    );
    await Future.wait<void>(<Future<void>>[first, second]);
    await pumpEventQueue();

    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'E-D: a double tap on Roll must not disconnect the player -- '
          'order 170\'s E, the defect this order exists to prove the fix '
          'of',
    );
    expect(
      controller.room!.seq,
      seqBefore + 1,
      reason: 'the rolled push from the accepted first tap must be reduced',
    );
    expect(controller.room!.turn?.value, 5);

    final int sentBeforeMove = transport.sentRaw.length;
    final Future<void> moveFuture = controller.move(0);
    await pumpEventQueue();
    final List<Map<String, Object?>> moveFrames = transport.sentRaw
        .skip(sentBeforeMove)
        .map(_decode)
        .where((Map<String, Object?> m) => m['t'] == 'move')
        .toList();
    expect(
      moveFrames,
      hasLength(1),
      reason:
          'E-D: a subsequent move() must still reach the wire on the '
          'same, still-open transport',
    );

    // Resolve it so nothing is left pending (standing lesson).
    final String moveId = moveFrames.single['id']! as String;
    transport.pushText(_frame(type: 'move', re: moveId));
    await moveFuture;
  });

  // ==========================================================================
  // E-C1 (GREEN on base, control for E2).
  // ==========================================================================
  test('E-C1 (control): roll() rejected BAD_SEAT_TOKEN -- not one of the four '
      'race codes -- lands in failed with that errorCode and closes the '
      'transport, exactly as on 449fc30', () async {
    final (RoomController controller, FakeTransport transport, _) =
        await _connectedController();
    addTearDown(controller.dispose);

    final Future<void> future = controller.roll();
    await pumpEventQueue();
    final String id = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'error',
        re: id,
        data: <String, Object?>{
          'code': 'BAD_SEAT_TOKEN',
          'message': 'stale seat token',
        },
      ),
    );
    await expectLater(future, completes);

    expect(controller.phase, RoomPhase.failed);
    expect(controller.errorCode, 'BAD_SEAT_TOKEN');
    expect(controller.errorMessage, 'stale seat token');
    expect(
      transport.isClosed,
      isTrue,
      reason:
          'E2: every code outside the four-code set behaves exactly as '
          'on 449fc30 -- _failFromRequest closes the connection',
    );
  });

  // ==========================================================================
  // E-C2 (GREEN on base, control for E2's scope: startGame() untouched).
  // ==========================================================================
  test('E-C2 (control): startGame() rejected WRONG_PHASE still lands in failed '
      'with errorCode WRONG_PHASE -- E does not touch startGame() or '
      'setPlayers()', () async {
    final (RoomController controller, FakeTransport transport, _) =
        await _connectedController();
    addTearDown(controller.dispose);

    final Future<void> future = controller.startGame();
    await pumpEventQueue();
    final String id = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'error',
        re: id,
        data: <String, Object?>{
          'code': 'WRONG_PHASE',
          'message': 'game already started',
        },
      ),
    );
    await expectLater(future, completes);

    expect(controller.phase, RoomPhase.failed);
    expect(controller.errorCode, 'WRONG_PHASE');
    expect(controller.errorMessage, 'game already started');
  });

  // ==========================================================================
  // E-C3 (RED on base): a rejected roll never arms an automatic sequence.
  // ==========================================================================
  test('E-C3: with autoReconnectDelays non-empty, a rejected roll '
      '(NOT_YOUR_TURN) leaves autoReconnectPending false after a minute of '
      'fake clock, and the connector is still called exactly once', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );

      unawaited(controller.roll());
      async.flushMicrotasks();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'NOT_YOUR_TURN',
            'message': 'not your turn',
          },
        ),
      );
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();

      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'E1/G3: a rejected intention must never arm an automatic '
            'sequence, however long a minute of fake time elapses',
      );
      expect(
        connector.calls.length,
        1,
        reason:
            'E1/G3: a rejected intention must never open a new '
            'connection',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });
}

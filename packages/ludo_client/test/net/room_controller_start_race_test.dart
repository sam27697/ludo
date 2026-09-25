// Proof for order 177's S: a lost Start race (the server answering
// startGame() with ROOM_STARTED or NOT_ENOUGH_PLAYERS) must not disconnect
// the host. Written from THE CONTRACT in
// work/ludo/orders/177-start-rejections-and-pending-notify.md, clauses S1
// through S3, copied verbatim from that order, and from nothing else. Where
// a case would need to assume something the contract leaves silent, that is
// called out at the case rather than guessed at.
//
// Built the way test/net/room_controller_rejected_intention_test.dart is
// built (order 171, the sibling proof for the same shape of fix against
// roll()/move()): a fake TransportConnector hands out FakeTransport
// instances (test/net/fake_transport.dart, read-only), frames are pushed
// with pushText, and every claim about what the controller sent is made by
// decoding FakeTransport.sentRaw. The helpers below are private copies for
// this file, not imports of that file's own private helpers -- neither file
// exports anything a test could import.
//
// The one case that depends on a delay (S-E) runs inside fakeAsync
// (package:fake_async), following the house pattern at
// test/net/connection_test.dart:887-940. Every other case runs on plain
// async/await, following room_controller_rejected_intention_test.dart's
// _connectedController.
//
// This file is written to run, unmodified, against packages/ludo_client on
// 24e9d8b (order 177 not yet landed): every case marked RED below is
// expected to fail there, for a reason that names the contract clause it
// violates, and every case marked GREEN or a control is expected to pass
// there already.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomState, SeatState;
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://order-178-s-test.invalid/ws';

/// S1's two codes, in the order the contract states them.
const List<String> _startRaceCodes = <String>[
  'ROOM_STARTED',
  'NOT_ENOUGH_PLAYERS',
];

/// A short, distinctive schedule for S-E, the one case in this file that
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
  return 'srv-178s-${_serverIdSeq.toString().padLeft(6, '0')}';
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

/// Builds a controller, drives it through a successful createRoom() as the
/// host (seat 0), and returns it already in phase connected with room, seat
/// and seatToken all populated, at [seq] with [state] and [seats] (defaulting
/// to a single occupied seat 0).
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

/// The fakeAsync twin of [_connectedController], for S-E, the one case that
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
  // S-R1, S-R2 (RED on base): startGame() rejected with each of the two
  // start-race codes.
  // ==========================================================================
  for (int i = 0; i < _startRaceCodes.length; i++) {
    final String code = _startRaceCodes[i];
    test('S-R${i + 1}: startGame() rejected $code (S1) leaves phase '
        'connected, does not close the current connection, opens no new '
        'connection, and the connection keeps reducing a contiguous push '
        'afterwards', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = await _connectedController();
      addTearDown(controller.dispose);

      final Future<void> future = controller.startGame();
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
        reason: 'startGame() must never throw, even on a lost start race',
      );

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'S1: $code is a start race with the server\'s own state, not a '
            'fault; phase must stay connected',
      );
      expect(
        controller.errorCode,
        isNull,
        reason: 'S1: $code must not set errorCode',
      );
      expect(
        controller.errorMessage,
        isNull,
        reason: 'S1: $code must not set errorMessage',
      );
      expect(
        transport.isClosed,
        isFalse,
        reason: 'S1: $code must not close the current connection',
      );
      expect(
        connector.calls.length,
        1,
        reason:
            'S1: $code must not open a new connection; the current one '
            'stays current',
      );

      // player_joined is a lobby event: the room this fixture built is still
      // RoomState.lobby (S1 never touches room), a second seat joining is an
      // ordinary thing to happen while a lobby waits on Start, and its
      // reducer (_reducePlayerJoined) carries no state gate of its own.
      final int seqBefore = controller.room!.seq;
      transport.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{
            'seat': 1,
            'name': 'Ann',
            'seq': seqBefore + 1,
          },
        ),
      );
      await pumpEventQueue();

      expect(
        controller.room!.seq,
        seqBefore + 1,
        reason:
            'S1: "the current connection is not closed and stays the '
            'current one (frames arriving on it afterwards are forwarded '
            'and reduced exactly as before)" -- room.seq must have '
            'advanced on the contiguous push',
      );
      expect(
        controller.room!.seats.any(
          (SeatState s) => s.seat == 1 && s.name == 'Ann',
        ),
        isTrue,
        reason:
            'S1: the player_joined push after the rejection must have '
            'been reduced, proving the connection is really still live, '
            'not merely "phase says connected"',
      );
    });
  }

  // ==========================================================================
  // S-D (RED on base): the double tap on Start, as a host produces it.
  // ==========================================================================
  test('S-D: two startGame() calls back to back -- the first accepted, '
      'followed by the game_started and turn pushes the server sends for '
      'it, the second answered ROOM_STARTED -- leave the connection '
      'connected, room.state playing, and a subsequent roll() request '
      'still reaches the wire on the same transport', () async {
    final (
      RoomController controller,
      FakeTransport transport,
      _Connector connector,
    ) = await _connectedController();
    addTearDown(controller.dispose);

    final int sentBefore = transport.sentRaw.length;
    final Future<void> first = controller.startGame();
    final Future<void> second = controller.startGame();
    await pumpEventQueue();

    final List<Map<String, Object?>> startFrames = transport.sentRaw
        .skip(sentBefore)
        .map(_decode)
        .where((Map<String, Object?> m) => m['t'] == 'start_game')
        .toList();
    expect(
      startFrames,
      hasLength(2),
      reason:
          'fixture is broken: two startGame() calls back to back must '
          'both reach the wire',
    );
    final String id1 = startFrames[0]['id']! as String;
    final String id2 = startFrames[1]['id']! as String;

    // ludo_server/lib/src/connection.dart's _handleStartGame: an accepted
    // start_game's own reply IS the game_started push (`_send(type:
    // 'game_started', ..., re: envelope.id)`), followed by a standalone
    // `turn` push announcing the opening segment, both addressed back to
    // the requester with `re` equal to the accepted request's own id
    // (`_sendAndBroadcast(..., re: envelope.id)`).
    final int seqBefore = controller.room!.seq;
    transport.pushText(
      _frame(
        type: 'game_started',
        re: id1,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'g-178-sd',
          'client_seeds': 'seed-178-sd',
          'seq': seqBefore + 1,
        },
      ),
    );
    transport.pushText(
      _frame(
        type: 'turn',
        re: id1,
        data: <String, Object?>{
          'seat': 0,
          'deadline_ms': 45000,
          'seq': seqBefore + 2,
        },
      ),
    );
    // The second tap: the race the server's state has already resolved.
    transport.pushText(
      _frame(
        type: 'error',
        re: id2,
        data: <String, Object?>{
          'code': 'ROOM_STARTED',
          'message': 'the room already left the lobby',
        },
      ),
    );
    await Future.wait<void>(<Future<void>>[first, second]);
    await pumpEventQueue();

    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'S1: a double tap on Start must not disconnect the host -- '
          'order 177\'s S, the defect this order exists to prove the fix '
          'of',
    );
    expect(
      controller.room!.state,
      RoomState.playing,
      reason:
          'the first, accepted startGame() must have carried the room '
          'into play through its game_started/turn pushes',
    );
    expect(
      controller.room!.seq,
      seqBefore + 2,
      reason: 'both the game_started and the turn push must be reduced',
    );
    expect(
      transport.isClosed,
      isFalse,
      reason: 'S1: ROOM_STARTED must not close the current connection',
    );
    expect(
      connector.calls.length,
      1,
      reason: 'S1: ROOM_STARTED must not open a new connection',
    );

    final int sentBeforeRoll = transport.sentRaw.length;
    final Future<void> rollFuture = controller.roll();
    await pumpEventQueue();
    final List<Map<String, Object?>> rollFrames = transport.sentRaw
        .skip(sentBeforeRoll)
        .map(_decode)
        .where((Map<String, Object?> m) => m['t'] == 'roll')
        .toList();
    expect(
      rollFrames,
      hasLength(1),
      reason:
          'S-D: a subsequent roll() must still reach the wire on the '
          'same, still-open transport',
    );

    // Resolve it so nothing is left pending (standing lesson): the reply is
    // a plain frame, not parsed, exactly as room_controller.dart's roll()
    // documents; the rolled push that follows is what actually moves state.
    final String rollId = rollFrames.single['id']! as String;
    transport.pushText(_frame(type: 'roll', re: rollId));
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 4,
          'legal': <int>[0, 1],
          'deadline_ms': 9000,
          'k': 0,
          'seq': seqBefore + 3,
        },
      ),
    );
    await rollFuture;
  });

  // ==========================================================================
  // S-C1 (GREEN on base, control for S2).
  // ==========================================================================
  test('S-C1 (control): startGame() rejected NOT_HOST -- not one of the two '
      'start-race codes -- lands in failed with that errorCode and closes '
      'the transport, exactly as on 24e9d8b', () async {
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
          'code': 'NOT_HOST',
          'message': 'only the host may start the game',
        },
      ),
    );
    await expectLater(future, completes);

    expect(controller.phase, RoomPhase.failed);
    expect(controller.errorCode, 'NOT_HOST');
    expect(controller.errorMessage, 'only the host may start the game');
    expect(
      transport.isClosed,
      isTrue,
      reason:
          'S2: every code outside the two-code set behaves exactly as on '
          '24e9d8b -- _failFromRequest closes the connection',
    );
  });

  // ==========================================================================
  // S-C2 (GREEN on base, control for S3): setPlayers() untouched.
  // ==========================================================================
  test('S-C2 (control): setPlayers(3) answered NOT_ENOUGH_PLAYERS still '
      'lands in failed with that errorCode -- S3 does not touch '
      'setPlayers()', () async {
    final (RoomController controller, FakeTransport transport, _) =
        await _connectedController();
    addTearDown(controller.dispose);

    final Future<void> future = controller.setPlayers(3);
    await pumpEventQueue();
    final String id = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'error',
        re: id,
        data: <String, Object?>{
          'code': 'NOT_ENOUGH_PLAYERS',
          'message': 'a seat emptied before the request arrived',
        },
      ),
    );
    await expectLater(future, completes);

    expect(controller.phase, RoomPhase.failed);
    expect(controller.errorCode, 'NOT_ENOUGH_PLAYERS');
    expect(
      controller.errorMessage,
      'a seat emptied before the request arrived',
    );
  });

  // ==========================================================================
  // S-C3 (GREEN on base, control for S3): roll()/move() untouched.
  // ==========================================================================
  test('S-C3 (control): roll() answered ROOM_STARTED still lands in '
      'failed -- S3\'s two new codes do not leak into '
      '_rejectedIntentionCodes', () async {
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
          'code': 'ROOM_STARTED',
          'message': 'the room already left the lobby',
        },
      ),
    );
    await expectLater(future, completes);

    expect(controller.phase, RoomPhase.failed);
    expect(controller.errorCode, 'ROOM_STARTED');
    expect(
      transport.isClosed,
      isTrue,
      reason:
          'S3: ROOM_STARTED must still close the connection when it '
          'answers roll(), exactly as any other rejected roll() code '
          'outside order 170\'s four-code set',
    );
  });

  // ==========================================================================
  // S-E (RED on base): a rejected start race never arms an automatic
  // sequence.
  // ==========================================================================
  test('S-E: with autoReconnectDelays non-empty, a rejected startGame() '
      '(NOT_ENOUGH_PLAYERS) leaves autoReconnectPending false after a '
      'minute of fake clock, and the connector is still called exactly '
      'once', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );

      final List<bool> pendingSeen = <bool>[];
      controller.addListener(() {
        pendingSeen.add(controller.autoReconnectPending);
      });

      unawaited(controller.startGame());
      async.flushMicrotasks();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'NOT_ENOUGH_PLAYERS',
            'message': 'a seat emptied before the request arrived',
          },
        ),
      );
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();

      expect(
        pendingSeen.contains(true),
        isFalse,
        reason:
            'S1: a rejected start race must never arm an automatic '
            'sequence, however long a minute of fake time elapses -- '
            'recorded=$pendingSeen',
      );
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'S1: after a minute, autoReconnectPending must still read '
            'false -- recorded=$pendingSeen',
      );
      expect(
        connector.calls.length,
        1,
        reason: 'S1: a rejected start race must never open a new connection',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // S-B (RETURN 1, item 3): S1's "not blocked" has no detecting assertion
  // without this -- a mutation that sets _blocked = true on a rejected start
  // code passes every other case in this file, because none of them ever
  // drop the connection afterwards to ask whether a later automatic sequence
  // is still allowed to start.
  // ==========================================================================
  test('S-B: delays non-empty, startGame() rejected ROOM_STARTED, then the '
      'transport closes on its own -- autoReconnectPending becomes true, '
      'proving the rejection left this controller eligible for a sequence '
      'a blocked controller would refuse', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );

      unawaited(controller.startGame());
      async.flushMicrotasks();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'ROOM_STARTED',
            'message': 'the room already left the lobby',
          },
        ),
      );
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: S1 must have kept phase connected after '
            'the rejection, or this case cannot go on to test what happens '
            'on a later drop',
      );

      transport.endFromFarSide();
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'fixture is broken: the later drop must land in closed before '
            'this case can ask whether a sequence is still allowed to '
            'start',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'S1: "not blocked" -- a rejected start race must not leave '
            'this controller unable to start an automatic sequence on a '
            'later, unrelated drop; a mutation of the fix that set '
            '_blocked = true on the rejected code would leave this false',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });
}

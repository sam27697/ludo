// Conformance tests for lib/src/net/room_controller.dart's RoomController,
// written from docs/PROTOCOL.md and from the frozen declaration block and
// fifteen rules of work order 074, against no implementation of
// room_controller.dart the author of this file has read. room_controller.dart
// does not exist on the branch this file was written on: a second worker is
// writing it, blind, from the same frozen block, at the same time. Section
// 5.3 of the project constitution is the reason the two are separate hands.
//
// RoomController is exercised as a black box at the wire level: this file
// never imports RoomConnection and never assumes RoomController is built on
// top of it. A fake TransportConnector hands out FakeTransport instances
// (test/net/fake_transport.dart, read-only, not edited here) and every
// assertion about what the controller sent is made by decoding
// FakeTransport.sentRaw, never by trusting that "a message was sent".
//
// Corners the fifteen rules leave open, reported rather than guessed at:
//
//   1. Rules 1/2 say every failure lands in phase == failed with an
//      errorCode set, including "connection ended with the request
//      outstanding" -> 'closed'. Rule 9 separately says "the transport
//      ending on its own sets phase = closed". Read together rather than
//      as a conflict: rule 9 is the case where nothing was outstanding when
//      the transport died (tested with a fully idle, already-connected
//      controller); rule 2's 'closed' row is the case where a request WAS
//      outstanding at that moment, which rule 1 says must resolve to
//      failed instead. Both are tested, each under the condition that makes
//      it the one that applies. This reading is not spelled out verbatim in
//      the order and should be checked against whatever the implementer
//      also inferred.
//
//   2. Rule 6 as originally issued said a delta naming a seat "not in
//      room.seats" is ignored for all three lobby deltas, including
//      player_joined. The master corrected this mid-task: room.seats holds
//      only occupied seats (packages/ludo_server/lib/src/registry.dart:
//      395-409 appends the new seat and re-sorts on every join), so
//      player_joined for a seat absent from room.seats must ADD it, with
//      the lobby defaults packages/ludo_server/lib/src/snapshot.dart:52-56
//      gives a freshly seated player (connected: true, tokens all -1,
//      clientSeed and seedOrigin both null), keeping room.seats sorted by
//      seat index. player_left and presence keep the original
//      ignore-when-absent behaviour, because both name a seat that should
//      already exist. This file tests the corrected rule, not the one
//      originally issued.
//
//   3. Rule 8 (seq gap => hasDesynced) and rule 15 ("game deltas ... change
//      no controller state") were in tension for the seven inert game-delta
//      types, which also carry seq. Ruled by the master, mid-task: gap
//      detection is scoped to the three lobby deltas only, and a game
//      delta never sets hasDesynced in this order. The reason is that this
//      controller does not reduce game state at all, so room.seq does not
//      advance during play; if a game delta could trip hasDesynced, it
//      would latch true the instant a game started, since every game
//      delta's seq would then look like a permanent gap against a room.seq
//      that is frozen at the LOBBY value. Rule 8's gap test uses a lobby
//      delta (presence); a dedicated test below covers the game-delta case
//      and asserts hasDesynced stays false, room is unchanged, and the
//      frame still reaches frames. **This scoping expires the moment the
//      game-state reducer lands**: once room.seq advances during play,
//      gap detection must extend to game deltas too, and this ruling (and
//      the test for it) will need revisiting against whatever that order
//      says.
//
//   4. Whether leave() waits for the server's reply (player_left or
//      presence, per docs/PROTOCOL.md section 4's leave_room row) before
//      closing, or closes unconditionally and drops any reply that arrives
//      after, is not stated by rule 12 ("sends leave_room, closes the
//      connection, sets phase = closed" reads as unconditional, with no
//      reply-gating clause). The test for it pushes a plausible reply only
//      if the transport is still open and only after the request already
//      went out, so it passes either way rather than assuming one design
//      and risking a hang against the other.
//
//   5. RoomController's frozen declaration exposes no requestTimeout
//      parameter, unlike RoomConnection's. The exact duration is therefore
//      unknown and untestable directly; the timeout test uses fake_async
//      (a transitive dependency of flutter_test, already resolvable without
//      touching pubspec.yaml, which is outside this order's file list) and
//      elapses two hours of fake time, a duration no reasonable
//      implementation would set as its real request timeout, rather than
//      asserting anything about the actual configured value.
//
// Every "must not throw" assertion checks both that the call returns
// normally (no synchronous throw) and that the Future it returns completes
// without an error (matcher `completes`, which fails if the future rejects),
// for the same reason connection_test.dart gives: a bare "did not throw"
// at the call site says nothing about a Future that silently completes with
// an error later.

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
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
/// url it was called with so a test can assert how many times (and prove no
/// more than that) a connection was ever attempted. [rejectNextWith] makes
/// exactly the next call reject instead, to exercise the connector-rejects
/// path (rule 2's 'transport' row) without touching any transport at all.
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

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

/// Builds a controller, drives it through a successful createRoom(), and
/// returns it already in phase connected with room, seat and seatToken all
/// populated. The seat this client holds is always [hostSeat], matching
/// docs/PROTOCOL.md section 4: the caller of create_room becomes host and
/// takes the first seat.
Future<(RoomController, FakeTransport, _Connector)> _connectedController({
  int players = 4,
  int hostSeat = 0,
  String code = 'K7M2QP',
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
        seats: seats,
        seq: seq,
      ),
    ),
  );
  await future;
  return (controller, transport, connector);
}

void main() {
  // --- Rule 1: no method ever throws. ---------------------------------
  group('rule 1: no method ever throws', () {
    test('createRoom, joinRoom, reconnect, setPlayers and startGame never '
        'throw when called while phase is connecting, invalid for all five, '
        'and none of them open a second transport', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final Future<void> pending = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      expect(controller.phase, RoomPhase.connecting);

      final List<Future<void> Function()> attempts = <Future<void> Function()>[
        () => controller.createRoom(name: 'Intruder', players: 4),
        () => controller.joinRoom(code: 'ZZZZZZ', name: 'Intruder'),
        () => controller.reconnect(),
        () => controller.setPlayers(3),
        () => controller.startGame(),
      ];
      for (final Future<void> Function() attempt in attempts) {
        late Future<void> future;
        expect(
          () => future = attempt(),
          returnsNormally,
          reason: 'must not throw synchronously while phase is connecting',
        );
        await expectLater(
          future,
          completes,
          reason: 'must not throw asynchronously either',
        );
      }
      expect(
        connector.calls,
        hasLength(1),
        reason:
            'none of the five invalid-phase calls above may have opened '
            'a transport of their own',
      );

      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok'},
        ),
      );
      transport.pushText(_frame(type: 'room', re: id, data: _roomJson(seq: 1)));
      await pending;
    });

    test('leave() never throws when called with no connection ever '
        'attempted (phase idle)', () async {
      final _Connector connector = _Connector();
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      late Future<void> future;
      expect(() => future = controller.leave(), returnsNormally);
      await expectLater(future, completes);
    });
  });

  // --- Rule 2: the error-code mapping table. --------------------------
  group('rule 2: error codes are mapped verbatim', () {
    test("a server 'error' reply maps errorCode/errorMessage verbatim, "
        'including a code this client has never heard of', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      final Future<void> future = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'TOTALLY_MADE_UP_CODE',
            'message': 'a code this client has never heard of',
          },
        ),
      );

      await expectLater(
        future,
        completes,
        reason: 'createRoom must never throw, even on a server error',
      );
      expect(controller.phase, RoomPhase.failed);
      expect(
        controller.errorCode,
        'TOTALLY_MADE_UP_CODE',
        reason:
            "the server's own error code must pass through unaltered, "
            'including one this client has never heard of',
      );
      expect(controller.errorMessage, 'a code this client has never heard of');
      expect(notifyCount, greaterThan(0));
    });

    test("no reply within the request timeout maps to errorCode='timeout', "
        "errorMessage=''", () {
      fakeAsync((FakeAsync async) {
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = _newController(connector);

        bool completed = false;
        Object? caughtError;
        controller
            .createRoom(name: 'Sam', players: 4)
            .then(
              (_) => completed = true,
              onError: (Object e) {
                caughtError = e;
                completed = true;
              },
            );
        async.flushMicrotasks();

        // No reply is ever pushed. Two hours of fake time is generous
        // enough to exceed any plausible request timeout; the frozen
        // declaration block exposes no way to configure or discover the
        // real value, see the file header, ambiguity 5.
        async.elapse(const Duration(hours: 2));
        async.flushMicrotasks();

        expect(
          caughtError,
          isNull,
          reason: 'createRoom must never throw, got $caughtError',
        );
        expect(completed, isTrue, reason: 'createRoom never completed');
        expect(controller.phase, RoomPhase.failed);
        expect(controller.errorCode, 'timeout');
        expect(controller.errorMessage, '');

        controller.dispose();
      });
    });

    test('the connection ending with the request outstanding maps to '
        "phase=failed, errorCode='closed', errorMessage=''", () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final Future<void> future = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      await pumpEventQueue();
      expect(
        transport.sentRaw,
        isNotEmpty,
        reason: 'fixture is broken: create_room must already be in flight',
      );

      transport.endFromFarSide();
      await expectLater(future, completes);

      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'closed');
      expect(controller.errorMessage, '');
    });

    test("the connector's future rejecting maps to phase=failed, "
        "errorCode='transport', errorMessage=''", () async {
      final _Connector connector = _Connector();
      connector.rejectNextWith(Exception('connect refused'));
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final Future<void> future = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      await expectLater(future, completes);
      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'transport');
      expect(controller.errorMessage, '');
    });

    test("a reply that is not a 'room' frame maps to phase=failed, "
        "errorCode='protocol', errorMessage=''", () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final Future<void> future = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(_frame(type: 'pong', re: id));

      await expectLater(future, completes);
      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'protocol');
      expect(controller.errorMessage, '');
    });
  });

  // --- Rule 3: createRoom/joinRoom accepted only in idle or failed. ---
  group('rule 3: createRoom/joinRoom are accepted only in idle or failed', () {
    Future<void> expectBothAreNoOps(
      RoomController controller,
      _Connector connector,
      String phaseLabel,
    ) async {
      final int callsBefore = connector.calls.length;
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final RoomPhase phaseBefore = controller.phase;
      final Object? roomBefore = controller.room;
      final int? seatBefore = controller.seat;
      final String? tokenBefore = controller.seatToken;
      final String? errBefore = controller.errorCode;

      final Future<void> createFuture = controller.createRoom(
        name: 'Intruder',
        players: 4,
      );
      await expectLater(createFuture, completes);
      expect(
        controller.phase,
        phaseBefore,
        reason: 'createRoom in phase $phaseLabel must be a no-op',
      );
      expect(identical(controller.room, roomBefore), isTrue);
      expect(controller.seat, seatBefore);
      expect(controller.seatToken, tokenBefore);
      expect(controller.errorCode, errBefore);

      final Future<void> joinFuture = controller.joinRoom(
        code: 'ZZZZZZ',
        name: 'Intruder',
      );
      await expectLater(joinFuture, completes);
      expect(
        controller.phase,
        phaseBefore,
        reason: 'joinRoom in phase $phaseLabel must be a no-op',
      );

      expect(
        notifyCount,
        0,
        reason:
            'neither createRoom nor joinRoom may notify while in phase '
            '$phaseLabel',
      );
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'neither createRoom nor joinRoom may open a transport while '
            'in phase $phaseLabel',
      );
    }

    test('both are no-ops while phase is connecting', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      unawaitedFuture(controller.createRoom(name: 'Sam', players: 4));
      expect(controller.phase, RoomPhase.connecting);

      await expectBothAreNoOps(controller, connector, 'connecting');
    });

    test('both are no-ops while phase is connected', () async {
      final (RoomController controller, _, _Connector connector) =
          await _connectedController();
      addTearDown(controller.dispose);
      await expectBothAreNoOps(controller, connector, 'connected');
    });

    test('both are no-ops while phase is closed', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = await _connectedController();
      addTearDown(controller.dispose);
      transport.endFromFarSide();
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.closed);

      await expectBothAreNoOps(controller, connector, 'closed');
    });
  });

  // --- Rule 4: an accepted create/join. --------------------------------
  group('rule 4: an accepted createRoom/joinRoom notifies at connecting, '
      'then again at connected', () {
    test('createRoom', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final List<RoomPhase> phasesSeen = <RoomPhase>[];
      controller.addListener(() => phasesSeen.add(controller.phase));

      expect(controller.phase, RoomPhase.idle);
      final Future<void> future = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      expect(
        controller.phase,
        RoomPhase.connecting,
        reason:
            'phase must already read connecting once createRoom has '
            'been called, before any reply has arrived',
      );
      expect(phasesSeen, contains(RoomPhase.connecting));

      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok'},
        ),
      );
      transport.pushText(_frame(type: 'room', re: id, data: _roomJson(seq: 1)));
      await future;

      expect(controller.phase, RoomPhase.connected);
      expect(controller.room, isNotNull);
      expect(controller.room!.code, 'K7M2QP');
      expect(controller.errorCode, isNull);
      expect(controller.errorMessage, isNull);
      expect(phasesSeen.last, RoomPhase.connected);
    });

    test('joinRoom', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final List<RoomPhase> phasesSeen = <RoomPhase>[];
      controller.addListener(() => phasesSeen.add(controller.phase));

      final Future<void> future = controller.joinRoom(
        code: 'K7M2QP',
        name: 'Bob',
      );
      expect(controller.phase, RoomPhase.connecting);
      expect(phasesSeen, contains(RoomPhase.connecting));

      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 1, 'seat_token': 'tok-guest'},
        ),
      );
      transport.pushText(_frame(type: 'room', re: id, data: _roomJson(seq: 1)));
      await future;

      expect(controller.phase, RoomPhase.connected);
      expect(controller.room, isNotNull);
      expect(controller.errorCode, isNull);
      expect(controller.errorMessage, isNull);
      expect(phasesSeen.last, RoomPhase.connected);
    });
  });

  // --- Rule 5: seat/seatToken caching. ---------------------------------
  group(
    'rule 5: seat and seatToken cache the last non-null values ever seen',
    () {
      test('a malformed seat_assigned arriving after a valid one leaves both '
          'cached values untouched, and is still forwarded to frames '
          '(master ruling, run 22: a seat token is the capability to '
          'reclaim a seat, and discarding a good one loses the seat '
          'outright)', () async {
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = _newController(connector);
        addTearDown(controller.dispose);

        final List<Frame> framesLog = <Frame>[];
        controller.frames.listen(framesLog.add);

        final Future<void> future = controller.createRoom(
          name: 'Sam',
          players: 4,
        );
        await pumpEventQueue();
        final String id = _idOf(transport.sentRaw.last);

        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 2, 'seat_token': 'tok-good'},
          ),
        );
        await pumpEventQueue();
        expect(controller.seat, 2);
        expect(controller.seatToken, 'tok-good');

        // Malformed: seat out of the 0..3 range.
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 99, 'seat_token': 'tok-bad'},
          ),
        );
        await pumpEventQueue();
        expect(controller.seat, 2);
        expect(controller.seatToken, 'tok-good');
        expect(
          framesLog.where((Frame f) => f.type == 'seat_assigned'),
          hasLength(2),
          reason:
              'both seat_assigned frames, including the malformed one, '
              'must still reach frames',
        );

        transport.pushText(
          _frame(type: 'room', re: id, data: _roomJson(hostSeat: 2, seq: 1)),
        );
        await future;
        expect(controller.seat, 2);
        expect(controller.seatToken, 'tok-good');
      });

      test(
        'seat and seatToken survive a transport drop and remain readable '
        'in phase closed, which is what makes reconnect() possible at all',
        () async {
          final (RoomController controller, FakeTransport transport, _) =
              await _connectedController(hostSeat: 1);
          addTearDown(controller.dispose);
          expect(controller.seat, 1);
          expect(controller.seatToken, isNotNull);
          final String tokenBefore = controller.seatToken!;

          transport.endFromFarSide();
          await pumpEventQueue();

          expect(controller.phase, RoomPhase.closed);
          expect(controller.seat, 1);
          expect(controller.seatToken, tokenBefore);
        },
      );
    },
  );

  // --- Rule 6, corrected mid-task by the master (see file header, ------
  // --- ambiguity 2): player_joined adds an absent seat; player_left and -
  // --- presence still ignore a delta naming a seat that is not present. -
  group('rule 6: the three lobby deltas, corrected rule', () {
    Future<(RoomController, FakeTransport)> setup() async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      final Future<void> future = controller.createRoom(
        name: 'Sam',
        players: 2,
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok'},
        ),
      );
      transport.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(
            players: 2,
            // room.seats holds only occupied seats, matching
            // packages/ludo_server/lib/src/registry.dart:395-409: seat 1
            // is not yet on the wire because nobody has joined it.
            seats: <Map<String, Object?>>[
              _seatJson(0, name: 'Sam', connected: true),
            ],
            seq: 5,
          ),
        ),
      );
      await future;
      return (controller, transport);
    }

    test('player_joined adds a seat absent from room.seats, with the '
        "server's own lobby defaults, notifies, and advances room.seq to "
        "the delta's own seq -- the real lobby-fills sequence the "
        'original rule 6 made untestable', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      expect(
        controller.room!.seats.any((s) => s.seat == 1),
        isFalse,
        reason:
            'fixture is broken: seat 1 must be absent before the '
            'test begins',
      );

      // The wire carries only seat, name and seq (docs/PROTOCOL.md
      // section 5's player_joined row); no "connected" field.
      transport.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': 1, 'name': 'Bob', 'seq': 6},
        ),
      );
      await pumpEventQueue();

      final seat1 = controller.room!.seats.firstWhere((s) => s.seat == 1);
      expect(seat1.name, 'Bob');
      expect(
        seat1.connected,
        isTrue,
        reason:
            "packages/ludo_server/lib/src/snapshot.dart:52-56's lobby "
            'default for a freshly seated player is connected: true',
      );
      expect(seat1.tokens, <int>[-1, -1, -1, -1]);
      expect(seat1.clientSeed, isNull);
      expect(seat1.seedOrigin, isNull);
      expect(controller.room!.seq, 6);
      expect(notifyCount, greaterThan(0));
    });

    test('room.seats stays sorted by seat index after player_joined adds a '
        'seat lower than an already-present one', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      final Future<void> future = controller.createRoom(
        name: 'Bob',
        players: 2,
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 1, 'seat_token': 'tok'},
        ),
      );
      transport.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(
            hostSeat: 1,
            players: 2,
            seats: <Map<String, Object?>>[
              _seatJson(1, name: 'Bob', connected: true),
            ],
            seq: 5,
          ),
        ),
      );
      await future;

      transport.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': 0, 'name': 'Alice', 'seq': 6},
        ),
      );
      await pumpEventQueue();

      expect(
        controller.room!.seats.map((s) => s.seat).toList(),
        <int>[0, 1],
        reason:
            'packages/ludo_server/lib/src/registry.dart re-sorts seats '
            'on every join; a client that only appends diverges from '
            "the server's own ordering",
      );
    });

    test("player_joined for an already-present seat updates that seat's "
        'name rather than duplicating the entry', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);

      transport.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': 0, 'name': 'Renamed', 'seq': 6},
        ),
      );
      await pumpEventQueue();

      expect(
        controller.room!.seats.where((s) => s.seat == 0),
        hasLength(1),
        reason: 'must update in place, not append a duplicate seat 0',
      );
      expect(controller.room!.seats.single.name, 'Renamed');
    });

    test('player_left removes the named seat from room.seats, notifies, and '
        "advances room.seq to the delta's own seq", () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      transport.pushText(
        _frame(
          type: 'player_left',
          data: <String, Object?>{'seat': 0, 'seq': 6},
        ),
      );
      await pumpEventQueue();

      expect(controller.room!.seats.any((s) => s.seat == 0), isFalse);
      expect(controller.room!.seq, 6);
      expect(notifyCount, greaterThan(0));
    });

    test("presence sets the named seat's connected, notifies, and advances "
        "room.seq to the delta's own seq", () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      transport.pushText(
        _frame(
          type: 'presence',
          data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 6},
        ),
      );
      await pumpEventQueue();

      final seat0 = controller.room!.seats.firstWhere((s) => s.seat == 0);
      expect(seat0.connected, isFalse);
      expect(controller.room!.seq, 6);
      expect(notifyCount, greaterThan(0));
    });

    test('presence naming a seat that is not in room.seats is ignored: no '
        'notify, no throw, no invented seat', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final List<int> seatsBefore = controller.room!.seats
          .map((s) => s.seat)
          .toList();
      final int seqBefore = controller.room!.seq;

      expect(
        () => transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{'seat': 1, 'connected': true, 'seq': 6},
          ),
        ),
        returnsNormally,
      );
      await pumpEventQueue();

      expect(
        controller.room!.seats.map((s) => s.seat).toList(),
        seatsBefore,
        reason: 'presence for an unlisted seat must not invent one',
      );
      expect(
        controller.room!.seq,
        seqBefore,
        reason: 'an ignored delta must not advance seq',
      );
      expect(notifyCount, 0, reason: 'an ignored delta must not notify');
    });

    test('player_left naming a seat that is not in room.seats is ignored: '
        'no notify, no throw', () async {
      final (RoomController controller, FakeTransport transport) =
          await setup();
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final List<int> seatsBefore = controller.room!.seats
          .map((s) => s.seat)
          .toList();
      final int seqBefore = controller.room!.seq;

      expect(
        () => transport.pushText(
          _frame(
            type: 'player_left',
            data: <String, Object?>{'seat': 1, 'seq': 6},
          ),
        ),
        returnsNormally,
      );
      await pumpEventQueue();

      expect(controller.room!.seats.map((s) => s.seat).toList(), seatsBefore);
      expect(controller.room!.seq, seqBefore);
      expect(notifyCount, 0);
    });
  });

  // --- Rule 7: frames re-exposes every inbound frame, survives reconnect.
  group('rule 7: frames re-exposes every inbound frame, including ignored '
      'ones, and survives reconnect()', () {
    test('a delta the reducer ignores still reaches frames', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectedController(
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', connected: true),
        ],
      );
      addTearDown(controller.dispose);
      final List<Frame> log = <Frame>[];
      controller.frames.listen(log.add);

      transport.pushText(
        _frame(
          type: 'presence',
          data: <String, Object?>{'seat': 3, 'connected': true, 'seq': 999},
        ),
      );
      await pumpEventQueue();

      expect(log.map((f) => f.type), contains('presence'));
    });

    test('a listener attached before a drop still receives frames from '
        'the new connection after reconnect()', () async {
      final (
        RoomController controller,
        FakeTransport transport1,
        _Connector connector,
      ) = await _connectedController();
      addTearDown(controller.dispose);
      final List<Frame> log = <Frame>[];
      controller.frames.listen(log.add);

      transport1.endFromFarSide();
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.closed);

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      final Future<void> reconnectFuture = controller.reconnect();
      await pumpEventQueue();
      final String id = _idOf(transport2.sentRaw.last);
      transport2.pushText(
        _frame(type: 'room', re: id, data: _roomJson(seq: 2)),
      );
      await reconnectFuture;
      expect(controller.phase, RoomPhase.connected);

      log.clear();
      transport2.pushText(
        _frame(
          type: 'presence',
          data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 3},
        ),
      );
      await pumpEventQueue();

      expect(
        log,
        isNotEmpty,
        reason:
            'a frames listener attached before the drop must still '
            'see frames from the new connection after reconnect()',
      );
      expect(log.single.type, 'presence');
    });
  });

  // --- Rule 8: seq gap. --------------------------------------------------
  group('rule 8: a seq gap sets hasDesynced and does not auto-recover', () {
    test('a lobby push whose seq is not room.seq + 1 sets hasDesynced, '
        'notifies, and opens no new transport', () async {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = await _connectedController(
        seq: 5,
      );
      addTearDown(controller.dispose);
      expect(controller.hasDesynced, isFalse);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final int callsBefore = connector.calls.length;

      transport.pushText(
        _frame(
          type: 'presence',
          data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 40},
        ),
      );
      await pumpEventQueue();

      expect(controller.hasDesynced, isTrue);
      expect(notifyCount, greaterThan(0));
      expect(
        connector.calls.length,
        callsBefore,
        reason: 'a seq gap must not trigger an automatic reconnect',
      );
    });

    test('hasDesynced clears only on a successful reconnect(), not on a '
        'failed one', () async {
      final (
        RoomController controller,
        FakeTransport transport1,
        _Connector connector,
      ) = await _connectedController();
      addTearDown(controller.dispose);

      transport1.pushText(
        _frame(
          type: 'presence',
          data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 999},
        ),
      );
      await pumpEventQueue();
      expect(controller.hasDesynced, isTrue);

      transport1.endFromFarSide();
      await pumpEventQueue();

      // A reconnect attempt that fails.
      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      final Future<void> failedReconnect = controller.reconnect();
      await pumpEventQueue();
      final String id2 = _idOf(transport2.sentRaw.last);
      transport2.pushText(
        _frame(
          type: 'error',
          re: id2,
          data: <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': 'gone'},
        ),
      );
      await expectLater(failedReconnect, completes);
      expect(
        controller.hasDesynced,
        isTrue,
        reason: 'a failed reconnect() must not clear hasDesynced',
      );

      // Then a reconnect attempt that succeeds, valid because rule 10
      // accepts reconnect() from phase failed too, and room/seatToken
      // must still be cached (rule 5).
      final FakeTransport transport3 = FakeTransport();
      connector.enqueue(transport3);
      final Future<void> okReconnect = controller.reconnect();
      await pumpEventQueue();
      final String id3 = _idOf(transport3.sentRaw.last);
      transport3.pushText(
        _frame(type: 'room', re: id3, data: _roomJson(seq: 2)),
      );
      await okReconnect;
      expect(controller.hasDesynced, isFalse);
    });

    test('a game delta carrying a seq far ahead of room.seq does not set '
        'hasDesynced, does not change room, and still reaches frames '
        '(master ruling, mid-task: gap detection is scoped to the three '
        'lobby deltas only, because this controller does not advance '
        "room.seq during play and a game delta would otherwise latch "
        'hasDesynced the instant a game started; this scoping expires '
        'when the game-state reducer lands)', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController(seq: 1);
      addTearDown(controller.dispose);
      final Object? roomBefore = controller.room;
      final List<Frame> log = <Frame>[];
      controller.frames.listen(log.add);

      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 4,
            'legal': <int>[0],
            'deadline_ms': 1000,
            'k': 1,
            'reveal': 'b' * 64,
            'seq': 9999,
          },
        ),
      );
      await pumpEventQueue();

      expect(
        controller.hasDesynced,
        isFalse,
        reason:
            'a game delta must never set hasDesynced under this '
            'scoping ruling, however far ahead its seq is',
      );
      expect(identical(controller.room, roomBefore), isTrue);
      expect(log.map((f) => f.type), contains('rolled'));
    });
  });

  // --- Rule 9: transport ending on its own. -----------------------------
  group('rule 9: the transport ending on its own, nothing outstanding', () {
    test(
      'sets phase=closed, notifies, and retains room, seat and seatToken',
      () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController(hostSeat: 2);
        addTearDown(controller.dispose);
        final Object? roomBefore = controller.room;
        final int? seatBefore = controller.seat;
        final String? tokenBefore = controller.seatToken;
        int notifyCount = 0;
        controller.addListener(() => notifyCount++);

        transport.endFromFarSide();
        await pumpEventQueue();

        expect(controller.phase, RoomPhase.closed);
        expect(notifyCount, greaterThan(0));
        expect(identical(controller.room, roomBefore), isTrue);
        expect(controller.seat, seatBefore);
        expect(controller.seatToken, tokenBefore);
      },
    );
  });

  // --- Rule 10: reconnect(). --------------------------------------------
  group('rule 10: reconnect()', () {
    test('is a silent no-op when room and seatToken are both null (never '
        'connected)', () async {
      final _Connector connector = _Connector();
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      await expectLater(controller.reconnect(), completes);
      expect(controller.phase, RoomPhase.idle);
      expect(notifyCount, 0);
      expect(connector.calls, isEmpty);
    });

    test('is a silent no-op while phase is connected, even though room and '
        'seatToken are already set', () async {
      final (RoomController controller, _, _Connector connector) =
          await _connectedController();
      addTearDown(controller.dispose);
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final int callsBefore = connector.calls.length;

      await expectLater(controller.reconnect(), completes);
      expect(controller.phase, RoomPhase.connected);
      expect(notifyCount, 0);
      expect(connector.calls.length, callsBefore);
    });

    test('is a silent no-op in phase closed when room is null (the '
        'transport dropped before any room ever arrived)', () async {
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
      transport.endFromFarSide();
      await expectLater(createFuture, completes);
      expect(controller.room, isNull);

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final int callsBefore = connector.calls.length;
      await expectLater(controller.reconnect(), completes);
      expect(notifyCount, 0);
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'reconnect() must not open a transport when room is null, '
            'regardless of phase',
      );
    });

    test(
      'is a silent no-op in phase failed when room is null (e.g. the '
      "connector's own future rejected before any room ever arrived)",
      () async {
        final _Connector connector = _Connector();
        connector.rejectNextWith(Exception('boom'));
        final RoomController controller = _newController(connector);
        addTearDown(controller.dispose);

        await expectLater(
          controller.createRoom(name: 'Sam', players: 4),
          completes,
        );
        expect(controller.phase, RoomPhase.failed);
        expect(controller.room, isNull);

        int notifyCount = 0;
        controller.addListener(() => notifyCount++);
        final int callsBefore = connector.calls.length;
        await expectLater(controller.reconnect(), completes);
        expect(notifyCount, 0);
        expect(connector.calls.length, callsBefore);
      },
    );

    test('when accepted, opens a new transport and sends resume carrying '
        "room.code and the cached seat token, verified byte-for-byte from "
        'sentRaw; on success updates room, phase and hasDesynced', () async {
      final (
        RoomController controller,
        FakeTransport transport1,
        _Connector connector,
      ) = await _connectedController(
        code: 'ZQ8MCP',
        hostSeat: 1,
      );
      addTearDown(controller.dispose);
      final String cachedToken = controller.seatToken!;
      final String code = controller.room!.code;

      transport1.endFromFarSide();
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.closed);

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      final int callsBefore = connector.calls.length;
      final Future<void> reconnectFuture = controller.reconnect();
      await pumpEventQueue();

      expect(
        connector.calls.length,
        callsBefore + 1,
        reason: 'reconnect() must open a second, new transport',
      );
      expect(transport2.sentRaw, isNotEmpty);
      final Map<String, Object?> sent = _decode(transport2.sentRaw.last);
      expect(sent['t'], 'resume');
      expect(
        sent['d'],
        equals(<String, Object?>{'code': code, 'seat_token': cachedToken}),
        reason:
            'the bytes actually sent for resume must carry room.code '
            'and the cached seat token, got d=${sent['d']}',
      );

      final String id = sent['id']! as String;
      transport2.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(code: code, hostSeat: 1, seq: 7),
        ),
      );
      await reconnectFuture;

      expect(controller.phase, RoomPhase.connected);
      expect(controller.room!.seq, 7);
      expect(controller.hasDesynced, isFalse);
    });
  });

  // --- Rule 11: setPlayers/startGame. ------------------------------------
  group(
    'rule 11: setPlayers and startGame forward only in phase connected',
    () {
      test('setPlayers is a silent no-op outside phase connected', () async {
        final _Connector connector = _Connector();
        final RoomController controller = _newController(connector);
        addTearDown(controller.dispose);
        int notifyCount = 0;
        controller.addListener(() => notifyCount++);

        await expectLater(controller.setPlayers(3), completes);
        expect(controller.phase, RoomPhase.idle);
        expect(notifyCount, 0);
        expect(connector.calls, isEmpty);
      });

      test('startGame is a silent no-op outside phase connected', () async {
        final _Connector connector = _Connector();
        final RoomController controller = _newController(connector);
        addTearDown(controller.dispose);
        int notifyCount = 0;
        controller.addListener(() => notifyCount++);

        await expectLater(controller.startGame(), completes);
        expect(controller.phase, RoomPhase.idle);
        expect(notifyCount, 0);
        expect(connector.calls, isEmpty);
      });

      test('setPlayers replaces room with the snapshot it gets back', () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController(players: 4);
        addTearDown(controller.dispose);

        final Future<void> future = controller.setPlayers(2);
        await pumpEventQueue();
        final String id = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(type: 'room', re: id, data: _roomJson(players: 2, seq: 9)),
        );
        await future;

        expect(controller.room!.players, 2);
        expect(controller.room!.seq, 9);
        expect(controller.phase, RoomPhase.connected);
      });

      test("startGame's reply is a plain frame and must not be parsed as a "
          'snapshot; room is left untouched by it', () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController();
        addTearDown(controller.dispose);
        final Object? roomBefore = controller.room;

        final Future<void> future = controller.startGame();
        await pumpEventQueue();
        final String id = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(
            type: 'game_started',
            re: id,
            data: <String, Object?>{
              'turn': 0,
              'game_id': 'a' * 16,
              'client_seeds': '0:seed',
              'seq': 10,
            },
          ),
        );

        await expectLater(future, completes);
        expect(controller.phase, RoomPhase.connected);
        expect(
          identical(controller.room, roomBefore),
          isTrue,
          reason:
              "startGame's reply (game_started) is not a room snapshot "
              'and must not overwrite room',
        );
      });
    },
  );

  // --- Rule 12: leave(). ---------------------------------------------
  group('rule 12: leave()', () {
    test(
      'sends leave_room, closes the transport, and sets phase=closed',
      () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController();
        addTearDown(controller.dispose);

        final Future<void> future = controller.leave();
        await pumpEventQueue();

        // Push a plausible reply only if leave_room actually went out and
        // the transport is still open; see file header, ambiguity 4, for
        // why this is conditional rather than assumed either way.
        if (!transport.isClosed && transport.sentRaw.isNotEmpty) {
          final Map<String, Object?> sent = _decode(transport.sentRaw.last);
          if (sent['t'] == 'leave_room') {
            transport.pushText(
              _frame(
                type: 'player_left',
                re: sent['id']! as String,
                data: <String, Object?>{'seat': 0, 'seq': 2},
              ),
            );
          }
        }
        await expectLater(future, completes);

        expect(
          transport.sentRaw.any(
            (String raw) => _decode(raw)['t'] == 'leave_room',
          ),
          isTrue,
          reason: 'leave() must send leave_room',
        );
        expect(controller.phase, RoomPhase.closed);
        expect(
          transport.closeCalls,
          isNotEmpty,
          reason: 'leave() must close the underlying transport',
        );
      },
    );

    test('never throws even when the socket already died before leave() '
        'was called', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController();
      addTearDown(controller.dispose);
      transport.endFromFarSide();
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.closed);

      late Future<void> future;
      expect(() => future = controller.leave(), returnsNormally);
      await expectLater(future, completes);
    });

    test('never throws when called from idle, before any connection was '
        'ever attempted', () async {
      final _Connector connector = _Connector();
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      late Future<void> future;
      expect(() => future = controller.leave(), returnsNormally);
      await expectLater(future, completes);
    });
  });

  // --- Rule 13: dispose(). ------------------------------------------
  group('rule 13: dispose() is safe to call in any phase', () {
    test('phase idle, no connection ever attempted', () {
      final _Connector connector = _Connector();
      final RoomController controller = _newController(connector);
      expect(controller.dispose, returnsNormally);
    });

    test('phase connecting, unresolved', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      unawaitedFuture(controller.createRoom(name: 'Sam', players: 4));
      expect(controller.phase, RoomPhase.connecting);
      expect(controller.dispose, returnsNormally);
    });

    test('phase connected: dispose() closes the live transport', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController();
      expect(controller.dispose, returnsNormally);
      await pumpEventQueue();
      expect(
        transport.closeCalls,
        isNotEmpty,
        reason: 'dispose() must close a live connection',
      );
    });

    test('phase failed', () async {
      final _Connector connector = _Connector();
      connector.rejectNextWith(Exception('boom'));
      final RoomController controller = _newController(connector);
      await expectLater(
        controller.createRoom(name: 'Sam', players: 4),
        completes,
      );
      expect(controller.phase, RoomPhase.failed);
      expect(controller.dispose, returnsNormally);
    });

    test('phase closed', () async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectedController();
      transport.endFromFarSide();
      await pumpEventQueue();
      expect(controller.phase, RoomPhase.closed);
      expect(controller.dispose, returnsNormally);
    });
  });

  // --- Rule 14: isHost. ------------------------------------------------
  group('rule 14: isHost == room != null && seat != null && room!.hostSeat '
      '== seat', () {
    test('true when this seat is the host seat', () async {
      final (RoomController controller, _, _) = await _connectedController(
        hostSeat: 2,
      );
      addTearDown(controller.dispose);
      expect(controller.seat, 2);
      expect(controller.room!.hostSeat, 2);
      expect(controller.isHost, isTrue);
    });

    test('false when this seat is not the host seat', () async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      final Future<void> future = controller.joinRoom(
        code: 'K7M2QP',
        name: 'Bob',
      );
      await pumpEventQueue();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 1, 'seat_token': 'tok-guest'},
        ),
      );
      transport.pushText(
        _frame(type: 'room', re: id, data: _roomJson(hostSeat: 0, seq: 1)),
      );
      await future;

      expect(controller.seat, 1);
      expect(controller.room!.hostSeat, 0);
      expect(controller.isHost, isFalse);
    });

    test('false before any room exists (seat and room both null)', () {
      final _Connector connector = _Connector();
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);
      expect(controller.room, isNull);
      expect(controller.seat, isNull);
      expect(controller.isHost, isFalse);
    });
  });

  // --- Rule 15: game deltas are inert here. -----------------------------
  group('rule 15: game deltas are inert here; they reach frames and change '
      'no controller state', () {
    final List<(String, Map<String, Object?>)> gameDeltas =
        <(String, Map<String, Object?>)>[
          (
            'rolled',
            <String, Object?>{
              'seat': 0,
              'value': 4,
              'legal': <int>[0],
              'deadline_ms': 1000,
              'k': 1,
              'reveal': 'b' * 64,
              'seq': 2,
            },
          ),
          (
            'moved',
            <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': -1,
              'to': 0,
              'captured': <Object?>[],
              'extra_roll': false,
              'seq': 2,
            },
          ),
          (
            'turn',
            <String, Object?>{'seat': 1, 'deadline_ms': 45000, 'seq': 2},
          ),
          (
            'turn_passed',
            <String, Object?>{'seat': 0, 'reason': 'no_legal_move', 'seq': 2},
          ),
          (
            'game_started',
            <String, Object?>{
              'turn': 0,
              'game_id': 'a' * 16,
              'client_seeds': '0:seed',
              'seq': 2,
            },
          ),
          (
            'game_over',
            <String, Object?>{
              'winner': 0,
              'verify_url': 'https://provefair.app/v/abc',
              'seq': 2,
            },
          ),
          (
            'seat_seed',
            <String, Object?>{
              'seat': 0,
              'client_seed': 'seed',
              'origin': 'player',
              'seq': 2,
            },
          ),
        ];

    for (final (String type, Map<String, Object?> data) in gameDeltas) {
      test('$type reaches frames and leaves room unchanged', () async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectedController(seq: 1);
        addTearDown(controller.dispose);
        final Object? roomBefore = controller.room;
        final List<Frame> log = <Frame>[];
        controller.frames.listen(log.add);

        transport.pushText(_frame(type: type, data: data));
        await pumpEventQueue();

        expect(log.map((f) => f.type), contains(type));
        expect(
          identical(controller.room, roomBefore),
          isTrue,
          reason:
              '$type must change no controller state; room must '
              'be untouched',
        );
      });
    }
  });
}

/// A fire-and-forget helper for the rare case a test needs to leave a
/// request outstanding without holding onto its Future, kept as a named
/// function (rather than package:pedantic's unawaited, not a dependency
/// here) purely so `dart format`/the unawaited_futures lint has something
/// unambiguous to see was deliberate.
void unawaitedFuture(Future<void> future) {}

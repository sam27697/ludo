// Conformance tests for lib/src/net/connection.dart's RoomConnection,
// written from docs/PROTOCOL.md sections 1, 2, 4, 5, 7 and 8, from the
// frozen declaration block of work order 070, and from the thirteen rulings
// listed in that order, against no implementation of connection.dart the
// author of this file has read. connection.dart does not exist on the
// branch this file was written on.
//
// Every negative test asserts the exception TYPE, never just "throws":
// throwsA(isA<ConnectionClosedException>()), never throwsException, for the
// same reason frame_test.dart and snapshot_test.dart give: a bare
// throwsException also passes on a TypeError or a StateError escaping from
// a careless cast or a double-completed Completer, which is exactly the
// class of defect this file exists to catch.
//
// Corners the frozen block and the thirteen rulings leave open, reported
// rather than guessed at:
//
//   1. Whether RoomConnection.close() must call the underlying transport's
//      close() at all, and with what code, is not one of the thirteen
//      numbered rulings. It is inferred here from two things that are
//      pinned: WireTransport.close's doc comment ("a client closing
//      deliberately has no reason to send anything but 1000") and the fact
//      that the engine owns exactly one transport per open(). Tested as
//      "close() closes the transport with code 1000"; flagged here as an
//      inference, not a quotation.
//   2. Whether the error out of a rejected connector future must propagate
//      byte-identical (the same object) or may be wrapped is not stated.
//      "Propagates that error" is read literally and tested with same().
//   3. Rule 3 says a malformed seat_assigned "leaves them unset". Only the
//      case where seat/seatToken were already null (no prior valid
//      seat_assigned) is tested, which is the unambiguous reading. Whether
//      a malformed seat_assigned arriving after a VALID one must clear an
//      already-populated seat/seatToken back to null is not stated and is
//      left untested.
//   4. fake_async is confirmed NOT a dev_dependency of packages/ludo_client
//      (read from pubspec.yaml before writing this file), so per the
//      order's instruction it was not added. The requestTimeout tests use a
//      short real Duration and await the actual Future the API returns;
//      nothing here sleeps blind.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/connection.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const _testUrl = 'wss://example.test/ws';
final _idShape = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

// --- server-side id generation for pushed frames ---------------------------
//
// Server-generated ids only have to satisfy the same shape rule as
// client-generated ones (docs/PROTOCOL.md section 1); nothing pins them to
// look like the real server's ids, and no test here depends on their exact
// value, only on their shape and on re-matching.
int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers -----------------------------------------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id'] as String;

Map<String, Object?> _without(Map<String, Object?> json, String key) {
  final copy = Map<String, Object?>.from(json);
  copy.remove(key);
  return copy;
}

/// A server push or reply, encoded exactly as Frame.decode expects.
String _serverFrame({
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

Map<String, Object?> _validRoomJson({
  String code = 'K7M2QP',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
  Map<String, Object?>? rules,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules':
      rules ??
      <String, Object?>{
        'blocks': true,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Object?>[
    <String, Object?>{
      'seat': 0,
      'name': 'Sam',
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    },
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
};

// --- connection construction -------------------------------------------------

/// Builds and opens a RoomConnection against a fresh FakeTransport.
Future<(RoomConnection, FakeTransport)> _openConnection({
  Duration requestTimeout = const Duration(seconds: 10),
}) async {
  final transport = FakeTransport();
  final connection = RoomConnection(
    url: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
    requestTimeout: requestTimeout,
  );
  await connection.open();
  return (connection, transport);
}

void main() {
  // --- Rule 1: every inbound frame reaches frames, in arrival order, -------
  // --- including a frame that also completed a pending request. -----------
  group('rule 1: frames sees every inbound frame in arrival order', () {
    test(
      'leave_room\'s reply (player_left, with re) both completes the '
      'request and appears on frames, in the correct arrival position',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);

        final framesLog = <Frame>[];
        connection.frames.listen(framesLog.add);

        transport.pushText(
          _serverFrame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 1, 'name': 'Bob', 'seq': 2},
          ),
        );
        await pumpEventQueue();

        final leaveFuture = connection.leaveRoom();
        await pumpEventQueue();
        final leaveId = _idOf(transport.sentRaw.last);

        transport.pushText(
          _serverFrame(
            type: 'player_left',
            re: leaveId,
            data: <String, Object?>{'seat': 0, 'seq': 3},
          ),
        );
        await pumpEventQueue();

        transport.pushText(
          _serverFrame(
            type: 'presence',
            data: <String, Object?>{'seat': 2, 'connected': false, 'seq': 4},
          ),
        );
        await pumpEventQueue();

        final leftFrame = await leaveFuture;
        expect(leftFrame.type, 'player_left');
        expect(leftFrame.re, leaveId);
        expect(leftFrame.data['seat'], 0);

        expect(
          framesLog.map((f) => f.type).toList(),
          <String>['player_joined', 'player_left', 'presence'],
          reason:
              'frames must see every inbound frame in arrival order; got '
              '${framesLog.map((f) => f.type).toList()}',
        );
        expect(
          framesLog[1].re,
          leaveId,
          reason:
              'the player_left on frames must be the exact same reply that '
              'completed leaveRoom(), carrying its re',
        );
        expect(framesLog[1].data['seat'], leftFrame.data['seat']);
      },
    );
  });

  // --- Rule 2: correlation is by re only. -----------------------------------
  group('rule 2: correlation is by re only', () {
    test(
      'a frame with no re completes nothing and appears on frames',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);

        final framesLog = <Frame>[];
        connection.frames.listen(framesLog.add);

        transport.pushText(
          _serverFrame(
            type: 'presence',
            data: <String, Object?>{'seat': 1, 'connected': true, 'seq': 5},
          ),
        );
        await pumpEventQueue();

        expect(framesLog, hasLength(1));
        expect(framesLog.single.type, 'presence');
        expect(framesLog.single.re, isNull);
      },
    );

    test('a frame whose re matches nothing outstanding completes nothing and '
        'appears on frames', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      final framesLog = <Frame>[];
      connection.frames.listen(framesLog.add);

      // Well-shaped re (satisfies the id rule) that was never sent as a
      // request id by this connection.
      transport.pushText(
        _serverFrame(
          type: 'error',
          re: 'ZZZZZZZZ',
          data: <String, Object?>{'code': 'INTERNAL', 'message': 'x'},
        ),
      );
      await pumpEventQueue();

      expect(framesLog, hasLength(1));
      expect(framesLog.single.re, 'ZZZZZZZZ');
    });

    test('two concurrent requests get their own replies even out of order, and '
        'a reply matching A never completes B', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      final futureA = connection.ping();
      await pumpEventQueue();
      final idA = _idOf(transport.sentRaw[0]);

      final futureB = connection.roll();
      await pumpEventQueue();
      final idB = _idOf(transport.sentRaw[1]);

      expect(idA, isNot(equals(idB)));

      // Reply to B first, then A: out of arrival order relative to the
      // requests, to prove correlation does not depend on send order.
      transport.pushText(
        _serverFrame(
          type: 'rolled',
          re: idB,
          data: <String, Object?>{
            'seat': 0,
            'value': 4,
            'legal': <int>[0],
            'deadline_ms': 1000,
            'k': 1,
            'reveal': 'b' * 64,
            'seq': 10,
          },
        ),
      );
      transport.pushText(_serverFrame(type: 'pong', re: idA));

      final frameB = await futureB;
      final frameA = await futureA;

      expect(frameB.re, idB, reason: 'B\'s reply must carry re == idB');
      expect(frameA.re, idA, reason: 'A\'s reply must carry re == idA');
      expect(frameB.type, 'rolled');
      expect(frameA.type, 'pong');
    });
  });

  // --- Rule 3: seat_assigned is a push with re: null. -----------------------
  group('rule 3: seat_assigned', () {
    test(
      'seat and seatToken are null before any seat_assigned arrives',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);
        expect(connection.seat, isNull);
        expect(connection.seatToken, isNull);
      },
    );

    test('a well-formed seat_assigned, arriving immediately before the room '
        'reply, populates seat and seatToken by the time the request '
        'resolves', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      final createFuture = connection.createRoom(name: 'Sam', players: 4);
      await pumpEventQueue();
      final requestId = _idOf(transport.sentRaw.last);

      transport.pushText(
        _serverFrame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 2, 'seat_token': 'tok-abc123'},
        ),
      );
      await pumpEventQueue();
      expect(connection.seat, 2);
      expect(connection.seatToken, 'tok-abc123');

      transport.pushText(
        _serverFrame(type: 'room', re: requestId, data: _validRoomJson(seq: 1)),
      );
      final snapshot = await createFuture;

      expect(connection.seat, 2);
      expect(connection.seatToken, 'tok-abc123');
      expect(snapshot.code, 'K7M2QP');
    });

    Future<void> expectMalformedSeatAssignedLeavesUnsetButForwarded(
      String label,
      Map<String, Object?> data,
    ) async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      final framesLog = <Frame>[];
      connection.frames.listen(framesLog.add);

      transport.pushText(_serverFrame(type: 'seat_assigned', data: data));
      await pumpEventQueue();

      expect(
        connection.seat,
        isNull,
        reason:
            'seat must be left unset for a malformed seat_assigned '
            '($label): d=$data',
      );
      expect(
        connection.seatToken,
        isNull,
        reason:
            'seatToken must be left unset for a malformed seat_assigned '
            '($label): d=$data',
      );
      expect(
        framesLog,
        hasLength(1),
        reason:
            'the malformed seat_assigned ($label) must still be '
            'forwarded to frames: d=$data',
      );
      expect(framesLog.single.type, 'seat_assigned');
    }

    test('seat out of 0..3 leaves seat/seatToken unset, still forwarded', () {
      return expectMalformedSeatAssignedLeavesUnsetButForwarded(
        'seat: 4, one over the maximum',
        <String, Object?>{'seat': 4, 'seat_token': 'tok'},
      );
    });

    test('seat missing leaves seat/seatToken unset, still forwarded', () {
      return expectMalformedSeatAssignedLeavesUnsetButForwarded(
        'seat missing entirely',
        <String, Object?>{'seat_token': 'tok'},
      );
    });

    test(
      'seat_token not a String leaves seat/seatToken unset, still forwarded',
      () {
        return expectMalformedSeatAssignedLeavesUnsetButForwarded(
          'seat_token as an int',
          <String, Object?>{'seat': 1, 'seat_token': 12345},
        );
      },
    );
  });

  // --- Rule 4: lastSeq is observed, never enforced. -------------------------
  group('rule 4: lastSeq', () {
    test('is null before the first frame carrying seq', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      expect(connection.lastSeq, isNull);
    });

    test('rises to the highest seq seen', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      transport.pushText(
        _serverFrame(
          type: 'presence',
          data: <String, Object?>{'seat': 1, 'connected': true, 'seq': 5},
        ),
      );
      await pumpEventQueue();
      expect(connection.lastSeq, 5);

      transport.pushText(
        _serverFrame(
          type: 'presence',
          data: <String, Object?>{'seat': 2, 'connected': true, 'seq': 9},
        ),
      );
      await pumpEventQueue();
      expect(connection.lastSeq, 9);
    });

    test('a frame with no seq (error, pong, seat_assigned) does not move '
        'lastSeq', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      transport.pushText(
        _serverFrame(
          type: 'presence',
          data: <String, Object?>{'seat': 1, 'connected': true, 'seq': 7},
        ),
      );
      await pumpEventQueue();
      expect(connection.lastSeq, 7);

      transport.pushText(_serverFrame(type: 'pong'));
      transport.pushText(
        _serverFrame(
          type: 'error',
          data: <String, Object?>{'code': 'INTERNAL', 'message': 'x'},
        ),
      );
      transport.pushText(
        _serverFrame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok'},
        ),
      );
      await pumpEventQueue();

      expect(
        connection.lastSeq,
        7,
        reason:
            'seq-less frames (error, pong, seat_assigned) must not '
            'move lastSeq',
      );
    });

    test('a gap in seq provokes nothing: no close, no throw, connection stays '
        'open and still serves requests', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      transport.pushText(
        _serverFrame(
          type: 'presence',
          data: <String, Object?>{'seat': 1, 'connected': true, 'seq': 3},
        ),
      );
      await pumpEventQueue();
      expect(connection.lastSeq, 3);

      // A gap: jumps straight from 3 to 40.
      transport.pushText(
        _serverFrame(
          type: 'presence',
          data: <String, Object?>{'seat': 2, 'connected': true, 'seq': 40},
        ),
      );
      await pumpEventQueue();

      expect(connection.lastSeq, 40);
      expect(connection.isOpen, isTrue);
      expect(
        transport.closeCalls,
        isEmpty,
        reason:
            'a seq gap must not cause the engine to close the '
            'transport; docs/PROTOCOL.md leaves gap recovery to a client '
            'that chooses to resume, never to the engine itself',
      );

      final pingFuture = connection.ping();
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(_serverFrame(type: 'pong', re: id));
      final reply = await pingFuture;
      expect(
        reply.type,
        'pong',
        reason:
            'the connection must still be able to serve a request '
            'after a seq gap',
      );
    });
  });

  // --- Rule 5: a malformed inbound frame is dropped, connection survives. --
  group('rule 5: malformed inbound frames', () {
    test('raw non-JSON, a JSON array, v as a String, and a frame over '
        'maxFrameBytes are all dropped: none reach frames, none throw '
        'observably, and a request afterward still works', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      final framesLog = <Frame>[];
      connection.frames.listen(framesLog.add);

      transport.pushText('this is not json {{{ at all');
      await pumpEventQueue();

      transport.pushText('[]');
      await pumpEventQueue();

      transport.pushText(
        jsonEncode(<String, Object?>{
          'v': '1',
          't': 'ping',
          'id': _nextServerId(),
          'd': <String, Object?>{},
        }),
      );
      await pumpEventQueue();

      final oversized = jsonEncode(<String, Object?>{
        'v': 1,
        't': 'ping',
        'id': _nextServerId(),
        'd': <String, Object?>{'pad': 'a' * maxFrameBytes},
      });
      expect(
        utf8.encode(oversized).length,
        greaterThan(maxFrameBytes),
        reason: 'fixture is broken: this frame must exceed maxFrameBytes',
      );
      transport.pushText(oversized);
      await pumpEventQueue();

      expect(
        framesLog,
        isEmpty,
        reason:
            'none of the four malformed pushes above may appear on '
            'frames; got ${framesLog.map((f) => f.type).toList()}',
      );
      expect(connection.isOpen, isTrue);

      final pingFuture = connection.ping();
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(_serverFrame(type: 'pong', re: id));
      final reply = await pingFuture;
      expect(
        reply.type,
        'pong',
        reason:
            'a request issued after the malformed pushes must still '
            'work',
      );
    });
  });

  // --- Rule 6: the four snapshot methods. -----------------------------------
  group('rule 6: the four snapshot methods return RoomSnapshot.fromJson', () {
    test('createRoom', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.createRoom(name: 'Sam', players: 3);
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: id,
          data: _validRoomJson(players: 3, seq: 1),
        ),
      );
      final snapshot = await future;
      expect(snapshot.players, 3);
      expect(snapshot.code, 'K7M2QP');
    });

    test('joinRoom', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.joinRoom(code: 'K7M2QP', name: 'Sam');
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _serverFrame(type: 'room', re: id, data: _validRoomJson(seq: 2)),
      );
      final snapshot = await future;
      expect(snapshot.code, 'K7M2QP');
      expect(snapshot.seq, 2);
    });

    test('resume', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.resume(code: 'K7M2QP', seatToken: 'tok');
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: id,
          data: _validRoomJson(state: 'FINISHED', seq: 40),
        ),
      );
      final snapshot = await future;
      expect(snapshot.state, RoomState.finished);
      expect(snapshot.seq, 40);
    });

    test('setPlayers', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.setPlayers(3);
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: id,
          data: _validRoomJson(players: 3, seq: 3),
        ),
      );
      final snapshot = await future;
      expect(snapshot.players, 3);
    });

    test('a reply whose t is not "room" throws FrameFormatException, not '
        'ProtocolErrorException', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.joinRoom(code: 'K7M2QP', name: 'Sam');
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      // "pong" rather than "error": t not "room" and not "error" either,
      // so this exercises the generic mismatch path, not rule 8's.
      transport.pushText(_serverFrame(type: 'pong', re: id));
      await expectLater(future, throwsA(isA<FrameFormatException>()));
    });

    test(
      'a SnapshotFormatException out of fromJson propagates unchanged',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);
        final future = connection.resume(code: 'K7M2QP', seatToken: 'tok');
        await pumpEventQueue();
        final id = _idOf(transport.sentRaw.last);
        final brokenRoom = _without(_validRoomJson(), 'code');
        transport.pushText(
          _serverFrame(type: 'room', re: id, data: brokenRoom),
        );
        await expectLater(future, throwsA(isA<SnapshotFormatException>()));
      },
    );
  });

  // --- Rule 7: createRoom's rules field, docs/PROTOCOL.md section 13.4. ----
  group('rule 7: createRoom rules on the wire', () {
    test('rules is omitted entirely when the argument is null', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.createRoom(name: 'Sam', players: 4);
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      final data = sent['d'] as Map<String, Object?>;
      expect(
        data.containsKey('rules'),
        isFalse,
        reason:
            'an absent rules argument must not put "rules": null (or '
            'anything else) on the wire; d was: $data',
      );
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: sent['id'] as String,
          data: _validRoomJson(),
        ),
      );
      await future;
    });

    test('rules emits exactly the three documented keys, in the values given, '
        'when the argument is not null', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      const rules = RulesConfig(
        blocks: false,
        captureBonus: true,
        turnSeconds: 30,
      );
      final future = connection.createRoom(
        name: 'Sam',
        players: 4,
        rules: rules,
      );
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      final data = sent['d'] as Map<String, Object?>;
      expect(
        data['rules'],
        equals(<String, Object?>{
          'blocks': false,
          'capture_bonus': true,
          'turn_seconds': 30,
        }),
        reason:
            'expected exactly the three documented keys with the '
            'RulesConfig\'s own values, got: ${data['rules']}',
      );
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: sent['id'] as String,
          data: _validRoomJson(),
        ),
      );
      await future;
    });
  });

  // --- Rule 8: an error reply. ----------------------------------------------
  group('rule 8: an error reply', () {
    test('completes the request with ProtocolErrorException carrying code, '
        'message and the frame', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.roll();
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _serverFrame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'NOT_YOUR_TURN',
            'message': 'not your turn',
          },
        ),
      );
      await expectLater(
        future,
        throwsA(
          isA<ProtocolErrorException>()
              .having((e) => e.code, 'code', 'NOT_YOUR_TURN')
              .having((e) => e.message, 'message', 'not your turn')
              .having((e) => e.frame.type, 'frame.type', 'error')
              .having((e) => e.frame.re, 'frame.re', id),
        ),
      );
    });

    test('message is "" when the field is absent, never null', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.roll();
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _serverFrame(
          type: 'error',
          re: id,
          data: <String, Object?>{'code': 'INTERNAL'},
        ),
      );
      await expectLater(
        future,
        throwsA(
          isA<ProtocolErrorException>().having((e) => e.message, 'message', ''),
        ),
      );
    });

    test('message is "" when the field is present but not a String', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.roll();
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _serverFrame(
          type: 'error',
          re: id,
          data: <String, Object?>{'code': 'INTERNAL', 'message': 42},
        ),
      );
      await expectLater(
        future,
        throwsA(
          isA<ProtocolErrorException>().having((e) => e.message, 'message', ''),
        ),
      );
    });

    test(
      'an error with no re completes nothing and lands on frames; the '
      'outstanding request is untouched and resolves normally afterward',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);

        final framesLog = <Frame>[];
        connection.frames.listen(framesLog.add);

        final future = connection.roll();
        await pumpEventQueue();

        transport.pushText(
          _serverFrame(
            type: 'error',
            data: <String, Object?>{'code': 'INTERNAL', 'message': 'bad'},
          ),
        );
        await pumpEventQueue();

        expect(framesLog, hasLength(1));
        expect(framesLog.single.type, 'error');
        expect(framesLog.single.re, isNull);

        // Because a Future can only ever complete once: if the unmatched
        // error above had wrongly completed `future`, awaiting it now would
        // yield the ProtocolErrorException rather than the real reply below.
        final id = _idOf(transport.sentRaw.last);
        transport.pushText(
          _serverFrame(
            type: 'rolled',
            re: id,
            data: <String, Object?>{
              'seat': 0,
              'value': 5,
              'legal': <int>[1],
              'deadline_ms': 500,
              'k': 1,
              'reveal': 'c' * 64,
              'seq': 12,
            },
          ),
        );
        final reply = await future;
        expect(reply.type, 'rolled');
      },
    );
  });

  // --- Rule 9: requestTimeout. -----------------------------------------------
  group('rule 9: requestTimeout', () {
    test('no reply within requestTimeout completes the request with '
        'RequestTimeoutException carrying the request\'s t', () async {
      final (connection, transport) = await _openConnection(
        requestTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(connection.close);
      final future = connection.ping();
      await expectLater(
        future,
        throwsA(
          isA<RequestTimeoutException>().having((e) => e.type, 'type', 'ping'),
        ),
      );
    });

    test('a reply arriving after the timeout is treated as an unmatched push, '
        'lands on frames, and does not throw into the zone', () async {
      final (connection, transport) = await _openConnection(
        requestTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(connection.close);

      final framesLog = <Frame>[];
      connection.frames.listen(framesLog.add);

      final future = connection.ping();
      await pumpEventQueue();
      final id = _idOf(transport.sentRaw.last);

      await expectLater(future, throwsA(isA<RequestTimeoutException>()));

      transport.pushText(_serverFrame(type: 'pong', re: id));
      await pumpEventQueue();

      expect(framesLog, hasLength(1));
      expect(framesLog.single.type, 'pong');
      expect(framesLog.single.re, id);
      expect(
        connection.isOpen,
        isTrue,
        reason:
            'a late reply must not be treated as a protocol '
            'violation that closes the connection',
      );
    });
  });

  // --- Rule 10: transport end. -----------------------------------------------
  group('rule 10: transport end', () {
    test('every outstanding request completes with ConnectionClosedException '
        'when the far end vanishes', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      final f1 = connection.ping();
      final f2 = connection.roll();
      await pumpEventQueue();

      transport.endFromFarSide();

      await expectLater(f1, throwsA(isA<ConnectionClosedException>()));
      await expectLater(f2, throwsA(isA<ConnectionClosedException>()));
    });

    test(
      'isOpen goes false and done completes when the far end vanishes',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);
        expect(connection.isOpen, isTrue);

        transport.endFromFarSide();
        await connection.done;

        expect(connection.isOpen, isFalse);
      },
    );

    test('frames closes without an error when the far end vanishes', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      Object? sawError;
      var sawDone = false;
      connection.frames.listen(
        (_) {},
        onError: (Object e) => sawError = e,
        onDone: () => sawDone = true,
      );

      transport.endFromFarSide();
      await connection.done;
      await pumpEventQueue();

      expect(
        sawDone,
        isTrue,
        reason: 'frames must close when the link is gone',
      );
      expect(
        sawError,
        isNull,
        reason: 'frames must close without an error, got $sawError',
      );
    });

    test(
      'a request made after the transport ended completes with '
      'ConnectionClosedException rather than throwing synchronously',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);

        transport.endFromFarSide();
        await connection.done;

        late Future<Frame> future;
        expect(() => future = connection.ping(), returnsNormally);
        await expectLater(future, throwsA(isA<ConnectionClosedException>()));
      },
    );

    test(
      'a request on a connection that was never opened completes with '
      'ConnectionClosedException rather than throwing synchronously',
      () async {
        final transport = FakeTransport();
        final connection = RoomConnection(
          url: Uri.parse(_testUrl),
          connect: (Uri url) async => transport,
        );
        late Future<Frame> future;
        expect(() => future = connection.ping(), returnsNormally);
        await expectLater(future, throwsA(isA<ConnectionClosedException>()));
      },
    );

    test('close() is idempotent', () async {
      final (connection, transport) = await _openConnection();
      await connection.close();
      expect(connection.isOpen, isFalse);
      await expectLater(connection.close(), completes);
    });

    test('a request on a connection closed locally completes with '
        'ConnectionClosedException', () async {
      final (connection, transport) = await _openConnection();
      await connection.close();
      late Future<Frame> future;
      expect(() => future = connection.ping(), returnsNormally);
      await expectLater(future, throwsA(isA<ConnectionClosedException>()));
    });

    test('close() closes the underlying transport with the normal-closure '
        'code (1000); an inference from WireTransport\'s doc comment, not '
        'one of the thirteen numbered rulings', () async {
      final (connection, transport) = await _openConnection();
      await connection.close();
      expect(
        transport.closeCalls,
        isNotEmpty,
        reason:
            'RoomConnection.close() should close its transport so '
            'the underlying socket does not leak',
      );
      expect(transport.closeCalls.first, 1000);
    });
  });

  // --- Rule 11: open(). --------------------------------------------------
  group('rule 11: open()', () {
    test('isOpen is false before open() is called', () {
      final transport = FakeTransport();
      final connection = RoomConnection(
        url: Uri.parse(_testUrl),
        connect: (Uri url) async => transport,
      );
      expect(connection.isOpen, isFalse);
    });

    test('calling open() a second time throws StateError', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      await expectLater(connection.open(), throwsA(isA<StateError>()));
    });

    test('when the connector\'s future rejects, open() propagates that error '
        'unchanged and leaves isOpen false', () async {
      final boom = Exception('connect failed');
      final connection = RoomConnection(
        url: Uri.parse(_testUrl),
        connect: (Uri url) => Future<WireTransport>.error(boom),
      );
      await expectLater(connection.open(), throwsA(same(boom)));
      expect(connection.isOpen, isFalse);
    });
  });

  // --- Rule 12: message ids. ------------------------------------------------
  group('rule 12: message ids', () {
    test('every request carries a fresh id matching ^[A-Za-z0-9_-]{8,64}\$, '
        'and no two requests on one connection share one', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      final futures = <Future<Frame>>[
        connection.ping(),
        connection.ping(),
        connection.roll(),
        connection.startGame(),
        connection.leaveRoom(),
      ];
      await pumpEventQueue();

      expect(transport.sentRaw, hasLength(5));
      final ids = transport.sentRaw.map(_idOf).toList();
      for (final id in ids) {
        expect(
          _idShape.hasMatch(id),
          isTrue,
          reason: 'id "$id" does not match ^[A-Za-z0-9_-]{8,64}\$',
        );
      }
      expect(
        ids.toSet(),
        hasLength(ids.length),
        reason: 'ids were not all distinct: $ids',
      );

      for (final id in ids) {
        transport.pushText(_serverFrame(type: 'pong', re: id));
      }
      await Future.wait(futures);
    });
  });

  // --- Rule 13: every typed method sends the documented t and d. -----------
  group('rule 13: typed methods send exactly section 4\'s t and d', () {
    test('move(2) sends t=move, d={"token": 2}', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.move(2);
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'move');
      expect(sent['d'], equals(<String, Object?>{'token': 2}));
      transport.pushText(_serverFrame(type: 'moved', re: sent['id'] as String));
      await future;
    });

    test('roll() sends t=roll, d={}', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.roll();
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'roll');
      expect(sent['d'], equals(<String, Object?>{}));
      transport.pushText(
        _serverFrame(type: 'rolled', re: sent['id'] as String),
      );
      await future;
    });

    test('startGame() sends t=start_game, d={}', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.startGame();
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'start_game');
      expect(sent['d'], equals(<String, Object?>{}));
      transport.pushText(
        _serverFrame(type: 'game_started', re: sent['id'] as String),
      );
      await future;
    });

    test('leaveRoom() sends t=leave_room, d={}', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.leaveRoom();
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'leave_room');
      expect(sent['d'], equals(<String, Object?>{}));
      transport.pushText(
        _serverFrame(type: 'player_left', re: sent['id'] as String),
      );
      await future;
    });

    test('ping() sends t=ping, d={}', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.ping();
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'ping');
      expect(sent['d'], equals(<String, Object?>{}));
      transport.pushText(_serverFrame(type: 'pong', re: sent['id'] as String));
      await future;
    });

    test(
      'setSeed("alice-seed-1") sends t=set_seed, d={"client_seed": s}',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);
        final future = connection.setSeed('alice-seed-1');
        await pumpEventQueue();
        final sent = _decode(transport.sentRaw.last);
        expect(sent['t'], 'set_seed');
        expect(
          sent['d'],
          equals(<String, Object?>{'client_seed': 'alice-seed-1'}),
        );
        transport.pushText(
          _serverFrame(type: 'seat_seed', re: sent['id'] as String),
        );
        await future;
      },
    );

    test('resume(code: ..., seatToken: ...) sends t=resume, '
        'd={"code":..., "seat_token":...}', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.resume(code: 'K7M2QP', seatToken: 'tok-xyz');
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'resume');
      expect(
        sent['d'],
        equals(<String, Object?>{'code': 'K7M2QP', 'seat_token': 'tok-xyz'}),
      );
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: sent['id'] as String,
          data: _validRoomJson(),
        ),
      );
      await future;
    });

    test('joinRoom(code: ..., name: ...) sends t=join_room, '
        'd={"code":..., "name":...}', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.joinRoom(code: 'K7M2QP', name: 'Sam');
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'join_room');
      expect(
        sent['d'],
        equals(<String, Object?>{'code': 'K7M2QP', 'name': 'Sam'}),
      );
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: sent['id'] as String,
          data: _validRoomJson(),
        ),
      );
      await future;
    });

    test('setPlayers(3) sends t=set_players, d={"players": 3}', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);
      final future = connection.setPlayers(3);
      await pumpEventQueue();
      final sent = _decode(transport.sentRaw.last);
      expect(sent['t'], 'set_players');
      expect(sent['d'], equals(<String, Object?>{'players': 3}));
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: sent['id'] as String,
          data: _validRoomJson(players: 3),
        ),
      );
      await future;
    });

    test(
      'createRoom(name: ..., players: ...), with rules omitted, sends '
      't=create_room, d={"name":..., "players":...} and nothing else',
      () async {
        final (connection, transport) = await _openConnection();
        addTearDown(connection.close);
        final future = connection.createRoom(name: 'Sam', players: 4);
        await pumpEventQueue();
        final sent = _decode(transport.sentRaw.last);
        expect(sent['t'], 'create_room');
        expect(
          sent['d'],
          equals(<String, Object?>{'name': 'Sam', 'players': 4}),
        );
        transport.pushText(
          _serverFrame(
            type: 'room',
            re: sent['id'] as String,
            data: _validRoomJson(),
          ),
        );
        await future;
      },
    );
  });
}

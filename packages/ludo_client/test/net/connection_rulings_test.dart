// Tests for the two master rulings of run 22 on
// packages/ludo_client/lib/src/net/connection.dart, written from work order
// 075 and from docs/PROTOCOL.md sections 7.1 and 8. Neither ruling is a
// change request: both are believed already implemented, and this file
// exists so that reversing either one fails a suite instead of failing a
// player.
//
// Ruling 1 (connection.dart:208-218): a malformed seat_assigned arriving
// after a valid one must not clear the seat or seat token the valid one
// set. A seat token is the capability to reclaim a seat after a disconnect
// (docs/PROTOCOL.md section 8); a later malformed frame throwing away a good
// token would turn a network hiccup into a lost seat.
//
// Ruling 2 (transport.dart's WireTransport.close and connection.dart's
// RoomConnection.close): close() must close the transport with code 1000, a
// normal closure. docs/PROTOCOL.md section 7.1 pins the codes the *server*
// sends on an abnormal close; a client closing deliberately has no reason to
// send anything but 1000.
//
// connection_test.dart (read, not modified, per the order) already covers,
// so it is deliberately not repeated here:
//   - seat/seatToken start null and a single well-formed seat_assigned sets
//     them (rule 3, "a well-formed seat_assigned... populates seat and
//     seatToken").
//   - a malformed seat_assigned leaves seat/seatToken unset when they were
//     already null, for three shapes of malformed d (seat out of range,
//     seat missing, seat_token not a String), and that the malformed frame
//     still reaches `frames` (rule 3's
//     expectMalformedSeatAssignedLeavesUnsetButForwarded).
//   - close() does not throw on a second call ("close() is idempotent").
//   - close() calls the transport's close with code 1000 once
//     ("close() closes the underlying transport with the normal-closure
//     code (1000)"), explicitly flagged there as an inference rather than a
//     quotation from a numbered rule.
// connection_test.dart's own header comment (corner 3) names exactly the gap
// this file closes for ruling 1: "Whether a malformed seat_assigned arriving
// after a VALID one must clear an already-populated seat/seatToken back to
// null is not stated and is left untested." That is the scenario below.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/connection.dart';

import 'fake_transport.dart';

const _testUrl = 'wss://example.test/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'ruling-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

/// A server push, encoded exactly as Frame.decode expects. Every frame
/// built here is a push (`re` omitted): seat_assigned is defined by
/// docs/PROTOCOL.md as a push, and close() needs no inbound frame at all.
String _serverPush({
  required String type,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  'd': data,
});

/// Builds and opens a RoomConnection against a fresh FakeTransport.
Future<(RoomConnection, FakeTransport)> _openConnection() async {
  final transport = FakeTransport();
  final connection = RoomConnection(
    url: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
  );
  await connection.open();
  return (connection, transport);
}

void main() {
  // --- Ruling 1 --------------------------------------------------------
  group('ruling 1: a malformed seat_assigned after a valid one leaves seat and '
      'seatToken untouched', () {
    /// Pushes a well-formed seat_assigned (seat 1, token 'tok-first'),
    /// confirms it took, then pushes [malformedData] as a second
    /// seat_assigned and asserts seat/seatToken still hold the first
    /// frame's values.
    Future<void> expectSecondMalformedSeatAssignedLeavesFirstIntact(
      String label,
      Map<String, Object?> malformedData,
    ) async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      transport.pushText(
        _serverPush(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 1, 'seat_token': 'tok-first'},
        ),
      );
      await pumpEventQueue();
      expect(
        connection.seat,
        1,
        reason:
            'setup failed: the first, valid seat_assigned must take '
            'before the malformed one is even sent ($label)',
      );
      expect(connection.seatToken, 'tok-first');

      transport.pushText(
        _serverPush(type: 'seat_assigned', data: malformedData),
      );
      await pumpEventQueue();

      expect(
        connection.seat,
        1,
        reason:
            'a malformed seat_assigned ($label: d=$malformedData) arriving '
            'after a valid one must not clear the seat already captured; '
            'a seat token is the capability to reclaim a seat after a '
            'disconnect (docs/PROTOCOL.md section 8) and a later malformed '
            'frame must not throw a good one away',
      );
      expect(
        connection.seatToken,
        'tok-first',
        reason:
            'a malformed seat_assigned ($label: d=$malformedData) arriving '
            'after a valid one must not clear seatToken already captured',
      );
    }

    test('seat as a non-integer (a String)', () {
      return expectSecondMalformedSeatAssignedLeavesFirstIntact(
        'seat as a String, not an int',
        <String, Object?>{'seat': '2', 'seat_token': 'tok-second'},
      );
    });

    test('seat out of the 0..3 range (4, one over the maximum)', () {
      return expectSecondMalformedSeatAssignedLeavesFirstIntact(
        'seat: 4, one over the maximum',
        <String, Object?>{'seat': 4, 'seat_token': 'tok-second'},
      );
    });

    test('seat out of the 0..3 range (-1, one under the minimum)', () {
      return expectSecondMalformedSeatAssignedLeavesFirstIntact(
        'seat: -1, one under the minimum',
        <String, Object?>{'seat': -1, 'seat_token': 'tok-second'},
      );
    });

    test('seat_token missing entirely', () {
      return expectSecondMalformedSeatAssignedLeavesFirstIntact(
        'seat_token missing entirely',
        <String, Object?>{'seat': 2},
      );
    });

    test('seat_token present but not a String', () {
      return expectSecondMalformedSeatAssignedLeavesFirstIntact(
        'seat_token as an int, not a String',
        <String, Object?>{'seat': 2, 'seat_token': 999},
      );
    });

    test('d missing both seat and seat_token', () {
      return expectSecondMalformedSeatAssignedLeavesFirstIntact(
        'd missing both keys entirely',
        const <String, Object?>{},
      );
    });

    test('opposite polarity: a second VALID seat_assigned does replace both '
        'values, so the tests above are not vacuous', () async {
      final (connection, transport) = await _openConnection();
      addTearDown(connection.close);

      transport.pushText(
        _serverPush(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 1, 'seat_token': 'tok-first'},
        ),
      );
      await pumpEventQueue();
      expect(connection.seat, 1);
      expect(connection.seatToken, 'tok-first');

      transport.pushText(
        _serverPush(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 3, 'seat_token': 'tok-second'},
        ),
      );
      await pumpEventQueue();

      expect(
        connection.seat,
        3,
        reason:
            'a second, well-formed seat_assigned must replace the seat '
            'captured from the first',
      );
      expect(
        connection.seatToken,
        'tok-second',
        reason:
            'a second, well-formed seat_assigned must replace the '
            'seatToken captured from the first',
      );
    });
  });

  // --- Ruling 2 --------------------------------------------------------
  group('ruling 2: close() closes the transport with code 1000', () {
    test('close() on an open connection closes the transport with exactly '
        'code 1000', () async {
      final (connection, transport) = await _openConnection();

      expect(
        transport.isClosed,
        isFalse,
        reason:
            'setup failed: the transport must still be open before '
            'close() is called',
      );

      await connection.close();

      expect(
        transport.isClosed,
        isTrue,
        reason: 'close() must close the transport',
      );
      expect(
        transport.closeCalls,
        isNotEmpty,
        reason:
            'close() must call WireTransport.close(), which '
            'FakeTransport records in closeCalls on every invocation',
      );
      expect(
        transport.closeCalls,
        everyElement(1000),
        reason:
            'every call RoomConnection.close() makes to the transport '
            'must carry close code 1000, a normal closure; '
            'docs/PROTOCOL.md section 7.1 pins the codes the server '
            'sends and none of those apply to a client closing '
            'deliberately, got ${transport.closeCalls}',
      );
    });

    test('close() is idempotent: a second call does not throw, isOpen stays '
        'false, and every close the transport actually recorded is still '
        '1000', () async {
      final (connection, transport) = await _openConnection();

      await connection.close();
      expect(connection.isOpen, isFalse);
      final List<int> afterFirstClose = List<int>.of(transport.closeCalls);
      expect(
        afterFirstClose,
        isNotEmpty,
        reason:
            'the first close() must have reached the transport before '
            'the idempotency of a second call means anything',
      );

      await expectLater(
        connection.close(),
        completes,
        reason: 'a second close() must not throw or hang',
      );

      expect(
        connection.isOpen,
        isFalse,
        reason: 'a second close() must not somehow reopen the connection',
      );
      expect(
        transport.isClosed,
        isTrue,
        reason:
            'the transport must still be closed after a second '
            'close() call',
      );
      // FakeTransport's own documentation on closeCalls: "including calls
      // made after the transport was already closed... still observed
      // here so a test can assert how many times the engine called it and
      // with what code each time." So closeCalls may grow past the first
      // close, and this test asserts the content of the list the fake
      // actually recorded rather than assuming a fixed length: whatever
      // RoomConnection.close() did on the second call, every entry it
      // produced must still be a normal closure, and it must never have
      // shrunk or mutated what the first call already recorded.
      expect(
        transport.closeCalls.sublist(0, afterFirstClose.length),
        afterFirstClose,
        reason:
            'a second close() must not alter the close calls already '
            'recorded by the first, got ${transport.closeCalls} after '
            'the first close recorded $afterFirstClose',
      );
      expect(
        transport.closeCalls,
        everyElement(1000),
        reason:
            'every close call the transport ever recorded, across both '
            'calls to RoomConnection.close(), must be code 1000, got '
            '${transport.closeCalls}',
      );
    });
  });
}

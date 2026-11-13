// Proof for contract C-547 D1
// (work/ludo/orders/C-547-seat-moved-to-another-phone.md): the controller
// side of a seat taken over by another phone. `RoomController.seatTakenOver`
// is true after an unsolicited `error` frame (`re` null) whose code is
// BAD_SEAT_TOKEN, goes false only when the phase next reaches `connected`,
// and is left alone by leave() and dispose().
//
// This file names the getter, which does not exist on the tree it was written
// for: on that tree it fails to compile, by design. The screens, Home and the
// strings are proved in test/c547_test.dart, which compiles everywhere.
//
// A real RoomController sits over FakeTransport (test/net/fake_transport.dart,
// read-only here) behind a connector double. Every frame is decoded by the
// controller's own request path; nothing pokes private state. testWidgets is
// used for its fake clock: the automatic reconnect timers fire on
// tester.pump(duration), never on a real wait.
//
// Cases:
//   D1.a    unsolicited BAD_SEAT_TOKEN then close: true, errorCode null
//   D1.b    true and notified at the frame, phase already closed, the client
//           closed the transport
//   D1.c    unsolicited error of any other code, or no usable code: false
//   D1.d    an error with `re` set (a reply), however it is addressed: false
//   D1.e    reconnect() on a moved seat opens nothing; a later joinRoom that
//           reaches connected clears it, one in flight or refused does not
//   D1.f    no automatic reconnect attempt follows the takeover
//   D1.g    leave() and dispose() leave it as it is
//   D1.h    the frame then the server's close is one takeover, the frame and
//           the close in one burst, the frame before any room is held
//
// There is no random input. Each failure reason names the case, what was
// expected and what the controller said, and ends with the command that
// replays that one case:
//   flutter test test/c547_controller_test.dart --plain-name '<id>'

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c547-controller.invalid/ws';
const String _code = 'K7M2QP';
const String _token = 'tok-c547-001';

const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

String _reproduce(String id) =>
    'reproduce: flutter test test/c547_controller_test.dart '
    '--plain-name "$id"';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c547-ctl-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

String _unsolicited(Object? code) => _frame(
  type: 'error',
  data: <String, Object?>{'code': ?code, 'message': 'taken over'},
);

Map<String, Object?> _roomJson({String state = 'PLAYING', int seq = 1}) =>
    <String, Object?>{
      'code': _code,
      'state': state,
      'host_seat': 0,
      'players': 2,
      'rules': <String, Object?>{
        'blocks': false,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
      'chain_commit': 'a' * 64,
      'chain_index': 0,
      'game_id': state == 'LOBBY' ? null : '7f3a9c1e5b2d4068',
      'client_seeds': null,
      'seats': <Map<String, Object?>>[
        for (final int seat in <int>[0, 1])
          <String, Object?>{
            'seat': seat,
            'name': seat == 0 ? 'Sam' : 'Bob',
            'connected': true,
            'tokens': <int>[-1, -1, -1, -1],
            'client_seed': null,
            'seed_origin': null,
          },
      ],
      'turn': state == 'PLAYING'
          ? <String, Object?>{
              'seat': 0,
              'phase': 'await_roll',
              'deadline_ms': 1000,
              'k': 0,
            }
          : null,
      'winner': null,
      'seq': seq,
    };

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has nothing queued; '
        'the controller opened a transport the scenario did not expect',
      );
    }
    return _queue.removeAt(0);
  }
}

/// A controller that holds a PLAYING room as seat 0, connected, over
/// [transport]. [connector] has nothing queued unless the case enqueues it.
class _Table {
  _Table(this.controller, this.transport, this.connector);

  final RoomController controller;
  final FakeTransport transport;
  final _Connector connector;

  bool _disposed = false;

  /// Disposes the controller once; a case that leaves a reconnect timer
  /// pending calls this in its body, before the binding checks for timers.
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      controller.dispose();
    }
  }

  /// What seatTakenOver read at each notification the controller sent.
  final List<bool> seenAtNotify = <bool>[];

  /// The phase and seatTakenOver a listener saw at each notification.
  final List<(RoomPhase, bool)> seenPairs = <(RoomPhase, bool)>[];

  static Future<_Table> connect(
    WidgetTester tester,
    String id, {
    List<Duration> delays = const <Duration>[],
  }) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
      autoReconnectDelays: delays,
    );
    final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
    // pumpEventQueue relies on real timers, which never fire under a
    // testWidgets body's fake clock; runAsync steps outside it.
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': _token},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(transport.sentRaw.last),
        data: _roomJson(),
      ),
    );
    await created;
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: '$id: fixture: the create reply must land connected',
    );
    final _Table table = _Table(controller, transport, connector);
    addTearDown(table.dispose);
    controller.addListener(() {
      table.seenAtNotify.add(controller.seatTakenOver);
      table.seenPairs.add((controller.phase, controller.seatTakenOver));
    });
    return table;
  }

  Future<void> push(WidgetTester tester, String text) async {
    transport.pushText(text);
    await tester.pump();
  }

  Future<void> drop(WidgetTester tester) async {
    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();
  }
}

void _expectTaken(
  RoomController controller,
  String id,
  bool expected,
  String when,
) {
  expect(
    controller.seatTakenOver,
    expected,
    reason:
        '$id: expected seatTakenOver $expected $when; saw '
        '${controller.seatTakenOver} (phase ${controller.phase}, errorCode '
        '${controller.errorCode}). ${_reproduce(id)}',
  );
}

void main() {
  testWidgets(
    'D1.a: an unsolicited BAD_SEAT_TOKEN then the close sets seatTakenOver '
    'and leaves errorCode null',
    (tester) async {
      const String id = 'D1.a';
      final _Table table = await _Table.connect(tester, id);
      _expectTaken(table.controller, id, false, 'on a healthy connection');
      await table.push(tester, _unsolicited('BAD_SEAT_TOKEN'));
      await table.drop(tester);
      _expectTaken(table.controller, id, true, 'after the takeover and close');
      expect(
        table.controller.errorCode,
        isNull,
        reason:
            '$id: expected errorCode null (the takeover is not a request '
            'failure); saw ${table.controller.errorCode}. ${_reproduce(id)}',
      );
      expect(
        table.controller.phase,
        RoomPhase.closed,
        reason:
            '$id: expected phase closed after the close; saw '
            '${table.controller.phase}. ${_reproduce(id)}',
      );
    },
  );

  testWidgets(
    'D1.b: at the frame listeners are told seatTakenOver true with the phase '
    'already closed, and the client closed the transport',
    (tester) async {
      const String id = 'D1.b';
      final _Table table = await _Table.connect(tester, id);
      await table.push(tester, _unsolicited('BAD_SEAT_TOKEN'));
      expect(
        table.seenAtNotify,
        contains(true),
        reason:
            '$id: expected a notification with seatTakenOver true at the '
            'frame; notifications saw ${table.seenAtNotify}. '
            '${_reproduce(id)}',
      );
      expect(
        table.seenPairs,
        isNot(contains((RoomPhase.connected, true))),
        reason:
            '$id: expected no listener to see (connected, true); '
            'notifications saw ${table.seenPairs}. ${_reproduce(id)}',
      );
      expect(
        table.seenPairs.last,
        (RoomPhase.closed, true),
        reason:
            '$id: expected the notification at the frame to read '
            '(closed, true); the last one read ${table.seenPairs.last}. '
            '${_reproduce(id)}',
      );
      _expectTaken(table.controller, id, true, 'at the frame');
      expect(
        table.controller.phase,
        RoomPhase.closed,
        reason:
            '$id: expected phase closed at the frame, before the server '
            'closes anything; saw ${table.controller.phase}. '
            '${_reproduce(id)}',
      );
      expect(
        table.transport.closeCalls.length,
        1,
        reason:
            '$id: expected the client to close the transport once at the '
            'frame; close calls ${table.transport.closeCalls}. '
            '${_reproduce(id)}',
      );
      expect(
        table.transport.isClosed,
        isTrue,
        reason:
            '$id: expected the transport closed by the client; it is still '
            'open. ${_reproduce(id)}',
      );
    },
  );

  for (final ({String name, Object? code}) other
      in <({String name, Object? code})>[
        (name: 'RATE_LIMITED', code: 'RATE_LIMITED'),
        (name: 'NO_SUCH_ROOM', code: 'NO_SUCH_ROOM'),
        (name: 'BAD_REQUEST', code: 'BAD_REQUEST'),
        (name: 'empty', code: ''),
        (name: 'a number', code: 4004),
        (name: 'no code at all', code: null),
      ]) {
    testWidgets(
      'D1.c (${other.name}): an unsolicited error that is not exactly '
      'BAD_SEAT_TOKEN does not set seatTakenOver',
      (tester) async {
        final String id = 'D1.c ${other.name}';
        final _Table table = await _Table.connect(tester, id);
        await table.push(tester, _unsolicited(other.code));
        _expectTaken(table.controller, id, false, 'after the frame');
        await table.drop(tester);
        _expectTaken(table.controller, id, false, 'after the close');
      },
    );
  }

  testWidgets('D1.d: an error reply (re set) with BAD_SEAT_TOKEN does not set '
      'seatTakenOver', (tester) async {
    const String id = 'D1.d reply';
    final _Table table = await _Table.connect(tester, id);
    unawaited(table.controller.roll());
    await tester.pump();
    final String rollId = _idOf(table.transport.sentRaw.last);
    expect(_typeOf(table.transport.sentRaw.last), 'roll');
    await table.push(
      tester,
      _frame(
        type: 'error',
        re: rollId,
        data: <String, Object?>{'code': 'BAD_SEAT_TOKEN', 'message': ''},
      ),
    );
    await tester.pump();
    _expectTaken(table.controller, id, false, 'after the error reply');
    await table.drop(tester);
    _expectTaken(table.controller, id, false, 'after the close');
  });

  testWidgets(
    'D1.d: an error naming a request nobody sent (re set, unknown id) is '
    'not unsolicited, so it does not set seatTakenOver',
    (tester) async {
      const String id = 'D1.d unknown re';
      final _Table table = await _Table.connect(tester, id);
      await table.push(
        tester,
        _frame(
          type: 'error',
          re: 'no-such-request',
          data: <String, Object?>{'code': 'BAD_SEAT_TOKEN', 'message': ''},
        ),
      );
      _expectTaken(table.controller, id, false, 'after the frame');
      await table.drop(tester);
      _expectTaken(table.controller, id, false, 'after the close');
    },
  );

  /// A controller whose first create is still in flight when the takeover
  /// frame lands: the one route on which a moved seat leaves the phase
  /// `failed`, from which joinRoom is accepted again. Returns it with the
  /// first transport, after the create has failed.
  Future<(RoomController, _Connector, FakeTransport)> failedAfterTakeover(
    WidgetTester tester,
    String id,
  ) async {
    final _Connector connector = _Connector();
    final FakeTransport first = FakeTransport();
    connector.enqueue(first);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
    );
    addTearDown(controller.dispose);
    unawaited(controller.createRoom(name: 'Sam', players: 2));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    first.pushText(_unsolicited('BAD_SEAT_TOKEN'));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    expect(
      controller.phase,
      RoomPhase.failed,
      reason:
          '$id: fixture: the create that lost its seat must end failed; '
          'phase ${controller.phase}, errorCode ${controller.errorCode}. '
          '${_reproduce(id)}',
    );
    _expectTaken(controller, id, true, 'after the create that lost its seat');
    return (controller, connector, first);
  }

  testWidgets(
    'D1.e: a joinRoom that reaches connected clears seatTakenOver; the '
    'attempt in flight does not',
    (tester) async {
      const String id = 'D1.e join';
      final (RoomController controller, _Connector connector, _) =
          await failedAfterTakeover(tester, id);

      final FakeTransport second = FakeTransport();
      connector.enqueue(second);
      unawaited(controller.joinRoom(code: _code, name: 'Sam'));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.connecting,
        reason:
            '$id: fixture: the join must be in flight; phase '
            '${controller.phase}. ${_reproduce(id)}',
      );
      expect(_typeOf(second.sentRaw.last), 'join_room');
      _expectTaken(
        controller,
        id,
        true,
        'while the join is still in flight (phase connecting)',
      );

      second.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 1, 'seat_token': 'tok-c547-002'},
        ),
      );
      second.pushText(
        _frame(
          type: 'room',
          re: _idOf(second.sentRaw.last),
          data: _roomJson(seq: 2),
        ),
      );
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason: '$id: fixture: the join reply must land connected',
      );
      _expectTaken(controller, id, false, 'once the join has connected');
    },
  );

  testWidgets(
    'D1.e: a joinRoom after a takeover on a held room is not accepted, opens '
    'no transport, and leaves seatTakenOver true',
    (tester) async {
      const String id = 'D1.e closed';
      final _Table table = await _Table.connect(tester, id);
      await table.push(tester, _unsolicited('BAD_SEAT_TOKEN'));
      await table.drop(tester);
      _expectTaken(table.controller, id, true, 'after the takeover');
      final int connects = table.connector.calls.length;

      final FakeTransport second = FakeTransport();
      table.connector.enqueue(second);
      unawaited(table.controller.joinRoom(code: _code, name: 'Sam'));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(
        table.connector.calls.length,
        connects,
        reason:
            '$id: expected no transport opened by joinRoom from the closed '
            'phase; connects went from $connects to '
            '${table.connector.calls.length}. ${_reproduce(id)}',
      );
      expect(
        second.sentRaw,
        isEmpty,
        reason:
            '$id: expected nothing sent; saw ${second.sentRaw}. '
            '${_reproduce(id)}',
      );
      expect(
        table.controller.phase,
        RoomPhase.closed,
        reason:
            '$id: expected phase closed; saw ${table.controller.phase}. '
            '${_reproduce(id)}',
      );
      _expectTaken(table.controller, id, true, 'after the refused joinRoom');
    },
  );

  testWidgets('D1.e: a refused joinRoom leaves seatTakenOver true', (
    tester,
  ) async {
    const String id = 'D1.e refused';
    final (RoomController controller, _Connector connector, _) =
        await failedAfterTakeover(tester, id);

    final FakeTransport second = FakeTransport();
    connector.enqueue(second);
    unawaited(controller.joinRoom(code: _code, name: 'Sam'));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    second.pushText(
      _frame(
        type: 'error',
        re: _idOf(second.sentRaw.last),
        data: <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': ''},
      ),
    );
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.failed,
      reason:
          '$id: fixture: the refused join must fail the phase; phase '
          '${controller.phase}. ${_reproduce(id)}',
    );
    expect(
      controller.errorCode,
      'NO_SUCH_ROOM',
      reason:
          '$id: expected errorCode NO_SUCH_ROOM from the refused join; saw '
          '${controller.errorCode}. ${_reproduce(id)}',
    );
    _expectTaken(
      controller,
      id,
      true,
      'after a join that never reached connected',
    );
  });

  testWidgets('D1.e: reconnect() on a moved seat opens no transport and leaves '
      'seatTakenOver true', (tester) async {
    const String id = 'D1.e reconnect';
    final _Table table = await _Table.connect(tester, id);
    await table.push(tester, _unsolicited('BAD_SEAT_TOKEN'));
    await table.drop(tester);
    final int connects = table.connector.calls.length;
    final int notified = table.seenAtNotify.length;

    final FakeTransport second = FakeTransport();
    table.connector.enqueue(second);
    unawaited(table.controller.reconnect());
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(
      table.connector.calls.length,
      connects,
      reason:
          '$id: expected no transport opened by reconnect() on a moved '
          'seat; connects went from $connects to '
          '${table.connector.calls.length}. ${_reproduce(id)}',
    );
    expect(
      second.sentRaw,
      isEmpty,
      reason:
          '$id: expected no resume sent; saw ${second.sentRaw}. '
          '${_reproduce(id)}',
    );
    expect(
      table.seenAtNotify.length,
      notified,
      reason:
          '$id: expected no notification from reconnect(); '
          '${table.seenAtNotify.length - notified} arrived. '
          '${_reproduce(id)}',
    );
    expect(
      table.controller.phase,
      RoomPhase.closed,
      reason:
          '$id: expected phase closed; saw ${table.controller.phase}. '
          '${_reproduce(id)}',
    );
    _expectTaken(table.controller, id, true, 'after reconnect()');
  });

  testWidgets('D1.f: no automatic reconnect attempt follows the takeover', (
    tester,
  ) async {
    const String id = 'D1.f';
    final _Table table = await _Table.connect(tester, id, delays: _delays);
    await table.push(tester, _unsolicited('BAD_SEAT_TOKEN'));
    await table.drop(tester);
    _expectTaken(table.controller, id, true, 'after the takeover');
    expect(
      table.controller.autoReconnectPending,
      isFalse,
      reason:
          '$id: expected no scheduled reconnect after the takeover; one '
          'is pending. ${_reproduce(id)}',
    );
    await tester.pump(_delays[0]);
    await tester.pump(_delays[1]);
    await tester.pump(const Duration(seconds: 30));
    expect(
      table.connector.calls.length,
      1,
      reason:
          '$id: expected the one connect the table opened and no retry; '
          'saw ${table.connector.calls.length} connects. ${_reproduce(id)}',
    );
    expect(
      table.controller.phase,
      RoomPhase.closed,
      reason:
          '$id: expected phase to stay closed; saw '
          '${table.controller.phase}. ${_reproduce(id)}',
    );
    _expectTaken(table.controller, id, true, 'after the retry window');
  });

  testWidgets('D1.f guard: a plain drop on the same controller does start the '
      'automatic retry, so the probe above can see one', (tester) async {
    const String id = 'D1.f guard';
    final _Table table = await _Table.connect(tester, id, delays: _delays);
    await table.drop(tester);
    _expectTaken(table.controller, id, false, 'after a plain drop');
    expect(
      table.controller.autoReconnectPending,
      isTrue,
      reason:
          '$id: expected a scheduled reconnect after a plain drop; none '
          'is pending. ${_reproduce(id)}',
    );
    table.dispose();
  });

  testWidgets('D1.g: leave() leaves seatTakenOver as it is', (tester) async {
    const String id = 'D1.g leave';
    final _Table table = await _Table.connect(tester, id);
    await table.push(tester, _unsolicited('BAD_SEAT_TOKEN'));
    final Future<void> left = table.controller.leave();
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await left;
    _expectTaken(table.controller, id, true, 'after leave()');
  });

  testWidgets(
    'D1.g: leave() does not set seatTakenOver on a seat that was never '
    'taken over',
    (tester) async {
      const String id = 'D1.g leave untouched';
      final _Table table = await _Table.connect(tester, id);
      final Future<void> left = table.controller.leave();
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      await left;
      _expectTaken(table.controller, id, false, 'after leave()');
    },
  );

  testWidgets('D1.g: dispose() leaves seatTakenOver as it is', (tester) async {
    const String id = 'D1.g dispose';
    final _Table table = await _Table.connect(tester, id);
    await table.push(tester, _unsolicited('BAD_SEAT_TOKEN'));
    table.dispose();
    _expectTaken(table.controller, id, true, 'after dispose()');
  });

  testWidgets(
    'D1.h: the takeover frame then the close arriving is still one takeover: '
    'one client close, and the close changes nothing and notifies no one',
    (tester) async {
      const String id = 'D1.h replay';
      final _Table table = await _Table.connect(tester, id, delays: _delays);
      final RoomController c = table.controller;
      await table.push(tester, _unsolicited('BAD_SEAT_TOKEN'));
      _expectTaken(c, id, true, 'after the frame');
      expect(
        table.transport.closeCalls.length,
        1,
        reason:
            '$id: expected one client close at the frame; close calls '
            '${table.transport.closeCalls}. ${_reproduce(id)}',
      );
      expect(
        c.phase,
        RoomPhase.closed,
        reason:
            '$id: expected phase closed after the frame; saw ${c.phase}. '
            '${_reproduce(id)}',
      );
      String fields() =>
          'phase ${c.phase}, seatTakenOver ${c.seatTakenOver}, errorCode '
          '${c.errorCode}, room ${identityHashCode(c.room)}, seat ${c.seat}, '
          'token ${c.seatToken}, hasDesynced ${c.hasDesynced}, isResyncing '
          '${c.isResyncing}, updateRequired ${c.updateRequired}, '
          'autoReconnectPending ${c.autoReconnectPending}';
      final String before = fields();
      final int notified = table.seenPairs.length;

      // The server's own close arrives after the client's: nothing further.
      await table.drop(tester);
      await tester.pump(_delays[0]);
      await tester.pump(_delays[1]);
      await tester.pump(const Duration(seconds: 30));

      expect(
        table.seenPairs.length,
        notified,
        reason:
            '$id: expected no notification after the close; got '
            '${table.seenPairs.sublist(notified)}. ${_reproduce(id)}',
      );
      expect(
        fields(),
        before,
        reason:
            '$id: expected no field to change when the close arrived. '
            '${_reproduce(id)}',
      );
      expect(
        table.transport.closeCalls.length,
        1,
        reason:
            '$id: expected exactly one close call from the client; close '
            'calls ${table.transport.closeCalls}. ${_reproduce(id)}',
      );
      expect(
        table.connector.calls.length,
        1,
        reason:
            '$id: expected no reconnect after the close; saw '
            '${table.connector.calls.length} connects. ${_reproduce(id)}',
      );
      _expectTaken(c, id, true, 'after the close');
      expect(
        c.errorCode,
        isNull,
        reason:
            '$id: expected errorCode null; saw ${c.errorCode}. '
            '${_reproduce(id)}',
      );
    },
  );

  testWidgets(
    'D1.h: the frame and the close in one burst, with no frame pumped '
    'between them',
    (tester) async {
      const String id = 'D1.h burst';
      final _Table table = await _Table.connect(tester, id, delays: _delays);
      table.transport.pushText(_unsolicited('BAD_SEAT_TOKEN'));
      table.transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      _expectTaken(table.controller, id, true, 'after the burst');
      expect(
        table.controller.autoReconnectPending,
        isFalse,
        reason:
            '$id: expected no scheduled reconnect after the burst; one is '
            'pending. ${_reproduce(id)}',
      );
      expect(
        table.controller.errorCode,
        isNull,
        reason:
            '$id: expected errorCode null; saw '
            '${table.controller.errorCode}. ${_reproduce(id)}',
      );
    },
  );

  testWidgets(
    'D1.h: the frame before any room is held (a create still in flight) '
    'sets seatTakenOver',
    (tester) async {
      const String id = 'D1.h no room';
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
      );
      addTearDown(controller.dispose);
      unawaited(controller.createRoom(name: 'Sam', players: 2));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(
        controller.room,
        isNull,
        reason: '$id: fixture: no room may be held yet',
      );
      transport.pushText(_unsolicited('BAD_SEAT_TOKEN'));
      await tester.pump();
      _expectTaken(controller, id, true, 'before any room is held');
      // Let the create time out so no timer outlives the case.
      await tester.pump(const Duration(seconds: 11));
    },
  );
}

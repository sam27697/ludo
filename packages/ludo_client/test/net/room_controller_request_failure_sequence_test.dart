// Proof for order 170's G1-G3: a retryable failure of an in-room request
// (setPlayers(), startGame(), roll() or move()) starts an automatic sequence
// exactly as a drop does, closing order 166's recorded gap ("a request that
// fails on an open socket ... starts no automatic sequence", verdict of
// work/ludo/orders/166-auto-reconnect.md). Written from THE CONTRACT in
// work/ludo/orders/171-prove-rejections-and-request-failure-sequence.md,
// clauses G1 through G3, copied verbatim from order 170, and from nothing
// else, plus L-1, order 167's own recorded proof gap (also that verdict:
// no A-case ever calls onAppResumed() after leave()).
//
// Fake clock throughout, following the house pattern at
// test/net/connection_test.dart:887-940 and the whole of
// test/net/room_controller_auto_reconnect_test.dart, whose rig this file's
// helpers are a private copy of (neither file exports anything a test could
// import), not a reuse of order 171's own E file, which is a sibling, not
// a dependency.
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

const String _testUrl = 'wss://order-171-g-test.invalid/ws';

/// G-T's own schedule, pinned by the order text ("delays [1s, 2s]"), reused
/// for every other case in this file so the whole file measures against one
/// schedule.
const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// RoomConnection's default requestTimeout (packages/ludo_client/lib/src/
/// net/connection.dart, RoomConnection's constructor:
/// `Duration requestTimeout = const Duration(seconds: 10)`), read from the
/// source rather than guessed, per the order. RoomController never
/// overrides it: every RoomConnection it constructs uses this default.
const Duration _requestTimeout = Duration(seconds: 10);

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-171g-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  int hostSeat = 0,
  int players = 4,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
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
  'seats': <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': null,
  'winner': null,
  'seq': seq,
};

// --- a TransportConnector test double that records and queues ----------

/// Hands out queued [FakeTransport]s, one per call, in order. Records every
/// url it was called with so a test can assert exactly how many times a
/// connection was ever attempted. [rejectNextWith] makes exactly the next
/// call reject instead, without handing out a transport at all.
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

/// Builds a controller inside a running [FakeAsync] zone, drives it through a
/// successful createRoom() using .then()/flushMicrotasks rather than a direct
/// await (a fakeAsync callback must stay synchronous), and returns it already
/// in phase connected with room, seat and seatToken all populated.
(RoomController, FakeTransport, _Connector) _connectedControllerSync(
  FakeAsync async, {
  List<Duration> autoReconnectDelays = const <Duration>[],
  int hostSeat = 0,
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
      data: _roomJson(hostSeat: hostSeat),
    ),
  );
  async.flushMicrotasks();

  return (controller, transport, connector);
}

void main() {
  // ==========================================================================
  // G-T (RED on base): roll() times out on a dead socket and must start an
  // automatic sequence -- order 166's recorded gap.
  // ==========================================================================
  test('G-T: roll() times out on a dead socket: phase failed, errorCode '
      'timeout, autoReconnectPending true; the retried attempt at delays[0] '
      'opens a new connection and sends resume carrying the cached code and '
      'seat token', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final String cachedCode = controller.room!.code;
      final String cachedToken = controller.seatToken!;

      unawaited(controller.roll());
      async.flushMicrotasks();
      expect(
        transport0.sentRaw
            .map(_decode)
            .where((Map<String, Object?> m) => m['t'] == 'roll'),
        hasLength(1),
        reason: 'fixture is broken: roll() must have reached the wire',
      );

      async.elapse(_requestTimeout);
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'a roll() left unanswered past RequestTimeoutException must '
            'land in failed',
      );
      expect(
        controller.errorCode,
        'timeout',
        reason:
            'RequestTimeoutException maps to the retryable code '
            '"timeout"',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'G1: a retryable failure of an in-room request (roll()) must '
            'start a sequence exactly as C5 starts one -- order 166\'s '
            'recorded gap ("a request that fails on an open socket ... '
            'starts no automatic sequence")',
      );

      final int callsBefore = connector.calls.length;
      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      async.elapse(_delays[0]);
      async.flushMicrotasks();

      expect(
        connector.calls.length,
        callsBefore + 1,
        reason:
            'G1: the sequence\'s single timer for autoReconnectDelays[0] '
            'must have fired and opened a new connection',
      );
      expect(transport1.sentRaw, isNotEmpty);
      final Map<String, Object?> sent = _decode(transport1.sentRaw.first);
      expect(
        sent['t'],
        'resume',
        reason: 'G1: the retried attempt is the same body C7 runs',
      );
      expect(
        sent['d'],
        equals(<String, Object?>{
          'code': cachedCode,
          'seat_token': cachedToken,
        }),
        reason:
            'G1: resume must carry the cached code and seat token, got '
            'd=${sent['d']}',
      );

      // Resolve it so nothing is left pending.
      final String id = sent['id']! as String;
      transport1.pushText(
        _frame(type: 'room', re: id, data: _roomJson(seq: 2)),
      );
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.connected);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // G-S (RED on base): the same for startGame() and setPlayers(). G1 names
  // all four requests; this proves more than one.
  // ==========================================================================
  for (final String which in <String>['startGame', 'setPlayers']) {
    test('G-S ($which): $which() times out on a dead socket: phase failed, '
        'errorCode timeout, autoReconnectPending true; the retried attempt at '
        'delays[0] opens a new connection and sends resume carrying the '
        'cached code and seat token', () {
      fakeAsync((FakeAsync async) {
        final (
          RoomController controller,
          FakeTransport transport0,
          _Connector connector,
        ) = _connectedControllerSync(
          async,
          autoReconnectDelays: _delays,
        );
        final String cachedCode = controller.room!.code;
        final String cachedToken = controller.seatToken!;

        if (which == 'startGame') {
          unawaited(controller.startGame());
        } else {
          unawaited(controller.setPlayers(3));
        }
        async.flushMicrotasks();
        expect(
          transport0.sentRaw,
          isNotEmpty,
          reason: 'fixture is broken: $which() must have reached the wire',
        );

        async.elapse(_requestTimeout);
        async.flushMicrotasks();

        expect(
          controller.phase,
          RoomPhase.failed,
          reason:
              '$which() left unanswered past RequestTimeoutException '
              'must land in failed',
        );
        expect(controller.errorCode, 'timeout');
        expect(
          controller.autoReconnectPending,
          isTrue,
          reason:
              'G1: $which() is one of the four requests G1 names; a '
              'retryable failure of it must start a sequence exactly as '
              'C5 starts one',
        );

        final int callsBefore = connector.calls.length;
        final FakeTransport transport1 = FakeTransport();
        connector.enqueue(transport1);
        async.elapse(_delays[0]);
        async.flushMicrotasks();

        expect(connector.calls.length, callsBefore + 1);
        expect(transport1.sentRaw, isNotEmpty);
        final Map<String, Object?> sent = _decode(transport1.sentRaw.first);
        expect(sent['t'], 'resume');
        expect(
          sent['d'],
          equals(<String, Object?>{
            'code': cachedCode,
            'seat_token': cachedToken,
          }),
        );

        final String id = sent['id']! as String;
        transport1.pushText(
          _frame(type: 'room', re: id, data: _roomJson(seq: 2)),
        );
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.connected);

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  }

  // ==========================================================================
  // G-2: the same dead socket produces both a failed request and a `done`.
  // Measured, not assumed: see the comment inside for which order this
  // file's fixtures can produce, and why the other order cannot be forced.
  // ==========================================================================
  test('G-2: the socket closes while roll() is in flight, so both the request '
      'failure and done fire from the one drop; every attempt fails at the '
      'connector and the whole schedule elapses: the connector is called '
      'exactly 1 + autoReconnectDelays.length times in the whole test', () {
    // FakeTransport.endFromFarSide() completes both the pending roll()
    // request (with ConnectionClosedException, inside RoomConnection.
    // _finishClosing's loop over _pending) and RoomConnection.done, in
    // that order, inside the same synchronous call to _finishClosing():
    // requests are failed first, `_doneCompleter.complete()` runs last.
    // Both are then delivered to this controller as separate microtasks,
    // in the order they completed, so the request-failure path always
    // reaches _connection first here. FakeTransport exposes no way to
    // reverse that -- there is no hook to deliver "done" before "the
    // pending request fails" -- so only this one order is exercised. Per
    // the order's instruction: it does not let the other order be forced.
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );

      unawaited(controller.roll());
      async.flushMicrotasks();

      transport0.endFromFarSide();
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: the drop must have failed the in-flight '
            'roll()',
      );
      expect(
        controller.errorCode,
        'closed',
        reason:
            'a connection ending with a request outstanding maps to '
            '"closed", one of the three retryable codes',
      );

      final int callsBefore = connector.calls.length;
      for (int i = 0; i < _delays.length; i++) {
        connector.rejectNextWith(Exception('G-2 attempt #$i refused'));
        async.elapse(_delays[i]);
        async.flushMicrotasks();
        expect(
          connector.calls.length,
          callsBefore + i + 1,
          reason:
              'G2: one sequence must have started from this drop -- '
              'whichever of the request failure and done saw it first -- '
              'and attempt #${i + 1} must fire at its schedule position',
        );
        expect(controller.phase, RoomPhase.failed);
        expect(controller.errorCode, 'transport');
      }

      expect(
        connector.calls.length,
        1 + _delays.length,
        reason:
            'G2: exactly one sequence ran from this drop, making exactly '
            'autoReconnectDelays.length attempts on top of the original '
            'connection',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // G-0 (GREEN on base, control): delays empty.
  // ==========================================================================
  test('G-0 (control): delays empty, roll() times out: autoReconnectPending is '
      'false after ten minutes of fake clock and the connector is called '
      'exactly once', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
      );

      unawaited(controller.roll());
      async.flushMicrotasks();
      async.elapse(_requestTimeout);
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'timeout');
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C1/C4: autoReconnectDelays empty means automatic '
            'reconnection is off; no timer is ever created',
      );

      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();

      expect(controller.autoReconnectPending, isFalse);
      expect(
        connector.calls.length,
        1,
        reason:
            'C1: no second connector call may ever happen when '
            'autoReconnectDelays is empty, however long ten minutes of '
            'fake time elapse',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // G-N (GREEN on base, control): non-retryable failure, E2's scope.
  // ==========================================================================
  test('G-N (control): delays non-empty, roll() rejected BAD_SEAT_TOKEN '
      '(non-retryable, E2): no sequence starts', () {
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
            'code': 'BAD_SEAT_TOKEN',
            'message': 'stale seat token',
          },
        ),
      );
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'BAD_SEAT_TOKEN');
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'G1: BAD_SEAT_TOKEN is not in _retryableErrorCodes; a '
            'non-retryable failure of roll() must not start a sequence',
      );

      final int callsBefore = connector.calls.length;
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'G-N: no automatic attempt may ever follow a non-retryable '
            'rejection',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // G-3 (GREEN on base, control): G3, a fresh controller's joinRoom().
  // ==========================================================================
  test('G-3 (control): delays non-empty, a fresh controller\'s joinRoom() '
      'fails at the connector (transport): no sequence, connector count one '
      'after a minute', () {
    fakeAsync((FakeAsync async) {
      final _Connector connector = _Connector();
      connector.rejectNextWith(Exception('G-3 connector refused'));
      final RoomController controller = _newController(
        connector,
        autoReconnectDelays: _delays,
      );

      unawaited(controller.joinRoom(code: 'K7M2QP', name: 'Sam'));
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'transport');
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason: 'G3: joinRoom() failing must never start a sequence',
      );

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        1,
        reason:
            'G3: no automatic attempt may ever follow a joinRoom() '
            'failure',
      );
      expect(controller.autoReconnectPending, isFalse);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // L-1 (GREEN on base, order 167's open gap): leave() then onAppResumed().
  // ==========================================================================
  test('L-1: delays non-empty, a connected controller whose socket drops, '
      'then leave(), then onAppResumed(): no new connection after a minute '
      'of fake clock and autoReconnectPending stays false', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );

      transport.endFromFarSide();
      async.flushMicrotasks();
      expect(
        controller.phase,
        RoomPhase.closed,
        reason: 'fixture is broken: the drop must land in closed',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the drop must have armed a sequence '
            'before this test calls leave()',
      );

      unawaited(controller.leave());
      async.flushMicrotasks();
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'fixture is broken: leave() must cancel the pending timer '
            '(C8) before this test calls onAppResumed()',
      );

      final int callsBeforeResume = connector.calls.length;
      controller.onAppResumed();
      async.flushMicrotasks();

      expect(
        connector.calls.length,
        callsBeforeResume,
        reason:
            'order 167\'s recorded proof gap: onAppResumed() called '
            'after leave() must be a no-op -- "leave() has never been '
            'called" is one of C4\'s eligibility clauses, and this is the '
            'one case no A-case in room_controller_auto_reconnect_test.'
            'dart exercises',
      );
      expect(controller.autoReconnectPending, isFalse);

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsBeforeResume,
        reason:
            'L-1: no new connection may ever follow onAppResumed() '
            'called after leave()',
      );
      expect(controller.autoReconnectPending, isFalse);

      controller.dispose();
      async.flushMicrotasks();
    });
  });
}

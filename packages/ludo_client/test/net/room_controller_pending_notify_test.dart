// Proof for order 177's N: whenever control returns to the event loop
// outside dispose(), autoReconnectPending must equal the value it held at
// the most recent notifyListeners() call (or false if there has been none).
// Written from THE CONTRACT in
// work/ludo/orders/177-start-rejections-and-pending-notify.md, clauses N1
// and N2, copied verbatim from that order, and from nothing else. Where a
// case would need to assume something the contract leaves silent, that is
// called out at the case rather than guessed at.
//
// Built the way test/net/room_controller_request_failure_sequence_test.dart
// and test/net/room_controller_auto_reconnect_test.dart are built: a fake
// TransportConnector hands out FakeTransport instances
// (test/net/fake_transport.dart, read-only), frames are pushed with
// pushText, and every claim about what the controller sent is made by
// decoding FakeTransport.sentRaw. The helpers below are private copies for
// this file, not imports of either other file's own private helpers --
// neither file exports anything a test could import.
//
// Fake clock throughout (package:fake_async), following the house pattern
// at test/net/connection_test.dart:887-940: an async operation is started
// and its result captured with .then()/a bare call, not awaited directly,
// and FakeAsync.flushMicrotasks()/elapse() drive it to completion, because a
// fakeAsync callback must stay synchronous.
//
// Every case attaches exactly one listener, at the point the case names,
// that records autoReconnectPending on each notifyListeners() call. The N1
// check ("the last recorded value, or false if none, equals the getter") is
// asserted by _expectN1 below, which always quotes the recorded list in its
// failure reason, per the order's instruction.
//
// This file is written to run, unmodified, against packages/ludo_client on
// 24e9d8b (order 177 not yet landed): every case marked RED below is
// expected to fail there, for a reason that names the contract clause it
// violates, and every case marked GREEN or a control is expected to pass
// there already. Three cases (N-X, N-M, N-L) are not pinned RED or GREEN by
// the order itself ("say which"); each carries a comment explaining what was
// measured and why.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://order-178-n-test.invalid/ws';

/// N-D's own schedule, pinned by the order text ("delays [1s, 2s]"), reused
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
  return 'srv-178n-${_serverIdSeq.toString().padLeft(6, '0')}';
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

// --- the N1 rig ----------------------------------------------------------

/// Attaches the one listener the order specifies and returns the list it
/// records into: `controller.autoReconnectPending`, read again on every
/// notifyListeners() call from this point on.
List<bool> _trackPending(RoomController controller) {
  final List<bool> recorded = <bool>[];
  controller.addListener(() {
    recorded.add(controller.autoReconnectPending);
  });
  return recorded;
}

/// N1: "the value of autoReconnectPending equals the value it had at the
/// most recent notifyListeners() call, or false if there has been none."
/// [recorded] must be the list [_trackPending] returned for [controller];
/// [context] names the step the order says this must hold after, and is
/// folded into the failure reason together with the recorded list itself,
/// per the order's instruction to quote it in every failure.
void _expectN1(RoomController controller, List<bool> recorded, String context) {
  final bool expected = recorded.isEmpty ? false : recorded.last;
  expect(
    controller.autoReconnectPending,
    expected,
    reason:
        'N1 violated $context: the getter must equal the last recorded '
        'notification (or false if none) -- recorded=$recorded, '
        'getter=${controller.autoReconnectPending}',
  );
}

void main() {
  // ==========================================================================
  // N-D (RED on base): a drop's own timer is armed after the notification
  // that announces it.
  // ==========================================================================
  test('N-D: delays [1s, 2s], connected, the transport closes on its own -- '
      'after the drop settles, getter is true and the N1 check holds', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final List<bool> recorded = _trackPending(controller);

      transport.endFromFarSide();
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'fixture is broken: the drop must land in closed before this '
            'test checks N1',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the drop must have armed the sequence\'s '
            'first timer -- recorded=$recorded',
      );
      _expectN1(controller, recorded, 'after the drop settles');

      expect(
        connector.calls.length,
        1,
        reason:
            'fixture is broken: only the original connection must have '
            'been opened by this point',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // N-F (RED on base): C7's own reschedule after a failed automatic attempt.
  // ==========================================================================
  test('N-F: continuing from a drop, the first automatic attempt fails at '
      'the connector (transport) -- after it settles, getter is true (the '
      'second timer is scheduled) and the N1 check holds', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final List<bool> recorded = _trackPending(controller);

      transport0.endFromFarSide();
      async.flushMicrotasks();
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the drop must have armed the first timer '
            '-- recorded=$recorded',
      );

      connector.rejectNextWith(Exception('N-F attempt refused'));
      async.elapse(_delays[0]);
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: the first automatic attempt must have '
            'failed at the connector',
      );
      expect(controller.errorCode, 'transport');
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'C7: a retryable failure with a further delay in the list '
            'schedules the next attempt -- recorded=$recorded',
      );
      _expectN1(
        controller,
        recorded,
        'after the first automatic attempt settles',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // N-G (RED on base): G1's own reschedule after a timed-out in-room
  // request.
  // ==========================================================================
  test('N-G: delays non-empty, connected, roll() never answered -- after '
      'the clock passes the request timeout, getter is true and the N1 '
      'check holds', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final List<bool> recorded = _trackPending(controller);

      unawaited(controller.roll());
      async.flushMicrotasks();
      expect(
        transport.sentRaw,
        isNotEmpty,
        reason: 'fixture is broken: roll() must have reached the wire',
      );

      async.elapse(_requestTimeout);
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: an unanswered roll() left past '
            'RequestTimeoutException must land in failed',
      );
      expect(controller.errorCode, 'timeout');
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'G1: a retryable failure of an in-room request must start a '
            'sequence -- recorded=$recorded',
      );
      _expectN1(controller, recorded, 'after the request timeout settles');

      expect(connector.calls.length, 1);
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // N-X (GREEN on base -- see comment): exhaustion sets no further timer.
  // ==========================================================================
  test('N-X (GREEN on base -- see comment): the whole schedule exhausted, '
      'every attempt failing at the connector: getter is false and the N1 '
      'check holds', () {
    // Measured GREEN on base: once the last scheduled attempt fails,
    // _afterReconnectAttemptFailure finds _nextDelayIndex ==
    // autoReconnectDelays.length and only clears _sequenceRunning; no
    // further timer is ever created. The notifyListeners() inside that
    // last _failFromRequest already reports the same pending=false the
    // getter reads afterwards, so N1 is not violated by exhaustion --
    // unlike N-D, N-F and N-G, nothing here schedules a timer after a
    // notification that did not announce it.
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final List<bool> recorded = _trackPending(controller);

      transport0.endFromFarSide();
      async.flushMicrotasks();

      for (int i = 0; i < _delays.length; i++) {
        connector.rejectNextWith(Exception('N-X attempt #$i refused'));
        async.elapse(_delays[i]);
        async.flushMicrotasks();
      }

      expect(
        controller.phase,
        RoomPhase.failed,
        reason: 'fixture is broken: the schedule must be exhausted',
      );
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C7: the list is exhausted, the sequence ends, no timer is '
            'left pending -- recorded=$recorded',
      );
      _expectN1(controller, recorded, 'after the schedule is exhausted');

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // N-M (GREEN on base -- see comment): manual reconnect() never reschedules.
  // ==========================================================================
  test('N-M (GREEN on base -- see comment): a timer pending, then '
      'reconnect() (manual): N1 holds immediately after the call returns '
      'and after the attempt settles', () {
    // Measured GREEN on base, both checks. reconnect() calls
    // _cancelAutoReconnect() -- which clears the timer with no
    // notification of its own -- before _attemptReconnect's first
    // notifyListeners() (phase connecting) ever fires, so that
    // notification already reports the cleared pending: the first check
    // holds by construction. A manual attempt's failure never reschedules
    // (_afterReconnectAttemptFailure returns immediately once it sees
    // !automatic, before it would otherwise call _scheduleNextAttempt), so
    // no timer is ever set after _failFromRequest's own notification
    // either: the second check holds too.
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
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the drop must have armed a pending timer '
            'before this test calls reconnect()',
      );

      final List<bool> recorded = _trackPending(controller);
      connector.rejectNextWith(Exception('N-M manual reconnect refused'));
      unawaited(controller.reconnect());

      _expectN1(controller, recorded, 'immediately after reconnect() returns');
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C8: a manual reconnect() call cancels the pending automatic '
            'timer -- recorded=$recorded',
      );

      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: the manual attempt must have failed at '
            'the connector',
      );
      expect(controller.errorCode, 'transport');
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C8: a retryable failure of a manual attempt must not start '
            'a new automatic sequence -- recorded=$recorded',
      );
      _expectN1(controller, recorded, 'after the manual attempt settles');

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // N-A (RED on base -- see comment): onAppResumed()'s own immediate
  // attempt reschedules through the same C7 path N-F exercises.
  // ==========================================================================
  test('N-A (RED on base -- see comment): a timer pending, then '
      'onAppResumed(): N1 holds immediately after the call returns, and '
      'is violated once the attempt settles', () {
    // The first check is GREEN on base, for the same reason as N-M's:
    // onAppResumed() cancels the pending timer before _startSequence's
    // immediate attempt fires its own notifyListeners() (phase
    // connecting), so that notification already reports the cleared
    // pending. The second check is RED: this immediate attempt is
    // automatic (_runAutomaticAttempt -> _attemptReconnect(automatic:
    // true, ...)), and when it fails retryably with a further delay left
    // in the schedule, _afterReconnectAttemptFailure schedules the next
    // timer -- C7, the same path N-F exercises from a drop -- after
    // _failFromRequest's own notifyListeners() already reported pending
    // false.
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
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the drop must have armed a pending timer '
            'before this test calls onAppResumed()',
      );

      final List<bool> recorded = _trackPending(controller);
      connector.rejectNextWith(Exception('N-A onAppResumed attempt refused'));
      controller.onAppResumed();

      _expectN1(
        controller,
        recorded,
        'immediately after onAppResumed() returns',
      );
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C10: onAppResumed() cancels the pending timer before running '
            'its own immediate attempt -- recorded=$recorded',
      );

      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: the resumed attempt must have failed at '
            'the connector',
      );
      expect(controller.errorCode, 'transport');
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'C7: a retryable failure with a further delay in the list '
            'schedules the next attempt -- recorded=$recorded',
      );
      _expectN1(controller, recorded, 'after the resumed attempt settles');

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // N-L (GREEN on base -- see comment): leave() cancels ahead of its own
  // notification, and dispose() never notifies at all.
  // ==========================================================================
  test('N-L (GREEN on base -- see comment): a timer pending, then leave(): '
      'getter false, N1 holds, and no notification after dispose()', () {
    // Measured GREEN on base. leave() calls _cancelAutoReconnect() --
    // clearing the timer with no notification of its own -- before its own
    // final notifyListeners() (phase closed), so that notification already
    // reports the cleared pending; nothing schedules a timer afterwards.
    // dispose() never calls notifyListeners() at all (ChangeNotifier's own
    // dispose() does not notify), so there is nothing to violate there
    // either. dispose() is called inside this test's body, not left to
    // addTearDown, specifically so "no notification after dispose()" is
    // something this test actually observes rather than assumes.
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
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the drop must have armed a pending timer '
            'before this test calls leave()',
      );

      final List<bool> recorded = _trackPending(controller);
      unawaited(controller.leave());
      async.flushMicrotasks();

      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C8: leave() must cancel the pending timer -- recorded=$recorded',
      );
      _expectN1(controller, recorded, 'after leave() settles');

      final int recordedBeforeDispose = recorded.length;
      controller.dispose();
      async.flushMicrotasks();

      expect(
        recorded.length,
        recordedBeforeDispose,
        reason:
            'no notification may ever fire after dispose() -- '
            'recorded=$recorded',
      );

      expect(connector.calls.length, 1);
    });
  });

  // ==========================================================================
  // N-Q (GREEN on base, control for N2): delays empty, nothing ever moves.
  // ==========================================================================
  test('N-Q (control, GREEN on base): delays empty, the transport drops: '
      'the recorded list contains no true at all and the getter is false '
      'after a minute', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
      );
      final List<bool> recorded = _trackPending(controller);

      transport.endFromFarSide();
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C1: empty autoReconnectDelays means automatic reconnection '
            'is off -- recorded=$recorded',
      );

      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();

      expect(
        recorded.contains(true),
        isFalse,
        reason:
            'N2/C1: with autoReconnectDelays empty, autoReconnectPending '
            'must never become true -- recorded=$recorded',
      );
      expect(controller.autoReconnectPending, isFalse);
      _expectN1(controller, recorded, 'after a minute with delays empty');
      expect(
        connector.calls.length,
        1,
        reason:
            'C1: no second connector call may ever happen when '
            'autoReconnectDelays is empty',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // ==========================================================================
  // N-LW (RETURN 1, item 1; RED on base): leave()'s own await window.
  // ==========================================================================
  test('N-LW: a timer pending, then leave() called without awaiting it -- '
      'the N1 check must hold inside leave()\'s own await window, before '
      'its future completes, and again after it settles', () {
    // N-L (above) only ever checks N1 after awaiting leave() to completion,
    // by which point leave()'s own final notifyListeners() (phase closed)
    // has already reported the settled state and nothing distinguishes a
    // controller that notified the cancellation from one that did not. The
    // defect this case exists to catch is entirely inside the window
    // leave() spends suspended at `await connection.leaveRoom()`: control
    // returns to the event loop with _cancelAutoReconnect() already having
    // cleared the timer, but nothing yet said so.
    //
    // Giving this case a last recorded value to measure that moment against
    // is not free: once a timer is genuinely pending, phase is closed or
    // failed and that connection's transport is already closed, so there is
    // no live transport left to push a further frame on to force an honest
    // notification the way this case's own drop cannot (FakeTransport
    // .pushText after close is a harness error, not something a real socket
    // can do either). _openFresh (createRoom, joinRoom) is the one path
    // that opens a *fresh* transport without ever touching the pending
    // timer on its way to connected (RETURN 1, item 2; N-J below turns
    // exactly this into its own case) -- its own connecting/connected
    // notifications, on that fresh transport, read the timer's real,
    // still-pending state honestly, for a reason that has nothing to do
    // with the timer itself. That is what this case uses to give itself a
    // last recorded value, and it is why leave() below runs against a
    // connection that is live, not the dead one an ordinary drop leaves
    // behind: the defect under test -- _cancelAutoReconnect() cancelling
    // ahead of leave()'s own notify, inside the same await window -- does
    // not depend on which connection leave() happens to be awaiting
    // leaveRoom() on.
    //
    // _openFresh's own gate is idle or failed, not closed, so the pending
    // timer here has to come from an in-room request failing (G1, the same
    // unanswered-roll()-times-out path N-G and N-J both use) rather than
    // from an ordinary drop, which would leave phase closed and joinRoom()
    // a silent no-op.
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
      async.elapse(_requestTimeout);
      async.flushMicrotasks();
      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: an unanswered roll() left past '
            'RequestTimeoutException must land in failed before this '
            'test calls leave()',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: G1 must have armed a pending timer before '
            'this test calls leave()',
      );

      final List<bool> recorded = _trackPending(controller);

      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      unawaited(controller.joinRoom(code: 'K7M2QP', name: 'Ann'));
      async.flushMicrotasks();
      final String joinId = _idOf(transport1.sentRaw.last);
      transport1.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 1, 'seat_token': 'tok-178n-lw'},
        ),
      );
      transport1.pushText(
        _frame(type: 'room', re: joinId, data: _roomJson(hostSeat: 1)),
      );
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: joinRoom() on the fresh transport must '
            'have landed in connected while the earlier sequence\'s timer '
            'is still pending -- recorded=$recorded',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the earlier timer must still be pending '
            'right after joinRoom() settles -- recorded=$recorded',
      );
      expect(
        recorded.last,
        isTrue,
        reason:
            'fixture is broken: joinRoom()\'s own connecting and '
            'connected notifications must have honestly captured the '
            'still-pending timer -- recorded=$recorded',
      );

      final Future<void> leaveFuture = controller.leave();
      // leave() runs synchronously through _cancelAutoReconnect() and only
      // then reaches `await connection.leaveRoom()`; by the time this
      // statement returns, that await has already suspended the method and
      // control is back here, with the cancellation already applied but
      // leave()'s own future nowhere near complete.
      _expectN1(
        controller,
        recorded,
        'inside leave()\'s await window, immediately after the call '
        'returns and before its future completes',
      );

      final String leaveId = _idOf(transport1.sentRaw.last);
      transport1.pushText(
        _frame(
          type: 'player_left',
          re: leaveId,
          data: <String, Object?>{'seat': 1, 'seq': 2},
        ),
      );
      async.flushMicrotasks();
      unawaited(leaveFuture);

      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C8: leave() must cancel the pending timer -- '
            'recorded=$recorded',
      );
      _expectN1(controller, recorded, 'after leave() settles');

      final int recordedBeforeDispose = recorded.length;
      controller.dispose();
      async.flushMicrotasks();

      expect(
        recorded.length,
        recordedBeforeDispose,
        reason:
            'no notification may ever fire after dispose() -- '
            'recorded=$recorded',
      );
    });
  });

  // ==========================================================================
  // N-J (RETURN 1, item 2; RED on base): a timer firing into
  // _onReconnectTimerFired's end branch while phase has moved on.
  // ==========================================================================
  test('N-J: delays [1s, 2s], connected, roll() never answered, the clock '
      'passes the request timeout -- then joinRoom() on a fresh transport, '
      'answered while the earlier sequence\'s timer is still pending, so '
      'phase is connected when the clock elapses the delay and that stray '
      'timer fires: getter is false and the N1 check holds', () {
    // No case anywhere else in this file lets a scheduled timer fire while
    // _eligible is false or phase has moved off closed/failed:
    // _onReconnectTimerFired's branch that does that -- clearing the timer,
    // ending the sequence, and (177's fix) notifying because nothing else
    // in that call is going to -- is reachable only because _openFresh
    // (createRoom, joinRoom) never cancels a pending timer on its way to a
    // gate of idle or failed. G1's own sequence (armed by an unanswered
    // roll() timing out) is left dangling exactly that way here.
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final List<bool> recorded = _trackPending(controller);

      unawaited(controller.roll());
      async.flushMicrotasks();
      expect(
        transport0.sentRaw,
        isNotEmpty,
        reason: 'fixture is broken: roll() must have reached the wire',
      );

      async.elapse(_requestTimeout);
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: an unanswered roll() left past '
            'RequestTimeoutException must land in failed',
      );
      expect(controller.errorCode, 'timeout');
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: G1 must have armed the sequence\'s first '
            'timer -- recorded=$recorded',
      );

      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      unawaited(controller.joinRoom(code: 'K7M2QP', name: 'Ann'));
      async.flushMicrotasks();
      final String joinId = _idOf(transport1.sentRaw.last);
      transport1.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 1, 'seat_token': 'tok-178n-join'},
        ),
      );
      transport1.pushText(
        _frame(type: 'room', re: joinId, data: _roomJson(hostSeat: 1)),
      );
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: joinRoom() on the fresh transport must '
            'have landed in connected while the earlier sequence\'s timer '
            'is still pending -- _openFresh never cancels it -- '
            'recorded=$recorded',
      );
      expect(
        connector.calls.length,
        2,
        reason:
            'fixture is broken: joinRoom() must have opened its own, '
            'second connection',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the earlier timer must still be pending '
            'right after joinRoom() settles, before this case elapses the '
            'delay -- recorded=$recorded',
      );

      async.elapse(_delays[0]);
      async.flushMicrotasks();

      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C7: the stray timer firing while phase is connected must '
            'clear itself and end that sequence -- recorded=$recorded',
      );
      _expectN1(
        controller,
        recorded,
        'after the stray timer fires into the end branch of '
        '_onReconnectTimerFired',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });
}

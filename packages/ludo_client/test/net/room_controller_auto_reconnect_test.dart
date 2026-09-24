// Proof for order 166's automatic reconnection, written from THE CONTRACT
// in work/ludo/orders/167-prove-auto-reconnect.md (clauses C1-C11), copied
// verbatim from order 166, and from nothing else. This file does not assume
// any behaviour that clause does not state; where a case would need to
// assume something the contract leaves silent, that is called out at the
// case rather than guessed at.
//
// Built the way test/net/room_controller_test.dart is built: a fake
// TransportConnector hands out FakeTransport instances
// (test/net/fake_transport.dart, read-only), frames are pushed with
// pushText, and every claim about what the controller sent is made by
// decoding FakeTransport.sentRaw, never by trusting that "a message was
// sent". The helpers below (_frame, _roomJson, _Connector,
// _connectedControllerSync) are private copies for this file, not imports
// of room_controller_test.dart's own private helpers.
//
// Every case that depends on a delay runs inside fakeAsync
// (package:fake_async), following the house pattern at
// test/net/connection_test.dart:887-940: an async operation is started and
// its result captured with .then()/a bare call, not awaited directly, and
// FakeAsync.flushMicrotasks()/elapse() drive it to completion, because a
// fakeAsync callback must be synchronous. A short, distinctive schedule
// (1s, 3s, 7s) is used throughout so an attempt landing at the wrong
// cumulative delay is unambiguous, per the order's guidance.
//
// Attempts are counted by counting connector calls (or the transports
// handed to it), never by reading `phase`, per the order.
//
// Every case builds its own controller (standing lesson 35: one mount, one
// controller, per case).

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomState;
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/server_config.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://order-167-test.invalid/ws';

/// A short, distinctive schedule: an attempt landing at the wrong
/// cumulative delay against this list is unambiguous.
const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 3),
  Duration(seconds: 7),
];

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-167-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  'turn': null,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double that records and queues ----------

/// Hands out queued [FakeTransport]s, one per call, in order. Records every
/// url it was called with so a test can assert exactly how many times a
/// connection was ever attempted. [rejectNextWith] makes exactly the next
/// call reject instead, to exercise the connector-rejects path ('transport')
/// without touching any transport at all.
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

/// Builds a controller inside a running [FakeAsync] zone, drives it through
/// a successful createRoom() using .then()/flushMicrotasks rather than a
/// direct await (a fakeAsync callback must stay synchronous, the house
/// pattern at test/net/connection_test.dart:887-940), and returns it already
/// in phase connected with room, seat and seatToken all populated.
(RoomController, FakeTransport, _Connector) _connectedControllerSync(
  FakeAsync async, {
  List<Duration> autoReconnectDelays = const <Duration>[],
  int hostSeat = 0,
  String code = 'K7M2QP',
  int players = 4,
  int seq = 1,
}) {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(
    connector,
    autoReconnectDelays: autoReconnectDelays,
  );

  unawaited(controller.createRoom(name: 'Sam', players: players));
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
      data: _roomJson(
        code: code,
        hostSeat: hostSeat,
        players: players,
        seq: seq,
      ),
    ),
  );
  async.flushMicrotasks();

  return (controller, transport, connector);
}

// --- widget-level (A14) helpers -----------------------------------------

Widget _homeScreenApp({required RoomControllerFactory controllerFactory}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<Object?>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

void main() {
  // --- A1: default off (C1). --------------------------------------------
  test('A1 default off (C1): no autoReconnectDelays, drop, elapse ten minutes: '
      'phase stays closed, no second connector call, autoReconnectPending '
      'false', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
      );
      expect(controller.phase, RoomPhase.connected);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C1: empty autoReconnectDelays means automatic reconnection '
            'is off; no timer is ever created',
      );

      final int callsBefore = connector.calls.length;
      transport.endFromFarSide();
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C1: a drop with autoReconnectDelays empty must not arm a '
            'timer',
      );

      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'C1: with autoReconnectDelays empty the controller must '
            'behave exactly as it did before order 166 (24ddca6): no '
            'phase change from a passage of time alone',
      );
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'C1: no second connector call may ever happen when '
            'autoReconnectDelays is empty, however long ten minutes of '
            'fake time elapse',
      );
      expect(controller.autoReconnectPending, isFalse);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A2: first attempt (C5, C7). ---------------------------------------
  test('A2 first attempt (C5, C7): a drop schedules exactly one attempt at '
      'delays[0], resume carries the cached code and seat token, and a '
      'successful reply clears autoReconnectPending', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport1,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final String cachedCode = controller.room!.code;
      final String cachedToken = controller.seatToken!;
      final int callsBefore = connector.calls.length;

      transport1.endFromFarSide();
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.closed);

      // Just before delays[0]: no second connector call, pending true.
      async.elapse(_delays[0] - const Duration(milliseconds: 1));
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'C5/C7: the automatic attempt must not fire before delays[0] '
            'has fully elapsed',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason: "C9: true while the sequence's timer is scheduled",
      );

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();

      expect(
        connector.calls.length,
        callsBefore + 1,
        reason: 'C7: exactly one new transport at delays[0]',
      );
      expect(transport2.sentRaw, isNotEmpty);
      final Map<String, Object?> sent = _decode(transport2.sentRaw.first);
      expect(
        sent['t'],
        'resume',
        reason: "C7: the attempt's first sent frame must be resume",
      );
      expect(
        sent['d'],
        equals(<String, Object?>{
          'code': cachedCode,
          'seat_token': cachedToken,
        }),
        reason:
            'C7: resume must carry the cached code and seat token, got '
            'd=${sent['d']}',
      );
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C9: false while an attempt is in flight, even though the '
            'sequence is still running',
      );

      final String id2 = sent['id']! as String;
      transport2.pushText(
        _frame(type: 'room', re: id2, data: _roomJson(seq: 2)),
      );
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.connected);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason: 'C7: the sequence ends once an attempt reaches connected',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A3: schedule and exhaustion (C7). ----------------------------------
  test('A3 schedule and exhaustion (C7): every attempt fails at the connector '
      "('transport'); attempts land at exactly the cumulative delays, there "
      'are exactly delays.length of them, then phase failed, pending false, '
      'and ten further minutes produce no attempt', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final int callsBefore = connector.calls.length;

      transport0.endFromFarSide();
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.closed);

      for (int i = 0; i < _delays.length; i++) {
        connector.rejectNextWith(Exception('A3 attempt #$i refused'));

        async.elapse(_delays[i] - const Duration(milliseconds: 1));
        expect(
          connector.calls.length,
          callsBefore + i,
          reason:
              'C7: attempt #${i + 1} must not fire before its own '
              'delays[$i] has fully elapsed since the previous attempt',
        );

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(
          connector.calls.length,
          callsBefore + i + 1,
          reason: 'C7: attempt #${i + 1} must fire at exactly delays[$i]',
        );
        expect(controller.phase, RoomPhase.failed);
        expect(controller.errorCode, 'transport');
      }

      expect(
        connector.calls.length,
        callsBefore + _delays.length,
        reason: 'C7: exactly delays.length attempts, no more, no fewer',
      );
      expect(controller.phase, RoomPhase.failed);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C7: the list is exhausted, the sequence ends, no timer is '
            'left pending',
      );

      final int callsAfterExhaustion = connector.calls.length;
      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsAfterExhaustion,
        reason:
            'C7: an exhausted sequence must never produce a further '
            'attempt, however long ten minutes of fake time elapse',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A4: retryable request failure continues (C3, C7). -----------------
  test('A4 retryable request failure continues (C3, C7): an attempt whose '
      "socket opens and then ends before resume is answered ('closed') is "
      'followed by the next attempt on schedule', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final int callsBefore = connector.calls.length;

      transport0.endFromFarSide();
      async.flushMicrotasks();

      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      async.elapse(_delays[0]);
      async.flushMicrotasks();
      expect(connector.calls.length, callsBefore + 1);
      expect(_decode(transport1.sentRaw.first)['t'], 'resume');

      // The socket ends before resume is answered.
      transport1.endFromFarSide();
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.failed);
      expect(
        controller.errorCode,
        'closed',
        reason:
            "C3: a connection ending with resume outstanding maps to "
            "'closed', one of the three retryable codes",
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'C7: a retryable failure with a further delay in the list '
            'schedules the next attempt',
      );

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      async.elapse(_delays[1] - const Duration(milliseconds: 1));
      expect(
        connector.calls.length,
        callsBefore + 1,
        reason: 'the next attempt must wait for delays[1], not fire early',
      );
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsBefore + 2,
        reason:
            'C7: the next attempt after a retryable failure follows on '
            'schedule, at delays[1]',
      );
      expect(_decode(transport2.sentRaw.first)['t'], 'resume');

      // Answer it so no timer is left pending.
      final String id2 = _decode(transport2.sentRaw.first)['id']! as String;
      transport2.pushText(
        _frame(type: 'room', re: id2, data: _roomJson(seq: 2)),
      );
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.connected);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A5: non-retryable stops (C3, C7, C10). -----------------------------
  test("A5 non-retryable stops (C3, C7, C10): an attempt's resume is answered "
      "with an error frame BAD_SEAT_TOKEN carrying the right re; phase "
      'failed, errorCode BAD_SEAT_TOKEN, no further attempt ever, and a '
      'later onAppResumed() opens nothing', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );

      transport0.endFromFarSide();
      async.flushMicrotasks();

      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      async.elapse(_delays[0]);
      async.flushMicrotasks();

      final Map<String, Object?> sent = _decode(transport1.sentRaw.first);
      expect(sent['t'], 'resume');
      final String id = sent['id']! as String;
      transport1.pushText(
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
            'C7: a non-retryable failure blocks the controller and ends '
            'the sequence; no timer is scheduled',
      );

      final int callsAfterFailure = connector.calls.length;
      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsAfterFailure,
        reason: 'C7: no further attempt ever follows a non-retryable failure',
      );

      controller.onAppResumed();
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsAfterFailure,
        reason:
            'C3/C10: a blocked controller is not eligible, so '
            'onAppResumed() must open nothing',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A6: seat takeover (C3). --------------------------------------------
  test('A6 seat takeover (C3): an unsolicited error frame (no re) followed by '
      'the far side ending blocks automatic reconnection; no attempt ever, '
      'pending false, and onAppResumed() opens nothing -- A2 is this case\'s '
      'control', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final int callsBefore = connector.calls.length;

      transport.pushText(
        _frame(
          type: 'error',
          data: <String, Object?>{
            'code': 'BAD_SEAT_TOKEN',
            'message': 'seat retaken by a newer socket',
          },
        ),
      );
      async.flushMicrotasks();
      transport.endFromFarSide();
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C3: an unsolicited error frame blocks the controller before '
            'the drop it precedes; the drop must not start a sequence',
      );

      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'C3: a blocked controller must never make an automatic '
            'attempt, however long ten minutes of fake time elapse',
      );

      controller.onAppResumed();
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'C3/C10: onAppResumed() must also be a no-op while '
            'blocked',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A7: finished room (C4). --------------------------------------------
  test(
    'A7 finished room (C4): a drop while room.state == RoomState.finished '
    '(reached through the wire, via game_over) makes no automatic attempt',
    () {
      fakeAsync((FakeAsync async) {
        final (
          RoomController controller,
          FakeTransport transport,
          _Connector connector,
        ) = _connectedControllerSync(
          async,
          autoReconnectDelays: _delays,
        );

        transport.pushText(
          _frame(
            type: 'game_over',
            data: <String, Object?>{
              'winner': 0,
              'verify_url': 'https://provefair.app/v/abc',
              'seq': 2,
            },
          ),
        );
        async.flushMicrotasks();
        expect(
          controller.room!.state,
          RoomState.finished,
          reason:
              'fixture is broken: game_over must bring room.state to '
              'finished before this test drops the connection',
        );

        final int callsBefore = connector.calls.length;
        transport.endFromFarSide();
        async.flushMicrotasks();

        expect(controller.phase, RoomPhase.closed);
        expect(
          controller.autoReconnectPending,
          isFalse,
          reason:
              'C4: a finished room is not eligible for automatic '
              'reconnection',
        );

        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(
          connector.calls.length,
          callsBefore,
          reason:
              'C4: no automatic attempt may ever happen once room.state is '
              'finished',
        );

        controller.dispose();
        async.flushMicrotasks();
      });
    },
  );

  // --- A8: leave cancels (C8). ---------------------------------------------
  test('A8 leave cancels (C8): drop, pending true, leave(): pending false, no '
      'attempt ever', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final int callsBefore = connector.calls.length;

      transport.endFromFarSide();
      async.flushMicrotasks();
      expect(controller.autoReconnectPending, isTrue);

      unawaited(controller.leave());
      async.flushMicrotasks();

      expect(
        controller.autoReconnectPending,
        isFalse,
        reason: 'C8: leave() must cancel the pending timer',
      );

      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'C8: leave() must end the sequence; no automatic attempt '
            'ever follows',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A9: dispose cancels (C8). --------------------------------------------
  test('A9 dispose cancels (C8): drop, pending true, dispose(): no attempt, '
      "and no timer left pending (fakeAsync's pendingTimers is empty "
      'afterwards)', () {
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
      expect(controller.autoReconnectPending, isTrue);

      final int callsBefore = connector.calls.length;
      controller.dispose();
      async.flushMicrotasks();

      expect(
        controller.autoReconnectPending,
        isFalse,
        reason: 'C8: dispose() must cancel the pending timer',
      );

      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'C8: dispose() must end the sequence; no automatic attempt '
            'ever follows',
      );

      expect(
        async.pendingTimers,
        isEmpty,
        reason: 'C8: no timer may be left pending after dispose()',
      );
    });
  });

  // --- A10: manual reconnect ends the sequence (C8). -----------------------
  test('A10 manual reconnect ends the sequence (C8): drop, pending true, call '
      "reconnect() with the connector failing: phase failed 'transport', "
      'pending false, and no automatic attempt ever follows', () {
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
      expect(controller.autoReconnectPending, isTrue);

      connector.rejectNextWith(Exception('manual reconnect refused'));
      unawaited(controller.reconnect());
      async.flushMicrotasks();

      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'transport');
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'C8: a manual reconnect() call cancels the pending '
            'automatic timer',
      );

      final int callsAfterManual = connector.calls.length;
      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsAfterManual,
        reason:
            'C8: a retryable failure of a manual attempt must not start '
            'a new automatic sequence',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A11: one sequence at a time (C6). ------------------------------------
  test('A11 one sequence at a time (C6): an attempt succeeds, that new socket '
      'drops, and the next attempt comes at delays[0] after that drop, not a '
      'later index; at no moment is more than one timer pending', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      expect(async.pendingTimers.length, lessThanOrEqualTo(1));

      final int callsBefore = connector.calls.length;
      transport0.endFromFarSide();
      async.flushMicrotasks();
      expect(async.pendingTimers.length, lessThanOrEqualTo(1));
      expect(controller.autoReconnectPending, isTrue);

      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      async.elapse(_delays[0]);
      async.flushMicrotasks();
      expect(async.pendingTimers.length, lessThanOrEqualTo(1));
      expect(connector.calls.length, callsBefore + 1);

      final String id1 = _decode(transport1.sentRaw.first)['id']! as String;
      transport1.pushText(
        _frame(type: 'room', re: id1, data: _roomJson(seq: 2)),
      );
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.connected);
      expect(async.pendingTimers.length, lessThanOrEqualTo(1));
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason: 'C7: the sequence ends on a connected outcome',
      );

      final int callsBeforeSecondDrop = connector.calls.length;
      transport1.endFromFarSide();
      async.flushMicrotasks();
      expect(async.pendingTimers.length, lessThanOrEqualTo(1));
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason: 'C5: a later drop starts a fresh sequence',
      );

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);
      async.elapse(_delays[0] - const Duration(milliseconds: 1));
      expect(
        connector.calls.length,
        callsBeforeSecondDrop,
        reason:
            'C6: the fresh sequence must restart from delays[0], not '
            'continue at a later index',
      );
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(
        connector.calls.length,
        callsBeforeSecondDrop + 1,
        reason:
            'C6: exactly one attempt lands, at delays[0] after the '
            'second drop',
      );
      expect(async.pendingTimers.length, lessThanOrEqualTo(1));

      final String id2 = _decode(transport2.sentRaw.first)['id']! as String;
      transport2.pushText(
        _frame(type: 'room', re: id2, data: _roomJson(seq: 3)),
      );
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.connected);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A12: onAppResumed (C10). ---------------------------------------------
  test('A12 onAppResumed after exhaustion (C10): runs an attempt immediately '
      '(no elapsed time); on a further retryable failure the next attempt '
      'follows delays[0]', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport0,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );

      transport0.endFromFarSide();
      async.flushMicrotasks();

      // Exhaust the whole schedule, every attempt failing at the
      // connector, mirroring A3.
      for (int i = 0; i < _delays.length; i++) {
        connector.rejectNextWith(Exception('A12 exhaustion attempt #$i'));
        async.elapse(_delays[i]);
        async.flushMicrotasks();
      }
      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture is broken: the schedule must be exhausted before '
            'this test calls onAppResumed()',
      );
      expect(controller.autoReconnectPending, isFalse);

      final int callsBeforeResume = connector.calls.length;
      connector.rejectNextWith(Exception('resumed attempt fails too'));
      controller.onAppResumed();
      async.flushMicrotasks();

      expect(
        connector.calls.length,
        callsBeforeResume + 1,
        reason: 'C10: onAppResumed() must make an attempt with no delay',
      );
      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'transport');
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'C10: on a retryable failure the next attempt follows '
            'autoReconnectDelays[0]',
      );

      final FakeTransport transportAfterResume = FakeTransport();
      connector.enqueue(transportAfterResume);
      async.elapse(_delays[0] - const Duration(milliseconds: 1));
      expect(
        connector.calls.length,
        callsBeforeResume + 1,
        reason:
            'the next attempt must wait for delays[0], not fire '
            'immediately again',
      );
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(connector.calls.length, callsBeforeResume + 2);

      final String id =
          _decode(transportAfterResume.sentRaw.first)['id']! as String;
      transportAfterResume.pushText(
        _frame(type: 'room', re: id, data: _roomJson(seq: 2)),
      );
      async.flushMicrotasks();
      expect(controller.phase, RoomPhase.connected);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('A12 control (C10): onAppResumed() while connected opens nothing', () {
    fakeAsync((FakeAsync async) {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = _connectedControllerSync(
        async,
        autoReconnectDelays: _delays,
      );
      final int callsBefore = connector.calls.length;

      controller.onAppResumed();
      async.flushMicrotasks();

      expect(
        connector.calls.length,
        callsBefore,
        reason:
            'C10: onAppResumed() must be a no-op unless phase is '
            'closed or failed',
      );
      expect(controller.phase, RoomPhase.connected);
      // Keep the analyzer from flagging transport as unused: it exists
      // for symmetry with the other cases' destructuring and to make
      // clear no frame is ever pushed to it here.
      expect(transport.sentRaw, isNotEmpty);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  // --- A13: production schedule (C2). ---------------------------------------
  test('A13 production schedule (C2): kAutoReconnectDelays is 1, 2, 4, 8, 15 '
      'seconds in that order, and defaultRoomControllerFactory().'
      'autoReconnectDelays equals it', () {
    expect(kAutoReconnectDelays, <Duration>[
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
      const Duration(seconds: 15),
    ]);

    final RoomController controller = defaultRoomControllerFactory();
    expect(controller.autoReconnectDelays, kAutoReconnectDelays);
    controller.dispose();
  });

  // --- A14: the foreground hook (C11). --------------------------------------
  testWidgets(
    'A14 the foreground hook (C11): app resumed opens a new transport and '
    'sends resume while an hour-long automatic timer is pending',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport1 = FakeTransport();
      connector.enqueue(transport1);
      RoomController? built;
      RoomController factory() {
        final RoomController created = RoomController(
          serverUrl: Uri.parse('wss://order-167-a14.invalid/ws'),
          connect: connector.call,
          autoReconnectDelays: const <Duration>[Duration(hours: 1)],
        );
        built = created;
        return created;
      }

      await tester.pumpWidget(_homeScreenApp(controllerFactory: factory));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('create-room-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final RoomController controller = built!;
      expect(
        connector.calls.length,
        1,
        reason:
            'fixture is broken: Create Room must have opened exactly one '
            'connection by now',
      );

      final List<Map<String, Object?>> sentBeforeReply = transport1.sentRaw
          .map(_decode)
          .toList();
      expect(sentBeforeReply, hasLength(1));
      expect(sentBeforeReply.single['t'], 'create_room');
      final String createId = sentBeforeReply.single['id']! as String;
      transport1.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
        ),
      );
      transport1.pushText(
        _frame(type: 'room', re: createId, data: _roomJson()),
      );
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: create_room must have completed before '
            'this test drops the socket',
      );

      transport1.endFromFarSide();
      await tester.pump();
      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the drop must have armed the hour-long '
            'automatic timer before this test resumes the app',
      );

      final FakeTransport transport2 = FakeTransport();
      connector.enqueue(transport2);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(
        connector.calls.length,
        2,
        reason:
            'C11: a resumed app lifecycle event must call onAppResumed(), '
            'opening a new connection',
      );
      expect(transport2.sentRaw, isNotEmpty);
      final Map<String, Object?> sent2 = _decode(transport2.sentRaw.first);
      expect(sent2['t'], 'resume');

      // Answer it so no timer is left pending (standing lesson 9).
      final String id2 = sent2['id']! as String;
      transport2.pushText(
        _frame(type: 'room', re: id2, data: _roomJson(seq: 2)),
      );
      await tester.pump();
      expect(controller.phase, RoomPhase.connected);
      expect(controller.autoReconnectPending, isFalse);
    },
  );

  testWidgets('A14c control (C11): app going inactive does not trigger '
      'onAppResumed(); no new transport is opened', (
    WidgetTester tester,
  ) async {
    final _Connector connector = _Connector();
    final FakeTransport transport1 = FakeTransport();
    connector.enqueue(transport1);
    RoomController? built;
    RoomController factory() {
      final RoomController created = RoomController(
        serverUrl: Uri.parse('wss://order-167-a14c.invalid/ws'),
        connect: connector.call,
        autoReconnectDelays: const <Duration>[Duration(hours: 1)],
      );
      built = created;
      return created;
    }

    await tester.pumpWidget(_homeScreenApp(controllerFactory: factory));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('create-room-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final RoomController controller = built!;
    expect(connector.calls.length, 1);

    final List<Map<String, Object?>> sentBeforeReply = transport1.sentRaw
        .map(_decode)
        .toList();
    expect(sentBeforeReply, hasLength(1));
    final String createId = sentBeforeReply.single['id']! as String;
    transport1.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
      ),
    );
    transport1.pushText(_frame(type: 'room', re: createId, data: _roomJson()));
    await tester.pump();
    expect(controller.phase, RoomPhase.connected);

    transport1.endFromFarSide();
    await tester.pump();
    expect(controller.phase, RoomPhase.closed);
    expect(
      controller.autoReconnectPending,
      isTrue,
      reason:
          'fixture is broken: the drop must have armed the hour-long '
          'automatic timer before this test\'s inactive transition',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(
      connector.calls.length,
      1,
      reason:
          'C11: inactive must not call onAppResumed(); no new transport '
          'may be opened',
    );
    expect(
      controller.autoReconnectPending,
      isTrue,
      reason:
          'C11 control: an hour-long timer, untouched by an inactive '
          'transition, must still be pending',
    );

    // Resolve the timer inside the body rather than leaving it to
    // addTearDown (standing lesson): dispose cancels it outright.
    controller.dispose();
    await tester.pump();
  });
}

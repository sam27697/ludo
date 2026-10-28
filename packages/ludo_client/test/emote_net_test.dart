// Net proof for C-478 D4 and D6 item 7 (order 481): RoomConnection.emote,
// RoomController.sendEmote and the rule that an `emote` frame never enters
// the game transcript. Written from work/ludo/orders/C-478-quick-chat.md and
// docs/PROTOCOL.md section 25 alone; the implementation (order 480) was
// being written in another tree and has not been read.
//
// The controller cases sit on the roll-tray harness (a real RoomController
// over FakeTransport, every reply a decoded wire frame); the connection
// cases open a RoomConnection on a bare FakeTransport. The request frame is
// read off the transport's sent frames, and the server's copy is injected
// with `re` set to that frame's `id`, as the wire does it.
//
// This file does not compile on a tree without RoomConnection.emote and
// RoomController.sendEmote; that is the expected failing arm on the base.
//
// Every failure reason says what scenario was running and what the
// transport had seen, so a red case replays from its message.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/connection.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';

import 'net/fake_transport.dart';
import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const String _gameA = 'aaaaaaaaaaaaaaaa';

Future<RollTrayDrive> _open(
  WidgetTester tester, {
  List<Duration> delays = const <Duration>[],
}) => connectPlaying(
  tester,
  turn: awaitRollTurn(0),
  seats: pairSeats(mySeat: 0),
  autoReconnectDelays: delays,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// The emote request this client has sent since [from], exactly one.
Map<String, Object?> _theRequest(RollTrayDrive d, int from, String scenario) {
  final List<Map<String, Object?>> sent = emotesSince(d.transport, from);
  expect(
    sent,
    hasLength(1),
    reason:
        '$scenario: expected exactly one emote frame sent, got $sent; '
        'frames sent: ${sentTypesSince(d.transport, from)}',
  );
  return sent.single;
}

/// A result slot for a future bool that may never complete.
class _Slot {
  _Slot(Future<bool> future) {
    future.then(
      (bool v) {
        value = v;
      },
      onError: (Object e) {
        error = e;
      },
    );
  }

  bool? value;
  Object? error;
}

void main() {
  // -------------------------------------------------------------------
  // The request frame and a successful send.
  // -------------------------------------------------------------------
  testWidgets('7. sendEmote sends one emote frame {"emote": id} and returns '
      'true on the server\'s copy', (tester) async {
    final RollTrayDrive d = await _open(tester);
    try {
      final int from = d.transport.sentRaw.length;
      final _Slot slot = _Slot(d.controller.sendEmote('good_luck'));
      await _settle(tester);
      final Map<String, Object?> request = _theRequest(d, from, 'send');
      expect(request['v'], 1, reason: 'send: protocol version 1');
      expect(request['t'], 'emote', reason: 'send: t is emote');
      expect(request['d'], <String, Object?>{
        'emote': 'good_luck',
      }, reason: 'send: d is exactly {"emote": "good_luck"}, no other key');
      expect(request['id'], isA<String>(), reason: 'send: carries an id');
      expect(
        request.containsKey('re'),
        isFalse,
        reason: 'send: a request has no re',
      );
      expect(slot.value, isNull, reason: 'send: still waiting for the copy');
      await pushRaw(
        tester,
        d,
        emoteFrame(seat: 0, emote: 'good_luck', re: request['id']! as String),
      );
      expect(
        slot.value,
        isTrue,
        reason: 'send: true once the copy with re arrived',
      );
      expect(d.controller.phase, RoomPhase.connected);
      expect(sentTypesSince(d.transport, from), <String>[
        'emote',
      ], reason: 'send: nothing but the one request went out');
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. every one of the twelve ids goes out as sent', (
    tester,
  ) async {
    final RollTrayDrive d = await _open(tester);
    try {
      for (final String id in const <String>[
        'hi',
        'good_luck',
        'your_move',
        'nice',
        'lucky',
        'oops',
        'ha_ha',
        'revenge',
        'coming',
        'back_home',
        'no_way',
        'good_game',
      ]) {
        final int from = d.transport.sentRaw.length;
        final _Slot slot = _Slot(d.controller.sendEmote(id));
        await _settle(tester);
        final Map<String, Object?> request = _theRequest(d, from, 'id $id');
        expect(request['d'], <String, Object?>{
          'emote': id,
        }, reason: 'id $id on the wire');
        await pushRaw(
          tester,
          d,
          emoteFrame(seat: 0, emote: id, re: request['id']! as String),
        );
        expect(slot.value, isTrue, reason: 'id $id: true on its copy');
      }
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. the future waits for the copy with the right re: another '
      'seat\'s emote, a stale re and an unrelated error do not settle it', (
    tester,
  ) async {
    final RollTrayDrive d = await _open(tester);
    try {
      final int from = d.transport.sentRaw.length;
      final _Slot slot = _Slot(d.controller.sendEmote('nice'));
      await _settle(tester);
      final String id = _theRequest(d, from, 'wait')['id']! as String;
      await pushRaw(tester, d, emoteFrame(seat: 2, emote: 'nice'));
      expect(
        slot.value,
        isNull,
        reason: 'wait: another seat\'s emote (no re) does not settle it',
      );
      await pushRaw(
        tester,
        d,
        emoteFrame(seat: 0, emote: 'nice', re: 'some-other-request-id'),
      );
      expect(
        slot.value,
        isNull,
        reason: 'wait: a copy answering another id does not settle it',
      );
      await pushRaw(
        tester,
        d,
        errorReplyFrame(re: 'some-other-request-id', code: 'RATE_LIMITED'),
      );
      expect(
        slot.value,
        isNull,
        reason: 'wait: an error for another id does not settle it',
      );
      await pushRaw(tester, d, emoteFrame(seat: 0, emote: 'nice', re: id));
      expect(
        slot.value,
        isTrue,
        reason: 'wait: the copy answering $id settles it',
      );
      expect(slot.error, isNull);
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. a copy replayed after the future settled changes nothing', (
    tester,
  ) async {
    final RollTrayDrive d = await _open(tester);
    try {
      final int from = d.transport.sentRaw.length;
      final _Slot slot = _Slot(d.controller.sendEmote('oops'));
      await _settle(tester);
      final String id = _theRequest(d, from, 'replay')['id']! as String;
      final String copy = emoteFrame(seat: 0, emote: 'oops', re: id);
      await pushRaw(tester, d, copy);
      await pushRaw(tester, d, copy);
      expect(
        slot.value,
        isTrue,
        reason: 'replay: true, and no error from the second copy',
      );
      expect(slot.error, isNull);
      expect(d.controller.phase, RoomPhase.connected);
      expect(sentTypesSince(d.transport, from), <String>[
        'emote',
      ], reason: 'replay: a replayed copy starts no resume');
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. two sends in flight are each settled by their own reply', (
    tester,
  ) async {
    final RollTrayDrive d = await _open(tester);
    try {
      final int from = d.transport.sentRaw.length;
      final _Slot first = _Slot(d.controller.sendEmote('hi'));
      final _Slot second = _Slot(d.controller.sendEmote('nice'));
      await _settle(tester);
      final List<Map<String, Object?>> sent = emotesSince(d.transport, from);
      expect(sent, hasLength(2), reason: 'two: both requests went out: $sent');
      expect(sent[0]['d'], <String, Object?>{'emote': 'hi'});
      expect(sent[1]['d'], <String, Object?>{'emote': 'nice'});
      await pushRaw(
        tester,
        d,
        emoteFrame(seat: 0, emote: 'nice', re: sent[1]['id']! as String),
      );
      expect(
        second.value,
        isTrue,
        reason: 'two: the second is true on its copy',
      );
      expect(first.value, isNull, reason: 'two: the first is still waiting');
      await pushRaw(
        tester,
        d,
        errorReplyFrame(re: sent[0]['id']! as String, code: 'RATE_LIMITED'),
      );
      expect(
        first.value,
        isFalse,
        reason: 'two: the first is false on its error',
      );
      expect(d.controller.phase, RoomPhase.connected);
    } finally {
      await releaseGame(tester, d);
    }
  });

  // -------------------------------------------------------------------
  // Refusals: false, silently, and the controller does not move.
  // -------------------------------------------------------------------
  for (final String code in const <String>[
    'RATE_LIMITED',
    'WRONG_PHASE',
    'BAD_FIELD',
    'GAME_OVER',
    'BAD_SEAT_TOKEN',
    'NO_SUCH_ROOM',
    'SOME_CODE_FROM_A_NEWER_SERVER',
  ]) {
    testWidgets('7. an $code reply: false, still connected, no resume, not '
        'blocked, no error recorded', (tester) async {
      final RollTrayDrive d = await _open(
        tester,
        delays: const <Duration>[Duration(milliseconds: 100)],
      );
      try {
        final int seq = d.controller.room!.seq;
        final int from = d.transport.sentRaw.length;
        final _Slot slot = _Slot(d.controller.sendEmote('revenge'));
        await _settle(tester);
        final String id = _theRequest(d, from, code)['id']! as String;
        await pushRaw(tester, d, errorReplyFrame(re: id, code: code));
        await tester.pump(const Duration(milliseconds: 50));
        final String where =
            '$code: frames sent ${sentTypesSince(d.transport, from)}, phase '
            '${d.controller.phase}, errorCode ${d.controller.errorCode}';
        expect(slot.value, isFalse, reason: '$where: sendEmote returns false');
        expect(slot.error, isNull, reason: '$where: and does not throw');
        expect(
          d.controller.phase,
          RoomPhase.connected,
          reason: '$where: still connected',
        );
        expect(
          d.controller.errorCode,
          isNull,
          reason: '$where: no error code recorded',
        );
        expect(
          d.controller.errorMessage,
          isNull,
          reason: '$where: no error message recorded',
        );
        expect(
          sentTypesSince(d.transport, from),
          <String>['emote'],
          reason:
              '$where: it sent no resume, no leave, nothing after the request',
        );
        expect(d.controller.hasDesynced, isFalse, reason: where);
        expect(
          d.controller.room!.seq,
          seq,
          reason: '$where: the room did not move',
        );
        expect(
          d.controller.autoReconnectPending,
          isFalse,
          reason: '$where: no reconnect scheduled',
        );
        expect(
          d.transport.isClosed,
          isFalse,
          reason: '$where: the socket stays open',
        );

        // Not blocked: a later real drop is still eligible for the
        // automatic reconnect.
        d.transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(
          d.controller.autoReconnectPending,
          isTrue,
          reason:
              '$where: after the refusal a dropped socket still schedules '
              'the automatic reconnect (the controller was not blocked)',
        );
      } finally {
        await releaseGame(tester, d);
      }
    });
  }

  testWidgets('7. after a refusal the next send still works', (tester) async {
    final RollTrayDrive d = await _open(tester);
    try {
      int from = d.transport.sentRaw.length;
      final _Slot refused = _Slot(d.controller.sendEmote('hi'));
      await _settle(tester);
      await pushRaw(
        tester,
        d,
        errorReplyFrame(
          re: _theRequest(d, from, 'again 1')['id']! as String,
          code: 'RATE_LIMITED',
        ),
      );
      expect(refused.value, isFalse);
      from = d.transport.sentRaw.length;
      final _Slot ok = _Slot(d.controller.sendEmote('hi'));
      await _settle(tester);
      final String id = _theRequest(d, from, 'again 2')['id']! as String;
      await pushRaw(tester, d, emoteFrame(seat: 0, emote: 'hi', re: id));
      expect(ok.value, isTrue, reason: 'the second send is answered normally');
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. a roll and a move still work after a refused emote', (
    tester,
  ) async {
    final RollTrayDrive d = await _open(tester);
    try {
      final int from = d.transport.sentRaw.length;
      final _Slot slot = _Slot(d.controller.sendEmote('hi'));
      await _settle(tester);
      await pushRaw(
        tester,
        d,
        errorReplyFrame(
          re: _theRequest(d, from, 'roll after')['id']! as String,
          code: 'RATE_LIMITED',
        ),
      );
      expect(slot.value, isFalse);
      final int beforeRoll = d.transport.sentRaw.length;
      unawaited(d.controller.roll());
      await _settle(tester);
      expect(
        sentTypesSince(d.transport, beforeRoll),
        <String>['roll'],
        reason: 'a refused emote does not leave the controller unable to roll',
      );
    } finally {
      await releaseGame(tester, d);
    }
  });

  // -------------------------------------------------------------------
  // Not connected, disposed, timeout, closed.
  // -------------------------------------------------------------------
  test('7. a controller that never connected returns false and sends '
      'nothing', () async {
    int connects = 0;
    final RoomController controller = RoomController(
      serverUrl: Uri.parse('wss://emote-net.invalid/ws'),
      connect: (Uri url) async {
        connects += 1;
        throw StateError('no network in this test');
      },
    );
    addTearDown(controller.dispose);
    expect(await controller.sendEmote('hi'), isFalse);
    expect(
      controller.phase,
      RoomPhase.idle,
      reason: 'sendEmote does not open a connection',
    );
    expect(connects, 0, reason: 'sendEmote never connects');
  });

  test('7. a controller whose connect failed returns false and stays '
      'failed', () async {
    final RoomController controller = RoomController(
      serverUrl: Uri.parse('wss://emote-net.invalid/ws'),
      connect: (Uri url) async => throw StateError('refused'),
    );
    addTearDown(controller.dispose);
    await controller.createRoom(name: 'Sam', players: 2);
    expect(
      controller.phase,
      RoomPhase.failed,
      reason: 'fixture: connect failed',
    );
    final String? code = controller.errorCode;
    expect(await controller.sendEmote('hi'), isFalse);
    expect(controller.phase, RoomPhase.failed);
    expect(
      controller.errorCode,
      code,
      reason: 'the recorded error is untouched',
    );
  });

  testWidgets('7. after the socket closed: false, nothing sent, phase stays '
      'closed', (tester) async {
    final RollTrayDrive d = await _open(tester);
    try {
      d.transport.endFromFarSide();
      await _settle(tester);
      expect(
        d.controller.phase,
        RoomPhase.closed,
        reason: 'fixture: the drop was noticed',
      );
      final int from = d.transport.sentRaw.length;
      final _Slot slot = _Slot(d.controller.sendEmote('hi'));
      await _settle(tester);
      expect(slot.value, isFalse, reason: 'closed: false');
      expect(slot.error, isNull);
      expect(d.transport.sentRaw.length, from, reason: 'closed: nothing sent');
      expect(d.controller.phase, RoomPhase.closed);
      expect(d.controller.errorCode, isNull);
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. the socket closing while the request waits: false, no '
      'throw, no failed phase', (tester) async {
    final RollTrayDrive d = await _open(tester);
    try {
      final int from = d.transport.sentRaw.length;
      final _Slot slot = _Slot(d.controller.sendEmote('hi'));
      await _settle(tester);
      _theRequest(d, from, 'closed mid flight');
      d.transport.endFromFarSide();
      await _settle(tester);
      expect(slot.value, isFalse, reason: 'mid-flight close: false');
      expect(slot.error, isNull, reason: 'mid-flight close: no throw');
      expect(
        d.controller.phase,
        isNot(RoomPhase.failed),
        reason:
            'mid-flight close: the emote failure path is not the roll/move one',
      );
      expect(
        d.controller.errorCode,
        isNull,
        reason: 'mid-flight close: no error code set by the emote',
      );
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. no reply in the request timeout: false, still connected, '
      'no reconnect, no resume; a late copy is harmless', (tester) async {
    final RollTrayDrive d = await _open(
      tester,
      delays: const <Duration>[Duration(milliseconds: 100)],
    );
    try {
      final int from = d.transport.sentRaw.length;
      final _Slot slot = _Slot(d.controller.sendEmote('hi'));
      await _settle(tester);
      final String id = _theRequest(d, from, 'timeout')['id']! as String;
      await tester.pump(const Duration(seconds: 5));
      expect(slot.value, isNull, reason: 'timeout: not settled at 5 s');
      await tester.pump(const Duration(seconds: 6));
      final String where =
          'timeout: phase ${d.controller.phase}, errorCode '
          '${d.controller.errorCode}, sent ${sentTypesSince(d.transport, from)}';
      expect(
        slot.value,
        isFalse,
        reason: '$where: false once the request timed out',
      );
      expect(slot.error, isNull, reason: where);
      expect(d.controller.phase, RoomPhase.connected, reason: where);
      expect(d.controller.errorCode, isNull, reason: where);
      expect(d.controller.autoReconnectPending, isFalse, reason: where);
      expect(sentTypesSince(d.transport, from), <String>[
        'emote',
      ], reason: where);
      await pushRaw(tester, d, emoteFrame(seat: 0, emote: 'hi', re: id));
      expect(
        slot.value,
        isFalse,
        reason: '$where: a late copy does not flip the result',
      );
      expect(d.controller.phase, RoomPhase.connected);
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. disposed while the request waits: false, no throw', (
    tester,
  ) async {
    final RollTrayDrive d = await _open(tester);
    final int from = d.transport.sentRaw.length;
    final _Slot slot = _Slot(d.controller.sendEmote('hi'));
    await _settle(tester);
    _theRequest(d, from, 'disposed mid flight');
    await tester.pumpWidget(const SizedBox.shrink());
    d.controller.dispose();
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    expect(slot.value, isFalse, reason: 'disposed mid-flight: false');
    expect(slot.error, isNull, reason: 'disposed mid-flight: no throw');
  });

  testWidgets('7. after dispose: false, nothing sent, no throw', (
    tester,
  ) async {
    final RollTrayDrive d = await _open(tester);
    final int from = d.transport.sentRaw.length;
    d.controller.dispose();
    final _Slot slot = _Slot(d.controller.sendEmote('hi'));
    await _settle(tester);
    expect(slot.value, isFalse, reason: 'disposed: false');
    expect(slot.error, isNull, reason: 'disposed: no throw');
    expect(
      emotesSince(d.transport, from),
      isEmpty,
      reason: 'disposed: no emote frame went out',
    );
  });

  // -------------------------------------------------------------------
  // The transcript and the frames stream.
  // -------------------------------------------------------------------
  Future<void> openTranscript(WidgetTester tester, RollTrayDrive d) async {
    await d.push(tester, 'game_started', <String, Object?>{
      'turn': 0,
      'game_id': _gameA,
      'client_seeds': '0:seed',
    });
    await d.push(tester, 'turn', <String, Object?>{
      'seat': 0,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
    });
  }

  List<String> types(RoomController c) => <String>[
    for (final Frame f in c.gameTranscript) f.type,
  ];

  testWidgets('7. emote frames reach frames but never enter the transcript, '
      'whatever their re', (tester) async {
    final RollTrayDrive d = await _open(tester);
    try {
      final List<Frame> seen = <Frame>[];
      final StreamSubscription<Frame> sub = d.controller.frames.listen(
        seen.add,
      );
      addTearDown(sub.cancel);
      await openTranscript(tester, d);
      expect(types(d.controller), <String>[
        'game_started',
        'turn',
      ], reason: 'fixture: transcript is open');

      // 1. another seat's emote, no re.
      await pushRaw(tester, d, emoteFrame(seat: 2, emote: 'hi'));
      // 2. my own copy, re set to a live request.
      final int from = d.transport.sentRaw.length;
      final _Slot slot = _Slot(d.controller.sendEmote('nice'));
      await _settle(tester);
      final String id = _theRequest(d, from, 'transcript')['id']! as String;
      await pushRaw(tester, d, emoteFrame(seat: 0, emote: 'nice', re: id));
      expect(slot.value, isTrue, reason: 'fixture: the send settled');
      // 3. an emote with a re that matches nothing.
      await pushRaw(
        tester,
        d,
        emoteFrame(seat: 2, emote: 'oops', re: 'nobody-asked-this'),
      );
      // 4. an emote this client cannot read.
      await pushRaw(tester, d, emoteFrame(seat: 9, emote: 'not-a-preset'));

      final List<Frame> emotes = seen
          .where((Frame f) => f.type == 'emote')
          .toList();
      expect(
        emotes,
        hasLength(4),
        reason:
            'frames saw all four emote pushes: ${seen.map((Frame f) => f.type).toList()}',
      );
      expect(emotes[0].data, <String, Object?>{'seat': 2, 'emote': 'hi'});
      expect(emotes[0].re, isNull);
      expect(emotes[1].re, id, reason: 'frames keeps the re of my own copy');
      expect(types(d.controller), <String>[
        'game_started',
        'turn',
      ], reason: 'no emote in the transcript: ${types(d.controller)}');

      // The transcript is still alive: the next real frame lands after it.
      await d.push(tester, 'turn', <String, Object?>{
        'seat': 2,
        'phase': 'await_roll',
        'deadline_ms': rollTrayDeadlineMs,
      });
      expect(types(d.controller), <String>[
        'game_started',
        'turn',
        'turn',
      ], reason: 'a real frame after the emotes is appended normally');
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. an emote before any game_started leaves the transcript '
      'empty', (tester) async {
    final RollTrayDrive d = await _open(tester);
    try {
      await pushRaw(tester, d, emoteFrame(seat: 2, emote: 'hi'));
      expect(d.controller.gameTranscript, isEmpty);
      await openTranscript(tester, d);
      expect(types(d.controller), <String>['game_started', 'turn']);
    } finally {
      await releaseGame(tester, d);
    }
  });

  testWidgets('7. an emote carries no seq: it starts no resync and does not '
      'move the room', (tester) async {
    final RollTrayDrive d = await _open(tester);
    try {
      final int seq = d.controller.room!.seq;
      final int from = d.transport.sentRaw.length;
      for (int i = 0; i < 5; i++) {
        await pushRaw(tester, d, emoteFrame(seat: 2, emote: 'hi'));
      }
      expect(d.controller.room!.seq, seq, reason: 'five emotes, same room seq');
      expect(
        sentTypesSince(d.transport, from),
        isEmpty,
        reason: 'five emotes sent nothing (no resume)',
      );
      expect(d.controller.hasDesynced, isFalse);
      await d.push(tester, 'turn', <String, Object?>{
        'seat': 2,
        'phase': 'await_roll',
        'deadline_ms': rollTrayDeadlineMs,
      });
      expect(
        d.controller.room!.turn!.seat,
        2,
        reason: 'the next state frame applies in order',
      );
      expect(
        sentTypesSince(d.transport, from),
        isEmpty,
        reason: 'and starts no resume',
      );
    } finally {
      await releaseGame(tester, d);
    }
  });

  // -------------------------------------------------------------------
  // RoomConnection.emote.
  // -------------------------------------------------------------------
  Future<(RoomConnection, FakeTransport)> openConnection({
    Duration requestTimeout = const Duration(seconds: 10),
  }) async {
    final FakeTransport transport = FakeTransport();
    final RoomConnection connection = RoomConnection(
      url: Uri.parse('wss://emote-net.invalid/ws'),
      connect: (Uri url) async => transport,
      requestTimeout: requestTimeout,
    );
    await connection.open();
    addTearDown(connection.close);
    return (connection, transport);
  }

  group('RoomConnection.emote', () {
    test(
      'requests emote {"emote": id} and returns the sender\'s copy',
      () async {
        final (RoomConnection connection, FakeTransport transport) =
            await openConnection();
        final Future<Frame> reply = connection.emote('your_move');
        await pumpEventQueue();
        expect(transport.sentRaw, hasLength(1));
        expect(frameType(transport.sentRaw.single), 'emote');
        expect(frameData(transport.sentRaw.single), <String, Object?>{
          'emote': 'your_move',
        });
        final String id = requestIdOf(transport.sentRaw.single);
        transport.pushText(emoteFrame(seat: 1, emote: 'your_move', re: id));
        final Frame copy = await reply;
        expect(copy.type, 'emote');
        expect(copy.re, id, reason: 'the copy answers the request');
        expect(copy.data, <String, Object?>{'seat': 1, 'emote': 'your_move'});
      },
    );

    test(
      'an error reply throws ProtocolErrorException with the code',
      () async {
        final (RoomConnection connection, FakeTransport transport) =
            await openConnection();
        final Future<Frame> reply = connection.emote('hi');
        final Future<void> outcome = expectLater(
          reply,
          throwsA(
            isA<ProtocolErrorException>().having(
              (ProtocolErrorException e) => e.code,
              'code',
              'RATE_LIMITED',
            ),
          ),
        );
        await pumpEventQueue();
        transport.pushText(
          errorReplyFrame(
            re: requestIdOf(transport.sentRaw.single),
            code: 'RATE_LIMITED',
          ),
        );
        await outcome;
      },
    );

    test('a closed link throws ConnectionClosedException', () async {
      final (RoomConnection connection, FakeTransport transport) =
          await openConnection();
      final Future<Frame> reply = connection.emote('hi');
      final Future<void> outcome = expectLater(
        reply,
        throwsA(isA<ConnectionClosedException>()),
      );
      await pumpEventQueue();
      transport.endFromFarSide();
      await outcome;
    });

    test('another seat\'s emote (no re) does not answer the request and is '
        'still delivered on frames', () async {
      final (RoomConnection connection, FakeTransport transport) =
          await openConnection();
      final List<Frame> frames = <Frame>[];
      connection.frames.listen(frames.add);
      bool done = false;
      final Future<Frame> reply = connection.emote('hi');
      unawaited(reply.then((Frame _) => done = true, onError: (Object _) {}));
      await pumpEventQueue();
      transport.pushText(emoteFrame(seat: 1, emote: 'oops'));
      await pumpEventQueue();
      expect(done, isFalse, reason: 'a push without re is not the answer');
      expect(frames.map((Frame f) => f.type), <String>['emote']);
      transport.pushText(
        emoteFrame(
          seat: 0,
          emote: 'hi',
          re: requestIdOf(transport.sentRaw.single),
        ),
      );
      await reply;
      expect(done, isTrue);
    });

    test('no reply within requestTimeout throws RequestTimeoutException', () {
      fakeAsync((FakeAsync async) {
        final FakeTransport transport = FakeTransport();
        final RoomConnection connection = RoomConnection(
          url: Uri.parse('wss://emote-net.invalid/ws'),
          connect: (Uri url) async => transport,
          requestTimeout: const Duration(milliseconds: 30),
        );
        Object? error;
        connection.open().then((_) {
          connection
              .emote('hi')
              .then(
                (Frame _) {},
                onError: (Object e) {
                  error = e;
                },
              );
        });
        async.flushMicrotasks();
        expect(transport.sentRaw, hasLength(1), reason: 'the request went out');
        async.elapse(const Duration(milliseconds: 29));
        expect(error, isNull, reason: 'not timed out at 29 ms');
        async.elapse(const Duration(milliseconds: 2));
        expect(error, isA<RequestTimeoutException>());
        expect((error! as RequestTimeoutException).type, 'emote');
        connection.close();
        async.flushMicrotasks();
      });
    });
  });
}

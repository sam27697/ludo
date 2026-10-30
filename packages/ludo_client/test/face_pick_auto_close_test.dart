// Screen proof for the rest of C-462 D4: the conditions that close the face
// picker on its own and are not covered in test/token_face_pick_test.dart
// (a new k, another queue, a token left with one face). Written from the
// contract (work/ludo/orders/C-462, "When the picker closes on its own"),
// not from any implementation. GameScreen is driven through a real
// RoomController on FakeTransport; every room state arrives as a decoded wire
// frame and every `move` is read back off the transport.
//
// Every case opens the picker on token 2 first, drives the room into the
// condition with frames, then reads three things: the picker is gone, no
// `move` left, no `tap` cue played by the close.
//
// Shared fixture, unless a case says otherwise: seat 0's own turn, phase
// await_move, k 2, queue [6, 4], value 6, legal_by_face
// {6: [0, 2], 4: [1, 2]}, seat 0 tokens at progress [1, 3, 6, -1]. Token 2 is
// the one both faces can move, so a tap on it opens the picker.
//
// D4 also lists "the auto-move hold is armed". No case here: with the picker
// open that state has no sequence of frames that reaches it. The hold arms
// only on exactly one alive face with exactly one token, and a picker needs a
// token under two faces of the same legal_by_face, so every frame that arms
// the hold also drops the token to one face, which the one-face case in
// token_face_pick_test.dart already pins. A tap cancels a pending hold before
// it opens a picker, and nothing re-arms one on the same decision.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart' show kEndCardHoldLimit;
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

const String _fixtureText =
    'seat 0 awaitMove k 2 queue [6, 4] value 6 '
    'legal_by_face {6: [0, 2], 4: [1, 2]} seat 0 tokens [1, 3, 6, -1]';

const List<int> _mine = <int>[1, 3, 6, -1];

const Key _winnerKey = Key('game-screen-winner');

List<Map<String, Object?>> _bothFaces() => <Map<String, Object?>>[
  faceLegal(6, const <int>[0, 2]),
  faceLegal(4, const <int>[1, 2]),
];

Map<String, Object?> _pickTurn({
  int seat = 0,
  int k = 2,
  int value = 6,
  List<int> queue = const <int>[6, 4],
  List<Map<String, Object?>>? legalByFace,
}) {
  final List<Map<String, Object?>> byFace = legalByFace ?? _bothFaces();
  final List<int> legal = <int>[];
  for (final Map<String, Object?> entry in byFace) {
    if (entry['face'] == value) {
      legal.addAll((entry['tokens']! as List<Object?>).cast<int>());
    }
  }
  return turnJson(
    seat: seat,
    phase: 'await_move',
    k: k,
    value: value,
    legal: legal,
    queue: queue,
    legalByFace: byFace,
  );
}

/// The `turn` frame body that puts seat 0 back on the very decision the
/// fixture opens on: same queue, same value, same legal_by_face. A `turn`
/// frame carries no k, the controller keeps the one it holds.
Map<String, Object?> _sameDecisionTurn({int seat = 0}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_move',
  'deadline_ms': rollTrayDeadlineMs,
  'queue': <int>[6, 4],
  'value': 6,
  'legal': <int>[0, 2],
  'legal_by_face': _bothFaces(),
};

Future<RollTrayDrive> _mount(
  WidgetTester tester, {
  Map<String, Object?>? turn,
  List<int> mine = _mine,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn ?? _pickTurn(),
    seats: twoSeats(mine: mine),
  );
  await mountGame(tester, drive);
  return drive;
}

/// Pumps past the 140 ms open motion in bounded frames, never settling:
/// the legal rings and the countdown animate for ever.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

String _describe(RollTrayDrive drive) {
  final TurnState? turn = drive.controller.room?.turn;
  final SeatState? me = drive.controller.room?.seats
      .where((SeatState seat) => seat.seat == 0)
      .firstOrNull;
  if (turn == null) {
    return 'no turn';
  }
  final String byFace = turn.legalByFace == null
      ? 'absent'
      : '{${turn.legalByFace!.map((FaceLegal f) => '${f.face}: ${f.tokens}').join(', ')}}';
  return 'seat ${turn.seat} ${turn.phase.name} k ${turn.k} queue ${turn.queue} '
      'value ${turn.value} legal_by_face $byFace seat 0 tokens ${me?.tokens}';
}

/// Reads one scenario's wire and screen state. The marks are taken at
/// construction, after the mount, so the mount's own cues and frames do not
/// count. A reconnect adds a second transport through [adopt]; moves are
/// counted across every transport the scenario used.
class _Probe {
  _Probe(this.tester, this.drive, this.scenario)
    : fixture = _describe(drive),
      _cuesFrom = drive.feedback.recorded.length {
    _sentFrom[drive.transport] = drive.transport.sentRaw.length;
  }

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String scenario;

  /// The room as it stood when the scenario began, so a failure line is
  /// enough to rebuild the case.
  final String fixture;
  final Map<FakeTransport, int> _sentFrom = <FakeTransport, int>{};
  int _cuesFrom;

  /// Starts counting [transport] from its first frame.
  void adopt(FakeTransport transport) {
    _sentFrom[transport] = 0;
  }

  void remark() {
    for (final FakeTransport transport in _sentFrom.keys.toList()) {
      _sentFrom[transport] = transport.sentRaw.length;
    }
    _cuesFrom = drive.feedback.recorded.length;
  }

  List<Map<String, Object?>> get moves => <Map<String, Object?>>[
    for (final MapEntry<FakeTransport, int> mark in _sentFrom.entries)
      ...movesSince(mark.key, mark.value),
  ];

  List<FeedbackCue> get cues =>
      drive.feedback.recorded.skip(_cuesFrom).toList();

  int cueCount(FeedbackCue cue) =>
      cues.where((FeedbackCue c) => c == cue).length;

  bool get pickerOpen => tester.any(find.byKey(facePickerKey));

  String why(String expected) =>
      '$scenario: expected $expected; got picker open: $pickerOpen, '
      'options: ${pickerOptionFaces(tester)}, rings: ${ringedTokens(tester)}, '
      'moves sent: $moves, cues: $cues. Reproduce with $fixture';

  Future<void> tapToken(int token) async {
    await tester.tap(find.byKey(tokenHitKey(0, token)), warnIfMissed: false);
    await tester.pump();
    await _settle(tester);
  }

  /// Opens the picker on token 2 and starts the marks afresh.
  Future<void> openOnTokenTwo() async {
    await tapToken(2);
    expectPicker('picker open on token 2 before the frames that close it');
    remark();
  }

  void expectPicker(String expected) {
    expect(pickerOpen, isTrue, reason: why(expected));
  }

  void expectNoPicker(String expected) {
    expect(pickerOpen, isFalse, reason: why(expected));
    expect(pickerOptionFaces(tester), isEmpty, reason: why(expected));
  }

  /// The picker is gone, nothing was sent and the close played no `tap`.
  void expectClosedQuietly(String expected) {
    expectNoPicker(expected);
    expect(moves, isEmpty, reason: why('nothing sent by the close'));
    expect(cueCount(FeedbackCue.tap), 0, reason: why('no tap cue'));
  }
}

/// The far side vanishes: the controller leaves `connected` and the screen
/// shows the connection-lost card.
Future<void> _dropSocket(WidgetTester tester, RollTrayDrive drive) async {
  drive.transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
  expect(
    drive.controller.phase,
    anyOf(RoomPhase.closed, RoomPhase.failed),
    reason:
        'fixture is broken: the far side vanishing ends the link. '
        '$_fixtureText',
  );
}

/// A manual reconnect on a second socket, answered by a snapshot of the very
/// decision the fixture opens on (same k, queue and legal_by_face).
Future<void> _resume(
  WidgetTester tester,
  RollTrayDrive drive,
  _Probe probe,
) async {
  final FakeTransport second = FakeTransport();
  drive.enqueueTransport(second);
  probe.adopt(second);
  final Future<void> resumed = drive.controller.reconnect();
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final Iterable<String> resumes = second.sentRaw.where(
    (String text) => frameType(text) == 'resume',
  );
  expect(
    resumes,
    hasLength(1),
    reason: 'fixture is broken: reconnect sends one resume. $_fixtureText',
  );
  second.pushText(
    roomReplyFrame(
      re: requestIdOf(resumes.single),
      seats: twoSeats(mine: _mine),
      turn: _pickTurn(),
      seq: drive.lastSeq + 1,
    ),
  );
  await resumed;
  await tester.pump();
  await tester.pump();
  expect(
    drive.controller.phase,
    RoomPhase.connected,
    reason: 'fixture is broken: the resume succeeded. $_fixtureText',
  );
  expect(
    _describe(drive),
    _fixtureText,
    reason: 'fixture is broken: the snapshot is the same decision',
  );
}

void main() {
  group('D4: the picker closes on its own, quietly', () {
    testWidgets(
      'D4 the turn passes to another seat: a turn frame for the opponent '
      '(my clock ran out) closes it',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester);
        try {
          final _Probe p = _Probe(tester, drive, 'D4 turn to seat 1');
          await p.openOnTokenTwo();
          await drive.push(tester, 'turn', <String, Object?>{
            'seat': 1,
            'phase': 'await_roll',
            'deadline_ms': rollTrayDeadlineMs,
            'queue': <int>[],
          });
          expect(
            drive.controller.room!.turn!.seat,
            1,
            reason: 'fixture is broken: the turn is seat 1\'s. $_fixtureText',
          );
          await _settle(tester);
          p.expectClosedQuietly('picker closed once the turn is seat 1\'s');
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'D4 the turn passes to another seat: seat 1 on the very same k, queue '
      'and legal_by_face still closes it, and my return does not reopen it',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester);
        try {
          final _Probe p = _Probe(tester, drive, 'D4 seat only');
          await p.openOnTokenTwo();
          await drive.push(tester, 'turn', _sameDecisionTurn(seat: 1));
          expect(
            drive.controller.room!.turn!.seat,
            1,
            reason: 'fixture is broken: the turn is seat 1\'s. $_fixtureText',
          );
          expect(
            drive.controller.room!.turn!.k,
            2,
            reason: 'fixture is broken: a turn frame keeps k. $_fixtureText',
          );
          await _settle(tester);
          p.expectClosedQuietly('picker closed by the seat alone');

          await drive.push(tester, 'turn', _sameDecisionTurn());
          expect(
            _describe(drive),
            contains('seat 0 awaitMove k 2 queue [6, 4]'),
            reason: 'fixture is broken: back on my decision. $_fixtureText',
          );
          await _settle(tester);
          p.expectClosedQuietly(
            'the picker does not come back when my turn returns',
          );
          expect(ringedTokens(tester), <int>[
            0,
            1,
            2,
          ], reason: p.why('the rings are back, the picker is not'));

          await p.tapToken(2);
          p.expectPicker('a fresh tap on token 2 opens it again');
          expect(
            p.cueCount(FeedbackCue.tap),
            1,
            reason: p.why('one tap cue for the fresh open'),
          );
          expect(p.moves, isEmpty, reason: p.why('opening sends nothing'));
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'D4 the turn is mine but no longer awaitMove: a turn frame back to '
      'awaitRoll on the same k and queue closes it',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester);
        try {
          final _Probe p = _Probe(tester, drive, 'D4 awaitRoll only');
          await p.openOnTokenTwo();
          await drive.push(tester, 'turn', <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': rollTrayDeadlineMs,
            'queue': <int>[6, 4],
          });
          final TurnState turn = drive.controller.room!.turn!;
          expect(
            <Object?>[turn.seat, turn.phase, turn.k, turn.queue],
            <Object?>[
              0,
              TurnPhase.awaitRoll,
              2,
              <int>[6, 4],
            ],
            reason: 'fixture is broken: still my turn and k 2. $_fixtureText',
          );
          await _settle(tester);
          p.expectClosedQuietly('picker closed once the phase is awaitRoll');
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'D4 the turn is mine but no longer awaitMove: a spend that earns a '
      'roll (moved with extra_roll, then awaitRoll) closes it, and the '
      'decision coming back does not reopen it',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester);
        try {
          final _Probe p = _Probe(tester, drive, 'D4 earned roll');
          await p.openOnTokenTwo();
          await drive.push(tester, 'moved', <String, Object?>{
            'seat': 0,
            'token': 2,
            'from': 6,
            'to': 10,
            'captured': <Object?>[],
            'extra_roll': true,
            'face': 4,
          });
          await drive.push(tester, 'turn', <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': rollTrayDeadlineMs,
            'queue': <int>[6],
          });
          expect(
            drive.controller.room!.turn!.phase,
            TurnPhase.awaitRoll,
            reason: 'fixture is broken: my turn is awaiting a roll',
          );
          await _settle(tester);
          p.expectClosedQuietly('picker closed on my awaitRoll');

          await drive.push(tester, 'turn', <String, Object?>{
            'seat': 0,
            'phase': 'await_move',
            'deadline_ms': rollTrayDeadlineMs,
            'queue': <int>[6],
            'value': 6,
            'legal': <int>[0, 2],
            'legal_by_face': <Map<String, Object?>>[
              faceLegal(6, const <int>[0, 2]),
            ],
          });
          await _settle(tester);
          p.expectClosedQuietly('the picker does not return with the move');
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'D4 the game ends while it is open: the winning move and game_over '
      'hold the board, the picker is gone on the held board and stays gone '
      'on the end card',
      (tester) async {
        // Token 2 is one 6 from home, so the move that wins is the 6 of the
        // queue the picker is open on (the server plays it when my clock
        // runs out). Tokens 0, 1 and 3 are home already.
        final RollTrayDrive drive = await _mount(
          tester,
          mine: const <int>[57, 57, 51, 57],
          turn: _pickTurn(
            legalByFace: <Map<String, Object?>>[
              faceLegal(6, const <int>[2]),
              faceLegal(4, const <int>[2]),
            ],
          ),
        );
        try {
          final _Probe p = _Probe(tester, drive, 'D4 game over');
          await p.openOnTokenTwo();
          await drive.push(tester, 'moved', <String, Object?>{
            'seat': 0,
            'token': 2,
            'from': 51,
            'to': 57,
            'captured': <Object?>[],
            'extra_roll': false,
            'face': 6,
            'by': 'timer',
          });
          await drive.push(tester, 'game_over', <String, Object?>{
            'winner': 0,
            'verify_url': 'https://face-pick-auto-close.invalid/verify/1',
          });
          expect(
            drive.controller.room!.state,
            RoomState.finished,
            reason: 'fixture is broken: the room is FINISHED',
          );
          expect(
            find.byKey(bigDieKey),
            findsOneWidget,
            reason: p.why('the end hold keeps the playing board up'),
          );
          expect(
            find.byKey(_winnerKey),
            findsNothing,
            reason: p.why('no end card while the winning walk is held'),
          );
          p.expectClosedQuietly('picker gone on the held board');

          int waitedMs = 0;
          final int limitMs = kEndCardHoldLimit.inMilliseconds + 500;
          while (tester.any(find.byKey(_winnerKey)) == false &&
              waitedMs < limitMs) {
            await tester.pump(const Duration(milliseconds: 50));
            waitedMs += 50;
            expect(
              tester.any(find.byKey(facePickerKey)),
              isFalse,
              reason: p.why('no picker at any frame of the hold'),
            );
          }
          expect(
            find.byKey(_winnerKey),
            findsOneWidget,
            reason: p.why(
              'the end card within the hold limit plus 500 ms; waited '
              '${waitedMs}ms',
            ),
          );
          await _settle(tester);
          p.expectClosedQuietly('picker gone on the end card');
          expect(
            find.byKey(bigDieKey),
            findsNothing,
            reason: p.why('the playing board left with the hold'),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'D4 the game ends while it is open: a FINISHED room snapshot with no '
      'hold shows the end card with no picker',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester);
        try {
          final _Probe p = _Probe(tester, drive, 'D4 finished snapshot');
          await p.openOnTokenTwo();
          await drive.push(
            tester,
            'room',
            roomData(
              seats: twoSeats(mine: _mine),
              state: 'FINISHED',
              winner: 1,
            ),
          );
          expect(
            drive.controller.room!.state,
            RoomState.finished,
            reason: 'fixture is broken: the room is FINISHED',
          );
          await _settle(tester);
          expect(
            find.byKey(_winnerKey),
            findsOneWidget,
            reason: p.why('the end card shows at once, nothing is held'),
          );
          p.expectClosedQuietly('picker gone on the end card');
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'D4 the playing body leaves the screen: while the socket is down and '
      'the connection-lost card is up the picker is closed',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester);
        try {
          final _Probe p = _Probe(tester, drive, 'D4 socket down');
          await p.openOnTokenTwo();
          await _dropSocket(tester, drive);
          await _settle(tester);
          p.expectClosedQuietly(
            'picker closed while the connection-lost card is up',
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'D4 the playing body leaves the screen: a resume snapshot on the same '
      'k, queue and legal_by_face does not bring the picker back, and a '
      'fresh tap opens it',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester);
        try {
          final _Probe p = _Probe(tester, drive, 'D4 drop and resume');
          await p.openOnTokenTwo();
          await _dropSocket(tester, drive);
          await _resume(tester, drive, p);
          await _settle(tester);
          p.expectClosedQuietly('picker not back after the resume');
          expect(ringedTokens(tester), <int>[
            0,
            1,
            2,
          ], reason: p.why('the rings are back, the picker is not'));

          await p.tapToken(2);
          p.expectPicker('a fresh tap on token 2 opens it again');
          expect(
            p.cueCount(FeedbackCue.tap),
            1,
            reason: p.why('one tap cue for the fresh open'),
          );
          expect(p.moves, isEmpty, reason: p.why('opening sends nothing'));
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  });
}

// Screen proof for C-462: the face is picked on the token, the tray only
// records. Written from the contract (work/ludo/orders/C-462), not from
// any implementation. GameScreen is driven through a real RoomController on
// FakeTransport; every room state arrives as a decoded wire frame and every
// `move` is read back off the transport.
//
// Shared fixture, unless a case says otherwise: seat 0's own turn, phase
// await_move, k 2, queue [6, 4], value 6, legal_by_face
// {6: [0, 2], 4: [1, 2]}, seat 0 tokens at progress [1, 3, 6, -1].
//   token 0: legal for 6 only      token 1: legal for 4 only
//   token 2: legal for 6 and for 4 token 3: in the yard, legal for neither
// Tokens 0 and 1 sit below token 2 on the viewer's board, so a picker
// opened above token 2 never covers a token a case goes on to tap.

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board_geometry.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/snapshot.dart';

import 'support/roll_tray_harness.dart';

const String _fixtureText =
    'seat 0 awaitMove k 2 queue [6, 4] value 6 '
    'legal_by_face {6: [0, 2], 4: [1, 2]} seat 0 tokens [1, 3, 6, -1]';

const List<int> _mine = <int>[1, 3, 6, -1];

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

Future<RollTrayDrive> _mount(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  Map<String, Object?>? turn,
  List<int> mine = _mine,
  bool disableAnimations = false,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn ?? _pickTurn(),
    seats: twoSeats(mine: mine),
  );
  await mountGame(
    tester,
    drive,
    locale: locale,
    disableAnimations: disableAnimations,
  );
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
/// count.
class _Probe {
  _Probe(this.tester, this.drive, this.scenario)
    : fixture = _describe(drive),
      _sentFrom = drive.transport.sentRaw.length,
      _cuesFrom = drive.feedback.recorded.length;

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String scenario;

  /// The room as it stood when the scenario began, so a failure line is
  /// enough to rebuild the case.
  final String fixture;
  int _sentFrom;
  int _cuesFrom;

  void remark() {
    _sentFrom = drive.transport.sentRaw.length;
    _cuesFrom = drive.feedback.recorded.length;
  }

  List<Map<String, Object?>> get moves =>
      movesSince(drive.transport, _sentFrom);

  int get framesSent => drive.transport.sentRaw.length - _sentFrom;

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

  Future<void> tapOption(int face) async {
    expect(
      find.byKey(facePickerOptionKey(face)),
      findsOneWidget,
      reason: why('board-face-picker-option-$face on screen before the tap'),
    );
    await tester.tap(find.byKey(facePickerOptionKey(face)));
    await tester.pump();
    await _settle(tester);
  }

  void expectPicker(String expected) {
    expect(pickerOpen, isTrue, reason: why(expected));
  }

  void expectNoPicker(String expected) {
    expect(pickerOpen, isFalse, reason: why(expected));
    expect(pickerOptionFaces(tester), isEmpty, reason: why(expected));
  }

  void expectNoMove(String expected) {
    expect(moves, isEmpty, reason: why(expected));
  }

  void expectOneMove(int token, int face, String expected) {
    expect(moves, hasLength(1), reason: why(expected));
    expect(moves.single['token'], token, reason: why(expected));
    expect(moves.single['face'], face, reason: why(expected));
  }
}

/// The first progress of seat 0 whose cell on the viewer's rotated board
/// satisfies [test], leaving out the progresses other tokens already use.
int _progressWhere(bool Function(BoardCell viewCell) test) {
  final int quarters = viewQuarters(0);
  for (int progress = 0; progress < 52; progress++) {
    if (progress == _mine[0] || progress == _mine[1]) {
      continue;
    }
    final BoardCell view = toView(
      cellFor(seat: 0, progress: progress),
      quarters,
    );
    if (test(view)) {
      return progress;
    }
  }
  throw StateError('no progress of seat 0 satisfies the board-edge predicate');
}

void main() {
  testWidgets('D1: rings on every token any alive face can move, none on the '
      'token no face can move', (tester) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D1');
      expect(
        drive.controller.room!.turn!.legalByFace,
        hasLength(2),
        reason: 'fixture is broken: two alive faces. $_fixtureText',
      );
      expect(ringedTokens(tester), <int>[
        0,
        1,
        2,
      ], reason: p.why('rings on tokens 0, 1 and 2 (the union) and none on 3'));
      await _settle(tester);
      expect(ringedTokens(tester), <int>[
        0,
        1,
        2,
      ], reason: p.why('the union rings stay after the frames settle'));
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D1: the union holds whichever alive face is the default value', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(tester, turn: _pickTurn(value: 4));
    try {
      final _Probe p = _Probe(tester, drive, 'D1 value 4');
      expect(
        drive.controller.room!.turn!.value,
        4,
        reason: 'fixture is broken',
      );
      expect(ringedTokens(tester), <int>[
        0,
        1,
        2,
      ], reason: p.why('rings on 0, 1 and 2 with default face 4 as well'));
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'D2.1: a token only face 6 can move sends move face 6 at once and '
    'never opens a picker',
    (tester) async {
      final RollTrayDrive drive = await _mount(tester);
      try {
        final _Probe p = _Probe(tester, drive, 'D2.1 token 0');
        await p.tapToken(0);
        p.expectOneMove(0, 6, 'exactly one move: token 0, face 6');
        expect(p.framesSent, 1, reason: p.why('no frame other than the move'));
        p.expectNoPicker('no picker after a single-face token tap');
        expect(
          p.cueCount(FeedbackCue.tap),
          1,
          reason: p.why('the tap cue plays once when the move sends'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('D2.1: a token only face 4 can move sends move face 4 at once', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D2.1 token 1');
      await p.tapToken(1);
      p.expectOneMove(1, 4, 'exactly one move: token 1, face 4');
      expect(p.framesSent, 1, reason: p.why('no frame other than the move'));
      p.expectNoPicker('no picker after a single-face token tap');
    } finally {
      await releaseGame(tester, drive);
    }
  });

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    final String code = locale.languageCode;
    testWidgets(
      'D2.2 $code: a token two faces can move opens a picker with exactly '
      '6 and 4 in reading order and sends nothing',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester, locale: locale);
        try {
          final _Probe p = _Probe(tester, drive, 'D2.2 $code token 2');
          await p.tapToken(2);
          p.expectPicker('board-face-picker open on token 2');
          expect(pickerOptionFaces(tester)..sort(), <int>[
            4,
            6,
          ], reason: p.why('exactly the options for faces 6 and 4'));
          expect(
            find.descendant(
              of: find.byKey(facePickerKey),
              matching: find.byKey(facePickerOptionKey(6)),
            ),
            findsOneWidget,
            reason: p.why('option 6 inside the picker'),
          );
          expect(
            find.descendant(
              of: find.byKey(facePickerKey),
              matching: find.byKey(facePickerOptionKey(4)),
            ),
            findsOneWidget,
            reason: p.why('option 4 inside the picker'),
          );
          p.expectNoMove('nothing sent while the picker is open');
          expect(p.framesSent, 0, reason: p.why('no frame at all'));
          expect(
            p.cueCount(FeedbackCue.invalidTap),
            0,
            reason: p.why('no invalid_tap cue for a ringed token'),
          );
          final double six = tester
              .getCenter(find.byKey(facePickerOptionKey(6)))
              .dx;
          final double four = tester
              .getCenter(find.byKey(facePickerOptionKey(4)))
              .dx;
          if (code == 'ar') {
            expect(
              six,
              greaterThan(four),
              reason: p.why('ar reads right to left: 6 right of 4'),
            );
          } else {
            expect(
              six,
              lessThan(four),
              reason: p.why('en reads left to right: 6 left of 4'),
            );
          }
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets('D3: tapping option 4 sends one move token 2 face 4, closes the '
      'picker, and a second tap where it was sends nothing more', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D3');
      await p.tapToken(2);
      p.expectPicker('picker open on token 2 before the pick');
      final Offset where = tester.getCenter(find.byKey(facePickerOptionKey(4)));
      await p.tapOption(4);
      p.expectOneMove(2, 4, 'exactly one move: token 2, face 4');
      expect(p.framesSent, 1, reason: p.why('only the move left'));
      p.expectNoPicker('picker gone after the pick');
      expect(
        p.cueCount(FeedbackCue.invalidTap),
        0,
        reason: p.why('the pick does not leak an invalid_tap'),
      );

      await tester.tapAt(where);
      await tester.pump();
      await _settle(tester);
      expect(
        p.moves,
        hasLength(1),
        reason: p.why('a second tap where the option was sends nothing'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'D2 last face: after the 4 is spent the one face left moves token '
    '3 at once with no picker',
    (tester) async {
      final RollTrayDrive drive = await _mount(tester);
      try {
        final _Probe p = _Probe(tester, drive, 'D2 last face');
        await p.tapToken(2);
        await p.tapOption(4);
        p.expectOneMove(2, 4, 'the first spend: token 2, face 4');

        await drive.push(tester, 'moved', <String, Object?>{
          'seat': 0,
          'token': 2,
          'from': 6,
          'to': 10,
          'captured': <Object?>[],
          'extra_roll': false,
          'face': 4,
        });
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 0,
          'phase': 'await_move',
          'deadline_ms': rollTrayDeadlineMs,
          'queue': <int>[6],
          'value': 6,
          'legal': <int>[2, 3],
          'legal_by_face': <Map<String, Object?>>[
            faceLegal(6, const <int>[2, 3]),
          ],
        });
        expect(
          drive.controller.room!.turn!.k,
          2,
          reason: 'fixture is broken: a spend keeps k. $_fixtureText',
        );

        p.remark();
        await p.tapToken(3);
        p.expectOneMove(3, 6, 'token 3 takes the only face left, 6');
        expect(p.framesSent, 1, reason: p.why('only the move left'));
        p.expectNoPicker('no picker for the last face');
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2.3: tapping token 2 again closes its picker and sends nothing, '
    'no cue',
    (tester) async {
      final RollTrayDrive drive = await _mount(tester);
      try {
        final _Probe p = _Probe(tester, drive, 'D2.3');
        await p.tapToken(2);
        p.expectPicker('picker open after the first tap');
        p.remark();
        await p.tapToken(2);
        p.expectNoPicker('picker closed by the second tap on the same token');
        p.expectNoMove('nothing sent by closing');
        expect(p.framesSent, 0, reason: p.why('no frame at all'));
        expect(p.cues, isEmpty, reason: p.why('no cue on the close'));
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2.4: with the picker open on token 2, tapping token 0 closes it '
    'and sends token 0 face 6',
    (tester) async {
      final RollTrayDrive drive = await _mount(tester);
      try {
        final _Probe p = _Probe(tester, drive, 'D2.4');
        await p.tapToken(2);
        p.expectPicker('picker open on token 2');
        await p.tapToken(0);
        p.expectNoPicker('picker closed by the tap on another ringed token');
        p.expectOneMove(0, 6, 'one move: token 0, face 6');
        expect(p.framesSent, 1, reason: p.why('only the move left'));
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('D2.4: with the picker open on token 2, tapping token 1 sends '
      'token 1 face 4', (tester) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D2.4 token 1');
      await p.tapToken(2);
      p.expectPicker('picker open on token 2');
      await p.tapToken(1);
      p.expectNoPicker('picker closed by the tap on another ringed token');
      p.expectOneMove(1, 4, 'one move: token 1, face 4');
    } finally {
      await releaseGame(tester, drive);
    }
  });

  group('D4: the picker never survives into another turn', () {
    Future<_Probe> openOnTokenTwo(
      WidgetTester tester,
      RollTrayDrive drive,
      String scenario,
    ) async {
      final _Probe p = _Probe(tester, drive, scenario);
      await p.tapToken(2);
      p.expectPicker('picker open on token 2 before the new frame');
      p.remark();
      return p;
    }

    testWidgets('a room snapshot with a new k closes it, nothing sent', (
      tester,
    ) async {
      final RollTrayDrive drive = await _mount(tester);
      try {
        final _Probe p = await openOnTokenTwo(tester, drive, 'D4 new k');
        await drive.push(
          tester,
          'room',
          roomData(
            seats: twoSeats(mine: _mine),
            turn: _pickTurn(k: 3),
          ),
        );
        expect(
          drive.controller.room!.turn!.k,
          3,
          reason: 'fixture is broken: the snapshot carries k 3',
        );
        await _settle(tester);
        p.expectNoPicker('picker closed when turn.k changed 2 -> 3');
        p.expectNoMove('nothing sent by the close');
        expect(p.cueCount(FeedbackCue.tap), 0, reason: p.why('no tap cue'));
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('a turn frame with another queue closes it, nothing sent', (
      tester,
    ) async {
      final RollTrayDrive drive = await _mount(tester);
      try {
        final _Probe p = await openOnTokenTwo(tester, drive, 'D4 new queue');
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 0,
          'phase': 'await_move',
          'deadline_ms': rollTrayDeadlineMs,
          'queue': <int>[6, 4, 6],
          'value': 6,
          'legal': <int>[0, 2],
          'legal_by_face': _bothFaces(),
        });
        expect(drive.controller.room!.turn!.queue, <int>[
          6,
          4,
          6,
        ], reason: 'fixture is broken');
        await _settle(tester);
        p.expectNoPicker('picker closed when turn.queue changed');
        p.expectNoMove('nothing sent by the close');
        expect(p.cueCount(FeedbackCue.tap), 0, reason: p.why('no tap cue'));
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('a turn frame that leaves token 2 one face closes it, nothing '
        'sent', (tester) async {
      final RollTrayDrive drive = await _mount(tester);
      try {
        final _Probe p = await openOnTokenTwo(tester, drive, 'D4 one face');
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 0,
          'phase': 'await_move',
          'deadline_ms': rollTrayDeadlineMs,
          'queue': <int>[6, 4],
          'value': 6,
          'legal': <int>[0],
          'legal_by_face': <Map<String, Object?>>[
            faceLegal(6, const <int>[0]),
            faceLegal(4, const <int>[1, 2]),
          ],
        });
        await _settle(tester);
        p.expectNoPicker('picker closed: token 2 lists under one face only');
        p.expectNoMove('nothing sent by the close');
        expect(p.cueCount(FeedbackCue.tap), 0, reason: p.why('no tap cue'));
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets(
      'turn_passed and the next seat\'s turn close it, nothing sent',
      (tester) async {
        final RollTrayDrive drive = await _mount(tester);
        try {
          final _Probe p = await openOnTokenTwo(tester, drive, 'D4 next seat');
          await drive.push(tester, 'turn_passed', <String, Object?>{
            'seat': 0,
            'reason': 'no_legal_move',
          });
          await drive.push(tester, 'turn', <String, Object?>{
            'seat': 1,
            'phase': 'await_roll',
            'deadline_ms': rollTrayDeadlineMs,
            'queue': <int>[],
          });
          expect(
            drive.controller.room!.turn!.seat,
            1,
            reason: 'fixture is broken: the turn is seat 1\'s',
          );
          await _settle(tester);
          p.expectNoPicker('picker closed once the turn is not mine');
          p.expectNoMove('nothing sent by the close');
          expect(p.cueCount(FeedbackCue.tap), 0, reason: p.why('no tap cue'));
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  });

  testWidgets('a tap on a token that is not ringed closes the picker, sends '
      'nothing and plays invalid_tap', (tester) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'not ringed');
      await p.tapToken(2);
      p.expectPicker('picker open on token 2');
      p.remark();
      await p.tapToken(3);
      p.expectNoPicker('picker closed by a tap on the unringed token 3');
      p.expectNoMove('nothing sent for an unringed token');
      expect(
        p.cueCount(FeedbackCue.invalidTap),
        1,
        reason: p.why('one invalid_tap cue'),
      );
      expect(
        p.cueCount(FeedbackCue.tap),
        0,
        reason: p.why('no tap cue for a refused tap'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('feedback: tap plays once when the picker opens and once when '
      'the pick sends', (tester) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'feedback open and pick');
      await p.tapToken(2);
      p.expectPicker('picker open');
      expect(p.cues, <FeedbackCue>[
        FeedbackCue.tap,
      ], reason: p.why('exactly one tap cue on open'));
      await p.tapOption(6);
      p.expectOneMove(2, 6, 'the pick sends token 2 face 6');
      expect(p.cues, <FeedbackCue>[
        FeedbackCue.tap,
        FeedbackCue.tap,
      ], reason: p.why('one more tap cue on the pick that sends'));
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('feedback: the close of rule D2.3 plays no cue', (tester) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'feedback close');
      await p.tapToken(2);
      p.expectPicker('picker open');
      expect(p.cueCount(FeedbackCue.tap), 1, reason: p.why('one cue on open'));
      await p.tapToken(2);
      p.expectNoPicker('picker closed');
      expect(p.cues, <FeedbackCue>[
        FeedbackCue.tap,
      ], reason: p.why('still only the open cue after the close'));
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('feedback: a one-face token tap plays tap once, not twice', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'feedback single face');
      await p.tapToken(0);
      p.expectOneMove(0, 6, 'token 0 face 6');
      expect(p.cues, <FeedbackCue>[
        FeedbackCue.tap,
      ], reason: p.why('one tap cue for a move that sends at once'));
    } finally {
      await releaseGame(tester, drive);
    }
  });

  Future<RollTrayDrive> mountTray(WidgetTester tester) =>
      _mount(tester, turn: _pickTurn(queue: const <int>[6, 4, 2]));

  testWidgets('D6: tapping every tray tile sends nothing, plays no cue, moves '
      'no ring and opens no picker', (tester) async {
    final RollTrayDrive drive = await mountTray(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D6 tap tiles');
      for (int i = 0; i < 3; i++) {
        expect(
          find.byKey(trayDieKey(i)),
          findsOneWidget,
          reason: p.why('fixture: tray tile $i in the tree'),
        );
      }
      expect(
        find.byKey(trayDeadKey(2)),
        findsOneWidget,
        reason: p.why('fixture: the 2 is dead'),
      );
      expect(ringedTokens(tester), <int>[
        0,
        1,
        2,
      ], reason: p.why('rings are the union before any tray tap'));

      for (int i = 0; i < 3; i++) {
        await tester.tapAt(tester.getCenter(find.byKey(trayDieKey(i))));
        await tester.pump();
        await _settle(tester);
        p.expectNoMove('tray tile $i sends nothing');
        expect(p.framesSent, 0, reason: p.why('tray tile $i sends no frame'));
        expect(
          p.cues,
          isEmpty,
          reason: p.why('tray tile $i plays no cue, not even invalid_tap'),
        );
        p.expectNoPicker('tray tile $i opens no picker');
        expect(ringedTokens(tester), <int>[
          0,
          1,
          2,
        ], reason: p.why('tray tile $i leaves the rings alone'));
      }
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D6: no tray tile is a button or has a tap action', (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final RollTrayDrive drive = await mountTray(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D6 semantics');
      for (int i = 0; i < 3; i++) {
        final SemanticsNode node = tester.getSemantics(
          find.byKey(trayDieKey(i)),
        );
        expect(
          node.flagsCollection.isButton,
          isFalse,
          reason: p.why('tray tile $i (label "${node.label}") is not a button'),
        );
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isFalse,
          reason: p.why('tray tile $i (label "${node.label}") has no tap'),
        );
      }
    } finally {
      semantics.dispose();
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D6: game-roll-tray-selected-<i> exists in no state', (
    tester,
  ) async {
    final RollTrayDrive drive = await mountTray(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D6 no selected mark');
      void expectNoSelectedKey(String when) {
        for (int i = 0; i < 6; i++) {
          expect(
            find.byKey(traySelectedKey(i)),
            findsNothing,
            reason: p.why('no game-roll-tray-selected-$i $when'),
          );
        }
      }

      expectNoSelectedKey('on the first frame');
      await tester.tapAt(tester.getCenter(find.byKey(trayDieKey(1))));
      await tester.pump();
      expectNoSelectedKey('after tapping tile 1');
      await p.tapToken(2);
      expectNoSelectedKey('with the picker open');
      await p.tapOption(4);
      expectNoSelectedKey('after a pick');

      await drive.push(tester, 'moved', <String, Object?>{
        'seat': 0,
        'token': 2,
        'from': 6,
        'to': 10,
        'captured': <Object?>[],
        'extra_roll': false,
        'face': 4,
      });
      await drive.push(tester, 'turn', <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': rollTrayDeadlineMs,
        'queue': <int>[6, 2],
        'value': 6,
        'legal': <int>[0, 2],
        'legal_by_face': <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 2]),
        ],
      });
      expectNoSelectedKey('after the next turn frame');
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D7: under the queue the big die shows turn.value for my seat', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(tester, turn: _pickTurn(value: 4));
    try {
      final _Probe p = _Probe(tester, drive, 'D7 mine');
      expect(
        drive.controller.room!.turn!.value,
        4,
        reason: 'fixture is broken',
      );
      expect(
        find.byKey(bigFaceKey(4)),
        findsOneWidget,
        reason: p.why('game-die-face-4, the server\'s value'),
      );
      expect(
        find.byKey(bigFaceKey(6)),
        findsNothing,
        reason: p.why('not the first queued face 6'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D7: under the queue the opponent\'s turn.value shows on his '
      'seat die and never on my big die (C-465)', (tester) async {
    final RollTrayDrive drive = await _mount(
      tester,
      turn: _pickTurn(seat: 1, value: 4),
    );
    try {
      final _Probe p = _Probe(tester, drive, 'D7 opponent');
      expect(drive.controller.room!.turn!.seat, 1, reason: 'fixture is broken');
      // C-465 D1.2: the big die is mine, idle on another seat's turn.
      expect(
        find.byKey(bigFaceKey(4)),
        findsNothing,
        reason: p.why('the big die never shows seat 1\'s face 4'),
      );
      expect(
        find.byKey(bigFaceKey(6)),
        findsNothing,
        reason: p.why('not the first queued face 6 either'),
      );
      expect(
        find.byKey(const Key('game-die-idle-art')),
        findsOneWidget,
        reason: p.why('the big die is the idle art on another seat\'s turn'),
      );
      // C-465 D2: with no throw up, seat 1's die shows turn.value, not the
      // first queued face.
      expect(
        find.byKey(seatDieFaceKey(1, 4)),
        findsOneWidget,
        reason: p.why('board-seat-die-face-1-4, the server\'s value'),
      );
      expect(
        find.byKey(seatDieFaceKey(1, 6)),
        findsNothing,
        reason: p.why('not the first queued face 6'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D7: tapping a tray tile does not change the big die', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(tester, turn: _pickTurn(value: 4));
    try {
      final _Probe p = _Probe(tester, drive, 'D7 tray tap');
      await tester.tapAt(tester.getCenter(find.byKey(trayDieKey(0))));
      await tester.pump();
      expect(
        find.byKey(bigFaceKey(4)),
        findsOneWidget,
        reason: p.why('the big die keeps turn.value 4 after a tray tap'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  const Map<String, List<String>> words = <String, List<String>>{
    'en': <String>['Which roll for piece 3?', 'Play 6', 'Play 4'],
    'ar': <String>['أي رمية للقطعة 3؟', 'العب 6', 'العب 4'],
  };
  for (final MapEntry<String, List<String>> entry in words.entries) {
    testWidgets('D5 semantics ${entry.key}: one labelled container and two '
        'button options that send what a tap sends', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final RollTrayDrive drive = await _mount(
        tester,
        locale: Locale(entry.key),
      );
      try {
        final _Probe p = _Probe(tester, drive, 'D5 semantics ${entry.key}');
        await p.tapToken(2);
        p.expectPicker('picker open on token 2');

        final SemanticsNode bubble = tester.getSemantics(
          find.byKey(facePickerKey),
        );
        expect(
          bubble.label,
          entry.value[0],
          reason: p.why('bubble label "${entry.value[0]}"'),
        );
        for (final (int face, String label) in <(int, String)>[
          (6, entry.value[1]),
          (4, entry.value[2]),
        ]) {
          final SemanticsNode option = tester.getSemantics(
            find.byKey(facePickerOptionKey(face)),
          );
          expect(
            option.label,
            label,
            reason: p.why('option $face label "$label"'),
          );
          expect(
            option.flagsCollection.isButton,
            isTrue,
            reason: p.why('option $face is a button'),
          );
          expect(
            option.flagsCollection.isEnabled,
            isNot(Tristate.isFalse),
            reason: p.why('option $face is not disabled'),
          );
          expect(
            option.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
            reason: p.why('option $face has a tap action'),
          );
        }

        p.remark();
        tester.semantics.performAction(
          find.semantics.byLabel(entry.value[2]),
          SemanticsAction.tap,
        );
        await tester.pump();
        await _settle(tester);
        p.expectOneMove(2, 4, 'the tap action sends token 2 face 4');
        p.expectNoPicker('picker closed by the tap action');
      } finally {
        semantics.dispose();
        await releaseGame(tester, drive);
      }
    });
  }

  group('D5 place: the picker lies inside the board', () {
    final Map<String, bool Function(BoardCell)> spots =
        <String, bool Function(BoardCell)>{
          'top row': (BoardCell c) => c.row == 0,
          'left column': (BoardCell c) => c.col == 0,
          'right column': (BoardCell c) => c.col == 14,
          'middle': (BoardCell c) => c.col == 5 && c.row == 8,
        };
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      for (final MapEntry<String, bool Function(BoardCell)> spot
          in spots.entries) {
        final String code = locale.languageCode;
        testWidgets('${spot.key} $code', (tester) async {
          final SemanticsHandle semantics = tester.ensureSemantics();
          final int progress = _progressWhere(spot.value);
          final RollTrayDrive drive = await _mount(
            tester,
            locale: locale,
            mine: <int>[_mine[0], _mine[1], progress, -1],
          );
          try {
            final _Probe p = _Probe(
              tester,
              drive,
              'D5 place ${spot.key} $code, token 2 at progress $progress',
            );
            await p.tapToken(2);
            p.expectPicker('picker open on token 2');

            final Rect board = boardSquare(tester);
            final Rect picker = tester.getRect(find.byKey(facePickerKey));
            const double eps = 1e-3;
            expect(
              picker.left >= board.left - eps &&
                  picker.right <= board.right + eps &&
                  picker.top >= board.top - eps &&
                  picker.bottom <= board.bottom + eps,
              isTrue,
              reason: p.why(
                'picker rect $picker inside the board square $board',
              ),
            );

            final Offset token = tester.getCenter(
              find.byKey(tokenHitKey(0, 2)),
            );
            if (spot.key == 'top row') {
              expect(
                picker.center.dy,
                greaterThan(token.dy),
                reason: p.why(
                  'picker $picker sits below the top-row token at $token',
                ),
              );
            } else {
              expect(
                picker.center.dy,
                lessThan(token.dy),
                reason: p.why('picker $picker sits above the token at $token'),
              );
            }

            for (final int face in <int>[6, 4]) {
              final Rect hit = tester.getRect(
                find.byKey(facePickerOptionKey(face)),
              );
              expect(
                hit.width >= 48 - eps && hit.height >= 48 - eps,
                isTrue,
                reason: p.why(
                  'option $face hit rect ${hit.width}x${hit.height} '
                  'at least 48x48',
                ),
              );
            }
          } finally {
            semantics.dispose();
            await releaseGame(tester, drive);
          }
        });
      }
    }
  });

  testWidgets('D5 look: the picker draws no text and none of the form '
      'widgets', (tester) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D5 look');
      await p.tapToken(2);
      p.expectPicker('picker open on token 2');
      final Finder inside = find.descendant(
        of: find.byKey(facePickerKey),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Text ||
              w is RichText ||
              w is Dialog ||
              w is PopupMenuButton ||
              w is ElevatedButton ||
              w is TextButton ||
              w is Chip ||
              w is Card,
        ),
      );
      expect(
        inside.evaluate().map((Element e) => e.widget.runtimeType).toList(),
        isEmpty,
        reason: p.why(
          'no Text, Dialog, PopupMenu, ElevatedButton, TextButton, Chip or '
          'Card inside the picker',
        ),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D5 motion: the picker opens with a scale from the token over '
      '140 ms', (tester) async {
    final RollTrayDrive drive = await _mount(tester);
    try {
      final _Probe p = _Probe(tester, drive, 'D5 motion');
      await tester.tap(find.byKey(tokenHitKey(0, 2)), warnIfMissed: false);
      await tester.pump();
      p.expectPicker('picker in the tree on the frame of the tap');
      // The option sits inside the scale; the bubble's keyed root is laid
      // out above it and keeps its size. A ticker counts from its first
      // frame, so the motion is measured over bounded frames, not one pump.
      final Finder option = find.byKey(facePickerOptionKey(6));
      final Rect first = tester.getRect(option);
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final Rect last = tester.getRect(option);
      expect(
        first.width,
        lessThan(last.width - 0.5),
        reason: p.why(
          'option width ${first.width} on the opening frame is smaller than '
          '${last.width} after 12 frames (scale-and-fade from the token)',
        ),
      );
      expect(
        last.width,
        greaterThanOrEqualTo(48),
        reason: p.why('the option reaches full size, ${last.width}'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D5 motion: under disableAnimations the picker is at full size '
      'on the opening frame', (tester) async {
    final RollTrayDrive drive = await _mount(tester, disableAnimations: true);
    try {
      final _Probe p = _Probe(tester, drive, 'D5 motion disabled');
      await tester.tap(find.byKey(tokenHitKey(0, 2)), warnIfMissed: false);
      await tester.pump();
      p.expectPicker('picker in the tree on the frame of the tap');
      final Finder option = find.byKey(facePickerOptionKey(6));
      final Rect first = tester.getRect(option);
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final Rect last = tester.getRect(option);
      expect(
        first,
        last,
        reason: p.why(
          'picker rect $first on the opening frame equals $last later: '
          'instant when animations are disabled',
        ),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('without the queue a token tap sends move with no face key and '
      'no picker ever appears', (tester) async {
    final RollTrayDrive drive = await connectPlaying(
      tester,
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 2,
        value: 4,
        legal: const <int>[0, 1],
      ),
      seats: twoSeats(mine: _mine),
    );
    try {
      await mountGame(tester, drive);
      final _Probe p = _Probe(tester, drive, 'no queue');
      expect(
        drive.controller.room!.turn!.legalByFace,
        isNull,
        reason: 'fixture is broken: legal_by_face is absent',
      );
      expect(ringedTokens(tester), <int>[
        0,
        1,
      ], reason: p.why('rings from turn.legal'));
      await p.tapToken(0);
      expect(p.moves, hasLength(1), reason: p.why('one move for the tap'));
      expect(p.moves.single['token'], 0, reason: p.why('token 0'));
      expect(
        p.moves.single.containsKey('face'),
        isFalse,
        reason: p.why('no face key at all'),
      );
      p.expectNoPicker('no picker without the queue');
    } finally {
      await releaseGame(tester, drive);
    }
  });
}

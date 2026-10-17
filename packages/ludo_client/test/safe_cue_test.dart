// Order 384: acceptance tests for the board safe-landing pill (contract
// C-384, A1 to A10). When a move lands on a main-track square shared with an
// opponent token and captures nothing, the board shows why: either the square
// is a safe star square or the opponent holds a safe pair.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart'
    show GameScreen, kSafeCueFade, kSafeCueHold;

import 'support/roll_tray_harness.dart';

const Duration _frame = Duration(milliseconds: 16);
const Duration _margin = Duration(milliseconds: 100);

const Key _starKey = Key('board-safe-cue-star');
const Key _pairKey = Key('board-safe-cue-pair');

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

String _pillText(WidgetTester tester, Key key) {
  final Finder finder = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Text),
    matchRoot: true,
  );
  expect(
    finder,
    findsOneWidget,
    reason: 'expected one Text widget under pill $key',
  );
  final Text widget = tester.widget<Text>(finder);
  return widget.data ?? widget.textSpan?.toPlainText() ?? '';
}

Map<String, Object?> _moverTurn({
  required int seat,
  required int face,
  required List<int> legal,
  int k = 1,
}) => turnJson(
  seat: seat,
  phase: 'await_move',
  k: k,
  value: face,
  legal: legal,
  queue: <int>[face],
  legalByFace: <Map<String, Object?>>[faceLegal(face, legal)],
);

Future<void> _pushMovedAndNextTurn(
  WidgetTester tester,
  RollTrayDrive drive, {
  required int seat,
  required int token,
  required int from,
  required int to,
  required int face,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  bool extraRoll = false,
  int nextSeat = 1,
}) async {
  await drive.push(tester, 'moved', <String, Object?>{
    'seat': seat,
    'token': token,
    'from': from,
    'to': to,
    'captured': captured,
    'extra_roll': extraRoll,
    'face': face,
  });
  await drive.push(tester, 'turn', <String, Object?>{
    'seat': nextSeat,
    'phase': 'await_roll',
    'deadline_ms': rollTrayDeadlineMs,
    'queue': <int>[],
  });
}

Future<void> _pumpFor(
  WidgetTester tester,
  Duration total, {
  void Function()? onFrame,
}) async {
  Duration elapsed = Duration.zero;
  while (elapsed < total) {
    await tester.pump(_frame);
    elapsed += _frame;
    onFrame?.call();
  }
}

Duration _travelFor(int steps) => kTokenStepDuration * steps + _frame;

void _expectInsideBoard(WidgetTester tester, Key pillKey, String label) {
  final Rect boardRect = tester.getRect(
    find.byKey(const Key('game-screen-board')),
  );
  final Rect pillRect = tester.getRect(find.byKey(pillKey));
  expect(
    pillRect.left,
    greaterThanOrEqualTo(boardRect.left),
    reason:
        '$label: pill left (${pillRect.left}) must stay inside '
        'board left (${boardRect.left})',
  );
  expect(
    pillRect.top,
    greaterThanOrEqualTo(boardRect.top),
    reason:
        '$label: pill top (${pillRect.top}) must stay inside '
        'board top (${boardRect.top})',
  );
  expect(
    pillRect.right,
    lessThanOrEqualTo(boardRect.right),
    reason:
        '$label: pill right (${pillRect.right}) must stay inside '
        'board right (${boardRect.right})',
  );
  expect(
    pillRect.bottom,
    lessThanOrEqualTo(boardRect.bottom),
    reason:
        '$label: pill bottom (${pillRect.bottom}) must stay inside '
        'board bottom (${boardRect.bottom})',
  );
}

void main() {
  testWidgets(
    'A1: my token 0 moves 10 -> 16 onto seat 1 pair at progress 3, shows '
    'board-safe-cue-pair with boardSafePairCue, and removes it after hold '
    'plus fade',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[10, 20, -1, -1],
          other: const <int>[3, 3, -1, -1],
        ),
        turn: _moverTurn(seat: 0, face: 6, legal: const <int>[0, 1]),
      );
      try {
        await mountGame(tester, drive);
        expect(drive.controller.seat, 0, reason: 'fixture: my seat is 0');
        expect(
          drive.controller.room!.seats[0].tokens[0],
          10,
          reason: 'fixture: my token 0 starts at progress 10',
        );
        expect(
          drive.controller.room!.seats[1].tokens.sublist(0, 2),
          const <int>[3, 3],
          reason: 'fixture: seat 1 holds two tokens at progress 3',
        );
        expect(
          cellFor(seat: 0, progress: 16),
          cellFor(seat: 1, progress: 3),
          reason:
              'fixture: seat 0 progress 16 and seat 1 progress 3 are both '
              'absolute square 16',
        );
        expect(
          safeTrackSquares.contains(16),
          isFalse,
          reason: 'fixture: absolute square 16 is not a safe square',
        );
        expect(
          find.byKey(_pairKey),
          findsNothing,
          reason: 'fixture: no pair pill before the move',
        );
        expect(
          find.byKey(_starKey),
          findsNothing,
          reason: 'fixture: no star pill before the move',
        );

        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 0,
          from: 10,
          to: 16,
          face: 6,
        );
        expect(
          drive.controller.room!.seats[0].tokens[0],
          16,
          reason: 'fixture: moved updated my token 0 to progress 16',
        );

        await _pumpFor(tester, _travelFor(6));

        expect(kSafeCueHold, const Duration(milliseconds: 1400));
        expect(kSafeCueFade, const Duration(milliseconds: 200));
        expect(
          find.byKey(_pairKey),
          findsOneWidget,
          reason:
              'A1: board-safe-cue-pair must be present after landing on '
              'an opponent pair',
        );
        expect(
          find.byKey(_starKey),
          findsNothing,
          reason: 'A1: board-safe-cue-star must not show on a non-safe cell',
        );
        final AppLocalizations loc = _locOf(tester);
        expect(loc.boardSafePairCue, 'Pair is safe');
        expect(
          _pillText(tester, _pairKey),
          loc.boardSafePairCue,
          reason: 'A1: the pair pill must show boardSafePairCue',
        );

        await _pumpFor(tester, kSafeCueHold + kSafeCueFade + _margin);

        expect(
          find.byKey(_pairKey),
          findsNothing,
          reason: 'A1: board-safe-cue-pair must be gone after hold + fade',
        );
        expect(
          find.byKey(_starKey),
          findsNothing,
          reason: 'A1: board-safe-cue-star must remain absent',
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A2: my token moves to safe square 21 where seat 1 has one token at '
    'progress 8 and shows board-safe-cue-star with boardSafeSquareCue',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[17, 30, -1, -1],
          other: const <int>[8, -1, -1, -1],
        ),
        turn: _moverTurn(seat: 0, face: 4, legal: const <int>[0, 1]),
      );
      try {
        await mountGame(tester, drive);
        expect(
          drive.controller.room!.seats[0].tokens[0],
          17,
          reason: 'fixture: my token 0 starts at progress 17',
        );
        expect(drive.controller.room!.seats[1].tokens, const <int>[
          8,
          -1,
          -1,
          -1,
        ], reason: 'fixture: seat 1 has one token at progress 8');
        expect(
          cellFor(seat: 0, progress: 21),
          cellFor(seat: 1, progress: 8),
          reason:
              'fixture: seat 0 progress 21 and seat 1 progress 8 are both '
              'absolute square 21',
        );
        expect(
          safeTrackSquares.contains(21),
          isTrue,
          reason: 'fixture: absolute square 21 is in safeTrackSquares',
        );
        expect(
          find.byKey(_starKey),
          findsNothing,
          reason: 'fixture: no star pill before the move',
        );

        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 0,
          from: 17,
          to: 21,
          face: 4,
        );
        expect(
          drive.controller.room!.seats[0].tokens[0],
          21,
          reason: 'fixture: moved updated my token 0 to progress 21',
        );

        await _pumpFor(tester, _travelFor(4));

        expect(
          find.byKey(_starKey),
          findsOneWidget,
          reason: 'A2: board-safe-cue-star must appear on safe square 21',
        );
        expect(
          find.byKey(_pairKey),
          findsNothing,
          reason: 'A2: board-safe-cue-pair must not appear for a safe square',
        );
        final AppLocalizations loc = _locOf(tester);
        expect(loc.boardSafeSquareCue, 'Safe square');
        expect(
          _pillText(tester, _starKey),
          loc.boardSafeSquareCue,
          reason: 'A2: the star pill must show boardSafeSquareCue',
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A3: seat 1 token landing on my pair shows board-safe-cue-pair on my '
    'screen',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[16, 16, -1, -1],
          other: const <int>[0, 10, -1, -1],
        ),
        turn: _moverTurn(seat: 1, face: 3, legal: const <int>[0, 1]),
      );
      try {
        await mountGame(tester, drive);
        expect(drive.controller.seat, 0, reason: 'fixture: my seat is 0');
        expect(
          drive.controller.room!.seats[0].tokens.sublist(0, 2),
          const <int>[16, 16],
          reason: 'fixture: my tokens 0 and 1 form a pair at progress 16',
        );
        expect(
          cellFor(seat: 1, progress: 3),
          cellFor(seat: 0, progress: 16),
          reason: 'fixture: seat 1 progress 3 lands on my pair at absolute 16',
        );
        expect(
          safeTrackSquares.contains(16),
          isFalse,
          reason: 'fixture: absolute square 16 is not in safeTrackSquares',
        );
        expect(
          find.byKey(_pairKey),
          findsNothing,
          reason: 'fixture: no pair pill before seat 1 moves',
        );

        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 1,
          token: 0,
          from: 0,
          to: 3,
          face: 3,
          nextSeat: 0,
        );
        expect(
          drive.controller.room!.seats[1].tokens[0],
          3,
          reason: 'fixture: seat 1 token 0 moved to progress 3',
        );

        await _pumpFor(tester, _travelFor(3));

        expect(
          find.byKey(_pairKey),
          findsOneWidget,
          reason:
              'A3: board-safe-cue-pair must show when seat 1 lands on my '
              'pair',
        );
        expect(
          find.byKey(_starKey),
          findsNothing,
          reason: 'A3: board-safe-cue-star must not show',
        );
        expect(
          _pillText(tester, _pairKey),
          _locOf(tester).boardSafePairCue,
          reason: 'A3: the pair pill shows boardSafePairCue on my screen',
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A4: a move with captured non-empty shows no pill at any frame up to '
    'kSafeCueHold after landing',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[10, 20, -1, -1],
          other: const <int>[3, 3, -1, -1],
        ),
        turn: _moverTurn(seat: 0, face: 6, legal: const <int>[0, 1]),
      );
      try {
        await mountGame(tester, drive);
        expect(
          drive.controller.room!.seats[0].tokens[0],
          10,
          reason: 'fixture: my token 0 starts at progress 10',
        );
        expect(
          drive.controller.room!.seats[1].tokens.sublist(0, 2),
          const <int>[3, 3],
          reason: 'fixture: seat 1 starts with tokens at progress 3',
        );

        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 0,
          from: 10,
          to: 16,
          face: 6,
          captured: const <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 0},
          ],
          extraRoll: true,
          nextSeat: 0,
        );
        expect(
          drive.controller.room!.seats[0].tokens[0],
          16,
          reason: 'fixture: my token 0 moved to progress 16',
        );
        expect(
          drive.controller.room!.seats[1].tokens[0],
          -1,
          reason: 'fixture: seat 1 token 0 was captured to the yard',
        );

        expect(find.byKey(_pairKey), findsNothing);
        expect(find.byKey(_starKey), findsNothing);

        await _pumpFor(
          tester,
          _travelFor(6) + kSafeCueHold + _margin,
          onFrame: () {
            expect(
              find.byKey(_pairKey),
              findsNothing,
              reason:
                  'A4: a capturing move must never show board-safe-cue-pair',
            );
            expect(
              find.byKey(_starKey),
              findsNothing,
              reason:
                  'A4: a capturing move must never show board-safe-cue-star',
            );
          },
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A5: a move to an empty square and a move onto a square holding only my '
    'own token show no pill',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[10, 20, -1, -1],
          other: const <int>[30, -1, -1, -1],
        ),
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 2,
          value: 4,
          legal: const <int>[0, 1],
          queue: const <int>[4, 6],
          legalByFace: <Map<String, Object?>>[
            faceLegal(4, const <int>[0, 1]),
            faceLegal(6, const <int>[0, 1]),
          ],
        ),
      );
      try {
        await mountGame(tester, drive);
        expect(drive.controller.room!.seats[0].tokens, const <int>[
          10,
          20,
          -1,
          -1,
        ], reason: 'fixture: my tokens 0 and 1 start at 10 and 20');
        expect(drive.controller.room!.seats[1].tokens, const <int>[
          30,
          -1,
          -1,
          -1,
        ], reason: 'fixture: seat 1 only sits at progress 30 (absolute 43)');

        // Move 1: 10 -> 14 onto an empty square.
        await drive.push(tester, 'moved', <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': 10,
          'to': 14,
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
          'legal': <int>[0, 1],
          'legal_by_face': <Map<String, Object?>>[
            faceLegal(6, const <int>[0, 1]),
          ],
        });
        expect(
          drive.controller.room!.seats[0].tokens[0],
          14,
          reason: 'fixture: my token 0 moved to empty square 14',
        );

        await _pumpFor(
          tester,
          _travelFor(4) + _margin,
          onFrame: () {
            expect(
              find.byKey(_pairKey),
              findsNothing,
              reason: 'A5: move to an empty square must not show pair pill',
            );
            expect(
              find.byKey(_starKey),
              findsNothing,
              reason: 'A5: move to an empty square must not show star pill',
            );
          },
        );

        // Move 2: 14 -> 20 onto a square holding only my own token 1.
        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 0,
          from: 14,
          to: 20,
          face: 6,
        );
        expect(
          drive.controller.room!.seats[0].tokens.sublist(0, 2),
          const <int>[20, 20],
          reason: 'fixture: my tokens 0 and 1 now share progress 20',
        );

        await _pumpFor(
          tester,
          _travelFor(6) + _margin,
          onFrame: () {
            expect(
              find.byKey(_pairKey),
              findsNothing,
              reason: 'A5: landing on my own token must not show pair pill',
            );
            expect(
              find.byKey(_starKey),
              findsNothing,
              reason: 'A5: landing on my own token must not show star pill',
            );
          },
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A6: a move into the home column (52..56) and a move home (57) show no '
    'pill',
    (tester) async {
      // Seat 1 holds tokens at progresses 41 and 44 (whose modulo-52 track
      // squares match 54 % 52 and 57 % 52) and at 54 and 57 (matching the raw
      // destination numbers), so a missing 0..51 main-track guard fails under
      // either comparison.
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[50, 54, -1, -1],
          other: const <int>[41, 44, 54, 57],
        ),
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 2,
          value: 4,
          legal: const <int>[0, 1],
          queue: const <int>[4, 3],
          legalByFace: <Map<String, Object?>>[
            faceLegal(4, const <int>[0]),
            faceLegal(3, const <int>[1]),
          ],
        ),
      );
      try {
        await mountGame(tester, drive);
        expect(
          drive.controller.room!.seats[0].tokens.sublist(0, 2),
          const <int>[50, 54],
          reason: 'fixture: my tokens 0 and 1 start at 50 and 54',
        );
        expect(drive.controller.room!.seats[1].tokens, const <int>[
          41,
          44,
          54,
          57,
        ], reason: 'fixture: seat 1 tokens sit at 41, 44, 54 and 57');

        // Move 1: 50 -> 54 into the home column (52..56).
        await drive.push(tester, 'moved', <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': 50,
          'to': 54,
          'captured': <Object?>[],
          'extra_roll': false,
          'face': 4,
        });
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 1,
          'phase': 'await_roll',
          'deadline_ms': rollTrayDeadlineMs,
          'queue': <int>[],
        });
        expect(
          drive.controller.room!.seats[0].tokens[0],
          54,
          reason: 'fixture: my token 0 moved into the home column at 54',
        );

        await _pumpFor(
          tester,
          _travelFor(4) + _margin,
          onFrame: () {
            expect(
              find.byKey(_pairKey),
              findsNothing,
              reason: 'A6: home-column move must not show board-safe-cue-pair',
            );
            expect(
              find.byKey(_starKey),
              findsNothing,
              reason: 'A6: home-column move must not show board-safe-cue-star',
            );
          },
        );

        // Move 2: 54 -> 57 reaching home.
        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 1,
          from: 54,
          to: 57,
          face: 3,
          extraRoll: true,
          nextSeat: 0,
        );
        expect(
          drive.controller.room!.seats[0].tokens[1],
          57,
          reason: 'fixture: my token 1 reached home at 57',
        );

        await _pumpFor(
          tester,
          _travelFor(3) + _margin,
          onFrame: () {
            expect(
              find.byKey(_pairKey),
              findsNothing,
              reason: 'A6: move home must not show board-safe-cue-pair',
            );
            expect(
              find.byKey(_starKey),
              findsNothing,
              reason: 'A6: move home must not show board-safe-cue-star',
            );
          },
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A7: a qualifying move plays the exact same feedback cues as the same '
    'move onto an empty square',
    (tester) async {
      late final List<FeedbackCue> qualifyingCues;
      final RollTrayDrive qualifyingDrive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[10, 20, -1, -1],
          other: const <int>[3, 3, -1, -1],
        ),
        turn: _moverTurn(seat: 0, face: 6, legal: const <int>[0, 1]),
      );
      try {
        await mountGame(tester, qualifyingDrive);
        expect(
          qualifyingDrive.controller.room!.seats[1].tokens.sublist(0, 2),
          const <int>[3, 3],
          reason: 'fixture: qualifying run has seat 1 pair at progress 3',
        );
        qualifyingDrive.feedback.recorded.clear();

        await _pushMovedAndNextTurn(
          tester,
          qualifyingDrive,
          seat: 0,
          token: 0,
          from: 10,
          to: 16,
          face: 6,
        );
        await _pumpFor(tester, _travelFor(6));
        expect(
          find.byKey(_pairKey),
          findsOneWidget,
          reason: 'A7: qualifying move must show the safe-cue pill on landing',
        );
        await _pumpFor(tester, kSafeCueHold + kSafeCueFade + _margin);
        qualifyingCues = List<FeedbackCue>.of(
          qualifyingDrive.feedback.recorded,
        );
      } finally {
        await releaseGame(tester, qualifyingDrive);
      }

      late final List<FeedbackCue> emptySquareCues;
      final RollTrayDrive emptyDrive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[10, 20, -1, -1],
          other: const <int>[-1, -1, -1, -1],
        ),
        turn: _moverTurn(seat: 0, face: 6, legal: const <int>[0, 1]),
      );
      try {
        await mountGame(tester, emptyDrive);
        expect(emptyDrive.controller.room!.seats[1].tokens, const <int>[
          -1,
          -1,
          -1,
          -1,
        ], reason: 'fixture: comparison run has destination square 16 empty');
        emptyDrive.feedback.recorded.clear();

        await _pushMovedAndNextTurn(
          tester,
          emptyDrive,
          seat: 0,
          token: 0,
          from: 10,
          to: 16,
          face: 6,
        );
        await _pumpFor(tester, _travelFor(6));
        expect(
          find.byKey(_pairKey),
          findsNothing,
          reason: 'fixture: empty-square move shows no pill',
        );
        await _pumpFor(tester, kSafeCueHold + kSafeCueFade + _margin);
        emptySquareCues = List<FeedbackCue>.of(emptyDrive.feedback.recorded);
      } finally {
        await releaseGame(tester, emptyDrive);
      }

      expect(
        qualifyingCues,
        isNotEmpty,
        reason: 'fixture: a 6-step move records step cues',
      );
      expect(
        qualifyingCues,
        emptySquareCues,
        reason:
            'A7: a qualifying move must play the exact same cues as the '
            'same move onto an empty square',
      );
    },
  );

  testWidgets(
    'A8: under Arabic at 360x640, the pill shows the Arabic line and its '
    'rect stays inside the board rect for top-row and leading-edge '
    'destinations',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Seat 1 holds:
      // - token 0 at progress 13 (absolute 26, safe square, viewed cell (8, 0)
      //   in the top row of the rotated board),
      // - token 1 at progress 0 (absolute 13, safe square, board-space cell
      //   (8, 0) and viewed cell (0, 6) on the left edge),
      // - tokens 2 and 3 at progress 25 (absolute 38, pair on viewed cell
      //   (14, 7) on the right / RTL-leading edge).
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[23, 10, 35, -1],
          other: const <int>[13, 0, 25, 25],
        ),
        turn: _moverTurn(seat: 0, face: 3, legal: const <int>[0, 1, 2]),
      );
      try {
        await mountGame(tester, drive, locale: const Locale('ar'));
        final int quarters = viewQuarters(0);
        expect(
          toView(cellFor(seat: 0, progress: 26), quarters),
          const BoardCell(8, 0),
          reason:
              'fixture: absolute 26 sits in the top row of the viewed '
              'board (row 0)',
        );
        expect(
          cellFor(seat: 0, progress: 13),
          const BoardCell(8, 0),
          reason: 'fixture: absolute 13 is in row 0 of unrotated board space',
        );
        expect(
          toView(cellFor(seat: 0, progress: 13), quarters),
          const BoardCell(0, 6),
          reason: 'fixture: absolute 13 sits on column 0 of the viewed board',
        );
        expect(
          toView(cellFor(seat: 0, progress: 38), quarters),
          const BoardCell(14, 7),
          reason:
              'fixture: absolute 38 sits on column 14 (RTL leading edge) '
              'of the viewed board',
        );

        final AppLocalizations loc = _locOf(tester);
        expect(loc.boardSafeSquareCue, 'مربع آمن');
        expect(loc.boardSafePairCue, 'قطعتان آمنتان');

        // 1. Top row of the viewed board: token 0 moves 23 -> 26 (safe square).
        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 0,
          from: 23,
          to: 26,
          face: 3,
        );
        await _pumpFor(tester, _travelFor(3));
        expect(
          find.byKey(_starKey),
          findsOneWidget,
          reason: 'A8: top-row safe square 26 must show board-safe-cue-star',
        );
        expect(_pillText(tester, _starKey), loc.boardSafeSquareCue);
        _expectInsideBoard(tester, _starKey, 'A8 top row (abs 26)');

        // 2. Column 0 of the viewed board (and row 0 in board space): token 1
        // moves 10 -> 13 (safe square).
        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 1,
          from: 10,
          to: 13,
          face: 3,
        );
        await _pumpFor(tester, _travelFor(3));
        expect(
          find.byKey(_starKey),
          findsOneWidget,
          reason: 'A8: edge square 13 must show board-safe-cue-star',
        );
        expect(_pillText(tester, _starKey), loc.boardSafeSquareCue);
        _expectInsideBoard(tester, _starKey, 'A8 col 0 (abs 13)');

        // 3. Column 14 (RTL leading edge of the viewed board): token 2 moves
        // 35 -> 38 onto seat 1's pair.
        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 2,
          from: 35,
          to: 38,
          face: 3,
        );
        await _pumpFor(tester, _travelFor(3));
        expect(
          find.byKey(_pairKey),
          findsOneWidget,
          reason:
              'A8: RTL leading-edge pair square 38 must show '
              'board-safe-cue-pair',
        );
        expect(_pillText(tester, _pairKey), loc.boardSafePairCue);
        _expectInsideBoard(tester, _pairKey, 'A8 RTL leading edge (abs 38)');
      } finally {
        await releaseGame(tester, drive);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'A9: under reduced motion, the pill is present on the first frames after '
    'moved and gone after kSafeCueHold plus a margin',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[10, 20, -1, -1],
          other: const <int>[3, 3, -1, -1],
        ),
        turn: _moverTurn(seat: 0, face: 6, legal: const <int>[0, 1]),
      );
      try {
        await mountGame(tester, drive, disableAnimations: true);
        expect(
          MediaQuery.disableAnimationsOf(
            tester.element(find.byType(GameScreen)),
          ),
          isTrue,
          reason: 'fixture: disableAnimations is true on GameScreen',
        );
        expect(
          find.byKey(_pairKey),
          findsNothing,
          reason: 'fixture: no pill before moved',
        );

        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 0,
          from: 10,
          to: 16,
          face: 6,
        );
        expect(
          drive.controller.room!.seats[0].tokens[0],
          16,
          reason: 'fixture: moved reduced token 0 to 16',
        );

        expect(
          find.byKey(_pairKey),
          findsOneWidget,
          reason:
              'A9: under reduced motion the pill must be present on the '
              'first frame after moved',
        );
        expect(
          find.byKey(_starKey),
          findsNothing,
          reason: 'A9: board-safe-cue-star must not appear',
        );
        expect(
          _pillText(tester, _pairKey),
          _locOf(tester).boardSafePairCue,
          reason: 'A9: the pill shows boardSafePairCue immediately',
        );

        await tester.pump(_frame);
        expect(
          find.byKey(_pairKey),
          findsOneWidget,
          reason: 'A9: the pill remains present on the next 16 ms frame',
        );

        // S5: under reduced motion the pill stays kSafeCueHold and is removed
        // with no fade. _margin (100 ms) is shorter than kSafeCueFade (200 ms),
        // so an implementation that failed to skip the fade would still have
        // the pill in the tree here.
        await _pumpFor(tester, kSafeCueHold + _margin - _frame);

        expect(
          find.byKey(_pairKey),
          findsNothing,
          reason:
              'A9: under reduced motion the pill must be gone after '
              'kSafeCueHold plus a margin, with no fade',
        );
        expect(find.byKey(_starKey), findsNothing);
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A10: a second qualifying move while a pill is showing leaves one pill, '
    'the new one with its key and position',
    (tester) async {
      // Seat 1 holds a pair at progress 3 (absolute 16, viewed cell (3, 6))
      // and a single token at progress 8 (absolute 21, safe square, viewed
      // cell (6, 3)).
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(
          mine: const <int>[10, 18, -1, -1],
          other: const <int>[3, 3, 8, -1],
        ),
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 2,
          value: 6,
          legal: const <int>[0, 1],
          queue: const <int>[6, 3],
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[0]),
            faceLegal(3, const <int>[1]),
          ],
        ),
      );
      try {
        await mountGame(tester, drive);
        final int quarters = viewQuarters(0);
        expect(
          toView(cellFor(seat: 0, progress: 16), quarters),
          const BoardCell(3, 6),
          reason:
              'fixture: first destination (abs 16) sits at viewed cell '
              '(3, 6)',
        );
        expect(
          toView(cellFor(seat: 0, progress: 21), quarters),
          const BoardCell(6, 3),
          reason:
              'fixture: second destination (abs 21) sits at viewed cell '
              '(6, 3)',
        );

        // First qualifying move: token 0 moves 10 -> 16 onto seat 1's pair.
        await drive.push(tester, 'moved', <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': 10,
          'to': 16,
          'captured': <Object?>[],
          'extra_roll': false,
          'face': 6,
        });
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 0,
          'phase': 'await_move',
          'deadline_ms': rollTrayDeadlineMs,
          'queue': <int>[3],
          'value': 3,
          'legal': <int>[0, 1],
          'legal_by_face': <Map<String, Object?>>[
            faceLegal(3, const <int>[0, 1]),
          ],
        });
        await _pumpFor(tester, _travelFor(6));

        expect(
          find.byKey(_pairKey),
          findsOneWidget,
          reason: 'fixture: first qualifying move shows board-safe-cue-pair',
        );
        expect(
          find.byKey(_starKey),
          findsNothing,
          reason: 'fixture: star pill is absent after first move',
        );
        final Rect firstRect = tester.getRect(find.byKey(_pairKey));

        // Second qualifying move while the first pill still has almost its
        // full kSafeCueHold left: token 1 moves 18 -> 21 onto safe square 21
        // where seat 1's token 2 stands.
        await _pushMovedAndNextTurn(
          tester,
          drive,
          seat: 0,
          token: 1,
          from: 18,
          to: 21,
          face: 3,
        );
        await _pumpFor(tester, _travelFor(3));

        expect(
          find.byKey(_starKey),
          findsOneWidget,
          reason:
              'A10: the second qualifying move must show '
              'board-safe-cue-star',
        );
        expect(
          find.byKey(_pairKey),
          findsNothing,
          reason:
              'A10: the first pill (board-safe-cue-pair) must be replaced '
              'so at most one pill is in the tree',
        );
        expect(
          _pillText(tester, _starKey),
          _locOf(tester).boardSafeSquareCue,
          reason: 'A10: the new pill shows boardSafeSquareCue',
        );

        final Rect secondRect = tester.getRect(find.byKey(_starKey));
        expect(
          secondRect.center.dx,
          greaterThan(firstRect.center.dx),
          reason:
              'A10: viewed cell (6, 3) is to the right of (3, 6), so the '
              'new pill centre dx (${secondRect.center.dx}) must exceed the '
              'first (${firstRect.center.dx})',
        );
        expect(
          secondRect.center.dy,
          lessThan(firstRect.center.dy),
          reason:
              'A10: viewed cell (6, 3) is above (3, 6), so the new pill '
              'centre dy (${secondRect.center.dy}) must be less than the '
              'first (${firstRect.center.dy})',
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );
}

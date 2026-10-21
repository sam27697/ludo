// Tests for C-420-tray-long-queue.md decisions D1-D5, the grouped roll
// tray. Written from the contract, not from roll_tray.dart: order 421
// writes the implementation in parallel and is handed this file to pass.
//
// Every queue used here is one 10q-12q (docs/RULES.md:125-148) actually
// reaches: under 12q a grouped tray holds at most two tiles, the 6-group
// and the one other face, so every case below uses exactly that shape,
// `[6, 6, 6, 6, 2]` (rolled 6, 6, 4; the 4 spent with a capture bonus
// roll of 6, 6, 2), or its own fitting control `[6, 6, 3]`.
//
// This is a measurement against the contract: a red case here is the
// finding, and stays red until the implementation earns it green.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsHandle, SemanticsNode;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';

import 'support/roll_tray_harness.dart';

const Size _groupedSize = Size(360, 640);

Future<void> _loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();

  final FontLoader noto = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    noto.addFont(rootBundle.load(asset));
  }
  await noto.load();
}

Key _countKey(int index) => Key('game-roll-tray-count-$index');

/// The grouped count pill's own displayed text, however the implementer
/// chose to carry it: a bare `Text` at the key, or a `Text` nested under
/// it. D2 only promises the key and the string; not the widget shape.
String _countText(WidgetTester tester, int index) {
  final Finder target = find.byKey(_countKey(index));
  expect(
    target,
    findsOneWidget,
    reason: 'D2: game-roll-tray-count-$index must exist on a grouped tile',
  );
  final Widget widget = tester.widget(target);
  if (widget is Text) {
    return widget.data ?? '';
  }
  final Finder nested = find.descendant(
    of: target,
    matching: find.byType(Text),
  );
  expect(
    nested,
    findsWidgets,
    reason:
        'D2: game-roll-tray-count-$index has no readable Text for its '
        'count',
  );
  return nested
      .evaluate()
      .map((Element e) => (e.widget as Text).data ?? '')
      .join();
}

/// Sets the screen size the way every case here mounts at, restorable in
/// the body's own `finally` (never only through `addTearDown`).
void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void _resetSize(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

/// D5's "no Flutter layout error" half, checked up front in every case:
/// a defect that only overflows (never touches a key this case also
/// checks) must still fail here, for the right reason.
void _expectNoOverflow(List<FlutterErrorDetails> captured, String reason) {
  expect(
    captured,
    isEmpty,
    reason:
        '$reason: flutter reported ${captured.length} layout error(s): '
        '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' || ')}',
  );
}

void main() {
  setUpAll(_loadAppFonts);

  testWidgets('case 2a (D1): a queue that fits keeps one tile per face, no count '
      'marks', (tester) async {
    final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? previous = FlutterError.onError;
    FlutterError.onError = captured.add;
    _setSize(tester, _groupedSize);
    final RollTrayDrive drive = await connectPlaying(
      tester,
      seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 3,
        value: 6,
        legal: const <int>[0, 1, 2, 3],
        queue: const <int>[6, 6, 3],
        legalByFace: <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 1, 2, 3]),
          faceLegal(3, const <int>[0]),
        ],
      ),
    );
    try {
      await mountGame(tester, drive);

      expect(
        captured,
        isEmpty,
        reason:
            'D1: a fitting queue must not overflow; got '
            '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' || ')}',
      );
      expect(
        find.byKey(trayDieKey(0)),
        findsOneWidget,
        reason: 'D1: die 0 is the first queued 6, unchanged from today',
      );
      expect(
        find.byKey(trayDieKey(1)),
        findsOneWidget,
        reason: 'D1: die 1 is the second queued 6, unchanged from today',
      );
      expect(
        find.byKey(trayDieKey(2)),
        findsOneWidget,
        reason: 'D1: die 2 is the queued 3, unchanged from today',
      );
      expect(
        find.byKey(_countKey(0)),
        findsNothing,
        reason: 'D1: a fitting queue never carries a count mark',
      );
      expect(find.byKey(_countKey(1)), findsNothing);
      expect(find.byKey(_countKey(2)), findsNothing);
    } finally {
      FlutterError.onError = previous;
      await releaseGame(tester, drive);
      _resetSize(tester);
    }
  });

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    testWidgets(
      'case 2b (D2 ${locale.languageCode}): the grouped 6 and the lone 2 '
      'keep the first-member keys, the right order and the ×4 count',
      (tester) async {
        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final FlutterExceptionHandler? previous = FlutterError.onError;
        FlutterError.onError = captured.add;
        _setSize(tester, _groupedSize);
        final RollTrayDrive drive = await connectPlaying(
          tester,
          seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
          turn: turnJson(
            seat: 0,
            phase: 'await_move',
            k: 5,
            value: 6,
            legal: const <int>[0, 1, 2, 3],
            queue: const <int>[6, 6, 6, 6, 2],
            legalByFace: <Map<String, Object?>>[
              faceLegal(6, const <int>[0, 1, 2, 3]),
              faceLegal(2, const <int>[0]),
            ],
          ),
        );
        try {
          await mountGame(tester, drive, locale: locale);
          _expectNoOverflow(captured, 'D2 ${locale.languageCode}');

          expect(
            find.byKey(trayDieKey(0)),
            findsOneWidget,
            reason: 'D2: game-roll-tray-die-0 is the 6-group\'s first member',
          );
          expect(
            find.byKey(trayDieKey(4)),
            findsOneWidget,
            reason: 'D2: game-roll-tray-die-4 is the lone 2, queue index 4',
          );
          expect(
            find.byKey(trayDieKey(1)),
            findsNothing,
            reason: 'D2: a later member of the 6-group keeps no index key',
          );
          expect(find.byKey(trayDieKey(2)), findsNothing);
          expect(find.byKey(trayDieKey(3)), findsNothing);

          expect(
            _countText(tester, 0),
            '×4',
            reason: 'D2: game-roll-tray-count-0 reads ×4',
          );
          expect(
            find.byKey(_countKey(4)),
            findsNothing,
            reason: 'D2: the lone 2 (count 1) carries no count mark',
          );

          final Rect sixRect = tester.getRect(find.byKey(trayDieKey(0)));
          final Rect twoRect = tester.getRect(find.byKey(trayDieKey(4)));
          if (locale.languageCode == 'ar') {
            expect(
              sixRect.center.dx,
              greaterThan(twoRect.center.dx),
              reason:
                  'D2: ar reads right to left, so the first-queued 6 '
                  'sits to the right of the 2',
            );
          } else {
            expect(
              sixRect.center.dx,
              lessThan(twoRect.center.dx),
              reason:
                  'D2: en reads left to right, so the first-queued 6 '
                  'sits to the left of the 2',
            );
          }
        } finally {
          FlutterError.onError = previous;
          await releaseGame(tester, drive);
          _resetSize(tester);
        }
      },
    );
  }

  testWidgets(
    'case 2c (D2 state): the 6-group is selected by default and the lone '
    '2 is dead',
    (tester) async {
      final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = captured.add;
      _setSize(tester, _groupedSize);
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 5,
          value: 6,
          legal: const <int>[0, 1, 2, 3],
          queue: const <int>[6, 6, 6, 6, 2],
          // Only the 6 is in legal_by_face: the 2's token has no legal
          // move this turn, so it is dead, and 6, being the only alive
          // face, is also the default selection (K4).
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[0, 1, 2, 3]),
          ],
        ),
      );
      try {
        await mountGame(tester, drive);
        _expectNoOverflow(captured, 'D2 state');

        expect(
          find.descendant(
            of: find.byKey(trayDieKey(0)),
            matching: find.byKey(traySelectedKey(0)),
          ),
          findsOneWidget,
          reason:
              'D2: the 6-group, the only alive face, is selected by '
              'default, game-roll-tray-selected-0',
        );
        expect(
          find.descendant(
            of: find.byKey(trayDieKey(4)),
            matching: find.byKey(trayDeadKey(4)),
          ),
          findsOneWidget,
          reason:
              'D2: the lone dead 2 carries game-roll-tray-dead-4 on its '
              'own first-member index',
        );
      } finally {
        FlutterError.onError = previous;
        await releaseGame(tester, drive);
        _resetSize(tester);
      }
    },
  );

  testWidgets(
    'case 2d (D2 tap): tapping the grouped 6 selects face 6; tapping the '
    'dead group selects nothing and plays invalidTap',
    (tester) async {
      final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = captured.add;
      _setSize(tester, _groupedSize);
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 5,
          value: 6,
          legal: const <int>[0, 1, 2, 3],
          queue: const <int>[6, 6, 6, 6, 2],
          // Both faces alive, first-queued order (PROTOCOL.md section
          // 21): the 6 is selected by default.
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[0, 1, 2, 3]),
            faceLegal(2, const <int>[0]),
          ],
        ),
      );
      try {
        await mountGame(tester, drive);
        _expectNoOverflow(captured, 'D2 tap, initial state');

        expect(
          find.descendant(
            of: find.byKey(trayDieKey(0)),
            matching: find.byKey(traySelectedKey(0)),
          ),
          findsOneWidget,
          reason: 'fixture is broken: the 6 is selected by default',
        );

        // Move the selection away from the default so a later tap on the
        // grouped 6 is an observable change, the way
        // test/roll_tray_test.dart's case 2 moves the mark off die 0.
        await tester.tap(find.byKey(trayDieKey(4)));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byKey(trayDieKey(4)),
            matching: find.byKey(traySelectedKey(4)),
          ),
          findsOneWidget,
          reason: 'fixture is broken: tapping the lone 2 must select it',
        );
        expect(find.byKey(traySelectedKey(0)), findsNothing);

        await tester.tap(find.byKey(trayDieKey(0)));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byKey(trayDieKey(0)),
            matching: find.byKey(traySelectedKey(0)),
          ),
          findsOneWidget,
          reason:
              'D2: tapping the grouped 6 tile selects face 6, the '
              'screen\'s selection',
        );
        expect(
          find.byKey(traySelectedKey(4)),
          findsNothing,
          reason: 'D2: the 2 is no longer selected once the 6 is tapped',
        );

        // Spend one of the queued 6s (12q: a 6 spent on a move grants
        // nothing), leaving the 2 dead in the shorter queue.
        await drive.push(tester, 'moved', <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': 0,
          'to': 6,
          'captured': <Object?>[],
          'extra_roll': false,
          'face': 6,
        });
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 0,
          'phase': 'await_move',
          'deadline_ms': rollTrayDeadlineMs,
          'queue': <int>[6, 6, 6, 2],
          'value': 6,
          'legal': <int>[0, 1, 2, 3],
          'legal_by_face': <Map<String, Object?>>[
            faceLegal(6, const <int>[0, 1, 2, 3]),
          ],
        });

        expect(
          find.descendant(
            of: find.byKey(trayDieKey(3)),
            matching: find.byKey(trayDeadKey(3)),
          ),
          findsOneWidget,
          reason:
              'fixture is broken: the 2, now alone and dead at queue '
              'index 3, must carry game-roll-tray-dead-3',
        );

        final int sentBefore = drive.transport.sentRaw.length;
        final int cuesBefore = drive.feedback.recorded.length;
        await tester.tap(find.byKey(trayDieKey(3)));
        await tester.pump();

        expect(
          drive.transport.sentRaw.length,
          sentBefore,
          reason: 'D2/K5: tapping a dead group sends nothing',
        );
        expect(drive.feedback.recorded.skip(cuesBefore).toList(), <FeedbackCue>[
          FeedbackCue.invalidTap,
        ], reason: 'D2: tapping a dead group plays invalidTap once');
        expect(
          find.byKey(traySelectedKey(3)),
          findsNothing,
          reason: 'D2: tapping a dead group selects nothing',
        );
      } finally {
        FlutterError.onError = previous;
        await releaseGame(tester, drive);
        _resetSize(tester);
      }
    },
  );

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final double scale in const <double>[1.0, 2.0]) {
      testWidgets(
        'case 2e (D2 count placement ${locale.languageCode} x$scale): the '
        'count pill sits inside the hit box at its bottom-end corner',
        (tester) async {
          final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
          final FlutterExceptionHandler? previous = FlutterError.onError;
          FlutterError.onError = captured.add;
          _setSize(tester, _groupedSize);
          final RollTrayDrive drive = await connectPlaying(
            tester,
            seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
            turn: turnJson(
              seat: 0,
              phase: 'await_move',
              k: 5,
              value: 6,
              legal: const <int>[0, 1, 2, 3],
              queue: const <int>[6, 6, 6, 6, 2],
              legalByFace: <Map<String, Object?>>[
                faceLegal(6, const <int>[0, 1, 2, 3]),
                faceLegal(2, const <int>[0]),
              ],
            ),
          );
          try {
            await mountGame(tester, drive, locale: locale, textScale: scale);
            _expectNoOverflow(
              captured,
              'D2 count placement ${locale.languageCode} x$scale',
            );

            final Rect tile = tester.getRect(find.byKey(trayDieKey(0)));
            final Rect pill = tester.getRect(find.byKey(_countKey(0)));

            expect(
              pill.left >= tile.left &&
                  pill.top >= tile.top &&
                  pill.right <= tile.right &&
                  pill.bottom <= tile.bottom,
              isTrue,
              reason:
                  'D2: the count pill rect $pill must lie inside the '
                  '48dp hit box $tile at text scale $scale',
            );
            expect(
              pill.center.dy,
              greaterThan(tile.center.dy),
              reason: 'D2: the count mark sits on the bottom edge',
            );
            if (locale.languageCode == 'ar') {
              expect(
                pill.center.dx,
                lessThan(tile.center.dx),
                reason: 'D2: ar puts the count mark at the bottom-left',
              );
            } else {
              expect(
                pill.center.dx,
                greaterThan(tile.center.dx),
                reason: 'D2: en puts the count mark at the bottom-right',
              );
            }
          } finally {
            FlutterError.onError = previous;
            await releaseGame(tester, drive);
            _resetSize(tester);
          }
        },
      );
    }
  }

  testWidgets(
    'case 2f (D3 en): the grouped 6 reads can-move plus its count, the '
    'lone 2 reads its old label unchanged',
    (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = captured.add;
      _setSize(tester, _groupedSize);
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 5,
          value: 6,
          legal: const <int>[0, 1, 2, 3],
          queue: const <int>[6, 6, 6, 6, 2],
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[0, 1, 2, 3]),
            faceLegal(2, const <int>[0]),
          ],
        ),
      );
      try {
        await mountGame(tester, drive, locale: const Locale('en'));
        _expectNoOverflow(captured, 'D3 en');

        // Move the selection off the 6 so it reads "can move", the
        // literal case D3 gives, not "selected".
        await tester.tap(find.byKey(trayDieKey(4)));
        await tester.pump();

        final SemanticsNode sixNode = tester.getSemantics(
          find.byKey(trayDieKey(0)),
        );
        expect(
          sixNode.label,
          'Die 6, can move, 4 of them',
          reason:
              'D3: en joins the existing can-move label with ", 4 of '
              'them"',
        );
        final SemanticsNode twoNode = tester.getSemantics(
          find.byKey(trayDieKey(4)),
        );
        expect(
          twoNode.label,
          'Die 2, selected',
          reason: 'D3: a count-1 tile reads exactly its old label',
        );
      } finally {
        semantics.dispose();
        FlutterError.onError = previous;
        await releaseGame(tester, drive);
        _resetSize(tester);
      }
    },
  );

  testWidgets(
    'case 2f (D3 ar): the grouped 6 reads can-move plus its count, the '
    'lone 2 reads its old label unchanged',
    (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = captured.add;
      _setSize(tester, _groupedSize);
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 5,
          value: 6,
          legal: const <int>[0, 1, 2, 3],
          queue: const <int>[6, 6, 6, 6, 2],
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[0, 1, 2, 3]),
            faceLegal(2, const <int>[0]),
          ],
        ),
      );
      try {
        await mountGame(tester, drive, locale: const Locale('ar'));
        _expectNoOverflow(captured, 'D3 ar');

        await tester.tap(find.byKey(trayDieKey(4)));
        await tester.pump();

        final SemanticsNode sixNode = tester.getSemantics(
          find.byKey(trayDieKey(0)),
        );
        expect(
          sixNode.label,
          'النرد 6، يمكن التحريك، العدد 4',
          reason: 'D3: ar joins the existing can-move label with "، العدد 4"',
        );
        final SemanticsNode twoNode = tester.getSemantics(
          find.byKey(trayDieKey(4)),
        );
        expect(
          twoNode.label,
          'النرد 2، محدد',
          reason: 'D3: a count-1 tile reads exactly its old label',
        );
      } finally {
        semantics.dispose();
        FlutterError.onError = previous;
        await releaseGame(tester, drive);
        _resetSize(tester);
      }
    },
  );

  testWidgets('case 2g (D4): spending the lone 2 fades it out over 220ms without '
      'any frame overflowing', (tester) async {
    final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? previous = FlutterError.onError;
    FlutterError.onError = captured.add;
    _setSize(tester, _groupedSize);
    final RollTrayDrive drive = await connectPlaying(
      tester,
      seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 5,
        value: 6,
        legal: const <int>[0, 1, 2, 3],
        queue: const <int>[6, 6, 6, 6, 2],
        legalByFace: <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 1, 2, 3]),
          faceLegal(2, const <int>[0]),
        ],
      ),
    );
    try {
      await mountGame(tester, drive);

      void checkFrame(String label) {
        expect(
          captured,
          isEmpty,
          reason:
              'D4 $label: flutter reported ${captured.length} layout '
              'error(s): '
              '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' || ')}',
        );
        for (int i = 0; i < 6; i++) {
          final Finder finder = find.byKey(trayDieKey(i));
          if (!tester.any(finder)) {
            continue;
          }
          final Rect rect = tester.getRect(finder);
          expect(
            rect.left >= 0 && rect.right <= _groupedSize.width,
            isTrue,
            reason:
                'D4 $label: game-roll-tray-die-$i rect $rect is '
                'outside the screen width 0..${_groupedSize.width}',
          );
        }
      }

      // 12q: spending the lone 2 (not a 6, not a capture here) grants
      // no bonus, so the queue just loses it.
      await drive.push(tester, 'moved', <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 0,
        'to': 2,
        'captured': <Object?>[],
        'extra_roll': false,
        'face': 2,
      });
      await drive.push(tester, 'turn', <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': rollTrayDeadlineMs,
        'queue': <int>[6, 6, 6, 6],
        'value': 6,
        'legal': <int>[0, 1, 2, 3],
        'legal_by_face': <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 1, 2, 3]),
        ],
      });

      checkFrame('t=0ms');
      for (int elapsed = 20; elapsed <= 220; elapsed += 20) {
        await tester.pump(const Duration(milliseconds: 20));
        checkFrame('t=${elapsed}ms');
      }
    } finally {
      FlutterError.onError = previous;
      await releaseGame(tester, drive);
      _resetSize(tester);
    }
  });
}

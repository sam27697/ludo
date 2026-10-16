// Screen proof for C-380 (order 380, Accept A2 and A3).
// Drives a real GameScreen over FakeTransport through roll_tray_harness.dart
// and checks that the dead-face badge sits on the top-right corner of the big
// die (for faces 1..6) and the tray die (in en and ar).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/roll_tray_harness.dart';

Future<void> _pushNoMoveRoll(
  WidgetTester tester,
  RollTrayDrive drive,
  int face,
) async {
  await drive.push(tester, 'rolled', <String, Object?>{
    'seat': 0,
    'value': face,
    'legal': <int>[],
    'deadline_ms': rollTrayDeadlineMs,
    'k': 1,
    'reveal': rollTrayReveal,
    'queue': <int>[],
  });
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
}

Future<RollTrayDrive> _mountQueueWithDeadFace(
  WidgetTester tester, {
  required Locale locale,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    seats: twoSeats(),
    turn: turnJson(
      seat: 0,
      phase: 'await_move',
      k: 2,
      value: 6,
      legal: const <int>[0, 1, 2, 3],
      queue: const <int>[6, 2],
      legalByFace: <Map<String, Object?>>[
        faceLegal(6, const <int>[0, 1, 2, 3]),
      ],
    ),
  );
  await mountGame(tester, drive, locale: locale);
  return drive;
}

void _expectCornerBadge(
  WidgetTester tester, {
  required Key dieKey,
  required Key markKey,
  required String label,
}) {
  expect(
    find.byKey(dieKey),
    findsOneWidget,
    reason: '$label: $dieKey must be in the tree',
  );
  expect(
    find.byKey(markKey),
    findsOneWidget,
    reason: '$label: $markKey must be in the tree',
  );

  final Rect dieRect = tester.getRect(find.byKey(dieKey));
  final Rect markRect = tester.getRect(find.byKey(markKey));
  final double dieSide = dieRect.shortestSide;
  final double dieArea = dieRect.width * dieRect.height;
  final double markArea = markRect.width * markRect.height;

  expect(
    markArea,
    greaterThan(0),
    reason: '$label: badge rect must have positive area',
  );
  expect(
    (markRect.center - dieRect.topRight).distance,
    lessThan(0.25 * dieSide),
    reason:
        '$label: badge centre ${markRect.center} must lie within '
        '0.25 * $dieSide of top-right corner ${dieRect.topRight}',
  );
  expect(
    markArea,
    lessThan(0.25 * dieArea),
    reason:
        '$label: badge area $markArea must be below 0.25 of die area $dieArea',
  );
}

void main() {
  for (int v = 1; v <= 6; v++) {
    testWidgets(
      'A2: big die no-move mark on face $v sits on top-right corner',
      (tester) async {
        final RollTrayDrive drive = await connectPlaying(
          tester,
          turn: turnJson(
            seat: 0,
            phase: 'await_roll',
            k: 0,
            queue: const <int>[],
          ),
          seats: twoSeats(),
        );
        try {
          await mountGame(tester, drive);
          await _pushNoMoveRoll(tester, drive, v);

          expect(
            find.byKey(bigFaceKey(v)),
            findsOneWidget,
            reason: 'A2: game-die-face-$v stays in the tree on a no-move roll',
          );
          _expectCornerBadge(
            tester,
            dieKey: bigDieKey,
            markKey: noMoveMarkKey,
            label: 'A2 (face $v)',
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets('A3: tray dead mark sits on top-right corner in en', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mountQueueWithDeadFace(
      tester,
      locale: const Locale('en'),
    );
    try {
      _expectCornerBadge(
        tester,
        dieKey: trayDieKey(1),
        markKey: trayDeadKey(1),
        label: 'A3 (en)',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'A3: tray dead mark sits on top-right corner in ar without mirroring',
    (tester) async {
      final RollTrayDrive drive = await _mountQueueWithDeadFace(
        tester,
        locale: const Locale('ar'),
      );
      try {
        _expectCornerBadge(
          tester,
          dieKey: trayDieKey(1),
          markKey: trayDeadKey(1),
          label: 'A3 (ar)',
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );
}

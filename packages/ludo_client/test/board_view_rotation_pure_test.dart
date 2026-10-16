// Pure geometry tests for the viewer-seat board rotation (contract C-367
// Part A, rule V1).
//
// Kept in a separate file from the widget tests in
// test/board_view_rotation_test.dart so the widget suite can compile on main
// before order 373 adds viewQuarters and toView to board_geometry.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart';

void main() {
  group('Viewer-seat board geometry (V1)', () {
    test('viewQuarters maps null to 0 and seats 0..3 to (3 - mySeat) % 4', () {
      expect(viewQuarters(null), 0);
      expect(viewQuarters(0), 3);
      expect(viewQuarters(1), 2);
      expect(viewQuarters(2), 1);
      expect(viewQuarters(3), 0);
    });

    test('toView is the identity at 0 quarters, rotates 90 degrees clockwise '
        'about (7, 7) at 1 quarter, and returns every cell of the 15x15 grid '
        'to itself after four 1-quarter steps', () {
      const cornersAndCentre = <BoardCell>[
        BoardCell(0, 0),
        BoardCell(14, 0),
        BoardCell(14, 14),
        BoardCell(0, 14),
        BoardCell(7, 7),
      ];
      for (final cell in cornersAndCentre) {
        expect(
          toView(cell, 0),
          cell,
          reason: 'toView($cell, 0) must be the identity',
        );
      }

      expect(toView(const BoardCell(0, 0), 1), const BoardCell(14, 0));
      expect(toView(const BoardCell(14, 0), 1), const BoardCell(14, 14));

      for (var col = 0; col <= 14; col++) {
        for (var row = 0; row <= 14; row++) {
          final cell = BoardCell(col, row);
          final rotatedFourTimes = toView(
            toView(toView(toView(cell, 1), 1), 1),
            1,
          );
          expect(
            rotatedFourTimes,
            cell,
            reason:
                'four 1-quarter rotations of $cell gave $rotatedFourTimes '
                'instead of returning to $cell',
          );
        }
      }
    });

    test('for every seat s, toView places that seat\'s yard slot 0 in the '
        'bottom-left yard (col <= 5, row >= 9)', () {
      for (var s = 0; s <= 3; s++) {
        final cell = toView(
          cellFor(seat: s, progress: -1, tokenIndex: 0),
          viewQuarters(s),
        );
        expect(
          cell.col >= 0 && cell.col <= 5,
          isTrue,
          reason:
              'seat $s yard slot 0 in view space is $cell, expected col in '
              '0..5',
        );
        expect(
          cell.row >= 9 && cell.row <= 14,
          isTrue,
          reason:
              'seat $s yard slot 0 in view space is $cell, expected row in '
              '9..14',
        );
      }
    });
  });
}

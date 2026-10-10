// C-307. stepsLeftOf and kNearFinishSquares are not in lib/src/game_stats.dart
// on this base (order 307 adds them). This file does not compile until
// they exist.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/game_stats.dart';

void main() {
  group('stepsLeftOf', () {
    // A yard token is 58: the 6 to enter, then 57 squares. 57 here would
    // be 228, and the mixed case below would be 115.
    test('four yard tokens are 232', () {
      expect(stepsLeftOf(<int>[-1, -1, -1, -1]), 232);
    });

    test('four home tokens are 0', () {
      expect(stepsLeftOf(<int>[57, 57, 57, 57]), 0);
    });

    test('[57, 57, 57, 50] is 7', () {
      expect(stepsLeftOf(<int>[57, 57, 57, 50]), 7);
    });

    test('[-1, 0, 56, 57] is 116', () {
      expect(stepsLeftOf(<int>[-1, 0, 56, 57]), 58 + 57 + 1 + 0);
    });

    test('length 3 throws ArgumentError', () {
      expect(() => stepsLeftOf(<int>[57, 57, 57]), throwsArgumentError);
    });

    test('a token at 58 throws ArgumentError', () {
      expect(() => stepsLeftOf(<int>[57, 57, 57, 58]), throwsArgumentError);
    });

    test('a token at -2 throws ArgumentError', () {
      expect(() => stepsLeftOf(<int>[-2, 0, 56, 57]), throwsArgumentError);
    });
  });

  test('kNearFinishSquares is 12', () {
    expect(kNearFinishSquares, 12);
  });
}

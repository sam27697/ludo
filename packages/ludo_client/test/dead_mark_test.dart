// Pure geometry proof for C-380 (order 380, Accept A1).
// Verifies that the dead-face corner badge sits on the top-right corner at
// 0.42 of the shortest side and never touches any pip circle on faces 1..6.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/dead_mark.dart';

const List<double> _dieSides = <double>[28, 40, 72, 96];

void main() {
  test('A1: deadBadgeRect sits on the top-right corner with side 0.42 of '
      'shortestSide', () {
    for (final double side in _dieSides) {
      final Size size = Size.square(side);
      final Rect badge = deadBadgeRect(size);

      expect(
        (badge.center - Offset(size.width, 0)).distance,
        lessThanOrEqualTo(1e-9),
        reason: 'A1: badge centre at side $side must be (size.width, 0)',
      );
      expect(badge.center.dx, closeTo(size.width, 1e-9));
      expect(badge.center.dy, closeTo(0.0, 1e-9));
      expect(badge.width, closeTo(0.42 * size.shortestSide, 1e-9));
      expect(badge.height, closeTo(0.42 * size.shortestSide, 1e-9));
    }
  });

  test('A1: no pip circle touches the badge circle for faces 1..6 and sides '
      '28, 40, 72, 96', () {
    for (final double side in _dieSides) {
      final Size size = Size.square(side);
      final Rect badge = deadBadgeRect(size);
      final double pipRadius = pipRadiusFor(size);
      expect(
        pipRadius,
        greaterThan(0),
        reason: 'A1: pipRadiusFor($size) must be positive',
      );

      for (int face = 1; face <= 6; face++) {
        final List<Offset> pips = pipCentresFor(face, size);
        expect(
          pips,
          hasLength(face),
          reason: 'A1: face $face must return $face pip centres',
        );
        for (final Offset p in pips) {
          final double distance = (p - badge.center).distance;
          final double minDistance = badge.width / 2 + pipRadius;
          expect(
            distance,
            greaterThan(minDistance),
            reason:
                'A1: face $face at side $side pip at $p is $distance from '
                'badge centre ${badge.center}, need > $minDistance',
          );
        }
      }
    }
  });

  // Master addition, run 93: the non-touch check above passes for pips
  // placed anywhere far from the corner, so pin them to the face itself.
  test('A1: every pip lies on the face, and face 1 is the centre', () {
    for (final double side in _dieSides) {
      final Size size = Size.square(side);
      final double r = pipRadiusFor(size);
      final Rect face = (Offset.zero & size).deflate(r);
      for (int value = 1; value <= 6; value++) {
        for (final Offset p in pipCentresFor(value, size)) {
          expect(
            face.contains(p),
            isTrue,
            reason: 'A1: face $value pip $p must lie on the $side die face',
          );
        }
      }
      final List<Offset> one = pipCentresFor(1, size);
      expect(
        (one.single - size.center(Offset.zero)).distance,
        lessThanOrEqualTo(1e-9),
        reason: 'A1: face 1 at side $side is a single centre pip',
      );
    }
  });

  test('A1: pipCentresFor throws ArgumentError for faces outside 1..6', () {
    const Size size = Size.square(72);
    expect(() => pipCentresFor(0, size), throwsArgumentError);
    expect(() => pipCentresFor(7, size), throwsArgumentError);
    expect(() => pipCentresFor(-1, size), throwsArgumentError);
    const DeadMarkPainter painter = DeadMarkPainter();
    expect(painter, isNotNull);
  });
}

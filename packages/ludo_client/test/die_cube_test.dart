// Pure unit proof for lib/src/die_cube.dart (order 377, contract C-377 A1).
// Checks the four timing constants, the six face normals and their opposite
// pairs, the resting rotation for each face 1..6, and the range check on
// restingRotationFor.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/die_cube.dart';

const double _kTolerance = 1e-9;

(double, double, double) _transformNormal(
  Matrix4 matrix,
  (double, double, double) normal,
) {
  final (double nx, double ny, double nz) = normal;
  final double rx =
      matrix.entry(0, 0) * nx +
      matrix.entry(0, 1) * ny +
      matrix.entry(0, 2) * nz +
      matrix.entry(0, 3);
  final double ry =
      matrix.entry(1, 0) * nx +
      matrix.entry(1, 1) * ny +
      matrix.entry(1, 2) * nz +
      matrix.entry(1, 3);
  final double rz =
      matrix.entry(2, 0) * nx +
      matrix.entry(2, 1) * ny +
      matrix.entry(2, 2) * nz +
      matrix.entry(2, 3);
  return (rx, ry, rz);
}

void main() {
  test('A1: timing constants equal 700, 600, 200 and 250 ms', () {
    expect(kThrowTumble, const Duration(milliseconds: 700));
    expect(kThrowRest, const Duration(milliseconds: 600));
    expect(kThrowFade, const Duration(milliseconds: 200));
    expect(kThrowFast, const Duration(milliseconds: 250));
  });

  test('A1: kFaceNormals covers faces 1..6 and opposite faces sum to 7 and are '
      'negatives', () {
    expect(kFaceNormals.keys.toSet(), <int>{1, 2, 3, 4, 5, 6});
    for (int face = 1; face <= 6; face++) {
      final int opposite = 7 - face;
      expect(face + opposite, 7);
      final (double nx, double ny, double nz) = kFaceNormals[face]!;
      final (double ox, double oy, double oz) = kFaceNormals[opposite]!;
      expect(nx * nx + ny * ny + nz * nz, closeTo(1.0, _kTolerance));
      expect(nx, closeTo(-ox, _kTolerance));
      expect(ny, closeTo(-oy, _kTolerance));
      expect(nz, closeTo(-oz, _kTolerance));
    }
  });

  for (int face = 1; face <= 6; face++) {
    test('A1: restingRotationFor($face) maps kFaceNormals[$face] to (0, 0, 1) '
        'within 1e-9', () {
      final Matrix4 rotation = restingRotationFor(face);
      final (double rx, double ry, double rz) = _transformNormal(
        rotation,
        kFaceNormals[face]!,
      );
      expect(
        rx,
        closeTo(0.0, _kTolerance),
        reason: 'face $face rotated x normal component must be 0',
      );
      expect(
        ry,
        closeTo(0.0, _kTolerance),
        reason: 'face $face rotated y normal component must be 0',
      );
      expect(
        rz,
        closeTo(1.0, _kTolerance),
        reason: 'face $face rotated z normal component must be 1',
      );

      // Pure rotation: no translation and no perspective entries.
      expect(rotation.entry(0, 3), closeTo(0.0, _kTolerance));
      expect(rotation.entry(1, 3), closeTo(0.0, _kTolerance));
      expect(rotation.entry(2, 3), closeTo(0.0, _kTolerance));
      expect(rotation.entry(3, 0), closeTo(0.0, _kTolerance));
      expect(rotation.entry(3, 1), closeTo(0.0, _kTolerance));
      expect(rotation.entry(3, 2), closeTo(0.0, _kTolerance));
      expect(rotation.entry(3, 3), closeTo(1.0, _kTolerance));
    });
  }

  test('A1: restingRotationFor throws ArgumentError for faces 0 and 7', () {
    expect(() => restingRotationFor(0), throwsArgumentError);
    expect(() => restingRotationFor(7), throwsArgumentError);
  });
}

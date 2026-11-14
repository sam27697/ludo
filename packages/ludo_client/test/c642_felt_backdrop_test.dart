// C-642: the felt behind home and the lobby carries no grid.
//
// `FeltBackdrop` used to draw a 1 px line every 28 px in both directions, so
// the first two screens a friend sees read as graph paper. The wash and the
// radial light stay; the lines go. A grid line shows as a pixel column (or
// row) that is darker than both of its neighbours, so each case compares a
// pixel on every old line position with the pixels one step either side of
// it. The wash changes by well under one channel unit per pixel, so a
// smooth backdrop passes with room to spare and a line at alpha 0.045 over
// this paper (about 9 units) cannot.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/theme.dart';

const double _side = 336;
const double _oldStep = 28;
const int _tolerance = 2;

Future<(ByteData, int)> _render(WidgetTester tester) async {
  tester.view.physicalSize = const Size(_side, _side);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(child: FeltBackdrop(child: SizedBox.expand())),
    ),
  );
  await tester.pump();

  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byType(RepaintBoundary).first,
  );
  ByteData? pixels;
  int width = 0;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
    width = image.width;
    pixels = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  });
  return (pixels!, width);
}

List<int> _rgb(ByteData data, int width, int x, int y) {
  final int i = (y * width + x) * 4;
  return <int>[data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)];
}

int _gap(List<int> a, List<int> b) {
  var worst = 0;
  for (var c = 0; c < 3; c++) {
    final int d = (a[c] - b[c]).abs();
    if (d > worst) {
      worst = d;
    }
  }
  return worst;
}

void main() {
  testWidgets('no vertical line at any old grid column', (tester) async {
    final (ByteData data, int width) = await _render(tester);
    final List<String> misses = <String>[];
    for (double x = _oldStep; x < _side - 1; x += _oldStep) {
      for (final int y in <int>[20, 150, 300]) {
        final List<int> on = _rgb(data, width, x.toInt(), y);
        final List<int> left = _rgb(data, width, x.toInt() - 1, y);
        final List<int> right = _rgb(data, width, x.toInt() + 1, y);
        final int gap = _gap(on, left) > _gap(on, right)
            ? _gap(on, left)
            : _gap(on, right);
        if (gap > _tolerance) {
          misses.add('x=${x.toInt()} y=$y on=$on left=$left right=$right');
        }
      }
    }
    expect(
      misses,
      isEmpty,
      reason:
          'pixel columns that stand out from both neighbours by more '
          'than $_tolerance per channel (a grid line): ${misses.join('; ')}',
    );
  });

  testWidgets('no horizontal line at any old grid row', (tester) async {
    final (ByteData data, int width) = await _render(tester);
    final List<String> misses = <String>[];
    for (double y = _oldStep; y < _side - 1; y += _oldStep) {
      for (final int x in <int>[20, 150, 300]) {
        final List<int> on = _rgb(data, width, x, y.toInt());
        final List<int> above = _rgb(data, width, x, y.toInt() - 1);
        final List<int> below = _rgb(data, width, x, y.toInt() + 1);
        final int gap = _gap(on, above) > _gap(on, below)
            ? _gap(on, above)
            : _gap(on, below);
        if (gap > _tolerance) {
          misses.add('x=$x y=${y.toInt()} on=$on above=$above below=$below');
        }
      }
    }
    expect(
      misses,
      isEmpty,
      reason:
          'pixel rows that stand out from both neighbours by more '
          'than $_tolerance per channel (a grid line): ${misses.join('; ')}',
    );
  });

  testWidgets('the wash stays: the top of the felt is not the bottom', (
    tester,
  ) async {
    final (ByteData data, int width) = await _render(tester);
    final List<int> top = _rgb(data, width, 14, 4);
    final List<int> bottom = _rgb(data, width, 14, _side.toInt() - 5);
    expect(
      _gap(top, bottom),
      greaterThan(0),
      reason:
          'the backdrop must keep its vertical wash, not become a flat '
          'fill: top=$top bottom=$bottom',
    );
  });
}

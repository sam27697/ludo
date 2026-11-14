// Pixel proof of order 643 (work/ludo/orders/643-yard-record-reads-on-band.md),
// written from that contract's text alone. Another seat's queued rolls, drawn
// by SeatYardRecord in the yard row that straddles the panel edge, must read
// on a light pill even where the row falls on the solid seat band (X186, P3).
//
// Method. LudoBoard is mounted in a 450 x 450 physical viewport at device
// pixel ratio 1.0, so one cell (s) is 30 px, inside one RepaintBoundary that is
// rendered with toImage(pixelRatio: 1.0) and read as rawStraightRgba. The
// harness is copied from test/c639_board_art_test.dart, not imported. All four
// seats are in play, every token sits on the main track, no seatNames,
// turnSeat or seatDice are passed.
//
// Reading choices, reported rather than invented around:
//
//   1. The tray box is the rect of the RollTray widget found inside
//      `board-seat-record-<seat>`, read in global coordinates (the FittedBox
//      scale is applied by the render tree) and moved to board-local px by the
//      RepaintBoundary's own origin.
//   2. "Band side of the panel edge (beyond u/v 5.5 toward the track)" is
//      taken in view space. The yard row that touches the track is the
//      bottom row of a yard drawn on the top of the board (panel edge at
//      v 5.5, band below it) and the top row of a yard drawn on the bottom
//      (panel edge at v 0.5, band above it). The same test the board uses
//      (the viewed quadrant's origin row) says which, so a rotated view
//      probes the right side. The case name says which side was probed.
//   3. The probe's y is the middle of the part of the tray box that lies on
//      the band side of that edge.
//   4. The probe's x is the tray box's horizontal centre. With two faces the
//      tray is two 48dp slots and an 8dp gap, so that centre is in the gap
//      between the numerals; R0 checks it lies between the two numeral boxes
//      (the `game-roll-tray-face-<i>-<face>` keys) so R1 and R2 cannot be
//      red because the point hit a glyph.
//   5. "Two pending states" is read as two TrayDieState.plain entries (the
//      enum has no pending value; plain is the alive state).
//   6. The contract names seats 1 and 2 and mySeat 2 "as well"; the cases run
//      seats 1 and 2 for mySeat 0 and mySeat 2.
//   7. R0 is not in the contract. It checks the harness (record found, tray
//      found, the box straddles the panel edge, the probe is in the gap) and
//      is expected green before and after the change.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/roll_tray.dart';
import 'package:ludo_client/src/seat_die.dart';
import 'package:ludo_client/src/theme.dart';

const double _boardSide = 450;
const double _cell = _boardSide / 15;

/// R1: a light pill reads above this relative luminance.
const double _lightLuminance = 0.6;

/// R2: the probe must be at least this far from the seat colour, summed over
/// the three channels (0..255 each).
const double _seatColourDistance = 30;

const List<int> _allSeats = <int>[0, 1, 2, 3];

// ---------------------------------------------------------------------------
// Harness (copied from test/c639_board_art_test.dart).
// ---------------------------------------------------------------------------

Widget _pixelHarness({
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
  required int? mySeat,
  required SeatRollRecord seatRecord,
}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: RepaintBoundary(
        child: LudoBoard(
          tokens: tokens,
          seatsInPlay: seatsInPlay,
          mySeat: mySeat,
          seatRecord: seatRecord,
        ),
      ),
    ),
  );
}

void _pinViewportToBoard(WidgetTester tester) {
  tester.view.physicalSize = const Size(_boardSide, _boardSide);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Every token of every seat on the main track, none in a yard.
Map<int, List<int>> _allOnTrack() => <int, List<int>>{
  for (final int seat in _allSeats) seat: <int>[20, 20, 20, 20],
};

// ---------------------------------------------------------------------------
// Pixels and colour arithmetic.
// ---------------------------------------------------------------------------

class _Rgb {
  const _Rgb(this.r, this.g, this.b);

  factory _Rgb.of(Color c) => _Rgb(c.r * 255, c.g * 255, c.b * 255);

  final double r;
  final double g;
  final double b;

  String get hex {
    String two(double v) =>
        v.round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${two(r)}${two(g)}${two(b)}';
  }

  /// WCAG relative luminance, sRGB linearised.
  double get luminance {
    double lin(double v) {
      final double c = v / 255;
      return c <= 0.03928
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  }

  /// Sum over the three channels of the absolute difference to [other].
  double distanceTo(_Rgb other) =>
      (r - other.r).abs() + (g - other.g).abs() + (b - other.b).abs();
}

class _Frame {
  _Frame(this.width, this.height, this.data);

  final int width;
  final int height;
  final ByteData data;

  ({_Rgb rgb, int alpha, int x, int y}) at(Offset local) {
    final int x = local.dx.floor().clamp(0, width - 1);
    final int y = local.dy.floor().clamp(0, height - 1);
    final int i = (y * width + x) * 4;
    return (
      rgb: _Rgb(
        data.getUint8(i).toDouble(),
        data.getUint8(i + 1).toDouble(),
        data.getUint8(i + 2).toDouble(),
      ),
      alpha: data.getUint8(i + 3),
      x: x,
      y: y,
    );
  }
}

Future<_Frame> _capture(WidgetTester tester) async {
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byType(RepaintBoundary).first,
  );
  expect(
    boundary.size,
    const Size(_boardSide, _boardSide),
    reason:
        'harness: the board must fill the 450 x 450 viewport so that one '
        'cell is 30 px; got ${boundary.size}',
  );
  ui.Image? image;
  ByteData? pixels;
  await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: 1.0);
    pixels = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image = img;
  });
  return _Frame(image!.width, image!.height, pixels!);
}

// ---------------------------------------------------------------------------
// View-space geometry, through the public geometry functions.
// ---------------------------------------------------------------------------

/// The top-left cell of [seat]'s yard quadrant after the board is turned for
/// [quarters]: the bounding box of the four rotated corner cells.
({int col, int row}) _viewQuadrantOrigin(int seat, int quarters) {
  final BoardCell o = yardQuadrantOrigin(seat);
  final int last = yardQuadrantSide - 1;
  final List<BoardCell> corners = <BoardCell>[
    toView(BoardCell(o.col, o.row), quarters),
    toView(BoardCell(o.col + last, o.row), quarters),
    toView(BoardCell(o.col, o.row + last), quarters),
    toView(BoardCell(o.col + last, o.row + last), quarters),
  ];
  return (
    col: corners.map((BoardCell c) => c.col).reduce(math.min),
    row: corners.map((BoardCell c) => c.row).reduce(math.min),
  );
}

String _cells(Offset px) =>
    '(${(px.dx / _cell).toStringAsFixed(2)}, ${(px.dy / _cell).toStringAsFixed(2)}) cells';

// ---------------------------------------------------------------------------
// One scenario: a record for [seat] on a board viewed from [mySeat].
// ---------------------------------------------------------------------------

class _Scenario {
  _Scenario({
    required this.testName,
    required this.seat,
    required this.mySeat,
    required this.frame,
    required this.trayBox,
    required this.numeralBoxes,
    required this.yardOnTop,
    required this.panelEdgeY,
  });

  final String testName;
  final int seat;
  final int mySeat;
  final _Frame frame;

  /// The RollTray's own rect inside the record, board-local px.
  final Rect trayBox;

  /// The two numeral boxes, board-local px, in roll order.
  final List<Rect> numeralBoxes;

  /// True when the yard is drawn on the top of the board, so the band that
  /// the record falls on is below the panel edge.
  final bool yardOnTop;

  /// Board-local y of the panel edge that touches the track.
  final double panelEdgeY;

  String get side => yardOnTop
      ? 'yard on top, band below the panel edge'
      : 'yard on bottom, band above the panel edge';

  /// The part of the tray box on the band side of the panel edge, as a y
  /// range (empty when the box lies wholly on the panel).
  ({double from, double to}) get bandPart => yardOnTop
      ? (from: math.max(trayBox.top, panelEdgeY), to: trayBox.bottom)
      : (from: trayBox.top, to: math.min(trayBox.bottom, panelEdgeY));

  /// Reading choices 3 and 4: the box's horizontal centre, the middle of the
  /// band-side part of the box.
  Offset get probe =>
      Offset(trayBox.center.dx, (bandPart.from + bandPart.to) / 2);

  String get scenario =>
      'LudoBoard 450x450 dpr 1.0, seatsInPlay $_allSeats, mySeat $mySeat, '
      'every token at progress 20, seatRecord seat $seat faces [6, 6] '
      'states [plain, plain], $side';

  String reproduce() =>
      'Reproduce: cd packages/ludo_client && flutter test '
      "test/c643_yard_record_on_band_test.dart --plain-name '$testName'";

  String describe(({_Rgb rgb, int alpha, int x, int y}) px) =>
      'seat $seat, mySeat $mySeat, probe ${_cells(probe)} = px (${px.x}, '
      '${px.y}) in the tray box ${trayBox.left.toStringAsFixed(1)},'
      '${trayBox.top.toStringAsFixed(1)} to ${trayBox.right.toStringAsFixed(1)},'
      '${trayBox.bottom.toStringAsFixed(1)}, between the numerals, on the '
      'band side of the panel edge (y ${panelEdgeY.toStringAsFixed(1)})';
}

Future<_Scenario> _render(
  WidgetTester tester, {
  required String testName,
  required int seat,
  required int mySeat,
}) async {
  _pinViewportToBoard(tester);
  await tester.pumpWidget(
    _pixelHarness(
      tokens: _allOnTrack(),
      seatsInPlay: _allSeats,
      mySeat: mySeat,
      seatRecord: SeatRollRecord(
        seat: seat,
        faces: const <int>[6, 6],
        states: const <TrayDieState>[TrayDieState.plain, TrayDieState.plain],
        seatColor: LudoColors.seats[seat],
      ),
    ),
  );
  await tester.pump();

  final Finder record = find.byKey(Key('board-seat-record-$seat'));
  expect(
    record,
    findsOneWidget,
    reason:
        'C-643t $testName: expected one board-seat-record-$seat, none or '
        'several found. Reproduce: flutter test '
        "test/c643_yard_record_on_band_test.dart --plain-name '$testName'",
  );
  final Finder tray = find.descendant(
    of: record,
    matching: find.byType(RollTray),
  );
  expect(
    tray,
    findsOneWidget,
    reason:
        'C-643t $testName: expected one RollTray inside '
        'board-seat-record-$seat, none or several found.',
  );
  final Offset origin = tester.getTopLeft(find.byType(RepaintBoundary).first);
  Rect local(Rect global) => global.shift(-origin);
  final Rect trayBox = local(tester.getRect(tray));
  final List<Rect> numerals = <Rect>[
    for (int i = 0; i < 2; i++)
      local(tester.getRect(find.byKey(Key('game-roll-tray-face-$i-6')))),
  ];

  final int quarters = viewQuarters(mySeat);
  final ({int col, int row}) o = _viewQuadrantOrigin(seat, quarters);
  final bool yardOnTop = o.row == 0;
  final double panelEdgeY = yardOnTop
      ? (o.row + 5.5) * _cell
      : (o.row + 0.5) * _cell;

  final _Frame frame = await _capture(tester);
  return _Scenario(
    testName: testName,
    seat: seat,
    mySeat: mySeat,
    frame: frame,
    trayBox: trayBox,
    numeralBoxes: numerals,
    yardOnTop: yardOnTop,
    panelEdgeY: panelEdgeY,
  );
}

// ---------------------------------------------------------------------------
// The cases.
// ---------------------------------------------------------------------------

void main() {
  for (final int mySeat in <int>[0, 2]) {
    for (final int seat in <int>[1, 2]) {
      final String who = 'seat $seat record, mySeat $mySeat';

      // Not in the contract: the harness finds what it probes.
      testWidgets('R0 harness finds the tray and the gap, $who', (
        tester,
      ) async {
        final String name = 'R0 harness finds the tray and the gap, $who';
        final _Scenario s = await _render(
          tester,
          testName: name,
          seat: seat,
          mySeat: mySeat,
        );
        final Rect box = s.trayBox;
        final ({double from, double to}) band = s.bandPart;
        final List<String> misses = <String>[];
        if (box.isEmpty) {
          misses.add('the tray box is empty: $box');
        }
        if (!(band.to > band.from)) {
          misses.add(
            'the tray box ${box.top.toStringAsFixed(1)} to '
            '${box.bottom.toStringAsFixed(1)} has no part on the band side '
            'of the panel edge y ${s.panelEdgeY.toStringAsFixed(1)} '
            '(${s.side})',
          );
        }
        final Rect left = s.numeralBoxes[0];
        final Rect right = s.numeralBoxes[1];
        if (!(s.probe.dx > left.right && s.probe.dx < right.left)) {
          misses.add(
            'the probe x ${s.probe.dx.toStringAsFixed(1)} is not between '
            'the numeral boxes (${left.right.toStringAsFixed(1)} to '
            '${right.left.toStringAsFixed(1)})',
          );
        }
        if (!(s.probe.dx > box.left && s.probe.dx < box.right)) {
          misses.add('the probe x is outside the tray box');
        }
        if (misses.isNotEmpty) {
          fail(
            'C-643t $name: harness precondition failed.\n'
            '${misses.map((String m) => '  - $m').join('\n')}\n'
            'Scenario: ${s.scenario}. ${s.reproduce()}',
          );
        }
      });

      // R1: the pill reads light where the row falls on the band.
      testWidgets('R1 pill reads light on the band side, $who', (tester) async {
        final String name = 'R1 pill reads light on the band side, $who';
        final _Scenario s = await _render(
          tester,
          testName: name,
          seat: seat,
          mySeat: mySeat,
        );
        final px = s.frame.at(s.probe);
        final double lum = px.rgb.luminance;
        if (lum > _lightLuminance) {
          return;
        }
        fail(
          'C-643t $name: expected relative luminance above '
          '$_lightLuminance (a light pill) at ${s.describe(px)}; read '
          '${px.rgb.hex} alpha ${px.alpha}, luminance '
          '${lum.toStringAsFixed(3)} (seat colour '
          '${_Rgb.of(LudoColors.seats[seat]).hex}).\n'
          'Scenario: ${s.scenario}. ${s.reproduce()}',
        );
      });

      // R2: and it is not the seat colour.
      testWidgets('R2 pill is not the seat colour on the band side, $who', (
        tester,
      ) async {
        final String name =
            'R2 pill is not the seat colour on the band side, '
            '$who';
        final _Scenario s = await _render(
          tester,
          testName: name,
          seat: seat,
          mySeat: mySeat,
        );
        final px = s.frame.at(s.probe);
        final _Rgb seatColour = _Rgb.of(LudoColors.seats[seat]);
        final double dist = px.rgb.distanceTo(seatColour);
        if (dist >= _seatColourDistance) {
          return;
        }
        fail(
          'C-643t $name: expected a colour at least $_seatColourDistance '
          'summed channel units from the seat colour ${seatColour.hex} at '
          '${s.describe(px)}; read ${px.rgb.hex} alpha ${px.alpha}, '
          'distance ${dist.toStringAsFixed(1)}.\n'
          'Scenario: ${s.scenario}. ${s.reproduce()}',
        );
      });
    }
  }
}

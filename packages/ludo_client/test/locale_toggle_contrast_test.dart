// Order 058: the locale toggle used to render pure white text on a
// near-white background (measured off a real screenshot at a 1.05:1
// contrast ratio, against a WCAG AA minimum of 4.5:1 for normal text).
// This file resolves the toggle's actual rendered foreground and its own
// painted fill at test time and computes the WCAG contrast ratio from
// them, rather than asserting a colour constant, so the gate stays
// meaningful if the theme underneath changes again.
//
// C-276 took the toggle off the app bar. C-678 made the fill the gradient
// HomeGoldFrame paints behind a transparent button, so the check now
// composites the frame's highest-alpha fill over each home backdrop colour
// and measures the ink against the worst result. The floor is the same 4.5.
//
// To see the original failure, put
// `style: const TextStyle(color: Colors.white)` back on the toggle's `Text`
// in home_screen.dart and rerun it; the failure message reports the ratio
// it measured, which lands at the same ~1.05:1 the screenshot scan found.
//
// The last test in this file covers the smaller defect found in the same
// screenshot frame: the Arabic homeRoomCodeInvalid string was being clipped
// with an ellipsis instead of wrapping.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_style.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/home_flow.dart';

/// WCAG 2.1 relative luminance of an sRGB colour. Each channel is
/// gamma-decoded before the weighted sum; this is the formula the 4.5:1 / 3:1
/// AA thresholds are defined against, not an approximation of it.
double _relativeLuminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG contrast ratio between two colours: (L1 + 0.05) / (L2 + 0.05) with
/// L1 the lighter of the two relative luminances. Ranges from 1:1
/// (identical) to 21:1 (black on white).
double _contrastRatio(Color a, Color b) {
  final lumA = _relativeLuminance(a);
  final lumB = _relativeLuminance(b);
  final lighter = lumA > lumB ? lumA : lumB;
  final darker = lumA > lumB ? lumB : lumA;
  return (lighter + 0.05) / (darker + 0.05);
}

/// The frame [HomeGoldFrame] paints behind the locale toggle.
CustomPaint _toggleFrame(WidgetTester tester) {
  final Finder frame = find.ancestor(
    of: find.byKey(const Key('locale-toggle-button')),
    matching: find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is HomeGoldFramePainter,
    ),
  );
  expect(
    frame,
    findsWidgets,
    reason: 'locale-toggle-button has no HomeGoldFrame painter behind it',
  );
  return tester.widget<CustomPaint>(frame.first);
}

/// The backdrop colours the home page paints under the toggle: the
/// [FeltBackdrop] wash stops. The toggle sits at the top, but the check
/// takes the worst of all three so a change of wash cannot hide a failure.
const List<Color> _backdrops = <Color>[
  LudoColors.paperWashTop,
  LudoColors.paper,
  LudoColors.paperWashBottom,
];

/// The frame's worst fill under the label: the painter's own fill composited
/// over [backdrop], read back from pixels on the first row below the border
/// stroke, where the fill gradient is at its highest alpha.
Future<Color> _frameOver(
  WidgetTester tester,
  CustomPaint frame,
  Color backdrop,
) async {
  const int side = 48;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const Size size = Size(48, 48);
  canvas.drawRect(Offset.zero & size, Paint()..color = backdrop);
  frame.painter!.paint(canvas, size);
  final Color? sampled = await tester.runAsync<Color>(() async {
    final ui.Image image = await recorder.endRecording().toImage(side, side);
    final ByteData data = (await image.toByteData())!;
    const int x = side ~/ 2;
    const int y = 2;
    final int o = (y * side + x) * 4;
    return Color.fromARGB(
      255,
      data.getUint8(o),
      data.getUint8(o + 1),
      data.getUint8(o + 2),
    );
  });
  expect(
    sampled,
    isNot(backdrop),
    reason:
        'the frame painted nothing over backdrop $backdrop at the sampled '
        'row, so the contrast below would measure the bare page',
  );
  return sampled!;
}

/// Lowest contrast of [foreground] over the frame's fill on every backdrop.
Future<({double ratio, Color fill})> _worstContrast(
  WidgetTester tester,
  Color foreground,
) async {
  final CustomPaint frame = _toggleFrame(tester);
  double worst = double.infinity;
  Color worstFill = _backdrops.first;
  for (final Color backdrop in _backdrops) {
    final Color fill = await _frameOver(tester, frame, backdrop);
    final double ratio = _contrastRatio(foreground, fill);
    if (ratio < worst) {
      worst = ratio;
      worstFill = fill;
    }
  }
  return (ratio: worst, fill: worstFill);
}

/// The colour the locale toggle's label actually renders in: the resolved
/// style of its laid-out paragraph, which is what a screenshot scan (or a
/// person) reads, rather than a style plucked off the button's constructor.
Color _toggleForeground(WidgetTester tester) {
  final paragraph = tester.renderObject<RenderParagraph>(
    // The button now holds a translate icon (also a RichText) above the code
    // text, so read the paragraph of the Text, not of the icon.
    find.descendant(
      of: find.descendant(
        of: find.byKey(const Key('locale-toggle-button')),
        matching: find.byType(Text),
      ),
      matching: find.byType(RichText),
    ),
  );
  final color = paragraph.text.style?.color;
  if (color == null) {
    fail('locale toggle paragraph resolved no text colour at all');
  }
  return color;
}

void main() {
  testWidgets(
    'locale toggle text meets WCAG AA contrast (4.5:1) against the frame worst fill',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      final foreground = _toggleForeground(tester);
      final worst = await _worstContrast(tester, foreground);
      final background = worst.fill;
      final ratio = worst.ratio;

      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'locale toggle foreground $foreground on the frame worst fill '
            '$background measures $ratio:1, below the WCAG AA minimum of '
            '4.5:1 for normal text',
      );
    },
  );

  testWidgets(
    'locale toggle text meets WCAG AA contrast (4.5:1) against the frame worst '
    'fill in the Arabic locale too',
    (tester) async {
      await tester.pumpWidget(const LudoApp(initialLocale: Locale('ar')));
      await tester.pumpAndSettle();

      final foreground = _toggleForeground(tester);
      final worst = await _worstContrast(tester, foreground);
      final background = worst.fill;
      final ratio = worst.ratio;

      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'locale toggle foreground $foreground on the frame worst fill '
            '$background measures $ratio:1, below the WCAG AA minimum of '
            '4.5:1 for normal text',
      );
    },
  );

  testWidgets(
    'the invalid room code error wraps instead of being clipped with an '
    'ellipsis',
    (tester) async {
      await tester.pumpWidget(const LudoApp(initialLocale: Locale('ar')));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      final loc = AppLocalizations.of(context);

      // Order 701: a name first (X226), then the code entry in the join
      // sheet, where the invalid code line now shows.
      await enterName(tester, 'لاعب');
      await openCodeEntry(tester);
      await tester.enterText(
        find.byKey(const Key('room-code-field')),
        'inval#',
      );
      // Join is in the tree only for a full-length code (C-523 D3), so the
      // typed text is six characters that still fail isValidRoomCode.
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('join-room-button')));
      await tester.pumpAndSettle();

      final errorText = loc.homeRoomCodeInvalid;
      final finder = find.text(errorText);
      expect(
        finder,
        findsOneWidget,
        reason:
            'the full, untruncated error string should still be the '
            'text of the widget on screen even when it wraps to more than '
            'one line',
      );

      final paragraph = tester.renderObject<RenderParagraph>(finder);
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason:
            'homeRoomCodeInvalid ("$errorText") did not fit within its '
            'line limit and was clipped; see errorMaxLines on the room code '
            'field in home_screen.dart',
      );
    },
  );
}

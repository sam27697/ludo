// Order 058: the app bar's locale toggle used to render pure white text on
// the app bar's own near-white background (measured off a real screenshot at
// a 1.05:1 contrast ratio, against a WCAG AA minimum of 4.5:1 for normal
// text). This file resolves the toggle's actual rendered foreground and the
// app bar's actual rendered background at test time and computes the WCAG
// contrast ratio from them, rather than asserting a colour constant, so the
// gate stays meaningful if the theme underneath changes again.
//
// To see this test fail the way it failed for real, revert the fix (put
// `style: const TextStyle(color: Colors.white)` back on the toggle's `Text`
// in home_screen.dart) and rerun it; the failure message reports the ratio
// it measured, which lands at the same ~1.05:1 the screenshot scan found.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/app.dart';

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

/// The app bar's own painted background: the nearest opaque [Material]
/// ancestor of its content is what a person actually sees behind the toggle,
/// as opposed to [AppBar.backgroundColor] or the theme's idea of it, either
/// of which could be null and would still leave the question of what
/// actually got painted unanswered.
Color _appBarBackground(WidgetTester tester) {
  final materials = tester.widgetList<Material>(
    find.descendant(of: find.byType(AppBar), matching: find.byType(Material)),
  );
  for (final material in materials) {
    final color = material.color;
    if (color != null && color.a == 1.0) {
      return color;
    }
  }
  fail('no opaque Material found under the AppBar to read a background from');
}

/// The colour the locale toggle's label actually renders in: the resolved
/// style of its laid-out paragraph, which is what a screenshot scan (or a
/// person) reads, rather than a style plucked off the button's constructor.
Color _toggleForeground(WidgetTester tester) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: find.byKey(const Key('locale-toggle-button')),
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
    'locale toggle text meets WCAG AA contrast (4.5:1) against the app bar',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      final background = _appBarBackground(tester);
      final foreground = _toggleForeground(tester);
      final ratio = _contrastRatio(foreground, background);

      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'locale toggle foreground $foreground on app bar background '
            '$background measures $ratio:1, below the WCAG AA minimum of '
            '4.5:1 for normal text',
      );
    },
  );

  testWidgets(
    'locale toggle text meets WCAG AA contrast in the Arabic locale too',
    (tester) async {
      await tester.pumpWidget(const LudoApp(initialLocale: Locale('ar')));
      await tester.pumpAndSettle();

      final background = _appBarBackground(tester);
      final foreground = _toggleForeground(tester);
      final ratio = _contrastRatio(foreground, background);

      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'locale toggle foreground $foreground on app bar background '
            '$background measures $ratio:1, below the WCAG AA minimum of '
            '4.5:1 for normal text',
      );
    },
  );
}

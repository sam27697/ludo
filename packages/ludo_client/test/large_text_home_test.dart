// Measurement for X54 (ludo-tester, order 349, run 89). HomeScreen's
// last-table chip (`_LastTableChip`, lib/src/home_screen.dart:1655) paints
// "<name> · <seats>" as one Text, maxLines: 1, ellipsis, at the ambient
// system text scale. No implementation exists or is ordered; this test is
// the measurement a contract may be written from. It may go red; it does
// not merge alone.
//
// Font loading and the RenderParagraph measurement plumbing
// (_loadAppFonts, _paragraphOf, _layoutMaxWidth, _painterFor) are copied,
// not imported, from test/large_text_fit_test.dart. The ambient
// MediaQuery textScaler override through MaterialApp.builder is the same
// technique that file's own _harness uses.
//
// Session-memory seeding (SharedPreferences.setMockInitialValues, then
// SessionMemory.recordSuccessfulCreate) is copied from
// test/home_chip_craft_test.dart, the file that already measures this
// same chip's ellipsis behaviour at the default text scale. That file
// seeds a 2-seat table; this file seeds the same seat count, so a case
// here is comparable to that file's own green cases rather than to an
// untested seat count invented for this file.
//
// "its width and the width of the chip's parent" (the order's own
// wording) is ambiguous between (a) the RenderParagraph's own rendered
// width versus the layout width it was given, the two quantities
// test/large_text_fit_test.dart itself reports side by side as
// `painterSize` and `width`, and (b) the literal render-tree parent of
// the keyed chip widget, which in lib/src/home_screen.dart is the Center
// wrapping Semantics wrapping the keyed DecoratedBox. This file reports
// all of them, separately labelled, rather than guessing which one the
// order meant: paragraphWidth (painted/measured), paragraphMaxWidth (the
// layout bound passed to the paragraph), and parentWidth (the Center
// ancestor's own rendered width). See the final report for this flagged
// as an ambiguity.
//
// One mount per case: a fresh HomeScreen, freshly seeded session memory,
// real fonts, one surface size, one text scale, one locale.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;
import 'package:shared_preferences/shared_preferences.dart';

const Key _chipKey = Key('home-last-table-chip');

// The order's own name. Matches test/large_text_fit_test.dart's and
// test/header_fits_test.dart's "Karim12345" case, a 10-character name.
const String _lastTableName = 'Karim12345';

// test/home_chip_craft_test.dart's own seat count for this same chip.
const int _lastTableSeats = 2;

const List<Size> _sizes = <Size>[Size(360, 640), Size(411, 704)];
const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

RoomController _unusedController() {
  return RoomController(
    serverUrl: Uri.parse('wss://large-text-home-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'large_text_home_test: connector must not open a transport',
      );
    },
  );
}

Future<void> _seedLastTable() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await SessionMemory.recordSuccessfulCreate(
    name: _lastTableName,
    seats: _lastTableSeats,
  );
}

Widget _harness({required Locale locale, required double textScale}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      );
    },
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: _unusedController,
    ),
  );
}

/// Mounts Home at [size], locale and scale, reset before the test returns
/// (test/large_text_fit_test.dart's own `_phone` precedent). No
/// RoomController is kept here (unlike that file's GameScreen mounts):
/// HomeScreen never owns a socket until Create or Join is tapped, which
/// this file never does.
Future<void> _mountHome(
  WidgetTester tester, {
  required Size size,
  required Locale locale,
  required double textScale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  try {
    await tester.pumpWidget(_harness(locale: locale, textScale: textScale));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  } finally {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

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

  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

// ---------------------------------------------------------------------------
// Measurement plumbing, copied from test/large_text_fit_test.dart's own
// `_paragraphOf` / `_layoutMaxWidth` / `_painterFor`.
// ---------------------------------------------------------------------------

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

RenderParagraph _paragraphOf(WidgetTester tester, Finder textFinder) {
  final Finder rich = find.descendant(
    of: textFinder,
    matching: find.byType(RichText),
  );
  return tester.renderObject<RenderParagraph>(rich);
}

/// RenderParagraph's own rule: unbounded unless it wraps or ellipsizes.
double _layoutMaxWidth(RenderParagraph paragraph) {
  final bool wraps =
      paragraph.softWrap || paragraph.overflow == TextOverflow.ellipsis;
  return wraps ? paragraph.constraints.maxWidth : double.infinity;
}

/// A fresh TextPainter from [paragraph]'s own resolved span, direction,
/// scaler and maxLines, laid out at [paragraph]'s own rendered width
/// (`_layoutMaxWidth`). Disposed by the caller.
TextPainter _painterFor(RenderParagraph paragraph) {
  final TextPainter painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
    ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '…' : null,
  );
  painter.layout(
    minWidth: paragraph.constraints.minWidth,
    maxWidth: _layoutMaxWidth(paragraph),
  );
  return painter;
}

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

/// Runs the X54 measurement against the mounted tree and prints one CASE
/// line. Never throws: a missing or malformed chip is itself the finding,
/// appended to the returned list, the same way
/// test/large_text_fit_test.dart's own `_checkCase` works.
List<String> _checkCase(WidgetTester tester, {required String label}) {
  final List<String> reds = <String>[];

  final Finder chipFinder = find.byKey(_chipKey);
  if (!tester.any(chipFinder)) {
    reds.add('$label: home-last-table-chip must be on screen, found none');
    return reds;
  }

  final Finder textFinder = find.descendant(
    of: chipFinder,
    matching: find.byType(Text),
  );
  final int textCount = tester.widgetList(textFinder).length;
  if (textCount != 1) {
    reds.add(
      '$label: home-last-table-chip must hold exactly one Text, found '
      '$textCount',
    );
    return reds;
  }

  final Finder parentFinder = find.ancestor(
    of: chipFinder,
    matching: find.byType(Center),
  );
  if (!tester.any(parentFinder)) {
    reds.add(
      '$label: home-last-table-chip must have a Center ancestor to '
      'measure as its parent (lib/src/home_screen.dart wraps '
      '_LastTableChip in Center), found none',
    );
    return reds;
  }

  final String shownText = _textOf(tester.widget<Text>(textFinder));
  final RenderParagraph paragraph = _paragraphOf(tester, textFinder);
  final TextPainter painter = _painterFor(paragraph);
  final double parentWidth = tester.getSize(parentFinder.first).width;
  final double chipWidth = tester.getSize(chipFinder).width;
  final double? styleFontSize = paragraph.text.style?.fontSize;
  final double paintedFontSize = styleFontSize == null
      ? 0
      : paragraph.textScaler.scale(styleFontSize);

  try {
    _print(
      'CASE $label text="$shownText" '
      'ellipsized=${painter.didExceedMaxLines} '
      'liveEllipsized=${paragraph.didExceedMaxLines} '
      'fontSize=${paintedFontSize.toStringAsFixed(2)} '
      'paragraphWidth=${painter.size.width.toStringAsFixed(1)} '
      'paragraphMaxWidth=${paragraph.constraints.maxWidth.toStringAsFixed(1)} '
      'parentWidth=${parentWidth.toStringAsFixed(1)} '
      'chipWidth=${chipWidth.toStringAsFixed(1)}',
    );
    if (painter.didExceedMaxLines) {
      reds.add(
        '$label: home-last-table-chip text "$shownText" is cut '
        '(ellipsized) at paragraph width '
        '${paragraph.constraints.maxWidth.toStringAsFixed(1)} '
        '(TextPainter.didExceedMaxLines=true)',
      );
    }
  } finally {
    painter.dispose();
  }

  return reds;
}

void main() {
  setUpAll(_loadAppFonts);

  for (final Size size in _sizes) {
    final String sizeLabel = '${size.width.toInt()}x${size.height.toInt()}';

    for (final double scale in _scales) {
      final String scaleLabel = scale.toStringAsFixed(1);

      for (final Locale locale in _locales) {
        final String code = locale.languageCode;
        final String label = '$sizeLabel $code scale $scaleLabel';

        testWidgets('$label: home-last-table-chip', (tester) async {
          await _seedLastTable();
          final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
          final FlutterExceptionHandler? previous = FlutterError.onError;
          FlutterError.onError = captured.add;
          final List<String> reds = <String>[];
          try {
            await _mountHome(
              tester,
              size: size,
              locale: locale,
              textScale: scale,
            );
            reds.addAll(_checkCase(tester, label: label));
          } finally {
            FlutterError.onError = previous;
          }
          if (captured.isNotEmpty) {
            reds.insert(
              0,
              '$label: expected no FlutterError during mount/pump, got '
              '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' | ')}',
            );
          }
          expect(reds, isEmpty, reason: reds.join('\n'));
        });
      }
    }
  }
}

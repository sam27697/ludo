// C-299. The winner card's four stat tiles, each value and each label, on a
// 360x640 logical surface (physical size with devicePixelRatio 1, reset in
// the test body). en and ar, text scale 1.0 and 1.3. One mount per locale
// and scale.
//
// EndCard is mounted inside buildAppTheme so the real text styles apply.
// The surface padding is the one GameScreen._gameOverBody already puts
// around the card (EdgeInsets.all(kSpace4)): that is the width a 360dp
// screen gives the row. Fonts are Poppins and Noto Sans Arabic, loaded
// the same way test/header_fits_test.dart loads them.
//
// RenderParagraph on this SDK has no computeLineMetrics. The line count
// is TextPainter.computeLineMetrics on a painter given the paragraph's
// own span, scaler, maxLines and the width the paragraph actually laid
// out (infinite when softWrap is off and overflow is not ellipsis, which
// is RenderParagraph's own rule). didExceedMaxLines is read off the
// RenderParagraph.
//
// Label height at scale 1.0 is _paintedLineHeight (the first line's
// metric times the paragraph's paint-transform Y scale) over
// _unboundedLineHeight (TextPainter of the same resolved style, no width
// bound). The celebration is 1200ms, so pumps stay bounded.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/game_stats.dart';
import 'package:ludo_client/src/theme.dart'
    show LudoColors, buildAppTheme, kSpace4;

const Size _phoneSize = Size(360, 640);

const Key _winKey = Key('end-card-win');

// The recording's four numbers. timesCaptured is not drawn on a tile.
const GameStats _completeStats = GameStats(
  rolls: 50,
  sixes: 32,
  capturesMade: 1,
  timesCaptured: 0,
  tokensHome: 4,
  complete: true,
);

const GameStats _gapStats = GameStats(
  rolls: 50,
  sixes: 32,
  capturesMade: 1,
  timesCaptured: 0,
  tokensHome: 4,
  complete: false,
);

const List<String> _tileKeyNames = <String>[
  'end-card-stat-rolls',
  'end-card-stat-sixes',
  'end-card-stat-captures',
  'end-card-stat-home',
];

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

Widget _harness({
  required Locale locale,
  required double textScale,
  required GameStats stats,
}) {
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
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(kSpace4),
        child: EndCard(
          mySeat: 0,
          winnerSeat: 0,
          winnerName: 'Sam',
          seatColors: LudoColors.seats,
          stats: stats,
          verifyUrl: 'https://end-card-labels-fit.invalid/verify',
          onVerify: () {},
          onNewTable: () {},
          onRematch: () {},
        ),
      ),
    ),
  );
}

/// 360x640, reset before the test returns.
Future<void> _onPhone(WidgetTester tester, Future<void> Function() body) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1.0;
  try {
    await body();
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  }
}

Future<void> _pumpCard(WidgetTester tester, Widget harness) async {
  await tester.pumpWidget(harness);
  await tester.pump();
  // _Celebration's burst is 1200ms. One bounded pump runs it out.
  await tester.pump(const Duration(milliseconds: 1200));
}

String _scaleLabel(double scale) => scale.toStringAsFixed(1);

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

Finder _textFinder(String keyName, String value) {
  return find.descendant(
    of: find.byKey(Key(keyName)),
    matching: find.byWidgetPredicate(
      (Widget widget) => widget is Text && _textOf(widget) == value,
    ),
  );
}

RenderParagraph _paragraphOf(WidgetTester tester, Finder textFinder) {
  final Finder rich = find.descendant(
    of: textFinder,
    matching: find.byType(RichText),
  );
  expect(rich, findsOneWidget);
  return tester.renderObject<RenderParagraph>(rich);
}

double _layoutMaxWidth(RenderParagraph paragraph) {
  final bool wraps =
      paragraph.softWrap || paragraph.overflow == TextOverflow.ellipsis;
  return wraps ? paragraph.constraints.maxWidth : double.infinity;
}

TextPainter _painterFor(RenderParagraph paragraph, {required bool unbounded}) {
  return TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: unbounded ? null : paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
    ellipsis: !unbounded && paragraph.overflow == TextOverflow.ellipsis
        ? '\u2026'
        : null,
  );
}

/// Line count of the paragraph as laid out, via TextPainter.computeLineMetrics.
int _lineCount(RenderParagraph paragraph) {
  final TextPainter painter = _painterFor(paragraph, unbounded: false);
  try {
    painter.layout(
      minWidth: paragraph.constraints.minWidth,
      maxWidth: _layoutMaxWidth(paragraph),
    );
    return painter.computeLineMetrics().length;
  } finally {
    painter.dispose();
  }
}

/// Height of the first laid-out line, times the Y scale of the paint
/// transform (a FittedBox scaleDown shows up here; the line metric itself
/// does not).
double _paintedLineHeight(RenderParagraph paragraph) {
  final TextPainter painter = _painterFor(paragraph, unbounded: false);
  final double lineHeight;
  try {
    painter.layout(
      minWidth: paragraph.constraints.minWidth,
      maxWidth: _layoutMaxWidth(paragraph),
    );
    lineHeight = painter.computeLineMetrics().first.height;
  } finally {
    painter.dispose();
  }
  final double layoutHeight = paragraph.size.height;
  if (layoutHeight == 0) {
    return lineHeight;
  }
  final double top = paragraph.localToGlobal(Offset.zero).dy;
  final double bottom = paragraph.localToGlobal(Offset(0, layoutHeight)).dy;
  final double scaleY = (bottom - top).abs() / layoutHeight;
  return lineHeight * scaleY;
}

/// Height of the same string in one line of the same resolved style, with
/// no width bound. TextPainter, the loaded font, the paragraph's scaler.
double _unboundedLineHeight(RenderParagraph paragraph) {
  final TextPainter painter = _painterFor(paragraph, unbounded: true);
  try {
    painter.layout();
    return painter.computeLineMetrics().single.height;
  } finally {
    painter.dispose();
  }
}

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

void main() {
  setUpAll(_loadAppFonts);

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final double scale in const <double>[1.0, 1.3]) {
      final String code = locale.languageCode;
      final String scaleLabel = _scaleLabel(scale);
      final String heightClause = scale == 1.0
          ? ', labels at least 85% of the unshrunk line'
          : '';

      testWidgets(
        '$code text scale $scaleLabel: each stat text is one line$heightClause',
        (WidgetTester tester) async {
          await _onPhone(tester, () async {
            await _pumpCard(
              tester,
              _harness(locale: locale, textScale: scale, stats: _completeStats),
            );

            expect(
              find.byKey(_winKey),
              findsOneWidget,
              reason:
                  '$code scale $scaleLabel: end-card-win must be the card '
                  'under test',
            );

            final AppLocalizations loc = AppLocalizations.of(
              tester.element(find.byType(EndCard)),
            );
            final List<({String keyName, String value, String label})> tiles =
                <({String keyName, String value, String label})>[
                  (
                    keyName: 'end-card-stat-rolls',
                    value: '${_completeStats.rolls}',
                    label: loc.endStatRolls,
                  ),
                  (
                    keyName: 'end-card-stat-sixes',
                    value: '${_completeStats.sixes}',
                    label: loc.endStatSixes,
                  ),
                  (
                    keyName: 'end-card-stat-captures',
                    value: '${_completeStats.capturesMade}',
                    label: loc.endStatCaptures,
                  ),
                  (
                    keyName: 'end-card-stat-home',
                    value: '${_completeStats.tokensHome}',
                    label: loc.endStatHome,
                  ),
                ];

            final StringBuffer widths = StringBuffer();
            for (final String keyName in _tileKeyNames) {
              final Size size = tester.getSize(find.byKey(Key(keyName)));
              widths.write('$keyName=${size.width.toStringAsFixed(1)} ');
            }
            _print('TILE $code scale $scaleLabel $widths');

            final RenderParagraph sample = _paragraphOf(
              tester,
              _textFinder(tiles.first.keyName, tiles.first.label),
            );
            final TextStyle? style = sample.text.style;
            _print(
              'FONT $code scale $scaleLabel family=${style?.fontFamily} '
              'fallback=${style?.fontFamilyFallback} '
              'fontSize=${style?.fontSize}',
            );
            expect(
              style?.fontFamily,
              'Poppins',
              reason:
                  '$code scale $scaleLabel: stat label must resolve to '
                  'Poppins, not the test font',
            );
            expect(
              style?.fontFamilyFallback,
              contains('Noto Sans Arabic'),
              reason:
                  '$code scale $scaleLabel: stat label must fall back to '
                  'Noto Sans Arabic',
            );

            final List<String> reds = <String>[];
            for (final ({String keyName, String value, String label}) tile
                in tiles) {
              for (final (String role, String text) in <(String, String)>[
                ('value', tile.value),
                ('label', tile.label),
              ]) {
                final String where =
                    '$code scale $scaleLabel ${tile.keyName} $role "$text"';
                final Finder textFinder = _textFinder(tile.keyName, text);
                expect(
                  textFinder,
                  findsOneWidget,
                  reason: '$where: that Text must be on the tile',
                );
                final RenderParagraph paragraph = _paragraphOf(
                  tester,
                  textFinder,
                );
                final int lines = _lineCount(paragraph);
                final bool exceeded = paragraph.didExceedMaxLines;
                _print('CASE $where lines=$lines didExceedMaxLines=$exceeded');
                if (lines != 1 || exceeded) {
                  reds.add(
                    '$where has $lines lines, didExceedMaxLines=$exceeded',
                  );
                }
                if (scale == 1.0 && role == 'label') {
                  final double painted = _paintedLineHeight(paragraph);
                  final double reference = _unboundedLineHeight(paragraph);
                  final double ratio = reference == 0 ? 0 : painted / reference;
                  _print(
                    'HEIGHT $where painted=${painted.toStringAsFixed(2)} '
                    'reference=${reference.toStringAsFixed(2)} '
                    'ratio=${ratio.toStringAsFixed(3)} '
                    'method=_paintedLineHeight/_unboundedLineHeight',
                  );
                  if (reference == 0 || painted < reference * 0.85) {
                    reds.add(
                      '$where painted height ${painted.toStringAsFixed(2)} '
                      'is under 85% of unbounded '
                      '${reference.toStringAsFixed(2)} '
                      '(method _paintedLineHeight / _unboundedLineHeight)',
                    );
                  }
                }
              }
            }
            expect(reds, isEmpty, reason: reds.join('\n'));
          });
        },
      );
    }
  }

  testWidgets(
    'complete false shows end-card-stat-home and not the other three',
    (WidgetTester tester) async {
      await _onPhone(tester, () async {
        await _pumpCard(
          tester,
          _harness(
            locale: const Locale('en'),
            textScale: 1.0,
            stats: _gapStats,
          ),
        );
        expect(
          find.byKey(_winKey),
          findsOneWidget,
          reason:
              'en scale 1.0 complete false: end-card-win must be the card '
              'under test',
        );
        final List<String> reds = <String>[];
        for (final String keyName in _tileKeyNames) {
          final int found = find.byKey(Key(keyName)).evaluate().length;
          final bool want = keyName == 'end-card-stat-home';
          _print(
            'CASE en scale 1.0 complete false $keyName '
            'found=$found want=${want ? 1 : 0}',
          );
          if ((found == 1) != want) {
            reds.add(
              'en scale 1.0 complete false: $keyName found=$found, '
              'expected ${want ? 1 : 0}',
            );
          }
        }
        expect(reds, isEmpty, reason: reds.join('\n'));
      });
    },
  );
}

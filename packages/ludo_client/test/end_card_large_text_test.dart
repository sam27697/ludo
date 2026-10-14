// C-343, order 344. Proves contract rules 1 and 2 on the end card at large
// system text scale: a name never breaks inside itself (rule 1), and the
// four stat tiles keep a gutter between their labels (rule 2).
//
// Surface and font loading follow test/end_card_labels_fit_test.dart.
// Ambient text scale is applied through MediaQuery the way
// test/large_text_fit_test.dart does it. Helpers are copied from both
// files rather than imported, per the order.
//
// Names: Karim12345 (the player, mySeat 0) and Samantha12 (the other seat,
// seat 1), both 10 characters, matching the screenshot that opened C-343.
//
// Rule 1 needs a name actually present in the game-screen-winner title.
// _nameHighlightSpans only puts a name into that title on the loser card
// (loc.endLoseTitle(name)); the winner card's own title is loc.endWinTitle,
// "You won!" in English, with no name placeholder in the ARB source
// (lib/l10n/app_en.arb line 405, lib/l10n/app_ar.arb line 86) and order
// 343 is not allowed to touch any ARB string. So on the winner card there
// is no name span under game-screen-winner to test rule 1 against; each
// winner-card case below confirms that and prints why, rather than
// asserting on a span that cannot exist, and still runs rule 2 in full
// (the stat row is on both cards alike). See the final report for this
// flagged ambiguity against the order's matrix wording.

import 'dart:math' as math;

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
    show LudoColors, buildAppTheme, kSpace2, kSpace4;

const Size _phoneSize = Size(360, 640);

const Key _winnerTitleKey = Key('game-screen-winner');

const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const double _minTitleFontSize = 20;

const List<String> _tileKeyNames = <String>[
  'end-card-stat-rolls',
  'end-card-stat-sixes',
  'end-card-stat-captures',
  'end-card-stat-home',
];

// The recording's four numbers, same as test/end_card_labels_fit_test.dart's
// own _completeStats: stats complete, four tiles.
const GameStats _completeStats = GameStats(
  rolls: 50,
  sixes: 32,
  capturesMade: 1,
  timesCaptured: 0,
  tokensHome: 4,
  complete: true,
);

enum _Card { winner, loser }

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

// Winner card: mySeat 0 wins. Loser card: mySeat 0 loses to seat 1
// (Samantha12), the exact shape of the screenshot that opened C-343.
Widget _harness({
  required Locale locale,
  required double textScale,
  required _Card card,
}) {
  final int winnerSeat = card == _Card.winner ? 0 : 1;
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
          winnerSeat: winnerSeat,
          winnerName: winnerSeat == 0 ? _mySeatName : _otherSeatName,
          seatColors: LudoColors.seats,
          stats: _completeStats,
          verifyUrl: 'https://end-card-large-text.invalid/verify',
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

/// The leaf [TextSpan] under [root] whose own text is exactly [name].
/// _nameHighlightSpans keeps the name as its own span (order 343's own
/// interface constraint); null when no such leaf exists (the winner
/// card's title, which carries no name at all).
TextSpan? _findNameSpan(InlineSpan root, String name) {
  TextSpan? found;
  root.visitChildren((InlineSpan span) {
    if (span is TextSpan && span.text == name) {
      found = span;
      return false;
    }
    return true;
  });
  return found;
}

/// Global rect of [paragraph] after every ancestor transform, including a
/// FittedBox scale-down.
Rect _globalRect(RenderParagraph paragraph) {
  return MatrixUtils.transformRect(
    paragraph.getTransformTo(null),
    Rect.fromLTWH(0, 0, paragraph.size.width, paragraph.size.height),
  );
}

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

void main() {
  setUpAll(_loadAppFonts);

  for (final double scale in const <double>[1.0, 1.3, 2.0]) {
    final String scaleLabel = scale.toStringAsFixed(1);

    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      final String code = locale.languageCode;

      for (final _Card card in _Card.values) {
        final String cardLabel = card == _Card.winner ? 'winner' : 'loser';
        final String label = '$code scale $scaleLabel $cardLabel card';

        testWidgets(label, (WidgetTester tester) async {
          final List<String> reds = <String>[];

          await _onPhone(tester, () async {
            await _pumpCard(
              tester,
              _harness(locale: locale, textScale: scale, card: card),
            );

            expect(
              find.byKey(_winnerTitleKey),
              findsOneWidget,
              reason: '$label: game-screen-winner must be on the card',
            );

            // ---- rule 1 -------------------------------------------------
            final RenderParagraph titleParagraph = _paragraphOf(
              tester,
              find.byKey(_winnerTitleKey),
            );
            final String name = card == _Card.winner
                ? _mySeatName
                : _otherSeatName;
            final TextSpan? nameSpan = _findNameSpan(titleParagraph.text, name);

            if (nameSpan == null) {
              _print(
                'CASE $label rule1 nameSpan=absent name="$name" '
                'plainText="${titleParagraph.text.toPlainText()}" '
                'reason=endWinTitle carries no name placeholder (ARB '
                'frozen, lib/l10n/app_en.arb:405)',
              );
              if (card == _Card.loser) {
                reds.add(
                  '$label: rule 1 expected a "$name" span under '
                  'game-screen-winner on the loser card (endLoseTitle), '
                  'found none in '
                  '"${titleParagraph.text.toPlainText()}"',
                );
              }
            } else {
              final String plainText = titleParagraph.text.toPlainText();
              final int start = plainText.indexOf(name);
              expect(
                start,
                greaterThanOrEqualTo(0),
                reason:
                    '$label: "$name" must appear verbatim in the title '
                    'plain text "$plainText"',
              );
              final List<TextBox> boxes = titleParagraph.getBoxesForSelection(
                TextSelection(
                  baseOffset: start,
                  extentOffset: start + name.length,
                ),
              );
              expect(
                boxes,
                isNotEmpty,
                reason: '$label: the name span must paint at least one box',
              );
              final double firstTop = boxes.first.top;
              final double maxTopDelta = boxes
                  .map((TextBox b) => (b.top - firstTop).abs())
                  .fold<double>(0, math.max);

              final double? styleFontSize = nameSpan.style?.fontSize;
              final double scaledFontSize = styleFontSize == null
                  ? 0
                  : titleParagraph.textScaler.scale(styleFontSize);

              _print(
                'CASE $label rule1 name="$name" boxes=${boxes.length} '
                'maxTopDelta=${maxTopDelta.toStringAsFixed(2)} '
                'styleFontSize=${styleFontSize?.toStringAsFixed(2)} '
                'scaledFontSize=${scaledFontSize.toStringAsFixed(2)}',
              );

              if (maxTopDelta > 0.5) {
                reds.add(
                  '$label: rule 1 broke "$name" across lines, boxes top '
                  '${boxes.map((TextBox b) => b.top.toStringAsFixed(2)).join(', ')} '
                  '(max delta ${maxTopDelta.toStringAsFixed(2)} > 0.5)',
                );
              }
              if (styleFontSize == null) {
                reds.add(
                  '$label: rule 1 found no style/fontSize on the "$name" '
                  'span',
                );
              } else if (scaledFontSize < _minTitleFontSize - 0.01) {
                reds.add(
                  '$label: rule 1 title font at the name span scaled to '
                  '${scaledFontSize.toStringAsFixed(2)}, under '
                  '$_minTitleFontSize',
                );
              }
            }

            // ---- rule 2 -------------------------------------------------
            final AppLocalizations loc = AppLocalizations.of(
              tester.element(find.byType(EndCard)),
            );
            final List<String> tileLabels = <String>[
              loc.endStatRolls(_completeStats.rolls),
              loc.endStatSixes(_completeStats.sixes),
              loc.endStatCaptures(_completeStats.capturesMade),
              loc.endStatHome(_completeStats.tokensHome),
            ];

            final List<Rect> rects = <Rect>[];
            for (int i = 0; i < _tileKeyNames.length; i++) {
              final Finder finder = _textFinder(
                _tileKeyNames[i],
                tileLabels[i],
              );
              expect(
                finder,
                findsOneWidget,
                reason:
                    '$label: ${_tileKeyNames[i]} must carry the label '
                    '"${tileLabels[i]}"',
              );
              final RenderParagraph labelParagraph = _paragraphOf(
                tester,
                finder,
              );
              rects.add(_globalRect(labelParagraph));
            }

            final List<Rect> sorted = List<Rect>.of(rects)
              ..sort((Rect a, Rect b) => a.left.compareTo(b.left));
            final List<double> gaps = <double>[
              for (int i = 1; i < sorted.length; i++)
                sorted[i].left - sorted[i - 1].right,
            ];

            _print(
              'CASE $label rule2 rects=${sorted.map((Rect r) => '[${r.left.toStringAsFixed(1)},${r.right.toStringAsFixed(1)}]').join(' ')} '
              'gaps=${gaps.map((double g) => g.toStringAsFixed(2)).join(',')}',
            );

            for (int i = 0; i < gaps.length; i++) {
              if (gaps[i] < kSpace2 - 0.01) {
                reds.add(
                  '$label: rule 2 gap ${gaps[i].toStringAsFixed(2)} '
                  'between stat labels ${i + 1} and ${i + 2} (sorted by x) '
                  'is under kSpace2 ($kSpace2)',
                );
              }
            }
          });

          expect(reds, isEmpty, reason: reds.join('\n'));
        });
      }
    }
  }
}

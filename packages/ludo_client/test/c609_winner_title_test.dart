// C-609, order 609t. The winner's title reads on its card: gold fill under a
// dark gold-ink rim, drawn as two Text layers in one Stack, heard once.
//
// Contract (work/ludo/orders/609-winner-title-legible.md):
//   D1  LudoColors.goldInk = 0xFF695617, readable on paperElevated.
//   D2  game-screen-winner keeps LudoColors.gold as its fill. A second Text
//       with the same data, keyed game-screen-winner-outline, sits earlier in
//       the same Stack and carries a stroke foreground Paint (goldInk, round
//       join, width fontSize * 0.12). It is wrapped in ExcludeSemantics.
//   D3  nothing else moves: the celebration burst stays gold, the loser card
//       has no outline.
//
// Written from the contract, not from the client change. Surface, fonts and
// text scale follow test/end_card_large_text_test.dart; helpers are copied
// rather than imported.
//
// Reproduce a single scenario with
//   flutter test test/c609_winner_title_test.dart --plain-name '<label>'
// where <label> is the "locale=.. scale=.." text every failure repeats.
//
// Two readings the contract leaves open, both handled the same way: the
// outline test accepts the key on the Text itself or on the ExcludeSemantics
// that wraps it (it resolves the Text under the key), and the stroke width at
// a text scale other than 1.0 is accepted as 0.12 of either the style's
// fontSize or the scaled fontSize (a Paint width is not scaled by the text
// scaler on its own). Scale 1.0 pins the formula without ambiguity.

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
    show LudoColors, buildAppTheme, contrastRatio, kSpace4;

const Size _phoneSize = Size(360, 640);

const Key _fillKey = Key('game-screen-winner');
const Key _outlineKey = Key('game-screen-winner-outline');
const Key _celebrationKey = Key('end-card-celebration');

const Color _goldInkWanted = Color(0xFF695617);
const double _strokeFactor = 0.12;
const double _strokeSlop = 0.01;
const double _geometrySlop = 0.5;

const GameStats _stats = GameStats(
  rolls: 50,
  sixes: 32,
  capturesMade: 1,
  timesCaptured: 0,
  tokensHome: 4,
  complete: true,
);

enum _Card { winner, loser, spectator, ended }

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
  required _Card card,
  bool reducedMotion = false,
}) {
  final int? mySeat = card == _Card.spectator ? null : 0;
  final int? winnerSeat = switch (card) {
    _Card.winner => 0,
    _Card.loser => 1,
    _Card.spectator => 2,
    _Card.ended => null,
  };
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
        data: data.copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reducedMotion,
        ),
        child: child!,
      );
    },
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(kSpace4),
        child: EndCard(
          mySeat: mySeat,
          winnerSeat: winnerSeat,
          winnerName: winnerSeat == null ? null : 'Player$winnerSeat',
          seatColors: LudoColors.seats,
          stats: _stats,
          verifyUrl: 'https://c609.invalid/verify',
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

/// The celebration burst is 1200ms; one bounded pump runs it out.
Future<void> _pumpCard(WidgetTester tester, Widget harness) async {
  await tester.pumpWidget(harness);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1200));
}

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

/// The [Text] a key resolves to: the widget itself, or the single Text under
/// it when the key sits on a wrapper. Null when nothing is found.
Finder _textUnder(Key key) {
  final Finder keyed = find.byKey(key);
  if (keyed.evaluate().isEmpty) {
    return keyed;
  }
  final Widget widget = keyed.evaluate().first.widget;
  if (widget is Text) {
    return keyed;
  }
  return find.descendant(of: keyed, matching: find.byType(Text));
}

RenderParagraph _paragraph(WidgetTester tester, Finder text) {
  final Finder rich = find.descendant(
    of: text,
    matching: find.byType(RichText),
  );
  expect(rich, findsOneWidget);
  return tester.renderObject<RenderParagraph>(rich);
}

/// Global offset and size of a paragraph after every ancestor transform.
Rect _globalRect(RenderParagraph p) => MatrixUtils.transformRect(
  p.getTransformTo(null),
  Rect.fromLTWH(0, 0, p.size.width, p.size.height),
);

/// The nearest Stack ancestor of [element] and the index, among that Stack's
/// children, of the child subtree [element] sits in.
(Element, int)? _stackSlot(Element element) {
  Element? child = element;
  Element? stack;
  Element? cursor;
  element.visitAncestorElements((Element ancestor) {
    if (ancestor.widget is Stack) {
      stack = ancestor;
      cursor = child;
      return false;
    }
    child = ancestor;
    return true;
  });
  if (stack == null || cursor == null) {
    return null;
  }
  int index = -1;
  int i = 0;
  stack!.visitChildren((Element c) {
    if (identical(c, cursor)) {
      index = i;
    }
    i++;
  });
  return index < 0 ? null : (stack!, index);
}

int _semanticsNodesCarrying(SemanticsNode root, String needle) {
  int count = 0;
  void walk(SemanticsNode node) {
    final SemanticsData data = node.getSemanticsData();
    if (data.label.contains(needle) ||
        data.value.contains(needle) ||
        data.hint.contains(needle)) {
      count++;
    }
    node.visitChildren((SemanticsNode child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return count;
}

String _scenario(Locale locale, double scale, _Card card) =>
    'locale=${locale.languageCode} scale=${scale.toStringAsFixed(1)} '
    'card=${card.name}';

void main() {
  setUpAll(_loadAppFonts);

  // (a) D1: the ink exists, is the named colour, and reads on the card.
  group('goldInk (D1)', () {
    test('goldInk is 0xFF695617 and is not the gold fill', () {
      expect(
        LudoColors.goldInk,
        _goldInkWanted,
        reason:
            'D1: LudoColors.goldInk must be 0xFF695617, got '
            '0x${LudoColors.goldInk.toARGB32().toRadixString(16)}',
      );
      expect(
        LudoColors.goldInk,
        isNot(LudoColors.gold),
        reason: 'D1: the outline ink must differ from the gold fill',
      );
    });

    test('goldInk on paperElevated is at least 4.5:1', () {
      final double ratio = contrastRatio(
        LudoColors.goldInk,
        LudoColors.paperElevated,
      );
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'D1/P9: goldInk over paperElevated must reach 4.5:1, '
            'measured ${ratio.toStringAsFixed(2)}:1',
      );
    });

    test('gold stays 0xFFD4AF37 (P2, D3)', () {
      expect(
        LudoColors.gold,
        const Color(0xFFD4AF37),
        reason: 'D3: the gold fill must stay 0xFFD4AF37',
      );
    });
  });

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    final String code = locale.languageCode;

    // (b) the fill keeps gold; no foreground paint leaks onto it.
    testWidgets('fill is gold, fill layer has no foreground paint ($code)', (
      WidgetTester tester,
    ) async {
      const double scale = 1.0;
      final String where = _scenario(locale, scale, _Card.winner);
      await _onPhone(tester, () async {
        await _pumpCard(
          tester,
          _harness(locale: locale, textScale: scale, card: _Card.winner),
        );
        final Finder fill = find.byKey(_fillKey);
        expect(
          fill,
          findsOneWidget,
          reason: '$where: game-screen-winner must be on the winner card',
        );
        final Widget widget = fill.evaluate().single.widget;
        expect(
          widget,
          isA<Text>(),
          reason:
              '$where: game-screen-winner must stay on the visible fill Text, '
              'found ${widget.runtimeType}',
        );
        final RenderParagraph p = _paragraph(tester, fill);
        final TextStyle? style = p.text.style;
        expect(
          style?.color,
          LudoColors.gold,
          reason:
              '$where: fill colour expected LudoColors.gold, got '
              '${style?.color}',
        );
        expect(
          style?.foreground,
          isNull,
          reason:
              '$where: the fill layer must colour through `color`, not a '
              'foreground paint (that is the outline layer): '
              '${style?.foreground}',
        );
      });
    });

    // (c) the outline layer.
    for (final double scale in const <double>[1.0, 2.0]) {
      testWidgets('outline layer is a stroke Text in goldInk, '
          'before the fill (${_scenario(locale, scale, _Card.winner)})', (
        WidgetTester tester,
      ) async {
        final String where = _scenario(locale, scale, _Card.winner);
        await _onPhone(tester, () async {
          await _pumpCard(
            tester,
            _harness(locale: locale, textScale: scale, card: _Card.winner),
          );
          final Finder outlineKeyed = find.byKey(_outlineKey);
          expect(
            outlineKeyed,
            findsOneWidget,
            reason:
                '$where: expected exactly one widget keyed '
                'game-screen-winner-outline, found '
                '${outlineKeyed.evaluate().length}',
          );
          final Finder outline = _textUnder(_outlineKey);
          final Finder fill = find.byKey(_fillKey);
          expect(
            outline,
            findsOneWidget,
            reason:
                '$where: game-screen-winner-outline must be, or wrap, '
                'exactly one Text',
          );
          expect(fill, findsOneWidget);

          final Text outlineText = tester.widget<Text>(outline);
          final Text fillText = tester.widget<Text>(fill);
          expect(
            _textOf(outlineText),
            _textOf(fillText),
            reason:
                '$where: outline data "${_textOf(outlineText)}" must equal '
                'fill data "${_textOf(fillText)}"',
          );
          expect(_textOf(fillText), isNotEmpty);

          final TextStyle? os = _paragraph(tester, outline).text.style;
          final TextStyle? fs = _paragraph(tester, fill).text.style;
          final Paint? paint = os?.foreground;
          expect(
            paint,
            isNotNull,
            reason:
                '$where: outline style must carry a foreground Paint, '
                'style=$os',
          );
          expect(
            paint!.style,
            PaintingStyle.stroke,
            reason:
                '$where: outline paint style expected stroke, got '
                '${paint.style}',
          );
          expect(
            paint.color.toARGB32(),
            LudoColors.goldInk.toARGB32(),
            reason:
                '$where: outline paint colour expected goldInk '
                '(0xFF695617), got 0x${paint.color.toARGB32().toRadixString(16)}',
          );
          expect(
            paint.strokeJoin,
            StrokeJoin.round,
            reason:
                '$where: outline strokeJoin expected round, got '
                '${paint.strokeJoin}',
          );
          expect(
            os?.color,
            isNull,
            reason:
                'Flutter forbids both color and foreground; $where: '
                'outline style has color=${os?.color}',
          );

          final double styleSize = fs!.fontSize!;
          final double scaledSize = TextScaler.linear(scale).scale(styleSize);
          final double wantStyle = styleSize * _strokeFactor;
          final double wantScaled = scaledSize * _strokeFactor;
          final bool matchesStyle =
              (paint.strokeWidth - wantStyle).abs() <= _strokeSlop;
          final bool matchesScaled =
              (paint.strokeWidth - wantScaled).abs() <= _strokeSlop;
          if (scale == 1.0) {
            expect(
              matchesStyle,
              isTrue,
              reason:
                  '$where: strokeWidth expected 0.12 * fontSize '
                  '($styleSize) = ${wantStyle.toStringAsFixed(3)}, got '
                  '${paint.strokeWidth}',
            );
          } else {
            expect(
              matchesStyle || matchesScaled,
              isTrue,
              reason:
                  '$where: strokeWidth expected 0.12 * style fontSize '
                  '($styleSize) = ${wantStyle.toStringAsFixed(3)} or '
                  '0.12 * scaled fontSize ($scaledSize) = '
                  '${wantScaled.toStringAsFixed(3)}, got '
                  '${paint.strokeWidth}',
            );
          }

          // Same layout inputs on both layers.
          expect(os?.fontSize, fs.fontSize, reason: '$where: fontSize');
          expect(os?.fontWeight, fs.fontWeight, reason: '$where: weight');
          expect(os?.fontFamily, fs.fontFamily, reason: '$where: family');
          expect(os?.height, fs.height, reason: '$where: line height');
          expect(
            os?.letterSpacing,
            fs.letterSpacing,
            reason: '$where: letterSpacing',
          );
          expect(
            outlineText.textAlign,
            fillText.textAlign,
            reason: '$where: textAlign',
          );
          expect(
            outlineText.maxLines,
            fillText.maxLines,
            reason: '$where: maxLines',
          );
          expect(
            outlineText.overflow,
            fillText.overflow,
            reason: '$where: overflow',
          );
          expect(
            outlineText.textScaler,
            fillText.textScaler,
            reason: '$where: textScaler',
          );

          // Order: same Stack, outline earlier.
          final (Element, int)? outSlot = _stackSlot(outline.evaluate().first);
          final (Element, int)? fillSlot = _stackSlot(fill.evaluate().first);
          expect(
            outSlot,
            isNotNull,
            reason: '$where: outline has no Stack ancestor',
          );
          expect(
            fillSlot,
            isNotNull,
            reason: '$where: fill has no Stack ancestor',
          );
          expect(
            identical(outSlot!.$1, fillSlot!.$1),
            isTrue,
            reason:
                '$where: outline and fill must be children of one and the '
                'same Stack',
          );
          expect(
            outSlot.$2,
            lessThan(fillSlot.$2),
            reason:
                '$where: outline must paint before the fill: Stack child '
                'index outline=${outSlot.$2} fill=${fillSlot.$2}',
          );

          // The outline layer is excluded from semantics.
          expect(
            find.ancestor(of: outline, matching: find.byType(ExcludeSemantics)),
            findsWidgets,
            reason: '$where: outline must sit under an ExcludeSemantics',
          );
        });
      });
    }

    // (d) the two layers coincide exactly.
    for (final double scale in const <double>[1.0, 2.0]) {
      testWidgets('outline and fill boxes coincide '
          '(${_scenario(locale, scale, _Card.winner)})', (
        WidgetTester tester,
      ) async {
        final String where = _scenario(locale, scale, _Card.winner);
        await _onPhone(tester, () async {
          await _pumpCard(
            tester,
            _harness(locale: locale, textScale: scale, card: _Card.winner),
          );
          final Finder outline = _textUnder(_outlineKey);
          final Finder fill = find.byKey(_fillKey);
          expect(
            outline,
            findsOneWidget,
            reason: '$where: no outline layer to compare against the fill',
          );
          expect(fill, findsOneWidget);
          final Rect o = _globalRect(_paragraph(tester, outline));
          final Rect f = _globalRect(_paragraph(tester, fill));
          final String measured =
              'outline=$o fill=$f (size ${o.size} vs ${f.size})';
          expect(
            (o.width - f.width).abs(),
            lessThanOrEqualTo(_geometrySlop),
            reason: '$where: width differs, $measured',
          );
          expect(
            (o.height - f.height).abs(),
            lessThanOrEqualTo(_geometrySlop),
            reason: '$where: height differs, $measured',
          );
          expect(
            (o.left - f.left).abs(),
            lessThanOrEqualTo(_geometrySlop),
            reason: '$where: global x differs, $measured',
          );
          expect(
            (o.top - f.top).abs(),
            lessThanOrEqualTo(_geometrySlop),
            reason: '$where: global y differs, $measured',
          );
        });
      });
    }

    // (e) TalkBack hears the title once.
    testWidgets('exactly one semantics node carries the win title ($code)', (
      WidgetTester tester,
    ) async {
      const double scale = 1.0;
      final String where = _scenario(locale, scale, _Card.winner);
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        await _onPhone(tester, () async {
          await _pumpCard(
            tester,
            _harness(locale: locale, textScale: scale, card: _Card.winner),
          );
          final AppLocalizations loc = AppLocalizations.of(
            tester.element(find.byType(EndCard)),
          );
          SemanticsNode root = tester.getSemantics(find.byType(EndCard));
          while (root.parent != null) {
            root = root.parent!;
          }
          final int count = _semanticsNodesCarrying(root, loc.endWinTitle);
          expect(
            count,
            1,
            reason:
                '$where: expected exactly 1 semantics node carrying '
                '"${loc.endWinTitle}", found $count',
          );
        });
      } finally {
        handle.dispose();
      }
    });

    // (f) the burst is still gold, in both motion modes.
    for (final bool reduced in const <bool>[false, true]) {
      testWidgets('celebration still paints with LudoColors.gold '
          '($code, reducedMotion=$reduced)', (WidgetTester tester) async {
        final String where =
            '${_scenario(locale, 1.0, _Card.winner)} reducedMotion=$reduced';
        await _onPhone(tester, () async {
          await tester.pumpWidget(
            _harness(
              locale: locale,
              textScale: 1.0,
              card: _Card.winner,
              reducedMotion: reduced,
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          final Finder celebration = find.byKey(_celebrationKey);
          expect(
            celebration,
            findsOneWidget,
            reason: '$where: end-card-celebration must be on the win card',
          );
          if (reduced) {
            final Finder box = find.descendant(
              of: celebration,
              matching: find.byType(Container),
            );
            expect(box, findsOneWidget, reason: '$where: glow Container');
            final Decoration? deco = tester.widget<Container>(box).decoration;
            expect(deco, isA<BoxDecoration>(), reason: where);
            final Gradient? gradient = (deco! as BoxDecoration).gradient;
            expect(gradient, isA<RadialGradient>(), reason: where);
            final Color first = gradient!.colors.first;
            expect(
              first.toARGB32() & 0x00FFFFFF,
              LudoColors.gold.toARGB32() & 0x00FFFFFF,
              reason:
                  '$where: glow starts from gold, got '
                  '0x${first.toARGB32().toRadixString(16)}',
            );
          } else {
            final Finder paint = find.descendant(
              of: celebration,
              matching: find.byType(CustomPaint),
            );
            expect(paint, findsOneWidget, reason: '$where: burst paint');
            final CustomPainter? painter = tester
                .widget<CustomPaint>(paint)
                .painter;
            expect(painter, isNotNull, reason: where);
            // _BurstPainter is private; goldColor is its public field.
            final Object? goldColor = (painter as dynamic).goldColor;
            expect(
              goldColor,
              LudoColors.gold,
              reason: '$where: burst goldColor expected gold, got $goldColor',
            );
          }
        });
      });
    }

    // (g) only the winner gets a rim.
    for (final _Card card in const <_Card>[
      _Card.loser,
      _Card.spectator,
      _Card.ended,
    ]) {
      testWidgets('${card.name} card has no outline layer ($code)', (
        WidgetTester tester,
      ) async {
        final String where = _scenario(locale, 1.0, card);
        await _onPhone(tester, () async {
          await _pumpCard(
            tester,
            _harness(locale: locale, textScale: 1.0, card: card),
          );
          expect(
            find.byKey(_outlineKey),
            findsNothing,
            reason: '$where: game-screen-winner-outline must be winner-only',
          );
          expect(
            find.byKey(_celebrationKey),
            findsNothing,
            reason: '$where: no celebration off the winner card',
          );
          if (card == _Card.loser) {
            final Finder title = find.byKey(_fillKey);
            expect(title, findsOneWidget, reason: where);
            final Color? colour = _paragraph(tester, title).text.style?.color;
            expect(
              colour,
              isNot(LudoColors.gold),
              reason: '$where: the loser title must not be gold (D3)',
            );
          }
        });
      });
    }
  }
}

// Order 393. One line and one PNG per phone shape, text scale and locale
// for the end card, won and lost. The lost card carries the same stat
// numbers as test/end_card_large_text_test.dart (rolls, sixes, captures,
// home). This file does not assert that any of them fit. The only expects
// are that the card variant mounted.
//
// The card harness is copied from test/end_card_large_text_test.dart. The
// text scale is not: it goes through textScaleFactorTestValue, the same
// channel as test/board_budget_large_text_test.dart, so the matrix has one
// scale source. Fonts and the TextPainter helper are copied from that
// file. The PNG write follows test/ux_instrument_test.dart at pixelRatio
// 1.0. Nothing here is imported from another test file.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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

const String _frameDir = '/tmp/ludo-393-frames';
const Key _shotKey = Key('probe-shot');

const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

const double _tapFloor = 48;
const double _fitSlop = 0.5;

const GameStats _completeStats = GameStats(
  rolls: 50,
  sixes: 32,
  capturesMade: 1,
  timesCaptured: 0,
  tokensHome: 4,
  complete: true,
);

class _Shape {
  const _Shape({
    required this.id,
    required this.width,
    required this.height,
    required this.dpr,
    required this.topInset,
    required this.bottomInset,
  });

  final String id;
  final double width;
  final double height;
  final double dpr;
  final double topInset;
  final double bottomInset;

  Size get physical => Size(width * dpr, height * dpr);
}

const List<_Shape> _shapes = <_Shape>[
  _Shape(
    id: 's1',
    width: 360,
    height: 616,
    dpr: 3,
    topInset: 24,
    bottomInset: 0,
  ),
  _Shape(
    id: 's2',
    width: 360,
    height: 640,
    dpr: 3,
    topInset: 24,
    bottomInset: 48,
  ),
  _Shape(
    id: 's3',
    width: 360,
    height: 780,
    dpr: 3,
    topInset: 32,
    bottomInset: 24,
  ),
  _Shape(
    id: 's4',
    width: 393,
    height: 851,
    dpr: 2.75,
    topInset: 48,
    bottomInset: 24,
  ),
  _Shape(
    id: 's5',
    width: 412,
    height: 915,
    dpr: 2.625,
    topInset: 32,
    bottomInset: 48,
  ),
  _Shape(
    id: 's6',
    width: 320,
    height: 568,
    dpr: 2,
    topInset: 24,
    bottomInset: 0,
  ),
];

enum _Card { win, lose }

String _casePath(_Card card) => card == _Card.win ? 'end/win' : 'end/lose';

Widget _harness({required Locale locale, required _Card card}) {
  final int winnerSeat = card == _Card.win ? 0 : 1;
  return RepaintBoundary(
    key: _shotKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
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
    ),
  );
}

Future<void> _surface(
  WidgetTester tester,
  _Shape shape,
  double scale,
  Future<void> Function() body,
) async {
  tester.view.physicalSize = shape.physical;
  tester.view.devicePixelRatio = shape.dpr;
  final FakeViewPadding inset = FakeViewPadding(
    top: shape.topInset * shape.dpr,
    bottom: shape.bottomInset * shape.dpr,
  );
  tester.view.padding = inset;
  tester.view.viewPadding = inset;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.reset);
  try {
    await body();
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
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

Future<void> _pumpCard(WidgetTester tester, Widget harness) async {
  await tester.pumpWidget(harness);
  await tester.pump();
  // _Celebration's burst is 1200ms. One bounded pump runs it out.
  await tester.pump(const Duration(milliseconds: 1200));
  await tester.pump();
}

double _layoutMaxWidth(RenderParagraph paragraph) {
  final bool wraps =
      paragraph.softWrap || paragraph.overflow == TextOverflow.ellipsis;
  return wraps ? paragraph.constraints.maxWidth : double.infinity;
}

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
    ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '\u2026' : null,
  );
  painter.layout(
    minWidth: paragraph.constraints.minWidth,
    maxWidth: _layoutMaxWidth(paragraph),
  );
  return painter;
}

String _snip(String text) {
  final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final StringBuffer buffer = StringBuffer();
  int count = 0;
  for (final int rune in flat.runes) {
    if (count == 24) {
      break;
    }
    buffer.writeCharCode(rune);
    count += 1;
  }
  return buffer.toString();
}

String _q(String text) {
  final String escaped = text.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  return '"$escaped"';
}

String _na(Object error) {
  String text = error.toString().split('\n').first.trim();
  text = text.replaceAll(RegExp(r'\s+'), ' ').replaceAll('=', ':');
  if (text.length > 60) {
    text = text.substring(0, 60);
  }
  if (text.isEmpty) {
    text = 'unknown';
  }
  return 'n/a($text)';
}

String _dim(double value) => value.toStringAsFixed(1);

String _keyLabel(Key? key) {
  if (key is ValueKey<String> && key.value.isNotEmpty) {
    return key.value;
  }
  if (key is ValueKey) {
    final Object? value = key.value;
    if (value is String && value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

String _visibleLabel(Element element) {
  final Widget self = element.widget;
  if (self is Semantics) {
    final String label = self.properties.label ?? '';
    if (label.trim().isNotEmpty) {
      return label.trim();
    }
  }
  if (self is Text) {
    final String text = self.data ?? self.textSpan?.toPlainText() ?? '';
    if (text.trim().isNotEmpty) {
      return text.trim();
    }
  }
  String found = '';
  void visit(Element child) {
    if (found.isNotEmpty) {
      return;
    }
    final Widget widget = child.widget;
    if (widget is Text) {
      final String text = widget.data ?? widget.textSpan?.toPlainText() ?? '';
      if (text.trim().isNotEmpty) {
        found = text.trim();
        return;
      }
    }
    if (widget is Semantics) {
      final String label = widget.properties.label ?? '';
      if (label.trim().isNotEmpty) {
        found = label.trim();
        return;
      }
    }
    child.visitChildren(visit);
  }

  element.visitChildren(visit);
  return found;
}

String _nameOf(Element element) {
  final String own = _keyLabel(element.widget.key);
  if (own.isNotEmpty) {
    return own;
  }
  String ancestorName = '';
  element.visitAncestorElements((Element ancestor) {
    final String labeled = _keyLabel(ancestor.widget.key);
    if (labeled.isNotEmpty) {
      ancestorName = labeled;
      return false;
    }
    return true;
  });
  if (ancestorName.isNotEmpty) {
    return ancestorName;
  }
  final String label = _visibleLabel(element);
  if (label.isNotEmpty) {
    return _snip(label);
  }
  return element.widget.runtimeType.toString();
}

bool _hidden(Element element) {
  bool hidden = false;
  element.visitAncestorElements((Element ancestor) {
    final Widget widget = ancestor.widget;
    if (widget is Offstage && widget.offstage) {
      hidden = true;
      return false;
    }
    if (widget is Visibility && !widget.visible) {
      hidden = true;
      return false;
    }
    if (widget is Opacity && widget.opacity <= 0) {
      hidden = true;
      return false;
    }
    return true;
  });
  return hidden;
}

Rect _globalRect(RenderBox box) {
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

bool _overlaps(RenderBox box, _Shape shape) {
  final Rect rect = _globalRect(box);
  final Rect screen = Rect.fromLTWH(0, 0, shape.width, shape.height);
  return rect.overlaps(screen);
}

bool _isHit(Widget widget) {
  if (widget is InkWell && widget.onTap != null) {
    return true;
  }
  if (widget is GestureDetector && widget.onTap != null) {
    return true;
  }
  if (widget is ButtonStyleButton && widget.onPressed != null) {
    return true;
  }
  if (widget is IconButton && widget.onPressed != null) {
    return true;
  }
  if (widget is Semantics && widget.properties.onTap != null) {
    return true;
  }
  return false;
}

bool _hasHitAncestor(Element element) {
  bool found = false;
  element.visitAncestorElements((Element ancestor) {
    if (_isHit(ancestor.widget)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

bool _isSmall(Size size) =>
    size.width + 0.01 < _tapFloor || size.height + 0.01 < _tapFloor;

Rect _safeRect(_Shape shape) => Rect.fromLTRB(
  0,
  shape.topInset,
  shape.width,
  shape.height - shape.bottomInset,
);

bool _whollyInside(Rect rect, Rect safe) {
  return rect.left >= safe.left - _fitSlop &&
      rect.top >= safe.top - _fitSlop &&
      rect.right <= safe.right + _fitSlop &&
      rect.bottom <= safe.bottom + _fitSlop;
}

String _clippedField(WidgetTester tester, _Shape shape) {
  final List<String> out = <String>[];
  for (final Element element in find.byType(RichText).evaluate()) {
    if (_hidden(element)) {
      continue;
    }
    final RenderObject? render = element.renderObject;
    if (render is! RenderParagraph) {
      continue;
    }
    if (!render.attached || !render.hasSize || render.size.isEmpty) {
      continue;
    }
    bool overlaps = false;
    try {
      overlaps = _overlaps(render, shape);
    } on Object {
      continue;
    }
    if (!overlaps) {
      continue;
    }
    final String plain = render.text.toPlainText();
    if (plain.trim().isEmpty) {
      continue;
    }
    TextPainter? painter;
    try {
      painter = _painterFor(render);
      final bool exceed = painter.didExceedMaxLines || render.didExceedMaxLines;
      final bool fadeOrEllipsis =
          render.overflow == TextOverflow.ellipsis ||
          render.overflow == TextOverflow.fade;
      final bool bigger =
          painter.size.width > render.size.width + _fitSlop ||
          painter.size.height > render.size.height + _fitSlop;
      if (exceed || bigger || (fadeOrEllipsis && (exceed || bigger))) {
        out.add(_q(_snip(plain)));
      }
    } on Object {
      out.add('n/a(painter)');
    } finally {
      painter?.dispose();
    }
  }
  return _bracket(out);
}

String _unsafeField(WidgetTester tester, _Shape shape) {
  final Finder buttons = find.descendant(
    of: find.byType(EndCard),
    matching: find.byWidgetPredicate(
      (Widget widget) => widget is ButtonStyleButton || widget is IconButton,
    ),
  );
  final Rect safe = _safeRect(shape);
  final List<String> out = <String>[];
  for (final Element element in buttons.evaluate()) {
    final String name = _nameOf(element);
    final RenderObject? render = element.renderObject;
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      out.add('$name n/a(no-rect)');
      continue;
    }
    try {
      final Rect rect = _globalRect(render);
      if (!_whollyInside(rect, safe)) {
        out.add(name);
      }
    } on Object catch (error) {
      out.add('$name ${_na(error)}');
    }
  }
  out.sort();
  return _bracket(out);
}

String _smallField(WidgetTester tester, _Shape shape) {
  final Finder rootFinder = find.byKey(_shotKey);
  if (rootFinder.evaluate().isEmpty) {
    return 'n/a(no-shot-boundary)';
  }
  final List<Element> hits = <Element>[];
  void visit(Element element) {
    if (_isHit(element.widget)) {
      hits.add(element);
    }
    element.visitChildren(visit);
  }

  visit(rootFinder.evaluate().first);
  final List<String> out = <String>[];
  for (final Element element in hits) {
    if (_hasHitAncestor(element)) {
      continue;
    }
    if (_hidden(element)) {
      continue;
    }
    final RenderObject? render = element.renderObject;
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      continue;
    }
    if (render.size.isEmpty) {
      continue;
    }
    if (!render.size.width.isFinite || !render.size.height.isFinite) {
      continue;
    }
    bool overlaps = false;
    try {
      overlaps = _overlaps(render, shape);
    } on Object {
      continue;
    }
    if (!overlaps) {
      continue;
    }
    if (!_isSmall(render.size)) {
      continue;
    }
    out.add(
      '${_nameOf(element)} ${_dim(render.size.width)}x${_dim(render.size.height)}',
    );
  }
  out.sort();
  return _bracket(out);
}

String _bracket(List<String> items) {
  if (items.isEmpty) {
    return '[]';
  }
  return '[${items.join(', ')}]';
}

String _overflowField(List<FlutterErrorDetails> errors) {
  if (errors.isEmpty) {
    return '0';
  }
  final String line = errors.first.exceptionAsString().split('\n').first.trim();
  return '${errors.length} ${_q(line)}';
}

Future<String> _capture(WidgetTester tester, String fileName) async {
  final Finder boundary = find.byKey(_shotKey);
  if (boundary.evaluate().isEmpty) {
    return 'n/a(no-shot-boundary)';
  }
  final RenderObject render = tester.renderObject(boundary);
  if (render is! RenderRepaintBoundary) {
    return 'n/a(boundary-not-repaint)';
  }
  if (!render.hasSize || render.size.isEmpty) {
    return 'n/a(boundary-empty)';
  }
  final String path = '$_frameDir/$fileName';
  try {
    await tester.runAsync(() async {
      final ui.Image image = await render.toImage(pixelRatio: 1);
      try {
        final ByteData? bytes = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (bytes == null) {
          throw StateError('png bytes were null');
        }
        File(path).writeAsBytesSync(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } on Object catch (error) {
    return _na(error);
  }
  return path;
}

void _emit({
  required _Shape shape,
  required double scale,
  required String locale,
  required String screen,
  required String board,
  required List<FlutterErrorDetails> errors,
  required String clipped,
  required String unsafe,
  required String small,
  required String png,
}) {
  final String scaleLabel = scale.toStringAsFixed(1);
  stdout.writeln(
    'SHAPE ${shape.id} $scaleLabel $locale $screen '
    'board=$board overflow=${_overflowField(errors)} clipped=$clipped '
    'unsafe=$unsafe small=$small png=$png',
  );
}

String _pngName(_Shape shape, double scale, String locale, String screen) {
  final String scaleLabel = scale.toStringAsFixed(1);
  final String slug = screen.replaceAll('/', '-');
  return '${shape.id}-$scaleLabel-$locale-$slug.png';
}

Future<void> _runCase(
  WidgetTester tester, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required _Card card,
}) async {
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = captured.add;
  final String screen = _casePath(card);
  try {
    await _surface(tester, shape, scale, () async {
      await _pumpCard(tester, _harness(locale: locale, card: card));
      expect(find.byType(EndCard), findsOneWidget);
      if (card == _Card.win) {
        expect(find.byKey(const Key('end-card-win')), findsOneWidget);
      } else {
        expect(find.byKey(const Key('end-card-lose')), findsOneWidget);
        expect(find.byKey(const Key('end-card-stat-rolls')), findsOneWidget);
        expect(find.byKey(const Key('end-card-stat-sixes')), findsOneWidget);
        expect(find.byKey(const Key('end-card-stat-captures')), findsOneWidget);
        expect(find.byKey(const Key('end-card-stat-home')), findsOneWidget);
      }

      const String board = '-';
      String clipped = 'n/a(not-measured)';
      String unsafe = 'n/a(not-measured)';
      String small = 'n/a(not-measured)';
      try {
        clipped = _clippedField(tester, shape);
      } on Object catch (error) {
        clipped = _na(error);
      }
      try {
        unsafe = _unsafeField(tester, shape);
      } on Object catch (error) {
        unsafe = _na(error);
      }
      try {
        small = _smallField(tester, shape);
      } on Object catch (error) {
        small = _na(error);
      }
      final String png = await _capture(
        tester,
        _pngName(shape, scale, locale.languageCode, screen),
      );
      _emit(
        shape: shape,
        scale: scale,
        locale: locale.languageCode,
        screen: screen,
        board: board,
        errors: captured,
        clipped: clipped,
        unsafe: unsafe,
        small: small,
        png: png,
      );
    });
  } finally {
    FlutterError.onError = previous;
  }
}

void main() {
  setUpAll(() async {
    await _loadAppFonts();
    Directory(_frameDir).createSync(recursive: true);
  });

  for (final _Shape shape in _shapes) {
    for (final double scale in _scales) {
      for (final Locale locale in _locales) {
        for (final _Card card in _Card.values) {
          final String scaleLabel = scale.toStringAsFixed(1);
          final String label =
              '${shape.id} $scaleLabel ${locale.languageCode} ${_casePath(card)}';
          testWidgets(label, (WidgetTester tester) async {
            await _runCase(
              tester,
              shape: shape,
              scale: scale,
              locale: locale,
              card: card,
            );
          });
        }
      }
    }
  }
}

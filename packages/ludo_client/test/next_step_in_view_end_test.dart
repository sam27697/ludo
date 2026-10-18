// C-398. End card, won and lost: Play again stays inside the safe area on
// the probe's phone shapes. Visibility is the keyed widget's global rect,
// wholly inside [padding.top, height - padding.bottom] and [0, width],
// read with the scroll at its start. The mount, the shapes, the insets,
// the text scale and the font load are copied from the order 393 probe
// (probe_shapes_end_test.dart), not imported. One mount per case.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/game_stats.dart';
import 'package:ludo_client/src/theme.dart'
    show LudoColors, buildAppTheme, kSpace4;

const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

// The shape probe's own wholly-inside slop. The contract table was measured
// with it, so a sub-pixel edge classifies the same way here.
const double _fitSlop = 0.5;
const double _tapFloor = 48;

const Key _rematchKey = Key('end-card-rematch');
const Key _verifyKey = Key('game-screen-verify-button');
const Key _newTableKey = Key('game-screen-new-room-button');

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

  bool get checksVisibility => id != 's6';

  double get safeBottom => height - bottomInset;
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

String _cardState(_Card card) => card == _Card.win ? 'end-win' : 'end-lose';

Widget _harness({required Locale locale, required _Card card}) {
  final int winnerSeat = card == _Card.win ? 0 : 1;
  return MaterialApp(
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

String _scaleLabel(double scale) => scale.toStringAsFixed(1);

String _where(_Shape shape, double scale, Locale locale) =>
    '${shape.id}, scale ${_scaleLabel(scale)}, ${locale.languageCode}';

String _box(Rect rect) =>
    '${rect.left.toStringAsFixed(1)},${rect.top.toStringAsFixed(1)} '
    '${rect.right.toStringAsFixed(1)},${rect.bottom.toStringAsFixed(1)}';

String _safe(_Shape shape) =>
    '0,${shape.topInset.toStringAsFixed(0)} '
    '${shape.width.toStringAsFixed(0)},${shape.safeBottom.toStringAsFixed(0)}';

bool _whollyInside(Rect rect, _Shape shape) {
  return rect.left >= -_fitSlop &&
      rect.top >= shape.topInset - _fitSlop &&
      rect.right <= shape.width + _fitSlop &&
      rect.bottom <= shape.safeBottom + _fitSlop;
}

String? _scrollNotAtStart(WidgetTester tester) {
  final List<String> moved = <String>[];
  for (final Element element in find.byType(SingleChildScrollView).evaluate()) {
    double? pixels;
    void visit(Element node) {
      if (pixels != null) {
        return;
      }
      if (node.widget is Scrollable && node is StatefulElement) {
        final State<StatefulWidget> state = node.state;
        if (state is ScrollableState && state.position.hasPixels) {
          pixels = state.position.pixels;
          return;
        }
      }
      node.visitChildElements(visit);
    }

    element.visitChildElements(visit);
    if (pixels != null && pixels!.abs() > _fitSlop) {
      moved.add(pixels!.toStringAsFixed(1));
    }
  }
  if (moved.isEmpty) {
    return null;
  }
  return moved.join(',');
}

String? _visibilityProblem(
  WidgetTester tester, {
  required Key key,
  required String name,
  required _Shape shape,
  required String why,
}) {
  final Finder finder = find.byKey(key);
  final int count = finder.evaluate().length;
  if (count != 1) {
    return '$why $name was found $count times, not once, so it is not on screen.';
  }
  final Rect rect = tester.getRect(finder);
  if (_whollyInside(rect, shape)) {
    return null;
  }
  return '$why $name rect ${_box(rect)} is outside the safe rect ${_safe(shape)}.';
}

String? _hitProblem(
  WidgetTester tester, {
  required Key key,
  required String name,
  required String why,
}) {
  final Finder finder = find.byKey(key);
  if (finder.evaluate().length != 1) {
    return '$why $name was not laid out once, so its hit size could not be read.';
  }
  final Size size = tester.getSize(finder);
  if (size.width + 0.01 < _tapFloor || size.height + 0.01 < _tapFloor) {
    return '$why $name hit size ${size.width.toStringAsFixed(1)}x'
        '${size.height.toStringAsFixed(1)} is under $_tapFloor dp on one axis.';
  }
  return null;
}

String _hitSizes(WidgetTester tester) {
  final List<String> parts = <String>[];
  for (final (Key, String) entry in <(Key, String)>[
    (_rematchKey, 'end-card-rematch'),
    (_newTableKey, 'game-screen-new-room-button'),
  ]) {
    final Finder finder = find.byKey(entry.$1);
    if (finder.evaluate().length != 1) {
      parts.add('${entry.$2}=missing');
      continue;
    }
    final Size size = tester.getSize(finder);
    parts.add(
      '${entry.$2}=${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}',
    );
  }
  return parts.join(',');
}

String _flag(bool? ok) {
  if (ok == null) {
    return 'skip';
  }
  return ok ? 'GREEN' : 'RED';
}

void _emit({
  required String state,
  required _Shape shape,
  required double scale,
  required Locale locale,
  required bool? vis,
  required bool? hit,
  required bool err,
  required String hitSizes,
}) {
  stdout.writeln(
    'NEXTSTEP state=$state shape=${shape.id} scale=${_scaleLabel(scale)} '
    'locale=${locale.languageCode} vis=${_flag(vis)} hit=${_flag(hit)} '
    'err=${_flag(err)} hits=$hitSizes',
  );
}

String _firstError(List<FlutterErrorDetails> errors) {
  if (errors.isEmpty) {
    return '';
  }
  String line = errors.first.exceptionAsString().split('\n').first.trim();
  line = line.replaceAll(RegExp(r'\s+'), ' ');
  if (line.length > 140) {
    line = line.substring(0, 140);
  }
  return line;
}

bool _checksVerify(_Shape shape, double scale, Locale locale) =>
    shape.id == 's1' && scale == 1.0 && locale.languageCode == 'en';

Future<void> _runCard(
  WidgetTester tester, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required _Card card,
  required List<FlutterErrorDetails> errors,
}) async {
  final String where = _where(shape, scale, locale);
  final String state = _cardState(card);
  final bool checkVis = shape.checksVisibility;
  await _pumpCard(tester, _harness(locale: locale, card: card));
  expect(
    find.byType(EndCard),
    findsOneWidget,
    reason:
        'decision 2, $where: EndCard is the mounted card. Catches a mount '
        'that painted a different screen.',
  );
  expect(
    find.byKey(
      card == _Card.win
          ? const Key('end-card-win')
          : const Key('end-card-lose'),
    ),
    findsOneWidget,
    reason:
        'decision 2, $where: the $state variant is the one on screen. '
        'Catches a win card mounted for a loss, or the reverse.',
  );
  expect(
    find.byKey(_rematchKey),
    findsOneWidget,
    reason:
        'decision 2, $where: end-card-rematch is in the tree. Catches an '
        'end card that drops Play again.',
  );

  final List<String> visProblems = <String>[];
  if (checkVis) {
    final String? moved = _scrollNotAtStart(tester);
    if (moved != null) {
      visProblems.add(
        'decision 2, $where: a scroll view was already at $moved px, not '
        'at the start. Catches an end card that scrolls Play again into '
        'view on mount instead of keeping it on screen at scroll zero.',
      );
    }
    final String? rematch = _visibilityProblem(
      tester,
      key: _rematchKey,
      name: 'end-card-rematch',
      shape: shape,
      why:
          'decision 2, $where: Play again must sit wholly inside the safe '
          'area while the scroll is at its start. Catches an end card that '
          'leaves end-card-rematch in the scrolling column, so on a short '
          'phone it sits below the fold.',
    );
    if (rematch != null) {
      visProblems.add(rematch);
    }
    if (_checksVerify(shape, scale, locale)) {
      final String? verify = _visibilityProblem(
        tester,
        key: _verifyKey,
        name: 'game-screen-verify-button',
        shape: shape,
        why:
            'decision 2, $where: the verify button is on screen without '
            'scrolling at 1.0 on s1, as it is today. Catches a fairness '
            'line pushed below the fold on that shape.',
      );
      if (verify != null) {
        visProblems.add(verify);
      }
    }
  }

  final List<String> hitProblems = <String>[];
  if (checkVis) {
    for (final (Key, String) entry in <(Key, String)>[
      (_rematchKey, 'end-card-rematch'),
      (_newTableKey, 'game-screen-new-room-button'),
    ]) {
      final String? problem = _hitProblem(
        tester,
        key: entry.$1,
        name: entry.$2,
        why:
            'decision 5, $where: a docked end-card control keeps a '
            '$_tapFloor dp hit target on both axes. Catches an action '
            'button whose hit box shrinks below $_tapFloor dp.',
      );
      if (problem != null) {
        hitProblems.add(problem);
      }
    }
  }

  final List<String> errProblems = <String>[];
  if (errors.isNotEmpty) {
    errProblems.add(
      'decision 5, $where: the mount reported ${errors.length} '
      'FlutterError(s), first "${_firstError(errors)}". Catches a row or '
      'a line that overflows instead of wrapping.',
    );
  }

  _emit(
    state: state,
    shape: shape,
    scale: scale,
    locale: locale,
    vis: checkVis ? visProblems.isEmpty : null,
    hit: checkVis ? hitProblems.isEmpty : null,
    err: errProblems.isEmpty,
    hitSizes: checkVis ? _hitSizes(tester) : '-',
  );

  if (checkVis) {
    expect(
      visProblems,
      isEmpty,
      reason:
          'decision 2, $where: end-card-rematch must lie wholly inside the '
          'safe area at scroll start'
          '${_checksVerify(shape, scale, locale) ? ', and game-screen-verify-button with it at s1 1.0 en' : ''}. '
          'Catches an end card that keeps Play again in the scrolling '
          'column, so on a short phone it sits below the fold. '
          '${visProblems.join(' ')}',
    );
  }
  expect(
    errProblems,
    isEmpty,
    reason:
        'decision 5, $where: $state reports no FlutterError'
        '${checkVis ? '' : '. Overflow only on this shape: visibility is not required here'}. '
        'Catches a row or a line that overflows instead of wrapping. '
        '${errProblems.join(' ')}',
  );
  if (checkVis) {
    expect(
      hitProblems,
      isEmpty,
      reason:
          'decision 5, $where: the docked end-card controls are at least '
          '$_tapFloor dp both ways. Catches a hit box shrunk below that '
          'floor. ${hitProblems.join(' ')}',
    );
  }
}

void main() {
  setUpAll(() async {
    await _loadAppFonts();
  });

  for (final _Shape shape in _shapes) {
    for (final double scale in _scales) {
      for (final Locale locale in _locales) {
        for (final _Card card in _Card.values) {
          final String label =
              '${_cardState(card)} ${shape.id} ${_scaleLabel(scale)} '
              '${locale.languageCode}';
          testWidgets(label, (WidgetTester tester) async {
            final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
            final FlutterExceptionHandler? previous = FlutterError.onError;
            FlutterError.onError = errors.add;
            try {
              await _surface(tester, shape, scale, () async {
                await _runCard(
                  tester,
                  shape: shape,
                  scale: scale,
                  locale: locale,
                  card: card,
                  errors: errors,
                );
              });
            } finally {
              FlutterError.onError = previous;
            }
          });
        }
      }
    }
  }
}

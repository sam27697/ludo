// Tests for C-391 (order 391, run 95): the board keeps its 324 floor on a
// real phone at large system text, the header banner and the no-move notice
// stay whole, the header's height never jumps between play states, and the
// own chip still shows "Karim12345" / "You" whole.
//
// GameScreen is mounted the way test/large_text_fit_test.dart mounts it: a
// real RoomController over FakeTransport, under FeedbackScope, buildAppTheme,
// the real Poppins and Noto Sans Arabic fonts. Every helper this file needs
// from that file (the font loader, the frame/seat/turn/room JSON builders,
// the connector, the fake feedback service, the TextPainter-based
// measurement plumbing) is copied here by hand, per this order's own
// instruction never to import across test files and never to edit that
// file.
//
// The fixture differs from test/large_text_fit_test.dart in two ways the
// order asks for:
//
//  * the surface is the measured phone, not 360x640: physical 1080x1848 at
//    devicePixelRatio 3.0 (logical 360x616), tester.view.padding and
//    viewPadding carrying a top inset of 72 physical (24 logical) and no
//    bottom inset;
//  * the system text scale is driven through
//    tester.platformDispatcher.textScaleFactorTestValue, not a MediaQuery
//    override in MaterialApp.builder, since that is the ambient system
//    setting C-391 itself is about, reset at the end of the test body and
//    again from a tearDown as a backstop.
//
// One mount per (state, scale, locale) case, lesson 35. No pumpAndSettle (a
// turn arms a one-second countdown, and the no-move case arms a 1500ms
// hold). The controller is disposed in the test body.
//
// Ambiguity flagged, not invented around: the order asks that, at scale 1.0,
// this file also assert the header row height equals "what
// test/header_fits_test.dart pins today (read the number there; do not
// hardcode a different one)". That file was read in full for this order.
// It pins no header row height anywhere -- no SizedBox height literal, no
// `closeTo`/`equals` on a height, no printed number. Its own cases only
// assert that the turn banner's RenderParagraph does not exceed one line
// (`paragraph.didExceedMaxLines` false) and that the shown string matches
// the expected localization string; the header row's height as a number
// does not appear in that file at all. There is therefore no number in
// that file to read and compare against without inventing one, which this
// file's author was told never to do. This file still implements the
// cross-state part of decision 4 in full (the header row height is the same
// across all four states, at every scale and locale this file drives); it
// only skips tying the scale-1.0 value to a literal that test/header_fits_
// test.dart does not contain. See the final report for the same flag.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://board-budget-large-text-test.invalid/ws';

const String _moveEn = 'Your turn. Move a token.';
const String _moveAr = 'دورك. حرّك قطعة.';

// Both 10 characters, both accepted by the server's 1-24 character limit
// (packages/ludo_server/lib/src/registry.dart:411-412), distinct from each
// other, so the board always draws two name chips and one You label in
// every state (test/large_text_fit_test.dart's own precedent).
const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _headerChipKey = Key('game-header-chip');
const Key _boardKey = Key('game-screen-board');
const Key _noticeKey = Key('game-no-move-notice');
const Key _trayKey = Key('game-roll-tray');
const Key _chip0Key = Key('board-seat-name-0');
const Key _youKey = Key('board-seat-you');

// The measured phone (C-391's own table): physical 1080x1848 at
// devicePixelRatio 3.0 = logical 360x616, top inset 24 logical (72
// physical), no bottom inset.
const Size _devicePhysicalSize = Size(1080, 1848);
const double _devicePixelRatio = 3.0;
const double _topInsetPhysical = 72;
const double _bottomInsetPhysical = 0;

const double _boardFloor = 324;

const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'board-budget-large-text-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _faceLegal(int face, List<int> tokens) =>
    <String, Object?>{'face': face, 'tokens': tokens};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  int? value,
  List<int>? legal,
  int k = 0,
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': 45000,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _roomJson({
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': null,
  'seq': seq,
};

List<Map<String, Object?>> _twoSeats({
  List<int> seat0Tokens = const <int>[-1, -1, -1, -1],
}) => <Map<String, Object?>>[
  _seatJson(0, name: _mySeatName, tokens: seat0Tokens),
  _seatJson(1, name: _otherSeatName),
];

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

class _FakeFeedbackService implements FeedbackService {
  @override
  void play(FeedbackCue cue) {}
}

typedef _Keep = void Function(RoomController controller);

/// Registers the controller before the first await that can throw, so the
/// caller's finally still disposes it. Copied from
/// test/large_text_fit_test.dart's own `_connect`.
Future<(RoomController, FakeTransport)> _connect(
  WidgetTester tester,
  _Keep keep, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  keep(controller);

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(seats: seats, turn: turn),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child, {required Locale locale}) {
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
    home: child,
  );
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  required Locale locale,
}) async {
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: _FakeFeedbackService(),
        child: GameScreen(controller: controller),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

/// The measured phone, reset before the test returns. The system text
/// scale is driven through `tester.platformDispatcher.textScaleFactorTestValue`
/// (the ambient system setting, not a MediaQuery override), reset at the end
/// of the test body and again from a tearDown as a backstop. [body] calls
/// [keep] with the controller it connects.
Future<void> _phone(
  WidgetTester tester,
  double scale,
  Future<void> Function(_Keep keep) body,
) async {
  tester.view.physicalSize = _devicePhysicalSize;
  tester.view.devicePixelRatio = _devicePixelRatio;
  const FakeViewPadding inset = FakeViewPadding(
    top: _topInsetPhysical,
    bottom: _bottomInsetPhysical,
  );
  tester.view.padding = inset;
  tester.view.viewPadding = inset;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  RoomController? controller;
  try {
    await body((RoomController c) {
      controller = c;
    });
  } finally {
    final RoomController? owned = controller;
    if (owned != null) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      owned.dispose();
    }
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
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
// Measurement plumbing, copied by hand from test/large_text_fit_test.dart's
// own `_textOf` / `_textFinderByData` / `_paragraphOf` / `_layoutMaxWidth` /
// `_painterFor` / `_fits` / `_print`.
// ---------------------------------------------------------------------------

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

Finder _textFinderByData(Finder scope, String value) {
  return find.descendant(
    of: scope,
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
  return tester.renderObject<RenderParagraph>(rich);
}

/// Every RenderParagraph under [scope], in tree order.
List<RenderParagraph> _paragraphsOf(WidgetTester tester, Finder scope) {
  final Finder rich = find.descendant(
    of: scope,
    matching: find.byType(RichText),
  );
  return tester.renderObjectList<RenderParagraph>(rich).toList();
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

bool _fits(double measured, double bound) => measured <= bound + 0.5;

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

// ---------------------------------------------------------------------------
// Case connectors.
// ---------------------------------------------------------------------------

/// Case 1: my turn to roll, seat 0 (local), `Karim12345`.
Future<RoomController> _mountMyTurnToRoll(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
}) async {
  final (RoomController controller, _) = await _connect(
    tester,
    keep,
    seats: _twoSeats(),
    turn: _turnJson(seat: 0, phase: 'await_roll'),
  );
  await _mount(tester, controller, locale: locale);
  return controller;
}

/// Case 2: waiting for seat 1, `Samantha12`.
Future<RoomController> _mountWaitingForOther(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
}) async {
  final (RoomController controller, _) = await _connect(
    tester,
    keep,
    seats: _twoSeats(),
    turn: _turnJson(seat: 1, phase: 'await_roll'),
  );
  await _mount(tester, controller, locale: locale);
  return controller;
}

/// Case 3: the no-move notice showing. Copied by hand from
/// test/no_move_beat_test.dart's own `_landOnNoMove`: my seat (0) lands on
/// await_roll, then a `rolled` with an empty `legal` and, at once (same
/// pump), the next seat's `turn` frame land together, arming the 1500ms
/// no-move hold. Two bare pumps only flush the microtasks the pushed frames'
/// own setState schedules; neither advances the fake clock the hold's Timer
/// runs on, so the notice is still up right after.
Future<RoomController> _mountNoMoveNotice(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connect(
    tester,
    keep,
    seats: _twoSeats(),
    turn: _turnJson(seat: 0, phase: 'await_roll', k: 0),
  );
  await _mount(tester, controller, locale: locale);

  final int seqAfterRolled = controller.room!.seq + 1;
  transport.pushText(
    _frame(
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 3,
        'legal': <int>[],
        'deadline_ms': 45000,
        'k': 1,
        'reveal': 'd' * 64,
        'seq': seqAfterRolled,
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'turn',
      data: <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
        'seq': seqAfterRolled + 1,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return controller;
}

/// Case 4: a roll queue of three dice in the tray. Copied by hand from
/// test/roll_tray_fit_test.dart's own "case 13": my seat (0) in await_move,
/// one token already out (token 0 at square 0), a queue of [6, 6, 3] with
/// `legal_by_face` entries for faces 6 and 3.
Future<RoomController> _mountRollQueue(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
}) async {
  final (RoomController controller, _) = await _connect(
    tester,
    keep,
    seats: _twoSeats(seat0Tokens: const <int>[0, -1, -1, -1]),
    turn: _turnJson(
      seat: 0,
      phase: 'await_move',
      k: 3,
      value: 6,
      legal: const <int>[0, 1, 2, 3],
      queue: const <int>[6, 6, 3],
      legalByFace: <Map<String, Object?>>[
        _faceLegal(6, const <int>[0, 1, 2, 3]),
        _faceLegal(3, const <int>[0]),
      ],
    ),
  );
  await _mount(tester, controller, locale: locale);
  return controller;
}

// ---------------------------------------------------------------------------
// Decision 2: at or below 1.5, the banner's laid-out font size is exactly
// `scale` times its base size; above 1.5 it is clamped to 1.5 (not yet
// implemented on today's code, which never clamps at all).
// ---------------------------------------------------------------------------

double _expectedBannerRatio(double scale) => scale <= 1.5 ? scale : 1.5;

// ---------------------------------------------------------------------------
// Decision 4's cross-state accounting: one entry per (scale, locale, case),
// compared once all four cases for that (scale, locale) have run. Top-level
// tests in one file run in declaration order within one isolate
// (test/arabic_shaping_gap_test.dart's own precedent for this pattern).
// ---------------------------------------------------------------------------

final Map<String, Map<String, double>> _headerHeightsByKey =
    <String, Map<String, double>>{};

void _recordHeaderHeight(String key, String caseName, double height) {
  _headerHeightsByKey.putIfAbsent(key, () => <String, double>{})[caseName] =
      height;
}

/// Runs assertions 1, 2, 3, 5 (decisions 1, 3, 2, 7) against the mounted
/// tree. Never throws: every red this finds is appended to the returned
/// list instead, so the caller can still run its own FlutterError.onError
/// check even when this finds something wrong (lesson 18's capture would
/// otherwise be skipped by the first failed `expect`).
({List<String> reds, double headerRowHeight, double boardSide}) _checkCase(
  WidgetTester tester, {
  required String label,
  required String expectedBanner,
  required double scale,
}) {
  final List<String> reds = <String>[];

  // ---- assertion 2 (banner text) + fixture for assertions 2 & 3. --------
  if (!tester.any(find.byKey(_bannerKey))) {
    reds.add('$label: game-screen-turn-banner must be on screen, found none');
    return (reds: reds, headerRowHeight: double.nan, boardSide: double.nan);
  }
  final String shownBanner =
      tester.widget<Text>(find.byKey(_bannerKey)).data ?? '';
  if (shownBanner != expectedBanner) {
    reds.add(
      '$label: banner text, expected "$expectedBanner", got "$shownBanner"',
    );
  }

  if (!tester.any(find.byKey(_headerChipKey))) {
    reds.add('$label: game-header-chip must be on screen, found none');
    return (reds: reds, headerRowHeight: double.nan, boardSide: double.nan);
  }
  final double chipHeight = tester.getSize(find.byKey(_headerChipKey)).height;

  // ---- decision 3: every RenderParagraph under the banner is whole and
  // not clipped by the chip that holds it. --------------------------------
  reds.addAll(
    _checkNotClipped(
      tester,
      label: label,
      what: 'banner',
      scope: find.byKey(_bannerKey),
      boxHeight: chipHeight,
    ),
  );

  // ---- decision 2: the banner's laid-out font size follows scale up to
  // 1.5, then clamps. -------------------------------------------------------
  final RenderParagraph bannerParagraph = _paragraphOf(
    tester,
    find.byKey(_bannerKey),
  );
  final InlineSpan bannerSpan = bannerParagraph.text;
  final double? baseFontSize = bannerSpan is TextSpan
      ? bannerSpan.style?.fontSize
      : null;
  if (baseFontSize == null) {
    reds.add(
      '$label: banner span carries no resolved fontSize, cannot measure '
      'decision 2',
    );
  } else {
    final double laidOutFontSize = bannerParagraph.textScaler.scale(
      baseFontSize,
    );
    final double ratio = laidOutFontSize / baseFontSize;
    final double expectedRatio = _expectedBannerRatio(scale);
    _print(
      'CASE $label banner="$shownBanner" baseFontSize='
      '${baseFontSize.toStringAsFixed(2)} laidOutFontSize='
      '${laidOutFontSize.toStringAsFixed(2)} ratio=${ratio.toStringAsFixed(3)} '
      'expectedRatio=${expectedRatio.toStringAsFixed(3)} scale=$scale',
    );
    if ((ratio - expectedRatio).abs() > 0.01) {
      reds.add(
        '$label: banner laid-out font ratio ${ratio.toStringAsFixed(3)} '
        '(base=${baseFontSize.toStringAsFixed(2)}, '
        'laidOut=${laidOutFontSize.toStringAsFixed(2)}) is not within 0.01 '
        'of the expected ${expectedRatio.toStringAsFixed(3)} at scale '
        '$scale (decision 2)',
      );
    }
  }

  // ---- decision 3, continued: the no-move notice, when shown. -----------
  if (tester.any(find.byKey(_noticeKey))) {
    final double noticeBoxHeight = tester
        .getSize(find.byKey(_noticeKey))
        .height;
    reds.addAll(
      _checkNotClipped(
        tester,
        label: label,
        what: 'no-move notice',
        scope: find.byKey(_noticeKey),
        boxHeight: noticeBoxHeight,
      ),
    );
  }

  // ---- decision 1: the board's floor. ------------------------------------
  double boardSide = double.nan;
  if (!tester.any(find.byKey(_boardKey))) {
    reds.add('$label: game-screen-board must be on screen, found none');
  } else {
    final Size boardSize = tester.getSize(find.byKey(_boardKey));
    boardSide = math.min(boardSize.width, boardSize.height);
    if (boardSide < _boardFloor) {
      reds.add(
        '$label: game-screen-board side ${boardSide.toStringAsFixed(1)} '
        '(board rect ${boardSize.width.toStringAsFixed(1)}x'
        '${boardSize.height.toStringAsFixed(1)}) is under the $_boardFloor '
        'floor (decision 1)',
      );
    }
  }

  // ---- decision 4's own value for this case, for the caller to record. --
  double headerRowHeight = double.nan;
  final Finder headerSizedBox = find
      .ancestor(of: find.byKey(_headerChipKey), matching: find.byType(SizedBox))
      .first;
  if (!tester.any(headerSizedBox)) {
    reds.add(
      '$label: no SizedBox ancestor of game-header-chip, cannot measure '
      'the header row height for decision 4',
    );
  } else {
    headerRowHeight = tester.getSize(headerSizedBox).height;
  }

  // ---- decision 7: the own chip shows the name whole, and "You" is up. --
  if (!tester.any(find.byKey(_chip0Key))) {
    reds.add('$label: board-seat-name-0 must be on the board, found none');
  } else {
    final Finder nameTextFinder = _textFinderByData(
      find.byKey(_chip0Key),
      _mySeatName,
    );
    if (!tester.any(nameTextFinder)) {
      reds.add(
        '$label: seat 0 name text "$_mySeatName" must be inside its chip, '
        'found none',
      );
    } else {
      final RenderParagraph nameParagraph = _paragraphOf(
        tester,
        nameTextFinder,
      );
      final TextPainter namePainter = _painterFor(nameParagraph);
      try {
        _print(
          'CASE $label seat=0 name="$_mySeatName" '
          'didExceedMaxLines=${namePainter.didExceedMaxLines}',
        );
        if (namePainter.didExceedMaxLines) {
          reds.add(
            '$label: board-seat-name-0 "$_mySeatName" is cut '
            '(TextPainter.didExceedMaxLines=true), decision 7',
          );
        }
      } finally {
        namePainter.dispose();
      }
    }
    if (!tester.any(find.byKey(_youKey))) {
      reds.add(
        '$label: board-seat-you must be in seat 0\'s chip, found none '
        '(decision 7)',
      );
    }
  }

  _print(
    'REPORT $label headerRowHeight=${headerRowHeight.toStringAsFixed(1)} '
    'boardSide=${boardSide.toStringAsFixed(1)} chipHeight='
    '${chipHeight.toStringAsFixed(1)}',
  );

  return (reds: reds, headerRowHeight: headerRowHeight, boardSide: boardSide);
}

/// Decision 3's shared check: every RenderParagraph under [scope] must not
/// exceed its max lines and must not be clipped by the box its parent gives
/// it (test/large_text_fit_test.dart's own `_fits` precedent, generalised
/// from one RenderParagraph to every one found).
List<String> _checkNotClipped(
  WidgetTester tester, {
  required String label,
  required String what,
  required Finder scope,
  required double boxHeight,
}) {
  final List<String> reds = <String>[];
  final List<RenderParagraph> paragraphs = _paragraphsOf(tester, scope);
  if (paragraphs.isEmpty) {
    reds.add('$label: $what has no RenderParagraph under it to measure');
    return reds;
  }
  for (int i = 0; i < paragraphs.length; i++) {
    final TextPainter painter = _painterFor(paragraphs[i]);
    try {
      if (painter.didExceedMaxLines) {
        reds.add(
          '$label: $what RenderParagraph #$i exceeded its max lines at '
          'width ${paragraphs[i].constraints.maxWidth.toStringAsFixed(1)} '
          '(TextPainter.didExceedMaxLines=true, decision 3)',
        );
      }
      if (!_fits(painter.size.height, boxHeight)) {
        reds.add(
          '$label: $what RenderParagraph #$i painted height '
          '${painter.size.height.toStringAsFixed(1)} is clipped by its '
          'parent, box height ${boxHeight.toStringAsFixed(1)} (tolerance '
          '0.5px, decision 3)',
        );
      }
    } finally {
      painter.dispose();
    }
  }
  return reds;
}

void main() {
  setUpAll(_loadAppFonts);

  for (final double scale in _scales) {
    final String scaleLabel = scale.toStringAsFixed(1);

    for (final Locale locale in _locales) {
      final String code = locale.languageCode;
      final String key = '$code-$scaleLabel';

      // -----------------------------------------------------------------
      // Case 1: my turn to roll.
      // -----------------------------------------------------------------
      testWidgets('$code scale $scaleLabel: my turn to roll', (tester) async {
        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final FlutterExceptionHandler? previous = FlutterError.onError;
        FlutterError.onError = captured.add;
        final String label = '$code scale $scaleLabel my turn to roll';
        List<String> reds = <String>[];
        double headerRowHeight = double.nan;
        try {
          await _phone(tester, scale, (_Keep keep) async {
            await _mountMyTurnToRoll(tester, keep, locale: locale);
            final result = _checkCase(
              tester,
              label: label,
              expectedBanner: _loc(tester).gameYourTurnRoll,
              scale: scale,
            );
            reds = result.reds;
            headerRowHeight = result.headerRowHeight;
            if (scale == 2.0 && code == 'en') {
              // Rig parity, required by the order: the header row height
              // and the board side at 2.0 en, my-turn state, on today's
              // code. CI emulator measured header 88, board 284.
              _print(
                'PARITY header=${headerRowHeight.toStringAsFixed(1)} '
                'board=${result.boardSide.toStringAsFixed(1)} label=$label',
              );
            }
          });
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
        _recordHeaderHeight(key, 'my turn to roll', headerRowHeight);
        expect(reds, isEmpty, reason: reds.join('\n'));
      });

      // -----------------------------------------------------------------
      // Case 2: waiting for seat 1, Samantha12.
      // -----------------------------------------------------------------
      testWidgets('$code scale $scaleLabel: waiting for Samantha12', (
        tester,
      ) async {
        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final FlutterExceptionHandler? previous = FlutterError.onError;
        FlutterError.onError = captured.add;
        final String label = '$code scale $scaleLabel waiting for Samantha12';
        List<String> reds = <String>[];
        double headerRowHeight = double.nan;
        try {
          await _phone(tester, scale, (_Keep keep) async {
            await _mountWaitingForOther(tester, keep, locale: locale);
            final result = _checkCase(
              tester,
              label: label,
              expectedBanner: _loc(tester).gameWaitingForPlayer(_otherSeatName),
              scale: scale,
            );
            reds = result.reds;
            headerRowHeight = result.headerRowHeight;
          });
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
        _recordHeaderHeight(key, 'waiting for Samantha12', headerRowHeight);
        expect(reds, isEmpty, reason: reds.join('\n'));
      });

      // -----------------------------------------------------------------
      // Case 3: the no-move notice showing.
      // -----------------------------------------------------------------
      testWidgets('$code scale $scaleLabel: the no-move notice showing', (
        tester,
      ) async {
        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final FlutterExceptionHandler? previous = FlutterError.onError;
        FlutterError.onError = captured.add;
        final String label =
            '$code scale $scaleLabel the no-move notice showing';
        List<String> reds = <String>[];
        double headerRowHeight = double.nan;
        try {
          await _phone(tester, scale, (_Keep keep) async {
            await _mountNoMoveNotice(tester, keep, locale: locale);
            if (!tester.any(find.byKey(_noticeKey))) {
              reds.add(
                '$label: fixture is broken, game-no-move-notice must be '
                'up before this case checks anything',
              );
              return;
            }
            // The next seat's turn has already landed underneath the
            // hold (test/no_move_beat_test.dart's own rule 4a case proves
            // the banner already names it for the same frames).
            final result = _checkCase(
              tester,
              label: label,
              expectedBanner: _loc(tester).gameWaitingForPlayer(_otherSeatName),
              scale: scale,
            );
            reds = result.reds;
            headerRowHeight = result.headerRowHeight;
          });
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
        _recordHeaderHeight(key, 'the no-move notice showing', headerRowHeight);
        expect(reds, isEmpty, reason: reds.join('\n'));
      });

      // -----------------------------------------------------------------
      // Case 4: a roll queue of three dice in the tray.
      // -----------------------------------------------------------------
      testWidgets(
        '$code scale $scaleLabel: a roll queue of three dice in the tray',
        (tester) async {
          final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
          final FlutterExceptionHandler? previous = FlutterError.onError;
          FlutterError.onError = captured.add;
          final String label =
              '$code scale $scaleLabel a roll queue of three dice in the tray';
          List<String> reds = <String>[];
          double headerRowHeight = double.nan;
          try {
            await _phone(tester, scale, (_Keep keep) async {
              await _mountRollQueue(tester, keep, locale: locale);
              if (!tester.any(find.byKey(_trayKey))) {
                reds.add(
                  '$label: fixture is broken, game-roll-tray must be up '
                  'for this case',
                );
                return;
              }
              final result = _checkCase(
                tester,
                label: label,
                expectedBanner: code == 'ar' ? _moveAr : _moveEn,
                scale: scale,
              );
              reds = result.reds;
              headerRowHeight = result.headerRowHeight;
            });
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
          _recordHeaderHeight(
            key,
            'a roll queue of three dice in the tray',
            headerRowHeight,
          );
          expect(reds, isEmpty, reason: reds.join('\n'));
        },
      );

      // -----------------------------------------------------------------
      // Decision 4: the header row's height is a function of the text
      // scale alone -- the same height in every one of the four states
      // above, at this scale and locale. Declared last in this (scale,
      // locale) group so all four recordings above have already run
      // (top-level tests in one file run in declaration order within one
      // isolate).
      // -----------------------------------------------------------------
      testWidgets(
        '$code scale $scaleLabel: header row height is the same across '
        'all four states (decision 4)',
        (tester) async {
          final Map<String, double>? heights = _headerHeightsByKey[key];
          expect(
            heights,
            isNotNull,
            reason:
                'fixture is broken: no header row heights were recorded '
                'for $key',
          );
          expect(
            heights!.length,
            4,
            reason:
                'fixture is broken: expected 4 recorded header row '
                'heights for $key, got ${heights.length}: $heights',
          );
          final double first = heights.values.first;
          final List<String> reds = <String>[
            for (final MapEntry<String, double> entry in heights.entries)
              if (!_fits(entry.value, first) || !_fits(first, entry.value))
                '$key: "${entry.key}" header row height '
                    '${entry.value.toStringAsFixed(2)} differs from '
                    '"${heights.entries.first.key}" height '
                    '${first.toStringAsFixed(2)} (decision 4); all measured: '
                    '$heights',
          ];
          expect(reds, isEmpty, reason: reds.join('\n'));
        },
      );
    }
  }
}

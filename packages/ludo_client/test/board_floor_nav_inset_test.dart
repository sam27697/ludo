// Tests for C-402 (order 402, run 97): the board keeps its 324 floor above
// a navigation bar, the play-column gaps stay at their scale-1.0 size on a
// roomy phone, the turn banner and the no-move notice stay whole, the die
// keeps a 48 dp hit target, and no case overflows.
//
// GameScreen is mounted the way test/board_budget_large_text_test.dart
// mounts it: a real RoomController over FakeTransport, under FeedbackScope,
// buildAppTheme, the real Poppins and Noto Sans Arabic fonts. The four play
// states are that file's own four mounts. The shape table and the inset
// setup (tester.view.padding and tester.view.viewPadding, both in physical
// pixels) are copied from the order 393 shape probe. Helpers are copied by
// hand. Nothing here is imported from another test file.
//
// One mount per case. The system text scale goes through
// tester.platformDispatcher.textScaleFactorTestValue, reset in the body and
// again from a tearDown. FlutterError.onError is restored in the body.
// No pumpAndSettle: a turn arms a one-second countdown, and the no-move
// case arms a 1500ms hold.
//
// On def9e22 the s2 cases at 1.3 and 2.0 are red on decision 1 (the board
// is under 324). s6 is width-bound: it is held only to decision 5, and
// only in the my-turn state. Decision 2 is the distance from the board
// rect's bottom edge to the die row's top edge. On s4 and s5 at 1.3, and
// on s5 at 2.0, that distance must equal the distance recorded at scale
// 1.0 for the same shape, locale and play state, within 0.5 dp. The 1.0
// case is declared first. Top-level tests in one file run in declaration
// order in one isolate, the same precedent as the header-height map in
// test/board_budget_large_text_test.dart.
//
// The notice Text sets no maxLines. didExceedMaxLines is read off a fresh
// TextPainter the way test/board_budget_large_text_test.dart reads it
// (_painterFor), which is the check that catches an ellipsis. A notice
// clipped by its slot with no maxLines stays didExceedMaxLines false.

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

const String _testUrl = 'wss://board-floor-nav-inset-test.invalid/ws';

const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _boardKey = Key('game-screen-board');
const Key _noticeKey = Key('game-no-move-notice');
const Key _trayKey = Key('game-roll-tray');
const Key _dieKey = Key('game-die');

const double _boardFloor = 324;
const double _dieHitFloor = 48;
const double _gapSlop = 0.5;

const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

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

// Logical dp. Insets are logical too; the surface helper multiplies by dpr
// because tester.view.padding is physical pixels. Copied from the order 393
// shape probe.
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

enum _PlayState { roll, wait, nomove, queue }

const List<_PlayState> _playStates = <_PlayState>[
  _PlayState.roll,
  _PlayState.wait,
  _PlayState.nomove,
  _PlayState.queue,
];

String _stateName(_PlayState state) {
  switch (state) {
    case _PlayState.roll:
      return 'my turn to roll';
    case _PlayState.wait:
      return 'waiting for Samantha12';
    case _PlayState.nomove:
      return 'the no-move notice showing';
    case _PlayState.queue:
      return 'a roll queue of three dice in the tray';
  }
}

String _stateSlug(_PlayState state) {
  switch (state) {
    case _PlayState.roll:
      return 'roll';
    case _PlayState.wait:
      return 'wait';
    case _PlayState.nomove:
      return 'nomove';
    case _PlayState.queue:
      return 'queue';
  }
}

String _where(_Shape shape, double scale, Locale locale, _PlayState state) {
  return '${shape.id} scale ${scale.toStringAsFixed(1)} '
      '${locale.languageCode} ${_stateName(state)}';
}

bool _holdsFloor(_Shape shape) => shape.id != 's6';

bool _recordsGap(_Shape shape) => shape.id == 's4' || shape.id == 's5';

bool _comparesGap(_Shape shape, double scale) {
  if (shape.id == 's5' && scale == 2.0) {
    return true;
  }
  return _recordsGap(shape) && scale == 1.3;
}

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'board-floor-nav-inset-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

/// The shape is set in physical pixels (logical times dpr), including both
/// system insets, and the text scale goes through
/// [TestPlatformDispatcher.textScaleFactorTestValue]. Both are cleared
/// before the test returns, and again from a tearDown if the body never
/// gets there.
Future<void> _phone(
  WidgetTester tester,
  _Shape shape,
  double scale,
  Future<void> Function(_Keep keep) body,
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
// Mounts, copied from test/board_budget_large_text_test.dart.
// ---------------------------------------------------------------------------

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

/// My seat lands on await_roll, then a `rolled` with an empty `legal` and,
/// in the same pumps, the next seat's `turn`. That arms the 1500ms no-move
/// hold. The pumps below do not advance that timer.
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

/// My seat in await_move, token 0 already out, queue [6, 6, 3].
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

Future<void> _mountState(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
  required _PlayState state,
}) async {
  switch (state) {
    case _PlayState.roll:
      await _mountMyTurnToRoll(tester, keep, locale: locale);
    case _PlayState.wait:
      await _mountWaitingForOther(tester, keep, locale: locale);
    case _PlayState.nomove:
      await _mountNoMoveNotice(tester, keep, locale: locale);
    case _PlayState.queue:
      await _mountRollQueue(tester, keep, locale: locale);
  }
}

// ---------------------------------------------------------------------------
// Measurement. TextPainter path copied from test/board_budget_large_text_test.dart.
// ---------------------------------------------------------------------------

List<RenderParagraph> _paragraphsOf(WidgetTester tester, Finder scope) {
  final Finder rich = find.descendant(
    of: scope,
    matching: find.byType(RichText),
  );
  return tester.renderObjectList<RenderParagraph>(rich).toList();
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

class _LineRead {
  const _LineRead({
    required this.exceeded,
    required this.maxWidth,
    required this.preview,
  });

  final bool exceeded;
  final double maxWidth;
  final String preview;
}

class _Measured {
  const _Measured({
    required this.boardPresent,
    required this.boardWidth,
    required this.boardHeight,
    required this.bannerPresent,
    required this.bannerReads,
    required this.noticePresent,
    required this.noticeReads,
    required this.trayPresent,
    required this.diePresent,
    required this.dieWidth,
    required this.dieHeight,
    required this.rowGap,
    required this.dieGap,
  });

  final bool boardPresent;
  final double boardWidth;
  final double boardHeight;
  final bool bannerPresent;
  final List<_LineRead> bannerReads;
  final bool noticePresent;
  final List<_LineRead> noticeReads;
  final bool trayPresent;
  final bool diePresent;
  final double dieWidth;
  final double dieHeight;
  final double? rowGap;
  final double? dieGap;

  double get boardSide => math.min(boardWidth, boardHeight);
}

String _snip(String text) {
  final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= 48) {
    return flat;
  }
  return '${flat.substring(0, 45)}...';
}

String _dp(double? value) {
  if (value == null || !value.isFinite) {
    return 'n/a';
  }
  return value.toStringAsFixed(1);
}

String _exceededField(bool present, List<_LineRead> reads) {
  if (!present) {
    return 'absent';
  }
  if (reads.isEmpty) {
    return 'noparagraph';
  }
  return reads.map((_LineRead read) => read.exceeded.toString()).join(',');
}

int _count(WidgetTester tester, Key key) =>
    tester.widgetList(find.byKey(key)).length;

List<_LineRead> _readLines(WidgetTester tester, Key key) {
  final Finder scope = find.byKey(key);
  if (tester.widgetList(scope).length != 1) {
    return const <_LineRead>[];
  }
  // Every RenderParagraph under the keyed text, the way
  // test/board_budget_large_text_test.dart reads didExceedMaxLines.
  final List<_LineRead> out = <_LineRead>[];
  for (final RenderParagraph paragraph in _paragraphsOf(tester, scope)) {
    final TextPainter painter = _painterFor(paragraph);
    try {
      out.add(
        _LineRead(
          exceeded: painter.didExceedMaxLines,
          maxWidth: paragraph.constraints.maxWidth,
          preview: _snip(paragraph.text.toPlainText()),
        ),
      );
    } finally {
      painter.dispose();
    }
  }
  return out;
}

_Measured _measure(WidgetTester tester) {
  final bool boardPresent = _count(tester, _boardKey) == 1;
  double boardWidth = double.nan;
  double boardHeight = double.nan;
  double? rowGap;
  double? dieGap;
  if (boardPresent) {
    final Rect board = tester.getRect(find.byKey(_boardKey));
    boardWidth = board.width;
    boardHeight = board.height;
    final bool diePresent = _count(tester, _dieKey) == 1;
    if (diePresent) {
      final Rect die = tester.getRect(find.byKey(_dieKey));
      dieGap = die.top - board.bottom;
      Element? row;
      tester.element(find.byKey(_dieKey)).visitAncestorElements((
        Element ancestor,
      ) {
        if (ancestor.widget is Row) {
          row = ancestor;
          return false;
        }
        return true;
      });
      final RenderObject? render = row?.renderObject;
      if (render is RenderBox && render.hasSize && render.attached) {
        rowGap = render.localToGlobal(Offset.zero).dy - board.bottom;
      }
    }
  }
  final bool diePresent = _count(tester, _dieKey) == 1;
  double dieWidth = double.nan;
  double dieHeight = double.nan;
  if (diePresent) {
    final Size die = tester.getSize(find.byKey(_dieKey));
    dieWidth = die.width;
    dieHeight = die.height;
  }
  return _Measured(
    boardPresent: boardPresent,
    boardWidth: boardWidth,
    boardHeight: boardHeight,
    bannerPresent: _count(tester, _bannerKey) == 1,
    bannerReads: _readLines(tester, _bannerKey),
    noticePresent: _count(tester, _noticeKey) == 1,
    noticeReads: _readLines(tester, _noticeKey),
    trayPresent: _count(tester, _trayKey) == 1,
    diePresent: diePresent,
    dieWidth: dieWidth,
    dieHeight: dieHeight,
    rowGap: rowGap,
    dieGap: dieGap,
  );
}

// Scale 1.0 board-bottom to die-row-top, keyed by shape, locale and state.
// Read by the 1.3 cases (s4, s5) and the 2.0 cases (s5) declared later.
final Map<String, double> _gapAtScaleOne = <String, double>{};

String _gapKey(_Shape shape, Locale locale, _PlayState state) =>
    '${shape.id}|${locale.languageCode}|${state.name}';

String _errorLine(FlutterErrorDetails details) {
  final String text = details.exceptionAsString().split('\n').first.trim();
  if (text.length <= 180) {
    return text;
  }
  return '${text.substring(0, 177)}...';
}

void _expectLines({
  required String where,
  required String what,
  required String decision,
  required List<_LineRead> reads,
  required String mutation,
}) {
  expect(
    reads,
    isNotEmpty,
    reason:
        '$decision: $where $what has no RenderParagraph, so '
        'didExceedMaxLines cannot be read. $mutation',
  );
  for (int i = 0; i < reads.length; i++) {
    final _LineRead read = reads[i];
    expect(
      read.exceeded,
      isFalse,
      reason:
          '$decision: $where $what RenderParagraph #$i '
          'didExceedMaxLines=${read.exceeded} at width '
          '${read.maxWidth.toStringAsFixed(1)} text="${read.preview}". '
          '$mutation',
    );
  }
}

Future<_Measured> _readCase(
  WidgetTester tester, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required _PlayState state,
}) async {
  late _Measured measured;
  await _phone(tester, shape, scale, (_Keep keep) async {
    await _mountState(tester, keep, locale: locale, state: state);
    measured = _measure(tester);
  });
  return measured;
}

void _expectCase(
  _Measured measured,
  List<FlutterErrorDetails> captured, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required _PlayState state,
}) {
  final String where = _where(shape, scale, locale, state);
  if (scale == 1.0 && _recordsGap(shape) && measured.rowGap != null) {
    _gapAtScaleOne[_gapKey(shape, locale, state)] = measured.rowGap!;
  }
  _print(
    'CASE ${shape.id} ${scale.toStringAsFixed(1)} ${locale.languageCode} '
    '${_stateSlug(state)} board=${_dp(measured.boardPresent ? measured.boardSide : null)} '
    'wh=${_dp(measured.boardPresent ? measured.boardWidth : null)}x'
    '${_dp(measured.boardPresent ? measured.boardHeight : null)} '
    'overflow=${captured.length} '
    'banner=${_exceededField(measured.bannerPresent, measured.bannerReads)} '
    'notice=${_exceededField(measured.noticePresent, measured.noticeReads)} '
    'tray=${measured.trayPresent} '
    'die=${_dp(measured.diePresent ? measured.dieWidth : null)}x'
    '${_dp(measured.diePresent ? measured.dieHeight : null)} '
    'rowGap=${_dp(measured.rowGap)} dieGap=${_dp(measured.dieGap)}',
  );

  expect(
    captured,
    isEmpty,
    reason:
        'decision 5: $where recorded ${captured.length} FlutterError'
        '${captured.isEmpty ? '' : ': ${_errorLine(captured.first)}'}'
        '. A RenderFlex overflow from the play column, the banner or the '
        'notice must fail this; the case expects none.',
  );

  if (!_holdsFloor(shape)) {
    return;
  }

  expect(
    measured.boardPresent,
    isTrue,
    reason:
        'decision 1: $where game-screen-board must be on screen to measure '
        'its painted side. A play state that drops the board hides a short '
        'floor.',
  );
  expect(
    measured.boardSide,
    greaterThanOrEqualTo(_boardFloor),
    reason:
        'decision 1: $where game-screen-board painted side '
        '${measured.boardSide.toStringAsFixed(1)} '
        '(${measured.boardWidth.toStringAsFixed(1)}x'
        '${measured.boardHeight.toStringAsFixed(1)}) is under $_boardFloor. '
        'A bottom navigation inset, or a gap ramp keyed only on text scale, '
        'that takes height the board needed must fail this.',
  );

  expect(
    measured.bannerPresent,
    isTrue,
    reason:
        'decision 4: $where game-screen-turn-banner must be on screen so '
        'its line can be read. Dropping the banner hides a cut turn line.',
  );
  _expectLines(
    where: where,
    what: 'game-screen-turn-banner',
    decision: 'decision 4',
    reads: measured.bannerReads,
    mutation:
        'An ellipsis or a max-lines clamp that cuts the turn line must '
        'fail this.',
  );

  if (state == _PlayState.nomove) {
    expect(
      measured.noticePresent,
      isTrue,
      reason:
          'decision 4: $where game-no-move-notice must be showing; this '
          'case is that play state. A mount that never arms the hold skips '
          'the notice line check.',
    );
  }
  if (measured.noticePresent) {
    _expectLines(
      where: where,
      what: 'game-no-move-notice',
      decision: 'decision 4',
      reads: measured.noticeReads,
      mutation:
          'An ellipsis or a max-lines clamp that cuts the no-move notice '
          'must fail this.',
    );
  }

  if (state == _PlayState.queue) {
    expect(
      measured.trayPresent,
      isTrue,
      reason:
          'decision 4: $where game-roll-tray must be on screen; this case '
          'is a roll queue of three dice. Without the tray the case is not '
          'that play state, and a fix that drops the tray to buy board '
          'height would not be seen.',
    );
  }

  expect(
    measured.diePresent,
    isTrue,
    reason:
        'decision 4: $where game-die must be on screen so its hit target '
        'can be read. Removing the die to free height for the board must '
        'fail this.',
  );
  expect(
    measured.dieWidth,
    greaterThanOrEqualTo(_dieHitFloor),
    reason:
        'decision 4: $where game-die hit width '
        '${measured.dieWidth.toStringAsFixed(1)} must be >= $_dieHitFloor. '
        'A fix that buys board height by shrinking the die under the 48 dp '
        'tap floor must fail this.',
  );
  expect(
    measured.dieHeight,
    greaterThanOrEqualTo(_dieHitFloor),
    reason:
        'decision 4: $where game-die hit height '
        '${measured.dieHeight.toStringAsFixed(1)} must be >= $_dieHitFloor. '
        'A fix that buys board height by shrinking the die under the 48 dp '
        'tap floor must fail this.',
  );

  if (scale == 1.0 && _recordsGap(shape)) {
    expect(
      measured.rowGap,
      isNotNull,
      reason:
          'decision 2: $where could not measure the distance from the '
          'board bottom edge to the die row top edge (dieGap='
          '${_dp(measured.dieGap)}). The later scales on this shape compare '
          'against this distance; a die that is not in a row hides a gap '
          'shrink.',
    );
  }

  if (!_comparesGap(shape, scale)) {
    return;
  }
  final String key = _gapKey(shape, locale, state);
  final double? atScaleOne = _gapAtScaleOne[key];
  expect(
    atScaleOne,
    isNotNull,
    reason:
        'decision 2: $where has no scale 1.0 board-to-die-row distance '
        'recorded for $key. The scale 1.0 case on this shape, locale and '
        'state must mount first. Measured rowGap=${_dp(measured.rowGap)}.',
  );
  expect(
    measured.rowGap,
    isNotNull,
    reason:
        'decision 2: $where could not measure the board-bottom to '
        'die-row-top distance (dieGap=${_dp(measured.dieGap)}). A die row '
        'that cannot be found hides a scale-keyed gap shrink.',
  );
  final double rest = atScaleOne!;
  final double gap = measured.rowGap!;
  expect(
    gap,
    closeTo(rest, _gapSlop),
    reason:
        'decision 2: $where board-bottom to die-row-top is '
        '${gap.toStringAsFixed(1)} dp, and at scale 1.0 on this shape, '
        'locale and state it was ${rest.toStringAsFixed(1)} dp '
        '(die top gap ${_dp(measured.dieGap)}, board side '
        '${measured.boardSide.toStringAsFixed(1)}). On a roomy phone the '
        'board is over $_boardFloor, so this gap stays the scale 1.0 size. '
        'A ramp that shrinks the gap from the text scale alone, with no '
        'measured shortfall, must fail this.',
  );
}

void main() {
  setUpAll(_loadAppFonts);

  for (final _Shape shape in _shapes) {
    for (final double scale in _scales) {
      for (final Locale locale in _locales) {
        final List<_PlayState> states = _holdsFloor(shape)
            ? _playStates
            : const <_PlayState>[_PlayState.roll];
        for (final _PlayState state in states) {
          final String scaleLabel = scale.toStringAsFixed(1);
          final String name = _holdsFloor(shape)
              ? '${shape.id} $scaleLabel ${locale.languageCode} '
                    '${_stateName(state)}'
              : '${shape.id} $scaleLabel ${locale.languageCode} '
                    '${_stateName(state)} overflow only';
          testWidgets(name, (WidgetTester tester) async {
            final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
            final FlutterExceptionHandler? previous = FlutterError.onError;
            FlutterError.onError = captured.add;
            try {
              final _Measured measured = await _readCase(
                tester,
                shape: shape,
                scale: scale,
                locale: locale,
                state: state,
              );
              _expectCase(
                measured,
                captured,
                shape: shape,
                scale: scale,
                locale: locale,
                state: state,
              );
            } finally {
              FlutterError.onError = previous;
            }
          });
        }
      }
    }
  }
}

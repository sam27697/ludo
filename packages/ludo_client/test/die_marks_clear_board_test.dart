// Tests for C-404 (order 404, run 97): a mark on a die never covers the
// board. deadBadgeRect (dead_mark.dart) centres a 0.42-of-side badge on its
// die's top-right corner; on the 72dp board die that is a 30.24dp badge
// that rises 15.1dp above the die. Where the board-to-die-row gap is
// shorter than that overhang, the badge covers the board's own bottom row.
// This file measures the badge's rect against game-screen-board's rect
// directly, on both marks this contract names: the board die's
// game-die-no-move-mark, and a tray die's game-roll-tray-dead-<i>.
//
// GameScreen is mounted the way test/board_floor_nav_inset_test.dart mounts
// it: a real RoomController over FakeTransport, under FeedbackScope,
// buildAppTheme, the real Poppins and Noto Sans Arabic fonts, one mount per
// case. The shape table (s1-s5, C-402's shapes) and the inset setup
// (tester.view.padding and tester.view.viewPadding, both physical pixels)
// are copied from that file by hand; nothing here is imported from another
// test file. FlutterError.onError is restored in the body of every case.
//
// Two play states carry the two marks this contract names: the no-move
// notice holding (the board die's game-die-no-move-mark, C-236 rule 4) and
// a roll queue in the tray with one dead face. The dead-face fixture is the
// same one test/roll_tray_test.dart's "case 4" uses: queue [6, 2],
// legal_by_face carries only face 6, so index 1 (face 2) has no legal
// token and game-roll-tray-dead-1 marks it.
//
// On aa3a382 (order 403's board-floor fix; C-404 has no fix yet) decision
// 1 is expected red wherever the board-to-die-row gap is shorter than the
// relevant badge's own overhang above its die: C-404's own table names s2
// at 1.3 and 2.0, and s1 at 2.0, for the board die. Every case prints its
// own measured board-bottom-to-mark-top distance, so a failing run names
// its own shortfall without rereading this file.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/dead_mark.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://die-marks-clear-board-test.invalid/ws';

const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const Key _boardKey = Key('game-screen-board');
const Key _boardDieKey = Key('game-die');
const Key _boardMarkKey = Key('game-die-no-move-mark');

// Fixture is roll_tray_test.dart's own case 4: queue [6, 2], legal_by_face
// names only face 6, so index 1 (face 2) is dead.
const int _deadTrayIndex = 1;
const int _deadTrayFace = 2;
const Key _trayDieArtKey = Key('game-roll-tray-face-1-2');
const Key _trayMarkKey = Key('game-roll-tray-dead-1');

const double _markSlop = 0.5;

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
// shape probe by way of test/board_floor_nav_inset_test.dart. s6 is left
// out: the order names s1-s5 (C-402's shapes), not s6.
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
];

enum _PlayState { nomove, queueDead }

String _stateName(_PlayState state) {
  switch (state) {
    case _PlayState.nomove:
      return 'the no-move notice showing';
    case _PlayState.queueDead:
      return 'a roll queue with a dead die in the tray';
  }
}

String _where(_Shape shape, double scale, Locale locale, _PlayState state) {
  return '${shape.id} scale ${scale.toStringAsFixed(1)} '
      '${locale.languageCode} ${_stateName(state)}';
}

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'die-marks-clear-board-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
// Mounts.
// ---------------------------------------------------------------------------

/// My seat lands on await_roll, then a `rolled` with an empty `legal` and,
/// in the same pumps, the next seat's `turn`. That arms the 1500ms no-move
/// hold, which is what draws `game-die-no-move-mark` on the board die
/// (C-236 rule 4). The pumps below do not advance that timer, so the mark
/// stays up for the whole case. Copied from
/// test/board_floor_nav_inset_test.dart's own `_mountNoMoveNotice`.
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

/// My seat in await_move, token 0 already out, queue [6, 2]. legal_by_face
/// names only face 6 as having a legal token, so index 1 (face 2) has none
/// and the tray marks it dead: the same fixture
/// test/roll_tray_test.dart's "case 4: tapping a dead tray die plays
/// invalidTap and sends nothing" mounts, which that file already proves
/// renders `game-roll-tray-dead-1`.
Future<RoomController> _mountRollQueueDead(
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
      k: 2,
      value: 6,
      legal: const <int>[0, 1, 2, 3],
      queue: const <int>[6, _deadTrayFace],
      legalByFace: <Map<String, Object?>>[
        _faceLegal(6, const <int>[0, 1, 2, 3]),
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
    case _PlayState.nomove:
      await _mountNoMoveNotice(tester, keep, locale: locale);
    case _PlayState.queueDead:
      await _mountRollQueueDead(tester, keep, locale: locale);
  }
}

// ---------------------------------------------------------------------------
// Measurement and assertions.
// ---------------------------------------------------------------------------

/// One mark this contract covers, and the die it hangs off.
class _MarkCase {
  const _MarkCase({
    required this.label,
    required this.markKey,
    required this.dieKey,
    required this.isBoardDie,
  });

  final String label;
  final Key markKey;
  final Key dieKey;
  final bool isBoardDie;
}

List<_MarkCase> _marksFor(_PlayState state) {
  switch (state) {
    case _PlayState.nomove:
      return const <_MarkCase>[
        _MarkCase(
          label: 'board die',
          markKey: _boardMarkKey,
          dieKey: _boardDieKey,
          isBoardDie: true,
        ),
      ];
    case _PlayState.queueDead:
      return const <_MarkCase>[
        _MarkCase(
          label: 'tray die $_deadTrayIndex (face $_deadTrayFace)',
          markKey: _trayMarkKey,
          dieKey: _trayDieArtKey,
          isBoardDie: false,
        ),
      ];
  }
}

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

String _dp(double value) => value.toStringAsFixed(2);

String _errorLine(FlutterErrorDetails details) {
  final String text = details.exceptionAsString().split('\n').first.trim();
  if (text.length <= 180) {
    return text;
  }
  return '${text.substring(0, 177)}...';
}

/// Checks one mark against decisions 1 and 2, and prints its measured
/// board-bottom-to-mark-top overlap so a red case names its own shortfall.
void _checkMark(
  WidgetTester tester, {
  required _MarkCase mark,
  required Rect boardRect,
  required Rect screenRect,
  required String where,
}) {
  expect(
    find.byKey(mark.markKey),
    findsOneWidget,
    reason:
        'decision 1: $where expected exactly one ${mark.markKey} '
        '(${mark.label}\'s mark). A second paint of the same badge, or '
        'none at all, must fail this.',
  );
  expect(
    find.byKey(mark.dieKey),
    findsOneWidget,
    reason:
        'decision 2: $where expected exactly one ${mark.dieKey} to read '
        '${mark.label}\'s own rect against. Without it the badge size and '
        'centre cannot be checked against the die it hangs off.',
  );

  final Rect markRect = tester.getRect(find.byKey(mark.markKey));
  final Rect dieRect = tester.getRect(find.byKey(mark.dieKey));
  final double overlap = boardRect.bottom - markRect.top;

  _print(
    'CASE $where mark=${mark.label} board.bottom=${_dp(boardRect.bottom)} '
    'mark.top=${_dp(markRect.top)} overlap=${_dp(overlap)} '
    'mark=${_dp(markRect.left)},${_dp(markRect.top)},'
    '${_dp(markRect.width)}x${_dp(markRect.height)} '
    'die=${_dp(dieRect.left)},${_dp(dieRect.top)},'
    '${_dp(dieRect.width)}x${_dp(dieRect.height)}',
  );

  // Decision 1: every mark that hangs off a die in the die row lies wholly
  // below the board's painted bottom edge.
  expect(
    markRect.top,
    greaterThanOrEqualTo(boardRect.bottom - _markSlop),
    reason:
        'decision 1: $where ${mark.label}\'s mark top ${_dp(markRect.top)} '
        'is above the board bottom ${_dp(boardRect.bottom)} by '
        '${_dp(overlap)}dp (tolerance $_markSlop). A gap ramp or a clamp '
        'that leaves the badge where deadBadgeRect first puts it, instead '
        'of pushing it down by the shortfall, must fail this.',
  );

  // Decision 2: the badge keeps its own size, wherever the column puts it.
  final double expectedSide = deadBadgeRect(Size.square(dieRect.shortestSide))
      .width;
  expect(
    markRect.width,
    closeTo(expectedSide, _markSlop),
    reason:
        'decision 2: $where ${mark.label}\'s mark width ${_dp(markRect.width)} '
        'must equal deadBadgeRect\'s side ${_dp(expectedSide)} for a die of '
        '${_dp(dieRect.shortestSide)}dp. A fix that shrinks the badge to '
        'dodge the board, instead of moving it down, must fail this.',
  );
  expect(
    markRect.height,
    closeTo(expectedSide, _markSlop),
    reason:
        'decision 2: $where ${mark.label}\'s mark height '
        '${_dp(markRect.height)} must equal deadBadgeRect\'s side '
        '${_dp(expectedSide)} for a die of ${_dp(dieRect.shortestSide)}dp. '
        'A fix that shrinks the badge to dodge the board, instead of '
        'moving it down, must fail this.',
  );

  // Decision 2: the badge's centre x stays on the die's right edge,
  // physically, in both locales.
  expect(
    markRect.center.dx,
    closeTo(dieRect.right, _markSlop),
    reason:
        'decision 2: $where ${mark.label}\'s mark centre x '
        '${_dp(markRect.center.dx)} must equal the die\'s right edge '
        '${_dp(dieRect.right)} (physical, not directional). A fix that '
        'moves the badge left of the die\'s right edge in ar, mirroring it '
        'like text, must fail this.',
  );

  // Decision 2: the badge stays whole and on screen.
  expect(
    markRect,
    predicate<Rect>(
      (Rect rect) =>
          screenRect.contains(rect.topLeft) &&
          rect.right <= screenRect.right &&
          rect.bottom <= screenRect.bottom,
    ),
    reason:
        'decision 2: $where ${mark.label}\'s mark rect '
        '${_dp(markRect.left)},${_dp(markRect.top)},'
        '${_dp(markRect.width)}x${_dp(markRect.height)} must lie wholly '
        'inside the screen ${_dp(screenRect.width)}x'
        '${_dp(screenRect.height)}. A downward clamp that pushes the badge '
        'off the bottom or side of the screen instead of only clearing the '
        'board must fail this.',
  );

  // Decision 3: at rest (scale 1.0) the board die's badge is still exactly
  // where deadBadgeRect puts it today, unmoved by this contract.
  if (mark.isBoardDie) {
    final Rect expectedRel = deadBadgeRect(Size.square(dieRect.width));
    final Rect actualRel = Rect.fromLTRB(
      markRect.left - dieRect.left,
      markRect.top - dieRect.top,
      markRect.right - dieRect.left,
      markRect.bottom - dieRect.top,
    );
    expect(
      actualRel.left,
      closeTo(expectedRel.left, _markSlop),
      reason:
          'decision 3: $where ${mark.label}\'s mark rect left relative to '
          'the die, ${_dp(actualRel.left)}, must equal '
          'deadBadgeRect(Size.square(dieSide)).left ${_dp(expectedRel.left)} '
          'at scale 1.0. A fix armed even at rest, with no shortfall to '
          'clear, must fail this.',
    );
    expect(
      actualRel.top,
      closeTo(expectedRel.top, _markSlop),
      reason:
          'decision 3: $where ${mark.label}\'s mark rect top relative to '
          'the die, ${_dp(actualRel.top)}, must equal '
          'deadBadgeRect(Size.square(dieSide)).top ${_dp(expectedRel.top)} '
          'at scale 1.0. A fix armed even at rest, with no shortfall to '
          'clear, must fail this.',
    );
    expect(
      actualRel.right,
      closeTo(expectedRel.right, _markSlop),
      reason:
          'decision 3: $where ${mark.label}\'s mark rect right relative to '
          'the die, ${_dp(actualRel.right)}, must equal '
          'deadBadgeRect(Size.square(dieSide)).right '
          '${_dp(expectedRel.right)} at scale 1.0. A fix armed even at '
          'rest, with no shortfall to clear, must fail this.',
    );
    expect(
      actualRel.bottom,
      closeTo(expectedRel.bottom, _markSlop),
      reason:
          'decision 3: $where ${mark.label}\'s mark rect bottom relative '
          'to the die, ${_dp(actualRel.bottom)}, must equal '
          'deadBadgeRect(Size.square(dieSide)).bottom '
          '${_dp(expectedRel.bottom)} at scale 1.0. A fix armed even at '
          'rest, with no shortfall to clear, must fail this.',
    );
  }
}

Future<void> _runCase(
  WidgetTester tester, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required _PlayState state,
}) async {
  final String where = _where(shape, scale, locale, state);
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = captured.add;
  try {
    await _phone(tester, shape, scale, (_Keep keep) async {
      await _mountState(tester, keep, locale: locale, state: state);

      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason:
            'decision 1: $where game-screen-board must be on screen to '
            'read the painted bottom edge every mark is checked against.',
      );
      final Rect boardRect = tester.getRect(find.byKey(_boardKey));
      final Rect screenRect = Rect.fromLTWH(0, 0, shape.width, shape.height);

      for (final _MarkCase mark in _marksFor(state)) {
        _checkMark(
          tester,
          mark: mark,
          boardRect: boardRect,
          screenRect: screenRect,
          where: where,
        );
      }
    });
  } finally {
    FlutterError.onError = previous;
  }

  expect(
    captured,
    isEmpty,
    reason:
        'C-404 order item 4: $where recorded ${captured.length} '
        'FlutterError${captured.isEmpty ? '' : ': ${_errorLine(captured.first)}'}. '
        'No layout error is expected from a badge that only moves inside '
        'its own Positioned rect.',
  );
}

void main() {
  setUpAll(_loadAppFonts);

  for (final _Shape shape in _shapes) {
    for (final double scale in _scales) {
      for (final Locale locale in _locales) {
        for (final _PlayState state in _PlayState.values) {
          final String name =
              '${shape.id} ${scale.toStringAsFixed(1)} '
              '${locale.languageCode} ${_stateName(state)}';
          testWidgets(name, (WidgetTester tester) async {
            await _runCase(
              tester,
              shape: shape,
              scale: scale,
              locale: locale,
              state: state,
            );
          });
        }
      }
    }
  }
}

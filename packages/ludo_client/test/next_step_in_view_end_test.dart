// C-398. End card, won and lost: Play again stays inside the safe area on
// the probe's phone shapes. Visibility is the keyed widget's global rect,
// wholly inside [padding.top, height - padding.bottom] and [0, width],
// read with the scroll at its start. The shapes, the insets, the text
// scale and the font load are copied from the order 393 probe
// (probe_shapes_end_test.dart), not imported. The finished game is the
// real GameScreen over a RoomController and FakeTransport, copied by hand
// from test/end_board_view_test.dart: connect on PLAYING, one mount, then
// one game_over frame. The frames before that game_over are the host
// script copied from test/end_card_game_log_test.dart, so the transcript
// is complete and the card shows rolls, sixes, captures and tokens home.
// One mount per case.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

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
const Key _rollsKey = Key('end-card-stat-rolls');
const Key _sixesKey = Key('end-card-stat-sixes');
const Key _capturesKey = Key('end-card-stat-captures');
const Key _homeKey = Key('end-card-stat-home');

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

const String _testUrl = 'wss://next-step-end.invalid/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'next-step-end-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _playingRoomJson() => <String, Object?>{
  'code': 'E8RDVW',
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
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: _mySeatName),
    _seatJson(1, name: _otherSeatName),
  ],
  'turn': null,
  'winner': null,
  // The host script copied below opens at seq 3, the same numbers as
  // test/end_card_game_log_test.dart, whose lobby is already at seq 2.
  'seq': 2,
};

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

/// Connects a fresh controller to a two-seat PLAYING room, local seat 0,
/// turn null. Copied by hand from test/end_board_view_test.dart's own
/// `_connectTo`.
Future<(RoomController, FakeTransport)> _connectTo(WidgetTester tester) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  addTearDown(controller.dispose);

  final Future<void> future = controller.createRoom(
    name: _mySeatName,
    players: 2,
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: _playingRoomJson()));
  await future;
  return (controller, transport);
}

/// 16 lowercase hex characters, the same id the copied script uses.
const String _gameId = 'aaaaaaaaaaaaaaaa';

Future<void> _flushFrame(
  WidgetTester tester,
  FakeTransport transport,
  String text,
) async {
  transport.pushText(text);
  await tester.pump();
  await tester.pump();
}

/// Seat 0's game, copied from test/end_card_game_log_test.dart's
/// `_hostEntries`. Pushed before GameScreen mounts, so none of these
/// moves is travel on the board.
///
/// Counted from the frames below, not from the card:
///   rolled 6 (seq 5), rolled 4 (seq 7): rolls 2, sixes 1
///   one captured entry on the move at seq 8: captures 1
///   four tokens at 57 when the game ends: home 4
Future<void> _pushHostScript(
  WidgetTester tester,
  FakeTransport transport,
) async {
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'game_started',
      data: <String, Object?>{
        'turn': 0,
        'game_id': _gameId,
        'client_seeds': '0:seed',
        'seq': 3,
      },
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'turn',
      data: <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 4},
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[0, 1, 2],
        'deadline_ms': 45000,
        'k': 1,
        'reveal': 'a' * 64,
        'seq': 5,
      },
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': -1,
        'to': 0,
        'captured': <Map<String, Object?>>[],
        'extra_roll': false,
        'seq': 6,
      },
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 4,
        'legal': <int>[0, 1, 2],
        'deadline_ms': 45000,
        'k': 2,
        'reveal': 'a' * 64,
        'seq': 7,
      },
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 0,
        'to': 4,
        'captured': <Map<String, Object?>>[
          <String, Object?>{'seat': 1, 'token': 0},
        ],
        'extra_roll': false,
        'seq': 8,
      },
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 1,
        'from': -1,
        'to': 57,
        'captured': <Map<String, Object?>>[],
        'extra_roll': false,
        'seq': 9,
      },
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 2,
        'from': -1,
        'to': 57,
        'captured': <Map<String, Object?>>[],
        'extra_roll': false,
        'seq': 10,
      },
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 3,
        'from': -1,
        'to': 57,
        'captured': <Map<String, Object?>>[],
        'extra_roll': false,
        'seq': 11,
      },
    ),
  );
  await _flushFrame(
    tester,
    transport,
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 4,
        'to': 57,
        'captured': <Map<String, Object?>>[],
        'extra_roll': false,
        'seq': 12,
      },
    ),
  );
}

Widget _app({required Locale locale, required Widget home}) {
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
    home: home,
  );
}

/// Mounts GameScreen over the connected controller. One mount per case.
/// The host script has already been pushed, so the room is still PLAYING
/// and the transcript already holds the rolls, the capture and the
/// tokens that finish at home.
Future<void> _mountGame(
  WidgetTester tester, {
  required RoomController controller,
  required Locale locale,
}) async {
  final FeedbackSettings settings = FeedbackSettings.forTest();
  addTearDown(settings.dispose);
  await tester.pumpWidget(
    _app(
      locale: locale,
      home: FeedbackScope(
        settings: settings,
        service: const NoopFeedbackService(),
        child: GameScreen(controller: controller),
      ),
    ),
  );
  await tester.pump();
}

/// Pushes one `game_over` frame and flushes it with the two-pump idiom
/// test/end_board_view_test.dart uses, then runs out the win card's 1200ms
/// celebration in bounded steps. Not pumpAndSettle. Seq 13 is the frame
/// after the host script's last move.
Future<void> _showFinished(
  WidgetTester tester,
  FakeTransport transport, {
  required int winner,
}) async {
  transport.pushText(
    _frame(
      type: 'game_over',
      data: <String, Object?>{
        'winner': winner,
        'verify_url': 'https://next-step-end.invalid/verify/$winner',
        'seq': 13,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
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
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
  );
  await _pushHostScript(tester, transport);
  await _mountGame(tester, controller: controller, locale: locale);
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'decision 2, $where: GameScreen is on the connected room before '
        'game_over. Catches a connect the screen ignores, so the finished '
        'card never appears.',
  );
  await _showFinished(tester, transport, winner: card == _Card.win ? 0 : 1);
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason:
        'decision 2, $where: the finished game is GameScreen. Catches a '
        'harness that mounts EndCard inside its own scroll view, so '
        'docking the action area in the game screen cannot put '
        'end-card-rematch on screen.',
  );
  expect(
    find.byType(EndCard),
    findsOneWidget,
    reason:
        'decision 2, $where: EndCard is the card GameScreen shows once '
        'the game is over. Catches a finished room that stays on the '
        'playing body.',
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
  for (final (Key, String) tile in <(Key, String)>[
    (_rollsKey, 'end-card-stat-rolls'),
    (_sixesKey, 'end-card-stat-sixes'),
    (_capturesKey, 'end-card-stat-captures'),
    (_homeKey, 'end-card-stat-home'),
  ]) {
    expect(
      find.byKey(tile.$1),
      findsOneWidget,
      reason:
          'decision 2, $where: ${tile.$2} is on the card. Catches a '
          'transcript that never completed, so the card keeps the home '
          'tile alone and is shorter than a played game.',
    );
  }

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

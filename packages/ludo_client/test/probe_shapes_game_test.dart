// Order 393. One line and one PNG per phone shape, text scale and locale
// for the four game states a player actually reaches. The line is the
// measurement. This file does not assert that a board is large enough, that
// text fits, or that a target is 48 dp. The only expects are that the state
// under test mounted: the board is on screen, the banner reads that state,
// and the no-move notice or the roll tray is up when that state says so.
//
// The surface, the four mounts, the font loader and the TextPainter helper
// are copied by hand from test/board_budget_large_text_test.dart. The PNG
// write is the same toImage path as test/ux_instrument_test.dart, at
// pixelRatio 1.0. Nothing here is imported from another test file.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

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

const String _testUrl = 'wss://probe-shapes-game.invalid/ws';
const String _frameDir = '/tmp/ludo-393-frames';
const Key _shotKey = Key('probe-shot');

const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

const double _tapFloor = 48;
const double _fitSlop = 0.5;

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
// because tester.view.padding is physical pixels.
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

enum _GameCase { roll, wait, nomove, queue }

String _casePath(_GameCase state) {
  switch (state) {
    case _GameCase.roll:
      return 'game/roll';
    case _GameCase.wait:
      return 'game/wait';
    case _GameCase.nomove:
      return 'game/nomove';
    case _GameCase.queue:
      return 'game/queue';
  }
}

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'probe-shapes-game-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
      home: child,
    ),
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

/// [shape] is set in physical pixels (logical times dpr), including the
/// system insets, and the text scale goes through
/// [TestPlatformDispatcher.textScaleFactorTestValue], the same channel
/// test/board_budget_large_text_test.dart uses. Both are cleared before
/// the test returns, and again from a tearDown if the body never gets there.
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
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      if (owned != null) {
        owned.dispose();
      }
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
/// in the same pump, the next seat's `turn`. That arms the 1500ms no-move
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

Future<void> _expectMounted(WidgetTester tester, _GameCase state) async {
  expect(find.byType(GameScreen), findsOneWidget);
  expect(find.byKey(const Key('game-screen-board')), findsOneWidget);
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  final String banner;
  switch (state) {
    case _GameCase.roll:
      banner = loc.gameYourTurnRoll;
    case _GameCase.wait:
      banner = loc.gameWaitingForPlayer(_otherSeatName);
    case _GameCase.nomove:
      banner = loc.gameWaitingForPlayer(_otherSeatName);
    case _GameCase.queue:
      banner = loc.gameYourTurnMove;
  }
  expect(find.text(banner), findsWidgets);
  if (state == _GameCase.nomove) {
    expect(find.byKey(const Key('game-no-move-notice')), findsOneWidget);
  }
  if (state == _GameCase.queue) {
    expect(find.byKey(const Key('game-roll-tray')), findsOneWidget);
  }
}

// ---------------------------------------------------------------------------
// Measurement. Prints. Does not decide pass or fail.
// ---------------------------------------------------------------------------

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

String _boardField(WidgetTester tester) {
  final Finder finder = find.byKey(const Key('game-screen-board'));
  if (finder.evaluate().isEmpty) {
    return 'n/a(board-missing)';
  }
  final Size size = tester.getSize(finder);
  if (!size.width.isFinite || !size.height.isFinite) {
    return 'n/a(board-non-finite)';
  }
  return _dim(math.min(size.width, size.height));
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
      // Ellipsis and fade count when the text does not actually fit. A
      // paragraph that merely allows ellipsis, and then fits, is whole.
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
  const List<String> keys = <String>[
    'game-die',
    'game-screen-turn-banner',
    'game-no-move-notice',
    'game-roll-tray',
    'game-screen-board',
  ];
  final Rect safe = _safeRect(shape);
  final List<String> out = <String>[];
  for (final String keyName in keys) {
    final Finder finder = find.byKey(Key(keyName));
    if (finder.evaluate().isEmpty) {
      continue;
    }
    for (final Element element in finder.evaluate()) {
      final RenderObject? render = element.renderObject;
      if (render is! RenderBox || !render.attached || !render.hasSize) {
        out.add('$keyName n/a(no-rect)');
        continue;
      }
      try {
        final Rect rect = _globalRect(render);
        if (!_whollyInside(rect, safe)) {
          out.add(keyName);
        }
      } on Object catch (error) {
        out.add('$keyName ${_na(error)}');
      }
    }
  }
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
    // Token rows are the board-token-hit Semantics (the hit rect), not the
    // drawn disc. The disc has no tap action, so it never reaches here.
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
  required _GameCase state,
}) async {
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = captured.add;
  final String screen = _casePath(state);
  try {
    await _phone(tester, shape, scale, (_Keep keep) async {
      switch (state) {
        case _GameCase.roll:
          await _mountMyTurnToRoll(tester, keep, locale: locale);
        case _GameCase.wait:
          await _mountWaitingForOther(tester, keep, locale: locale);
        case _GameCase.nomove:
          await _mountNoMoveNotice(tester, keep, locale: locale);
        case _GameCase.queue:
          await _mountRollQueue(tester, keep, locale: locale);
      }
      await _expectMounted(tester, state);

      String board = 'n/a(not-measured)';
      String clipped = 'n/a(not-measured)';
      String unsafe = 'n/a(not-measured)';
      String small = 'n/a(not-measured)';
      try {
        board = _boardField(tester);
      } on Object catch (error) {
        board = _na(error);
      }
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
        for (final _GameCase state in _GameCase.values) {
          final String scaleLabel = scale.toStringAsFixed(1);
          final String label =
              '${shape.id} $scaleLabel ${locale.languageCode} ${_casePath(state)}';
          testWidgets(label, (WidgetTester tester) async {
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

// Order 393. One line and one PNG per phone shape, text scale and locale
// for the host's four-seat lobby and for home as a first-time player sees
// it (no last table, no recent code, no rejoin). This file does not assert
// that a name fits or that a control clears the system inset. The only
// expects are that the screen mounted.
//
// The lobby mount is copied from test/large_text_lobby_names_test.dart,
// with the four names this order names. The home mount is copied from
// test/large_text_home_test.dart, without that file's last-table seed.
// The text scale goes through textScaleFactorTestValue, the same channel
// as test/board_budget_large_text_test.dart. Fonts and the TextPainter
// helper are copied from that file. The PNG write follows
// test/ux_instrument_test.dart at pixelRatio 1.0. Nothing here is imported
// from another test file.

import 'dart:convert';
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
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://probe-shapes-room.invalid/ws';
const String _frameDir = '/tmp/ludo-393-frames';
const Key _shotKey = Key('probe-shot');

const String _seat0 = 'Karim12345';
const String _seat1 = 'Samantha12';
const String _seat2 = 'Abdulrahma';
const String _seat3 = 'Christophe';

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

enum _RoomCase { host4, home }

String _casePath(_RoomCase room) =>
    room == _RoomCase.host4 ? 'lobby/host4' : 'home/home';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'probe-shapes-room-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

List<Map<String, Object?>> _fourSeats() => <Map<String, Object?>>[
  _seatJson(0, name: _seat0),
  _seatJson(1, name: _seat1),
  _seatJson(2, name: _seat2),
  _seatJson(3, name: _seat3),
];

Map<String, Object?> _lobbyRoomJson() => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 4,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': _fourSeats(),
  'turn': null,
  'winner': null,
  'rematch': null,
  'seq': 1,
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

typedef _Keep = void Function(RoomController controller);

Widget _app({required Locale locale, required Widget home}) {
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
      home: home,
    ),
  );
}

RoomController _unusedController() {
  return RoomController(
    serverUrl: Uri.parse('wss://probe-shapes-home.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'probe_shapes_room_test: home must not open a transport',
      );
    },
  );
}

Future<void> _mountLobby(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  keep(controller);

  await tester.pumpWidget(
    _app(
      locale: locale,
      home: LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: _seat0,
        players: 4,
      ),
    ),
  );
  await tester.pump();
  expect(transport.sentRaw, isNotEmpty);
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: _lobbyRoomJson()));
  await tester.pump();
  await tester.pump();
  expect(controller.phase, RoomPhase.connected);
  expect(find.byType(LobbyScreen), findsOneWidget);
  expect(find.byKey(const Key('lobby-start-button')), findsOneWidget);
  for (final int seat in <int>[0, 1, 2, 3]) {
    expect(find.byKey(Key('lobby-seat-$seat')), findsOneWidget);
  }
  expect(find.text(_seat0), findsWidgets);
  expect(find.text(_seat1), findsWidgets);
  expect(find.text(_seat2), findsWidgets);
  expect(find.text(_seat3), findsWidgets);
}

Future<void> _mountHome(WidgetTester tester, {required Locale locale}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(
    _app(
      locale: locale,
      home: HomeScreen(
        onToggleLocale: () {},
        controllerFactory: _unusedController,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget);
  expect(find.byKey(const Key('create-room-button')), findsOneWidget);
  expect(find.byKey(const Key('join-room-button')), findsOneWidget);
  expect(find.byKey(const Key('home-last-table-chip')), findsNothing);
}

Future<void> _surface(
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

String _unsafeField(WidgetTester tester, _Shape shape, _RoomCase room) {
  final List<Element> targets = <Element>[];
  if (room == _RoomCase.host4) {
    final Finder buttons = find.descendant(
      of: find.byType(LobbyScreen),
      matching: find.byWidgetPredicate(
        (Widget widget) => widget is ButtonStyleButton || widget is IconButton,
      ),
    );
    targets.addAll(buttons.evaluate());
  } else {
    for (final String keyName in <String>[
      'create-room-button',
      'join-room-button',
    ]) {
      targets.addAll(find.byKey(Key(keyName)).evaluate());
    }
  }
  final Rect safe = _safeRect(shape);
  final List<String> out = <String>[];
  for (final Element element in targets) {
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
  required List<FlutterErrorDetails> errors,
  required String clipped,
  required String unsafe,
  required String small,
  required String png,
}) {
  final String scaleLabel = scale.toStringAsFixed(1);
  stdout.writeln(
    'SHAPE ${shape.id} $scaleLabel $locale $screen '
    'board=- overflow=${_overflowField(errors)} clipped=$clipped '
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
  required _RoomCase room,
}) async {
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = captured.add;
  final String screen = _casePath(room);
  try {
    await _surface(tester, shape, scale, (_Keep keep) async {
      if (room == _RoomCase.host4) {
        await _mountLobby(tester, keep, locale: locale);
      } else {
        await _mountHome(tester, locale: locale);
      }
      String clipped = 'n/a(not-measured)';
      String unsafe = 'n/a(not-measured)';
      String small = 'n/a(not-measured)';
      try {
        clipped = _clippedField(tester, shape);
      } on Object catch (error) {
        clipped = _na(error);
      }
      try {
        unsafe = _unsafeField(tester, shape, room);
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
        for (final _RoomCase room in _RoomCase.values) {
          final String scaleLabel = scale.toStringAsFixed(1);
          final String label =
              '${shape.id} $scaleLabel ${locale.languageCode} ${_casePath(room)}';
          testWidgets(label, (WidgetTester tester) async {
            await _runCase(
              tester,
              shape: shape,
              scale: scale,
              locale: locale,
              room: room,
            );
          });
        }
      }
    }
  }
}

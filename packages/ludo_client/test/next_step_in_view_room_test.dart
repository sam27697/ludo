// C-398. Lobby and home: the next step stays inside the safe area on the
// probe's phone shapes. Visibility is the keyed widget's global rect,
// wholly inside [padding.top, height - padding.bottom] and [0, width],
// read with the scroll at its start. The mount, the shapes, the insets,
// the text scale and the font load are copied from the order 393 probe
// (probe_shapes_room_test.dart), not imported. One mount per case.
//
// The s1 scale 2.0 focus case is the exception. It focuses room-code-field
// with showKeyboard, then sets a 260 dp bottom viewInset and reads
// join-room-button against height - max(padding.bottom, that inset).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart' show DieMark, dieMarkSize;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://probe-shapes-room.invalid/ws';

const String _seat0 = 'Karim12345';
const String _seat1 = 'Samantha12';
const String _seat2 = 'Abdulrahma';
const String _seat3 = 'Christophe';

const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

// The shape probe's own wholly-inside slop. The contract table was measured
// with it, so a sub-pixel edge classifies the same way here.
const double _fitSlop = 0.5;
const double _tapFloor = 48;

const Key _startKey = Key('lobby-start-button');
const Key _presentKey = Key('lobby-start-with-present-button');
const Key _waitingKey = Key('lobby-waiting');
const Key _createKey = Key('create-room-button');
const Key _codeKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');

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

enum _LobbyCase { host4, host3, guest3 }

String _lobbyState(_LobbyCase lobbyCase) => switch (lobbyCase) {
  _LobbyCase.host4 => 'lobby-host4',
  _LobbyCase.host3 => 'lobby-host3',
  _LobbyCase.guest3 => 'lobby-guest3',
};

List<Key> _shownKeys(_LobbyCase lobbyCase) => switch (lobbyCase) {
  _LobbyCase.host4 => const <Key>[_startKey],
  _LobbyCase.host3 => const <Key>[_presentKey, _waitingKey],
  _LobbyCase.guest3 => const <Key>[_waitingKey],
};

List<Key> _hiddenKeys(_LobbyCase lobbyCase) => switch (lobbyCase) {
  _LobbyCase.host4 => const <Key>[_presentKey, _waitingKey],
  _LobbyCase.host3 => const <Key>[_startKey],
  _LobbyCase.guest3 => const <Key>[_startKey, _presentKey],
};

List<Key> _hitKeys(_LobbyCase lobbyCase) => switch (lobbyCase) {
  _LobbyCase.host4 => const <Key>[_startKey],
  _LobbyCase.host3 => const <Key>[_presentKey],
  _LobbyCase.guest3 => const <Key>[],
};

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

List<Map<String, Object?>> _occupiedSeats(int count) {
  const List<String> names = <String>[_seat0, _seat1, _seat2, _seat3];
  return <Map<String, Object?>>[
    for (int i = 0; i < count; i++) _seatJson(i, name: names[i]),
  ];
}

Map<String, Object?> _lobbyRoomJson(int occupied) => <String, Object?>{
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
  'seats': _occupiedSeats(occupied),
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

RoomController _unusedController() {
  return RoomController(
    serverUrl: Uri.parse('wss://probe-shapes-home.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'next_step_in_view_room_test: home must not open a transport',
      );
    },
  );
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

String _scaleLabel(double scale) => scale.toStringAsFixed(1);

String _keyName(Key key) {
  if (key is ValueKey<String>) {
    return key.value;
  }
  return key.toString();
}

String _where(_Shape shape, double scale, Locale locale) =>
    '${shape.id}, scale ${_scaleLabel(scale)}, ${locale.languageCode}';

String _box(Rect rect) =>
    '${rect.left.toStringAsFixed(1)},${rect.top.toStringAsFixed(1)} '
    '${rect.right.toStringAsFixed(1)},${rect.bottom.toStringAsFixed(1)}';

double _bottomEdge(_Shape shape, double? bottomInset) =>
    shape.height - (bottomInset ?? shape.bottomInset);

String _safe(_Shape shape, {double? bottomInset}) =>
    '0,${shape.topInset.toStringAsFixed(0)} '
    '${shape.width.toStringAsFixed(0)},'
    '${_bottomEdge(shape, bottomInset).toStringAsFixed(0)}';

bool _whollyInside(Rect rect, _Shape shape, {double? bottomInset}) {
  return rect.left >= -_fitSlop &&
      rect.top >= shape.topInset - _fitSlop &&
      rect.right <= shape.width + _fitSlop &&
      rect.bottom <= _bottomEdge(shape, bottomInset) + _fitSlop;
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
  required _Shape shape,
  required String why,
  double? bottomInset,
}) {
  final Finder finder = find.byKey(key);
  final int count = finder.evaluate().length;
  final String name = _keyName(key);
  if (count != 1) {
    return '$why $name was found $count times, not once, so it is not on screen.';
  }
  final Rect rect = tester.getRect(finder);
  if (_whollyInside(rect, shape, bottomInset: bottomInset)) {
    return null;
  }
  return '$why $name rect ${_box(rect)} is outside the safe rect '
      '${_safe(shape, bottomInset: bottomInset)}.';
}

String? _hitProblem(
  WidgetTester tester, {
  required Key key,
  required String why,
}) {
  final Finder finder = find.byKey(key);
  final String name = _keyName(key);
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

String _hitSizes(WidgetTester tester, List<Key> keys) {
  if (keys.isEmpty) {
    return '-';
  }
  final List<String> parts = <String>[];
  for (final Key key in keys) {
    final Finder finder = find.byKey(key);
    if (finder.evaluate().length != 1) {
      parts.add('${_keyName(key)}=missing');
      continue;
    }
    final Size size = tester.getSize(finder);
    parts.add(
      '${_keyName(key)}=${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}',
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

Future<void> _mountLobby(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
  required _LobbyCase lobbyCase,
  required String where,
}) async {
  final bool guest = lobbyCase == _LobbyCase.guest3;
  final int occupied = lobbyCase == _LobbyCase.host4 ? 4 : 3;
  final int mySeat = guest ? 1 : 0;
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
        action: guest ? LobbyAction.join : LobbyAction.create,
        code: guest ? 'K7M2QP' : null,
        playerName: guest ? _seat1 : _seat0,
        players: 4,
      ),
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'decision 1, $where: LobbyScreen sends its one request on mount. '
        'Catches a lobby that never opens the room, so the next-step '
        'control is not the one a seated player sees.',
  );
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(type: 'room', re: id, data: _lobbyRoomJson(occupied)),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'decision 1, $where: the lobby is the connected room, not the '
        'connecting placeholder. Catches a reply the screen ignores, so '
        'the start control never appears.',
  );
  expect(
    find.byType(LobbyScreen),
    findsOneWidget,
    reason:
        'decision 1, $where: LobbyScreen is the mounted screen. Catches '
        'a mount that painted a different route.',
  );
}

Future<void> _mountHome(
  WidgetTester tester, {
  required Locale locale,
  required String where,
}) async {
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
  expect(
    find.byType(HomeScreen),
    findsOneWidget,
    reason:
        'decision 3, $where: HomeScreen is the mounted screen. Catches a '
        'mount that painted a different route.',
  );
  expect(
    find.byKey(_createKey),
    findsOneWidget,
    reason:
        'decision 3, $where: create-room-button is in the tree. Catches a '
        'home screen that drops the create step.',
  );
  expect(
    find.byKey(_joinKey),
    findsOneWidget,
    reason:
        'decision 3, $where: join-room-button is in the tree. Catches a '
        'home screen that drops the join step.',
  );
  expect(
    find.byKey(const Key('home-last-table-chip')),
    findsNothing,
    reason:
        'decision 3, $where: a first-time home has no last-table chip. '
        'Catches a seeded last table pushing the join step down, which '
        'is not the screen this case measures.',
  );
}

Future<void> _runLobby(
  WidgetTester tester, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required _LobbyCase lobbyCase,
  required List<FlutterErrorDetails> errors,
  required _Keep keep,
}) async {
  final String where = _where(shape, scale, locale);
  final bool checkVis = shape.checksVisibility;
  final List<Key> hits = _hitKeys(lobbyCase);
  final bool checkHit = checkVis && hits.isNotEmpty;
  await _mountLobby(
    tester,
    keep,
    locale: locale,
    lobbyCase: lobbyCase,
    where: where,
  );

  for (final Key key in _hiddenKeys(lobbyCase)) {
    expect(
      find.byKey(key),
      findsNothing,
      reason:
          'decision 1, $where: ${_keyName(key)} is not the control this '
          'seat shows. Catches a guest handed the host start button, or a '
          'full room still offering start-with-present.',
    );
  }
  for (final Key key in _shownKeys(lobbyCase)) {
    expect(
      find.byKey(key),
      findsOneWidget,
      reason:
          'decision 1, $where: ${_keyName(key)} has to be in the tree for '
          'this lobby state. Catches a host-full room that drops the start '
          'button, or a short room that drops the waiting line.',
    );
  }

  final List<String> visProblems = <String>[];
  if (checkVis) {
    final String? moved = _scrollNotAtStart(tester);
    if (moved != null) {
      visProblems.add(
        'decision 1, $where: a scroll view was already at $moved px, not '
        'at the start. Catches a lobby that scrolls the next step into '
        'view on mount instead of keeping it on screen at scroll zero.',
      );
    }
    for (final Key key in _shownKeys(lobbyCase)) {
      final String? problem = _visibilityProblem(
        tester,
        key: key,
        shape: shape,
        why:
            'decision 1, $where: the next step must sit wholly inside the '
            'safe area while the scroll is at its start. Catches a lobby '
            'that leaves ${_keyName(key)} in the scrolling column, so on '
            'a short phone it sits below the fold.',
      );
      if (problem != null) {
        visProblems.add(problem);
      }
    }
  }

  final List<String> hitProblems = <String>[];
  if (checkHit) {
    for (final Key key in hits) {
      final String? problem = _hitProblem(
        tester,
        key: key,
        why:
            'decision 5, $where: a docked control keeps a $_tapFloor dp '
            'hit target on both axes. Catches a lobby action button whose '
            'hit box shrinks below $_tapFloor dp.',
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
    state: _lobbyState(lobbyCase),
    shape: shape,
    scale: scale,
    locale: locale,
    vis: checkVis ? visProblems.isEmpty : null,
    hit: checkHit ? hitProblems.isEmpty : null,
    err: errProblems.isEmpty,
    hitSizes: checkHit ? _hitSizes(tester, hits) : '-',
  );

  if (checkVis) {
    expect(
      visProblems,
      isEmpty,
      reason:
          'decision 1, $where: ${_shownKeys(lobbyCase).map(_keyName).join(' and ')} '
          'must lie wholly inside the safe area at scroll start. Catches a '
          'lobby that keeps that control in the scrolling column, so on a '
          'short phone it sits below the fold. ${visProblems.join(' ')}',
    );
  }
  expect(
    errProblems,
    isEmpty,
    reason:
        'decision 5, $where: ${_lobbyState(lobbyCase)} reports no '
        'FlutterError. Catches a row or a line that overflows instead of '
        'wrapping. ${errProblems.join(' ')}',
  );
  if (checkHit) {
    expect(
      hitProblems,
      isEmpty,
      reason:
          'decision 5, $where: the docked lobby control is at least '
          '$_tapFloor dp both ways. Catches a hit box shrunk below that '
          'floor. ${hitProblems.join(' ')}',
    );
  }
}

Future<void> _runHomeAtRest(
  WidgetTester tester, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required List<FlutterErrorDetails> errors,
}) async {
  final String where = _where(shape, scale, locale);
  await _mountHome(tester, locale: locale, where: where);
  const List<Key> keys = <Key>[_createKey, _codeKey, _joinKey];
  final List<String> visProblems = <String>[];
  final String? moved = _scrollNotAtStart(tester);
  if (moved != null) {
    visProblems.add(
      'decision 3, $where: a scroll view was already at $moved px, not at '
      'the start. Catches a home screen that scrolls the join step into '
      'view on mount instead of fitting it at scroll zero.',
    );
  }
  for (final Key key in keys) {
    final String? problem = _visibilityProblem(
      tester,
      key: key,
      shape: shape,
      why:
          'decision 3, $where: create, the code field and join must all '
          'sit wholly inside the safe area at scroll start on 1.0 and 1.3. '
          'Catches a home screen that leaves ${_keyName(key)} below the '
          'fold, so joining needs a scroll the screen never asks for.',
    );
    if (problem != null) {
      visProblems.add(problem);
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
    state: 'home',
    shape: shape,
    scale: scale,
    locale: locale,
    vis: visProblems.isEmpty,
    hit: null,
    err: errProblems.isEmpty,
    hitSizes: '-',
  );
  expect(
    visProblems,
    isEmpty,
    reason:
        'decision 3, $where: create-room-button, room-code-field and '
        'join-room-button must lie wholly inside the safe area at scroll '
        'start. Catches a home screen that drops the join step below the '
        'fold at 1.0 or 1.3. ${visProblems.join(' ')}',
  );
  expect(
    errProblems,
    isEmpty,
    reason:
        'decision 5, $where: home reports no FlutterError. Catches a row '
        'or a line that overflows instead of wrapping. ${errProblems.join(' ')}',
  );
}

Future<void> _runHomeFocus(
  WidgetTester tester, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required List<FlutterErrorDetails> errors,
}) async {
  final String where = _where(shape, scale, locale);
  await _mountHome(tester, locale: locale, where: where);
  // showKeyboard focuses the field even when its center sits below the
  // root. A tap at that offset misses, so the field never takes focus.
  await tester.showKeyboard(find.byKey(const Key('room-code-field')));
  final EditableTextState fieldState = tester.state<EditableTextState>(
    find.descendant(
      of: find.byKey(_codeKey),
      matching: find.byType(EditableText),
    ),
  );
  expect(
    fieldState.widget.focusNode.hasFocus,
    isTrue,
    reason:
        'decision 3, $where: room-code-field takes focus from '
        'showKeyboard. Catches a focus request that never lands, so '
        'join-room-button would be checked while the field is still '
        'unfocused.',
  );
  // 260 logical dp, in physical pixels like the other view insets. The
  // phone's keyboard. The join button has to clear that, not only the
  // nav-bar padding.
  const double keyboardInset = 260;
  final double bottomInset = shape.bottomInset > keyboardInset
      ? shape.bottomInset
      : keyboardInset;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset * shape.dpr);
  final List<String> visProblems = <String>[];
  try {
    // The room-link scroll runs for 300ms. Six 100ms pumps cover it.
    // Bounded on purpose: not pumpAndSettle.
    await tester.pump();
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final String? problem = _visibilityProblem(
      tester,
      key: _joinKey,
      shape: shape,
      bottomInset: bottomInset,
      why:
          'decision 3, $where: after room-code-field takes focus, a 260 dp '
          'keyboard inset must leave join-room-button wholly inside '
          '[padding.top, height - max(padding.bottom, 260)] and [0, width]. '
          'Catches a code field that takes focus without bringing Join up '
          'with it, so Join sits under the keyboard at text scale 2.0.',
    );
    if (problem != null) {
      visProblems.add(problem);
    }
  } finally {
    tester.view.viewInsets = FakeViewPadding();
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
    state: 'home-focus',
    shape: shape,
    scale: scale,
    locale: locale,
    vis: visProblems.isEmpty,
    hit: null,
    err: errProblems.isEmpty,
    hitSizes: '-',
  );
  expect(
    visProblems,
    isEmpty,
    reason:
        'decision 3, $where: after showKeyboard on room-code-field, a '
        '260 dp bottom viewInset and six bounded 100ms frames, '
        'join-room-button lies inside [padding.top, height - '
        'max(padding.bottom, 260)]. Catches a code field that takes '
        'focus without bringing Join with it. ${visProblems.join(' ')}',
  );
  expect(
    errProblems,
    isEmpty,
    reason:
        'decision 5, $where: home at 2.0 reports no FlutterError after the '
        'code field takes focus. Catches a row or a line that overflows '
        'instead of wrapping. ${errProblems.join(' ')}',
  );
}

Future<void> _runHomeOverflow(
  WidgetTester tester, {
  required _Shape shape,
  required double scale,
  required Locale locale,
  required List<FlutterErrorDetails> errors,
}) async {
  final String where = _where(shape, scale, locale);
  await _mountHome(tester, locale: locale, where: where);
  expect(
    find.byKey(_codeKey),
    findsOneWidget,
    reason:
        'decision 5, $where: room-code-field is in the tree so the '
        'overflow check is about home. Catches a mount that never built '
        'the join step.',
  );
  final List<String> errProblems = <String>[];
  if (errors.isNotEmpty) {
    errProblems.add(
      'decision 5, $where: the mount reported ${errors.length} '
      'FlutterError(s), first "${_firstError(errors)}". Catches a row or '
      'a line that overflows instead of wrapping.',
    );
  }
  _emit(
    state: 'home-overflow',
    shape: shape,
    scale: scale,
    locale: locale,
    vis: null,
    hit: null,
    err: errProblems.isEmpty,
    hitSizes: '-',
  );
  expect(
    errProblems,
    isEmpty,
    reason:
        'decision 5, $where: home reports no FlutterError. Overflow only '
        'on this shape: visibility is not required here. Catches a row or '
        'a line that overflows instead of wrapping. ${errProblems.join(' ')}',
  );
}

Future<void> _runCompact(
  WidgetTester tester, {
  required _Shape shape,
  required String screen,
  required Locale locale,
  required List<FlutterErrorDetails> errors,
  required Future<void> Function() mount,
}) async {
  const double scale = 1.0;
  final String where = _where(shape, scale, locale);
  await mount();
  expect(
    find.byType(DieMark),
    findsOneWidget,
    reason:
        'decision 4, $where: $screen lays out one DieMark, the observable '
        'dieMarkSize(compact) is passed to. Catches a screen that drops '
        'the mark or paints a second one.',
  );
  final DieMark mark = tester.widget<DieMark>(find.byType(DieMark));
  final Size rendered = tester.getSize(find.byType(DieMark));
  final double compactMark = dieMarkSize(true);
  final double roomyMark = dieMarkSize(false);
  stdout.writeln(
    'COMPACT screen=$screen shape=${shape.id} scale=1.0 '
    'locale=${locale.languageCode} dieMark.size=${mark.size} '
    'rendered=${rendered.width.toStringAsFixed(1)}x'
    '${rendered.height.toStringAsFixed(1)} '
    'dieMarkSize(true)=$compactMark dieMarkSize(false)=$roomyMark '
    'errors=${errors.length}',
  );
  expect(
    mark.size,
    compactMark,
    reason:
        'decision 4, $where: $screen lays out compact. DieMark.size is '
        '${mark.size}, dieMarkSize(true) is $compactMark, dieMarkSize(false) '
        'is $roomyMark. Safe height is ${shape.height} - ${shape.topInset} - '
        '${shape.bottomInset} = '
        '${shape.height - shape.topInset - shape.bottomInset}, which is under '
        'the existing 640 threshold, so the mark must take the compact '
        'size. Catches a compact check that still reads the raw screen '
        'height (s2 is 640, which is not under 640) instead of the height '
        'inside the safe area. Compared with the other of s1 and s2 at '
        '1.0, which must take the same compact size.',
  );
  expect(
    errors,
    isEmpty,
    reason:
        'decision 5, $where: $screen at the compact measurement reports '
        'no FlutterError. Catches a row or a line that overflows instead '
        'of wrapping.',
  );
}

void main() {
  setUpAll(() async {
    await _loadAppFonts();
  });

  for (final _Shape shape in _shapes) {
    for (final double scale in _scales) {
      for (final Locale locale in _locales) {
        for (final _LobbyCase lobbyCase in _LobbyCase.values) {
          final String label =
              '${_lobbyState(lobbyCase)} ${shape.id} ${_scaleLabel(scale)} '
              '${locale.languageCode}';
          testWidgets(label, (WidgetTester tester) async {
            final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
            final FlutterExceptionHandler? previous = FlutterError.onError;
            FlutterError.onError = errors.add;
            try {
              await _surface(tester, shape, scale, (_Keep keep) async {
                await _runLobby(
                  tester,
                  shape: shape,
                  scale: scale,
                  locale: locale,
                  lobbyCase: lobbyCase,
                  errors: errors,
                  keep: keep,
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

  for (final _Shape shape in _shapes) {
    for (final double scale in _scales) {
      for (final Locale locale in _locales) {
        final bool atRest = shape.checksVisibility && scale < 2.0;
        final bool focus = shape.id == 's1' && scale == 2.0;
        final String kind = atRest
            ? 'home'
            : focus
            ? 'home-focus'
            : 'home-overflow';
        final String label =
            '$kind ${shape.id} ${_scaleLabel(scale)} ${locale.languageCode}';
        testWidgets(label, (WidgetTester tester) async {
          final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
          final FlutterExceptionHandler? previous = FlutterError.onError;
          FlutterError.onError = errors.add;
          try {
            await _surface(tester, shape, scale, (_Keep keep) async {
              if (atRest) {
                await _runHomeAtRest(
                  tester,
                  shape: shape,
                  scale: scale,
                  locale: locale,
                  errors: errors,
                );
              } else if (focus) {
                await _runHomeFocus(
                  tester,
                  shape: shape,
                  scale: scale,
                  locale: locale,
                  errors: errors,
                );
              } else {
                await _runHomeOverflow(
                  tester,
                  shape: shape,
                  scale: scale,
                  locale: locale,
                  errors: errors,
                );
              }
            });
          } finally {
            FlutterError.onError = previous;
          }
        });
      }
    }
  }

  for (final _Shape shape in <_Shape>[_shapes[0], _shapes[1]]) {
    const Locale locale = Locale('en');
    testWidgets('compact home ${shape.id} 1.0 en', (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      final String where = _where(shape, 1.0, locale);
      try {
        await _surface(tester, shape, 1.0, (_Keep keep) async {
          await _runCompact(
            tester,
            shape: shape,
            screen: 'home',
            locale: locale,
            errors: errors,
            mount: () => _mountHome(tester, locale: locale, where: where),
          );
        });
      } finally {
        FlutterError.onError = previous;
      }
    });
    testWidgets('compact lobby ${shape.id} 1.0 en', (
      WidgetTester tester,
    ) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      final String where = _where(shape, 1.0, locale);
      try {
        await _surface(tester, shape, 1.0, (_Keep keep) async {
          await _runCompact(
            tester,
            shape: shape,
            screen: 'lobby',
            locale: locale,
            errors: errors,
            mount: () => _mountLobby(
              tester,
              keep,
              locale: locale,
              lobbyCase: _LobbyCase.host4,
              where: where,
            ),
          );
        });
      } finally {
        FlutterError.onError = previous;
      }
    });
  }
}

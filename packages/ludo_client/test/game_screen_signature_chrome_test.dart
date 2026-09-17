// Signature chrome on GameScreen: a seat-pip strip and felt edge must live in
// the shared scaffold chrome so waiting, playing, and game-over all carry the
// brand. Compact geometry must keep Roll and Leave at least 48dp, and the
// brand theme must still meet textContrast with that chrome mounted.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

const Key _seatPipStripKey = Key('game-seat-pip-strip');
const Key _feltEdgeKey = Key('game-felt-edge');
const Key _rollKey = Key('game-screen-roll-button');
const Key _leaveKey = Key('game-screen-appbar-leave');
const Key _waitingKey = Key('game-screen-waiting');
const Key _boardKey = Key('game-screen-board');
const Key _winnerKey = Key('game-screen-winner');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'sig-chrome-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
};

Map<String, Object?> _roomJson({
  required String state,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  int players = 2,
  int seq = 1,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': state,
  'host_seat': 0,
  'players': players,
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
  'winner': winner,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('no FakeTransport queued for connect($url)');
    }
    return _queue.removeAt(0);
  }
}

Future<RoomController> _connectRoom(
  WidgetTester tester, {
  required String state,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  int players = 2,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(
    name: 'Sam',
    players: players,
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
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: state,
        seats: seats,
        turn: turn,
        winner: winner,
        players: players,
      ),
    ),
  );
  await future;
  return controller;
}

Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: const Locale('en'),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mount(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(_harness(GameScreen(controller: controller)));
  await tester.pump();
  await tester.pump();
}

final List<Map<String, Object?>> _twoSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam', tokens: const <int>[-1, 0, -1, -1]),
  _seatJson(1, name: 'Bob'),
];

Map<String, Object?> _awaitRollTurn() =>
    _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0);

Color? _solidColorOf(Widget widget) {
  if (widget is ColoredBox) {
    return widget.color;
  }
  if (widget is Material) {
    return widget.color;
  }
  if (widget is Container) {
    final Decoration? decoration = widget.decoration;
    if (decoration is BoxDecoration && decoration.color != null) {
      return decoration.color;
    }
    return widget.color;
  }
  if (widget is DecoratedBox) {
    final Decoration decoration = widget.decoration;
    if (decoration is BoxDecoration) {
      return decoration.color;
    }
  }
  return null;
}

Color _requireColor(WidgetTester tester, Finder finder, String label) {
  expect(finder, findsOneWidget, reason: '$label must be present');
  Color? found = _solidColorOf(tester.widget(finder));
  if (found != null) {
    return found;
  }
  final Element root = tester.element(finder);
  Color? childColor;
  void visit(Element element) {
    if (childColor != null) {
      return;
    }
    childColor = _solidColorOf(element.widget);
    if (childColor == null) {
      element.visitChildren(visit);
    }
  }

  root.visitChildren(visit);
  expect(
    childColor,
    isNotNull,
    reason: '$label must expose a solid colour on itself or a descendant',
  );
  return childColor!;
}

void _expectSeatPipStrip(WidgetTester tester) {
  final Finder strip = find.byKey(_seatPipStripKey);
  expect(
    strip,
    findsOneWidget,
    reason: 'game-seat-pip-strip must be present in game chrome',
  );

  for (int i = 0; i < LudoColors.seats.length; i++) {
    final Finder pip = find.descendant(
      of: strip,
      matching: find.byKey(Key('game-seat-pip-$i')),
    );
    expect(
      pip,
      findsOneWidget,
      reason:
          'game-seat-pip-strip must contain game-seat-pip-$i in '
          'LudoColors.seats order',
    );
    final Color color = _requireColor(tester, pip, 'game-seat-pip-$i');
    expect(
      color,
      LudoColors.seats[i],
      reason:
          'game-seat-pip-$i must use LudoColors.seats[$i] '
          '(${LudoColors.seats[i]}), was $color',
    );
  }
}

void _expectFeltEdge(WidgetTester tester) {
  final Finder edge = find.byKey(_feltEdgeKey);
  expect(
    edge,
    findsOneWidget,
    reason: 'game-felt-edge must be present in game chrome',
  );
  final Color color = _requireColor(tester, edge, 'game-felt-edge');
  final LudoBrand? brand = Theme.of(tester.element(edge))
      .extension<LudoBrand>();
  final bool matchesFeltMid = color == LudoColors.feltMid;
  final bool matchesExtensionFelt = brand != null && color == brand.felt;
  expect(
    matchesFeltMid || matchesExtensionFelt,
    isTrue,
    reason:
        'game-felt-edge colour must be LudoColors.feltMid '
        '(${LudoColors.feltMid}) or ThemeExtension LudoBrand.felt '
        '(${brand?.felt}), was $color',
  );
}

void main() {
  testWidgets(
    'seat-pip strip with four LudoColors.seats pips is present while waiting',
    (WidgetTester tester) async {
      final RoomController controller = await _connectRoom(
        tester,
        state: 'LOBBY',
        seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
        turn: null,
        players: 4,
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      expect(
        find.byKey(_waitingKey),
        findsOneWidget,
        reason: 'fixture must reach the waiting body',
      );
      _expectSeatPipStrip(tester);
    },
  );

  testWidgets(
    'seat-pip strip with four LudoColors.seats pips is present while playing',
    (WidgetTester tester) async {
      final RoomController controller = await _connectRoom(
        tester,
        state: 'PLAYING',
        seats: _twoSeats,
        turn: _awaitRollTurn(),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason: 'fixture must reach the playing board',
      );
      _expectSeatPipStrip(tester);
    },
  );

  testWidgets(
    'seat-pip strip with four LudoColors.seats pips is present at game-over',
    (WidgetTester tester) async {
      final RoomController controller = await _connectRoom(
        tester,
        state: 'FINISHED',
        seats: _twoSeats,
        turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 5),
        winner: 0,
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      expect(
        find.byKey(_winnerKey),
        findsOneWidget,
        reason: 'fixture must reach the game-over body',
      );
      _expectSeatPipStrip(tester);
    },
  );

  testWidgets(
    'game-felt-edge uses LudoColors.feltMid or extension felt colour',
    (WidgetTester tester) async {
      final RoomController controller = await _connectRoom(
        tester,
        state: 'PLAYING',
        seats: _twoSeats,
        turn: _awaitRollTurn(),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      _expectFeltEdge(tester);
    },
  );

  testWidgets(
    'at 360x600 Roll and Leave are at least 48dp with signature chrome visible',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final RoomController controller = await _connectRoom(
        tester,
        state: 'PLAYING',
        seats: _twoSeats,
        turn: _awaitRollTurn(),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      _expectSeatPipStrip(tester);
      _expectFeltEdge(tester);

      final Finder leave = find.byKey(_leaveKey);
      final Finder roll = find.byKey(_rollKey);
      expect(leave, findsOneWidget, reason: 'Leave must be visible at 360x600');
      expect(roll, findsOneWidget, reason: 'Roll must be visible at 360x600');

      final Size leaveSize = tester.getSize(leave);
      final Size rollSize = tester.getSize(roll);
      expect(
        leaveSize.width,
        greaterThanOrEqualTo(48.0),
        reason: 'Leave width must be ≥48 at 360x600, was ${leaveSize.width}',
      );
      expect(
        leaveSize.height,
        greaterThanOrEqualTo(48.0),
        reason: 'Leave height must be ≥48 at 360x600, was ${leaveSize.height}',
      );
      expect(
        rollSize.width,
        greaterThanOrEqualTo(48.0),
        reason: 'Roll width must be ≥48 at 360x600, was ${rollSize.width}',
      );
      expect(
        rollSize.height,
        greaterThanOrEqualTo(48.0),
        reason: 'Roll height must be ≥48 at 360x600, was ${rollSize.height}',
      );
    },
  );

  testWidgets(
    'game screen textContrastGuideline passes with signature chrome present',
    (WidgetTester tester) async {
      final RoomController controller = await _connectRoom(
        tester,
        state: 'PLAYING',
        seats: _twoSeats,
        turn: _awaitRollTurn(),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason: 'fixture must reach the playing board before contrast check',
      );
      _expectSeatPipStrip(tester);
      _expectFeltEdge(tester);

      await expectLater(tester, meetsGuideline(textContrastGuideline));
    },
  );
}

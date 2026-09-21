// Signature chrome on LobbyScreen: the connected gathering body must carry
// the same felt-edge and seat-pip strip cues as GameScreen so home→lobby→
// game reads as one continuous table. Accepts either game-* keys (shared
// widgets) or lobby-* keys (lobby-scoped mounts).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const Key _roomCodeKey = Key('lobby-room-code');
const Key _startKey = Key('lobby-start-button');

const Key _gameFeltEdgeKey = Key('game-felt-edge');
const Key _lobbyFeltEdgeKey = Key('lobby-felt-edge');
const Key _gameSeatPipStripKey = Key('game-seat-pip-strip');
const Key _lobbySeatPipStripKey = Key('lobby-seat-pip-strip');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'lobby-sig-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {String name = 'Sam'}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  String code = 'ABC234',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
  'host_seat': hostSeat,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat)],
  'turn': null,
  'winner': null,
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

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

Widget _localizations({required Widget home}) {
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
    home: home,
  );
}

Future<void> _pumpConnectedHostLobby(WidgetTester tester) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    _localizations(
      home: LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 4,
      ),
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason: 'LobbyScreen must have sent create_room',
  );
  final String requestId = _idOf(transport.sentRaw.last);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(
        players: 4,
        hostSeat: 0,
        seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(controller.phase, RoomPhase.connected);
  expect(
    find.byKey(_roomCodeKey),
    findsOneWidget,
    reason: 'fixture must reach the connected lobby body',
  );
  expect(
    find.byKey(_startKey),
    findsOneWidget,
    reason: 'connected lobby must show the host Start control',
  );
}

Finder _lobbyScope() => find.byType(LobbyScreen);

Finder _feltEdgeInLobby() {
  final Finder game = find.descendant(
    of: _lobbyScope(),
    matching: find.byKey(_gameFeltEdgeKey),
  );
  if (game.evaluate().isNotEmpty) {
    return game;
  }
  return find.descendant(
    of: _lobbyScope(),
    matching: find.byKey(_lobbyFeltEdgeKey),
  );
}

Finder _seatPipStripInLobby() {
  final Finder game = find.descendant(
    of: _lobbyScope(),
    matching: find.byKey(_gameSeatPipStripKey),
  );
  if (game.evaluate().isNotEmpty) {
    return game;
  }
  return find.descendant(
    of: _lobbyScope(),
    matching: find.byKey(_lobbySeatPipStripKey),
  );
}

Finder _pipInStrip(Finder strip, int index) {
  final Finder gamePip = find.descendant(
    of: strip,
    matching: find.byKey(Key('game-seat-pip-$index')),
  );
  if (gamePip.evaluate().isNotEmpty) {
    return gamePip;
  }
  return find.descendant(
    of: strip,
    matching: find.byKey(Key('lobby-seat-pip-$index')),
  );
}

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

void _expectLobbyFeltEdge(WidgetTester tester) {
  final Finder edge = _feltEdgeInLobby();
  expect(
    edge,
    findsOneWidget,
    reason:
        'connected LobbyScreen must mount game-felt-edge or lobby-felt-edge',
  );
  final Color color = _requireColor(tester, edge, 'lobby felt-edge');
  final LudoBrand? brand = Theme.of(tester.element(edge))
      .extension<LudoBrand>();
  final bool matchesFeltMid = color == LudoColors.feltMid;
  final bool matchesExtensionFelt = brand != null && color == brand.felt;
  expect(
    matchesFeltMid || matchesExtensionFelt,
    isTrue,
    reason:
        'lobby felt-edge colour must be LudoColors.feltMid '
        '(${LudoColors.feltMid}) or ThemeExtension LudoBrand.felt '
        '(${brand?.felt}), was $color',
  );
}

void _expectLobbySeatPipStrip(WidgetTester tester) {
  final Finder strip = _seatPipStripInLobby();
  expect(
    strip,
    findsOneWidget,
    reason:
        'connected LobbyScreen must mount game-seat-pip-strip or '
        'lobby-seat-pip-strip',
  );

  expect(
    LudoColors.seats.length,
    greaterThanOrEqualTo(4),
    reason: 'LudoColors.seats must define at least four seat colours',
  );

  for (int i = 0; i < LudoColors.seats.length; i++) {
    final Finder pip = _pipInStrip(strip, i);
    expect(
      pip,
      findsOneWidget,
      reason:
          'lobby seat-pip strip must contain game-seat-pip-$i or '
          'lobby-seat-pip-$i in LudoColors.seats order',
    );
    final Color color = _requireColor(tester, pip, 'seat-pip-$i');
    expect(
      color,
      LudoColors.seats[i],
      reason:
          'seat-pip-$i must use LudoColors.seats[$i] '
          '(${LudoColors.seats[i]}), was $color',
    );
  }
}

void main() {
  testWidgets(
    'connected lobby mounts felt-edge keyed game-felt-edge or lobby-felt-edge',
    (WidgetTester tester) async {
      await _pumpConnectedHostLobby(tester);
      _expectLobbyFeltEdge(tester);
    },
  );

  testWidgets(
    'connected lobby mounts seat-pip strip with four LudoColors.seats pips',
    (WidgetTester tester) async {
      await _pumpConnectedHostLobby(tester);
      _expectLobbySeatPipStrip(tester);
    },
  );
}

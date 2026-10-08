// Playing board width against the view, C-272 / X10.
//
// At 360x800 and at 411x704, dpr 1, game-screen-board's width is at least
// 92% of the view width. The threshold is not lowered. The measured
// percentage is printed either way: a miss here can come from padding or
// the play header, which this contract does not change, and the number is
// what the report records.
//
// GameScreen is driven the same way test/game_screen_appbar_leave_label_test
// .dart drives RoomController. One mount per case. deadline_ms is 0 so the
// turn countdown does not arm a ticker.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const Key _boardKey = Key('game-screen-board');
const double _minShare = 0.92;

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'share-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {String name = ''}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson() => <String, Object?>{
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
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ],
  'turn': <String, Object?>{
    'seat': 0,
    'phase': 'await_roll',
    'deadline_ms': 0,
    'k': 0,
  },
  'winner': null,
  'seq': 1,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

Future<RoomController> _connectPlaying(WidgetTester tester) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
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
  transport.pushText(_frame(type: 'room', re: id, data: _roomJson()));
  await future;
  return controller;
}

void _setView(WidgetTester tester, Size logical) {
  tester.view.physicalSize = logical;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _expectBoardShare(WidgetTester tester, Size logical) async {
  _setView(tester, logical);
  final RoomController controller = await _connectPlaying(tester);
  var disposed = false;
  addTearDown(() {
    if (!disposed) {
      disposed = true;
      controller.dispose();
    }
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: GameScreen(controller: controller),
    ),
  );
  await tester.pump();

  expect(
    find.byKey(_boardKey),
    findsOneWidget,
    reason: 'fixture is broken: PLAYING must show game-screen-board',
  );
  final double viewWidth =
      tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final double boardWidth = tester.getSize(find.byKey(_boardKey)).width;
  final double share = boardWidth / viewWidth;
  // The key sits on LudoBoard. Its box is the slot the playing column gives
  // it. The painted board is the largest square inside that slot, and it is
  // smaller when the slot is taller than it is wide. Printed, not asserted:
  // the 92% bar below is the keyed box, which is what this file was asked
  // to measure.
  double? squareSide;
  final Finder boxes = find.descendant(
    of: find.byKey(_boardKey),
    matching: find.byType(SizedBox),
  );
  for (final Element element in boxes.evaluate()) {
    final RenderObject? object = element.renderObject;
    if (object is! RenderBox || !object.hasSize) {
      continue;
    }
    final Size size = object.size;
    if (size.width != size.height || size.width <= 1) {
      continue;
    }
    if (squareSide == null || size.width > squareSide) {
      squareSide = size.width;
    }
  }
  final String squareText = squareSide == null
      ? 'square=absent'
      : 'square=${squareSide.toStringAsFixed(1)}';
  stdout.writeln(
    'BOARD_SHARE ${logical.width.toStringAsFixed(0)}x'
    '${logical.height.toStringAsFixed(0)} '
    'board=${boardWidth.toStringAsFixed(1)} '
    'view=${viewWidth.toStringAsFixed(1)} '
    'pct=${(share * 100).toStringAsFixed(2)} '
    '$squareText',
  );
  expect(
    share,
    greaterThanOrEqualTo(_minShare),
    reason:
        'game-screen-board width must be at least 92% of the view width '
        'at ${logical.width.toStringAsFixed(0)}x'
        '${logical.height.toStringAsFixed(0)}; '
        'board ${boardWidth.toStringAsFixed(1)} / view '
        '${viewWidth.toStringAsFixed(1)} = '
        '${(share * 100).toStringAsFixed(2)}%',
  );
  disposed = true;
  controller.dispose();
}

void main() {
  testWidgets('at 360x800 the playing board is at least 92% of the width', (
    tester,
  ) async {
    await _expectBoardShare(tester, const Size(360, 800));
  });

  testWidgets('at 411x704 the playing board is at least 92% of the width', (
    tester,
  ) async {
    await _expectBoardShare(tester, const Size(411, 704));
  });
}

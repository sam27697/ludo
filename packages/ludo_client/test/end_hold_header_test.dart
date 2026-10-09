// C-290 rule 2. The end hold is driven the way test/end_hold_test.dart
// drives it: a real RoomController over FakeTransport, a travelling moved,
// then game_over, read while the board is up and the end card is not.
//
// end_hold_test.dart connects with turn null so nothing arms a countdown.
// These rooms carry a turn. A null turn would make the banner the no-turn
// waiting line; the recording's header names the seat whose phase has
// become finished. Pumps stay bounded (two per frame, the sibling's own
// flush). No pumpAndSettle, no bare pumpEventQueue() in a testWidgets
// body. The controller is disposed in the test body.
//
// A reconnect snapshot of an already finished room is not a case here.
// The hold is armed only when this mount has already seen a travelling
// moved and then a game_over. A fresh finished snapshot takes the end
// card, so the play banner is not on screen to read.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://end-hold-header-test.invalid/ws';

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _dieKey = Key('game-die');
const Key _winnerKey = Key('game-screen-winner');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'end-hold-header-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _turnJson({required int seat}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': 45000,
  'k': 0,
};

Map<String, Object?> _roomJson({
  required List<Map<String, Object?>> seats,
  required Map<String, Object?> turn,
  int seq = 1,
}) => <String, Object?>{
  'code': 'E4ND72',
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
  required int turnSeat,
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
      data: _roomJson(
        seats: seats,
        turn: _turnJson(seat: turnSeat),
      ),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
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
  Locale locale = const Locale('en'),
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

Future<void> _pushMoved(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int from,
  required int to,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': seat,
        'token': 0,
        'from': from,
        'to': to,
        'captured': <Map<String, Object?>>[],
        'extra_roll': false,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pushGameOver(
  WidgetTester tester,
  FakeTransport transport, {
  required int winner,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'game_over',
      data: <String, Object?>{
        'winner': winner,
        'verify_url': 'https://end-hold-header-test.invalid/verify/$seq',
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Unmounts first, so GameScreen drops its listener before the controller
/// closes, then disposes the controller. Runs from the test body.
Future<void> _dispose(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  controller.dispose();
}

void _expectHoldBanner(
  WidgetTester tester, {
  required String bannerText,
  required String absentFragment,
  required String label,
}) {
  expect(
    find.byKey(_dieKey),
    findsOneWidget,
    reason: '$label: the end hold must still show the board',
  );
  expect(
    find.byKey(_winnerKey),
    findsNothing,
    reason: '$label: the end card must not be up yet',
  );
  expect(
    tester.widget<Text>(find.byKey(_bannerKey)).data,
    bannerText,
    reason: '$label: banner text during the end hold',
  );
  expect(
    find.textContaining(absentFragment),
    findsNothing,
    reason: '$label: nothing on screen may contain "$absentFragment"',
  );
}

void main() {
  testWidgets(
    'local seat wins: during the end hold the banner is Game over and '
    'nothing contains Waiting for',
    (tester) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[51, -1, -1, -1]),
        _seatJson(1, name: 'Bob'),
      ];
      RoomController? controller;
      try {
        final (
          RoomController connected,
          FakeTransport transport,
        ) = await _connect(
          tester,
          (RoomController c) {
            controller = c;
          },
          seats: seats,
          turnSeat: 0,
        );
        controller = connected;
        await _mount(tester, connected);
        await _pushMoved(tester, transport, seat: 0, from: 51, to: 57, seq: 2);
        await _pushGameOver(tester, transport, winner: 0, seq: 3);
        _expectHoldBanner(
          tester,
          bannerText: 'Game over',
          absentFragment: 'Waiting for',
          label: 'local win',
        );
      } finally {
        final RoomController? owned = controller;
        if (owned != null) {
          await _dispose(tester, owned);
        }
      }
    },
  );

  testWidgets(
    'local seat loses: during the end hold the banner is Game over and '
    'nothing contains Waiting for',
    (tester) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob', tokens: const <int>[51, -1, -1, -1]),
      ];
      RoomController? controller;
      try {
        final (
          RoomController connected,
          FakeTransport transport,
        ) = await _connect(
          tester,
          (RoomController c) {
            controller = c;
          },
          seats: seats,
          turnSeat: 1,
        );
        controller = connected;
        await _mount(tester, connected);
        await _pushMoved(tester, transport, seat: 1, from: 51, to: 57, seq: 2);
        await _pushGameOver(tester, transport, winner: 1, seq: 3);
        _expectHoldBanner(
          tester,
          bannerText: 'Game over',
          absentFragment: 'Waiting for',
          label: 'local loss',
        );
      } finally {
        final RoomController? owned = controller;
        if (owned != null) {
          await _dispose(tester, owned);
        }
      }
    },
  );

  testWidgets(
    'ar, local seat wins: during the end hold the banner is انتهت اللعبة '
    'and nothing contains بانتظار',
    (tester) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[51, -1, -1, -1]),
        _seatJson(1, name: 'Bob'),
      ];
      RoomController? controller;
      try {
        final (
          RoomController connected,
          FakeTransport transport,
        ) = await _connect(
          tester,
          (RoomController c) {
            controller = c;
          },
          seats: seats,
          turnSeat: 0,
        );
        controller = connected;
        await _mount(tester, connected, locale: const Locale('ar'));
        await _pushMoved(tester, transport, seat: 0, from: 51, to: 57, seq: 2);
        await _pushGameOver(tester, transport, winner: 0, seq: 3);
        _expectHoldBanner(
          tester,
          bannerText: 'انتهت اللعبة',
          absentFragment: 'بانتظار',
          label: 'ar local win',
        );
      } finally {
        final RoomController? owned = controller;
        if (owned != null) {
          await _dispose(tester, owned);
        }
      }
    },
  );

  testWidgets('control: an ordinary move still shows the live own-turn line', (
    tester,
  ) async {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: const <int>[10, -1, -1, -1]),
      _seatJson(1, name: 'Bob'),
    ];
    RoomController? controller;
    try {
      final (
        RoomController connected,
        FakeTransport transport,
      ) = await _connect(
        tester,
        (RoomController c) {
          controller = c;
        },
        seats: seats,
        turnSeat: 0,
      );
      controller = connected;
      await _mount(tester, connected);
      // Not a finish: 10 to 14 stays on the track. moved puts the same
      // seat back on awaitRoll, so the live line is the roll line.
      await _pushMoved(tester, transport, seat: 0, from: 10, to: 14, seq: 2);
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      expect(
        tester.widget<Text>(find.byKey(_bannerKey)).data,
        loc.gameYourTurnRoll,
        reason:
            'an ordinary move must still show the live own-turn line '
            '(${loc.gameYourTurnRoll})',
      );
    } finally {
      final RoomController? owned = controller;
      if (owned != null) {
        await _dispose(tester, owned);
      }
    }
  });
}

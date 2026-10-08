// GameScreen chrome for C-272: no AppBar in any state, the corner leave
// control (key game-screen-appbar-leave, kept), and a confirm sheet only
// while a playing game would cost the seat.
//
// GameScreen is driven the same way test/game_screen_appbar_leave_label_test
// .dart drives RoomController: a real RoomController over FakeTransport, no
// real sockets. Room snapshots arrive as protocol frames, never as hand-built
// RoomSnapshot objects. One GameScreen mount per case.
//
// The three confirm strings are the literals from C-272 rule 6. The new
// AppLocalizations getters are not on this tree, and a reference to them
// would not compile here.
//
// A pop is observed by pushing GameScreen on MaterialApp's own navigator,
// above a previous route. A nested navigator (the leave-label file's tap
// pattern) never hears tester.binding.handlePopRoute, which the root
// navigator receives. Navigator.pop from the corner control still finds
// that same navigator, so a tap-pop is observable the same way.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

const Key _leaveKey = Key('game-screen-appbar-leave');
const Key _confirmKey = Key('game-leave-confirm');
const Key _stayKey = Key('game-leave-confirm-stay');
const Key _confirmLeaveKey = Key('game-leave-confirm-leave');
const Key _boardKey = Key('game-screen-board');
const Key _waitingKey = Key('game-screen-waiting');
const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _newRoomKey = Key('game-screen-new-room-button');
const Key _openKey = Key('open-game-screen');

const String _enTitle = 'Leave the game?';
const String _enBody =
    'Your tokens stay on the board and the timer plays your turns.';
const String _enStay = 'Keep playing';

const String _arTitle = 'مغادرة اللعبة؟';
const String _arBody = 'تبقى قطعك على اللوحة ويلعب المؤقت أدوارك.';
const String _arStay = 'تابع اللعب';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'chrome-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call has no transport queued for $url; '
        'the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

final List<Map<String, Object?>> _twoSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

Map<String, Object?> _playingTurn() =>
    _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 0, k: 0);

Future<(RoomController, FakeTransport)> _connect(
  WidgetTester tester, {
  int mySeat = 0,
  String state = 'PLAYING',
  int players = 2,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
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
  // pumpEventQueue() uses real Timers via Future.delayed and never fires
  // under testWidgets' fake-async clock. runAsync() steps out of that zone
  // so the connect handshake can complete.
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: state,
        players: players,
        seats: seats,
        turn: turn,
        winner: winner,
        seq: seq,
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
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mountHome(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

/// Pushes GameScreen above a previous route on MaterialApp's navigator.
Future<void> _pushGame(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(
      Builder(
        builder: (BuildContext context) => Scaffold(
          key: const Key('previous-route'),
          body: TextButton(
            key: _openKey,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GameScreen(controller: controller),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(_openKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _use(
  WidgetTester tester,
  RoomController controller,
  Future<void> Function() body,
) async {
  var disposed = false;
  void dispose() {
    if (disposed) {
      return;
    }
    disposed = true;
    controller.dispose();
  }

  addTearDown(dispose);
  try {
    await body();
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    dispose();
  }
}

/// Sheet enter is 250ms, exit is 200ms. Several bounded pumps, no settle:
/// a playing countdown's ticker never lets pumpAndSettle return.
Future<void> _pumpSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _pumpOneSecond(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

void _expectNoAppBar(WidgetTester tester, String where) {
  expect(
    find.descendant(of: find.byType(GameScreen), matching: find.byType(AppBar)),
    findsNothing,
    reason: 'an AppBar found under GameScreen ($where)',
  );
}

void _expectPlayingSeat(RoomController controller) {
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: 'fixture is broken: phase must be connected',
  );
  expect(
    controller.room,
    isNotNull,
    reason: 'fixture is broken: room must be held',
  );
  expect(
    controller.room!.state,
    RoomState.playing,
    reason: 'fixture is broken: room must be PLAYING',
  );
  expect(
    controller.seat,
    isNotNull,
    reason: 'fixture is broken: my seat must be assigned',
  );
  expect(
    controller.room!.seats.any((seat) => seat.seat == controller.seat),
    isTrue,
    reason: 'fixture is broken: my seat must be in room.seats',
  );
}

/// The corner control's own press. A pointer at the icon's center while the
/// sheet is up hits the scrim, and rule 4 says that scrim tap is "stay"
/// (the sheet closes). The control itself is what a second tap on the icon
/// invokes, so this calls onPressed.
void _pressCorner(WidgetTester tester) {
  final Widget widget = tester.widget(find.byKey(_leaveKey));
  final VoidCallback? onPressed = switch (widget) {
    IconButton(:final VoidCallback? onPressed) => onPressed,
    TextButton(:final VoidCallback? onPressed) => onPressed,
    _ => null,
  };
  expect(
    onPressed,
    isNotNull,
    reason:
        'game-screen-appbar-leave must be a button with onPressed, '
        'found ${widget.runtimeType}',
  );
  onPressed!();
}

void _expectHalf(
  WidgetTester tester, {
  required bool left,
  required String why,
}) {
  final Finder leave = find.byKey(_leaveKey);
  expect(
    leave,
    findsOneWidget,
    reason: 'fixture is broken: game-screen-appbar-leave must be present',
  );
  final double mid =
      tester.view.physicalSize.width / tester.view.devicePixelRatio / 2;
  final double center = tester.getCenter(leave).dx;
  expect(
    left ? center < mid : center > mid,
    isTrue,
    reason:
        '$why: center dx was $center, view midpoint was $mid '
        '(left half is below the midpoint, right half is above it)',
  );
}

void _setPhone(WidgetTester tester, Size logical) {
  tester.view.physicalSize = logical;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _failRoll(
  WidgetTester tester,
  RoomController controller,
  FakeTransport transport,
) async {
  unawaited(controller.roll());
  await tester.pump();
  final String rollId = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'error',
      re: rollId,
      data: <String, Object?>{'code': 'SERVER_GONE', 'message': ''},
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.failed,
    reason: 'fixture is broken: the error reply must have failed roll()',
  );
  expect(
    controller.room!.state,
    RoomState.playing,
    reason: 'fixture is broken: the last snapshot must still be PLAYING',
  );
}

void main() {
  testWidgets('PLAYING: GameScreen builds no AppBar', (tester) async {
    final (controller, _) = await _connect(
      tester,
      seats: _twoSeats,
      turn: _playingTurn(),
    );
    await _use(tester, controller, () async {
      _expectPlayingSeat(controller);
      await _mountHome(tester, controller);
      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason: 'fixture is broken: PLAYING must show the board',
      );
      _expectNoAppBar(tester, 'PLAYING');
    });
  });

  testWidgets('FINISHED: GameScreen builds no AppBar', (tester) async {
    final (controller, _) = await _connect(
      tester,
      state: 'FINISHED',
      seats: _twoSeats,
      turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 1),
      winner: 0,
    );
    await _use(tester, controller, () async {
      expect(
        controller.room!.state,
        RoomState.finished,
        reason: 'fixture is broken',
      );
      await _mountHome(tester, controller);
      expect(
        find.byKey(_newRoomKey),
        findsOneWidget,
        reason: 'fixture is broken: FINISHED must show New table',
      );
      _expectNoAppBar(tester, 'FINISHED');
    });
  });

  testWidgets('waiting: GameScreen builds no AppBar', (tester) async {
    final (controller, _) = await _connect(
      tester,
      state: 'LOBBY',
      seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
    );
    await _use(tester, controller, () async {
      expect(
        controller.room!.state,
        RoomState.lobby,
        reason: 'fixture is broken',
      );
      expect(
        controller.room!.rematch,
        isNull,
        reason: 'fixture is broken: a rematch lobby is not the waiting body',
      );
      await _mountHome(tester, controller);
      expect(
        find.byKey(_waitingKey),
        findsOneWidget,
        reason: 'fixture is broken: a lobby with no rematch must wait',
      );
      _expectNoAppBar(tester, 'waiting');
    });
  });

  testWidgets('connection lost: GameScreen builds no AppBar', (tester) async {
    final (controller, transport) = await _connect(
      tester,
      seats: _twoSeats,
      turn: _playingTurn(),
    );
    await _use(tester, controller, () async {
      await _failRoll(tester, controller, transport);
      await _mountHome(tester, controller);
      expect(
        find.byKey(_connectionLostKey),
        findsOneWidget,
        reason: 'fixture is broken: phase failed must show connection lost',
      );
      _expectNoAppBar(tester, 'connection lost');
    });
  });

  testWidgets('PLAYING with my seat: corner tap opens game-leave-confirm, '
      'stay closes it without a frame, leave pops', (tester) async {
    final (controller, transport) = await _connect(
      tester,
      seats: _twoSeats,
      turn: _playingTurn(),
    );
    await _use(tester, controller, () async {
      _expectPlayingSeat(controller);
      await _pushGame(tester, controller);
      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'fixture is broken: GameScreen must have been pushed',
      );

      final int sentAtOpen = transport.sentRaw.length;
      await tester.tap(find.byKey(_leaveKey));
      await _pumpSheet(tester);

      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'the screen popped',
      );
      expect(find.byKey(_confirmKey), findsOneWidget, reason: 'no sheet shown');
      expect(transport.sentRaw.length, sentAtOpen, reason: 'no frame sent');

      await tester.tap(find.byKey(_stayKey));
      await _pumpSheet(tester);

      expect(
        find.byKey(_confirmKey),
        findsNothing,
        reason: 'stay must close game-leave-confirm and nothing else',
      );
      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'the screen popped',
      );
      expect(transport.sentRaw.length, sentAtOpen, reason: 'no frame sent');

      await tester.tap(find.byKey(_leaveKey));
      await _pumpSheet(tester);
      expect(find.byKey(_confirmKey), findsOneWidget, reason: 'no sheet shown');
      await tester.tap(find.byKey(_confirmLeaveKey));
      await _pumpOneSecond(tester);

      expect(
        find.byType(GameScreen),
        findsNothing,
        reason:
            'game-leave-confirm-leave must pop GameScreen within one '
            'second of pumped time',
      );
      expect(transport.sentRaw.length, sentAtOpen, reason: 'no frame sent');
    });
  });

  testWidgets('PLAYING with my seat: system back opens game-leave-confirm and '
      'leaves GameScreen mounted', (tester) async {
    final (controller, transport) = await _connect(
      tester,
      seats: _twoSeats,
      turn: _playingTurn(),
    );
    await _use(tester, controller, () async {
      _expectPlayingSeat(controller);
      await _pushGame(tester, controller);
      final int sentBefore = transport.sentRaw.length;

      await tester.binding.handlePopRoute();
      await _pumpSheet(tester);

      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'the screen popped',
      );
      expect(find.byKey(_confirmKey), findsOneWidget, reason: 'no sheet shown');
      expect(transport.sentRaw.length, sentBefore, reason: 'no frame sent');
    });
  });

  // Control. FINISHED is not a confirm (rule 3): the corner tap pops at
  // once and no sheet is built. May pass on the old chrome too.
  testWidgets(
    'FINISHED: corner tap pops at once and shows no game-leave-confirm',
    (tester) async {
      final (controller, _) = await _connect(
        tester,
        state: 'FINISHED',
        seats: _twoSeats,
        turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 1),
        winner: 0,
      );
      await _use(tester, controller, () async {
        expect(controller.room!.state, RoomState.finished);
        expect(controller.phase, isNot(RoomPhase.failed));
        expect(controller.phase, isNot(RoomPhase.closed));
        await _pushGame(tester, controller);
        expect(find.byKey(_leaveKey), findsOneWidget);

        await tester.tap(find.byKey(_leaveKey));
        await tester.pump();
        expect(find.byKey(_confirmKey), findsNothing, reason: 'no sheet shown');
        await _pumpOneSecond(tester);
        expect(
          find.byType(GameScreen),
          findsNothing,
          reason: 'FINISHED corner tap must pop GameScreen at once',
        );
        expect(find.byKey(_confirmKey), findsNothing, reason: 'no sheet shown');
      });
    },
  );

  // Control. System back on a finished game pops at once, same as today.
  testWidgets(
    'FINISHED: system back pops at once and shows no game-leave-confirm',
    (tester) async {
      final (controller, _) = await _connect(
        tester,
        state: 'FINISHED',
        seats: _twoSeats,
        turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 1),
        winner: 0,
      );
      await _use(tester, controller, () async {
        expect(controller.room!.state, RoomState.finished);
        await _pushGame(tester, controller);

        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.byKey(_confirmKey), findsNothing, reason: 'no sheet shown');
        await _pumpOneSecond(tester);
        expect(
          find.byType(GameScreen),
          findsNothing,
          reason: 'FINISHED system back must pop GameScreen at once',
        );
        expect(find.byKey(_confirmKey), findsNothing, reason: 'no sheet shown');
      });
    },
  );

  // Control. Phase failed over a PLAYING snapshot is not a confirm (rule 3).
  testWidgets(
    'connection lost over a PLAYING snapshot: corner tap pops at once '
    'and shows no game-leave-confirm',
    (tester) async {
      final (controller, transport) = await _connect(
        tester,
        seats: _twoSeats,
        turn: _playingTurn(),
      );
      await _use(tester, controller, () async {
        await _failRoll(tester, controller, transport);
        await _pushGame(tester, controller);
        expect(
          find.byKey(_connectionLostKey),
          findsOneWidget,
          reason: 'fixture is broken: phase failed must show connection lost',
        );
        expect(find.byKey(_leaveKey), findsOneWidget);

        await tester.tap(find.byKey(_leaveKey));
        await tester.pump();
        expect(find.byKey(_confirmKey), findsNothing, reason: 'no sheet shown');
        await _pumpOneSecond(tester);
        expect(
          find.byType(GameScreen),
          findsNothing,
          reason:
              'connection-lost corner tap must pop GameScreen at once, '
              'with no confirm',
        );
        expect(find.byKey(_confirmKey), findsNothing, reason: 'no sheet shown');
      });
    },
  );

  // Control. player_left naming my own seat calls _leave, which pops with
  // no sheet. PopScope does not block that Navigator.pop.
  testWidgets('player_left naming my own seat in PLAYING pops with no '
      'game-leave-confirm', (tester) async {
    final (controller, transport) = await _connect(
      tester,
      mySeat: 0,
      seats: _twoSeats,
      turn: _playingTurn(),
      seq: 1,
    );
    await _use(tester, controller, () async {
      _expectPlayingSeat(controller);
      await _pushGame(tester, controller);
      expect(find.byType(GameScreen), findsOneWidget);

      transport.pushText(
        _frame(
          type: 'player_left',
          data: <String, Object?>{'seat': 0, 'seq': 2},
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'player_left naming my own seat must not throw',
      );
      expect(find.byKey(_confirmKey), findsNothing, reason: 'no sheet shown');
      await _pumpOneSecond(tester);
      expect(
        find.byType(GameScreen),
        findsNothing,
        reason:
            'player_left naming my own seat must pop GameScreen with '
            'no sheet',
      );
      expect(find.byKey(_confirmKey), findsNothing, reason: 'no sheet shown');
    });
  });

  testWidgets(
    'a second corner tap while game-leave-confirm is open leaves exactly '
    'one sheet',
    (tester) async {
      final (controller, _) = await _connect(
        tester,
        seats: _twoSeats,
        turn: _playingTurn(),
      );
      await _use(tester, controller, () async {
        _expectPlayingSeat(controller);
        await _pushGame(tester, controller);

        await tester.tap(find.byKey(_leaveKey));
        await _pumpSheet(tester);
        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason: 'the screen popped',
        );
        expect(
          find.byKey(_confirmKey),
          findsOneWidget,
          reason: 'no sheet shown',
        );

        _pressCorner(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason: 'the screen popped',
        );
        expect(
          find.byKey(_confirmKey),
          findsOneWidget,
          reason:
              'a second tap on the corner icon while the sheet is open '
              'must leave exactly one game-leave-confirm',
        );
      });
    },
  );

  testWidgets('en: game-leave-confirm shows the three rule 6 strings', (
    tester,
  ) async {
    final (controller, _) = await _connect(
      tester,
      seats: _twoSeats,
      turn: _playingTurn(),
    );
    await _use(tester, controller, () async {
      _expectPlayingSeat(controller);
      await _pushGame(tester, controller, locale: const Locale('en'));

      await tester.tap(find.byKey(_leaveKey));
      await _pumpSheet(tester);
      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'the screen popped',
      );
      final Finder sheet = find.byKey(_confirmKey);
      expect(sheet, findsOneWidget, reason: 'no sheet shown');
      expect(
        find.descendant(of: sheet, matching: find.text(_enTitle)),
        findsOneWidget,
        reason: 'game-leave-confirm must show "$_enTitle"',
      );
      expect(
        find.descendant(of: sheet, matching: find.text(_enBody)),
        findsOneWidget,
        reason: 'game-leave-confirm must show the rule 6 body',
      );
      expect(
        find.descendant(of: sheet, matching: find.text(_enStay)),
        findsOneWidget,
        reason: 'game-leave-confirm must show "$_enStay"',
      );
    });
  });

  testWidgets('ar: game-leave-confirm shows the three rule 6 strings', (
    tester,
  ) async {
    final (controller, _) = await _connect(
      tester,
      seats: _twoSeats,
      turn: _playingTurn(),
    );
    await _use(tester, controller, () async {
      _expectPlayingSeat(controller);
      await _pushGame(tester, controller, locale: const Locale('ar'));

      await tester.tap(find.byKey(_leaveKey));
      await _pumpSheet(tester);
      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'the screen popped',
      );
      final Finder sheet = find.byKey(_confirmKey);
      expect(sheet, findsOneWidget, reason: 'no sheet shown');
      expect(
        find.descendant(of: sheet, matching: find.text(_arTitle)),
        findsOneWidget,
        reason: 'game-leave-confirm must show the Arabic title',
      );
      expect(
        find.descendant(of: sheet, matching: find.text(_arBody)),
        findsOneWidget,
        reason: 'game-leave-confirm must show the Arabic body',
      );
      expect(
        find.descendant(of: sheet, matching: find.text(_arStay)),
        findsOneWidget,
        reason: 'game-leave-confirm must show the Arabic stay label',
      );
    });
  });

  testWidgets('en: game-screen-appbar-leave sits in the left half', (
    tester,
  ) async {
    _setPhone(tester, const Size(360, 800));
    final (controller, _) = await _connect(
      tester,
      seats: _twoSeats,
      turn: _playingTurn(),
    );
    await _use(tester, controller, () async {
      await _mountHome(tester, controller, locale: const Locale('en'));
      _expectHalf(
        tester,
        left: true,
        why: 'en: the corner icon must sit in the left half',
      );
    });
  });

  testWidgets('ar: game-screen-appbar-leave sits in the right half', (
    tester,
  ) async {
    _setPhone(tester, const Size(360, 800));
    final (controller, _) = await _connect(
      tester,
      seats: _twoSeats,
      turn: _playingTurn(),
    );
    await _use(tester, controller, () async {
      await _mountHome(tester, controller, locale: const Locale('ar'));
      _expectHalf(
        tester,
        left: false,
        why: 'ar: the corner icon must sit in the right half',
      );
    });
  });
}

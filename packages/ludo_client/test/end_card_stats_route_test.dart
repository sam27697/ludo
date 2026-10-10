// Route tests for C-293: the end card's numbers come from the game the
// RoomRoute actually played, not from a list GameScreen started too late.
//
// Mounted the way test/room_route_test.dart mounts RoomRoute: a real
// RoomController over FakeTransport (test/net/fake_transport.dart,
// read-only). One mount per case. The host creates, one guest joins, the
// host taps Start, and game_started plus the standalone turn (PROTOCOL
// 13.1) are pushed with no pump between them. The end hold is driven the
// way test/rematch_client_test.dart drives it after a move the board snaps:
// pump kEndCardHoldLimit in bounded chunks, never pumpAndSettle, and never
// pumpEventQueue inside the test body.
//
// A seq hole makes RoomController resync on the open socket and stop
// applying later frames, including game_over. Case 4 still delivers the
// rest of the script (so the hole is in the frames the screen saw) and
// answers that resume with the finished room the script ends on, which is
// the only way the end card is reached once the reducer has stopped.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/room_route.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://end-card-stats.invalid/ws';
const String _code = 'ABC234';

// 16 lowercase hex characters, PROTOCOL section 11.
const String _gameOne = 'aaaaaaaaaaaaaaaa';
const String _gameTwo = 'bbbbbbbbbbbbbbbb';

const Key _rollsKey = Key('end-card-stat-rolls');
const Key _sixesKey = Key('end-card-stat-sixes');
const Key _capturesKey = Key('end-card-stat-captures');
const Key _homeKey = Key('end-card-stat-home');
const Key _rematchKey = Key('end-card-rematch');
const Key _winKey = Key('end-card-win');
const Key _loseKey = Key('end-card-lose');
const Key _startKey = Key('lobby-start-button');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c293-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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

Map<String, Object?> _rematchJson({
  required int by,
  required List<int> ready,
}) => <String, Object?>{'by': by, 'ready': ready};

Map<String, Object?> _roomJson({
  String code = _code,
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  String? gameId,
  String? clientSeeds,
  int chainIndex = 0,
  Map<String, Object?>? rematch,
  String? verifyUrl,
  required int seq,
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
  'chain_commit': (chainIndex == 0 ? 'a' : 'b') * 64,
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': clientSeeds,
  'seats':
      seats ??
      <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
      ],
  'turn': turn,
  'winner': winner,
  'verify_url': ?verifyUrl,
  'rematch': rematch,
  'seq': seq,
};

List<Map<String, Object?>> _twoSeats({
  List<int> hostTokens = const <int>[-1, -1, -1, -1],
  List<int> guestTokens = const <int>[-1, -1, -1, -1],
}) => <Map<String, Object?>>[
  _seatJson(0, name: 'Sam', tokens: hostTokens),
  _seatJson(1, name: 'Bob', tokens: guestTokens),
];

Map<String, Object?> _finishedTurn({required int k}) => <String, Object?>{
  'seat': 0,
  'phase': 'finished',
  'deadline_ms': 45000,
  'k': k,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: connect() has no transport queued');
    }
    return _queue.removeAt(0);
  }
}

class _Table {
  _Table(this.controller, this.transport);

  final RoomController controller;
  final FakeTransport transport;

  /// Last seq the server has used. The next push takes this plus one.
  int seq = 0;
}

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
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

Future<void> _finish(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  controller.dispose();
}

/// Host creates a 2-player room and one guest joins, so Start is enabled.
/// Leaves the room in LOBBY at seq 2. Does not start the game.
Future<_Table> _mountLobby(WidgetTester tester) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final _Table table = _Table(controller, transport);

  await tester.pumpWidget(
    _harness(
      RoomRoute(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 2,
      ),
    ),
  );
  await tester.pump();
  expect(transport.sentRaw, isNotEmpty);
  final String createId = _idOf(transport.sentRaw.last);
  expect(_typeOf(transport.sentRaw.last), 'create_room');

  table.seq = 1;
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: _roomJson(
        seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
        seq: table.seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(controller.room, isNotNull);
  expect(controller.room!.state, RoomState.lobby);

  table.seq = 2;
  transport.pushText(
    _frame(
      type: 'player_joined',
      data: <String, Object?>{'seat': 1, 'name': 'Bob', 'seq': table.seq},
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(controller.room!.seats, hasLength(2));
  expect(find.byType(GameScreen), findsNothing);
  return table;
}

/// Taps Start, then delivers game_started and the opening turn.
///
/// [turnWithStart] pushes the two with no pump between them, the way one
/// socket read can deliver PROTOCOL 13.1's pair before the game screen
/// exists. When it is false, game_started is pumped until GameScreen is
/// up and only then is the turn pushed.
Future<void> _startGame(
  WidgetTester tester,
  _Table table, {
  required int turnSeat,
  required String gameId,
  bool turnWithStart = true,
}) async {
  final Finder start = find.byKey(_startKey);
  expect(start, findsOneWidget, reason: 'a full lobby must show Start');
  await tester.ensureVisible(start);
  await tester.tap(start);
  await tester.pump();

  final List<String> starts = table.transport.sentRaw
      .where((String raw) => _typeOf(raw) == 'start_game')
      .toList();
  expect(
    starts,
    hasLength(1),
    reason: 'tapping Start must send exactly one start_game',
  );
  final String startId = _idOf(starts.single);

  table.seq += 1;
  final int startedSeq = table.seq;
  table.transport.pushText(
    _frame(
      type: 'game_started',
      re: startId,
      data: <String, Object?>{
        'turn': turnSeat,
        'game_id': gameId,
        'client_seeds': '0:seed',
        'seq': startedSeq,
      },
    ),
  );

  if (turnWithStart) {
    table.seq += 1;
    table.transport.pushText(
      _frame(
        type: 'turn',
        re: startId,
        data: <String, Object?>{
          'seat': turnSeat,
          'deadline_ms': 45000,
          'seq': table.seq,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
  } else {
    await tester.pump();
    await tester.pump();
    expect(find.byType(GameScreen), findsOneWidget);
    table.seq += 1;
    table.transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': turnSeat,
          'deadline_ms': 45000,
          'seq': table.seq,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  expect(table.controller.room!.state, RoomState.playing);
  expect(find.byType(GameScreen), findsOneWidget);
  expect(find.byType(LobbyScreen), findsNothing);
}

Future<void> _flush(
  WidgetTester tester,
  FakeTransport transport,
  String text,
) async {
  transport.pushText(text);
  await tester.pump();
  await tester.pump();
}

Future<void> _pushRolled(
  WidgetTester tester,
  _Table table, {
  required int value,
  required int k,
  int seat = 0,
}) async {
  table.seq += 1;
  await _flush(
    tester,
    table.transport,
    _frame(
      type: 'rolled',
      data: <String, Object?>{
        'seat': seat,
        'value': value,
        'legal': <int>[0, 1, 2],
        'deadline_ms': 45000,
        'k': k,
        'reveal': 'a' * 64,
        'seq': table.seq,
      },
    ),
  );
}

Future<void> _pushMoved(
  WidgetTester tester,
  _Table table, {
  required int token,
  required int from,
  required int to,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  int seat = 0,
}) async {
  table.seq += 1;
  await _flush(
    tester,
    table.transport,
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': seat,
        'token': token,
        'from': from,
        'to': to,
        'captured': captured,
        'extra_roll': false,
        'seq': table.seq,
      },
    ),
  );
}

Future<void> _pushGameOver(
  WidgetTester tester,
  _Table table, {
  required int winner,
  required String gameId,
}) async {
  table.seq += 1;
  await _flush(
    tester,
    table.transport,
    _frame(
      type: 'game_over',
      data: <String, Object?>{
        'winner': winner,
        'verify_url': 'https://end-card-stats.invalid/v/$gameId',
        'seq': table.seq,
      },
    ),
  );
}

/// Seat 0's game.
///
/// Counted from the frames below, not from the card:
///   rolled 6, rolled 4: rolls 2, sixes 1
///   one captured entry on the move that follows the 4: captures 1
///   tokens finish 57, 57, 57, 57: home 4
///
/// When [skipSecondRoll] is set, the rolled 4 is not sent. Later frames
/// keep the seq they would have had, so the client sees a hole there.
Future<void> _playHostGame(
  WidgetTester tester,
  _Table table, {
  bool skipSecondRoll = false,
}) async {
  await _pushRolled(tester, table, value: 6, k: 1);
  await _pushMoved(tester, table, token: 0, from: -1, to: 0);
  if (skipSecondRoll) {
    table.seq += 1;
  } else {
    await _pushRolled(tester, table, value: 4, k: 2);
  }
  await _pushMoved(
    tester,
    table,
    token: 0,
    from: 0,
    to: 4,
    captured: const <Map<String, Object?>>[
      <String, Object?>{'seat': 1, 'token': 0},
    ],
  );
  await _pushMoved(tester, table, token: 1, from: -1, to: 57);
  await _pushMoved(tester, table, token: 2, from: -1, to: 57);
  await _pushMoved(tester, table, token: 3, from: -1, to: 57);
  await _pushMoved(tester, table, token: 0, from: 4, to: 57);
}

/// The board snaps a jump it cannot step, and that snap runs before
/// game_over, so the hold (when the moved frame still counted as travel)
/// releases at kEndCardHoldLimit. Bounded chunks, never one long pump.
Future<void> _pumpPastEndCardHold(WidgetTester tester) async {
  Duration remaining = kEndCardHoldLimit;
  const Duration chunk = Duration(milliseconds: 250);
  while (remaining > Duration.zero) {
    final Duration step = remaining > chunk ? chunk : remaining;
    await tester.pump(step);
    remaining -= step;
  }
  await tester.pump();
}

String _textUnder(WidgetTester tester, Finder root) {
  if (root.evaluate().isEmpty) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  final Finder texts = find.descendant(of: root, matching: find.byType(Text));
  for (final Text text in tester.widgetList<Text>(texts)) {
    final String? data = text.data;
    if (data != null && data.isNotEmpty) {
      out.writeln(data);
    }
  }
  return out.toString();
}

bool _tileShowsNumber(WidgetTester tester, Key key, int expected) {
  final Finder tile = find.byKey(key);
  if (tile.evaluate().isEmpty) {
    return false;
  }
  return RegExp('(?<!\\d)$expected(?!\\d)').hasMatch(_textUnder(tester, tile));
}

void _expectCompleteNumbers(
  WidgetTester tester, {
  required int rolls,
  required int sixes,
  required int captures,
  required int home,
}) {
  expect(
    find.byKey(_rollsKey),
    findsOneWidget,
    reason: 'end-card-stat-rolls must be on a complete card',
  );
  expect(
    _tileShowsNumber(tester, _rollsKey, rolls),
    isTrue,
    reason:
        'end-card-stat-rolls must show $rolls; text was '
        '"${_textUnder(tester, find.byKey(_rollsKey))}"',
  );
  expect(
    find.byKey(_sixesKey),
    findsOneWidget,
    reason: 'end-card-stat-sixes must be on a complete card',
  );
  expect(
    _tileShowsNumber(tester, _sixesKey, sixes),
    isTrue,
    reason:
        'end-card-stat-sixes must show $sixes; text was '
        '"${_textUnder(tester, find.byKey(_sixesKey))}"',
  );
  expect(
    find.byKey(_capturesKey),
    findsOneWidget,
    reason: 'end-card-stat-captures must be on a complete card',
  );
  expect(
    _tileShowsNumber(tester, _capturesKey, captures),
    isTrue,
    reason:
        'end-card-stat-captures must show $captures; text was '
        '"${_textUnder(tester, find.byKey(_capturesKey))}"',
  );
  expect(
    find.byKey(_homeKey),
    findsOneWidget,
    reason: 'end-card-stat-home must be on a complete card',
  );
  expect(
    _tileShowsNumber(tester, _homeKey, home),
    isTrue,
    reason:
        'end-card-stat-home must show $home; text was '
        '"${_textUnder(tester, find.byKey(_homeKey))}"',
  );
}

List<int> _tokensOf(RoomController controller, int seat) {
  for (final SeatState state in controller.room!.seats) {
    if (state.seat == seat) {
      return state.tokens;
    }
  }
  fail('seat $seat is not in the room');
}

void main() {
  testWidgets(
    '1. host wins: the end card shows rolls, sixes and captures from the '
    'script',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountLobby(tester);
        controller = table.controller;
        await _startGame(tester, table, turnSeat: 0, gameId: _gameOne);
        await _playHostGame(tester, table);
        await _pushGameOver(tester, table, winner: 0, gameId: _gameOne);
        expect(table.controller.room!.state, RoomState.finished);
        expect(_tokensOf(table.controller, 0), <int>[
          57,
          57,
          57,
          57,
        ], reason: 'fixture: seat 0\'s four tokens finish on 57');

        await _pumpPastEndCardHold(tester);

        expect(find.byKey(_winKey), findsOneWidget);
        // rolled 6 and rolled 4: rolls 2, sixes 1.
        // one captured entry: captures 1.
        // four tokens at 57: home 4.
        _expectCompleteNumbers(
          tester,
          rolls: 2,
          sixes: 1,
          captures: 1,
          home: 4,
        );
      } finally {
        if (controller != null) {
          await _finish(tester, controller);
        }
      }
    },
  );

  testWidgets(
    '2. guest wins: the host\'s card is the loser and still shows seat 0\'s '
    'four numbers',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountLobby(tester);
        controller = table.controller;
        await _startGame(tester, table, turnSeat: 0, gameId: _gameOne);
        await _playHostGame(tester, table);
        await _pushGameOver(tester, table, winner: 1, gameId: _gameOne);
        expect(_tokensOf(table.controller, 0), <int>[
          57,
          57,
          57,
          57,
        ], reason: 'fixture: seat 0\'s four tokens finish on 57');

        await _pumpPastEndCardHold(tester);

        expect(
          find.byKey(_loseKey),
          findsOneWidget,
          reason: 'seat 0 lost, so the host sees the loser card',
        );
        expect(find.byKey(_winKey), findsNothing);
        // Same script as case 1: rolls 2, sixes 1, captures 1, home 4.
        _expectCompleteNumbers(
          tester,
          rolls: 2,
          sixes: 1,
          captures: 1,
          home: 4,
        );
      } finally {
        if (controller != null) {
          await _finish(tester, controller);
        }
      }
    },
  );

  testWidgets(
    '3. rematch: the second game\'s card counts only the second game',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountLobby(tester);
        controller = table.controller;
        await _startGame(tester, table, turnSeat: 0, gameId: _gameOne);
        await _playHostGame(tester, table);
        await _pushGameOver(tester, table, winner: 0, gameId: _gameOne);
        await _pumpPastEndCardHold(tester);
        expect(
          find.byKey(_rematchKey),
          findsOneWidget,
          reason: 'game one\'s end card must be up before the rematch',
        );

        await tester.ensureVisible(find.byKey(_rematchKey));
        await tester.tap(find.byKey(_rematchKey));
        await tester.pump();
        final List<String> rematches = table.transport.sentRaw
            .where((String raw) => _typeOf(raw) == 'rematch')
            .toList();
        expect(rematches, hasLength(1));
        final String rematchId = _idOf(rematches.single);

        // Host asked. PROTOCOL 16.2: the reply is the room, back in a
        // rematch lobby, seq one past game_over.
        table.seq += 1;
        await _flush(
          tester,
          table.transport,
          _frame(
            type: 'room',
            re: rematchId,
            data: _roomJson(
              state: 'LOBBY',
              seats: _twoSeats(),
              gameId: null,
              clientSeeds: null,
              chainIndex: 1,
              rematch: _rematchJson(by: 0, ready: const <int>[0]),
              seq: table.seq,
            ),
          ),
        );
        expect(table.controller.room!.state, RoomState.lobby);
        expect(table.controller.room!.rematch, isNotNull);

        // Guest accepts. Both occupied seats are ready, so PROTOCOL 16.4
        // starts the next game on its own: the host is not offered a
        // second Start, and game_started follows as a push.
        table.seq += 1;
        await _flush(
          tester,
          table.transport,
          _frame(
            type: 'room',
            data: _roomJson(
              state: 'LOBBY',
              seats: _twoSeats(),
              gameId: null,
              clientSeeds: null,
              chainIndex: 1,
              rematch: _rematchJson(by: 0, ready: const <int>[0, 1]),
              seq: table.seq,
            ),
          ),
        );

        table.seq += 1;
        final int startedSeq = table.seq;
        table.transport.pushText(
          _frame(
            type: 'game_started',
            data: <String, Object?>{
              'turn': 0,
              'game_id': _gameTwo,
              'client_seeds': '0:seed-b',
              'seq': startedSeq,
            },
          ),
        );
        table.seq += 1;
        table.transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 0,
              'deadline_ms': 45000,
              'seq': table.seq,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(table.controller.room!.state, RoomState.playing);
        expect(table.controller.room!.gameId, _gameTwo);

        // Game two, shorter, counted from these frames alone:
        //   one rolled, value 5: rolls 1, sixes 0
        //   one moved, captured empty, token 0 from -1 to 57:
        //     captures 0, home 1 (the other three tokens stay -1)
        await _pushRolled(tester, table, value: 5, k: 1);
        await _pushMoved(tester, table, token: 0, from: -1, to: 57);
        await _pushGameOver(tester, table, winner: 0, gameId: _gameTwo);
        expect(_tokensOf(table.controller, 0), <int>[
          57,
          -1,
          -1,
          -1,
        ], reason: 'fixture: game two leaves one token home');

        await _pumpPastEndCardHold(tester);

        expect(find.byKey(_winKey), findsOneWidget);
        // rolls 1, sixes 0, captures 0, home 1. Not game one's 2, 1, 1, 4.
        _expectCompleteNumbers(
          tester,
          rolls: 1,
          sixes: 0,
          captures: 0,
          home: 1,
        );
      } finally {
        if (controller != null) {
          await _finish(tester, controller);
        }
      }
    },
  );

  testWidgets(
    '4. a skipped mid-game seq: the card shows home and not the other three',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountLobby(tester);
        controller = table.controller;
        await _startGame(tester, table, turnSeat: 0, gameId: _gameOne);

        // Same script as case 1, except the second rolled is never sent.
        // That frame would have been seq 7 (5 rolled 6, 6 moved, 7 rolled
        // 4). Later frames keep 8..13, so the client never receives seq 7.
        await _playHostGame(tester, table, skipSecondRoll: true);
        // 5 rolled 6, 6 moved, 7 skipped, 8 capture, 9..12 the home moves.
        expect(
          table.seq,
          12,
          reason: 'fixture: seq 7 was not sent and the home moves end at 12',
        );
        await _pushGameOver(tester, table, winner: 0, gameId: _gameOne);
        expect(table.seq, 13, reason: 'fixture: game_over is seq 13');

        final List<String> resumes = table.transport.sentRaw
            .where((String raw) => _typeOf(raw) == 'resume')
            .toList();
        expect(
          resumes,
          hasLength(1),
          reason:
              'the hole at seq 7 must make the controller ask for a '
              'resume, once, on the socket it already has',
        );

        // The reducer stopped at the hole, so game_over did not land.
        // The resume answer is the finished room the script ends on:
        // seat 0's tokens 57, 57, 57, 57, winner 0.
        table.seq += 1;
        await _flush(
          tester,
          table.transport,
          _frame(
            type: 'room',
            re: _idOf(resumes.single),
            data: _roomJson(
              state: 'FINISHED',
              seats: _twoSeats(hostTokens: const <int>[57, 57, 57, 57]),
              turn: _finishedTurn(k: 2),
              winner: 0,
              gameId: _gameOne,
              clientSeeds: '0:seed',
              verifyUrl: 'https://end-card-stats.invalid/v/$_gameOne',
              seq: table.seq,
            ),
          ),
        );
        expect(table.controller.room!.state, RoomState.finished);
        expect(_tokensOf(table.controller, 0), <int>[57, 57, 57, 57]);

        await _pumpPastEndCardHold(tester);

        expect(
          find.byKey(_homeKey),
          findsOneWidget,
          reason:
              'end-card-stat-home must still be shown when a seq is missing',
        );
        expect(
          _tileShowsNumber(tester, _homeKey, 4),
          isTrue,
          reason:
              'end-card-stat-home must show 4, from the four tokens at 57; '
              'text was "${_textUnder(tester, find.byKey(_homeKey))}"',
        );
        expect(find.byKey(_rollsKey), findsNothing);
        expect(find.byKey(_sixesKey), findsNothing);
        expect(find.byKey(_capturesKey), findsNothing);
      } finally {
        if (controller != null) {
          await _finish(tester, controller);
        }
      }
    },
  );
}

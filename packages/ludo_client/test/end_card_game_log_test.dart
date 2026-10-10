// Route tests for C-304: when the end card is up and the transcript's
// stats are not complete, the client asks once for game_log and, if the
// log is this game, redraws the four tiles from it.
//
// Mounted the way test/end_card_stats_route_test.dart mounts RoomRoute: a
// real RoomController over FakeTransport (test/net/fake_transport.dart,
// read-only). The script and the helpers are copied from that file. One
// mount per case. The end hold is pumped in bounded chunks, never
// pumpAndSettle, and never pumpEventQueue inside a test body.
//
// The log answer is the same scripted frames ({t, d}, seq inside d),
// split into two parts. part, parts and game_id are on each part, and re
// is the id of the game_log the client sent (read off sentRaw).
//
// RATE_LIMITED and the timeout are one contract bullet. They are two
// mounts: one request cannot be both refused and timed out.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/room_route.dart';
import 'package:ludo_client/src/session_memory.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://end-card-game-log.invalid/ws';
const String _code = 'ABC234';

// 16 lowercase hex characters, PROTOCOL section 11.
const String _gameOne = 'aaaaaaaaaaaaaaaa';
const String _gameTwo = 'bbbbbbbbbbbbbbbb';

const Key _rollsKey = Key('end-card-stat-rolls');
const Key _sixesKey = Key('end-card-stat-sixes');
const Key _capturesKey = Key('end-card-stat-captures');
const Key _homeKey = Key('end-card-stat-home');
const Key _winKey = Key('end-card-win');
const Key _startKey = Key('lobby-start-button');

/// A few seconds of fake time. Long enough for the end card to have sent
/// game_log, and short of RoomConnection's 10s request timeout.
const Duration _fewSeconds = Duration(seconds: 3);

/// RoomConnection's default requestTimeout. C-304 rule 1: a game_log that
/// nobody answers fails on that same timeout.
const Duration _requestTimeout = Duration(seconds: 10);

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c304-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _entry(String type, Map<String, Object?> data) =>
    <String, Object?>{'t': type, 'd': data};

int _seqOf(Map<String, Object?> entry) =>
    (entry['d']! as Map<String, Object?>)['seq']! as int;

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

Map<String, Object?> _awaitRollTurn() => <String, Object?>{
  'seat': 0,
  'phase': 'await_roll',
  'deadline_ms': 45000,
  'k': 0,
};

/// Seat 0's game, from game_started through game_over.
///
/// Counted from the frames below, not from the card:
///   rolled 6 (seq 5), rolled 4 (seq 7): rolls 2, sixes 1
///   one captured entry on the move at seq 8: captures 1
///   four tokens at 57 on the finished room: home 4
///
/// Seq 3 is game_started and seq 4 the opening turn, because a lobby
/// mount leaves the room at seq 2. Seq 7 is the roll a hole skips on the
/// wire; the log still carries it, or the chain would stay broken and
/// the four tiles could not come from this script.
List<Map<String, Object?>> _hostEntries(
  String gameId,
) => <Map<String, Object?>>[
  _entry('game_started', <String, Object?>{
    'turn': 0,
    'game_id': gameId,
    'client_seeds': '0:seed',
    'seq': 3,
  }),
  _entry('turn', <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 4}),
  _entry('rolled', <String, Object?>{
    'seat': 0,
    'value': 6,
    'legal': <int>[0, 1, 2],
    'deadline_ms': 45000,
    'k': 1,
    'reveal': 'a' * 64,
    'seq': 5,
  }),
  _entry('moved', <String, Object?>{
    'seat': 0,
    'token': 0,
    'from': -1,
    'to': 0,
    'captured': <Map<String, Object?>>[],
    'extra_roll': false,
    'seq': 6,
  }),
  _entry('rolled', <String, Object?>{
    'seat': 0,
    'value': 4,
    'legal': <int>[0, 1, 2],
    'deadline_ms': 45000,
    'k': 2,
    'reveal': 'a' * 64,
    'seq': 7,
  }),
  _entry('moved', <String, Object?>{
    'seat': 0,
    'token': 0,
    'from': 0,
    'to': 4,
    'captured': <Map<String, Object?>>[
      <String, Object?>{'seat': 1, 'token': 0},
    ],
    'extra_roll': false,
    'seq': 8,
  }),
  _entry('moved', <String, Object?>{
    'seat': 0,
    'token': 1,
    'from': -1,
    'to': 57,
    'captured': <Map<String, Object?>>[],
    'extra_roll': false,
    'seq': 9,
  }),
  _entry('moved', <String, Object?>{
    'seat': 0,
    'token': 2,
    'from': -1,
    'to': 57,
    'captured': <Map<String, Object?>>[],
    'extra_roll': false,
    'seq': 10,
  }),
  _entry('moved', <String, Object?>{
    'seat': 0,
    'token': 3,
    'from': -1,
    'to': 57,
    'captured': <Map<String, Object?>>[],
    'extra_roll': false,
    'seq': 11,
  }),
  _entry('moved', <String, Object?>{
    'seat': 0,
    'token': 0,
    'from': 4,
    'to': 57,
    'captured': <Map<String, Object?>>[],
    'extra_roll': false,
    'seq': 12,
  }),
  _entry('game_over', <String, Object?>{
    'winner': 0,
    'verify_url': 'https://end-card-stats.invalid/v/$gameId',
    'seq': 13,
  }),
];

/// A different finished game. Counted from these frames:
///   one rolled, value 5: rolls 1, sixes 0
///   one moved, captured empty: captures 0
/// Home would still be the room's own token count. Accepted, the card
/// would show the rolls tile. It must not.
List<Map<String, Object?>> _otherGameEntries() => <Map<String, Object?>>[
  _entry('game_started', <String, Object?>{
    'turn': 0,
    'game_id': _gameTwo,
    'client_seeds': '0:seed-b',
    'seq': 1,
  }),
  _entry('turn', <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 2}),
  _entry('rolled', <String, Object?>{
    'seat': 0,
    'value': 5,
    'legal': <int>[0, 1, 2],
    'deadline_ms': 45000,
    'k': 1,
    'reveal': 'b' * 64,
    'seq': 3,
  }),
  _entry('moved', <String, Object?>{
    'seat': 0,
    'token': 0,
    'from': -1,
    'to': 57,
    'captured': <Map<String, Object?>>[],
    'extra_roll': false,
    'seq': 4,
  }),
  _entry('game_over', <String, Object?>{
    'winner': 0,
    'verify_url': 'https://end-card-stats.invalid/v/$_gameTwo',
    'seq': 5,
  }),
];

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

class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

class _Table {
  _Table(this.controller, this.transport, [this.feedback]);

  final RoomController controller;
  final FakeTransport transport;
  final _FakeFeedbackService? feedback;

  /// Last seq the server has used. The next push takes this plus one.
  int seq = 0;
}

Widget _harness(Widget child, {_FakeFeedbackService? feedback}) {
  final Widget home = feedback == null
      ? child
      : FeedbackScope(
          settings: FeedbackSettings.forTest(),
          service: feedback,
          child: child,
        );
  return MaterialApp(
    locale: const Locale('en'),
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

Future<void> _finish(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  controller.dispose();
}

/// Host creates a 2-player room and one guest joins, so Start is enabled.
/// Leaves the room in LOBBY at seq 2. Does not start the game.
Future<_Table> _mountLobby(
  WidgetTester tester, {
  _FakeFeedbackService? feedback,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final _Table table = _Table(controller, transport, feedback);

  await tester.pumpWidget(
    _harness(
      RoomRoute(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 2,
      ),
      feedback: feedback,
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

/// A fresh controller, the app-kill path: LobbyAction.resume, no
/// transcript, because this process never saw the game's frames.
Future<_Table> _mountResume(
  WidgetTester tester, {
  _FakeFeedbackService? feedback,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final _Table table = _Table(controller, transport, feedback);

  await tester.pumpWidget(
    _harness(
      RoomRoute(
        controller: controller,
        action: LobbyAction.resume,
        playerName: 'Sam',
        resume: const SeatRecord(code: _code, seat: 0, seatToken: 'tok-0'),
      ),
      feedback: feedback,
    ),
  );
  await tester.pump();
  expect(transport.sentRaw, isNotEmpty);
  expect(_typeOf(transport.sentRaw.last), 'resume');
  expect(controller.gameTranscript, isEmpty);
  return table;
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

/// Taps Start, then delivers [entries]. game_started and the opening turn
/// go out with no pump between them, answering start_game. Later entries
/// are pumped one at a time. [skipSeq] is not pushed; later seqs stay
/// what the script says, so the client sees a hole there.
Future<void> _deliverScript(
  WidgetTester tester,
  _Table table,
  List<Map<String, Object?>> entries, {
  int? skipSeq,
  bool tapStart = true,
}) async {
  String? startId;
  if (tapStart) {
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
    startId = _idOf(starts.single);
  }

  for (int i = 0; i < entries.length; i++) {
    final Map<String, Object?> entry = entries[i];
    final String type = entry['t']! as String;
    final Map<String, Object?> data = entry['d']! as Map<String, Object?>;
    final int frameSeq = _seqOf(entry);
    table.seq = frameSeq;
    if (frameSeq == skipSeq) {
      continue;
    }
    final String text = _frame(
      type: type,
      re: i < 2 ? startId : null,
      data: data,
    );
    if (i < 2 && tapStart) {
      table.transport.pushText(text);
      if (i == 1) {
        await tester.pump();
        await tester.pump();
        expect(table.controller.room!.state, RoomState.playing);
        expect(find.byType(GameScreen), findsOneWidget);
        expect(find.byType(LobbyScreen), findsNothing);
      }
    } else {
      await _flush(tester, table.transport, text);
    }
  }
}

Future<void> _answerResume(
  WidgetTester tester,
  _Table table, {
  required String requestId,
  required Map<String, Object?> room,
}) async {
  await _flush(
    tester,
    table.transport,
    _frame(type: 'room', re: requestId, data: room),
  );
}

/// Two parts, back to back, the way the server sends them. The split is
/// half and half so neither part is empty. re is [requestId].
void _pushGameLog(
  FakeTransport transport, {
  required String requestId,
  required String gameId,
  required List<Map<String, Object?>> entries,
}) {
  expect(
    entries.length,
    greaterThan(1),
    reason: 'fixture: a two-part log needs at least two entries',
  );
  final int split = entries.length ~/ 2;
  final List<List<Map<String, Object?>>> parts = <List<Map<String, Object?>>>[
    entries.sublist(0, split),
    entries.sublist(split),
  ];
  for (int i = 0; i < parts.length; i++) {
    transport.pushText(
      _frame(
        type: 'game_log',
        re: requestId,
        data: <String, Object?>{
          'game_id': gameId,
          'part': i + 1,
          'parts': parts.length,
          'frames': parts[i],
        },
      ),
    );
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const Duration chunk = Duration(milliseconds: 250);
  Duration remaining = total;
  while (remaining > Duration.zero) {
    final Duration step = remaining > chunk ? chunk : remaining;
    await tester.pump(step);
    remaining -= step;
  }
  await tester.pump();
}

/// The board snaps a jump it cannot step, and that snap runs before
/// game_over, so the hold releases at kEndCardHoldLimit. Bounded chunks,
/// never one long pump.
Future<void> _pumpPastEndCardHold(WidgetTester tester) async {
  await _pumpFor(tester, kEndCardHoldLimit);
}

String _sentTypes(_Table table) =>
    table.transport.sentRaw.map(_typeOf).toList().toString();

List<String> _gameLogs(_Table table) => table.transport.sentRaw
    .where((String raw) => _typeOf(raw) == 'game_log')
    .toList();

String _cardNote(WidgetTester tester) {
  final bool rolls = find.byKey(_rollsKey).evaluate().isNotEmpty;
  final String home = _textUnder(tester, find.byKey(_homeKey)).trim();
  return 'rolls tile present: $rolls; home tile: "$home"';
}

/// Counts game_log on sentRaw after a few seconds of fake time.
Future<void> _expectGameLogCount(
  WidgetTester tester,
  _Table table,
  int count,
) async {
  await _pumpFor(tester, _fewSeconds);
  expect(
    _gameLogs(table),
    hasLength(count),
    reason:
        'expected $count game_log after the end card; sent ${_sentTypes(table)}; '
        '${_cardNote(tester)}',
  );
}

/// The one game_log the card sent, after the same wait. Its d is empty
/// (PROTOCOL section 17) and its id is what the answer's re must echo.
Future<String> _expectOneGameLog(WidgetTester tester, _Table table) async {
  await _expectGameLogCount(tester, table, 1);
  final String raw = _gameLogs(table).single;
  expect(
    _decode(raw)['d'],
    <String, Object?>{},
    reason: 'game_log is sent as {}',
  );
  return _idOf(raw);
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

/// The honest fallback: home from the four tokens at 57, and not the
/// other three tiles.
void _expectHomeAlone(WidgetTester tester) {
  expect(find.byKey(_winKey), findsOneWidget);
  expect(
    find.byKey(_homeKey),
    findsOneWidget,
    reason: 'end-card-stat-home must still be shown',
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
}

void _expectNoException(WidgetTester tester) {
  final Object? exception = tester.takeException();
  expect(
    exception,
    isNull,
    reason: 'game_log failing must not surface as an exception; got $exception',
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

/// Case 4 of the stats route test: one push never delivered, the client
/// resumes on the open socket, and the resume answer is the finished room.
Future<_Table> _mountHoleAtEndCard(WidgetTester tester) async {
  final _Table table = await _mountLobby(tester);
  final List<Map<String, Object?>> script = _hostEntries(_gameOne);
  // Seq 7 is the rolled 4. It is not pushed. Later frames keep 8..13.
  await _deliverScript(tester, table, script, skipSeq: 7);
  expect(
    table.seq,
    13,
    reason: 'fixture: the skipped roll is seq 7 and game_over is seq 13',
  );

  final List<String> resumes = table.transport.sentRaw
      .where((String raw) => _typeOf(raw) == 'resume')
      .toList();
  expect(
    resumes,
    hasLength(1),
    reason:
        'the hole at seq 7 must make the controller ask for a resume, '
        'once, on the socket it already has',
  );

  // The reducer stopped at the hole, so game_over did not land. The
  // resume answer is the finished room the script ends on, seq one past
  // game_over, the same answer the stats route test's case 4 uses.
  table.seq += 1;
  await _answerResume(
    tester,
    table,
    requestId: _idOf(resumes.single),
    room: _roomJson(
      state: 'FINISHED',
      seats: _twoSeats(hostTokens: const <int>[57, 57, 57, 57]),
      turn: _finishedTurn(k: 2),
      winner: 0,
      gameId: _gameOne,
      clientSeeds: '0:seed',
      verifyUrl: 'https://end-card-stats.invalid/v/$_gameOne',
      seq: table.seq,
    ),
  );
  expect(table.controller.room!.state, RoomState.finished);
  expect(_tokensOf(table.controller, 0), <int>[57, 57, 57, 57]);

  await _pumpPastEndCardHold(tester);
  _expectHomeAlone(tester);
  return table;
}

Map<String, Object?> _finishedRoom({required int seq}) => _roomJson(
  state: 'FINISHED',
  seats: _twoSeats(hostTokens: const <int>[57, 57, 57, 57]),
  turn: _finishedTurn(k: 2),
  winner: 0,
  gameId: _gameOne,
  clientSeeds: '0:seed',
  verifyUrl: 'https://end-card-stats.invalid/v/$_gameOne',
  seq: seq,
);

void main() {
  testWidgets('seq hole mid-game: one game_log, two parts, the four tiles', (
    WidgetTester tester,
  ) async {
    RoomController? controller;
    try {
      final _Table table = await _mountHoleAtEndCard(tester);
      controller = table.controller;

      final String requestId = await _expectOneGameLog(tester, table);
      _pushGameLog(
        table.transport,
        requestId: requestId,
        gameId: _gameOne,
        entries: _hostEntries(_gameOne),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(_winKey), findsOneWidget);
      // rolled 6 and rolled 4: rolls 2, sixes 1.
      // one captured entry: captures 1.
      // four tokens at 57: home 4.
      _expectCompleteNumbers(tester, rolls: 2, sixes: 1, captures: 1, home: 4);
      expect(_gameLogs(table), hasLength(1));
    } finally {
      if (controller != null) {
        await _finish(tester, controller);
      }
    }
  });

  testWidgets(
    'app kill: resume into PLAYING with no transcript, the game finishes '
    'live: one game_log, four tiles',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountResume(tester);
        controller = table.controller;
        final List<Map<String, Object?>> script = _hostEntries(_gameOne);
        // The snapshot is the opening turn (seq 4). game_started was seq 3
        // and this process never received it.
        await _answerResume(
          tester,
          table,
          requestId: _idOf(table.transport.sentRaw.last),
          room: _roomJson(
            state: 'PLAYING',
            seats: _twoSeats(),
            turn: _awaitRollTurn(),
            gameId: _gameOne,
            clientSeeds: '0:seed',
            seq: _seqOf(script[1]),
          ),
        );
        expect(table.controller.room!.state, RoomState.playing);
        expect(
          table.controller.gameTranscript,
          isEmpty,
          reason:
              'fixture: game_started was not delivered, so the transcript '
              'never opened',
        );
        expect(find.byType(GameScreen), findsOneWidget);

        // The tail of the script, seq 5 onward, delivered live. No
        // game_started, so the transcript stays shut.
        await _deliverScript(
          tester,
          table,
          script
              .where((Map<String, Object?> entry) => _seqOf(entry) >= 5)
              .toList(),
          tapStart: false,
        );
        expect(table.controller.room!.state, RoomState.finished);
        expect(table.controller.gameTranscript, isEmpty);
        expect(_tokensOf(table.controller, 0), <int>[57, 57, 57, 57]);

        await _pumpPastEndCardHold(tester);
        _expectHomeAlone(tester);

        final String requestId = await _expectOneGameLog(tester, table);
        _pushGameLog(
          table.transport,
          requestId: requestId,
          gameId: _gameOne,
          entries: script,
        );
        await tester.pump();
        await tester.pump();

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

  testWidgets('resume straight into FINISHED: one game_log, four tiles', (
    WidgetTester tester,
  ) async {
    RoomController? controller;
    try {
      final _Table table = await _mountResume(tester);
      controller = table.controller;
      final List<Map<String, Object?>> script = _hostEntries(_gameOne);
      await _answerResume(
        tester,
        table,
        requestId: _idOf(
          table.transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'resume')
              .single,
        ),
        room: _finishedRoom(seq: _seqOf(script.last)),
      );
      expect(table.controller.room!.state, RoomState.finished);
      expect(table.controller.gameTranscript, isEmpty);
      expect(find.byType(GameScreen), findsOneWidget);
      _expectHomeAlone(tester);

      final String requestId = await _expectOneGameLog(tester, table);
      _pushGameLog(
        table.transport,
        requestId: requestId,
        gameId: _gameOne,
        entries: script,
      );
      await tester.pump();
      await tester.pump();

      // rolled 6 and rolled 4: rolls 2, sixes 1.
      // one captured entry: captures 1.
      // four tokens at 57: home 4.
      _expectCompleteNumbers(tester, rolls: 2, sixes: 1, captures: 1, home: 4);
    } finally {
      if (controller != null) {
        await _finish(tester, controller);
      }
    }
  });

  testWidgets('a whole game seen live: zero game_log frames sent', (
    WidgetTester tester,
  ) async {
    RoomController? controller;
    try {
      final _Table table = await _mountLobby(tester);
      controller = table.controller;
      await _deliverScript(tester, table, _hostEntries(_gameOne));
      expect(table.controller.room!.state, RoomState.finished);
      expect(_tokensOf(table.controller, 0), <int>[
        57,
        57,
        57,
        57,
      ], reason: 'fixture: seat 0\'s four tokens finish on 57');

      await _pumpPastEndCardHold(tester);
      await _expectGameLogCount(tester, table, 0);

      expect(find.byKey(_winKey), findsOneWidget);
      // rolled 6 and rolled 4: rolls 2, sixes 1.
      // one captured entry: captures 1.
      // four tokens at 57: home 4.
      _expectCompleteNumbers(tester, rolls: 2, sixes: 1, captures: 1, home: 4);
    } finally {
      if (controller != null) {
        await _finish(tester, controller);
      }
    }
  });

  testWidgets(
    'game_log refused RATE_LIMITED: home alone, exactly one game_log, '
    'no exception',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountHoleAtEndCard(tester);
        controller = table.controller;

        final String requestId = await _expectOneGameLog(tester, table);
        table.transport.pushText(
          _frame(
            type: 'error',
            re: requestId,
            data: <String, Object?>{
              'code': 'RATE_LIMITED',
              'message': 'game_log',
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        await _pumpFor(tester, _fewSeconds);

        expect(_gameLogs(table), hasLength(1));
        _expectHomeAlone(tester);
        _expectNoException(tester);
      } finally {
        if (controller != null) {
          await _finish(tester, controller);
        }
      }
    },
  );

  testWidgets(
    'game_log timed out: home alone, exactly one game_log, no exception',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountHoleAtEndCard(tester);
        controller = table.controller;

        await _expectOneGameLog(tester, table);
        // The few-second wait above already consumed part of the timeout
        // if the request went out at the start of it. Another full
        // timeout past that is enough either way.
        await _pumpFor(tester, _requestTimeout + const Duration(seconds: 1));
        await _pumpFor(tester, _fewSeconds);

        expect(
          _gameLogs(table),
          hasLength(1),
          reason:
              'a timeout must not send a second game_log; sent '
              '${_sentTypes(table)}; ${_cardNote(tester)}',
        );
        _expectHomeAlone(tester);
        _expectNoException(tester);
      } finally {
        if (controller != null) {
          await _finish(tester, controller);
        }
      }
    },
  );

  testWidgets("a log whose game_id is another game's: home alone", (
    WidgetTester tester,
  ) async {
    RoomController? controller;
    try {
      final _Table table = await _mountHoleAtEndCard(tester);
      controller = table.controller;

      final String requestId = await _expectOneGameLog(tester, table);
      // Both parts name _gameTwo, so the parts agree with each other.
      // The first entry is that other game's game_started. The finished
      // room is _gameOne.
      _pushGameLog(
        table.transport,
        requestId: requestId,
        gameId: _gameTwo,
        entries: _otherGameEntries(),
      );
      await tester.pump();
      await tester.pump();
      await _pumpFor(tester, _fewSeconds);

      expect(_gameLogs(table), hasLength(1));
      _expectHomeAlone(tester);
    } finally {
      if (controller != null) {
        await _finish(tester, controller);
      }
    }
  });

  testWidgets('no cue fired by the log\'s frames', (WidgetTester tester) async {
    RoomController? controller;
    try {
      final _FakeFeedbackService feedback = _FakeFeedbackService();
      final _Table table = await _mountResume(tester, feedback: feedback);
      controller = table.controller;
      final List<Map<String, Object?>> script = _hostEntries(_gameOne);
      await _answerResume(
        tester,
        table,
        requestId: _idOf(
          table.transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'resume')
              .single,
        ),
        room: _finishedRoom(seq: _seqOf(script.last)),
      );
      expect(find.byType(GameScreen), findsOneWidget);
      _expectHomeAlone(tester);

      // The card is up and nothing is in flight. Whatever the log's
      // rolled, moved and game_over would have cued, none of it may
      // land after this.
      final List<FeedbackCue> atCard = List<FeedbackCue>.from(
        feedback.recorded,
      );

      final String requestId = await _expectOneGameLog(tester, table);
      _pushGameLog(
        table.transport,
        requestId: requestId,
        gameId: _gameOne,
        entries: script,
      );
      await tester.pump();
      await tester.pump();
      await _pumpFor(tester, _fewSeconds);

      expect(feedback.recorded, atCard);
      // rolled 6 and rolled 4: rolls 2, sixes 1.
      // one captured entry: captures 1.
      // four tokens at 57: home 4.
      _expectCompleteNumbers(tester, rolls: 2, sixes: 1, captures: 1, home: 4);
    } finally {
      if (controller != null) {
        await _finish(tester, controller);
      }
    }
  });

  testWidgets('gameTranscript holds no game_log frame', (
    WidgetTester tester,
  ) async {
    RoomController? controller;
    try {
      final _Table table = await _mountHoleAtEndCard(tester);
      controller = table.controller;
      final List<Map<String, Object?>> script = _hostEntries(_gameOne);

      final String requestId = await _expectOneGameLog(tester, table);
      _pushGameLog(
        table.transport,
        requestId: requestId,
        gameId: _gameOne,
        entries: script,
      );
      await tester.pump();
      await tester.pump();

      // rolled 6 and rolled 4: rolls 2, sixes 1.
      // one captured entry: captures 1.
      // four tokens at 57: home 4.
      _expectCompleteNumbers(tester, rolls: 2, sixes: 1, captures: 1, home: 4);
      expect(
        table.controller.gameTranscript.any(
          (frame) => frame.type == 'game_log',
        ),
        isFalse,
        reason:
            'gameTranscript types: '
            '${table.controller.gameTranscript.map((frame) => frame.type).toList()}',
      );
    } finally {
      if (controller != null) {
        await _finish(tester, controller);
      }
    }
  });
}

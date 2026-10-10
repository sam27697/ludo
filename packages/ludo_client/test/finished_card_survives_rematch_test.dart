// C-310: the finished game's card survives the rematch ask. Cases 1-6 go
// through GameScreen on a real RoomController over FakeTransport, the way
// test/rematch_client_test.dart drives a rematch. Case 7 is the controller
// getter and sits in its own group at the end: `lastFinished` is not on
// the base this file was written against, so that group does not compile
// there.
//
// The LOBBY snapshot is docs/PROTOCOL.md section 16.2, field for field:
// state LOBBY, game_id null, client_seeds null, turn null, winner null,
// every token [-1, -1, -1, -1], client_seed and seed_origin null, a new
// chain (chain_index + 1, a different chain_commit), rematch
// {by, ready: [by]}, players, rules, host and names unchanged, seq + 1.
// Section 16.2 names no verify_url, and section 6's snapshot has no such
// key, so the lobby JSON omits it. RoomSnapshot.fromJson records
// verify_url only when the key is present, which leaves the live lobby
// verifyUrl null. The URL the finished game_over carried is the one
// Check must open.
//
// Case 5's "lastFinished is null" is asserted in case 7, not here in the
// screen case. The order limits that getter to case 7 so cases 1-6 compile
// on the base. Case 5 asserts the playing body, which is the screen half.
//
// Case 8 leaves one rolled out of the transcript, the way
// test/end_card_game_log_test.dart skips a rolled, so the finished card
// sends one game_log. The socket drops before any answer. Reconnect's
// resume is the section 16.2 rematch LOBBY. The live room is LOBBY, so
// that retry does not send a second game_log. The numbers stay the
// incomplete fallback: home, and not the other three tiles.
//
// Check's tap is observed the way test/end_card_test.dart observes
// game-screen-verify-button: the url_launcher method channels. GameScreen's
// constructor takes only the controller, so there is no opener to inject.
// test/rematch_client_test.dart never taps Check.
//
// One mount per case. Bounded pumps once GameScreen is up. SharedPreferences
// is mocked and never read back.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/board_geometry.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://finished-card-rematch-test.invalid/ws';
const String _code = 'K7M2QP';

const String _seat0Name = 'Sam';
const String _seat1Name = 'Bob';

const String _finishedGameId = 'a1b2c3d4e5f60718';
const String _nextGameId = 'b2c3d4e5f60718a1';
const String _finishedVerifyUrl =
    'https://finished-card.invalid/v/a1b2c3d4e5f60718';

const String _roomSnapshotVerifyUrl =
    'https://finished-card.invalid/v/room-snapshot';
const String _gameOverVerifyUrl = 'https://finished-card.invalid/v/game-over';
const String _resumeVerifyUrl = 'https://finished-card.invalid/v/resume';

const List<int> _winnerTokens = <int>[57, 57, 57, 57];
const List<int> _loserTokens = <int>[57, 57, 57, 48];
const List<int> _yardTokens = <int>[-1, -1, -1, -1];

// Hand count of the script in [_playToFinished] against
// lib/src/game_stats.dart, not a value computed by calling it.
//
// Seat 1 (the device in cases 1-3 and 5, the loser):
//   rolled value 6, then 5, then 4, then 3. rolls 4, sixes 1.
//   no moved frame of seat 1 carries a capture. captures 0.
//   final tokens [57, 57, 57, 48]. home 3.
//   steps left: three tokens already home (0) and 57 - 48 = 9.
// Seat 0 (the winner, the device in case 4):
//   rolled value 6, 6, and 2. rolls 3, sixes 2.
//   one moved frame captures seat 1's token 0. captures 1.
//   final tokens [57, 57, 57, 57]. home 4.
// Seq runs 2 through 19 with no hole, so the transcript is complete and
// all four tiles render. The jumps to 57 are not a legal single roll;
// the client does not re-check that, and the board snaps them.
const int _loserRolls = 4;
const int _loserSixes = 1;
const int _loserCaptures = 0;
const int _loserHome = 3;
const int _loserStepsLeft = 9;

const int _winnerRolls = 3;
const int _winnerSixes = 2;
const int _winnerCaptures = 1;
const int _winnerHome = 4;

final String _chainA = 'a' * 64;
final String _chainB = 'b' * 64;

const Key _winKey = Key('end-card-win');
const Key _loseKey = Key('end-card-lose');
const Key _endedKey = Key('end-card-ended');
const Key _loseLineKey = Key('end-card-lose-line');
const Key _winnerTitleKey = Key('game-screen-winner');
const Key _statRollsKey = Key('end-card-stat-rolls');
const Key _statSixesKey = Key('end-card-stat-sixes');
const Key _statCapturesKey = Key('end-card-stat-captures');
const Key _statHomeKey = Key('end-card-stat-home');
const Key _verifyKey = Key('game-screen-verify-button');
const Key _rematchKey = Key('end-card-rematch');
const Key _rematchAskKey = Key('end-card-rematch-ask');
const Key _boardKey = Key('game-screen-board');
const Key _dieKey = Key('game-die');
const Key _reconnectKey = Key('game-screen-reconnect-button');

/// Long enough for a post-frame game_log to have been sent, and short of
/// RoomConnection's 10s request timeout. Same bound as
/// test/end_card_game_log_test.dart.
const Duration _fewSeconds = Duration(seconds: 3);

const List<String> _urlLauncherChannels = <String>[
  'plugins.flutter.io/url_launcher',
  'plugins.flutter.io/url_launcher_macos',
  'plugins.flutter.io/url_launcher_linux',
  'plugins.flutter.io/url_launcher_windows',
  'plugins.flutter.io/url_launcher_web',
  'plugins.flutter.io/url_launcher_android',
  'plugins.flutter.io/url_launcher_ios',
];

int _serverIdSeq = 0;

String _nextServerId() {
  _serverIdSeq += 1;
  return 'finished-card-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  required String name,
  List<int> tokens = _yardTokens,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _rulesJson() => <String, Object?>{
  'blocks': true,
  'capture_bonus': true,
  'turn_seconds': 45,
};

Map<String, Object?> _roomJson({
  required String state,
  required int seq,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  String? gameId,
  String? clientSeeds,
  String? verifyUrl,
  int chainIndex = 0,
  String? chainCommit,
  Map<String, Object?>? rematch,
}) => <String, Object?>{
  'code': _code,
  'state': state,
  'host_seat': 0,
  'players': 2,
  'rules': _rulesJson(),
  'chain_commit': chainCommit ?? _chainA,
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': clientSeeds,
  'seats': seats ?? _playingSeats(),
  'turn': turn,
  'winner': winner,
  'seq': seq,
  if (verifyUrl != null) 'verify_url': verifyUrl,
  if (rematch != null) 'rematch': rematch,
};

List<Map<String, Object?>> _playingSeats() => <Map<String, Object?>>[
  _seatJson(0, name: _seat0Name),
  _seatJson(1, name: _seat1Name),
];

List<Map<String, Object?>> _finishedSeats() => <Map<String, Object?>>[
  _seatJson(0, name: _seat0Name, tokens: _winnerTokens),
  _seatJson(1, name: _seat1Name, tokens: _loserTokens),
];

/// Section 16.2's first rematch, as one room snapshot. No verify_url.
Map<String, Object?> _rematchLobbyJson({required int seq, required int by}) =>
    _roomJson(
      state: 'LOBBY',
      seq: seq,
      seats: _playingSeats(),
      gameId: null,
      clientSeeds: null,
      chainIndex: 1,
      chainCommit: _chainB,
      rematch: <String, Object?>{
        'by': by,
        'ready': <int>[by],
      },
    );

Map<String, Object?> _finishedTurnJson() => <String, Object?>{
  'seat': 0,
  'phase': 'finished',
  'deadline_ms': 0,
  'k': 8,
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

Future<(RoomController, FakeTransport, _Connector)> _connectTracked(
  WidgetTester tester, {
  required int mySeat,
  required Map<String, Object?> room,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  addTearDown(controller.dispose);

  final String name = mySeat == 0 ? _seat0Name : _seat1Name;
  final Future<void> future = controller.createRoom(name: name, players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: room));
  await future;
  return (controller, transport, connector);
}

Future<(RoomController, FakeTransport)> _connect(
  WidgetTester tester, {
  required int mySeat,
  required Map<String, Object?> room,
}) async {
  final (RoomController controller, FakeTransport transport, _) =
      await _connectTracked(tester, mySeat: mySeat, room: room);
  return (controller, transport);
}

class _Script {
  _Script(this.tester, this.transport, {int startSeq = 1}) : _seq = startSeq;

  final WidgetTester tester;
  final FakeTransport transport;
  int _seq;

  int get seq => _seq;

  Future<void> _push(String type, Map<String, Object?> data) async {
    _seq += 1;
    transport.pushText(
      _frame(type: type, data: <String, Object?>{...data, 'seq': _seq}),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> gameStarted({required int turnSeat, required String gameId}) =>
      _push('game_started', <String, Object?>{
        'turn': turnSeat,
        'game_id': gameId,
        'client_seeds': '0:sam-seed|1:bob-seed',
      });

  Future<void> turn({required int seat}) =>
      _push('turn', <String, Object?>{'seat': seat, 'deadline_ms': 45000});

  Future<void> rolled({
    required int seat,
    required int value,
    required int k,
  }) => _push('rolled', <String, Object?>{
    'seat': seat,
    'value': value,
    'legal': const <int>[0, 1, 2, 3],
    'deadline_ms': 45000,
    'k': k,
    'reveal': 'a' * 64,
  });

  Future<void> moved({
    required int seat,
    required int token,
    required int from,
    required int to,
    List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
    bool extraRoll = false,
  }) => _push('moved', <String, Object?>{
    'seat': seat,
    'token': token,
    'from': from,
    'to': to,
    'captured': captured,
    'extra_roll': extraRoll,
  });

  Future<void> gameOver({required int winner, required String verifyUrl}) =>
      _push('game_over', <String, Object?>{
        'winner': winner,
        'verify_url': verifyUrl,
      });

  Future<void> pushRoom(Map<String, Object?> room, {String? re}) async {
    transport.pushText(_frame(type: 'room', re: re, data: room));
    final Object? seq = room['seq'];
    if (seq is int) {
      _seq = seq;
    }
    await tester.pump();
    await tester.pump();
  }

  /// Consumes one seq and sends nothing, so the next push is a hole.
  void skipOne() {
    _seq += 1;
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

Future<void> _pumpPastEndCardHold(WidgetTester tester) async {
  await _pumpFor(tester, kEndCardHoldLimit);
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

Future<void> _mount(WidgetTester tester, RoomController controller) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_harness(GameScreen(controller: controller)));
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

void _writeBlob(StringBuffer out, String? value) {
  if (value != null && value.trim().isNotEmpty) {
    out.writeln(value);
  }
}

String _blobUnder(WidgetTester tester, Finder root) {
  if (root.evaluate().isEmpty) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  final Finder descendants = find.descendant(
    of: root,
    matching: find.byWidgetPredicate((Widget _) => true),
  );
  for (final Element element in <Element>[
    tester.element(root),
    ...descendants.evaluate(),
  ]) {
    final Widget widget = element.widget;
    if (widget is Text) {
      _writeBlob(out, widget.data);
      _writeBlob(out, widget.textSpan?.toPlainText());
    } else if (widget is RichText) {
      _writeBlob(out, widget.text.toPlainText());
    }
  }
  return out.toString();
}

bool _tileShowsNumber(WidgetTester tester, Key key, int expected) {
  final Finder tile = find.byKey(key);
  if (tile.evaluate().isEmpty) {
    return false;
  }
  final String blob = _blobUnder(tester, tile);
  return RegExp('(?<!\\d)$expected(?!\\d)').hasMatch(blob);
}

String _where(int seat, String state, String expected) =>
    'seat $seat, state $state, expected $expected';

void _expectText(
  WidgetTester tester,
  Finder finder,
  String expected, {
  required int seat,
  required String state,
  required String what,
}) {
  final String blob = _blobUnder(tester, finder);
  expect(
    blob.contains(expected),
    isTrue,
    reason: _where(seat, state, '$what "$expected" (was "$blob")'),
  );
}

void _expectTappable(
  WidgetTester tester,
  Finder finder, {
  required int seat,
  required String state,
  required String label,
}) {
  expect(
    finder,
    findsOneWidget,
    reason: _where(seat, state, '$label present and tappable'),
  );
  final Widget widget = tester.widget(finder);
  final VoidCallback? onPressed = widget is ButtonStyleButton
      ? widget.onPressed
      : null;
  expect(
    onPressed,
    isNotNull,
    reason: _where(seat, state, '$label ("$label") tappable'),
  );
}

void _expectTile(
  WidgetTester tester,
  Key key,
  int expected, {
  required int seat,
  required String state,
  required String name,
}) {
  expect(
    find.byKey(key),
    findsOneWidget,
    reason: _where(seat, state, 'four tiles, $name tile present'),
  );
  final String blob = _blobUnder(tester, find.byKey(key));
  expect(
    _tileShowsNumber(tester, key, expected),
    isTrue,
    reason: _where(seat, state, '$name tile $expected (was "$blob")'),
  );
}

List<MethodCall> _listenUrlLaunches(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  Future<Object?> handler(MethodCall call) async {
    calls.add(call);
    return true;
  }

  for (final String name in _urlLauncherChannels) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      handler,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      ),
    );
  }
  return calls;
}

bool _containsUrl(Object? value, String url) {
  if (value is String) {
    return value.contains(url);
  }
  if (value is Map) {
    return value.values.any((Object? item) => _containsUrl(item, url));
  }
  if (value is Iterable) {
    return value.any((Object? item) => _containsUrl(item, url));
  }
  return false;
}

bool _launched(List<MethodCall> calls, String url) {
  return calls.any(
    (MethodCall call) =>
        _containsUrl(call.arguments, url) || call.method.contains(url),
  );
}

int _sentOfType(FakeTransport transport, String type) {
  var count = 0;
  for (final String raw in transport.sentRaw) {
    if (_typeOf(raw) == type) {
      count += 1;
    }
  }
  return count;
}

/// Answers any game_log already sent so its request timer does not outlive
/// the case. Returns how many were sent. A client that never asks leaves
/// the count at 0 and nothing is pushed.
Future<int> _answerGameLogs(
  WidgetTester tester,
  FakeTransport transport,
) async {
  final List<String> ids = <String>[];
  for (final String raw in transport.sentRaw) {
    if (_typeOf(raw) == 'game_log') {
      ids.add(_idOf(raw));
    }
  }
  for (final String id in ids) {
    transport.pushText(
      _frame(
        type: 'error',
        re: id,
        data: <String, Object?>{'code': 'WRONG_PHASE', 'message': 'game_log'},
      ),
    );
  }
  if (ids.isNotEmpty) {
    await tester.pump();
    await tester.pump();
  }
  return ids.length;
}

List<int> _tokensOf(RoomSnapshot room, int seat) {
  for (final SeatState seatState in room.seats) {
    if (seatState.seat == seat) {
      return seatState.tokens;
    }
  }
  return const <int>[];
}

/// Plays the contract's game to FINISHED with the screen already up.
/// Device seat is [mySeat]. Seat 0 wins; seat 1 ends on [_loserTokens].
Future<(RoomController, FakeTransport, _Script)> _playToFinished(
  WidgetTester tester, {
  required int mySeat,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connect(
    tester,
    mySeat: mySeat,
    room: _roomJson(state: 'PLAYING', seq: 1),
  );
  await _mount(tester, controller);
  final _Script script = _Script(tester, transport);

  await script.gameStarted(turnSeat: 0, gameId: _finishedGameId);
  await script.rolled(seat: 1, value: 6, k: 1);
  await script.moved(seat: 1, token: 0, from: -1, to: 10, extraRoll: true);
  await script.rolled(seat: 0, value: 6, k: 2);
  await script.moved(
    seat: 0,
    token: 0,
    from: -1,
    to: 57,
    captured: const <Map<String, Object?>>[
      <String, Object?>{'seat': 1, 'token': 0},
    ],
  );
  await script.rolled(seat: 0, value: 6, k: 3);
  await script.moved(seat: 0, token: 1, from: -1, to: 57);
  await script.rolled(seat: 0, value: 2, k: 4);
  await script.moved(seat: 0, token: 2, from: -1, to: 57);
  await script.moved(seat: 0, token: 3, from: -1, to: 57);
  await script.rolled(seat: 1, value: 5, k: 5);
  await script.moved(seat: 1, token: 0, from: -1, to: 57);
  await script.rolled(seat: 1, value: 4, k: 6);
  await script.moved(seat: 1, token: 1, from: -1, to: 57);
  await script.rolled(seat: 1, value: 3, k: 7);
  await script.moved(seat: 1, token: 2, from: -1, to: 57);
  await script.moved(seat: 1, token: 3, from: -1, to: 48);
  await script.gameOver(winner: 0, verifyUrl: _finishedVerifyUrl);
  await _pumpPastEndCardHold(tester);

  final RoomSnapshot room = controller.room!;
  expect(
    room.state,
    RoomState.finished,
    reason: _where(
      mySeat,
      'FINISHED',
      'fixture reaches FINISHED before the case asserts',
    ),
  );
  expect(
    room.winner,
    0,
    reason: _where(mySeat, 'FINISHED', 'fixture winner is seat 0'),
  );
  expect(
    room.gameId,
    _finishedGameId,
    reason: _where(mySeat, 'FINISHED', 'fixture game_id is $_finishedGameId'),
  );
  expect(
    room.verifyUrl,
    _finishedVerifyUrl,
    reason: _where(
      mySeat,
      'FINISHED',
      'fixture verify_url is $_finishedVerifyUrl',
    ),
  );
  expect(
    _tokensOf(room, 0),
    _winnerTokens,
    reason: _where(mySeat, 'FINISHED', 'fixture seat 0 tokens $_winnerTokens'),
  );
  expect(
    _tokensOf(room, 1),
    _loserTokens,
    reason: _where(mySeat, 'FINISHED', 'fixture seat 1 tokens $_loserTokens'),
  );
  return (controller, transport, script);
}

/// The same game as [_playToFinished], except seat 1's rolled value 4 is
/// not pushed. Later frames keep the seqs the full script uses, so the
/// transcript has a hole there, the way test/end_card_game_log_test.dart
/// skips a rolled. The reducer stops at the hole and resumes on the open
/// socket; the resume answer is the finished room, which is what lands
/// FINISHED. The missing rolled stays missing.
Future<(RoomController, FakeTransport, _Connector, _Script)>
_playToFinishedWithHole(WidgetTester tester) async {
  const int mySeat = 1;
  final (
    RoomController controller,
    FakeTransport transport,
    _Connector connector,
  ) = await _connectTracked(
    tester,
    mySeat: mySeat,
    room: _roomJson(state: 'PLAYING', seq: 1),
  );
  await _mount(tester, controller);
  final _Script script = _Script(tester, transport);

  await script.gameStarted(turnSeat: 0, gameId: _finishedGameId);
  await script.rolled(seat: 1, value: 6, k: 1);
  await script.moved(seat: 1, token: 0, from: -1, to: 10, extraRoll: true);
  await script.rolled(seat: 0, value: 6, k: 2);
  await script.moved(
    seat: 0,
    token: 0,
    from: -1,
    to: 57,
    captured: const <Map<String, Object?>>[
      <String, Object?>{'seat': 1, 'token': 0},
    ],
  );
  await script.rolled(seat: 0, value: 6, k: 3);
  await script.moved(seat: 0, token: 1, from: -1, to: 57);
  await script.rolled(seat: 0, value: 2, k: 4);
  await script.moved(seat: 0, token: 2, from: -1, to: 57);
  await script.moved(seat: 0, token: 3, from: -1, to: 57);
  await script.rolled(seat: 1, value: 5, k: 5);
  await script.moved(seat: 1, token: 0, from: -1, to: 57);
  // Seq 14 would have been seat 1's rolled value 4. It is not pushed.
  script.skipOne();
  await script.moved(seat: 1, token: 1, from: -1, to: 57);
  await script.rolled(seat: 1, value: 3, k: 7);
  await script.moved(seat: 1, token: 2, from: -1, to: 57);
  await script.moved(seat: 1, token: 3, from: -1, to: 48);
  await script.gameOver(winner: 0, verifyUrl: _finishedVerifyUrl);

  final List<String> resumes = transport.sentRaw
      .where((String raw) => _typeOf(raw) == 'resume')
      .toList();
  expect(
    resumes,
    hasLength(1),
    reason: _where(
      mySeat,
      'PLAYING',
      'the hole at the skipped rolled sends one resume on the open socket',
    ),
  );

  final int finishedSeq = script.seq + 1;
  await script.pushRoom(
    _roomJson(
      state: 'FINISHED',
      seq: finishedSeq,
      seats: _finishedSeats(),
      turn: _finishedTurnJson(),
      winner: 0,
      gameId: _finishedGameId,
      clientSeeds: '0:sam-seed|1:bob-seed',
      verifyUrl: _finishedVerifyUrl,
    ),
    re: _idOf(resumes.single),
  );
  expect(
    controller.room!.state,
    RoomState.finished,
    reason: _where(
      mySeat,
      'FINISHED',
      'the hole resume answers with the finished room',
    ),
  );
  expect(
    _tokensOf(controller.room!, 1),
    _loserTokens,
    reason: _where(mySeat, 'FINISHED', 'fixture seat 1 tokens $_loserTokens'),
  );

  await _pumpPastEndCardHold(tester);
  return (controller, transport, connector, script);
}

Future<void> _pushRematchAsk(_Script script, {required int by}) async {
  await script.pushRoom(_rematchLobbyJson(seq: script.seq + 1, by: by));
}

void _expectLiveLobby(
  RoomController controller, {
  required int mySeat,
  required int by,
}) {
  final RoomSnapshot room = controller.room!;
  final String state = 'LOBBY rematch by seat $by';
  expect(
    room.state,
    RoomState.lobby,
    reason: _where(mySeat, state, 'live room state LOBBY'),
  );
  expect(
    room.winner,
    isNull,
    reason: _where(mySeat, state, 'live winner null'),
  );
  expect(
    room.gameId,
    isNull,
    reason: _where(mySeat, state, 'live game_id null'),
  );
  expect(
    room.rematch?.by,
    by,
    reason: _where(mySeat, state, 'live rematch.by $by'),
  );
  expect(room.rematch?.ready, <int>[
    by,
  ], reason: _where(mySeat, state, 'live rematch.ready [$by]'));
  expect(
    _tokensOf(room, 1),
    _yardTokens,
    reason: _where(mySeat, state, 'live seat 1 tokens reset $_yardTokens'),
  );
  expect(
    room.verifyUrl,
    isNull,
    reason: _where(
      mySeat,
      state,
      'live verify_url null (section 16.2 has none)',
    ),
  );
}

void _expectFourTiles(
  WidgetTester tester, {
  required int seat,
  required String state,
  required int rolls,
  required int sixes,
  required int captures,
  required int home,
}) {
  _expectTile(
    tester,
    _statRollsKey,
    rolls,
    seat: seat,
    state: state,
    name: 'rolls',
  );
  _expectTile(
    tester,
    _statSixesKey,
    sixes,
    seat: seat,
    state: state,
    name: 'sixes',
  );
  _expectTile(
    tester,
    _statCapturesKey,
    captures,
    seat: seat,
    state: state,
    name: 'captures',
  );
  _expectTile(
    tester,
    _statHomeKey,
    home,
    seat: seat,
    state: state,
    name: 'home',
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('case 1: FINISHED loser card', () {
    testWidgets('case 1: FINISHED shows end-card-lose, four tiles, home 3, '
        'the near line, and Check enabled', (WidgetTester tester) async {
      await _playToFinished(tester, mySeat: 1);
      final AppLocalizations loc = _locOf(tester);
      const String state = 'FINISHED';
      const int seat = 1;

      expect(
        find.byKey(_loseKey),
        findsOneWidget,
        reason: _where(seat, state, 'end-card-lose'),
      );
      expect(
        find.byKey(_winKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-win beside the loss'),
      );
      expect(
        find.byKey(_endedKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-ended beside the loss'),
      );
      _expectText(
        tester,
        find.byKey(_winnerTitleKey),
        loc.endLoseTitle(_seat0Name),
        seat: seat,
        state: state,
        what: 'title',
      );
      _expectText(
        tester,
        find.byKey(_loseLineKey),
        loc.endLoseNear(_loserStepsLeft),
        seat: seat,
        state: state,
        what: 'near line',
      );
      _expectFourTiles(
        tester,
        seat: seat,
        state: state,
        rolls: _loserRolls,
        sixes: _loserSixes,
        captures: _loserCaptures,
        home: _loserHome,
      );
      _expectTappable(
        tester,
        find.byKey(_verifyKey),
        seat: seat,
        state: state,
        label: loc.endFairCheck,
      );
    });
  });

  group('case 2: the card survives seat 0 asking', () {
    testWidgets(
      'case 2: after seat 0 asks, the lose card, its numbers, the near '
      'line and Check survive, and Play again is tappable',
      (WidgetTester tester) async {
        final (RoomController controller, _, _Script script) =
            await _playToFinished(tester, mySeat: 1);
        await _pushRematchAsk(script, by: 0);
        _expectLiveLobby(controller, mySeat: 1, by: 0);

        final AppLocalizations loc = _locOf(tester);
        const String state = 'LOBBY rematch by seat 0';
        const int seat = 1;
        final String title = loc.endLoseTitle(_seat0Name);
        final String near = loc.endLoseNear(_loserStepsLeft);
        final String ask = loc.endRematchAsk(_seat0Name);

        expect(
          find.byKey(_loseKey),
          findsOneWidget,
          reason: _where(seat, state, 'end-card-lose still up'),
        );
        expect(
          find.byKey(_endedKey),
          findsNothing,
          reason: _where(seat, state, 'no end-card-ended in place of the loss'),
        );
        _expectText(
          tester,
          find.byKey(_winnerTitleKey),
          title,
          seat: seat,
          state: state,
          what: 'title',
        );
        _expectText(
          tester,
          find.byKey(_loseLineKey),
          near,
          seat: seat,
          state: state,
          what: 'near line',
        );
        _expectFourTiles(
          tester,
          seat: seat,
          state: state,
          rolls: _loserRolls,
          sixes: _loserSixes,
          captures: _loserCaptures,
          home: _loserHome,
        );
        _expectText(
          tester,
          find.byKey(_rematchAskKey),
          ask,
          seat: seat,
          state: state,
          what: 'rematch ask',
        );
        _expectTappable(
          tester,
          find.byKey(_verifyKey),
          seat: seat,
          state: state,
          label: loc.endFairCheck,
        );

        final List<MethodCall> launches = _listenUrlLaunches(tester);
        await tester.ensureVisible(find.byKey(_verifyKey));
        await tester.tap(find.byKey(_verifyKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          _launched(launches, _finishedVerifyUrl),
          isTrue,
          reason: _where(
            seat,
            state,
            'tapping ${loc.endFairCheck} opens $_finishedVerifyUrl '
            '(calls were $launches)',
          ),
        );

        _expectTappable(
          tester,
          find.byKey(_rematchKey),
          seat: seat,
          state: state,
          label: loc.endRematch,
        );
      },
    );
  });

  group('case 3: the board under the card keeps the finished tokens', () {
    testWidgets('case 3: under the card during the ask, seat 1 tokens stay at '
        'the finished squares, not the yard', (WidgetTester tester) async {
      final (RoomController controller, _, _Script script) =
          await _playToFinished(tester, mySeat: 1);
      await _pushRematchAsk(script, by: 0);
      _expectLiveLobby(controller, mySeat: 1, by: 0);

      const String state = 'LOBBY rematch by seat 0';
      const int seat = 1;
      final LudoBoard board = tester.widget<LudoBoard>(find.byKey(_boardKey));
      expect(
        board.tokens[1],
        _loserTokens,
        reason: _where(
          seat,
          state,
          'board model seat 1 tokens $_loserTokens, not the yard '
          '$_yardTokens',
        ),
      );
      for (var token = 0; token < 4; token++) {
        final int progress = _loserTokens[token];
        final BoardCell finished = cellFor(
          seat: seat,
          progress: progress,
          tokenIndex: token,
        );
        final BoardCell yard = cellFor(
          seat: seat,
          progress: -1,
          tokenIndex: token,
        );
        final Semantics node = tester.widget<Semantics>(
          find.byKey(Key('token-$seat-$token')),
        );
        expect(
          node.properties.identifier,
          'cell-${finished.col}-${finished.row}',
          reason: _where(
            seat,
            state,
            'token-$seat-$token on the finished cell of progress '
            '$progress (cell-${finished.col}-${finished.row}), '
            'not the yard (cell-${yard.col}-${yard.row})',
          ),
        );
      }
    });
  });

  group('case 4: the winner card survives the ask', () {
    testWidgets('case 4: device in seat 0, seat 1 asks, end-card-win and four '
        'tiles survive', (WidgetTester tester) async {
      final (RoomController controller, _, _Script script) =
          await _playToFinished(tester, mySeat: 0);
      await _pushRematchAsk(script, by: 1);
      _expectLiveLobby(controller, mySeat: 0, by: 1);

      final AppLocalizations loc = _locOf(tester);
      const String state = 'LOBBY rematch by seat 1';
      const int seat = 0;

      expect(
        find.byKey(_winKey),
        findsOneWidget,
        reason: _where(seat, state, 'end-card-win still up'),
      );
      expect(
        find.byKey(_endedKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-ended in place of the win'),
      );
      expect(
        find.byKey(_loseKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-lose in place of the win'),
      );
      _expectText(
        tester,
        find.byKey(_winnerTitleKey),
        loc.endWinTitle,
        seat: seat,
        state: state,
        what: 'title',
      );
      _expectFourTiles(
        tester,
        seat: seat,
        state: state,
        rolls: _winnerRolls,
        sixes: _winnerSixes,
        captures: _winnerCaptures,
        home: _winnerHome,
      );
      _expectText(
        tester,
        find.byKey(_rematchAskKey),
        loc.endRematchAsk(_seat1Name),
        seat: seat,
        state: state,
        what: 'rematch ask',
      );
    });
  });

  group('case 5: the rematch game starts', () {
    testWidgets('case 5: game_started after the ask shows the playing body', (
      WidgetTester tester,
    ) async {
      final (RoomController controller, _, _Script script) =
          await _playToFinished(tester, mySeat: 1);
      await _pushRematchAsk(script, by: 0);
      await script.gameStarted(turnSeat: 0, gameId: _nextGameId);
      await script.turn(seat: 0);

      const String state = 'PLAYING after game_started';
      const int seat = 1;
      final RoomSnapshot room = controller.room!;
      expect(
        room.state,
        RoomState.playing,
        reason: _where(seat, state, 'live room state PLAYING'),
      );
      expect(
        room.gameId,
        _nextGameId,
        reason: _where(seat, state, 'live game_id $_nextGameId'),
      );
      expect(
        find.byKey(_loseKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-lose on the new game'),
      );
      expect(
        find.byKey(_winKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-win on the new game'),
      );
      expect(
        find.byKey(_endedKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-ended on the new game'),
      );
      expect(
        find.byKey(_dieKey),
        findsOneWidget,
        reason: _where(seat, state, 'playing body (game-die)'),
      );
      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason: _where(seat, state, 'playing body (game-screen-board)'),
      );
    });
  });

  group('case 6: resume straight into a rematch lobby', () {
    testWidgets('case 6: a fresh controller resumed into a rematch LOBBY shows '
        'end-card-ended and sends no game_log', (WidgetTester tester) async {
      // Contract rule 4: the process was killed and came back straight
      // into the rematch LOBBY, so no finished snapshot was kept. Today's
      // ended variant is the honest fallback, not a gap to paper over.
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
      );
      addTearDown(controller.dispose);

      const int seat = 1;
      const String state = 'LOBBY rematch by seat 0, resumed, no FINISHED';
      final Future<void> future = controller.resumeRoom(
        code: _code,
        seat: seat,
        seatToken: 'tok-1',
      );
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': seat, 'seat_token': 'tok-1'},
        ),
      );
      transport.pushText(
        _frame(type: 'room', re: id, data: _rematchLobbyJson(seq: 4, by: 0)),
      );
      await future;
      await _mount(tester, controller);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final int gameLogs = await _answerGameLogs(tester, transport);
      final AppLocalizations loc = _locOf(tester);

      expect(
        find.byKey(_endedKey),
        findsOneWidget,
        reason: _where(seat, state, 'end-card-ended'),
      );
      expect(
        find.byKey(_loseKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-lose without a finished game'),
      );
      expect(
        find.byKey(_winKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-win without a finished game'),
      );
      _expectText(
        tester,
        find.byKey(_winnerTitleKey),
        loc.gameOverEnded,
        seat: seat,
        state: state,
        what: 'title',
      );
      expect(gameLogs, 0, reason: _where(seat, state, 'no game_log sent'));
      expect(
        _sentOfType(transport, 'game_log'),
        0,
        reason: _where(seat, state, 'no game_log frame on the wire'),
      );
    });
  });

  // Case 7 names RoomController.lastFinished. That getter is not on the
  // base this file was written against, so this group does not compile
  // there. It is last on purpose: cases 1-6 above do not mention it.
  group('case 7: lastFinished on the controller', () {
    testWidgets(
      'case 7: lastFinished is set by a FINISHED room, by game_over and '
      'by a resume into FINISHED, and cleared by game_started and leave',
      (WidgetTester tester) async {
        final (RoomController byRoom, _, _Script roomScript) =
            await _connectFinishedByRoom(tester);
        _expectHeldFinished(
          byRoom.lastFinished,
          seat: 1,
          state: 'FINISHED room snapshot',
          verifyUrl: _roomSnapshotVerifyUrl,
          gameId: _finishedGameId,
          seq: 2,
        );

        await _pushRematchAsk(roomScript, by: 0);
        _expectLiveLobby(byRoom, mySeat: 1, by: 0);
        _expectHeldFinished(
          byRoom.lastFinished,
          seat: 1,
          state: 'LOBBY rematch by seat 0, last FINISHED room kept',
          verifyUrl: _roomSnapshotVerifyUrl,
          gameId: _finishedGameId,
          seq: 2,
        );

        await roomScript.gameStarted(turnSeat: 0, gameId: _nextGameId);
        expect(
          byRoom.lastFinished,
          isNull,
          reason: _where(1, 'PLAYING after game_started', 'lastFinished null'),
        );
        expect(
          byRoom.room!.state,
          RoomState.playing,
          reason: _where(
            1,
            'PLAYING after game_started',
            'live room state PLAYING',
          ),
        );

        final (
          RoomController byOver,
          FakeTransport overTransport,
        ) = await _connect(
          tester,
          mySeat: 1,
          room: _roomJson(state: 'PLAYING', seq: 1),
        );
        expect(
          byOver.lastFinished,
          isNull,
          reason: _where(1, 'PLAYING', 'lastFinished null before game_over'),
        );
        overTransport.pushText(
          _frame(
            type: 'game_over',
            data: <String, Object?>{
              'winner': 0,
              'verify_url': _gameOverVerifyUrl,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        _expectHeldFinished(
          byOver.lastFinished,
          seat: 1,
          state: 'FINISHED by game_over',
          verifyUrl: _gameOverVerifyUrl,
          gameId: null,
          seq: 2,
          tokensAlreadyHome: false,
        );

        final Future<void> leaving = byOver.leave();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        final String leaveId = _idOf(overTransport.sentRaw.last);
        overTransport.pushText(
          _frame(
            type: 'player_left',
            re: leaveId,
            data: <String, Object?>{'seat': 1, 'seq': 3},
          ),
        );
        await leaving;
        await tester.pump();
        expect(
          byOver.lastFinished,
          isNull,
          reason: _where(1, 'closed after leave', 'lastFinished null'),
        );
        expect(
          byOver.phase,
          RoomPhase.closed,
          reason: _where(1, 'closed after leave', 'phase closed'),
        );

        final (RoomController byResume, _) = await _resumeFinished(tester);
        _expectHeldFinished(
          byResume.lastFinished,
          seat: 1,
          state: 'FINISHED resume snapshot',
          verifyUrl: _resumeVerifyUrl,
          gameId: _finishedGameId,
          seq: 6,
        );
      },
    );
  });

  group('case 8: a rematch lobby does not fetch game_log again', () {
    testWidgets('case 8: a socket-down game_log is not asked again after the '
        'rematch LOBBY, and home 3 stays without the other tiles', (
      WidgetTester tester,
    ) async {
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
        _Script script,
      ) = await _playToFinishedWithHole(
        tester,
      );

      const int seat = 1;
      const String finishedState = 'FINISHED';
      expect(
        _sentOfType(transport, 'game_log'),
        1,
        reason: _where(
          seat,
          finishedState,
          'the hole makes the card send one game_log',
        ),
      );

      // The game_log is still unanswered. Dropping the socket fails it
      // with the connection closed, which is the socket-down failure
      // the one retry is armed for.
      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.closed,
        reason: _where(seat, finishedState, 'phase closed after the drop'),
      );
      expect(
        _sentOfType(transport, 'game_log'),
        1,
        reason: _where(
          seat,
          finishedState,
          'the drop does not send a second game_log',
        ),
      );

      // Automatic reconnect is off on this controller, the same as the
      // other cases. The reconnect control calls controller.reconnect,
      // which sends resume on a new transport.
      final FakeTransport resumeTransport = FakeTransport();
      connector.enqueue(resumeTransport);
      final Finder reconnect = find.byKey(_reconnectKey);
      await tester.ensureVisible(reconnect);
      await tester.tap(reconnect);
      await tester.pump();
      expect(
        resumeTransport.sentRaw,
        isNotEmpty,
        reason: _where(seat, finishedState, 'reconnect sends a resume'),
      );
      final String resumeId = _idOf(
        resumeTransport.sentRaw
            .where((String raw) => _typeOf(raw) == 'resume')
            .last,
      );

      const String state = 'LOBBY rematch by seat 0';
      // script.seq is the finished snapshot. Section 16.2 advances seq
      // by one from that room. The answer goes to the transport the
      // reconnect opened, not the one the drop already closed.
      final int lobbySeq = script.seq + 1;
      resumeTransport.pushText(
        _frame(
          type: 'room',
          re: resumeId,
          data: _rematchLobbyJson(seq: lobbySeq, by: 0),
        ),
      );
      await tester.pump();
      await tester.pump();
      _expectLiveLobby(controller, mySeat: seat, by: 0);

      // A post-frame callback scheduled by the lobby build, plus enough
      // time for a game_log answer to have arrived if a second request
      // had been sent. Nothing is pushed in reply: the assertion is that
      // the request is not on the wire.
      await _pumpFor(tester, _fewSeconds);

      expect(
        _sentOfType(transport, 'game_log'),
        1,
        reason: _where(
          seat,
          state,
          'no second game_log on the dropped transport',
        ),
      );
      expect(
        _sentOfType(resumeTransport, 'game_log'),
        0,
        reason: _where(
          seat,
          state,
          'no game_log on the reconnected transport after the LOBBY',
        ),
      );
      expect(
        find.byKey(_loseKey),
        findsOneWidget,
        reason: _where(seat, state, 'end-card-lose still up'),
      );
      expect(
        find.byKey(_endedKey),
        findsNothing,
        reason: _where(seat, state, 'no end-card-ended in place of the loss'),
      );
      _expectTile(
        tester,
        _statHomeKey,
        _loserHome,
        seat: seat,
        state: state,
        name: 'home',
      );
      expect(
        find.byKey(_statRollsKey),
        findsNothing,
        reason: _where(
          seat,
          state,
          'no end-card-stat-rolls; stats stay incomplete',
        ),
      );
      expect(
        find.byKey(_statSixesKey),
        findsNothing,
        reason: _where(
          seat,
          state,
          'no end-card-stat-sixes; stats stay incomplete',
        ),
      );
      expect(
        find.byKey(_statCapturesKey),
        findsNothing,
        reason: _where(
          seat,
          state,
          'no end-card-stat-captures; stats stay incomplete',
        ),
      );
    });
  });
}

/// Connects seat 1 into PLAYING, then an unsolicited FINISHED room frame.
Future<(RoomController, FakeTransport, _Script)> _connectFinishedByRoom(
  WidgetTester tester,
) async {
  final (RoomController controller, FakeTransport transport) = await _connect(
    tester,
    mySeat: 1,
    room: _roomJson(state: 'PLAYING', seq: 1),
  );
  final _Script script = _Script(tester, transport);
  await script.pushRoom(
    _roomJson(
      state: 'FINISHED',
      seq: 2,
      seats: _finishedSeats(),
      turn: _finishedTurnJson(),
      winner: 0,
      gameId: _finishedGameId,
      clientSeeds: '0:sam-seed|1:bob-seed',
      verifyUrl: _roomSnapshotVerifyUrl,
    ),
  );
  return (controller, transport, script);
}

Future<(RoomController, FakeTransport)> _resumeFinished(
  WidgetTester tester,
) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  addTearDown(controller.dispose);

  final Future<void> future = controller.resumeRoom(
    code: _code,
    seat: 1,
    seatToken: 'tok-resume',
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 1, 'seat_token': 'tok-resume'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: 'FINISHED',
        seq: 6,
        seats: _finishedSeats(),
        turn: _finishedTurnJson(),
        winner: 0,
        gameId: _finishedGameId,
        clientSeeds: '0:sam-seed|1:bob-seed',
        verifyUrl: _resumeVerifyUrl,
      ),
    ),
  );
  await future;
  return (controller, transport);
}

void _expectHeldFinished(
  RoomSnapshot? held, {
  required int seat,
  required String state,
  required String verifyUrl,
  required String? gameId,
  required int seq,
  bool tokensAlreadyHome = true,
}) {
  expect(held, isNotNull, reason: _where(seat, state, 'lastFinished set'));
  final RoomSnapshot snapshot = held!;
  expect(
    snapshot.state,
    RoomState.finished,
    reason: _where(seat, state, 'lastFinished state FINISHED'),
  );
  expect(
    snapshot.winner,
    0,
    reason: _where(seat, state, 'lastFinished winner seat 0'),
  );
  expect(
    snapshot.gameId,
    gameId,
    reason: _where(seat, state, 'lastFinished game_id $gameId'),
  );
  expect(
    snapshot.verifyUrl,
    verifyUrl,
    reason: _where(seat, state, 'lastFinished verify_url $verifyUrl'),
  );
  expect(
    snapshot.seq,
    seq,
    reason: _where(seat, state, 'lastFinished seq $seq'),
  );
  expect(
    snapshot.rematch,
    isNull,
    reason: _where(seat, state, 'lastFinished rematch null'),
  );
  if (tokensAlreadyHome) {
    expect(
      _tokensOf(snapshot, 0),
      _winnerTokens,
      reason: _where(seat, state, 'lastFinished seat 0 tokens $_winnerTokens'),
    );
    expect(
      _tokensOf(snapshot, 1),
      _loserTokens,
      reason: _where(seat, state, 'lastFinished seat 1 tokens $_loserTokens'),
    );
  }
}

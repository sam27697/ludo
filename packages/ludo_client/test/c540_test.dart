// Proof for contract C-540
// (work/ludo/orders/C-540-game-route-server-exits.md), written from the
// contract alone: the game route's server-driven exits. D1 a refused seat
// goes home with the removed line, D2 a refused resume splits its two codes,
// D3 a frame that changes the screen closes the sheets the route opened,
// D4 Home says removed before it waits for the leave, D5 my own Leave never
// draws Connection lost, D6 a tap during a leave already in flight does
// nothing.
//
// Two rigs, both copied rather than imported so the files they came from stay
// untouched. D1, D2, D4, D5 and D6 use the rig test/c533_test.dart uses: the
// real HomeScreen, RoomRoute, LobbyScreen and GameScreen over a real
// RoomController on FakeTransport, a fresh transport per connect. D3 uses the
// shared roll-tray harness test/sheet_closes_on_my_turn_test.dart uses:
// GameScreen pushed over a host page, so a pop that took the screen itself
// shows as GameScreen gone.
//
// Cases (a case whose name starts with "guard" is green on a tree without
// the contract on purpose: it pins what must not change, or proves the
// probe can see what the red cases say is absent):
//   D1  PLAYING (lastFinished null), FINISHED (lastFinished set) and a
//       rematch LOBBY (lastFinished set), the resume that follows a drop
//       refused BAD_SEAT_TOKEN, en and ar: one pop, Home shows
//       homeRemovedNotice, no Reconnect and no Play again that taps through.
//       Guard: a plain drop still draws Reconnect.
//   D2  an automatic resume and a tapped Rejoin, refused BAD_SEAT_TOKEN
//       (removed line) and NO_SUCH_ROOM (game-gone line), en and ar.
//   D3  game_over with the chat sheet, game_over with the leave confirm,
//       game_started with the fair-hint sheet, a drop with the chat sheet,
//       and my turn with the leave confirm: no sheet route remains, the new
//       body is visible. Guards: a sheet the player closed first, and a frame
//       that changes nothing.
//   D4  a leave that never answers: the notice is up and the Rejoin control
//       is gone before it completes, for removed and for game-gone.
//   D5  Leave, New table and a server-driven exit, the phase going closed
//       during the exit transition: no connection-lost card, no Reconnect,
//       no announcement. Guard: a plain drop does draw and announce it.
//   D6  Leave tapped twice in one frame, and Leave tapped while a
//       server-driven leave is running, on the game route and on the lobby
//       route: Home is never popped.
//
// Each failure reason names the case, what was expected and what was on the
// tree. There is no random input: the case id reproduces it exactly, with
//   flutter test test/c540_test.dart --plain-name '<id>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/room_route.dart';
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';
import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const Key _createKey = Key('create-room-button');
const Key _rejoinKey = Key('home-rejoin-button');
const Key _removedNoticeKey = Key('home-removed-notice');
const Key _goneNoticeKey = Key('home-game-gone-notice');
const Key _staleTableKey = Key('game-screen-stale-table');
const Key _appBarLeaveKey = Key('game-screen-appbar-leave');
const Key _leaveConfirmKey = Key('game-leave-confirm');
const Key _leaveConfirmLeaveKey = Key('game-leave-confirm-leave');
const Key _leaveConfirmStayKey = Key('game-leave-confirm-stay');
const Key _chatButtonKey = Key('game-chat-button');
const Key _chatSheetKey = Key('quick-chat-sheet');
const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _gameReconnectKey = Key('game-screen-reconnect-button');
const Key _gameLeaveKey = Key('game-screen-leave-button');
const Key _newTableKey = Key('game-screen-new-room-button');
const Key _rematchKey = Key('end-card-rematch');
const Key _offlineKey = Key('end-card-offline');
const Key _fairHintKey = Key('end-card-fair-hint');
const Key _endWinKey = Key('end-card-win');
const Key _endLoseKey = Key('end-card-lose');
const Key _lobbyLeaveKey = Key('lobby-leave-button');
const Key _lobbyErrorKey = Key('lobby-error');

const String _testUrl = 'wss://c540-test.invalid/ws';
const String _code = 'K7M2QP';
const String _token = 'tok-c540-001';
const String _gameId = '7f3a9c1e5b2d4068';
const String _verifyUrl = 'https://c540-test.invalid/v/7f3a9c1e5b2d4068';
const String _chainB = 'b2c3d4e5f60718a1';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';

const Locale _ar = Locale('ar');

String _reproduce(String id) =>
    'reproduce: flutter test test/c540_test.dart --plain-name "$id"';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c540-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _wireSeat(
  int seat, {
  required String name,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _wireRoom({
  required String state,
  int seq = 3,
  String? gameId,
  Map<String, Object?>? turn,
  int? winner,
  String? verifyUrl,
  Map<String, Object?>? rematch,
  int chainIndex = 0,
  List<Map<String, Object?>>? seats,
}) => <String, Object?>{
  'code': _code,
  'state': state,
  'host_seat': 0,
  'players': 2,
  'rules': const <String, Object?>{
    'blocks': false,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': (chainIndex == 0 ? 'a' : 'b') * 64,
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': gameId == null ? null : '0:sam-seed|1:bob-seed',
  'seats':
      seats ??
      <Map<String, Object?>>[
        _wireSeat(0, name: 'Host'),
        _wireSeat(1, name: 'Guest'),
      ],
  'turn': turn,
  'winner': winner,
  'seq': seq,
  'verify_url': ?verifyUrl,
  'rematch': ?rematch,
};

Map<String, Object?> _lobbyRoom() => _wireRoom(state: 'LOBBY');

Map<String, Object?> _playingRoom() => _wireRoom(
  state: 'PLAYING',
  gameId: _gameId,
  turn: const <String, Object?>{
    'seat': 0,
    'phase': 'await_roll',
    'deadline_ms': 45000,
    'k': 0,
  },
);

Map<String, Object?> _finishedRoom({int seq = 9}) => _wireRoom(
  state: 'FINISHED',
  seq: seq,
  gameId: _gameId,
  winner: 0,
  verifyUrl: _verifyUrl,
  turn: const <String, Object?>{
    'seat': 0,
    'phase': 'finished',
    'deadline_ms': 0,
    'k': 8,
  },
  seats: <Map<String, Object?>>[
    _wireSeat(0, name: 'Host', tokens: const <int>[57, 57, 57, 57]),
    _wireSeat(1, name: 'Guest', tokens: const <int>[57, 57, 12, -1]),
  ],
);

/// Section 16.2's first rematch ask as one room snapshot: LOBBY, no game id,
/// a new chain, `rematch {by, ready: [by]}`.
Map<String, Object?> _rematchRoom({required int seq, required int by}) =>
    _wireRoom(
      state: 'LOBBY',
      seq: seq,
      chainIndex: 1,
      rematch: <String, Object?>{
        'by': by,
        'ready': <int>[by],
      },
    );

// ---------------------------------------------------------------- app rig

class _TrackedController extends RoomController {
  _TrackedController({required super.serverUrl, required super.connect});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

/// Hands out a fresh controller per call; every connect opens a new
/// [FakeTransport].
class _Rig {
  final List<_TrackedController> controllers = <_TrackedController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  Future<WireTransport> _connect(Uri url) async {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    return transport;
  }

  RoomController call() {
    final _TrackedController created = _TrackedController(
      serverUrl: Uri.parse(_testUrl),
      connect: _connect,
    );
    controllers.add(created);
    return created;
  }

  FakeTransport get last => transports.last;

  List<String> sent(String type) => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (_typeOf(s) == type) s,
  ];

  String lastRequestId(String type) => _idOf(sent(type).last);

  void disposeAll() {
    for (final _TrackedController controller in controllers) {
      if (!controller.wasDisposed) {
        controller.dispose();
      }
    }
  }
}

const String _pushedHomeRouteName = 'c540-home';

/// A page under Home for the cases that pop Home on purpose to see whether
/// anything does: with Home as the only route a stray pop trips a Navigator
/// assertion instead of showing up as a route taken off.
class _BasePage extends StatefulWidget {
  const _BasePage({required this.home});

  final Widget home;

  @override
  State<_BasePage> createState() => _BasePageState();
}

class _BasePageState extends State<_BasePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: _pushedHomeRouteName),
          builder: (_) => widget.home,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(key: Key('c540-base'));
}

/// Records every route the navigator takes off its stack.
class _RouteLog extends NavigatorObserver {
  final List<({String kind, Route<dynamic> route, bool wasFirst})> events =
      <({String kind, Route<dynamic> route, bool wasFirst})>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    events.add((kind: 'pop', route: route, wasFirst: previousRoute == null));
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    events.add((kind: 'remove', route: route, wasFirst: previousRoute == null));
  }

  int get pageLeaves =>
      events.where((e) => e.route is PageRoute<dynamic>).length;

  bool get homeWasPopped => events.any(
    (e) => e.wasFirst || e.route.settings.name == _pushedHomeRouteName,
  );

  String describe() => events
      .map(
        (e) =>
            '${e.kind} ${e.route.runtimeType}'
            '${e.wasFirst ? ' (first route)' : ''}',
      )
      .join(', ');
}

Widget _app(
  RoomControllerFactory factory, {
  Locale? locale,
  required _RouteLog log,
  bool underBase = false,
}) {
  final Widget home = HomeScreen(
    onToggleLocale: () {},
    controllerFactory: factory,
    initialLinkReader: noInitialLink,
    linkStream: noLinkStream,
  );
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: <NavigatorObserver>[log],
    home: underBase ? _BasePage(home: home) : home,
  );
}

/// Bounded pumps only: the lobby spinner and the game countdown never
/// settle, so pumpAndSettle would not return once a route is pushed.
Future<void> _pumpBounded(WidgetTester tester, {int frames = 6}) async {
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _mount(
  WidgetTester tester,
  _Rig rig,
  _RouteLog log, {
  Locale? locale,
  bool underBase = false,
}) async {
  await tester.pumpWidget(
    _app(rig.call, locale: locale, log: log, underBase: underBase),
  );
  await _pumpBounded(tester);
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// Flushes any request still waiting on RoomConnection's ten second timeout,
/// unmounts the tree so no listener outlives its controller, and disposes the
/// controllers, all inside the case body.
Future<void> _finish(WidgetTester tester, _Rig rig) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  rig.disposeAll();
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _answerError(FakeTransport transport, String requestId, String code) {
  transport.pushText(
    _frame(
      type: 'error',
      re: requestId,
      data: <String, Object?>{'code': code, 'message': ''},
    ),
  );
}

void _answerRoom(
  FakeTransport transport,
  String requestId,
  Map<String, Object?> room, {
  required int seat,
}) {
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': seat, 'seat_token': _token},
    ),
  );
  transport.pushText(_frame(type: 'room', re: requestId, data: room));
}

void _pushPlayerLeft(_Rig rig, {required int seat, required int seq}) {
  rig.last.pushText(
    _frame(
      type: 'player_left',
      data: <String, Object?>{'seat': seat, 'seq': seq},
    ),
  );
}

/// Answers every game_log the end card has asked for, so its request timer
/// does not outlive the case.
Future<void> _refuseGameLogs(WidgetTester tester, _Rig rig) async {
  final FakeTransport transport = rig.last;
  if (transport.isClosed) {
    return;
  }
  final List<String> ids = <String>[
    for (final String raw in transport.sentRaw)
      if (_typeOf(raw) == 'game_log') _idOf(raw),
  ];
  for (final String id in ids) {
    _answerError(transport, id, 'RATE_LIMITED');
  }
  await tester.pump();
  await tester.pump();
}

bool _homeIsCurrent(WidgetTester tester) {
  final Finder home = find.byType(HomeScreen, skipOffstage: false);
  if (home.evaluate().length != 1) {
    return false;
  }
  return ModalRoute.of(tester.element(home))?.isCurrent ?? false;
}

/// Seeds a fresh seat record so Home resumes on its own at mount.
void _seedFreshSeat() {
  SharedPreferences.setMockInitialValues(<String, Object>{
    _seatPrefsKey: <String>[_code, '0', _token],
    _savedAtPrefsKey: DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  });
}

/// A record with no saved time keeps the Rejoin button and does not resume
/// on its own.
void _seedLegacySeat() {
  SharedPreferences.setMockInitialValues(<String, Object>{
    _seatPrefsKey: <String>[_code, '0', _token],
  });
}

enum _Room { playing, finished, rematch }

/// Home resumes on its own from a fresh record and the server answers with
/// [room]: the game route is up and the controller is connected. A FINISHED
/// room shows the end card; a rematch ask is pushed on top of it.
Future<void> _gameRoute(
  WidgetTester tester,
  _Rig rig,
  String scenario, {
  required _Room room,
}) async {
  expect(
    rig.sent('resume'),
    hasLength(1),
    reason: '$scenario: fixture: a fresh record resumes on its own',
  );
  _answerRoom(
    rig.last,
    rig.lastRequestId('resume'),
    room == _Room.playing ? _playingRoom() : _finishedRoom(),
    seat: 0,
  );
  await _pumpBounded(tester, frames: 3);
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: '$scenario: fixture: a resume shows GameScreen',
  );
  if (room != _Room.playing) {
    await _refuseGameLogs(tester, rig);
  }
  if (room == _Room.rematch) {
    rig.last.pushText(_frame(type: 'room', data: _rematchRoom(seq: 10, by: 1)));
    await _pumpBounded(tester, frames: 2);
    expect(
      rig.controllers.last.room?.rematch,
      isNotNull,
      reason: '$scenario: fixture: the rematch ask must be on the room',
    );
    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: '$scenario: fixture: the game route survives the rematch ask',
    );
  }
}

/// The socket drops under the game route and the player asks to come back:
/// Reconnect on the connection-lost card for a PLAYING room, Play again on
/// the offline end card otherwise. Returns with the resume sent and
/// unanswered on the new transport.
Future<void> _dropAndAskBack(
  WidgetTester tester,
  _Rig rig,
  String scenario, {
  required _Room room,
}) async {
  final RoomController controller = rig.controllers.last;
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: '$scenario: fixture: the game route must be connected before drop',
  );
  final int before = rig.transports.length;
  rig.last.endFromFarSide();
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.closed,
    reason: '$scenario: fixture: the far side vanishing must close the phase',
  );
  final Key ask = room == _Room.playing ? _gameReconnectKey : _rematchKey;
  expect(
    find.byKey(ask),
    findsOneWidget,
    reason:
        '$scenario: fixture: the dropped game route must offer '
        '${(ask as ValueKey<String>).value}',
  );
  await tester.ensureVisible(find.byKey(ask));
  await tester.tap(find.byKey(ask));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  expect(
    rig.transports.length,
    before + 1,
    reason: '$scenario: fixture: the tap must open one new transport',
  );
  expect(
    rig.last.sentRaw.map(_typeOf).toList(),
    contains('resume'),
    reason:
        '$scenario: fixture: the tap must send a resume; sent '
        '${rig.last.sentRaw.map(_typeOf).toList()}',
  );
}

/// Home, tap Create, answer create_room with a two seat lobby for host seat 0.
Future<void> _hostLobby(WidgetTester tester, _Rig rig, String scenario) async {
  await _tap(tester, _createKey);
  expect(
    rig.sent('create_room'),
    hasLength(1),
    reason: '$scenario: fixture: Create must send one create_room',
  );
  _answerRoom(
    rig.last,
    rig.lastRequestId('create_room'),
    _lobbyRoom(),
    seat: 0,
  );
  await _pumpBounded(tester, frames: 3);
  expect(
    find.byType(LobbyScreen),
    findsOneWidget,
    reason: '$scenario: fixture: a room reply shows LobbyScreen',
  );
  expect(
    rig.controllers.last.phase,
    RoomPhase.connected,
    reason: '$scenario: fixture: the lobby must be connected',
  );
}

/// Home retires the controller it owns after a route returns, and waits for
/// the answer to its leave_room. Answers every leave_room still open on the
/// current transport so the notice that waits behind it can show.
Future<void> _settleHome(WidgetTester tester, _Rig rig) async {
  await _pumpBounded(tester, frames: 3);
  for (int attempt = 0; attempt < 3; attempt += 1) {
    final List<String> leaves = rig.sent('leave_room');
    if (leaves.isNotEmpty && !rig.last.isClosed) {
      rig.last.pushText(
        _frame(
          type: 'player_left',
          re: _idOf(leaves.last),
          data: <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': 99},
        ),
      );
    }
    await _pumpBounded(tester, frames: 3);
  }
  for (int i = 0; i < 20; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _treeNote(WidgetTester tester, _Rig rig, _RouteLog log) =>
    'GameScreen=${find.byType(GameScreen, skipOffstage: false).evaluate().length} '
    'LobbyScreen=${find.byType(LobbyScreen, skipOffstage: false).evaluate().length} '
    'RoomRoute=${find.byType(RoomRoute, skipOffstage: false).evaluate().length} '
    'leave-confirm=${find.byKey(_leaveConfirmKey, skipOffstage: false).evaluate().length} '
    'quick-chat-sheet=${find.byKey(_chatSheetKey, skipOffstage: false).evaluate().length} '
    'connection-lost=${find.byKey(_connectionLostKey, skipOffstage: false).evaluate().length} '
    'reconnect=${find.byKey(_gameReconnectKey, skipOffstage: false).evaluate().length} '
    'end-card-rematch=${find.byKey(_rematchKey, skipOffstage: false).evaluate().length} '
    'end-card-offline=${find.byKey(_offlineKey, skipOffstage: false).evaluate().length} '
    'stale-table=${find.byKey(_staleTableKey, skipOffstage: false).evaluate().length} '
    'homeIsCurrent=${_homeIsCurrent(tester)} '
    'removed-notice=${find.byKey(_removedNoticeKey).evaluate().length} '
    'game-gone-notice=${find.byKey(_goneNoticeKey).evaluate().length} '
    'rejoin=${find.byKey(_rejoinKey).evaluate().length} '
    'controller=${rig.controllers.isEmpty ? 'none' : '${rig.controllers.last.phase}/${rig.controllers.last.errorCode}'} '
    'routes taken off: [${log.describe()}]';

/// Nothing of the room route and no sheet left; Home is the current route.
void _expectRouteGone(
  WidgetTester tester,
  _Rig rig,
  _RouteLog log,
  String scenario,
) {
  final String note = _treeNote(tester, rig, log);
  for (final (Type, String) widgetType in <(Type, String)>[
    (GameScreen, 'the game route'),
    (LobbyScreen, 'the lobby route'),
    (RoomRoute, 'the room route'),
  ]) {
    expect(
      find.byType(widgetType.$1, skipOffstage: false),
      findsNothing,
      reason:
          '$scenario: expected ${widgetType.$2} gone from the tree; saw '
          '$note. ${_reproduce(scenario)}',
    );
  }
  for (final (Key, String) sheet in <(Key, String)>[
    (_leaveConfirmKey, 'the leave confirm'),
    (_chatSheetKey, 'the quick-chat sheet'),
    (_staleTableKey, 'the dimmed stale table'),
    (_connectionLostKey, 'the connection-lost card'),
  ]) {
    expect(
      find.byKey(sheet.$1, skipOffstage: false),
      findsNothing,
      reason:
          '$scenario: expected ${sheet.$2} gone from the tree; saw $note. '
          '${_reproduce(scenario)}',
    );
  }
  expect(
    _homeIsCurrent(tester),
    isTrue,
    reason:
        '$scenario: expected Home to be the current route; saw $note. '
        '${_reproduce(scenario)}',
  );
}

void _expectHomeNotice(
  WidgetTester tester,
  _Rig rig,
  _RouteLog log,
  String scenario, {
  required Key key,
  required String expected,
  Key? absent,
}) {
  final Finder notice = find.byKey(key);
  expect(
    notice,
    findsOneWidget,
    reason:
        '$scenario: expected Home to show ${key.toString()}; saw '
        '${_treeNote(tester, rig, log)}. ${_reproduce(scenario)}',
  );
  expect(
    tester.widget<Text>(notice).data,
    expected,
    reason:
        '$scenario: expected the notice to read "$expected"; read '
        '"${tester.widget<Text>(notice).data}". ${_reproduce(scenario)}',
  );
  if (absent != null) {
    expect(
      find.byKey(absent, skipOffstage: false),
      findsNothing,
      reason:
          '$scenario: expected ${absent.toString()} not to show beside '
          '${key.toString()}; saw ${_treeNote(tester, rig, log)}. '
          '${_reproduce(scenario)}',
    );
  }
}

/// The announcements the accessibility channel hears, in order.
List<String> _listenAnnouncements(WidgetTester tester) {
  final List<String> heard = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        heard.add(data['message'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return heard;
}

/// Pumps frame by frame for [frames] frames and fails on the first one that
/// draws the connection-lost card, a Reconnect, the dimmed table, or the
/// connection-lost line, wherever on the tree it sits (the leaving route
/// stays on the tree through its exit transition).
Future<void> _expectNoConnectionLost(
  WidgetTester tester,
  _Rig rig,
  _RouteLog log,
  String scenario,
  List<String> heard, {
  int frames = 40,
}) async {
  final String lostLine = _loc(tester).lobbyConnectionLost;
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 16));
    final String note =
        'frame $i after the ack; saw ${_treeNote(tester, rig, log)}; '
        'announcements $heard. ${_reproduce(scenario)}';
    expect(
      find.byKey(_connectionLostKey, skipOffstage: false),
      findsNothing,
      reason: '$scenario: expected no connection-lost card at $note',
    );
    expect(
      find.byKey(_gameReconnectKey, skipOffstage: false),
      findsNothing,
      reason: '$scenario: expected no Reconnect button at $note',
    );
    expect(
      find.byKey(_staleTableKey, skipOffstage: false),
      findsNothing,
      reason: '$scenario: expected no dimmed table at $note',
    );
    expect(
      find.text(lostLine, skipOffstage: false),
      findsNothing,
      reason: '$scenario: expected no "$lostLine" text at $note',
    );
  }
  expect(
    heard.where((String m) => m == lostLine),
    isEmpty,
    reason:
        '$scenario: expected TalkBack not to hear "$lostLine"; heard '
        '$heard. ${_reproduce(scenario)}',
  );
}

// ---------------------------------------------------------------- D3 rig

const Duration _sheetMotion = Duration(milliseconds: 500);
const Key _hostOpenKey = Key('c540-open-game');
const Key _hostPageKey = Key('c540-host-page');

class _Game {
  _Game(this.s, this.heard, this.name);

  final Scn s;
  final List<String> heard;
  final String name;

  WidgetTester get tester => s.tester;
  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  String why(String expected) =>
      '${s.why(expected)} | announcements: $heard | sheets: ${_sheets()} | '
      'reproduce: flutter test test/c540_test.dart --plain-name "$name"';

  String _sheets() => <String>[
    'BottomSheet=${find.byType(BottomSheet, skipOffstage: false).evaluate().length}',
    if (tester.any(find.byKey(_chatSheetKey))) 'quick-chat-sheet',
    if (tester.any(find.byKey(_leaveConfirmKey))) 'game-leave-confirm',
    if (tester.any(find.text(loc.endFairHint, skipOffstage: false)))
      'fair-hint',
    'GameScreen current=${_gameIsCurrent()}',
  ].join(', ');

  bool _gameIsCurrent() {
    final Finder game = find.byType(GameScreen, skipOffstage: false);
    if (game.evaluate().length != 1) {
      return false;
    }
    return ModalRoute.of(tester.element(game))?.isCurrent ?? false;
  }

  Future<void> tapAndOpen(Key button, Finder sheet) async {
    s.steps.add('tap ${(button as ValueKey<String>).value}');
    await tester.ensureVisible(find.byKey(button));
    await tester.tap(find.byKey(button));
    await tester.pump();
    await s.pump(_sheetMotion);
    expect(
      sheet,
      findsOneWidget,
      reason: why('the sheet is on screen after the tap (fixture)'),
    );
  }

  Future<void> openChat() =>
      tapAndOpen(_chatButtonKey, find.byKey(_chatSheetKey));

  Future<void> openLeaveConfirm() =>
      tapAndOpen(_appBarLeaveKey, find.byKey(_leaveConfirmKey));

  Future<void> openFairHint() =>
      tapAndOpen(_fairHintKey, find.text(loc.endFairHint, skipOffstage: false));

  Future<void> pushAndSettle(String type, Map<String, Object?> data) async {
    await s.push(type, data);
    await s.pump(_sheetMotion);
  }

  /// Every sheet this route opens is off the tree, and the game route is the
  /// current route again (a sheet route above it would make it not current).
  void expectNoSheet(String when) {
    expect(
      find.byType(BottomSheet, skipOffstage: false),
      findsNothing,
      reason: why('no bottom sheet route remains $when'),
    );
    expect(
      find.byKey(_chatSheetKey, skipOffstage: false),
      findsNothing,
      reason: why('the quick-chat sheet is gone $when'),
    );
    expect(
      find.byKey(_leaveConfirmKey, skipOffstage: false),
      findsNothing,
      reason: why('the leave confirm is gone $when'),
    );
    expect(
      find.text(loc.endFairHint, skipOffstage: false),
      findsNothing,
      reason: why('the fair-hint sheet is gone $when'),
    );
    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: why('GameScreen is still mounted $when (it was not popped)'),
    );
    expect(
      _gameIsCurrent(),
      isTrue,
      reason: why('the game route is the current route $when'),
    );
  }

  void expectNoLeaveSent(String when) {
    expect(
      sentTypesSince(s.drive.transport, 0),
      isNot(contains('leave_room')),
      reason: why('closing a sheet is silent, no leave_room sent $when'),
    );
  }

  Finder get endCard => find.byWidgetPredicate(
    (Widget w) => w.key == _endWinKey || w.key == _endLoseKey,
  );
}

/// Mounts the game over a host page. PLAYING: Bob holds the turn, I am seat
/// 0. FINISHED: I am seat 0 and won, the end card shows.
Future<_Game> _startGame(
  WidgetTester tester,
  String name, {
  Locale locale = const Locale('en'),
  bool finished = false,
}) async {
  phoneSurface(tester);
  final List<String> heard = _listenAnnouncements(tester);
  final RollTrayDrive drive = finished
      ? await connectPlaying(
          tester,
          turn: turnJson(seat: 0, phase: 'finished', k: 8),
          seats: twoSeats(
            mine: const <int>[57, 57, 57, 57],
            other: const <int>[57, 57, 12, -1],
          ),
          state: 'FINISHED',
          winner: 0,
          gameId: _gameId,
          verifyUrl: _verifyUrl,
        )
      : await connectPlaying(tester, turn: awaitRollTurn(1), seats: twoSeats());
  await tester.pumpWidget(
    rollTrayHarness(
      Scaffold(
        key: _hostPageKey,
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              key: _hostOpenKey,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GameScreen(controller: drive.controller),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(_hostOpenKey));
  await tester.pump();
  final Scn s = Scn(name, tester, drive);
  s.steps.add(
    'mount ${locale.languageCode}, ${finished ? 'FINISHED' : 'Bob to roll'}',
  );
  await s.pump(_sheetMotion);
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: 'fixture is broken: $name: GameScreen was not pushed',
  );
  final _Game game = _Game(s, heard, name);
  if (finished) {
    await _refuseLogs(game);
    expect(
      game.endCard,
      findsOneWidget,
      reason: game.why('fixture: a FINISHED room shows the end card'),
    );
  }
  return game;
}

Future<void> _refuseLogs(_Game game) async {
  final FakeTransport transport = game.s.drive.transport;
  if (transport.isClosed) {
    return;
  }
  for (final String raw in List<String>.of(transport.sentRaw)) {
    if (frameType(raw) == 'game_log') {
      transport.pushText(
        errorReplyFrame(re: requestIdOf(raw), code: 'RATE_LIMITED'),
      );
    }
  }
  await game.tester.pump();
  await game.tester.pump();
}

Future<void> _release(_Game game) async {
  await _refuseLogs(game);
  await releaseGame(game.tester, game.s.drive);
}

Map<String, Object?> _gameStartedData({required int turn}) => <String, Object?>{
  'turn': turn,
  'game_id': _chainB,
  'client_seeds': '0:sam-seed|1:bob-seed',
};

// ----------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- D1
  group('D1 a refused seat on the game route goes home with the removed line', () {
    for (final ({String id, Locale? locale, _Room room}) variant in [
      (id: 'D1.1a', locale: null, room: _Room.playing),
      (id: 'D1.1b', locale: _ar, room: _Room.playing),
      (id: 'D1.2a', locale: null, room: _Room.finished),
      (id: 'D1.2b', locale: _ar, room: _Room.finished),
      (id: 'D1.3a', locale: null, room: _Room.rematch),
      (id: 'D1.3b', locale: _ar, room: _Room.rematch),
    ]) {
      testWidgets('${variant.id}: D1 ${variant.room.name} room '
          '(lastFinished ${variant.room == _Room.playing ? 'null' : 'set'}), '
          'locale ${variant.locale ?? 'en'}: the resume refused BAD_SEAT_TOKEN '
          'pops once, Home shows homeRemovedNotice, no Reconnect and no Play '
          'again taps through', (tester) async {
        final String scenario = variant.id;
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log, locale: variant.locale);
        try {
          await _gameRoute(tester, rig, scenario, room: variant.room);
          await _dropAndAskBack(tester, rig, scenario, room: variant.room);
          final int leavesBefore = log.pageLeaves;

          _answerError(rig.last, rig.lastRequestId('resume'), 'BAD_SEAT_TOKEN');
          // The frame that carries the refusal, then frame by frame: the
          // exiting route may sit on the tree, it may not take a tap.
          await tester.pump();
          for (int i = 0; i < 45; i += 1) {
            await tester.pump(const Duration(milliseconds: 16));
            final String note =
                'frame $i after the refusal; saw '
                '${_treeNote(tester, rig, log)}. ${_reproduce(scenario)}';
            expect(
              find.byKey(_gameReconnectKey).hitTestable(),
              findsNothing,
              reason:
                  '$scenario: expected no Reconnect that taps through at $note',
            );
            expect(
              find.byKey(_rematchKey).hitTestable(),
              findsNothing,
              reason:
                  '$scenario: expected no Play again that taps through at $note',
            );
          }
          await _settleHome(tester, rig);

          _expectRouteGone(tester, rig, log, scenario);
          _expectHomeNotice(
            tester,
            rig,
            log,
            scenario,
            key: _removedNoticeKey,
            expected: _loc(tester).homeRemovedNotice,
            absent: _goneNoticeKey,
          );
          expect(
            log.pageLeaves - leavesBefore,
            1,
            reason:
                '$scenario: expected exactly one page route to leave (the '
                'game route); routes taken off: [${log.describe()}]. '
                '${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      });
    }

    testWidgets(
      'D1.4 guard: a plain drop with no refusal still draws Reconnect that '
      'taps, and the player stays on the game route',
      (tester) async {
        const String scenario = 'D1.4';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, scenario, room: _Room.playing);
          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));

          final String note = _treeNote(tester, rig, log);
          expect(
            find.byKey(_gameReconnectKey).hitTestable(),
            findsOneWidget,
            reason:
                '$scenario: expected Reconnect to tap through after a plain '
                'drop; saw $note. ${_reproduce(scenario)}',
          );
          expect(
            _homeIsCurrent(tester),
            isFalse,
            reason:
                '$scenario: expected the player to stay on the game route; '
                'saw $note. ${_reproduce(scenario)}',
          );
          expect(
            find.byKey(_removedNoticeKey, skipOffstage: false),
            findsNothing,
            reason: '$scenario: expected no removed notice; saw $note',
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );
  });

  // ---------------------------------------------------------------- D2
  group('D2 a refused resume splits BAD_SEAT_TOKEN from NO_SUCH_ROOM', () {
    for (final ({String id, Locale? locale, String code, bool tapRejoin})
        variant
        in [
          (id: 'D2.1a', locale: null, code: 'BAD_SEAT_TOKEN', tapRejoin: false),
          (id: 'D2.1b', locale: _ar, code: 'BAD_SEAT_TOKEN', tapRejoin: false),
          (id: 'D2.1c', locale: null, code: 'BAD_SEAT_TOKEN', tapRejoin: true),
          (id: 'D2.2a', locale: null, code: 'NO_SUCH_ROOM', tapRejoin: false),
          (id: 'D2.2b', locale: _ar, code: 'NO_SUCH_ROOM', tapRejoin: false),
          (id: 'D2.2c', locale: null, code: 'NO_SUCH_ROOM', tapRejoin: true),
        ]) {
      final bool removed = variant.code == 'BAD_SEAT_TOKEN';
      testWidgets('${variant.id}: D2 resume refused ${variant.code} '
          '(${variant.tapRejoin ? 'tapped Rejoin' : 'automatic'}), locale '
          '${variant.locale ?? 'en'}: Home reads '
          '${removed ? 'removed, not game ended' : 'game ended'}'
          '${removed ? '' : ' (guard: unchanged)'}', (tester) async {
        final String scenario = variant.id;
        if (variant.tapRejoin) {
          _seedLegacySeat();
        } else {
          _seedFreshSeat();
        }
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log, locale: variant.locale);
        try {
          if (variant.tapRejoin) {
            await _tap(tester, _rejoinKey);
          }
          expect(
            rig.sent('resume'),
            hasLength(1),
            reason: '$scenario: fixture: one resume must be on the wire',
          );
          _answerError(rig.last, rig.lastRequestId('resume'), variant.code);
          await _pumpBounded(tester, frames: 3);
          await _settleHome(tester, rig);

          _expectRouteGone(tester, rig, log, scenario);
          final AppLocalizations loc = _loc(tester);
          _expectHomeNotice(
            tester,
            rig,
            log,
            scenario,
            key: removed ? _removedNoticeKey : _goneNoticeKey,
            expected: removed ? loc.homeRemovedNotice : loc.homeGameGoneNotice,
            absent: removed ? _goneNoticeKey : _removedNoticeKey,
          );
          expect(
            find.byKey(_lobbyErrorKey, skipOffstage: false),
            findsNothing,
            reason:
                '$scenario: expected no lobby error body; saw '
                '${_treeNote(tester, rig, log)}. ${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      });
    }
  });

  // ---------------------------------------------------------------- D3
  group(
    'D3 a frame that changes the screen closes the sheets the route opened',
    () {
      testWidgets(
        'D3.1a: game_over with the quick-chat sheet open closes it, and the '
        'end card shows under no scrim',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.1a');
          try {
            await g.openChat();
            await g.pushAndSettle('game_over', gameOverFrame(0));
            await g.s.pump(kEndCardHoldLimit + const Duration(seconds: 1));

            g.expectNoSheet('after game_over');
            expect(
              g.endCard.hitTestable(),
              findsOneWidget,
              reason: g.why('the end card is on screen and takes taps'),
            );
            g.expectNoLeaveSent('after game_over');
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.1b: game_over with the leave confirm open closes it, and the end '
        'card shows under no scrim',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.1b');
          try {
            await g.openLeaveConfirm();
            await g.pushAndSettle('game_over', gameOverFrame(0));
            await g.s.pump(kEndCardHoldLimit + const Duration(seconds: 1));

            g.expectNoSheet('after game_over');
            expect(
              g.endCard.hitTestable(),
              findsOneWidget,
              reason: g.why('the end card is on screen and takes taps'),
            );
            g.expectNoLeaveSent('after game_over');
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.2: game_started with the end card\'s fair-hint sheet open closes '
        'it, and the new board is on screen under no scrim',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.2', finished: true);
          try {
            await g.openFairHint();
            await g.pushAndSettle('game_started', _gameStartedData(turn: 1));

            g.expectNoSheet('after game_started');
            expect(
              g.endCard,
              findsNothing,
              reason: g.why('the end card is gone, the new game is on'),
            );
            expect(
              find.byKey(bigDieKey).hitTestable(),
              findsOneWidget,
              reason: g.why(
                'the new board is on screen and its die takes taps',
              ),
            );
            g.expectNoLeaveSent('after game_started');
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.3a: a drop with the quick-chat sheet open closes it, and the '
        'connection-lost card shows under no scrim',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.3a');
          try {
            await g.openChat();
            g.s.steps.add('socket ends from the far side');
            g.s.drive.transport.endFromFarSide();
            await tester.pump();
            await tester.pump();
            await g.s.pump(_sheetMotion);

            expect(
              g.s.drive.controller.phase,
              RoomPhase.closed,
              reason: g.why('fixture: the far side vanishing closes the phase'),
            );
            g.expectNoSheet('after the drop');
            expect(
              find.byKey(_connectionLostKey),
              findsOneWidget,
              reason: g.why('the connection-lost card is the new body'),
            );
            expect(
              find.byKey(_gameReconnectKey).hitTestable(),
              findsOneWidget,
              reason: g.why('Reconnect takes taps'),
            );
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.3b: a drop with the leave confirm open closes it, and the '
        'connection-lost card shows under no scrim',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.3b');
          try {
            await g.openLeaveConfirm();
            g.s.steps.add('socket ends from the far side');
            g.s.drive.transport.endFromFarSide();
            await tester.pump();
            await tester.pump();
            await g.s.pump(_sheetMotion);

            g.expectNoSheet('after the drop');
            expect(
              find.byKey(_connectionLostKey),
              findsOneWidget,
              reason: g.why('the connection-lost card is the new body'),
            );
            expect(
              find.byKey(_gameLeaveKey).hitTestable(),
              findsOneWidget,
              reason: g.why('the card\'s own Leave takes taps'),
            );
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.3c: a drop with the end card\'s fair-hint sheet open closes it',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.3c', finished: true);
          try {
            await g.openFairHint();
            g.s.steps.add('socket ends from the far side');
            g.s.drive.transport.endFromFarSide();
            await tester.pump();
            await tester.pump();
            await g.s.pump(_sheetMotion);

            g.expectNoSheet('after the drop');
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.4a: my turn with the leave confirm open closes it, and the die '
        'takes taps',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.4a');
          try {
            await g.openLeaveConfirm();
            await g.pushAndSettle('turn', turnFrame(0));

            g.expectNoSheet('after my turn frame');
            expect(
              find.byKey(bigDieKey).hitTestable(),
              findsOneWidget,
              reason: g.why('the die is hit-testable on my turn'),
            );
            g.expectNoLeaveSent('after my turn frame');
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.4b guard: my turn with the quick-chat sheet open closes it '
        '(C-518 D1, unchanged)',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.4b');
          try {
            await g.openChat();
            await g.pushAndSettle('turn', turnFrame(0));

            g.expectNoSheet('after my turn frame');
            expect(
              find.byKey(bigDieKey).hitTestable(),
              findsOneWidget,
              reason: g.why('the die is hit-testable on my turn'),
            );
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.5 guard: a sheet the player already closed is left alone, and a '
        'game_over after it pops nothing',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.5');
          try {
            await g.openLeaveConfirm();
            g.s.steps.add('tap game-leave-confirm-stay');
            await tester.tap(find.byKey(_leaveConfirmStayKey));
            await tester.pump();
            await g.s.pump(_sheetMotion);
            g.expectNoSheet('after Stay (fixture)');

            await g.pushAndSettle('game_over', gameOverFrame(0));
            await g.s.pump(kEndCardHoldLimit + const Duration(seconds: 1));

            g.expectNoSheet('after game_over on a closed confirm');
            expect(
              find.byKey(_hostPageKey, skipOffstage: false),
              findsOneWidget,
              reason: g.why(
                'the host page under the game route is still there',
              ),
            );
            expect(
              g.endCard.hitTestable(),
              findsOneWidget,
              reason: g.why('the end card is on screen'),
            );
          } finally {
            await _release(g);
          }
        },
      );

      testWidgets(
        'D3.6 guard: frames that change nothing on screen (an opponent roll, '
        'a quick message) leave the quick-chat sheet open',
        (tester) async {
          final _Game g = await _startGame(tester, 'D3.6');
          try {
            await g.openChat();
            await g.pushAndSettle(
              'rolled',
              rolledFrame(1, 4, 1, legal: const <int>[0, 1]),
            );
            await g.s.pushEmote(1, 'hi');
            await g.s.pump(_sheetMotion);

            expect(
              find.byKey(_chatSheetKey),
              findsOneWidget,
              reason: g.why('the quick-chat sheet stays open on these frames'),
            );
            expect(
              find.byType(GameScreen),
              findsOneWidget,
              reason: g.why('GameScreen is still mounted'),
            );
          } finally {
            await _release(g);
          }
        },
      );
    },
  );

  // ---------------------------------------------------------------- D4
  group('D4 Home says removed before it waits for the leave', () {
    /// A player_left naming me on a connected game route sends Home into its
    /// retire, which waits on a leave_room nobody answers. Bounded pumps
    /// short of RoomConnection's ten second timeout; what the player sees
    /// meanwhile is what the cases read.
    Future<void> removedWhileLeaveHangs(
      WidgetTester tester,
      _Rig rig,
      _RouteLog log,
      String scenario, {
      Locale? locale,
    }) async {
      _seedFreshSeat();
      await _mount(tester, rig, log, locale: locale);
      await _gameRoute(tester, rig, scenario, room: _Room.playing);

      _pushPlayerLeft(rig, seat: 0, seq: 4);
      await _pumpBounded(tester, frames: 4);

      expect(
        rig.sent('leave_room'),
        hasLength(1),
        reason:
            '$scenario: fixture: Home must be waiting on one leave_room '
            'that nobody answers; saw ${_treeNote(tester, rig, log)}',
      );
      expect(
        rig.controllers.last.wasDisposed,
        isFalse,
        reason:
            '$scenario: fixture: the retire must still be waiting on the '
            'leave, the controller is not disposed yet',
      );
      _expectRouteGone(tester, rig, log, scenario);
    }

    for (final ({String id, Locale? locale}) variant in [
      (id: 'D4.1a', locale: null),
      (id: 'D4.1b', locale: _ar),
    ]) {
      testWidgets('${variant.id}: D4 player_left naming me (locale '
          '${variant.locale ?? 'en'}), the leave never answers: the removed '
          'notice is on Home before the leave completes', (tester) async {
        final String scenario = variant.id;
        final _RouteLog log = _RouteLog();
        final _Rig rig = _Rig();
        try {
          await removedWhileLeaveHangs(
            tester,
            rig,
            log,
            scenario,
            locale: variant.locale,
          );
          _expectHomeNotice(
            tester,
            rig,
            log,
            scenario,
            key: _removedNoticeKey,
            expected: _loc(tester).homeRemovedNotice,
          );

          // The leave finally completes; the line stays.
          await _settleHome(tester, rig);
          _expectHomeNotice(
            tester,
            rig,
            log,
            scenario,
            key: _removedNoticeKey,
            expected: _loc(tester).homeRemovedNotice,
          );
        } finally {
          await _finish(tester, rig);
        }
      });
    }

    testWidgets(
      'D4.2: player_left naming me, the leave never answers: Home offers no '
      'Rejoin control for the seat that is gone before the leave completes',
      (tester) async {
        const String scenario = 'D4.2';
        final _RouteLog log = _RouteLog();
        final _Rig rig = _Rig();
        try {
          await removedWhileLeaveHangs(tester, rig, log, scenario);
          expect(
            find.byKey(_rejoinKey, skipOffstage: false),
            findsNothing,
            reason:
                '$scenario: expected no Rejoin control for the seat that is '
                'gone while the leave is open; saw '
                '${_treeNote(tester, rig, log)}. ${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D4.3 guard: a game route whose resume is refused NO_SUCH_ROOM shows '
      'the game-gone notice and no Rejoin control as soon as Home is back '
      '(its retire has nothing to wait for, so this holds on main)',
      (tester) async {
        const String scenario = 'D4.3';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, scenario, room: _Room.playing);
          await _dropAndAskBack(tester, rig, scenario, room: _Room.playing);
          _answerError(rig.last, rig.lastRequestId('resume'), 'NO_SUCH_ROOM');
          await _pumpBounded(tester, frames: 4);

          _expectRouteGone(tester, rig, log, scenario);
          _expectHomeNotice(
            tester,
            rig,
            log,
            scenario,
            key: _goneNoticeKey,
            expected: _loc(tester).homeGameGoneNotice,
          );
          expect(
            find.byKey(_rejoinKey, skipOffstage: false),
            findsNothing,
            reason:
                '$scenario: expected no Rejoin control for the room that '
                'is gone; saw ${_treeNote(tester, rig, log)}. '
                '${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );
  });

  // ---------------------------------------------------------------- D5
  group('D5 my own Leave never draws Connection lost', () {
    for (final ({String id, Locale? locale}) variant in [
      (id: 'D5.1a', locale: null),
      (id: 'D5.1b', locale: _ar),
    ]) {
      testWidgets('${variant.id}: D5 Leave through the confirm (locale '
          '${variant.locale ?? 'en'}), the ack closes the phase during the '
          'exit transition: no connection-lost card, no Reconnect, no '
          'announcement', (tester) async {
        final String scenario = variant.id;
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        final List<String> heard = _listenAnnouncements(tester);
        await _mount(tester, rig, log, locale: variant.locale);
        try {
          await _gameRoute(tester, rig, scenario, room: _Room.playing);
          await _tap(tester, _appBarLeaveKey);
          expect(
            find.byKey(_leaveConfirmKey),
            findsOneWidget,
            reason: '$scenario: fixture: the leave confirm must be open',
          );
          await tester.tap(find.byKey(_leaveConfirmLeaveKey));
          await tester.pump();

          expect(
            rig.sent('leave_room'),
            hasLength(1),
            reason:
                '$scenario: fixture: Home must have sent one leave_room '
                'as the route began to leave',
          );
          rig.last.pushText(
            _frame(
              type: 'player_left',
              re: rig.lastRequestId('leave_room'),
              data: <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': 99},
            ),
          );
          await _expectNoConnectionLost(tester, rig, log, scenario, heard);
        } finally {
          await _finish(tester, rig);
        }
      });
    }

    testWidgets(
      'D5.2 guard: Leave from the finished table (no confirm), the ack closes '
      'the phase during the exit transition: no connection-lost card, no '
      'Reconnect, no announcement (the offline end card is not asserted)',
      (tester) async {
        const String scenario = 'D5.2';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        final List<String> heard = _listenAnnouncements(tester);
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, scenario, room: _Room.finished);
          await tester.ensureVisible(find.byKey(_appBarLeaveKey));
          await tester.tap(find.byKey(_appBarLeaveKey));
          await tester.pump();

          expect(
            rig.sent('leave_room'),
            hasLength(1),
            reason:
                '$scenario: fixture: Home must have sent one leave_room as '
                'the route began to leave',
          );
          rig.last.pushText(
            _frame(
              type: 'player_left',
              re: rig.lastRequestId('leave_room'),
              data: <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': 99},
            ),
          );
          await _expectNoConnectionLost(tester, rig, log, scenario, heard);
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D5.3 guard: New table from the finished table, the ack closes the phase '
      'during the exit transition: no connection-lost card, no Reconnect, '
      'no announcement',
      (tester) async {
        const String scenario = 'D5.3';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        final List<String> heard = _listenAnnouncements(tester);
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, scenario, room: _Room.finished);
          await tester.ensureVisible(find.byKey(_newTableKey));
          await tester.tap(find.byKey(_newTableKey));
          await tester.pump();

          expect(
            rig.sent('leave_room'),
            hasLength(1),
            reason:
                '$scenario: fixture: Home must have sent one leave_room as '
                'the route began to leave',
          );
          rig.last.pushText(
            _frame(
              type: 'player_left',
              re: rig.lastRequestId('leave_room'),
              data: <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': 99},
            ),
          );
          await _expectNoConnectionLost(tester, rig, log, scenario, heard);
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D5.4: D5 a player_left naming me leaves the route, the leave\'s ack '
      'closes the phase during the exit transition: no connection-lost '
      'card, no Reconnect, no announcement',
      (tester) async {
        const String scenario = 'D5.4';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        final List<String> heard = _listenAnnouncements(tester);
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, scenario, room: _Room.playing);
          _pushPlayerLeft(rig, seat: 0, seq: 4);
          await tester.pump();
          await tester.pump();

          expect(
            rig.sent('leave_room'),
            hasLength(1),
            reason:
                '$scenario: fixture: Home must have sent one leave_room as '
                'the route began to leave',
          );
          rig.last.pushText(
            _frame(
              type: 'player_left',
              re: rig.lastRequestId('leave_room'),
              data: <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': 99},
            ),
          );
          await _expectNoConnectionLost(tester, rig, log, scenario, heard);
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets('D5.5 guard: a plain drop (nobody is leaving) draws the '
        'connection-lost card and TalkBack hears it', (tester) async {
      const String scenario = 'D5.5';
      _seedFreshSeat();
      final _Rig rig = _Rig();
      final _RouteLog log = _RouteLog();
      final List<String> heard = _listenAnnouncements(tester);
      await _mount(tester, rig, log);
      try {
        await _gameRoute(tester, rig, scenario, room: _Room.playing);
        rig.last.endFromFarSide();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final String lostLine = _loc(tester).lobbyConnectionLost;
        expect(
          find.byKey(_connectionLostKey),
          findsOneWidget,
          reason:
              '$scenario: expected the connection-lost card after a plain '
              'drop; saw ${_treeNote(tester, rig, log)}',
        );
        expect(
          heard,
          contains(lostLine),
          reason:
              '$scenario: expected TalkBack to hear "$lostLine" after a '
              'plain drop; heard $heard. ${_reproduce(scenario)}',
        );
      } finally {
        await _finish(tester, rig);
      }
    });
  });

  // ---------------------------------------------------------------- C-544 D1
  // Contract C-544 (work/ludo/orders/C-544-own-leave-no-offline-end-card.md):
  // on a finished table, and on a rematch lobby with lastFinished, my own
  // Leave or New table never swaps the end card for its offline variant while
  // the route exits. The offline line is the `end-card-offline` text
  // (endOffline); the offline Play again is the `end-card-rematch` button
  // beside it, so the cases compare that button with what the player saw at
  // the tap. The rematch lobby cases (D1.3, D1.4) are guards:
  // RoomController.leave() clears lastFinished at the tap, so a lobby never
  // reaches the offline end card on an own leave; they pin that it stays so.
  group('C-544 D1 my own leave never draws the offline end card', () {
    /// Pumps frame by frame after the leave's ack closed the phase and fails
    /// on the first frame where the leaving route draws the offline line, its
    /// text, or a Play again the card did not have at the tap.
    Future<void> expectNoOfflineEndCard(
      WidgetTester tester,
      _Rig rig,
      _RouteLog log,
      String scenario, {
      required bool playAgainAtTap,
    }) async {
      final String offlineLine = _loc(tester).endOffline;
      int framesWithRoute = 0;
      for (int i = 0; i < 40; i += 1) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.byType(GameScreen, skipOffstage: false).evaluate().isEmpty) {
          break;
        }
        framesWithRoute += 1;
        final String note =
            'frame $i after the ack; saw ${_treeNote(tester, rig, log)}. '
            '${_reproduce(scenario)}';
        expect(
          find.byKey(_offlineKey, skipOffstage: false),
          findsNothing,
          reason: '$scenario: expected no offline end card line at $note',
        );
        expect(
          find.text(offlineLine, skipOffstage: false),
          findsNothing,
          reason: '$scenario: expected no "$offlineLine" text at $note',
        );
        expect(
          find.byKey(_rematchKey, skipOffstage: false).evaluate().isNotEmpty,
          playAgainAtTap,
          reason:
              '$scenario: expected Play again '
              '${playAgainAtTap ? 'still drawn' : 'still absent'}, as at the '
              'tap, at $note',
        );
      }
      expect(
        framesWithRoute,
        greaterThan(0),
        reason:
            '$scenario: fixture: the route must still be on the tree after '
            'the ack, or the exit transition was not observed; saw '
            '${_treeNote(tester, rig, log)}',
      );
    }

    for (final ({String id, Locale? locale, _Room room, Key action}) variant
        in [
          (
            id: 'C-544 D1.1a',
            locale: null,
            room: _Room.finished,
            action: _appBarLeaveKey,
          ),
          (
            id: 'C-544 D1.1b',
            locale: _ar,
            room: _Room.finished,
            action: _appBarLeaveKey,
          ),
          (
            id: 'C-544 D1.2a',
            locale: null,
            room: _Room.finished,
            action: _newTableKey,
          ),
          (
            id: 'C-544 D1.2b',
            locale: _ar,
            room: _Room.finished,
            action: _newTableKey,
          ),
          (
            id: 'C-544 D1.3a',
            locale: null,
            room: _Room.rematch,
            action: _appBarLeaveKey,
          ),
          (
            id: 'C-544 D1.3b',
            locale: _ar,
            room: _Room.rematch,
            action: _appBarLeaveKey,
          ),
          (
            id: 'C-544 D1.4a',
            locale: null,
            room: _Room.rematch,
            action: _newTableKey,
          ),
          (
            id: 'C-544 D1.4b',
            locale: _ar,
            room: _Room.rematch,
            action: _newTableKey,
          ),
        ]) {
      testWidgets(
        '${variant.id}${variant.room == _Room.rematch ? ' guard' : ''}: '
        '${variant.room.name} table, '
        '${(variant.action as ValueKey<String>).value} (locale '
        '${variant.locale ?? 'en'}), the ack closes the phase during the '
        'exit transition: no offline end card line, no offline Play again',
        (tester) async {
          final String scenario = variant.id;
          _seedFreshSeat();
          final _Rig rig = _Rig();
          final _RouteLog log = _RouteLog();
          await _mount(tester, rig, log, locale: variant.locale);
          try {
            await _gameRoute(tester, rig, scenario, room: variant.room);
            expect(
              find.byKey(_offlineKey, skipOffstage: false),
              findsNothing,
              reason:
                  '$scenario: fixture: the connected end card is not offline',
            );
            if (variant.room == _Room.rematch) {
              expect(
                rig.controllers.first.lastFinished,
                isNotNull,
                reason:
                    '$scenario: fixture: a rematch lobby is the contract\'s case '
                    'only while lastFinished is held at the tap',
              );
            }
            final bool playAgainAtTap = find
                .byKey(_rematchKey, skipOffstage: false)
                .evaluate()
                .isNotEmpty;
            await tester.ensureVisible(find.byKey(variant.action));
            await tester.tap(find.byKey(variant.action));
            await tester.pump();

            expect(
              rig.sent('leave_room'),
              hasLength(1),
              reason:
                  '$scenario: fixture: Home must have sent one leave_room as '
                  'the route began to leave; saw ${_treeNote(tester, rig, log)}',
            );
            rig.last.pushText(
              _frame(
                type: 'player_left',
                re: rig.lastRequestId('leave_room'),
                data: <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': 99},
              ),
            );
            await expectNoOfflineEndCard(
              tester,
              rig,
              log,
              scenario,
              playAgainAtTap: playAgainAtTap,
            );
            expect(
              rig.controllers.first.phase,
              RoomPhase.closed,
              reason:
                  '$scenario: fixture: the ack must have closed the phase; '
                  'saw ${rig.controllers.first.phase}',
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );
    }

    for (final ({String id, Locale? locale}) variant in [
      (id: 'C-544 D1.5a', locale: null),
      (id: 'C-544 D1.5b', locale: _ar),
    ]) {
      testWidgets(
        '${variant.id} guard: an offline end card already up at the tap stays '
        'up through the exit (locale ${variant.locale ?? 'en'})',
        (tester) async {
          final String scenario = variant.id;
          _seedFreshSeat();
          final _Rig rig = _Rig();
          final _RouteLog log = _RouteLog();
          await _mount(tester, rig, log, locale: variant.locale);
          try {
            await _gameRoute(tester, rig, scenario, room: _Room.finished);
            rig.last.endFromFarSide();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(
              find.byKey(_offlineKey),
              findsOneWidget,
              reason:
                  '$scenario: fixture: a dropped finished table must show the '
                  'offline end card; saw ${_treeNote(tester, rig, log)}',
            );
            await tester.ensureVisible(find.byKey(_appBarLeaveKey));
            await tester.tap(find.byKey(_appBarLeaveKey));
            await tester.pump();

            int framesWithRoute = 0;
            for (int i = 0; i < 40; i += 1) {
              if (find
                  .byType(GameScreen, skipOffstage: false)
                  .evaluate()
                  .isEmpty) {
                break;
              }
              framesWithRoute += 1;
              expect(
                find.byKey(_offlineKey, skipOffstage: false),
                findsOneWidget,
                reason:
                    '$scenario: expected the offline end card to stay up '
                    'through the exit, as at the tap; frame $i, saw '
                    '${_treeNote(tester, rig, log)}. ${_reproduce(scenario)}',
              );
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(
              framesWithRoute,
              greaterThan(0),
              reason:
                  '$scenario: fixture: the route must be on the tree after '
                  'the tap; saw ${_treeNote(tester, rig, log)}',
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );
    }
  });

  // ---------------------------------------------------------------- D6
  group('D6 a tap during a leave already in flight does nothing', () {
    /// The pointer cannot reach a route that is already leaving: the
    /// Navigator absorbs the rest of the frame after a pop, and a reversing
    /// route ignores pointers from the next frame on. A second Leave that
    /// beat both (a tap in the frame of the pop, an assistive activation)
    /// runs the button's own handler, so the case calls that handler.
    void activate(WidgetTester tester, Key key, String scenario) {
      final Widget widget = tester.widget(find.byKey(key));
      final VoidCallback? handler = switch (widget) {
        IconButton() => widget.onPressed,
        ButtonStyleButton() => widget.onPressed,
        _ => null,
      };
      expect(
        handler,
        isNotNull,
        reason:
            '$scenario: fixture: ${(key as ValueKey<String>).value} must '
            'have a handler to activate',
      );
      handler!();
    }

    Future<void> expectHomeSurvived(
      WidgetTester tester,
      _Rig rig,
      _RouteLog log,
      String scenario, {
      required String when,
      bool expectHomeCurrent = true,
    }) async {
      expect(
        log.homeWasPopped,
        isFalse,
        reason:
            '$scenario: expected Home never to be popped $when; routes '
            'taken off: [${log.describe()}]. ${_reproduce(scenario)}',
      );
      await _settleHome(tester, rig);
      expect(
        log.homeWasPopped,
        isFalse,
        reason:
            '$scenario: expected Home never to be popped once the leave '
            'settled; routes taken off: [${log.describe()}]. '
            '${_reproduce(scenario)}',
      );
      expect(
        find.byType(HomeScreen, skipOffstage: false),
        findsOneWidget,
        reason:
            '$scenario: expected Home on the tree; saw '
            '${_treeNote(tester, rig, log)}. ${_reproduce(scenario)}',
      );
      if (expectHomeCurrent) {
        _expectRouteGone(tester, rig, log, scenario);
      }
    }

    /// Home, then a game route in [room] or the host lobby.
    Future<void> openRoute(
      WidgetTester tester,
      _Rig rig,
      _RouteLog log,
      String scenario, {
      required bool lobby,
      _Room? room,
    }) async {
      if (!lobby) {
        _seedFreshSeat();
      }
      await _mount(tester, rig, log, underBase: true);
      if (lobby) {
        await _hostLobby(tester, rig, scenario);
      } else {
        await _gameRoute(tester, rig, scenario, room: room!);
      }
    }

    // A real pointer: both taps are swallowed (the Navigator absorbs the
    // rest of the frame after the first pop), so Home survives today.
    void guardCase(String id, String what, Key key, {required bool lobby}) {
      testWidgets(
        '$id guard: $what tapped twice by a real pointer in one frame: Home '
        'is still the root and on screen',
        (tester) async {
          final _RouteLog log = _RouteLog();
          final _Rig rig = _Rig();
          try {
            await openRoute(
              tester,
              rig,
              log,
              id,
              lobby: lobby,
              room: _Room.finished,
            );
            await tester.ensureVisible(find.byKey(key));
            await tester.pump();
            await tester.tap(find.byKey(key), warnIfMissed: false);
            await tester.tap(find.byKey(key), warnIfMissed: false);

            await expectHomeSurvived(
              tester,
              rig,
              log,
              id,
              when: 'by the second tap',
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );
    }

    // The same control activated twice before a frame is drawn.
    void doubleCase(
      String id,
      String what,
      Key key, {
      required bool lobby,
      _Room? room,
      bool dropFirst = false,
    }) {
      testWidgets(
        '$id: $what activated twice in one frame: one pop, Home is still '
        'the root and on screen',
        (tester) async {
          final _RouteLog log = _RouteLog();
          final _Rig rig = _Rig();
          try {
            await openRoute(tester, rig, log, id, lobby: lobby, room: room);
            if (dropFirst) {
              rig.last.endFromFarSide();
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
            }
            await tester.ensureVisible(find.byKey(key));
            await tester.pump();
            final int leavesBefore = log.pageLeaves;

            activate(tester, key, id);
            expect(
              () => activate(tester, key, id),
              returnsNormally,
              reason:
                  '$id: expected the second activation to do nothing; it '
                  'went on to pop again. routes taken off: '
                  '[${log.describe()}]. ${_reproduce(id)}',
            );

            await expectHomeSurvived(
              tester,
              rig,
              log,
              id,
              when: 'by the second activation',
              expectHomeCurrent: key != _newTableKey,
            );
            expect(
              log.pageLeaves - leavesBefore,
              1,
              reason:
                  '$id: expected exactly one page route to leave; routes '
                  'taken off: [${log.describe()}]. ${_reproduce(id)}',
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );
    }

    // The control activated after a player_left naming me has already
    // started taking the route away.
    void serverCase(
      String id,
      String what,
      Key key, {
      required bool lobby,
      _Room? room,
    }) {
      testWidgets(
        '$id: $what activated while a player_left naming me is already '
        'taking the route away: Home is still the root and on screen',
        (tester) async {
          final _RouteLog log = _RouteLog();
          final _Rig rig = _Rig();
          try {
            await openRoute(tester, rig, log, id, lobby: lobby, room: room);
            await tester.ensureVisible(find.byKey(key));
            await tester.pump();
            final int leavesBefore = log.pageLeaves;

            _pushPlayerLeft(rig, seat: 0, seq: 10);
            await tester.pump();
            expect(
              log.pageLeaves - leavesBefore,
              1,
              reason:
                  '$id: fixture: the server-driven leave must be running '
                  '(one page route taken off); routes taken off: '
                  '[${log.describe()}]. ${_reproduce(id)}',
            );
            expect(
              () => activate(tester, key, id),
              returnsNormally,
              reason:
                  '$id: expected an activation during the server-driven '
                  'leave to do nothing; it went on to pop again. routes '
                  'taken off: [${log.describe()}]. ${_reproduce(id)}',
            );

            await expectHomeSurvived(
              tester,
              rig,
              log,
              id,
              when: 'by an activation during the server-driven leave',
            );
            expect(
              log.pageLeaves - leavesBefore,
              1,
              reason:
                  '$id: expected exactly one page route to leave; routes '
                  'taken off: [${log.describe()}]. ${_reproduce(id)}',
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );
    }

    // The lobby cases run last: a Home popped by a stray second activation
    // leaves the binding mid-frame, and nothing may run after that.
    guardCase(
      'D6.8',
      'Leave on the finished game route',
      _appBarLeaveKey,
      lobby: false,
    );
    guardCase('D6.9', 'Leave on the lobby route', _lobbyLeaveKey, lobby: true);
    doubleCase(
      'D6.1',
      'Leave on the finished game route',
      _appBarLeaveKey,
      lobby: false,
      room: _Room.finished,
    );
    doubleCase(
      'D6.2',
      'Leave on the connection-lost card',
      _gameLeaveKey,
      lobby: false,
      room: _Room.playing,
      dropFirst: true,
    );
    doubleCase(
      'D6.3',
      'New table on the finished game route',
      _newTableKey,
      lobby: false,
      room: _Room.finished,
    );
    serverCase(
      'D6.5',
      'Leave on the finished game route',
      _appBarLeaveKey,
      lobby: false,
      room: _Room.finished,
    );
    serverCase(
      'D6.6',
      'New table on the finished game route',
      _newTableKey,
      lobby: false,
      room: _Room.finished,
    );
    doubleCase('D6.4', 'Leave on the lobby route', _lobbyLeaveKey, lobby: true);
    serverCase('D6.7', 'Leave on the lobby route', _lobbyLeaveKey, lobby: true);
  });
}

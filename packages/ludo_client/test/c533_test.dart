// Proof for contract C-533
// (work/ludo/orders/C-533-leave-above-sheets-error-cards-no-zero-tiles.md),
// written from the contract alone: D1 leaving from under a sheet, D2 the
// lobby error and never-connected bodies as a card, D3 no stat tile shows 0.
//
// The D1 rig is the one test/c529_a1_test.dart uses (copied, not imported):
// the real HomeScreen, RoomRoute, LobbyScreen and GameScreen over a real
// RoomController on FakeTransport, a fresh transport per connect. The D2 rig
// mounts LobbyScreen on its own over a RoomController on FakeTransport. The D3
// rig mounts EndCard on its own.
//
// The lobby has no sheet of its own any more (C-523 D7 replaced the settings
// button and its sheet with the sound toggle), so the D1.2 and D1.3 cases put
// a modal bottom sheet, and in one case a dialog on top of it, above the
// lobby route from the lobby's own context. That is the "everything above the
// lobby route" the contract names.
//
// Cases:
//   D1.1  game route, leave confirm or quick chat open, player_left naming my
//         seat: Home shows the removed notice, no route and no sheet left. No
//         sheet: the same. Another seat: nothing moves. Two frames: one pop.
//   D1.2  lobby route, sheet open, player_left naming my seat: same.
//   D1.3  lobby route, sheet open, resume answered NO_SUCH_ROOM while a room
//         is held: Home shows the room-closed line, no route, no sheet.
//   D2    lobby-error-card and lobby-closed, en and ar.
//   D3    the end-card stat tiles, winner and loser, en and ar.
//
// Not covered: D1.1's "_clearSafeCue() runs first". The cue is a pill on the
// game route and leaves with it, so nothing on the tree tells the orders apart
// once the route is gone.
//
// Each failure reason names the case, what was expected and what was on the
// tree. There is no random input: the case id reproduces it exactly, with
//   flutter test test/c533_test.dart --plain-name '<id>'

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/game_stats.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/room_route.dart';
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:ludo_client/src/theme.dart'
    show LudoColors, buildAppTheme, kSpace4;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _createKey = Key('create-room-button');
const Key _removedNoticeKey = Key('home-removed-notice');
const Key _roomClosedNoticeKey = Key('home-room-closed-notice');
const Key _gameGoneNoticeKey = Key('home-game-gone-notice');
const Key _staleTableKey = Key('game-screen-stale-table');
const Key _appBarLeaveKey = Key('game-screen-appbar-leave');
const Key _leaveConfirmKey = Key('game-leave-confirm');
const Key _chatButtonKey = Key('game-chat-button');
const Key _chatSheetKey = Key('quick-chat-sheet');
const Key _testSheetKey = Key('c533-lobby-sheet');
const Key _testDialogKey = Key('c533-lobby-dialog');

const Key _errorKey = Key('lobby-error');
const Key _errorCardKey = Key('lobby-error-card');
const Key _closedKey = Key('lobby-closed');
const Key _retryKey = Key('lobby-retry-button');
const Key _leaveKey = Key('lobby-leave-button');
const Key _reconnectKey = Key('lobby-reconnect-button');
const Key _reconnectingKey = Key('lobby-reconnecting');

const Key _statRollsKey = Key('end-card-stat-rolls');
const Key _statSixesKey = Key('end-card-stat-sixes');
const Key _statCapturesKey = Key('end-card-stat-captures');
const Key _statHomeKey = Key('end-card-stat-home');
const Key _loseKey = Key('end-card-lose');
const Key _loseLineKey = Key('end-card-lose-line');
const Key _winKey = Key('end-card-win');
const Key _winnerTitleKey = Key('game-screen-winner');
const Key _verifyKey = Key('game-screen-verify-button');

const List<Key> _tileOrder = <Key>[
  _statRollsKey,
  _statSixesKey,
  _statCapturesKey,
  _statHomeKey,
];

const String _testUrl = 'wss://c533-test.invalid/ws';
const String _code = 'K7M2QP';
const String _token = 'tok-c533-001';
const String _gameId = '7f3a9c1e5b2d4068';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';

const Locale _ar = Locale('ar');

String _reproduce(String id) =>
    'reproduce: flutter test test/c533_test.dart --plain-name "$id"';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c533-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  required String state,
  String? gameId,
  Map<String, Object?>? turn,
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
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': gameId,
  'client_seeds': gameId == null ? null : '0:sam-seed|1:bob-seed',
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Host'),
    _seatJson(1, name: 'Guest'),
  ],
  'turn': turn,
  'winner': null,
  'seq': 3,
};

Map<String, Object?> _lobbyRoom() => _roomJson(state: 'LOBBY');

Map<String, Object?> _playingRoom() => _roomJson(
  state: 'PLAYING',
  gameId: _gameId,
  turn: const <String, Object?>{
    'seat': 0,
    'phase': 'await_roll',
    'deadline_ms': 45000,
    'k': 0,
  },
);

// ---------------------------------------------------------------- D1 rig

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

/// Records every route the navigator takes off its stack, so "acts once" can
/// be asserted as a count and "no extra pop of Home" as an empty list.
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

  /// Page routes taken off: the room route is one, Home is another.
  int get pageLeaves =>
      events.where((e) => e.route is PageRoute<dynamic>).length;

  bool get homeWasPopped => events.any((e) => e.wasFirst);

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
}) {
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
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: factory,
      initialLinkReader: noInitialLink,
      linkStream: noLinkStream,
    ),
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
}) async {
  await tester.pumpWidget(_app(rig.call, locale: locale, log: log));
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

/// Home resumes on its own from a fresh record and the server answers with a
/// PLAYING room: the game route is up and the controller is connected.
Future<void> _playingGame(
  WidgetTester tester,
  _Rig rig,
  String scenario,
) async {
  expect(
    rig.sent('resume'),
    hasLength(1),
    reason: '$scenario: fixture: a fresh record resumes on its own',
  );
  _answerRoom(rig.last, rig.lastRequestId('resume'), _playingRoom(), seat: 0);
  await _pumpBounded(tester, frames: 3);
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: '$scenario: fixture: a PLAYING resume shows GameScreen',
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

enum _Over { confirm, chat, none }

enum _LobbyOver { none, sheet, sheetAndDialog }

/// Puts a modal bottom sheet (and, for [_LobbyOver.sheetAndDialog], a dialog
/// over it) above the lobby route, from the lobby's own context.
Future<void> _openOverLobby(
  WidgetTester tester,
  _LobbyOver over,
  String scenario,
) async {
  if (over == _LobbyOver.none) {
    return;
  }
  final BuildContext context = tester.element(find.byType(LobbyScreen));
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) =>
          const SizedBox(key: _testSheetKey, height: 200),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(
    find.byKey(_testSheetKey),
    findsOneWidget,
    reason: '$scenario: fixture: the sheet must be up over the lobby',
  );
  if (over == _LobbyOver.sheetAndDialog) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) =>
            const Dialog(child: SizedBox(key: _testDialogKey, height: 80)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(_testDialogKey),
      findsOneWidget,
      reason: '$scenario: fixture: the dialog must be up over the sheet',
    );
  }
  expect(
    find.byType(LobbyScreen),
    findsOneWidget,
    reason: '$scenario: fixture: the lobby route is still under the sheet',
  );
  expect(
    ModalRoute.of(context)!.isCurrent,
    isFalse,
    reason: '$scenario: fixture: the lobby route must not be current',
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

String _treeNote(WidgetTester tester, _RouteLog log) =>
    'GameScreen=${find.byType(GameScreen, skipOffstage: false).evaluate().length} '
    'LobbyScreen=${find.byType(LobbyScreen, skipOffstage: false).evaluate().length} '
    'RoomRoute=${find.byType(RoomRoute, skipOffstage: false).evaluate().length} '
    'leave-confirm=${find.byKey(_leaveConfirmKey, skipOffstage: false).evaluate().length} '
    'quick-chat-sheet=${find.byKey(_chatSheetKey, skipOffstage: false).evaluate().length} '
    'test-sheet=${find.byKey(_testSheetKey, skipOffstage: false).evaluate().length} '
    'test-dialog=${find.byKey(_testDialogKey, skipOffstage: false).evaluate().length} '
    'stale-table=${find.byKey(_staleTableKey, skipOffstage: false).evaluate().length} '
    'homeIsCurrent=${_homeIsCurrent(tester)} '
    'removed-notice=${find.byKey(_removedNoticeKey).evaluate().length} '
    'room-closed-notice=${find.byKey(_roomClosedNoticeKey).evaluate().length} '
    'game-gone-notice=${find.byKey(_gameGoneNoticeKey).evaluate().length} '
    'routes taken off: [${log.describe()}]';

/// Nothing of the room route and no sheet left; Home is the current route.
void _expectRouteAndSheetsGone(
  WidgetTester tester,
  _RouteLog log,
  String scenario,
) {
  final String note = _treeNote(tester, log);
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
    (_testSheetKey, 'the test sheet'),
    (_testDialogKey, 'the test dialog'),
    (_staleTableKey, 'the dimmed stale table'),
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
  _RouteLog log,
  String scenario, {
  required Key key,
  required String expected,
}) {
  final Finder notice = find.byKey(key);
  expect(
    notice,
    findsOneWidget,
    reason:
        '$scenario: expected Home to show ${key.toString()}; saw '
        '${_treeNote(tester, log)}. ${_reproduce(scenario)}',
  );
  expect(
    tester.widget<Text>(notice).data,
    expected,
    reason:
        '$scenario: expected the notice to read "$expected"; read '
        '"${tester.widget<Text>(notice).data}". ${_reproduce(scenario)}',
  );
}

// ---------------------------------------------------------------- D2 rig

/// A controller whose reconnect schedule reads as pending. No wire frame makes
/// a controller with no room schedule one (a schedule needs a room and a seat
/// token), and the closed body has to draw its reconnecting line for that
/// flag, so this is the one getter the case overrides.
class _PendingController extends RoomController {
  _PendingController({required super.serverUrl, required super.connect});

  bool pending = false;

  @override
  bool get autoReconnectPending => pending;

  void poke() => notifyListeners();
}

Widget _lobbyApp(Widget child, {Locale? locale}) {
  return MaterialApp(
    theme: buildAppTheme(),
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

class _Direct {
  _Direct({this.connectFails = false, bool pendingFlag = false}) {
    Future<WireTransport> connect(Uri url) async {
      if (connectFails) {
        throw StateError('c533_test: connect rejected');
      }
      return transport;
    }

    controller = pendingFlag
        ? _PendingController(serverUrl: Uri.parse(_testUrl), connect: connect)
        : RoomController(serverUrl: Uri.parse(_testUrl), connect: connect);
  }

  final bool connectFails;
  final FakeTransport transport = FakeTransport();
  late final RoomController controller;
}

/// Mounts a join lobby for [_code], answers it with [errorCode] (or lets the
/// connect fail when [connectFails]), and returns with the error body up.
Future<_Direct> _errorLobby(
  WidgetTester tester, {
  required String? errorCode,
  Locale? locale,
  bool fromLink = false,
  bool connectFails = false,
}) async {
  final _Direct direct = _Direct(connectFails: connectFails);
  addTearDown(direct.controller.dispose);
  await tester.pumpWidget(
    _lobbyApp(
      LobbyScreen(
        controller: direct.controller,
        action: LobbyAction.join,
        code: _code,
        playerName: 'Sam',
        fromLink: fromLink,
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump();
  if (errorCode != null) {
    expect(
      direct.transport.sentRaw,
      isNotEmpty,
      reason: 'fixture: the join must have been sent',
    );
    _answerError(
      direct.transport,
      _idOf(direct.transport.sentRaw.last),
      errorCode,
    );
    await tester.pump();
    await tester.pump();
  }
  return direct;
}

/// Mounts a join lobby and takes it to phase closed with no room held: the
/// player leaves while the join is still unanswered, which closes the
/// controller and keeps no room.
Future<_Direct> _closedLobby(
  WidgetTester tester, {
  Locale? locale,
  bool pending = false,
}) async {
  final _Direct direct = _Direct(pendingFlag: true);
  addTearDown(direct.controller.dispose);
  await tester.pumpWidget(
    _lobbyApp(
      LobbyScreen(
        controller: direct.controller,
        action: LobbyAction.join,
        code: _code,
        playerName: 'Sam',
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump();
  final Future<void> left = direct.controller.leave();
  await tester.pump();
  await tester.pump(const Duration(seconds: 11));
  await left;
  if (pending) {
    final _PendingController controller =
        direct.controller as _PendingController;
    controller.pending = true;
    controller.poke();
  }
  await tester.pump();
  return direct;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

AppLocalizations _locOfLobby(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(LobbyScreen)));

/// The contract's card, checked as a whole. [card] is the Material's key,
/// [icon] the icon the code asks for, [text] the exact line, [elevated] the
/// key of the one ElevatedButton, [outlined] the key of the one OutlinedButton
/// or null for none.
void _expectCard(
  WidgetTester tester, {
  required String id,
  required Key card,
  required IconData icon,
  required String text,
  required Key elevated,
  required Key? outlined,
  required String leaveLabel,
  required TextDirection direction,
}) {
  final Finder cardFinder = find.byKey(card);
  expect(
    cardFinder,
    findsOneWidget,
    reason:
        '$id: expected one widget keyed $card; found '
        '${cardFinder.evaluate().length}. ${_reproduce(id)}',
  );
  final Widget cardWidget = tester.widget(cardFinder);
  expect(
    cardWidget,
    isA<Material>(),
    reason:
        '$id: expected $card to be a Material; it is a '
        '${cardWidget.runtimeType}. ${_reproduce(id)}',
  );
  final Material material = cardWidget as Material;
  expect(
    material.color,
    LudoColors.paperElevated,
    reason:
        '$id: expected the card colour LudoColors.paperElevated; saw '
        '${material.color}. ${_reproduce(id)}',
  );
  expect(
    material.elevation,
    6,
    reason:
        '$id: expected the card elevation 6 (the game connection-lost '
        'card); saw ${material.elevation}. ${_reproduce(id)}',
  );
  expect(
    tester.getSize(cardFinder).width,
    lessThanOrEqualTo(320),
    reason:
        '$id: expected the card at most 320 dp wide; saw '
        '${tester.getSize(cardFinder).width}. ${_reproduce(id)}',
  );

  final Finder icons = find.descendant(
    of: cardFinder,
    matching: find.byType(Icon),
  );
  expect(
    icons,
    findsOneWidget,
    reason:
        '$id: expected exactly one Icon in the card; found '
        '${icons.evaluate().length}. ${_reproduce(id)}',
  );
  final Icon iconWidget = tester.widget<Icon>(icons);
  expect(
    iconWidget.icon,
    icon,
    reason:
        '$id: expected the icon $icon; saw ${iconWidget.icon}. '
        '${_reproduce(id)}',
  );
  expect(
    iconWidget.size,
    32,
    reason:
        '$id: expected a 32 dp icon; saw ${iconWidget.size}. '
        '${_reproduce(id)}',
  );
  expect(
    iconWidget.color,
    LudoColors.inkMuted,
    reason:
        '$id: expected the icon in inkMuted; saw ${iconWidget.color}. '
        '${_reproduce(id)}',
  );

  final Finder line = find.descendant(
    of: cardFinder,
    matching: find.text(text),
  );
  expect(
    line,
    findsOneWidget,
    reason:
        '$id: expected the line "$text" inside the card; texts inside: '
        '${find.descendant(of: cardFinder, matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data).toList()}. '
        '${_reproduce(id)}',
  );
  expect(
    tester.widget<Text>(line).style?.color,
    LudoColors.ink,
    reason:
        '$id: expected the line in ink; saw '
        '${tester.widget<Text>(line).style?.color}. ${_reproduce(id)}',
  );
  expect(
    Directionality.of(tester.element(line)),
    direction,
    reason:
        '$id: expected text direction $direction around the line; saw '
        '${Directionality.of(tester.element(line))}. ${_reproduce(id)}',
  );

  final Finder filled = find.descendant(
    of: cardFinder,
    matching: find.byType(ElevatedButton),
  );
  expect(
    filled,
    findsOneWidget,
    reason:
        '$id: expected exactly one ElevatedButton in the card; found '
        '${filled.evaluate().length}. ${_reproduce(id)}',
  );
  expect(
    tester.widget(filled).key,
    elevated,
    reason:
        '$id: expected the ElevatedButton to be $elevated; it is '
        '${tester.widget(filled).key}. ${_reproduce(id)}',
  );
  final Finder outline = find.descendant(
    of: cardFinder,
    matching: find.byType(OutlinedButton),
  );
  if (outlined == null) {
    expect(
      outline,
      findsNothing,
      reason:
          '$id: expected no OutlinedButton in the card; found '
          '${outline.evaluate().length}. ${_reproduce(id)}',
    );
  } else {
    expect(
      outline,
      findsOneWidget,
      reason:
          '$id: expected exactly one OutlinedButton in the card; found '
          '${outline.evaluate().length}. ${_reproduce(id)}',
    );
    expect(
      tester.widget(outline).key,
      outlined,
      reason:
          '$id: expected the OutlinedButton to be $outlined; it is '
          '${tester.widget(outline).key}. ${_reproduce(id)}',
    );
  }

  final Finder leave = find.descendant(
    of: cardFinder,
    matching: find.byKey(_leaveKey),
  );
  expect(
    leave,
    findsOneWidget,
    reason: '$id: expected $_leaveKey inside the card. ${_reproduce(id)}',
  );
  expect(
    find.descendant(of: leave, matching: find.text(leaveLabel)),
    findsOneWidget,
    reason:
        '$id: expected the way out to read "$leaveLabel". ${_reproduce(id)}',
  );
  expect(
    tester.widget(leave),
    outlined == null ? isA<ElevatedButton>() : isA<OutlinedButton>(),
    reason:
        '$id: expected the way out to be '
        '${outlined == null ? 'the ElevatedButton' : 'an OutlinedButton'}; it '
        'is a ${tester.widget(leave).runtimeType}. ${_reproduce(id)}',
  );

  for (final Key key in <Key>[elevated, ?outlined]) {
    final double height = tester.getSize(find.byKey(key)).height;
    expect(
      height,
      greaterThanOrEqualTo(48),
      reason:
          '$id: expected $key at least 48 dp tall; saw $height. '
          '${_reproduce(id)}',
    );
  }

  final double iconY = tester.getTopLeft(icons).dy;
  final double lineY = tester.getTopLeft(line).dy;
  final double filledY = tester.getTopLeft(filled).dy;
  expect(
    iconY < lineY && lineY < filledY,
    isTrue,
    reason:
        '$id: expected icon, then line, then buttons from the top; saw tops '
        'icon $iconY, line $lineY, elevated button $filledY. ${_reproduce(id)}',
  );
  if (outlined != null) {
    final double outlineY = tester.getTopLeft(outline).dy;
    expect(
      filledY < outlineY,
      isTrue,
      reason:
          '$id: expected the ElevatedButton above the OutlinedButton; saw '
          'tops $filledY and $outlineY. ${_reproduce(id)}',
    );
  }
}

// ---------------------------------------------------------------- D3 rig

Widget _cardApp({
  required Locale locale,
  required GameStats? stats,
  required bool winner,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(kSpace4),
        child: EndCard(
          mySeat: 0,
          winnerSeat: winner ? 0 : 1,
          winnerName: winner ? 'Sam' : 'Bob',
          seatColors: LudoColors.seats,
          stats: stats,
          verifyUrl: 'https://c533-test.invalid/verify',
          onVerify: () {},
          onNewTable: () {},
          onRematch: () {},
        ),
      ),
    ),
  );
}

GameStats _stats({
  int rolls = 0,
  int sixes = 0,
  int captures = 0,
  int home = 0,
  bool complete = true,
}) => GameStats(
  rolls: rolls,
  sixes: sixes,
  capturesMade: captures,
  timesCaptured: 0,
  tokensHome: home,
  complete: complete,
);

Future<void> _mountCard(
  WidgetTester tester, {
  required GameStats? stats,
  required bool winner,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _cardApp(locale: locale, stats: stats, winner: winner),
  );
  await tester.pump();
  expect(
    find.byKey(winner ? _winKey : _loseKey),
    findsOneWidget,
    reason: 'fixture: the ${winner ? 'win' : 'lose'} card must be up',
  );
}

List<Key> _tilesOnCard() => <Key>[
  for (final Key key in _tileOrder)
    if (find.byKey(key).evaluate().isNotEmpty) key,
];

String _keyName(Key key) => (key as ValueKey<String>).value;

/// Every key that starts with end-card-stat- anywhere in the tree.
List<String> _allStatKeys(WidgetTester tester) {
  final List<String> found = <String>[];
  for (final Element element
      in find
          .byWidgetPredicate(
            (Widget w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('end-card-stat-'),
            skipOffstage: false,
          )
          .evaluate()) {
    found.add((element.widget.key! as ValueKey<String>).value);
  }
  return found;
}

void _expectTiles(
  WidgetTester tester, {
  required String id,
  required List<Key> expected,
}) {
  final List<String> all = _allStatKeys(tester);
  expect(
    all,
    expected.map(_keyName).toList(),
    reason:
        '$id: expected the stat tiles ${expected.map(_keyName).toList()} in '
        'that order; saw $all. ${_reproduce(id)}',
  );
}

/// Vertical distance from the bottom of [above] to the top of the Check the
/// rolls button: it contains the stat row and the gaps around it, whatever
/// the card keeps between the two.
double _gapToFairness(WidgetTester tester, Key above) =>
    tester.getTopLeft(find.byKey(_verifyKey)).dy -
    tester.getBottomLeft(find.byKey(above)).dy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- D1.1
  group('D1.1 a player_left naming my seat leaves the game route', () {
    for (final ({String id, Locale? locale, _Over over}) variant in [
      (id: 'D1.1a', locale: null, over: _Over.confirm),
      (id: 'D1.1b', locale: null, over: _Over.chat),
      (id: 'D1.1c', locale: null, over: _Over.none),
      (id: 'D1.1d', locale: _ar, over: _Over.confirm),
      (id: 'D1.1e', locale: _ar, over: _Over.chat),
      (id: 'D1.1f', locale: _ar, over: _Over.none),
    ]) {
      testWidgets('${variant.id}: ${variant.over.name} over the game, locale '
          '${variant.locale ?? 'en'}: Home shows the removed notice, no route '
          'and no sheet left', (tester) async {
        final String scenario = variant.id;
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log, locale: variant.locale);
        try {
          await _playingGame(tester, rig, scenario);
          switch (variant.over) {
            case _Over.confirm:
              await _tap(tester, _appBarLeaveKey);
              expect(
                find.byKey(_leaveConfirmKey),
                findsOneWidget,
                reason: '$scenario: fixture: the leave confirm must be open',
              );
            case _Over.chat:
              await _tap(tester, _chatButtonKey);
              expect(
                find.byKey(_chatSheetKey),
                findsOneWidget,
                reason: '$scenario: fixture: the chat sheet must be open',
              );
            case _Over.none:
              break;
          }
          final int leavesBefore = log.pageLeaves;

          _pushPlayerLeft(rig, seat: 0, seq: 4);
          await _pumpBounded(tester, frames: 2);
          await _settleHome(tester, rig);

          _expectRouteAndSheetsGone(tester, log, scenario);
          _expectHomeNotice(
            tester,
            log,
            scenario,
            key: _removedNoticeKey,
            expected: _loc(tester).homeRemovedNotice,
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
      'D1.1g: a player_left naming the other seat leaves the game route and '
      'the leave confirm exactly as they were',
      (tester) async {
        const String scenario = 'D1.1g';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _playingGame(tester, rig, scenario);
          await _tap(tester, _appBarLeaveKey);
          expect(find.byKey(_leaveConfirmKey), findsOneWidget);
          final int leavesBefore = log.pageLeaves;

          _pushPlayerLeft(rig, seat: 1, seq: 4);
          await _pumpBounded(tester, frames: 2);
          for (int i = 0; i < 20; i += 1) {
            await tester.pump(const Duration(milliseconds: 100));
          }

          final String note = _treeNote(tester, log);
          expect(
            find.byType(GameScreen),
            findsOneWidget,
            reason:
                '$scenario: expected the game route to stay; saw $note. '
                '${_reproduce(scenario)}',
          );
          expect(
            find.byKey(_leaveConfirmKey),
            findsOneWidget,
            reason:
                '$scenario: expected the leave confirm to stay; saw $note. '
                '${_reproduce(scenario)}',
          );
          expect(
            _homeIsCurrent(tester),
            isFalse,
            reason:
                '$scenario: expected Home not to be current; saw $note. '
                '${_reproduce(scenario)}',
          );
          expect(
            find.byKey(_removedNoticeKey, skipOffstage: false),
            findsNothing,
            reason:
                '$scenario: expected no removed notice; saw $note. '
                '${_reproduce(scenario)}',
          );
          expect(
            log.pageLeaves - leavesBefore,
            0,
            reason:
                '$scenario: expected no page route to leave; saw $note. '
                '${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D1.1h: a player_left naming the other seat with no sheet leaves the '
      'game route as it was',
      (tester) async {
        const String scenario = 'D1.1h';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _playingGame(tester, rig, scenario);
          final int leavesBefore = log.pageLeaves;

          _pushPlayerLeft(rig, seat: 1, seq: 4);
          await _pumpBounded(tester, frames: 2);

          final String note = _treeNote(tester, log);
          expect(
            find.byType(GameScreen),
            findsOneWidget,
            reason:
                '$scenario: expected the game route to stay; saw $note. '
                '${_reproduce(scenario)}',
          );
          expect(
            log.pageLeaves - leavesBefore,
            0,
            reason:
                '$scenario: expected no page route to leave; saw $note. '
                '${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    for (final ({String id, _Over over}) variant in [
      (id: 'D1.1j', over: _Over.none),
    ]) {
      testWidgets(
        '${variant.id}: two player_left frames naming my seat, ${variant.over.name} '
        'over the game: one pop, Home is never popped',
        (tester) async {
          final String scenario = variant.id;
          _seedFreshSeat();
          final _Rig rig = _Rig();
          final _RouteLog log = _RouteLog();
          await _mount(tester, rig, log);
          try {
            await _playingGame(tester, rig, scenario);
            if (variant.over == _Over.confirm) {
              await _tap(tester, _appBarLeaveKey);
              expect(find.byKey(_leaveConfirmKey), findsOneWidget);
            }
            final int leavesBefore = log.pageLeaves;

            // Both land before the next frame is pumped.
            _pushPlayerLeft(rig, seat: 0, seq: 4);
            _pushPlayerLeft(rig, seat: 0, seq: 5);
            await _pumpBounded(tester, frames: 2);
            await _settleHome(tester, rig);

            expect(
              log.homeWasPopped,
              isFalse,
              reason:
                  '$scenario: expected Home never to be popped by the second '
                  'frame; routes taken off: [${log.describe()}]. '
                  '${_reproduce(scenario)}',
            );
            expect(
              log.pageLeaves - leavesBefore,
              1,
              reason:
                  '$scenario: expected exactly one page route to leave; '
                  'routes taken off: [${log.describe()}]. '
                  '${_reproduce(scenario)}',
            );
            expect(
              find.byType(HomeScreen, skipOffstage: false),
              findsOneWidget,
              reason:
                  '$scenario: expected Home to be on the tree; saw '
                  '${_treeNote(tester, log)}. ${_reproduce(scenario)}',
            );
            _expectRouteAndSheetsGone(tester, log, scenario);
            _expectHomeNotice(
              tester,
              log,
              scenario,
              key: _removedNoticeKey,
              expected: _loc(tester).homeRemovedNotice,
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );
    }
  });

  // ---------------------------------------------------------------- D1.2
  group('D1.2 a player_left naming my seat leaves the lobby route', () {
    for (final ({String id, Locale? locale, _LobbyOver over}) variant in [
      (id: 'D1.2a', locale: null, over: _LobbyOver.sheet),
      (id: 'D1.2b', locale: _ar, over: _LobbyOver.sheet),
      (id: 'D1.2c', locale: null, over: _LobbyOver.sheetAndDialog),
      (id: 'D1.2d', locale: null, over: _LobbyOver.none),
      (id: 'D1.2e', locale: _ar, over: _LobbyOver.none),
    ]) {
      testWidgets('${variant.id}: ${variant.over.name} over the lobby, locale '
          '${variant.locale ?? 'en'}: Home shows the removed notice, no route '
          'and no sheet left', (tester) async {
        final String scenario = variant.id;
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log, locale: variant.locale);
        try {
          await _hostLobby(tester, rig, scenario);
          await _openOverLobby(tester, variant.over, scenario);
          final int leavesBefore = log.pageLeaves;

          _pushPlayerLeft(rig, seat: 0, seq: 4);
          await _pumpBounded(tester, frames: 2);
          await _settleHome(tester, rig);

          _expectRouteAndSheetsGone(tester, log, scenario);
          _expectHomeNotice(
            tester,
            log,
            scenario,
            key: _removedNoticeKey,
            expected: _loc(tester).homeRemovedNotice,
          );
          expect(
            log.pageLeaves - leavesBefore,
            1,
            reason:
                '$scenario: expected exactly one page route to leave (the '
                'lobby route); routes taken off: [${log.describe()}]. '
                '${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      });
    }

    testWidgets(
      'D1.2f: a player_left naming the other seat leaves the lobby route and '
      'the sheet as they were',
      (tester) async {
        const String scenario = 'D1.2f';
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _hostLobby(tester, rig, scenario);
          await _openOverLobby(tester, _LobbyOver.sheet, scenario);
          final int leavesBefore = log.pageLeaves;

          _pushPlayerLeft(rig, seat: 1, seq: 4);
          await _pumpBounded(tester, frames: 2);
          for (int i = 0; i < 20; i += 1) {
            await tester.pump(const Duration(milliseconds: 100));
          }

          final String note = _treeNote(tester, log);
          expect(
            find.byType(LobbyScreen),
            findsOneWidget,
            reason:
                '$scenario: expected the lobby route to stay; saw $note. '
                '${_reproduce(scenario)}',
          );
          expect(
            find.byKey(_testSheetKey),
            findsOneWidget,
            reason:
                '$scenario: expected the sheet to stay; saw $note. '
                '${_reproduce(scenario)}',
          );
          expect(
            log.pageLeaves - leavesBefore,
            0,
            reason:
                '$scenario: expected no page route to leave; saw $note. '
                '${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    for (final ({String id, _LobbyOver over}) variant in [
      (id: 'D1.2g', over: _LobbyOver.sheet),
      (id: 'D1.2h', over: _LobbyOver.none),
    ]) {
      testWidgets(
        '${variant.id}: two player_left frames naming my seat, ${variant.over.name} '
        'over the lobby: one pop, Home is never popped',
        (tester) async {
          final String scenario = variant.id;
          final _Rig rig = _Rig();
          final _RouteLog log = _RouteLog();
          await _mount(tester, rig, log);
          try {
            await _hostLobby(tester, rig, scenario);
            await _openOverLobby(tester, variant.over, scenario);
            final int leavesBefore = log.pageLeaves;

            _pushPlayerLeft(rig, seat: 0, seq: 4);
            _pushPlayerLeft(rig, seat: 0, seq: 5);
            await _pumpBounded(tester, frames: 2);
            await _settleHome(tester, rig);

            expect(
              log.homeWasPopped,
              isFalse,
              reason:
                  '$scenario: expected Home never to be popped by the second '
                  'frame; routes taken off: [${log.describe()}]. '
                  '${_reproduce(scenario)}',
            );
            expect(
              log.pageLeaves - leavesBefore,
              1,
              reason:
                  '$scenario: expected exactly one page route to leave; '
                  'routes taken off: [${log.describe()}]. '
                  '${_reproduce(scenario)}',
            );
            _expectRouteAndSheetsGone(tester, log, scenario);
            _expectHomeNotice(
              tester,
              log,
              scenario,
              key: _removedNoticeKey,
              expected: _loc(tester).homeRemovedNotice,
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );
    }
  });

  // ---------------------------------------------------------------- D1.3
  group('D1.3 a room that closed while away leaves the lobby route', () {
    for (final ({String id, Locale? locale, _LobbyOver over, bool host}) variant
        in [
          (id: 'D1.3a', locale: null, over: _LobbyOver.sheet, host: true),
          (id: 'D1.3b', locale: _ar, over: _LobbyOver.sheet, host: true),
          (
            id: 'D1.3c',
            locale: null,
            over: _LobbyOver.sheetAndDialog,
            host: true,
          ),
          (id: 'D1.3d', locale: null, over: _LobbyOver.sheet, host: false),
          (id: 'D1.3e', locale: null, over: _LobbyOver.none, host: true),
        ]) {
      testWidgets('${variant.id}: ${variant.host ? 'host' : 'guest'}, '
          '${variant.over.name} over the lobby, locale '
          '${variant.locale ?? 'en'}: socket drop, resume answered '
          'NO_SUCH_ROOM: Home shows the room-closed line, no route and no '
          'sheet left', (tester) async {
        final String scenario = variant.id;
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log, locale: variant.locale);
        try {
          if (variant.host) {
            await _hostLobby(tester, rig, scenario);
          } else {
            await tester.enterText(
              find.byKey(const Key('room-code-field')),
              _code,
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 250));
            await _tap(tester, const Key('join-room-button'));
            _answerRoom(
              rig.last,
              rig.lastRequestId('join_room'),
              _lobbyRoom(),
              seat: 1,
            );
            await _pumpBounded(tester, frames: 3);
            expect(
              rig.controllers.last.phase,
              RoomPhase.connected,
              reason: '$scenario: fixture: the guest lobby must connect',
            );
          }
          await _openOverLobby(tester, variant.over, scenario);

          final RoomController controller = rig.controllers.last;
          final int before = rig.transports.length;
          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump();
          expect(
            controller.phase,
            RoomPhase.closed,
            reason: '$scenario: fixture: the far side vanishing must close',
          );
          unawaited(controller.reconnect());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(
            rig.transports.length,
            before + 1,
            reason: '$scenario: fixture: reconnect must open a transport',
          );
          expect(rig.last.sentRaw.map(_typeOf).toList(), <String>[
            'resume',
          ], reason: '$scenario: fixture: reconnect must send one resume');
          final int leavesBefore = log.pageLeaves;

          _answerError(
            rig.last,
            _idOf(rig.last.sentRaw.single),
            'NO_SUCH_ROOM',
          );
          await _pumpBounded(tester, frames: 2);
          await _settleHome(tester, rig);

          _expectRouteAndSheetsGone(tester, log, scenario);
          final AppLocalizations loc = _loc(tester);
          _expectHomeNotice(
            tester,
            log,
            scenario,
            key: _roomClosedNoticeKey,
            expected: variant.host
                ? loc.homeRoomClosedHostNotice
                : loc.homeRoomClosedGuestNotice,
          );
          expect(
            log.pageLeaves - leavesBefore,
            1,
            reason:
                '$scenario: expected exactly one page route to leave (the '
                'lobby route); routes taken off: [${log.describe()}]. '
                '${_reproduce(scenario)}',
          );
        } finally {
          await _finish(tester, rig);
        }
      });
    }
  });

  // ---------------------------------------------------------------- D2
  group('D2.1 the lobby error is a card', () {
    for (final Locale locale in <Locale>[const Locale('en'), _ar]) {
      final TextDirection direction = locale == _ar
          ? TextDirection.rtl
          : TextDirection.ltr;
      final String tag = locale.languageCode;

      testWidgets(
        'D2.1a $tag: NO_SUCH_ROOM on a typed code: link_off icon, the text, '
        'the way out is the one ElevatedButton',
        (tester) async {
          const String base = 'D2.1a';
          final String id = '$base $tag';
          await _errorLobby(tester, errorCode: 'NO_SUCH_ROOM', locale: locale);
          try {
            final AppLocalizations loc = _locOfLobby(tester);
            expect(
              find.byKey(_errorKey),
              findsOneWidget,
              reason: '$id: expected lobby-error on screen. ${_reproduce(id)}',
            );
            expect(
              find.descendant(
                of: find.byKey(_errorKey),
                matching: find.byKey(_errorCardKey),
              ),
              findsOneWidget,
              reason:
                  '$id: expected lobby-error-card inside lobby-error. '
                  '${_reproduce(id)}',
            );
            expect(
              find.byKey(_retryKey),
              findsNothing,
              reason:
                  '$id: expected no Retry for NO_SUCH_ROOM. ${_reproduce(id)}',
            );
            _expectCard(
              tester,
              id: id,
              card: _errorCardKey,
              icon: Icons.link_off_rounded,
              text: loc.lobbyErrorNoSuchRoom,
              elevated: _leaveKey,
              outlined: null,
              leaveLabel: loc.lobbyBackToHomeButton,
              direction: direction,
            );
          } finally {
            await _unmount(tester);
          }
        },
      );

      testWidgets(
        'D2.1b $tag: NO_SUCH_ROOM on a room link: link_off icon, the link '
        'line, the way out is the one ElevatedButton',
        (tester) async {
          const String base = 'D2.1b';
          final String id = '$base $tag';
          await _errorLobby(
            tester,
            errorCode: 'NO_SUCH_ROOM',
            locale: locale,
            fromLink: true,
          );
          try {
            final AppLocalizations loc = _locOfLobby(tester);
            _expectCard(
              tester,
              id: id,
              card: _errorCardKey,
              icon: Icons.link_off_rounded,
              text: loc.lobbyErrorLinkRoomGone,
              elevated: _leaveKey,
              outlined: null,
              leaveLabel: loc.lobbyBackToHomeButton,
              direction: direction,
            );
          } finally {
            await _unmount(tester);
          }
        },
      );

      testWidgets(
        'D2.1c $tag: transport failure: wifi_off icon, Retry is the one '
        'ElevatedButton, the way out is an OutlinedButton under it',
        (tester) async {
          const String base = 'D2.1c';
          final String id = '$base $tag';
          await _errorLobby(
            tester,
            errorCode: null,
            locale: locale,
            connectFails: true,
          );
          try {
            final AppLocalizations loc = _locOfLobby(tester);
            _expectCard(
              tester,
              id: id,
              card: _errorCardKey,
              icon: Icons.wifi_off_rounded,
              text: loc.lobbyErrorTransport,
              elevated: _retryKey,
              outlined: _leaveKey,
              leaveLabel: loc.lobbyBackToHomeButton,
              direction: direction,
            );
          } finally {
            await _unmount(tester);
          }
        },
      );

      testWidgets(
        'D2.1d $tag: RATE_LIMITED (another code, Retry shown): info icon, '
        'Retry is the one ElevatedButton, the way out is an OutlinedButton',
        (tester) async {
          const String base = 'D2.1d';
          final String id = '$base $tag';
          await _errorLobby(tester, errorCode: 'RATE_LIMITED', locale: locale);
          try {
            final AppLocalizations loc = _locOfLobby(tester);
            _expectCard(
              tester,
              id: id,
              card: _errorCardKey,
              icon: Icons.info_outline_rounded,
              text: loc.lobbyErrorRateLimited,
              elevated: _retryKey,
              outlined: _leaveKey,
              leaveLabel: loc.lobbyBackToHomeButton,
              direction: direction,
            );
          } finally {
            await _unmount(tester);
          }
        },
      );

      testWidgets(
        'D2.1e $tag: ROOM_STARTED (another code, no Retry): info icon, the '
        'way out is the one ElevatedButton',
        (tester) async {
          const String base = 'D2.1e';
          final String id = '$base $tag';
          await _errorLobby(tester, errorCode: 'ROOM_STARTED', locale: locale);
          try {
            final AppLocalizations loc = _locOfLobby(tester);
            expect(
              find.byKey(_retryKey),
              findsNothing,
              reason:
                  '$id: expected no Retry for ROOM_STARTED. ${_reproduce(id)}',
            );
            _expectCard(
              tester,
              id: id,
              card: _errorCardKey,
              icon: Icons.info_outline_rounded,
              text: loc.lobbyErrorRoomStarted,
              elevated: _leaveKey,
              outlined: null,
              leaveLabel: loc.lobbyBackToHomeButton,
              direction: direction,
            );
          } finally {
            await _unmount(tester);
          }
        },
      );
    }
  });

  group('D2.3 the never-connected body is a card', () {
    for (final Locale locale in <Locale>[const Locale('en'), _ar]) {
      final TextDirection direction = locale == _ar
          ? TextDirection.rtl
          : TextDirection.ltr;
      final String tag = locale.languageCode;

      testWidgets(
        'D2.3a $tag: closed with no room: lobby-closed is the card, wifi_off '
        'icon, Reconnect is the one ElevatedButton, Leave an OutlinedButton',
        (tester) async {
          final String id = 'D2.3a $tag';
          final _Direct direct = await _closedLobby(tester, locale: locale);
          try {
            expect(
              direct.controller.room,
              isNull,
              reason: '$id: fixture: no room may be held',
            );
            expect(direct.controller.phase, RoomPhase.closed);
            final AppLocalizations loc = _locOfLobby(tester);
            _expectCard(
              tester,
              id: id,
              card: _closedKey,
              icon: Icons.wifi_off_rounded,
              text: loc.lobbyConnectionLost,
              elevated: _reconnectKey,
              outlined: _leaveKey,
              leaveLabel: loc.gameLeaveButton,
              direction: direction,
            );
            expect(
              find.byKey(_reconnectingKey),
              findsNothing,
              reason:
                  '$id: expected no reconnecting line while nothing is '
                  'pending. ${_reproduce(id)}',
            );
          } finally {
            await _unmount(tester);
          }
        },
      );

      testWidgets(
        'D2.3b $tag: closed with no room and a reconnect pending: the '
        'reconnecting line is in the card',
        (tester) async {
          final String id = 'D2.3b $tag';
          final _Direct direct = await _closedLobby(
            tester,
            locale: locale,
            pending: true,
          );
          try {
            expect(direct.controller.autoReconnectPending, isTrue);
            final AppLocalizations loc = _locOfLobby(tester);
            final Finder card = find.byKey(_closedKey);
            expect(
              card,
              findsOneWidget,
              reason: '$id: expected the card. ${_reproduce(id)}',
            );
            expect(
              tester.widget(card),
              isA<Material>(),
              reason:
                  '$id: expected lobby-closed to be a Material; it is a '
                  '${tester.widget(card).runtimeType}. ${_reproduce(id)}',
            );
            final Finder line = find.descendant(
              of: card,
              matching: find.byKey(_reconnectingKey),
            );
            expect(
              line,
              findsOneWidget,
              reason:
                  '$id: expected lobby-reconnecting inside the card. '
                  '${_reproduce(id)}',
            );
            expect(
              tester.widget<Text>(line).data,
              loc.lobbyReconnecting,
              reason: '$id: expected the reconnecting text. ${_reproduce(id)}',
            );
            expect(
              find.descendant(
                of: card,
                matching: find.byIcon(Icons.sync_rounded),
              ),
              findsOneWidget,
              reason:
                  '$id: expected the sync icon beside the line. '
                  '${_reproduce(id)}',
            );
            expect(
              find.descendant(
                of: card,
                matching: find.byIcon(Icons.wifi_off_rounded),
              ),
              findsOneWidget,
              reason: '$id: expected the wifi_off icon. ${_reproduce(id)}',
            );
            expect(
              Directionality.of(tester.element(line)),
              direction,
              reason: '$id: expected $direction around the line.',
            );
          } finally {
            await _unmount(tester);
          }
        },
      );
    }
  });

  // ---------------------------------------------------------------- D3
  group('D3 no stat tile shows 0', () {
    for (final Locale locale in <Locale>[const Locale('en'), _ar]) {
      final String tag = locale.languageCode;

      testWidgets('D3.1a $tag: loser, complete, rolls 3 and the rest 0: only '
          'rolls', (tester) async {
        final String id = 'D3.1a $tag';
        await _mountCard(
          tester,
          stats: _stats(rolls: 3),
          winner: false,
          locale: locale,
        );
        _expectTiles(tester, id: id, expected: <Key>[_statRollsKey]);
        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byKey(_statRollsKey)),
        );
        expect(
          find.descendant(
            of: find.byKey(_statRollsKey),
            matching: find.text(loc.endStatRolls(3)),
          ),
          findsOneWidget,
          reason: '$id: expected the rolls label unchanged. ${_reproduce(id)}',
        );
        expect(
          find.descendant(
            of: find.byKey(_statRollsKey),
            matching: find.text('3'),
          ),
          findsOneWidget,
          reason: '$id: expected the rolls value 3. ${_reproduce(id)}',
        );
      });

      testWidgets('D3.1b $tag: loser, complete, all four 0: no stat tile', (
        tester,
      ) async {
        final String id = 'D3.1b $tag';
        await _mountCard(
          tester,
          stats: _stats(),
          winner: false,
          locale: locale,
        );
        _expectTiles(tester, id: id, expected: <Key>[]);
      });

      testWidgets('D3.1c $tag: winner, complete, all four 0: no stat tile', (
        tester,
      ) async {
        final String id = 'D3.1c $tag';
        await _mountCard(tester, stats: _stats(), winner: true, locale: locale);
        _expectTiles(tester, id: id, expected: <Key>[]);
      });

      testWidgets('D3.2a $tag: incomplete stats, home 0: no stat tile', (
        tester,
      ) async {
        final String id = 'D3.2a $tag';
        await _mountCard(
          tester,
          stats: _stats(rolls: 50, sixes: 9, captures: 2, complete: false),
          winner: false,
          locale: locale,
        );
        _expectTiles(tester, id: id, expected: <Key>[]);
      });

      testWidgets('D3.2b $tag: incomplete stats, home 2: only home', (
        tester,
      ) async {
        final String id = 'D3.2b $tag';
        await _mountCard(
          tester,
          stats: _stats(
            rolls: 50,
            sixes: 9,
            captures: 2,
            home: 2,
            complete: false,
          ),
          winner: false,
          locale: locale,
        );
        _expectTiles(tester, id: id, expected: <Key>[_statHomeKey]);
        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byKey(_statHomeKey)),
        );
        expect(
          find.descendant(
            of: find.byKey(_statHomeKey),
            matching: find.text(loc.endStatHome(2)),
          ),
          findsOneWidget,
          reason: '$id: expected the home label unchanged. ${_reproduce(id)}',
        );
      });

      testWidgets('D3.3a $tag: winner, captures 0, the other three shown', (
        tester,
      ) async {
        final String id = 'D3.3a $tag';
        await _mountCard(
          tester,
          stats: _stats(rolls: 7, sixes: 2, home: 4),
          winner: true,
          locale: locale,
        );
        _expectTiles(
          tester,
          id: id,
          expected: <Key>[_statRollsKey, _statSixesKey, _statHomeKey],
        );
      });

      testWidgets('D3.4a $tag: all four non-zero, four tiles in order', (
        tester,
      ) async {
        final String id = 'D3.4a $tag';
        await _mountCard(
          tester,
          stats: _stats(rolls: 7, sixes: 2, captures: 1, home: 4),
          winner: true,
          locale: locale,
        );
        _expectTiles(tester, id: id, expected: _tileOrder);
        final List<double> xs = <double>[
          for (final Key key in _tileOrder)
            tester.getTopLeft(find.byKey(key)).dx,
        ];
        final bool inReadingOrder = locale == _ar
            ? xs[0] > xs[1] && xs[1] > xs[2] && xs[2] > xs[3]
            : xs[0] < xs[1] && xs[1] < xs[2] && xs[2] < xs[3];
        expect(
          inReadingOrder,
          isTrue,
          reason:
              '$id: expected the tiles rolls, sixes, captures, home in '
              'reading order for $tag; left edges $xs. ${_reproduce(id)}',
        );
      });
    }

    for (final ({String id, GameStats stats, Key only}) one in [
      (id: 'D3.5a', stats: _stats(sixes: 5), only: _statSixesKey),
      (id: 'D3.5b', stats: _stats(captures: 5), only: _statCapturesKey),
      (id: 'D3.5c', stats: _stats(home: 1), only: _statHomeKey),
    ]) {
      testWidgets(
        '${one.id}: a loser with only ${_keyName(one.only)} above 0 shows '
        'that tile and no other',
        (tester) async {
          await _mountCard(tester, stats: one.stats, winner: false);
          _expectTiles(tester, id: one.id, expected: <Key>[one.only]);
        },
      );
    }

    testWidgets(
      'D3.6: a stat tile never reads 0 on any card the contract names',
      (tester) async {
        const String id = 'D3.6';
        for (final bool winner in <bool>[true, false]) {
          for (final GameStats stats in <GameStats>[
            _stats(rolls: 3),
            _stats(rolls: 3, sixes: 1),
            _stats(rolls: 3, home: 2),
            _stats(rolls: 9, sixes: 2, captures: 1),
            _stats(rolls: 9, complete: false, home: 2),
          ]) {
            await _mountCard(tester, stats: stats, winner: winner);
            for (final Key key in _tilesOnCard()) {
              final Finder value = find.descendant(
                of: find.byKey(key),
                matching: find.text('0'),
              );
              expect(
                value,
                findsNothing,
                reason:
                    '$id: expected no 0 in ${_keyName(key)} on the '
                    '${winner ? 'winner' : 'loser'} card with rolls '
                    '${stats.rolls} sixes ${stats.sixes} captures '
                    '${stats.capturesMade} home ${stats.tokensHome} complete '
                    '${stats.complete}. ${_reproduce(id)}',
              );
            }
          }
        }
      },
    );

    for (final ({String id, bool winner, Key above}) side in [
      (id: 'D3.7a', winner: false, above: _loseLineKey),
      (id: 'D3.7b', winner: true, above: _winnerTitleKey),
    ]) {
      testWidgets(
        '${side.id}: with no tile left the row and the gap above it are not '
        'built on the ${side.winner ? 'winner' : 'loser'} card',
        (tester) async {
          final String id = side.id;
          await _mountCard(tester, stats: null, winner: side.winner);
          final double noStats = _gapToFairness(tester, side.above);

          await _mountCard(tester, stats: _stats(), winner: side.winner);
          final double allZero = _gapToFairness(tester, side.above);

          await _mountCard(
            tester,
            stats: _stats(rolls: 50, sixes: 9, captures: 2, complete: false),
            winner: side.winner,
          );
          final double incompleteHomeZero = _gapToFairness(tester, side.above);

          await _mountCard(
            tester,
            stats: _stats(rolls: 3),
            winner: side.winner,
          );
          final double oneTile = _gapToFairness(tester, side.above);

          expect(
            oneTile,
            greaterThan(noStats),
            reason:
                '$id: fixture: a card with a tile must be taller between the '
                'title and the fairness line than one with none ($oneTile '
                'vs $noStats). ${_reproduce(id)}',
          );
          expect(
            allZero,
            noStats,
            reason:
                '$id: expected the all-zero card to space the title and the '
                'fairness line exactly as a card with no stats ($noStats); '
                'saw $allZero. ${_reproduce(id)}',
          );
          expect(
            incompleteHomeZero,
            noStats,
            reason:
                '$id: expected the incomplete home-0 card to space the '
                'title and the fairness line exactly as a card with no '
                'stats ($noStats); saw $incompleteHomeZero. '
                '${_reproduce(id)}',
          );
        },
      );
    }
  });
}

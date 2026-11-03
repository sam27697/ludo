// Proof for contract C-547
// (work/ludo/orders/C-547-seat-moved-to-another-phone.md), written from the
// contract alone: a seat taken over by another phone says so, and nothing on
// this phone takes it back. The server sends an unsolicited `error`
// BAD_SEAT_TOKEN (no `re`) and closes with 4004 when a newer socket resumes
// the same seat; this phone must then say the true reason and offer no
// action that harms the phone that now holds the seat.
//
// Rigs, copied rather than imported so the files they came from stay
// untouched. The game route and Home (D2 game, D3, D4) use the rig
// test/c540_test.dart uses: the real HomeScreen, RoomRoute and GameScreen over
// a real RoomController on FakeTransport, a fresh transport per connect. The
// lobby bodies (D2 closed with no room, D2 stale-room overlay) use a real
// LobbyScreen pushed over a host page, as test/lobby_stale_room_test.dart
// does, so a pop of the lobby route is observable.
//
// The getter `RoomController.seatTakenOver` and the getter
// `AppLocalizations.seatMovedLine` do not exist on the tree this was written
// for, so neither is named here: the line is compared as the exact text the
// contract gives, and the controller is observed through what a screen and
// SessionMemory show of it. The controller's own cases (D1) name the getter
// and live in test/c547_controller_test.dart.
//
// Cases (a case whose id starts with "guard" is green on a tree without the
// contract on purpose: it pins what must not change):
//   D2.game.en/ar   GameScreen mid-game
//   D2.closed.en/ar LobbyScreen closed with no room held
//   D2.stale.en/ar  LobbyScreen stale-room overlay
//     each: the card shows the line and Icons.phonelink_rounded, no
//     lobbyConnectionLost text, no Reconnect Key, no reconnecting Key, one
//     filled Leave on the Leave Key, and Leave leaves the route without
//     opening another transport.
//   guard.game / guard.closed / guard.stale: a plain drop still draws
//     lobbyConnectionLost and the Reconnect button.
//   guard.game.code: an unsolicited error of another code is a plain drop.
//   D3.finished.en/ar, D3.rematch.en/ar: the takeover card in place of the
//     offline end card, no endOffline text, no Play again.
//   guard.finished: a plain drop on a FINISHED table still draws the
//     offline end card.
//   D4.clear, D4.once, D4.relaunch: Home clears the stored seat once, drops
//     Back to game, and a relaunch does not resume. guard.D4.drop: a plain
//     drop keeps the seat and a relaunch resumes it.
//   D5.en / D5.ar: the arb texts.
//
// There is no random input. Each failure reason names the case, what was
// expected and what was on the tree, and ends with the command that replays
// that one case:
//   flutter test test/c547_test.dart --plain-name '<id>'

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

// D5's exact texts, from the contract.
const String _enMoved = 'Your seat moved to another phone.';
const String _arMoved = 'انتقل مقعدك إلى هاتف آخر.';

const Key _gameCardKey = Key('game-screen-connection-lost');
const Key _gameReconnectKey = Key('game-screen-reconnect-button');
const Key _gameReconnectingKey = Key('game-screen-reconnecting');
const Key _gameErrorKey = Key('game-screen-error-message');
const Key _gameLeaveKey = Key('game-screen-leave-button');
const Key _lobbyCardKey = Key('lobby-closed');
const Key _lobbyReconnectKey = Key('lobby-reconnect-button');
const Key _lobbyReconnectingKey = Key('lobby-reconnecting');
// Amendment A1: the lobby takeover card's Leave has its own Key; the corner
// close keeps `lobby-leave-button`.
const Key _lobbyLeaveKey = Key('lobby-seat-moved-leave');
const Key _staleRoomKey = Key('lobby-stale-room');
const Key _rejoinKey = Key('home-rejoin-button');
const Key _rematchKey = Key('end-card-rematch');
const Key _offlineKey = Key('end-card-offline');
const Key _endWinKey = Key('end-card-win');
const Key _endLoseKey = Key('end-card-lose');
const Key _openLobbyKey = Key('c547-open-lobby');

const String _testUrl = 'wss://c547-test.invalid/ws';
const String _code = 'K7M2QP';
const String _token = 'tok-c547-001';
const String _gameId = '7f3a9c1e5b2d4068';
const String _verifyUrl = 'https://c547-test.invalid/v/7f3a9c1e5b2d4068';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';

const Locale _ar = Locale('ar');

String _reproduce(String id) =>
    'reproduce: flutter test test/c547_test.dart --plain-name "$id"';

String _why(String id, String expected, String saw) =>
    '$id: expected $expected; saw $saw. ${_reproduce(id)}';

// ---------------------------------------------------------------- frames

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c547-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

/// What the server sends before it closes a displaced socket with 4004: an
/// `error` with no `re`.
String _takeoverFrame([String code = 'BAD_SEAT_TOKEN']) => _frame(
  type: 'error',
  data: <String, Object?>{'code': code, 'message': 'taken over'},
);

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

/// Records every page route the navigator takes off its stack.
class _RouteLog extends NavigatorObserver {
  int pageLeaves = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) {
      pageLeaves += 1;
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) {
      pageLeaves += 1;
    }
  }
}

Widget _localized(
  Widget home, {
  Locale? locale,
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
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
    navigatorObservers: observers,
    home: home,
  );
}

Widget _app(RoomControllerFactory factory, {Locale? locale, _RouteLog? log}) {
  return _localized(
    HomeScreen(
      onToggleLocale: () {},
      controllerFactory: factory,
      initialLinkReader: noInitialLink,
      linkStream: noLinkStream,
    ),
    locale: locale,
    observers: <NavigatorObserver>[?log],
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

/// Lets the SharedPreferences futures a notification started complete.
Future<void> _flushPrefs(WidgetTester tester) async {
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
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

enum _Room { playing, finished, rematch }

/// Home resumes on its own from a fresh record and the server answers with
/// [room]: the game route is up and the controller is connected.
Future<void> _gameRoute(
  WidgetTester tester,
  _Rig rig,
  String id, {
  required _Room room,
}) async {
  expect(
    rig.sent('resume'),
    hasLength(1),
    reason: '$id: fixture: a fresh record resumes on its own',
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
    reason: '$id: fixture: a resume shows GameScreen',
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
      reason: '$id: fixture: the rematch ask must be on the room',
    );
    expect(
      rig.controllers.last.lastFinished,
      isNotNull,
      reason: '$id: fixture: a rematch LOBBY must hold lastFinished',
    );
  }
  expect(
    rig.controllers.last.phase,
    RoomPhase.connected,
    reason: '$id: fixture: the game route must be connected before the drop',
  );
}

// ------------------------------------------------------------ lobby rig

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has nothing queued; '
        'the scenario opened a transport it should not have',
      );
    }
    return _queue.removeAt(0);
  }
}

class _PopLog extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }
}

/// A create lobby pushed over a host page, on a controller of its own, so a
/// pop of the lobby route shows. [answered] true resolves create_room with a
/// two seat lobby (the room is held and the phase is connected); false leaves
/// it in flight (no room yet).
class _LobbyRig {
  _LobbyRig._(this.connector, this.transport, this.controller, this.pops);

  final _Connector connector;
  final FakeTransport transport;
  final RoomController controller;
  final _PopLog pops;

  static Future<_LobbyRig> open(
    WidgetTester tester,
    String id, {
    Locale? locale,
    required bool answered,
  }) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
    );
    final _PopLog pops = _PopLog();
    await tester.pumpWidget(
      _localized(
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: _openLobbyKey,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LobbyScreen(
                      controller: controller,
                      action: LobbyAction.create,
                      playerName: 'Sam',
                      players: 2,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        locale: locale,
        observers: <NavigatorObserver>[pops],
      ),
    );
    await tester.tap(find.byKey(_openLobbyKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      transport.sentRaw,
      isNotEmpty,
      reason: '$id: fixture: the pushed lobby must have sent create_room',
    );
    expect(_typeOf(transport.sentRaw.last), 'create_room');
    if (answered) {
      _answerRoom(
        transport,
        _idOf(transport.sentRaw.last),
        _lobbyRoom(),
        seat: 0,
      );
      await tester.pump();
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason: '$id: fixture: the create reply must land connected',
      );
    }
    return _LobbyRig._(connector, transport, controller, pops);
  }

  /// The player's own Leave while create_room is still unanswered closes the
  /// controller with no room held, the one way a lobby reaches
  /// RoomPhase.closed with room null. A takeover frame pushed before it is
  /// already on the controller, and leave() leaves it there.
  Future<void> closeWithNoRoom(WidgetTester tester, String id) async {
    final Future<void> left = controller.leave();
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await left;
    await tester.pump();
    expect(
      controller.room,
      isNull,
      reason: '$id: fixture: no room may be held',
    );
    expect(
      controller.phase,
      RoomPhase.closed,
      reason: '$id: fixture: the controller must be closed',
    );
  }

  Future<void> takeOver(WidgetTester tester) async {
    transport.pushText(_takeoverFrame());
    await tester.pump();
  }

  Future<void> drop(WidgetTester tester) async {
    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  }
}

// ------------------------------------------------------------- assertions

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

String _movedFor(Locale? locale) => locale == _ar ? _arMoved : _enMoved;

/// One line of what the screen is drawing, for every failure reason.
String _note(WidgetTester tester, RoomController? controller) {
  final AppLocalizations loc = _loc(tester);
  final String moved = _movedFor(Locale(loc.localeName));
  int keys(Key key) => find.byKey(key, skipOffstage: false).evaluate().length;
  int icon(IconData data) =>
      find.byIcon(data, skipOffstage: false).evaluate().length;
  return 'controller=${controller == null ? 'none' : '${controller.phase}/${controller.errorCode}'} '
      'game-card=${keys(_gameCardKey)} lobby-card=${keys(_lobbyCardKey)} '
      'game-reconnect=${keys(_gameReconnectKey)} '
      'lobby-reconnect=${keys(_lobbyReconnectKey)} '
      'reconnecting=${keys(_gameReconnectingKey) + keys(_lobbyReconnectingKey)} '
      'end-card-offline=${keys(_offlineKey)} end-card-rematch=${keys(_rematchKey)} '
      'phonelink-icon=${icon(Icons.phonelink_rounded)} '
      'wifi-off-icon=${icon(Icons.wifi_off_rounded)} '
      'text("$moved")=${find.text(moved, skipOffstage: false).evaluate().length} '
      'text("${loc.lobbyConnectionLost}")='
      '${find.text(loc.lobbyConnectionLost, skipOffstage: false).evaluate().length} '
      'GameScreen=${find.byType(GameScreen, skipOffstage: false).evaluate().length} '
      'LobbyScreen=${find.byType(LobbyScreen, skipOffstage: false).evaluate().length}';
}

/// D2 for one card: the line, the icon, none of the connection-lost card's
/// parts, one filled Leave on the card's own Leave Key.
void _expectTakeoverCard(
  WidgetTester tester,
  String id,
  RoomController? controller, {
  required Key cardKey,
  required Key reconnectKey,
  required Key reconnectingKey,
  required Key leaveKey,
  Key? errorKey,
  Locale? locale,
}) {
  final AppLocalizations loc = _loc(tester);
  final String moved = _movedFor(locale);
  expect(
    loc.localeName,
    (locale ?? const Locale('en')).languageCode,
    reason: '$id: fixture: the tree must be in the locale under test',
  );
  final String saw = _note(tester, controller);
  final Finder card = find.byKey(cardKey);
  expect(
    card,
    findsOneWidget,
    reason: _why(id, 'the card on ${cardKey.toString()}', saw),
  );
  expect(
    tester.widget(card),
    isA<Material>(),
    reason: _why(id, 'the same card shape, a Material on the card Key', saw),
  );
  expect(
    find.descendant(of: card, matching: find.text(moved)),
    findsOneWidget,
    reason: _why(id, 'the card to read "$moved"', saw),
  );
  expect(
    find.descendant(of: card, matching: find.byIcon(Icons.phonelink_rounded)),
    findsOneWidget,
    reason: _why(id, 'Icons.phonelink_rounded on the card', saw),
  );
  expect(
    find.descendant(of: card, matching: find.byIcon(Icons.wifi_off_rounded)),
    findsNothing,
    reason: _why(id, 'no wifi-off icon on the takeover card', saw),
  );
  expect(
    find.text(loc.lobbyConnectionLost, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no "${loc.lobbyConnectionLost}" text anywhere', saw),
  );
  expect(
    find.text(loc.lobbyReconnecting, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no "${loc.lobbyReconnecting}" text anywhere', saw),
  );
  expect(
    find.byKey(reconnectKey, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no Reconnect button (${reconnectKey.toString()})', saw),
  );
  expect(
    find.byKey(reconnectingKey, skipOffstage: false),
    findsNothing,
    reason: _why(
      id,
      'no reconnecting row (${reconnectingKey.toString()})',
      saw,
    ),
  );
  expect(
    find.descendant(of: card, matching: find.byType(CircularProgressIndicator)),
    findsNothing,
    reason: _why(id, 'no spinner on the takeover card', saw),
  );
  if (errorKey != null) {
    expect(
      find.byKey(errorKey, skipOffstage: false),
      findsNothing,
      reason: _why(id, 'no error line (${errorKey.toString()})', saw),
    );
  }
  final Finder leave = find.descendant(
    of: card,
    matching: find.byKey(leaveKey),
  );
  expect(
    leave,
    findsOneWidget,
    reason: _why(
      id,
      'the Leave button ${leaveKey.toString()} on the card',
      saw,
    ),
  );
  expect(
    tester.widget(leave),
    isA<ElevatedButton>(),
    reason: _why(
      id,
      'Leave as a filled ElevatedButton, found '
      '${tester.widget(leave).runtimeType}',
      saw,
    ),
  );
  expect(
    find.descendant(of: leave, matching: find.text(loc.gameLeaveButton)),
    findsOneWidget,
    reason: _why(id, 'the Leave button to read "${loc.gameLeaveButton}"', saw),
  );
  expect(
    find.descendant(of: card, matching: find.byType(ElevatedButton)),
    findsOneWidget,
    reason: _why(id, 'Leave as the only action on the card', saw),
  );
  expect(
    find.descendant(of: card, matching: find.byType(OutlinedButton)),
    findsNothing,
    reason: _why(id, 'no second action on the card', saw),
  );
  expect(
    leave.hitTestable(),
    findsOneWidget,
    reason: _why(id, 'Leave to be tappable', saw),
  );
}

/// The unchanged plain card: the connection-lost line, the wifi icon, a
/// Reconnect that taps, no takeover line.
void _expectPlainCard(
  WidgetTester tester,
  String id,
  RoomController? controller, {
  required Key cardKey,
  required Key reconnectKey,
}) {
  final AppLocalizations loc = _loc(tester);
  final String saw = _note(tester, controller);
  final Finder card = find.byKey(cardKey);
  expect(
    card,
    findsOneWidget,
    reason: _why(id, 'the connection-lost card ${cardKey.toString()}', saw),
  );
  expect(
    find.descendant(of: card, matching: find.text(loc.lobbyConnectionLost)),
    findsOneWidget,
    reason: _why(id, 'the card to read "${loc.lobbyConnectionLost}"', saw),
  );
  expect(
    find.descendant(of: card, matching: find.byIcon(Icons.wifi_off_rounded)),
    findsOneWidget,
    reason: _why(id, 'the wifi-off icon on the card', saw),
  );
  expect(
    find.byIcon(Icons.phonelink_rounded, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no takeover icon for a plain drop', saw),
  );
  expect(
    find.text(_enMoved, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no takeover line for a plain drop', saw),
  );
  expect(
    find.byKey(reconnectKey).hitTestable(),
    findsOneWidget,
    reason: _why(id, 'Reconnect (${reconnectKey.toString()}) to tap', saw),
  );
}

/// Game route gone, Home current, no card left, and no transport opened
/// since [transportsBefore]: Leave never reaches the other phone's seat.
void _expectLeftGame(
  WidgetTester tester,
  String id,
  _Rig rig,
  _RouteLog log, {
  required int transportsBefore,
  required int leavesBefore,
}) {
  final String saw = _note(tester, rig.controllers.last);
  expect(
    find.byType(GameScreen, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'the game route gone after Leave', saw),
  );
  expect(
    _homeIsCurrent(tester),
    isTrue,
    reason: _why(id, 'Home to be the current route after Leave', saw),
  );
  expect(
    log.pageLeaves - leavesBefore,
    1,
    reason: _why(
      id,
      'exactly one page route to leave, as the existing Leave does',
      '${log.pageLeaves - leavesBefore}; $saw',
    ),
  );
  expect(
    rig.transports.length,
    transportsBefore,
    reason: _why(
      id,
      'no transport opened by Leave (a resume would take the seat back)',
      '${rig.transports.length - transportsBefore} new; $saw',
    ),
  );
  expect(
    rig.sent('resume'),
    hasLength(1),
    reason: _why(
      id,
      'only the one resume Home sent at launch',
      '${rig.sent('resume').length} resumes; $saw',
    ),
  );
}

Future<void> _tapLeaveOnCard(
  WidgetTester tester,
  Key cardKey,
  Key leaveKey,
) async {
  final Finder leave = find.descendant(
    of: find.byKey(cardKey),
    matching: find.byKey(leaveKey),
  );
  await tester.ensureVisible(leave);
  await tester.tap(leave);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Home retires the controller it owns after the route returns. Nothing is
/// waiting on the wire here (the socket is closed), so bounded pumps do.
Future<void> _settleHome(WidgetTester tester) async {
  for (int i = 0; i < 30; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _takeOverGame(WidgetTester tester, _Rig rig) async {
  rig.last.pushText(_takeoverFrame());
  await tester.pump();
  rig.last.endFromFarSide();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _dropGame(WidgetTester tester, _Rig rig) async {
  rig.last.endFromFarSide();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

// ----------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- D2
  group('D2 the takeover card replaces the connection-lost card', () {
    for (final Locale? locale in <Locale?>[null, _ar]) {
      final String tag = locale == null ? 'en' : 'ar';

      testWidgets(
        'D2.game.$tag: GameScreen mid-game, the takeover card with Leave; '
        'Leave leaves the route and opens no transport',
        (tester) async {
          final String id = 'D2.game.$tag';
          _seedFreshSeat();
          final _Rig rig = _Rig();
          final _RouteLog log = _RouteLog();
          await _mount(tester, rig, log, locale: locale);
          try {
            await _gameRoute(tester, rig, id, room: _Room.playing);
            await _takeOverGame(tester, rig);
            expect(
              rig.controllers.last.phase,
              RoomPhase.closed,
              reason: '$id: fixture: the close must end the connection',
            );
            _expectTakeoverCard(
              tester,
              id,
              rig.controllers.last,
              cardKey: _gameCardKey,
              reconnectKey: _gameReconnectKey,
              reconnectingKey: _gameReconnectingKey,
              leaveKey: _gameLeaveKey,
              errorKey: _gameErrorKey,
              locale: locale,
            );
            final int transportsBefore = rig.transports.length;
            final int leavesBefore = log.pageLeaves;
            await _tapLeaveOnCard(tester, _gameCardKey, _gameLeaveKey);
            await _settleHome(tester);
            _expectLeftGame(
              tester,
              id,
              rig,
              log,
              transportsBefore: transportsBefore,
              leavesBefore: leavesBefore,
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );

      testWidgets(
        'D2.closed.$tag: LobbyScreen closed with no room, the takeover card '
        'with Leave; Leave pops the lobby route',
        (tester) async {
          final String id = 'D2.closed.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: locale,
            answered: false,
          );
          try {
            await lobby.takeOver(tester);
            await lobby.closeWithNoRoom(tester, id);
            _expectTakeoverCard(
              tester,
              id,
              lobby.controller,
              cardKey: _lobbyCardKey,
              reconnectKey: _lobbyReconnectKey,
              reconnectingKey: _lobbyReconnectingKey,
              leaveKey: _lobbyLeaveKey,
              locale: locale,
            );
            await _tapLeaveOnCard(tester, _lobbyCardKey, _lobbyLeaveKey);
            expect(
              lobby.pops.popCount,
              1,
              reason: _why(
                id,
                'Leave to pop the lobby route once',
                '${lobby.pops.popCount} pops; ${_note(tester, lobby.controller)}',
              ),
            );
            expect(
              find.byType(LobbyScreen),
              findsNothing,
              reason: _why(id, 'LobbyScreen gone after Leave', 'still there'),
            );
            expect(
              lobby.connector.calls.length,
              1,
              reason: _why(
                id,
                'no transport opened after the first',
                '${lobby.connector.calls.length} connects',
              ),
            );
          } finally {
            await lobby.finish(tester);
          }
        },
      );

      testWidgets(
        'D2.stale.$tag: LobbyScreen stale-room overlay, the takeover card '
        'with Leave over the dimmed room; Leave pops the lobby route',
        (tester) async {
          final String id = 'D2.stale.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: locale,
            answered: true,
          );
          try {
            await lobby.takeOver(tester);
            await lobby.drop(tester);
            expect(
              lobby.controller.phase,
              RoomPhase.closed,
              reason: '$id: fixture: the close must end the connection',
            );
            expect(
              find.byKey(_staleRoomKey),
              findsOneWidget,
              reason: '$id: fixture: the held room stays under the card',
            );
            _expectTakeoverCard(
              tester,
              id,
              lobby.controller,
              cardKey: _lobbyCardKey,
              reconnectKey: _lobbyReconnectKey,
              reconnectingKey: _lobbyReconnectingKey,
              leaveKey: _lobbyLeaveKey,
              locale: locale,
            );
            expect(
              find.byKey(const Key('lobby-leave-button')),
              findsOneWidget,
              reason: _why(
                id,
                'the header corner close alone on lobby-leave-button '
                '(one widget per Key)',
                _note(tester, lobby.controller),
              ),
            );
            await _tapLeaveOnCard(tester, _lobbyCardKey, _lobbyLeaveKey);
            expect(
              lobby.pops.popCount,
              1,
              reason: _why(
                id,
                'Leave to pop the lobby route once',
                '${lobby.pops.popCount} pops; ${_note(tester, lobby.controller)}',
              ),
            );
            expect(
              find.byType(LobbyScreen),
              findsNothing,
              reason: _why(id, 'LobbyScreen gone after Leave', 'still there'),
            );
            expect(
              lobby.connector.calls.length,
              1,
              reason: _why(
                id,
                'no transport opened after the first',
                '${lobby.connector.calls.length} connects',
              ),
            );
          } finally {
            await lobby.finish(tester);
          }
        },
      );
    }

    testWidgets(
      'guard.game: a plain drop mid-game still draws lobbyConnectionLost and '
      'the Reconnect button',
      (tester) async {
        const String id = 'guard.game';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, id, room: _Room.playing);
          await _dropGame(tester, rig);
          _expectPlainCard(
            tester,
            id,
            rig.controllers.last,
            cardKey: _gameCardKey,
            reconnectKey: _gameReconnectKey,
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'guard.game.code: an unsolicited error of another code before the '
      'close is a plain drop, not a takeover',
      (tester) async {
        const String id = 'guard.game.code';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, id, room: _Room.playing);
          rig.last.pushText(_takeoverFrame('RATE_LIMITED'));
          await tester.pump();
          await _dropGame(tester, rig);
          _expectPlainCard(
            tester,
            id,
            rig.controllers.last,
            cardKey: _gameCardKey,
            reconnectKey: _gameReconnectKey,
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets('guard.closed: a plain close with no room held still draws '
        'lobbyConnectionLost and the Reconnect button', (tester) async {
      const String id = 'guard.closed';
      final _LobbyRig lobby = await _LobbyRig.open(tester, id, answered: false);
      try {
        await lobby.closeWithNoRoom(tester, id);
        _expectPlainCard(
          tester,
          id,
          lobby.controller,
          cardKey: _lobbyCardKey,
          reconnectKey: _lobbyReconnectKey,
        );
      } finally {
        await lobby.finish(tester);
      }
    });

    testWidgets('guard.stale: a plain drop with a room held still draws '
        'lobbyConnectionLost over the dimmed room', (tester) async {
      const String id = 'guard.stale';
      final _LobbyRig lobby = await _LobbyRig.open(tester, id, answered: true);
      try {
        await lobby.drop(tester);
        expect(
          lobby.controller.phase,
          RoomPhase.closed,
          reason: '$id: fixture: the drop must close the phase',
        );
        // No automatic delays on this controller: the Reconnect button is
        // up at once.
        _expectPlainCard(
          tester,
          id,
          lobby.controller,
          cardKey: _lobbyCardKey,
          reconnectKey: _lobbyReconnectKey,
        );
        expect(find.byKey(_staleRoomKey), findsOneWidget);
      } finally {
        await lobby.finish(tester);
      }
    });
  });

  // ---------------------------------------------------------------- D3
  group('D3 a finished table shows the takeover card, not the offline end '
      'card', () {
    for (final ({String id, Locale? locale, _Room room}) variant in [
      (id: 'D3.finished.en', locale: null, room: _Room.finished),
      (id: 'D3.finished.ar', locale: _ar, room: _Room.finished),
      (id: 'D3.rematch.en', locale: null, room: _Room.rematch),
      (id: 'D3.rematch.ar', locale: _ar, room: _Room.rematch),
    ]) {
      testWidgets('${variant.id}: ${variant.room.name} table '
          '(lastFinished set), after the takeover: the takeover card, no '
          'endOffline text, no Play again', (tester) async {
        final String id = variant.id;
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log, locale: variant.locale);
        try {
          await _gameRoute(tester, rig, id, room: variant.room);
          await _takeOverGame(tester, rig);
          final RoomController controller = rig.controllers.last;
          _expectTakeoverCard(
            tester,
            id,
            controller,
            cardKey: _gameCardKey,
            reconnectKey: _gameReconnectKey,
            reconnectingKey: _gameReconnectingKey,
            leaveKey: _gameLeaveKey,
            errorKey: _gameErrorKey,
            locale: variant.locale,
          );
          final AppLocalizations loc = _loc(tester);
          final String saw = _note(tester, controller);
          expect(
            find.text(loc.endOffline, skipOffstage: false),
            findsNothing,
            reason: _why(id, 'no "${loc.endOffline}" text', saw),
          );
          expect(
            find.byKey(_offlineKey, skipOffstage: false),
            findsNothing,
            reason: _why(id, 'no offline end card line', saw),
          );
          expect(
            find.byKey(_rematchKey).hitTestable(),
            findsNothing,
            reason: _why(id, 'no Play again that taps through', saw),
          );
          for (final Key endKey in <Key>[_endWinKey, _endLoseKey]) {
            expect(
              find.byKey(endKey, skipOffstage: false),
              findsNothing,
              reason: _why(
                id,
                'the takeover card in place of the end card '
                '(${endKey.toString()})',
                saw,
              ),
            );
          }
          expect(
            rig.sent('rematch'),
            isEmpty,
            reason: _why(id, 'no rematch sent', saw),
          );
        } finally {
          await _finish(tester, rig);
        }
      });
    }

    testWidgets(
      'guard.finished: a plain drop on a FINISHED table still draws the '
      'offline end card with Play again',
      (tester) async {
        const String id = 'guard.finished';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, id, room: _Room.finished);
          await _dropGame(tester, rig);
          final AppLocalizations loc = _loc(tester);
          final String saw = _note(tester, rig.controllers.last);
          expect(
            find.text(loc.endOffline),
            findsOneWidget,
            reason: _why(id, 'the "${loc.endOffline}" line', saw),
          );
          expect(
            find.byKey(_rematchKey).hitTestable(),
            findsOneWidget,
            reason: _why(id, 'Play again to tap', saw),
          );
          expect(
            find.byKey(_gameCardKey, skipOffstage: false),
            findsNothing,
            reason: _why(id, 'no connection-lost card on the end card', saw),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );
  });

  // ---------------------------------------------------------------- D4
  group('D4 Home drops the stored seat the moment it is taken over', () {
    Future<SeatRecord?> storedSeat(WidgetTester tester) async {
      await _flushPrefs(tester);
      final SessionMemory memory = await SessionMemory.load();
      return memory.seatRecord;
    }

    const SeatRecord held = SeatRecord(code: _code, seat: 0, seatToken: _token);

    testWidgets('D4.clear: the takeover clears session.seat and Home offers no Back '
        'to game for it', (tester) async {
      const String id = 'D4.clear';
      _seedFreshSeat();
      final _Rig rig = _Rig();
      final _RouteLog log = _RouteLog();
      await _mount(tester, rig, log);
      try {
        await _gameRoute(tester, rig, id, room: _Room.playing);
        expect(
          await storedSeat(tester),
          held,
          reason: '$id: fixture: the seat is stored while it is held',
        );
        expect(
          find.byKey(_rejoinKey, skipOffstage: false),
          findsOneWidget,
          reason: '$id: fixture: Home holds Back to game under the route',
        );

        rig.last.pushText(_takeoverFrame());
        await tester.pump();
        final SeatRecord? afterFrame = await storedSeat(tester);
        expect(
          afterFrame,
          isNull,
          reason: _why(
            id,
            'session.seat cleared at the takeover frame',
            'still stored $afterFrame; ${_note(tester, rig.controllers.last)}',
          ),
        );
        expect(
          find.byKey(_rejoinKey, skipOffstage: false),
          findsNothing,
          reason: _why(
            id,
            'no Back to game for the seat that moved',
            _note(tester, rig.controllers.last),
          ),
        );

        rig.last.endFromFarSide();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          await storedSeat(tester),
          isNull,
          reason: _why(
            id,
            'session.seat still cleared after the close',
            'stored again',
          ),
        );

        await _tapLeaveOnCard(tester, _gameCardKey, _gameLeaveKey);
        await _settleHome(tester);
        expect(
          _homeIsCurrent(tester),
          isTrue,
          reason: _why(
            id,
            'Home current after Leave',
            _note(tester, rig.controllers.last),
          ),
        );
        expect(
          find.byKey(_rejoinKey),
          findsNothing,
          reason: _why(
            id,
            'Home offers no Back to game after Leave',
            _note(tester, rig.controllers.last),
          ),
        );
      } finally {
        await _finish(tester, rig);
      }
    });

    testWidgets(
      'D4.once: the clear happens at the takeover frame, not again at the '
      'close',
      (tester) async {
        const String id = 'D4.once';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, id, room: _Room.playing);
          rig.last.pushText(_takeoverFrame());
          await tester.pump();
          expect(
            await storedSeat(tester),
            isNull,
            reason: _why(
              id,
              'session.seat cleared at the takeover frame',
              'still stored; ${_note(tester, rig.controllers.last)}',
            ),
          );

          // A record written after the clear (another table this player
          // joined) must outlive the close of the displaced socket.
          const SeatRecord later = SeatRecord(
            code: 'ZY98XW',
            seat: 1,
            seatToken: 'tok-c547-later',
          );
          await tester.runAsync(() => SessionMemory.recordSeat(later));
          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            await storedSeat(tester),
            later,
            reason: _why(
              id,
              'the clear to run once, at the takeover frame',
              'the later record was cleared by the close',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets('D4.relaunch: after the takeover a relaunch of this phone does not '
        'resume the seat', (tester) async {
      const String id = 'D4.relaunch';
      _seedFreshSeat();
      final _Rig first = _Rig();
      final _RouteLog log = _RouteLog();
      await _mount(tester, first, log);
      await _gameRoute(tester, first, id, room: _Room.playing);
      await _takeOverGame(tester, first);
      await _flushPrefs(tester);
      await _finish(tester, first);

      final _Rig second = _Rig();
      final _RouteLog log2 = _RouteLog();
      await _mount(tester, second, log2);
      try {
        await _flushPrefs(tester);
        await _pumpBounded(tester);
        expect(
          second.transports,
          isEmpty,
          reason: _why(
            id,
            'no connection on relaunch',
            '${second.transports.length} transports, sent '
                '${<String>[for (final FakeTransport t in second.transports) ...t.sentRaw.map(_typeOf)]}',
          ),
        );
        expect(
          find.byKey(_rejoinKey, skipOffstage: false),
          findsNothing,
          reason: _why(id, 'no Back to game on relaunch', _note(tester, null)),
        );
        expect(
          find.byType(GameScreen, skipOffstage: false),
          findsNothing,
          reason: _why(id, 'no game route on relaunch', _note(tester, null)),
        );
      } finally {
        await _finish(tester, second);
      }
    });

    testWidgets(
      'guard.D4.drop: a plain drop keeps the stored seat, Back to game '
      'stays, and a relaunch resumes it',
      (tester) async {
        const String id = 'guard.D4.drop';
        _seedFreshSeat();
        final _Rig first = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, first, log);
        await _gameRoute(tester, first, id, room: _Room.playing);
        await _dropGame(tester, first);
        expect(
          await storedSeat(tester),
          held,
          reason: _why(id, 'the seat kept after a plain drop', 'cleared'),
        );
        expect(
          find.byKey(_rejoinKey, skipOffstage: false),
          findsOneWidget,
          reason: _why(id, 'Back to game kept after a plain drop', 'gone'),
        );
        await _finish(tester, first);

        final _Rig second = _Rig();
        final _RouteLog log2 = _RouteLog();
        await _mount(tester, second, log2);
        try {
          await _flushPrefs(tester);
          await _pumpBounded(tester);
          expect(
            second.sent('resume'),
            hasLength(1),
            reason: _why(
              id,
              'a relaunch to resume the kept seat',
              '${second.sent('resume').length} resumes',
            ),
          );
        } finally {
          await _finish(tester, second);
        }
      },
    );
  });

  // ---------------------------------------------------------------- D5
  group('D5 the line in both locales', () {
    Map<String, Object?> arb(String name) =>
        jsonDecode(File('lib/l10n/$name.arb').readAsStringSync())
            as Map<String, Object?>;

    test('D5.en: app_en.arb carries seatMovedLine and its description', () {
      final Map<String, Object?> file = arb('app_en');
      expect(
        file['seatMovedLine'],
        _enMoved,
        reason:
            'D5.en: expected app_en.arb seatMovedLine "$_enMoved"; saw '
            '${file['seatMovedLine']}. ${_reproduce('D5.en')}',
      );
      final Object? meta = file['@seatMovedLine'];
      expect(
        meta is Map<String, Object?> &&
            meta['description'] is String &&
            (meta['description']! as String).trim().isNotEmpty,
        isTrue,
        reason:
            'D5.en: expected an @seatMovedLine description in app_en.arb in '
            'the style of its neighbours; saw $meta. ${_reproduce('D5.en')}',
      );
    });

    test('D5.ar: app_ar.arb carries seatMovedLine', () {
      final Map<String, Object?> file = arb('app_ar');
      expect(
        file['seatMovedLine'],
        _arMoved,
        reason:
            'D5.ar: expected app_ar.arb seatMovedLine "$_arMoved"; saw '
            '${file['seatMovedLine']}. ${_reproduce('D5.ar')}',
      );
    });
  });
}

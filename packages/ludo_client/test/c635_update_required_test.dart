// Proof for contract C-635 (work/ludo/orders/634-update-required.md, order
// 635t), docs/PROTOCOL.md section 27 rules 1 and 6: an app too old for the
// server is told so, once, and is not asked to try again. The server sends an
// unsolicited `error` UPDATE_REQUIRED (no `re`) and closes with 4005; this
// phone must then say the true reason on every screen it can be on, offer one
// tap to its Google Play page and one quiet way home, and open no further
// connection.
//
// The getter `RoomController.updateRequired`, the widget `UpdateRequiredView`
// with its `UpdateLauncher`, and the four ARB keys do not exist on the tree
// this was written for, so this file does not compile there, by design. The
// strings are compared as the exact text the contract gives, never through the
// generated getters, so a wrong ARB value fails here by its text.
//
// Rigs, copied rather than imported so the files they came from stay
// untouched. The controller cases use a real RoomController over
// FakeTransport behind a connector double (test/c547_controller_test.dart).
// The screens use the real HomeScreen, RoomRoute, LobbyScreen and GameScreen
// over a real RoomController on FakeTransport, a fresh transport per connect
// (test/c547_test.dart). The view is also mounted on its own.
//
// Cases (a case whose id starts with "guard" is green on a tree without the
// contract on purpose: it pins what must not change):
//   C1      the frame sets updateRequired, notifies once at the frame, before
//           the close; phase and the other flags are left alone
//   C2      an unsolicited error of any other code (case, padding, number,
//           missing) does not set it; a missing or odd min_build still does
//   C3      an error with `re`, however addressed, does not set it
//   C4      no automatic reconnect follows, for every kAutoReconnectDelays
//           entry and well past them; guard.C4 shows a plain drop does start one
//   C5      reconnect(), resync() and onAppResumed() do nothing once set
//   C6      it stays true: replay, another frame, leave(), dispose()
//   C7      the frame before a room is held, and the frame and the close in
//           one burst
//   V1..V5  UpdateRequiredView on its own: strings, keys, icon, direction,
//           the market: then https: launch order, home, 48 dp at 2.0 text
//   S.*     the screens, in en and ar: lobby connecting for a create, lobby
//           seated, game PLAYING, finished table, finished table with a
//           rematch asked; the view replaces the card, the home button
//           leaves the way the corner close does
//   S.both  seatTakenOver and updateRequired together, in both orders
//   S.reply an UPDATE_REQUIRED reply (re set) draws no update view
//   K.*     Home keeps the stored seat and the recent codes; a relaunch
//           resumes the same seat
//   A1      the four ARB keys and their descriptions
//
// There is no random input. Each failure reason names the case, what was
// expected and what was on the tree, and ends with the command that replays
// that one case:
//   flutter test test/c635_update_required_test.dart --plain-name '<id>'

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
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
import 'package:ludo_client/src/update_required_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

// The exact texts, from the contract's table.
const String _enTitle = 'Update to keep playing';
const String _enBody =
    'This table needs the newest Ludo RNG. Update it on Google Play, then '
    'open the same link or code again.';
const String _enStore = 'Update on Google Play';
const String _enHome = 'Back to home';
const String _arTitle = 'حدّث اللعبة لتكمل اللعب';
const String _arBody =
    'هذه الطاولة تحتاج أحدث نسخة من Ludo RNG. حدّثها من Google Play، ثم افتح '
    'الرابط أو الرمز نفسه مرة أخرى.';
const String _arStore = 'حدّث من Google Play';
const String _arHome = 'العودة إلى الشاشة الرئيسية';

// The two pages the primary action asks for, in this order.
const String _marketUrl = 'market://details?id=app.fayad.ludo';
const String _httpsUrl =
    'https://play.google.com/store/apps/details?id=app.fayad.ludo';

// The seat-moved line of contract C-547, which this one must outrank.
const String _enMoved = 'Your seat moved to another phone.';
const String _arMoved = 'انتقل مقعدك إلى هاتف آخر.';

const Key _viewKey = Key('update-required-view');
const Key _storeKey = Key('update-required-store-button');
const Key _homeKey = Key('update-required-home-button');

const Key _gameCardKey = Key('game-screen-connection-lost');
const Key _gameReconnectKey = Key('game-screen-reconnect-button');
const Key _gameReconnectingKey = Key('game-screen-reconnecting');
const Key _lobbyCardKey = Key('lobby-closed');
const Key _lobbyReconnectKey = Key('lobby-reconnect-button');
const Key _lobbyReconnectingKey = Key('lobby-reconnecting');
const Key _staleRoomKey = Key('lobby-stale-room');
const Key _rejoinKey = Key('home-rejoin-button');
const Key _rematchKey = Key('end-card-rematch');
const Key _offlineKey = Key('end-card-offline');
const Key _endWinKey = Key('end-card-win');
const Key _endLoseKey = Key('end-card-lose');
const Key _openLobbyKey = Key('c635-open-lobby');

const String _testUrl = 'wss://c635-test.invalid/ws';
const String _code = 'K7M2QP';
const String _token = 'tok-c635-001';
const String _gameId = '7f3a9c1e5b2d4068';
const String _verifyUrl = 'https://c635-test.invalid/v/7f3a9c1e5b2d4068';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';
const String _codesPrefsKey = 'session.recentCodes';
const List<String> _recentCodes = <String>['ZY98XW', 'AB23CD'];

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

String _reproduce(String id) =>
    'reproduce: flutter test test/c635_update_required_test.dart '
    '--plain-name "$id"';

String _why(String id, String expected, String saw) =>
    '$id: expected $expected; saw $saw. ${_reproduce(id)}';

// ---------------------------------------------------------------- frames

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c635-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

/// What the server sends before it closes with 4005: an `error` with no `re`
/// (docs/PROTOCOL.md section 27 rule 4).
String _updateFrame({
  Object? code = 'UPDATE_REQUIRED',
  Object? minBuild = 600,
  bool withMinBuild = true,
  String? re,
}) => _frame(
  type: 'error',
  re: re,
  data: <String, Object?>{
    'code': ?code,
    'message': 'x',
    if (withMinBuild) 'min_build': minBuild,
  },
);

String _takeoverFrame() => _frame(
  type: 'error',
  data: <String, Object?>{'code': 'BAD_SEAT_TOKEN', 'message': 'taken over'},
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

// ------------------------------------------------------- controller rig

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has nothing queued; '
        'the controller opened a transport the scenario did not expect',
      );
    }
    return _queue.removeAt(0);
  }
}

/// A controller that holds a PLAYING room as seat 0, connected, over
/// [transport]. [connector] has nothing queued unless the case enqueues it.
class _Table {
  _Table(this.controller, this.transport, this.connector);

  final RoomController controller;
  final FakeTransport transport;
  final _Connector connector;

  bool _disposed = false;

  void dispose() {
    if (!_disposed) {
      _disposed = true;
      controller.dispose();
    }
  }

  /// How many notifications the controller sent while updateRequired was
  /// already true, since the last [resetNotes].
  int notesWhileRequired = 0;
  int notesTotal = 0;

  void resetNotes() {
    notesWhileRequired = 0;
    notesTotal = 0;
  }

  static Future<_Table> connect(
    WidgetTester tester,
    String id, {
    List<Duration> delays = const <Duration>[],
  }) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
      autoReconnectDelays: delays,
    );
    final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': _token},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(transport.sentRaw.last),
        data: _playingRoom(),
      ),
    );
    await created;
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: '$id: fixture: the create reply must land connected',
    );
    final _Table table = _Table(controller, transport, connector);
    addTearDown(table.dispose);
    controller.addListener(() {
      table.notesTotal += 1;
      if (controller.updateRequired) {
        table.notesWhileRequired += 1;
      }
    });
    return table;
  }

  Future<void> push(WidgetTester tester, String text) async {
    transport.pushText(text);
    await tester.pump();
  }

  Future<void> drop(WidgetTester tester) async {
    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();
  }
}

void _expectRequired(
  RoomController controller,
  String id,
  bool expected,
  String when,
) {
  expect(
    controller.updateRequired,
    expected,
    reason:
        '$id: expected updateRequired $expected $when; saw '
        '${controller.updateRequired} (phase ${controller.phase}, errorCode '
        '${controller.errorCode}). ${_reproduce(id)}',
  );
}

void _expectConnects(_Table table, String id, int expected, String when) {
  expect(
    table.connector.calls.length,
    expected,
    reason:
        '$id: expected $expected connect(s) $when (the one the table '
        'opened, nothing after); saw ${table.connector.calls.length}. '
        '${_reproduce(id)}',
  );
}

// ------------------------------------------------------------- app rig

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

class _PopLog extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }
}

Widget _localized(
  Widget home, {
  Locale? locale,
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
  double textScale = 1.0,
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
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
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

/// Seeds a fresh seat record so Home resumes on its own at mount, and the
/// recent codes Home must never clear.
void _seedFreshSeat() {
  SharedPreferences.setMockInitialValues(<String, Object>{
    _seatPrefsKey: <String>[_code, '0', _token],
    _savedAtPrefsKey: DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
    _codesPrefsKey: _recentCodes,
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
    reason: '$id: fixture: the game route must be connected before the frame',
  );
}

/// A create lobby pushed over a host page, on a controller of its own, so a
/// pop of the lobby route shows. [answered] true resolves create_room with a
/// two seat lobby; false leaves it in flight (the lobby is connecting).
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
    double textScale = 1.0,
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
        textScale: textScale,
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

  Future<void> push(WidgetTester tester, String text) async {
    transport.pushText(text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
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

({String title, String body, String store, String home, String moved})
_textsFor(Locale locale) => locale == _ar
    ? (
        title: _arTitle,
        body: _arBody,
        store: _arStore,
        home: _arHome,
        moved: _arMoved,
      )
    : (
        title: _enTitle,
        body: _enBody,
        store: _enStore,
        home: _enHome,
        moved: _enMoved,
      );

/// One line of what the screen is drawing, for every failure reason.
String _note(WidgetTester tester, RoomController? controller) {
  int keys(Key key) => find.byKey(key, skipOffstage: false).evaluate().length;
  int icon(IconData data) =>
      find.byIcon(data, skipOffstage: false).evaluate().length;
  return 'controller=${controller == null ? 'none' : '${controller.phase}/${controller.errorCode}'} '
      'update-view=${keys(_viewKey)} store=${keys(_storeKey)} '
      'home=${keys(_homeKey)} game-card=${keys(_gameCardKey)} '
      'lobby-card=${keys(_lobbyCardKey)} '
      'game-reconnect=${keys(_gameReconnectKey)} '
      'lobby-reconnect=${keys(_lobbyReconnectKey)} '
      'end-card-offline=${keys(_offlineKey)} end-card-rematch=${keys(_rematchKey)} '
      'system-update-icon=${icon(Icons.system_update_rounded)} '
      'phonelink-icon=${icon(Icons.phonelink_rounded)} '
      'wifi-off-icon=${icon(Icons.wifi_off_rounded)} '
      'GameScreen=${find.byType(GameScreen, skipOffstage: false).evaluate().length} '
      'LobbyScreen=${find.byType(LobbyScreen, skipOffstage: false).evaluate().length}';
}

void _expectTapTarget(WidgetTester tester, String id, Key key, String saw) {
  final Finder finder = find.byKey(key);
  final Size size = tester.getSize(finder);
  expect(
    size.width >= 48 && size.height >= 48,
    isTrue,
    reason: _why(
      id,
      'the control ${key.toString()} to be at least 48 x 48 dp',
      '${size.width} x ${size.height}; $saw',
    ),
  );
}

/// The view as the contract draws it: the card, the icon, the four texts of
/// [locale], the direction, two tap targets of 48 dp or more, and nothing of
/// the cards it replaces.
void _expectUpdateView(
  WidgetTester tester,
  String id,
  RoomController? controller, {
  required Locale locale,
}) {
  final String saw = _note(tester, controller);
  final texts = _textsFor(locale);
  final Finder view = find.byKey(_viewKey);
  expect(
    view,
    findsOneWidget,
    reason: _why(id, 'one update-required-view', saw),
  );
  for (final (String label, String text) in <(String, String)>[
    ('title', texts.title),
    ('body', texts.body),
    ('store button text', texts.store),
    ('home button text', texts.home),
  ]) {
    expect(
      find.descendant(of: view, matching: find.text(text)),
      findsOneWidget,
      reason: _why(id, 'the $label "$text" once inside the view', saw),
    );
  }
  expect(
    find.descendant(
      of: view,
      matching: find.byIcon(Icons.system_update_rounded),
    ),
    findsOneWidget,
    reason: _why(id, 'Icons.system_update_rounded once on the card', saw),
  );
  expect(
    Directionality.of(tester.element(view)),
    locale == _ar ? TextDirection.rtl : TextDirection.ltr,
    reason: _why(
      id,
      'Directionality ${locale == _ar ? 'rtl' : 'ltr'} for ${locale.languageCode}',
      saw,
    ),
  );
  expect(
    find.descendant(of: view, matching: find.byKey(_storeKey)),
    findsOneWidget,
    reason: _why(id, 'the store button inside the view', saw),
  );
  expect(
    find.descendant(of: view, matching: find.byKey(_homeKey)),
    findsOneWidget,
    reason: _why(id, 'the home button inside the view', saw),
  );
  expect(
    find.byKey(_storeKey).hitTestable(),
    findsOneWidget,
    reason: _why(id, 'the store button to be tappable', saw),
  );
  expect(
    find.byKey(_homeKey).hitTestable(),
    findsOneWidget,
    reason: _why(id, 'the home button to be tappable', saw),
  );
  _expectTapTarget(tester, id, _storeKey, saw);
  _expectTapTarget(tester, id, _homeKey, saw);
  expect(
    find.textContaining('600', skipOffstage: false),
    findsNothing,
    reason: _why(id, 'min_build never shown to the player', saw),
  );
  // None of the cards the view replaces, none of their actions.
  final AppLocalizations loc = AppLocalizations.of(tester.element(view));
  expect(
    loc.localeName,
    locale.languageCode,
    reason: '$id: fixture: the tree must be in the locale under test',
  );
  for (final Key gone in <Key>[
    _gameCardKey,
    _gameReconnectKey,
    _gameReconnectingKey,
    _lobbyCardKey,
    _lobbyReconnectKey,
    _lobbyReconnectingKey,
    _offlineKey,
    _rematchKey,
    _endWinKey,
    _endLoseKey,
  ]) {
    expect(
      find.byKey(gone, skipOffstage: false),
      findsNothing,
      reason: _why(id, '${gone.toString()} replaced by the view', saw),
    );
  }
  for (final String text in <String>[
    loc.lobbyConnectionLost,
    loc.lobbyReconnecting,
    _enMoved,
    _arMoved,
  ]) {
    expect(
      find.text(text, skipOffstage: false),
      findsNothing,
      reason: _why(id, 'no "$text" next to the view', saw),
    );
  }
  expect(
    find.byIcon(Icons.phonelink_rounded, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no seat-moved icon next to the view', saw),
  );
  expect(
    find.byIcon(Icons.wifi_off_rounded, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no wifi-off icon next to the view', saw),
  );
}

void _expectNoUpdateView(WidgetTester tester, String id, String when) {
  expect(
    find.byKey(_viewKey, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no update-required-view $when', _note(tester, null)),
  );
}

/// Starts [call] without waiting for it: a controller that wrongly opens a
/// connection would wait ten seconds of fake time for a reply, and a test that
/// awaited it would hang instead of failing with its reason.
Future<void> _poke(WidgetTester tester, Future<void> call) async {
  unawaited(call);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
}

Future<void> _tapHome(WidgetTester tester) async {
  final Finder home = find.byKey(_homeKey);
  await tester.ensureVisible(home);
  await tester.tap(home);
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

// ----------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- C1
  group('C controller', () {
    testWidgets(
      'C1.a: an unsolicited UPDATE_REQUIRED sets updateRequired, once '
      'notified, at the frame and before the close',
      (tester) async {
        const String id = 'C1.a';
        final _Table table = await _Table.connect(tester, id);
        _expectRequired(table.controller, id, false, 'on a healthy connection');
        table.resetNotes();
        await table.push(tester, _updateFrame());
        _expectRequired(table.controller, id, true, 'at the frame');
        expect(
          table.notesWhileRequired,
          1,
          reason:
              '$id: expected exactly one notification with updateRequired '
              'true at the frame; saw ${table.notesWhileRequired} (of '
              '${table.notesTotal} in all). ${_reproduce(id)}',
        );
        expect(
          table.controller.phase,
          RoomPhase.connected,
          reason:
              '$id: fixture: the frame alone does not end the connection; '
              'phase was ${table.controller.phase}. ${_reproduce(id)}',
        );
        await table.drop(tester);
        _expectRequired(table.controller, id, true, 'after the close');
        expect(
          table.controller.phase,
          RoomPhase.closed,
          reason:
              '$id: expected phase closed after the close; saw '
              '${table.controller.phase}. ${_reproduce(id)}',
        );
      },
    );

    testWidgets(
      'C1.b: updateRequired leaves seatTakenOver false, and a takeover '
      'leaves updateRequired false',
      (tester) async {
        const String id = 'C1.b';
        final _Table table = await _Table.connect(tester, id);
        await table.push(tester, _updateFrame());
        expect(
          table.controller.seatTakenOver,
          isFalse,
          reason:
              '$id: expected seatTakenOver false after UPDATE_REQUIRED; saw '
              '${table.controller.seatTakenOver}. ${_reproduce(id)}',
        );
        final _Table other = await _Table.connect(tester, id);
        await other.push(tester, _takeoverFrame());
        _expectRequired(
          other.controller,
          id,
          false,
          'after an unsolicited BAD_SEAT_TOKEN',
        );
      },
    );

    for (final ({String name, Object? code}) other
        in <({String name, Object? code})>[
          (name: 'RATE_LIMITED', code: 'RATE_LIMITED'),
          (name: 'BAD_SEAT_TOKEN', code: 'BAD_SEAT_TOKEN'),
          (name: 'lower case', code: 'update_required'),
          (name: 'trailing space', code: 'UPDATE_REQUIRED '),
          (name: 'a prefix', code: 'UPDATE_REQUIRED_SOON'),
          (name: 'empty', code: ''),
          (name: 'a number', code: 4005),
          (name: 'no code at all', code: null),
        ]) {
      testWidgets(
        'C2.a (${other.name}): an unsolicited error that is not exactly '
        'UPDATE_REQUIRED does not set updateRequired',
        (tester) async {
          final String id = 'C2.a ${other.name}';
          final _Table table = await _Table.connect(tester, id);
          await table.push(tester, _updateFrame(code: other.code));
          _expectRequired(table.controller, id, false, 'after the frame');
          await table.drop(tester);
          _expectRequired(table.controller, id, false, 'after the close');
        },
      );
    }

    for (final ({String name, bool present, Object? value}) row
        in <({String name, bool present, Object? value})>[
          (name: 'min_build absent', present: false, value: null),
          (name: 'min_build null', present: true, value: null),
          (name: 'min_build a string', present: true, value: 'six hundred'),
          (name: 'min_build zero', present: true, value: 0),
          (name: 'min_build huge', present: true, value: 999999999),
        ]) {
      testWidgets(
        'C2.b (${row.name}): the code alone decides, min_build is never '
        'needed',
        (tester) async {
          final String id = 'C2.b ${row.name}';
          final _Table table = await _Table.connect(tester, id);
          await table.push(
            tester,
            _updateFrame(withMinBuild: row.present, minBuild: row.value),
          );
          _expectRequired(table.controller, id, true, 'after the frame');
        },
      );
    }

    testWidgets(
      'C3.a: an error reply (re set to a request in flight) with code '
      'UPDATE_REQUIRED does not set updateRequired',
      (tester) async {
        const String id = 'C3.a reply';
        final _Table table = await _Table.connect(tester, id);
        unawaited(table.controller.roll());
        await tester.pump();
        final String rollId = _idOf(table.transport.sentRaw.last);
        expect(_typeOf(table.transport.sentRaw.last), 'roll');
        await table.push(tester, _updateFrame(re: rollId));
        await tester.pump();
        _expectRequired(table.controller, id, false, 'after the error reply');
        await table.drop(tester);
        _expectRequired(table.controller, id, false, 'after the close');
      },
    );

    testWidgets(
      'C3.b: an error naming a request nobody sent (re set, unknown id) is '
      'not unsolicited, so it does not set updateRequired',
      (tester) async {
        const String id = 'C3.b unknown re';
        final _Table table = await _Table.connect(tester, id);
        await table.push(tester, _updateFrame(re: 'no-such-request'));
        _expectRequired(table.controller, id, false, 'after the frame');
        await table.drop(tester);
        _expectRequired(table.controller, id, false, 'after the close');
      },
    );

    testWidgets(
      'C4: no automatic reconnect follows, for every kAutoReconnectDelays '
      'entry and well past them',
      (tester) async {
        const String id = 'C4';
        final _Table table = await _Table.connect(
          tester,
          id,
          delays: kAutoReconnectDelays,
        );
        for (int i = 0; i < kAutoReconnectDelays.length + 1; i += 1) {
          table.connector.enqueue(FakeTransport());
        }
        await table.push(tester, _updateFrame());
        await table.drop(tester);
        _expectRequired(table.controller, id, true, 'after the close');
        expect(
          table.controller.autoReconnectPending,
          isFalse,
          reason:
              '$id: expected no scheduled reconnect after UPDATE_REQUIRED; '
              'one is pending. ${_reproduce(id)}',
        );
        for (final Duration delay in kAutoReconnectDelays) {
          await tester.pump(delay);
          await tester.runAsync(() => pumpEventQueue());
        }
        await tester.pump(const Duration(minutes: 5));
        await tester.runAsync(() => pumpEventQueue());
        _expectConnects(table, id, 1, 'after every delay and five minutes');
        expect(
          table.controller.phase,
          RoomPhase.closed,
          reason:
              '$id: expected phase to stay closed; saw '
              '${table.controller.phase}. ${_reproduce(id)}',
        );
        _expectRequired(table.controller, id, true, 'after the retry window');
      },
    );

    testWidgets('guard.C4: a plain drop on the same controller does start the '
        'automatic retry, so the probe above can see one', (tester) async {
      const String id = 'guard.C4';
      final _Table table = await _Table.connect(
        tester,
        id,
        delays: kAutoReconnectDelays,
      );
      await table.drop(tester);
      _expectRequired(table.controller, id, false, 'after a plain drop');
      expect(
        table.controller.autoReconnectPending,
        isTrue,
        reason:
            '$id: expected a scheduled reconnect after a plain drop; none '
            'is pending. ${_reproduce(id)}',
      );
      table.dispose();
    });

    testWidgets(
      'C5.a: reconnect() after the close does nothing, however often it is '
      'called',
      (tester) async {
        const String id = 'C5.a';
        final _Table table = await _Table.connect(tester, id);
        final FakeTransport spare = FakeTransport();
        table.connector.enqueue(spare);
        await table.push(tester, _updateFrame());
        await table.drop(tester);
        for (int i = 0; i < 3; i += 1) {
          await _poke(tester, table.controller.reconnect());
          await tester.runAsync(() => pumpEventQueue());
          await tester.pump();
        }
        _expectConnects(table, id, 1, 'after three reconnect() calls');
        expect(
          spare.sentRaw,
          isEmpty,
          reason:
              '$id: expected nothing sent on a transport reconnect() must '
              'not open; saw ${spare.sentRaw}. ${_reproduce(id)}',
        );
        expect(
          table.controller.phase,
          RoomPhase.closed,
          reason:
              '$id: expected phase closed; saw ${table.controller.phase}. '
              '${_reproduce(id)}',
        );
        await tester.pump(const Duration(seconds: 11));
        _expectRequired(table.controller, id, true, 'after reconnect()');
      },
    );

    testWidgets(
      'C5.b: reconnect() right after the frame, with the link still up and '
      'then dropped, does nothing',
      (tester) async {
        const String id = 'C5.b';
        final _Table table = await _Table.connect(tester, id);
        table.connector.enqueue(FakeTransport());
        await table.push(tester, _updateFrame());
        await _poke(tester, table.controller.reconnect());
        await table.drop(tester);
        await _poke(tester, table.controller.reconnect());
        await tester.runAsync(() => pumpEventQueue());
        _expectConnects(table, id, 1, 'around the close');
        await tester.pump(const Duration(seconds: 11));
        _expectRequired(table.controller, id, true, 'after reconnect()');
      },
    );

    testWidgets('C5.c: resync() and onAppResumed() open no connection either', (
      tester,
    ) async {
      const String id = 'C5.c';
      final _Table table = await _Table.connect(
        tester,
        id,
        delays: kAutoReconnectDelays,
      );
      table.connector.enqueue(FakeTransport());
      await table.push(tester, _updateFrame());
      await table.drop(tester);
      await _poke(tester, table.controller.resync());
      table.controller.onAppResumed();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump(const Duration(seconds: 30));
      _expectConnects(table, id, 1, 'after resync() and onAppResumed()');
      _expectRequired(table.controller, id, true, 'after both');
    });

    testWidgets(
      'C5.d: reconnectAndRematch() after the frame sends no rematch and opens '
      'no connection, with the link up and after the close',
      (tester) async {
        const String id = 'C5.d';
        final _Table table = await _Table.connect(
          tester,
          id,
          delays: kAutoReconnectDelays,
        );
        table.connector.enqueue(FakeTransport());
        await table.push(tester, _updateFrame());
        final int sentBefore = table.transport.sentRaw.length;
        await _poke(tester, table.controller.reconnectAndRematch());
        expect(
          table.transport.sentRaw.length,
          sentBefore,
          reason:
              '$id: expected nothing sent by reconnectAndRematch() while the '
              'refused link is still up; saw '
              '${table.transport.sentRaw.skip(sentBefore).toList()}. '
              '${_reproduce(id)}',
        );
        _expectConnects(table, id, 1, 'after reconnectAndRematch(), link up');
        await table.drop(tester);
        await _poke(tester, table.controller.reconnectAndRematch());
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump(const Duration(minutes: 1));
        _expectConnects(table, id, 1, 'after reconnectAndRematch(), closed');
        expect(
          table.transport.sentRaw.length,
          sentBefore,
          reason:
              '$id: expected nothing sent once the link closed; saw '
              '${table.transport.sentRaw.skip(sentBefore).toList()}. '
              '${_reproduce(id)}',
        );
        _expectRequired(table.controller, id, true, 'after both calls');
      },
    );

    testWidgets(
      'C6.a: the same frame replayed, then the close, is still one refusal '
      'and still no reconnect',
      (tester) async {
        const String id = 'C6.a';
        final _Table table = await _Table.connect(
          tester,
          id,
          delays: kAutoReconnectDelays,
        );
        table.connector.enqueue(FakeTransport());
        await table.push(tester, _updateFrame());
        await table.push(tester, _updateFrame());
        _expectRequired(table.controller, id, true, 'after the replay');
        await table.drop(tester);
        await tester.pump(const Duration(minutes: 5));
        await tester.runAsync(() => pumpEventQueue());
        _expectRequired(table.controller, id, true, 'after the close');
        _expectConnects(table, id, 1, 'after the replay and the close');
      },
    );

    testWidgets('C6.b: another unsolicited error after it does not clear it', (
      tester,
    ) async {
      const String id = 'C6.b';
      final _Table table = await _Table.connect(tester, id);
      await table.push(tester, _updateFrame());
      await table.push(tester, _updateFrame(code: 'RATE_LIMITED'));
      await table.push(tester, _updateFrame(code: null));
      _expectRequired(
        table.controller,
        id,
        true,
        'after later unsolicited errors',
      );
    });

    testWidgets('C6.c: leave() leaves updateRequired as it is', (tester) async {
      const String id = 'C6.c leave';
      final _Table table = await _Table.connect(tester, id);
      await table.push(tester, _updateFrame());
      final Future<void> left = table.controller.leave();
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      await left;
      _expectRequired(table.controller, id, true, 'after leave()');
    });

    testWidgets('C6.d: dispose() leaves updateRequired as it is', (
      tester,
    ) async {
      const String id = 'C6.d dispose';
      final _Table table = await _Table.connect(tester, id);
      await table.push(tester, _updateFrame());
      table.dispose();
      _expectRequired(table.controller, id, true, 'after dispose()');
    });

    testWidgets(
      'C7.a: the frame before any room is held (a create still in flight) '
      'sets updateRequired',
      (tester) async {
        const String id = 'C7.a no room';
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        addTearDown(controller.dispose);
        unawaited(controller.createRoom(name: 'Sam', players: 2));
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        expect(
          controller.room,
          isNull,
          reason: '$id: fixture: no room may be held yet',
        );
        transport.pushText(_updateFrame());
        await tester.pump();
        _expectRequired(controller, id, true, 'before any room is held');
        // Let the create time out so no timer outlives the case.
        await tester.pump(const Duration(seconds: 11));
      },
    );

    testWidgets(
      'C7.b: the frame and the close in one burst, with no pump between '
      'them, still leave no retry pending',
      (tester) async {
        const String id = 'C7.b burst';
        final _Table table = await _Table.connect(
          tester,
          id,
          delays: kAutoReconnectDelays,
        );
        table.connector.enqueue(FakeTransport());
        table.transport.pushText(_updateFrame());
        table.transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        _expectRequired(table.controller, id, true, 'after the burst');
        expect(
          table.controller.autoReconnectPending,
          isFalse,
          reason:
              '$id: expected no scheduled reconnect after the burst; one is '
              'pending. ${_reproduce(id)}',
        );
        await tester.pump(const Duration(minutes: 5));
        await tester.runAsync(() => pumpEventQueue());
        _expectConnects(table, id, 1, 'after the burst and five minutes');
      },
    );
  });

  // ---------------------------------------------------------------- V
  group('V the view on its own', () {
    Future<void> mountView(
      WidgetTester tester, {
      required Locale locale,
      required VoidCallback onHome,
      UpdateLauncher? launcher,
      double textScale = 1.0,
      Size? surface,
    }) async {
      if (surface != null) {
        tester.view.physicalSize = surface;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      await tester.pumpWidget(
        _localized(
          Scaffold(
            body: UpdateRequiredView(onHome: onHome, launcher: launcher),
          ),
          locale: locale,
          textScale: textScale,
        ),
      );
      await tester.pump();
    }

    for (final Locale locale in <Locale>[_en, _ar]) {
      testWidgets(
        'V1.${locale.languageCode}: the card, the icon, the four texts, '
        'the direction and two 48 dp targets',
        (tester) async {
          final String id = 'V1.${locale.languageCode}';
          await mountView(tester, locale: locale, onHome: () {});
          _expectUpdateView(tester, id, null, locale: locale);
          expect(
            find.descendant(
              of: find.byKey(_viewKey),
              matching: find.byWidgetPredicate(
                (Widget w) => w is ButtonStyleButton,
              ),
            ),
            findsNWidgets(2),
            reason: _why(
              id,
              'two buttons on the card, the store one and the home one',
              _note(tester, null),
            ),
          );
        },
      );
    }

    testWidgets('V2: the store button asks for the market: page and, when that '
        'succeeds, for nothing more', (tester) async {
      const String id = 'V2';
      final List<Uri> asked = <Uri>[];
      int homes = 0;
      await mountView(
        tester,
        locale: _en,
        onHome: () => homes += 1,
        launcher: (Uri url) async {
          asked.add(url);
          return true;
        },
      );
      await tester.tap(find.byKey(_storeKey));
      await tester.pump();
      await tester.pump();
      expect(
        <String>[for (final Uri u in asked) u.toString()],
        <String>[_marketUrl],
        reason: _why(id, 'one launch of $_marketUrl', '$asked'),
      );
      expect(
        homes,
        0,
        reason: _why(id, 'onHome untouched by the store button', '$homes'),
      );
    });

    testWidgets(
      'V3: when the market: launch returns false the https: page is asked '
      'for, once',
      (tester) async {
        const String id = 'V3';
        final List<Uri> asked = <Uri>[];
        await mountView(
          tester,
          locale: _en,
          onHome: () {},
          launcher: (Uri url) async {
            asked.add(url);
            return asked.length > 1;
          },
        );
        await tester.tap(find.byKey(_storeKey));
        await tester.pump();
        await tester.pump();
        expect(
          <String>[for (final Uri u in asked) u.toString()],
          <String>[_marketUrl, _httpsUrl],
          reason: _why(id, 'market: then https:', '$asked'),
        );
      },
    );

    testWidgets(
      'V4.a: when the market: launch throws (asynchronously) the https: page '
      'is asked for',
      (tester) async {
        const String id = 'V4.a';
        final List<Uri> asked = <Uri>[];
        await mountView(
          tester,
          locale: _en,
          onHome: () {},
          launcher: (Uri url) async {
            asked.add(url);
            if (asked.length == 1) {
              throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
            }
            return true;
          },
        );
        await tester.tap(find.byKey(_storeKey));
        await tester.pump();
        await tester.pump();
        expect(
          <String>[for (final Uri u in asked) u.toString()],
          <String>[_marketUrl, _httpsUrl],
          reason: _why(id, 'market: then https:', '$asked'),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: _why(id, 'no error to escape the tap', 'one did'),
        );
      },
    );

    testWidgets(
      'V4.b: when the market: launch throws before it returns a future the '
      'https: page is asked for',
      (tester) async {
        const String id = 'V4.b';
        final List<Uri> asked = <Uri>[];
        await mountView(
          tester,
          locale: _en,
          onHome: () {},
          launcher: (Uri url) {
            asked.add(url);
            if (asked.length == 1) {
              throw StateError('no handler for market:');
            }
            return Future<bool>.value(true);
          },
        );
        await tester.tap(find.byKey(_storeKey));
        await tester.pump();
        await tester.pump();
        expect(
          <String>[for (final Uri u in asked) u.toString()],
          <String>[_marketUrl, _httpsUrl],
          reason: _why(id, 'market: then https:', '$asked'),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: _why(id, 'no error to escape the tap', 'one did'),
        );
      },
    );

    testWidgets(
      'V4.c: when both launches return false there are exactly two asks and '
      'no error',
      (tester) async {
        const String id = 'V4.c';
        final List<Uri> asked = <Uri>[];
        await mountView(
          tester,
          locale: _en,
          onHome: () {},
          launcher: (Uri url) async {
            asked.add(url);
            return false;
          },
        );
        await tester.tap(find.byKey(_storeKey));
        await tester.pump();
        await tester.pump();
        expect(
          <String>[for (final Uri u in asked) u.toString()],
          <String>[_marketUrl, _httpsUrl],
          reason: _why(id, 'market: then https: and no third ask', '$asked'),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: _why(id, 'no error to escape the tap', 'one did'),
        );
        _expectUpdateView(tester, id, null, locale: _en);
      },
    );

    testWidgets(
      'V4.d: when both launches throw there are exactly two asks and the '
      'tap does not crash the app',
      (tester) async {
        const String id = 'V4.d';
        final List<Uri> asked = <Uri>[];
        await mountView(
          tester,
          locale: _en,
          onHome: () {},
          launcher: (Uri url) async {
            asked.add(url);
            throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
          },
        );
        await tester.tap(find.byKey(_storeKey));
        await tester.pump();
        await tester.pump();
        expect(
          <String>[for (final Uri u in asked) u.toString()],
          <String>[_marketUrl, _httpsUrl],
          reason: _why(id, 'market: then https: and no third ask', '$asked'),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: _why(
            id,
            'no error to escape the tap when nothing can open a store page',
            'one did',
          ),
        );
      },
    );

    testWidgets(
      'V4.e: the https: ask waits for the market: ask to settle, it is '
      'never made alongside it',
      (tester) async {
        const String id = 'V4.e';
        final List<Uri> asked = <Uri>[];
        final Completer<bool> first = Completer<bool>();
        await mountView(
          tester,
          locale: _en,
          onHome: () {},
          launcher: (Uri url) {
            asked.add(url);
            return asked.length == 1 ? first.future : Future<bool>.value(true);
          },
        );
        await tester.tap(find.byKey(_storeKey));
        await tester.pump();
        await tester.pump();
        expect(
          <String>[for (final Uri u in asked) u.toString()],
          <String>[_marketUrl],
          reason: _why(
            id,
            'only the market: ask while it is unsettled',
            '$asked',
          ),
        );
        first.complete(false);
        await tester.pump();
        await tester.pump();
        expect(
          <String>[for (final Uri u in asked) u.toString()],
          <String>[_marketUrl, _httpsUrl],
          reason: _why(id, 'https: once market: settled false', '$asked'),
        );
      },
    );

    testWidgets(
      'V5.a: the home button calls onHome once and asks for no page',
      (tester) async {
        const String id = 'V5.a';
        final List<Uri> asked = <Uri>[];
        int homes = 0;
        await mountView(
          tester,
          locale: _en,
          onHome: () => homes += 1,
          launcher: (Uri url) async {
            asked.add(url);
            return true;
          },
        );
        await tester.tap(find.byKey(_homeKey));
        await tester.pump();
        expect(
          homes,
          1,
          reason: _why(id, 'onHome called once', '$homes calls'),
        );
        expect(
          asked,
          isEmpty,
          reason: _why(id, 'no store page for the home button', '$asked'),
        );
      },
    );

    for (final Locale locale in <Locale>[_en, _ar]) {
      testWidgets(
        'V5.b.${locale.languageCode}: at text scale 2.0 on a 320 x 480 '
        'surface nothing overflows, both buttons are reachable by scrolling '
        'and stay 48 dp',
        (tester) async {
          final String id = 'V5.b.${locale.languageCode}';
          int homes = 0;
          await mountView(
            tester,
            locale: locale,
            onHome: () => homes += 1,
            launcher: (Uri url) async => true,
            textScale: 2.0,
            surface: const Size(320, 480),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: _why(id, 'no overflow at text scale 2.0', 'one was thrown'),
          );
          await tester.ensureVisible(find.byKey(_storeKey));
          await tester.pump();
          _expectTapTarget(tester, id, _storeKey, _note(tester, null));
          await tester.ensureVisible(find.byKey(_homeKey));
          await tester.pump();
          _expectTapTarget(tester, id, _homeKey, _note(tester, null));
          await tester.tap(find.byKey(_homeKey));
          await tester.pump();
          expect(
            homes,
            1,
            reason: _why(
              id,
              'the scrolled-to home button to call onHome once',
              '$homes calls',
            ),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: _why(id, 'no error after scrolling', 'one was thrown'),
          );
        },
      );
    }
  });

  // ---------------------------------------------------------------- S
  group('S the screens', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String tag = locale.languageCode;
      final Locale? appLocale = locale == _en ? null : locale;

      testWidgets(
        'S.lobby.connecting.$tag: a lobby still connecting for a create '
        'shows the view at the frame and after the close; home pops the '
        'route and opens no transport',
        (tester) async {
          final String id = 'S.lobby.connecting.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: appLocale,
            answered: false,
          );
          try {
            expect(lobby.controller.room, isNull);
            await lobby.push(tester, _updateFrame());
            _expectUpdateView(
              tester,
              '$id (frame)',
              lobby.controller,
              locale: locale,
            );
            await lobby.drop(tester);
            await tester.pump(const Duration(seconds: 11));
            _expectUpdateView(
              tester,
              '$id (close)',
              lobby.controller,
              locale: locale,
            );
            expect(
              lobby.controller.updateRequired,
              isTrue,
              reason: _why(
                id,
                'updateRequired true on the lobby controller',
                '${lobby.controller.updateRequired}',
              ),
            );
            await _tapHome(tester);
            expect(
              lobby.pops.popCount,
              1,
              reason: _why(
                id,
                'home to pop the lobby route once',
                '${lobby.pops.popCount} pops; ${_note(tester, lobby.controller)}',
              ),
            );
            expect(
              find.byType(LobbyScreen),
              findsNothing,
              reason: _why(id, 'LobbyScreen gone after home', 'still there'),
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
        'S.lobby.seated.$tag: a lobby seated in LOBBY shows the view over '
        'the held room, at the frame and after the close; home pops the '
        'route',
        (tester) async {
          final String id = 'S.lobby.seated.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: appLocale,
            answered: true,
          );
          try {
            await lobby.push(tester, _updateFrame());
            _expectUpdateView(
              tester,
              '$id (frame)',
              lobby.controller,
              locale: locale,
            );
            await lobby.drop(tester);
            expect(
              lobby.controller.phase,
              RoomPhase.closed,
              reason: '$id: fixture: the close must end the connection',
            );
            _expectUpdateView(
              tester,
              '$id (close)',
              lobby.controller,
              locale: locale,
            );
            expect(
              lobby.controller.room,
              isNotNull,
              reason: '$id: fixture: the room is still held',
            );
            await _tapHome(tester);
            expect(
              lobby.pops.popCount,
              1,
              reason: _why(
                id,
                'home to pop the lobby route once',
                '${lobby.pops.popCount} pops; ${_note(tester, lobby.controller)}',
              ),
            );
            expect(
              find.byType(LobbyScreen),
              findsNothing,
              reason: _why(id, 'LobbyScreen gone after home', 'still there'),
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

      for (final _Room room in _Room.values) {
        testWidgets(
          'S.game.${room.name}.$tag: the game route on a ${room.name} table '
          'shows the view at the frame and after the close; home leaves the '
          'route and opens no transport',
          (tester) async {
            final String id = 'S.game.${room.name}.$tag';
            _seedFreshSeat();
            final _Rig rig = _Rig();
            final _RouteLog log = _RouteLog();
            await _mount(tester, rig, log, locale: appLocale);
            try {
              await _gameRoute(tester, rig, id, room: room);
              rig.last.pushText(_updateFrame());
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
              _expectUpdateView(
                tester,
                '$id (frame)',
                rig.controllers.last,
                locale: locale,
              );
              rig.last.endFromFarSide();
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
              expect(
                rig.controllers.last.phase,
                RoomPhase.closed,
                reason: '$id: fixture: the close must end the connection',
              );
              _expectUpdateView(
                tester,
                '$id (close)',
                rig.controllers.last,
                locale: locale,
              );
              expect(
                find.byType(GameScreen),
                findsOneWidget,
                reason: _why(
                  id,
                  'the game route to stay up under the view',
                  _note(tester, rig.controllers.last),
                ),
              );
              if (room != _Room.playing) {
                expect(
                  rig.sent('rematch'),
                  isEmpty,
                  reason: _why(
                    id,
                    'no rematch sent',
                    _note(tester, rig.controllers.last),
                  ),
                );
              }

              final int transportsBefore = rig.transports.length;
              final int leavesBefore = log.pageLeaves;
              await _tapHome(tester);
              await _settleHome(tester);
              final String saw = _note(tester, rig.controllers.last);
              expect(
                find.byType(GameScreen, skipOffstage: false),
                findsNothing,
                reason: _why(id, 'the game route gone after home', saw),
              );
              expect(
                _homeIsCurrent(tester),
                isTrue,
                reason: _why(id, 'Home to be the current route', saw),
              );
              expect(
                log.pageLeaves - leavesBefore,
                1,
                reason: _why(
                  id,
                  'exactly one page route to leave, as the corner close does',
                  '${log.pageLeaves - leavesBefore}; $saw',
                ),
              );
              expect(
                rig.transports.length,
                transportsBefore,
                reason: _why(
                  id,
                  'no transport opened by home (a resume would hit the same '
                      'refusal)',
                  '${rig.transports.length - transportsBefore} new; $saw',
                ),
              );
            } finally {
              await _finish(tester, rig);
            }
          },
        );
      }
    }

    testWidgets(
      'S.both.takeoverFirst: a takeover frame and then UPDATE_REQUIRED on '
      'the game screen draws the update view, not the seat-moved card',
      (tester) async {
        const String id = 'S.both.takeoverFirst';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, id, room: _Room.playing);
          rig.last.pushText(_takeoverFrame());
          await tester.pump();
          rig.last.pushText(_updateFrame());
          await tester.pump();
          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          _expectUpdateView(tester, id, rig.controllers.last, locale: _en);
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'S.both.updateFirst: UPDATE_REQUIRED and then a takeover frame on the '
      'game screen draws the update view, not the seat-moved card',
      (tester) async {
        const String id = 'S.both.updateFirst';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, id, room: _Room.playing);
          rig.last.pushText(_updateFrame());
          await tester.pump();
          rig.last.pushText(_takeoverFrame());
          await tester.pump();
          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          _expectUpdateView(tester, id, rig.controllers.last, locale: _en);
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'S.both.lobby: a takeover frame and then UPDATE_REQUIRED on a seated '
      'lobby draws the update view, not the seat-moved card',
      (tester) async {
        const String id = 'S.both.lobby';
        final _LobbyRig lobby = await _LobbyRig.open(
          tester,
          id,
          answered: true,
        );
        try {
          await lobby.push(tester, _takeoverFrame());
          await lobby.push(tester, _updateFrame());
          await lobby.drop(tester);
          _expectUpdateView(tester, id, lobby.controller, locale: _en);
        } finally {
          await lobby.finish(tester);
        }
      },
    );

    testWidgets(
      'S.reply: an UPDATE_REQUIRED error that answers a request (re set) '
      'draws no update view on the lobby',
      (tester) async {
        const String id = 'S.reply';
        final _LobbyRig lobby = await _LobbyRig.open(
          tester,
          id,
          answered: false,
        );
        try {
          lobby.transport.pushText(
            _updateFrame(re: _idOf(lobby.transport.sentRaw.last)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            lobby.controller.updateRequired,
            isFalse,
            reason: _why(
              id,
              'updateRequired false after a reply',
              '${lobby.controller.updateRequired}',
            ),
          );
          _expectNoUpdateView(tester, id, 'for a reply');
        } finally {
          await lobby.finish(tester);
        }
      },
    );

    testWidgets('guard.S.drop: a plain drop on a seated lobby still draws the '
        'connection-lost card and no update view', (tester) async {
      const String id = 'guard.S.drop';
      final _LobbyRig lobby = await _LobbyRig.open(tester, id, answered: true);
      try {
        await lobby.drop(tester);
        _expectNoUpdateView(tester, id, 'for a plain drop');
        expect(
          find.byKey(_lobbyCardKey),
          findsOneWidget,
          reason: _why(
            id,
            'the connection-lost card',
            _note(tester, lobby.controller),
          ),
        );
        expect(
          find.byKey(_staleRoomKey),
          findsOneWidget,
          reason: _why(
            id,
            'the held room under the card',
            _note(tester, lobby.controller),
          ),
        );
      } finally {
        await lobby.finish(tester);
      }
    });
  });

  // ---------------------------------------------------------------- K
  group('K Home keeps what the player needs to come back', () {
    const SeatRecord held = SeatRecord(code: _code, seat: 0, seatToken: _token);

    Future<SessionMemory> memory(WidgetTester tester) async {
      await _flushPrefs(tester);
      return SessionMemory.load();
    }

    testWidgets(
      'K.game: UPDATE_REQUIRED on the game route keeps session.seat and the '
      'recent codes, at the frame and after the close, and Back to game '
      'stays on Home',
      (tester) async {
        const String id = 'K.game';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, id, room: _Room.playing);
          expect(
            (await memory(tester)).seatRecord,
            held,
            reason: '$id: fixture: the seat is stored while it is held',
          );
          expect(
            find.byKey(_rejoinKey, skipOffstage: false),
            findsOneWidget,
            reason: '$id: fixture: Home holds Back to game under the route',
          );

          rig.last.pushText(_updateFrame());
          await tester.pump();
          SessionMemory now = await memory(tester);
          expect(
            now.seatRecord,
            held,
            reason: _why(
              id,
              'session.seat kept at the frame',
              'saw ${now.seatRecord}; ${_note(tester, rig.controllers.last)}',
            ),
          );
          expect(
            find.byKey(_rejoinKey, skipOffstage: false),
            findsOneWidget,
            reason: _why(
              id,
              'Back to game kept at the frame',
              _note(tester, rig.controllers.last),
            ),
          );

          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump(const Duration(seconds: 11));
          now = await memory(tester);
          expect(
            now.seatRecord,
            held,
            reason: _why(
              id,
              'session.seat kept after the close and the request timeout',
              'saw ${now.seatRecord}; ${_note(tester, rig.controllers.last)}',
            ),
          );
          expect(
            now.recentCodes,
            _recentCodes,
            reason: _why(id, 'the recent codes kept', 'saw ${now.recentCodes}'),
          );
          expect(
            find.byKey(_rejoinKey, skipOffstage: false),
            findsOneWidget,
            reason: _why(
              id,
              'Back to game kept after the close',
              _note(tester, rig.controllers.last),
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    Future<void> expectResumable(
      WidgetTester tester,
      _Rig rig,
      String id,
      String when,
    ) async {
      final String saw = _note(tester, rig.controllers.last);
      expect(
        _homeIsCurrent(tester),
        isTrue,
        reason: _why(id, 'Home to be the current route $when', saw),
      );
      final SessionMemory now = await memory(tester);
      expect(
        now.seatRecord,
        held,
        reason: _why(
          id,
          'session.seat unchanged $when',
          'saw ${now.seatRecord}; $saw',
        ),
      );
      expect(
        now.recentCodes,
        _recentCodes,
        reason: _why(
          id,
          'the recent codes unchanged $when',
          'saw ${now.recentCodes}',
        ),
      );
      expect(
        find.byKey(_rejoinKey),
        findsOneWidget,
        reason: _why(id, 'Home to still offer Back to game $when', saw),
      );
    }

    Future<void> resumeAgain(WidgetTester tester, _Rig rig, String id) async {
      final int before = rig.sent('resume').length;
      await tester.ensureVisible(find.byKey(_rejoinKey));
      await tester.tap(find.byKey(_rejoinKey));
      await _pumpBounded(tester, frames: 3);
      final List<String> resumes = rig.sent('resume');
      expect(
        resumes.length,
        before + 1,
        reason: _why(
          id,
          'one more resume from the Home button',
          '${resumes.length - before} more; ${_note(tester, null)}',
        ),
      );
      final Map<String, Object?> data =
          _decode(resumes.last)['d']! as Map<String, Object?>;
      expect(
        <Object?>[data['code'], data['seat_token']],
        <Object?>[_code, _token],
        reason: _why(
          id,
          'the resume to name the same room and seat token',
          '${data['code']} / ${data['seat_token']}',
        ),
      );
    }

    testWidgets(
      'K.home.game: Back to home on the update card of a PLAYING table lands '
      'on Home with the seat record and recent codes unchanged and the '
      'resume still offered',
      (tester) async {
        const String id = 'K.home.game';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          await _gameRoute(tester, rig, id, room: _Room.playing);
          rig.last.pushText(_updateFrame());
          await tester.pump();
          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          _expectUpdateView(tester, id, rig.controllers.last, locale: _en);
          await _tapHome(tester);
          await _settleHome(tester);
          expect(
            rig.controllers.last.wasDisposed,
            isTrue,
            reason: _why(
              id,
              'the owned controller retired by Home',
              _note(tester, rig.controllers.last),
            ),
          );
          await expectResumable(tester, rig, id, 'after Back to home');
          await resumeAgain(tester, rig, id);
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'K.home.lobby: Back to home on the update card of a seated lobby '
      'lands on Home with the seat record and recent codes unchanged and '
      'the resume still offered',
      (tester) async {
        const String id = 'K.home.lobby';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          expect(
            rig.sent('resume'),
            hasLength(1),
            reason: '$id: fixture: a fresh record resumes on its own',
          );
          _answerRoom(
            rig.last,
            rig.lastRequestId('resume'),
            _lobbyRoom(),
            seat: 0,
          );
          await _pumpBounded(tester, frames: 3);
          expect(
            find.byType(LobbyScreen),
            findsOneWidget,
            reason: '$id: fixture: a resume of a LOBBY room shows LobbyScreen',
          );
          rig.last.pushText(_updateFrame());
          await tester.pump();
          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          _expectUpdateView(tester, id, rig.controllers.last, locale: _en);
          await _tapHome(tester);
          await _settleHome(tester);
          expect(
            find.byType(LobbyScreen, skipOffstage: false),
            findsNothing,
            reason: _why(
              id,
              'the lobby route gone after Back to home',
              _note(tester, rig.controllers.last),
            ),
          );
          expect(
            rig.controllers.last.wasDisposed,
            isTrue,
            reason: _why(
              id,
              'the owned controller retired by Home',
              _note(tester, rig.controllers.last),
            ),
          );
          await expectResumable(tester, rig, id, 'after Back to home');
          await resumeAgain(tester, rig, id);
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'K.relaunch: after the refusal a relaunch of the app resumes the same '
      'seat',
      (tester) async {
        const String id = 'K.relaunch';
        _seedFreshSeat();
        final _Rig first = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, first, log);
        await _gameRoute(tester, first, id, room: _Room.playing);
        first.last.pushText(_updateFrame());
        await tester.pump();
        first.last.endFromFarSide();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _flushPrefs(tester);
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
          final Map<String, Object?> resume = _decode(
            second.sent('resume').single,
          );
          final Map<String, Object?> data =
              resume['d']! as Map<String, Object?>;
          expect(
            <Object?>[data['code'], data['seat_token']],
            <Object?>[_code, _token],
            reason: _why(
              id,
              'the resume to name the same room and seat token',
              '${data['code']} / ${data['seat_token']}',
            ),
          );
          expect(
            (await memory(tester)).recentCodes,
            _recentCodes,
            reason: _why(
              id,
              'the recent codes kept across the relaunch',
              'lost',
            ),
          );
        } finally {
          await _finish(tester, second);
        }
      },
    );

    testWidgets(
      'K.resume: the refusal that answers the resume Home sends at launch '
      'shows the view and keeps the seat and the recent codes',
      (tester) async {
        const String id = 'K.resume';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        final _RouteLog log = _RouteLog();
        await _mount(tester, rig, log);
        try {
          expect(
            rig.sent('resume'),
            hasLength(1),
            reason: '$id: fixture: a fresh record resumes on its own',
          );
          rig.last.pushText(_updateFrame());
          await tester.pump();
          rig.last.endFromFarSide();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump(const Duration(seconds: 11));
          _expectUpdateView(tester, id, rig.controllers.last, locale: _en);
          final SessionMemory now = await memory(tester);
          expect(
            now.seatRecord,
            held,
            reason: _why(
              id,
              'session.seat kept',
              'saw ${now.seatRecord}; ${_note(tester, rig.controllers.last)}',
            ),
          );
          expect(
            now.recentCodes,
            _recentCodes,
            reason: _why(id, 'the recent codes kept', 'saw ${now.recentCodes}'),
          );
          expect(
            rig.sent('resume'),
            hasLength(1),
            reason: _why(
              id,
              'no second resume on this controller',
              '${rig.sent('resume').length} resumes',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );
  });

  // ---------------------------------------------------------------- A1
  group('A1 the four ARB keys', () {
    Map<String, Object?> arb(String name) =>
        jsonDecode(File('lib/l10n/$name.arb').readAsStringSync())
            as Map<String, Object?>;

    final Map<String, ({String en, String ar})> expected = {
      'updateRequiredTitle': (en: _enTitle, ar: _arTitle),
      'updateRequiredBody': (en: _enBody, ar: _arBody),
      'updateRequiredStoreButton': (en: _enStore, ar: _arStore),
      'updateRequiredHomeButton': (en: _enHome, ar: _arHome),
    };

    for (final MapEntry<String, ({String en, String ar})> entry
        in expected.entries) {
      test('A1.en ${entry.key}: the exact English text and a description', () {
        final String id = 'A1.en ${entry.key}';
        final Map<String, Object?> file = arb('app_en');
        expect(
          file[entry.key],
          entry.value.en,
          reason:
              '$id: expected app_en.arb ${entry.key} "${entry.value.en}"; '
              'saw ${file[entry.key]}. ${_reproduce(id)}',
        );
        final Object? meta = file['@${entry.key}'];
        expect(
          meta is Map<String, Object?> &&
              meta['description'] is String &&
              (meta['description']! as String).trim().isNotEmpty,
          isTrue,
          reason:
              '$id: expected an @${entry.key} description in app_en.arb; '
              'saw $meta. ${_reproduce(id)}',
        );
      });

      test('A1.ar ${entry.key}: the exact Arabic text', () {
        final String id = 'A1.ar ${entry.key}';
        final Map<String, Object?> file = arb('app_ar');
        expect(
          file[entry.key],
          entry.value.ar,
          reason:
              '$id: expected app_ar.arb ${entry.key} "${entry.value.ar}"; '
              'saw ${file[entry.key]}. ${_reproduce(id)}',
        );
      });
    }

    test('A1.plain: no em-dash, no curly quote, no emoji in either text', () {
      const String id = 'A1.plain';
      final RegExp odd = RegExp(
        r'[\u2014\u2013\u2018\u2019\u201C\u201D\u{1F000}-\u{1FFFF}\u2600-\u27BF]',
        unicode: true,
      );
      for (final String name in <String>['app_en', 'app_ar']) {
        final Map<String, Object?> file = arb(name);
        for (final String key in expected.keys) {
          final Object? value = file[key];
          expect(
            value is String && !odd.hasMatch(value),
            isTrue,
            reason:
                '$id: expected $name.arb $key to be plain text with straight '
                'quotes; saw $value. ${_reproduce(id)}',
          );
        }
      }
    });
  });
}

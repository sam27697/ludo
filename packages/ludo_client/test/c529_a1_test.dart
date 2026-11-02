// Proof for amendment A1 of contract C-529
// (work/ludo/orders/C-529-dead-rooms-and-first-launch.md), the four points the
// review of order 529 found: A1.1 to A1.4. A1.5 records accepted deviations
// and needs no case.
//
// The rig is the one test/dead_rooms_first_launch_test.dart uses (copied, not
// imported, so that file stays untouched): the real HomeScreen, RoomRoute,
// LobbyScreen and GameScreen over a real RoomController on FakeTransport, a
// fresh transport per connect so a controller that reconnects can be answered
// on its second one.
//
// Cases:
//   A1.1  a PLAYING game with a sheet above the game route (the leave confirm,
//         the quick-chat sheet), the server answers a resume NO_SUCH_ROOM:
//         the game route and the sheet both leave, Home shows
//         home-game-gone-notice, game-screen-stale-table is gone once settled.
//   A1.2  a join to dead code A, a room link for B arrives while the lobby
//         route is up: back home the field holds B and a Join of B is a link
//         join. Control: without the second link the field is cleared.
//   A1.3  a resume lobby that fails before any snapshot keeps the Leave label.
//   A1.4  a create or join lobby that held a room, resume refused
//         BAD_SEAT_TOKEN: no Retry, the button reads Leave. Control:
//         RATE_LIMITED keeps Retry.
//
// Each failure reason names the case and the scenario and what was seen. There
// is no random input: the case id reproduces it exactly, with
//   flutter test test/c529_a1_test.dart --plain-name '<id>'
//
// Not covered, because the amendment does not give a way to drive it: A1.4's
// second trigger ("the controller has no seat token to resume with") needs a
// controller holding a room and no token, which no wire frame produces.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _codeKey = Key('room-code-field');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _lobbyErrorKey = Key('lobby-error');
const Key _retryKey = Key('lobby-retry-button');
const Key _lobbyLeaveKey = Key('lobby-leave-button');
const Key _lobbyReconnectKey = Key('lobby-reconnect-button');
const Key _gameReconnectKey = Key('game-screen-reconnect-button');
const Key _goneNoticeKey = Key('home-game-gone-notice');
const Key _staleTableKey = Key('game-screen-stale-table');
const Key _appBarLeaveKey = Key('game-screen-appbar-leave');
const Key _leaveConfirmKey = Key('game-leave-confirm');
const Key _chatButtonKey = Key('game-chat-button');
const Key _chatSheetKey = Key('quick-chat-sheet');

const String _testUrl = 'wss://c529-a1-test.invalid/ws';
const String _code = 'K7M2QP';
const String _deadCode = 'ZY98XW';
const String _linkCode = 'AB23CD';
const String _token = 'tok-c529-a1-001';
const String _gameId = '7f3a9c1e5b2d4068';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';

const String _enGameGone = 'That game has ended.';
const String _arGameGone = 'انتهت تلك اللعبة.';
const String _enBackHome = 'Back to home';
const String _arBackHome = 'العودة إلى الرئيسية';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c529-a1-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

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
  String code = _code,
  String? gameId,
  Map<String, Object?>? turn,
}) => <String, Object?>{
  'code': code,
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

/// A [RoomController] that remembers whether [dispose] has run: Home retires
/// the controllers it owns when a route pops, and a ChangeNotifier refuses a
/// second dispose.
class _TrackedController extends RoomController {
  _TrackedController({required super.serverUrl, required super.connect});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

/// Hands out a fresh controller per call. Every connect any of them makes
/// opens a new [FakeTransport] (the first [rejectFirstConnects] connects
/// throw instead, which RoomConnection maps to errorCode "transport").
class _Rig {
  _Rig({this.rejectFirstConnects = 0});

  final int rejectFirstConnects;
  final List<_TrackedController> controllers = <_TrackedController>[];
  final List<FakeTransport> transports = <FakeTransport>[];
  int connectCalls = 0;

  Future<WireTransport> _connect(Uri url) async {
    connectCalls += 1;
    if (connectCalls <= rejectFirstConnects) {
      throw StateError('c529_a1_test: connect rejected');
    }
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

  /// Every frame of [type] sent on any transport, in order.
  List<String> sent(String type) => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (_typeOf(s) == type) s,
  ];

  List<String> get allTypes => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw) _typeOf(s),
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

class _LinkRig {
  final StreamController<Uri> stream = StreamController<Uri>.broadcast();

  Future<Uri?> read() => Future<Uri?>.value(null);
  Stream<Uri> open() => stream.stream;
}

Uri _linkTo(String code) => Uri.parse('https://ludo.provefair.app/r/$code');

Widget _app(RoomControllerFactory factory, {Locale? locale, _LinkRig? links}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: factory,
      initialLinkReader: links?.read ?? noInitialLink,
      linkStream: links?.open ?? noLinkStream,
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
  _Rig rig, {
  Locale? locale,
  _LinkRig? links,
}) async {
  addTearDown(() => links?.stream.close());
  await tester.pumpWidget(_app(rig.call, locale: locale, links: links));
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

/// Types a full code, then waits out the 200 ms AnimatedSize that brings Join
/// in so a tap lands on its final rect.
Future<void> _typeCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(_codeKey), code);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

String _fieldText(WidgetTester tester, Key key) {
  return tester
      .widget<TextField>(find.byKey(key, skipOffstage: false))
      .controller!
      .text;
}

List<String?> _errorTexts(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(_lobbyErrorKey),
        matching: find.byType(Text),
      ),
    )
    .map((Text t) => t.data)
    .toList();

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

/// Home, tap Create, answer create_room with a two seat lobby for host seat
/// 0, then drop the socket and tap Reconnect. Returns with the resume sent
/// and unanswered on the second transport.
Future<void> _hostLobbyAwaitingResume(
  WidgetTester tester,
  _Rig rig,
  String scenario,
) async {
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
  await _dropAndReconnect(
    tester,
    rig,
    scenario,
    find.byKey(_lobbyReconnectKey),
  );
}

/// Home, type [_code], tap Join, answer with a two seat lobby for guest seat
/// 1, then drop the socket and tap Reconnect.
Future<void> _guestLobbyAwaitingResume(
  WidgetTester tester,
  _Rig rig,
  String scenario,
) async {
  await _typeCode(tester, _code);
  await _tap(tester, _joinKey);
  expect(
    rig.sent('join_room'),
    hasLength(1),
    reason: '$scenario: fixture: Join must send one join_room',
  );
  _answerRoom(rig.last, rig.lastRequestId('join_room'), _lobbyRoom(), seat: 1);
  await _pumpBounded(tester, frames: 3);
  await _dropAndReconnect(
    tester,
    rig,
    scenario,
    find.byKey(_lobbyReconnectKey),
  );
}

/// Drops the socket under the controller and checks the screen offers
/// Reconnect. With [tapReconnect] the button is tapped and the resume is
/// checked on the second transport; without it the caller owns the next step
/// (a sheet above the screen hides the button from a tap).
Future<void> _dropAndReconnect(
  WidgetTester tester,
  _Rig rig,
  String scenario,
  Finder reconnectButton, {
  bool tapReconnect = true,
}) async {
  final RoomController controller = rig.controllers.last;
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        '$scenario: fixture: the room reply must land connected; phase '
        '${controller.phase}, error ${controller.errorCode}',
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
  expect(
    reconnectButton,
    findsOneWidget,
    reason: '$scenario: fixture: the dropped screen must offer Reconnect',
  );
  if (!tapReconnect) {
    return;
  }
  await tester.ensureVisible(reconnectButton);
  await tester.tap(reconnectButton);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  _expectResumeSent(rig, scenario, before);
}

void _expectResumeSent(_Rig rig, String scenario, int transportsBefore) {
  expect(
    rig.transports.length,
    transportsBefore + 1,
    reason: '$scenario: fixture: Reconnect must open a second transport',
  );
  expect(
    rig.last.sentRaw.map(_typeOf).toList(),
    <String>['resume'],
    reason:
        '$scenario: fixture: Reconnect must send exactly one resume; sent '
        '${rig.last.sentRaw.map(_typeOf).toList()}',
  );
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

void _expectLeaveLabel(
  WidgetTester tester,
  String expected,
  String scenario, {
  List<String> notExpected = const <String>[],
}) {
  expect(
    find.byKey(_lobbyLeaveKey),
    findsOneWidget,
    reason: '$scenario: lobby-leave-button must be on screen',
  );
  final Finder error = find.byKey(_lobbyErrorKey);
  expect(
    error,
    findsOneWidget,
    reason: '$scenario: lobby-error must be on screen',
  );
  expect(
    find.descendant(
      of: find.byKey(_lobbyLeaveKey),
      matching: find.text(expected),
    ),
    findsOneWidget,
    reason:
        '$scenario: lobby-leave-button must read "$expected"; the texts in '
        'lobby-error are ${_errorTexts(tester)}',
  );
  for (final String other in notExpected) {
    expect(
      find.descendant(
        of: find.byKey(_lobbyLeaveKey),
        matching: find.text(other),
      ),
      findsNothing,
      reason:
          '$scenario: lobby-leave-button must not read "$other"; the texts '
          'in lobby-error are ${_errorTexts(tester)}',
    );
  }
}

/// What is on the tree after a PLAYING room answered NO_SUCH_ROOM with a sheet
/// above the game: nothing of the game, nothing of the sheet, Home current
/// with the gone notice.
Future<void> _expectGameLeft(
  WidgetTester tester, {
  required String expected,
  required String scenario,
}) async {
  // Frame by frame first, so a route that only leaves late still counts as
  // not having left; then a settling window long enough for any sheet exit
  // motion, a barrier fade and the game route's own transition.
  for (int i = 0; i < 20; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  String seenOnTree() =>
      'GameScreen=${find.byType(GameScreen, skipOffstage: false).evaluate().length} '
      'leave-confirm=${find.byKey(_leaveConfirmKey, skipOffstage: false).evaluate().length} '
      'quick-chat-sheet=${find.byKey(_chatSheetKey, skipOffstage: false).evaluate().length} '
      'stale-table=${find.byKey(_staleTableKey, skipOffstage: false).evaluate().length} '
      'homeIsCurrent=${_homeIsCurrent(tester)}';

  expect(
    find.byType(GameScreen, skipOffstage: false),
    findsNothing,
    reason:
        '$scenario: the game route must leave even with a sheet above it; '
        'on the tree after 2 s: ${seenOnTree()}',
  );
  expect(
    find.byKey(_leaveConfirmKey, skipOffstage: false),
    findsNothing,
    reason: '$scenario: the leave confirm must be gone; ${seenOnTree()}',
  );
  expect(
    find.byKey(_chatSheetKey, skipOffstage: false),
    findsNothing,
    reason: '$scenario: the quick-chat sheet must be gone; ${seenOnTree()}',
  );
  expect(
    find.byKey(_staleTableKey, skipOffstage: false),
    findsNothing,
    reason:
        '$scenario: the player must never be left on the dimmed stale '
        'table; ${seenOnTree()}',
  );
  expect(
    _homeIsCurrent(tester),
    isTrue,
    reason: '$scenario: Home must be the current route; ${seenOnTree()}',
  );
  final Finder notice = find.byKey(_goneNoticeKey);
  expect(
    notice,
    findsOneWidget,
    reason: '$scenario: Home must show home-game-gone-notice; ${seenOnTree()}',
  );
  expect(
    tester.widget<Text>(notice).data,
    expected,
    reason:
        '$scenario: the notice must read "$expected"; read '
        '"${tester.widget<Text>(notice).data}"',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- A1.1
  group('A1.1 a sheet above the game does not keep the player on a dead table', () {
    for (final ({String id, Locale? locale, String expected}) variant in [
      (id: 'A1.1a', locale: null, expected: _enGameGone),
      (id: 'A1.1b', locale: const Locale('ar'), expected: _arGameGone),
    ]) {
      testWidgets(
        '${variant.id}: the leave confirm is open when the resume is answered '
        'NO_SUCH_ROOM (${variant.locale ?? 'en'}): game route and sheet gone, '
        'gone notice on Home',
        (tester) async {
          final String scenario =
              '${variant.id} PLAYING room, socket drop, Reconnect, leave '
              'confirm opened from game-screen-appbar-leave, resume answered '
              'NO_SUCH_ROOM, locale ${variant.locale ?? 'en'}';
          _seedFreshSeat();
          final _Rig rig = _Rig();
          await _mount(tester, rig, locale: variant.locale);
          await _playingGame(tester, rig, scenario);
          await _dropAndReconnect(
            tester,
            rig,
            scenario,
            find.byKey(_gameReconnectKey),
          );

          await _tap(tester, _appBarLeaveKey);
          expect(
            find.byKey(_leaveConfirmKey),
            findsOneWidget,
            reason:
                '$scenario: fixture: the leave control must open the leave '
                'confirm sheet over the game',
          );

          _answerError(
            rig.last,
            _idOf(rig.last.sentRaw.single),
            'NO_SUCH_ROOM',
          );
          await _pumpBounded(tester, frames: 2);
          await _expectGameLeft(
            tester,
            expected: variant.expected,
            scenario: scenario,
          );

          await _finish(tester, rig);
        },
      );
    }

    testWidgets(
      'A1.1c: the leave confirm was opened while connected, the socket '
      'dropped under it, the resume is answered NO_SUCH_ROOM: game route and '
      'sheet gone, gone notice on Home',
      (tester) async {
        const String scenario =
            'A1.1c PLAYING room, leave confirm open, socket drop, reconnect '
            'from the controller, resume answered NO_SUCH_ROOM';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        await _mount(tester, rig);
        await _playingGame(tester, rig, scenario);

        await _tap(tester, _appBarLeaveKey);
        expect(
          find.byKey(_leaveConfirmKey),
          findsOneWidget,
          reason: '$scenario: fixture: the leave confirm must be open',
        );
        final int before = rig.transports.length;
        await _dropAndReconnect(
          tester,
          rig,
          scenario,
          find.byKey(_gameReconnectKey, skipOffstage: false),
          tapReconnect: false,
        );
        expect(
          find.byKey(_leaveConfirmKey),
          findsOneWidget,
          reason:
              '$scenario: fixture: a dropped socket must not close the leave '
              'confirm by itself',
        );
        unawaited(rig.controllers.last.reconnect());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        _expectResumeSent(rig, scenario, before);

        _answerError(rig.last, _idOf(rig.last.sentRaw.single), 'NO_SUCH_ROOM');
        await _pumpBounded(tester, frames: 2);
        await _expectGameLeft(
          tester,
          expected: _enGameGone,
          scenario: scenario,
        );

        await _finish(tester, rig);
      },
    );

    testWidgets(
      'A1.1d: the quick-chat sheet was opened while connected, the socket '
      'dropped under it, the resume is answered NO_SUCH_ROOM: game route and '
      'sheet gone, gone notice on Home',
      (tester) async {
        const String scenario =
            'A1.1d PLAYING room, quick-chat sheet open, socket drop, '
            'reconnect from the controller, resume answered NO_SUCH_ROOM';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        await _mount(tester, rig);
        await _playingGame(tester, rig, scenario);

        await _tap(tester, _chatButtonKey);
        expect(
          find.byKey(_chatSheetKey),
          findsOneWidget,
          reason: '$scenario: fixture: the chat button must open the sheet',
        );
        final int before = rig.transports.length;
        await _dropAndReconnect(
          tester,
          rig,
          scenario,
          find.byKey(_gameReconnectKey, skipOffstage: false),
          tapReconnect: false,
        );
        expect(
          find.byKey(_chatSheetKey),
          findsOneWidget,
          reason:
              '$scenario: fixture: a dropped socket must not close the chat '
              'sheet by itself',
        );
        unawaited(rig.controllers.last.reconnect());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        _expectResumeSent(rig, scenario, before);

        _answerError(rig.last, _idOf(rig.last.sentRaw.single), 'NO_SUCH_ROOM');
        await _pumpBounded(tester, frames: 2);
        await _expectGameLeft(
          tester,
          expected: _enGameGone,
          scenario: scenario,
        );

        await _finish(tester, rig);
      },
    );
  });

  // ---------------------------------------------------------------- A1.2
  group('A1.2 a link that arrived while the dead join was up is kept', () {
    for (final String deadAnswer in <String>['NO_SUCH_ROOM', 'ROOM_STARTED']) {
      testWidgets(
        'A1.2a: join of dead code answered $deadAnswer, a room link for '
        'another code arrives while the lobby route is up, Back to home: the '
        'field holds the link code, Join sends it as a link join',
        (tester) async {
          final String scenario =
              'A1.2a typed join of $_deadCode answered $deadAnswer, link '
              'for $_linkCode delivered on the link stream while the lobby '
              'route is pushed, Back to home';
          final _Rig rig = _Rig();
          final _LinkRig links = _LinkRig();
          await _mount(tester, rig, links: links);

          await _typeCode(tester, _deadCode);
          await _tap(tester, _joinKey);
          _answerError(rig.last, rig.lastRequestId('join_room'), deadAnswer);
          await _pumpBounded(tester, frames: 3);
          expect(
            find.byKey(_lobbyErrorKey),
            findsOneWidget,
            reason: '$scenario: fixture: lobby-error must show for the join',
          );

          links.stream.add(_linkTo(_linkCode));
          await _pumpBounded(tester, frames: 3);
          expect(
            find.byKey(_lobbyErrorKey),
            findsOneWidget,
            reason:
                '$scenario: fixture: a link while a route is up must not '
                'move the player off the lobby route',
          );

          await tester.tap(find.byKey(_lobbyLeaveKey));
          await tester.pump();
          await _pumpBounded(tester, frames: 3);
          expect(
            _homeIsCurrent(tester),
            isTrue,
            reason: '$scenario: Back to home must return to Home',
          );

          expect(
            _fieldText(tester, _codeKey),
            _linkCode,
            reason:
                '$scenario: the code the link filled must stay; the field '
                'holds "${_fieldText(tester, _codeKey)}"',
          );
          expect(
            find.byKey(_joinKey),
            findsOneWidget,
            reason: '$scenario: Join must be primary for the link code',
          );

          await _tap(tester, _joinKey);
          final List<String> joins = rig.sent('join_room');
          expect(
            joins,
            hasLength(2),
            reason:
                '$scenario: the second Join must send a join_room; sent '
                '${rig.allTypes}',
          );
          expect(
            _dataOf(joins.last)['code'],
            _linkCode,
            reason:
                '$scenario: the second join_room must carry the link code; '
                'sent ${_dataOf(joins.last)}',
          );
          _answerError(rig.last, _idOf(joins.last), 'NO_SUCH_ROOM');
          await _pumpBounded(tester, frames: 3);
          final Finder error = find.byKey(_lobbyErrorKey);
          expect(
            error,
            findsOneWidget,
            reason: '$scenario: lobby-error must show for the second join',
          );
          expect(
            find.descendant(
              of: error,
              matching: find.text(_loc(tester).lobbyErrorLinkRoomGone),
            ),
            findsOneWidget,
            reason:
                '$scenario: the second Join is a link join, so the error '
                'reads lobbyErrorLinkRoomGone; texts are '
                '${_errorTexts(tester)}',
          );

          await _finish(tester, rig);
        },
      );
    }

    testWidgets(
      'A1.2b (control): the same join answered NO_SUCH_ROOM with no link in '
      'between: Back to home clears the code field and Create is primary',
      (tester) async {
        const String scenario =
            'A1.2b typed join of $_deadCode answered NO_SUCH_ROOM, no link, '
            'Back to home';
        final _Rig rig = _Rig();
        await _mount(tester, rig, links: _LinkRig());

        await _typeCode(tester, _deadCode);
        await _tap(tester, _joinKey);
        _answerError(rig.last, rig.lastRequestId('join_room'), 'NO_SUCH_ROOM');
        await _pumpBounded(tester, frames: 3);
        expect(
          find.byKey(_lobbyErrorKey),
          findsOneWidget,
          reason: '$scenario: fixture: lobby-error must show',
        );

        await tester.tap(find.byKey(_lobbyLeaveKey));
        await tester.pump();
        await _pumpBounded(tester, frames: 3);

        expect(
          _homeIsCurrent(tester),
          isTrue,
          reason: '$scenario: Back to home must return to Home',
        );
        expect(
          _fieldText(tester, _codeKey),
          '',
          reason:
              '$scenario: the dead code must not stay in the field; holds '
              '"${_fieldText(tester, _codeKey)}"',
        );
        expect(
          find.byKey(_joinKey, skipOffstage: false),
          findsNothing,
          reason: '$scenario: Join must be gone with the code',
        );

        await _finish(tester, rig);
      },
    );
  });

  // ---------------------------------------------------------------- A1.3
  group('A1.3 a resume lobby that never held a room keeps Leave', () {
    for (final ({String id, Locale? locale, String back}) variant in [
      (id: 'A1.3a', locale: null, back: _enBackHome),
      (id: 'A1.3b', locale: const Locale('ar'), back: _arBackHome),
    ]) {
      testWidgets(
        '${variant.id}: a stored seat, the automatic resume fails on the '
        'transport before any snapshot (${variant.locale ?? 'en'}): the '
        'button reads Leave, not "${variant.back}"',
        (tester) async {
          final String scenario =
              '${variant.id} fresh seat record, first connect rejected, '
              'locale ${variant.locale ?? 'en'}';
          _seedFreshSeat();
          final _Rig rig = _Rig(rejectFirstConnects: 1);
          await _mount(tester, rig, locale: variant.locale);

          expect(
            rig.controllers.last.errorCode,
            'transport',
            reason:
                '$scenario: fixture: the rejected connect must land '
                'errorCode transport; got ${rig.controllers.last.errorCode}',
          );
          expect(
            rig.controllers.last.room,
            isNull,
            reason: '$scenario: fixture: no snapshot may have arrived',
          );
          _expectLeaveLabel(
            tester,
            _loc(tester).gameLeaveButton,
            scenario,
            notExpected: <String>[variant.back],
          );

          await _finish(tester, rig);
        },
      );
    }

    testWidgets(
      'A1.3c: a stored seat, the automatic resume is answered RATE_LIMITED '
      'before any snapshot: the button reads Leave, not "Back to home"',
      (tester) async {
        const String scenario =
            'A1.3c fresh seat record, resume answered RATE_LIMITED';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        await _mount(tester, rig);
        expect(
          rig.sent('resume'),
          hasLength(1),
          reason: '$scenario: fixture: a fresh record resumes on its own',
        );
        _answerError(rig.last, rig.lastRequestId('resume'), 'RATE_LIMITED');
        await _pumpBounded(tester, frames: 3);

        _expectLeaveLabel(
          tester,
          _loc(tester).gameLeaveButton,
          scenario,
          notExpected: <String>[_enBackHome],
        );

        await _finish(tester, rig);
      },
    );
  });

  // ---------------------------------------------------------------- A1.4
  group('A1.4 a seat taken back leaves no Retry that cannot work', () {
    for (final ({String id, bool host, Locale? locale}) variant in [
      (id: 'A1.4a', host: true, locale: null),
      (id: 'A1.4b', host: false, locale: null),
      (id: 'A1.4c', host: true, locale: const Locale('ar')),
    ]) {
      testWidgets(
        '${variant.id}: a ${variant.host ? 'create' : 'join'} lobby that held '
        'a room, Reconnect answered BAD_SEAT_TOKEN '
        '(${variant.locale ?? 'en'}): no lobby-retry-button, the button reads '
        'Leave',
        (tester) async {
          final String scenario =
              '${variant.id} ${variant.host ? 'create' : 'join'} lobby, '
              'socket drop, Reconnect answered BAD_SEAT_TOKEN, locale '
              '${variant.locale ?? 'en'}';
          final _Rig rig = _Rig();
          await _mount(tester, rig, locale: variant.locale);
          if (variant.host) {
            await _hostLobbyAwaitingResume(tester, rig, scenario);
          } else {
            await _guestLobbyAwaitingResume(tester, rig, scenario);
          }

          _answerError(
            rig.last,
            _idOf(rig.last.sentRaw.single),
            'BAD_SEAT_TOKEN',
          );
          await _pumpBounded(tester, frames: 3);

          expect(
            rig.controllers.last.errorCode,
            'BAD_SEAT_TOKEN',
            reason:
                '$scenario: fixture: the resume must fail with '
                'BAD_SEAT_TOKEN; got ${rig.controllers.last.errorCode}',
          );
          expect(
            find.byKey(_lobbyErrorKey),
            findsOneWidget,
            reason:
                '$scenario: fixture: the lobby must stay on its error body; '
                'home is current: ${_homeIsCurrent(tester)}',
          );
          expect(
            find.byKey(_retryKey),
            findsNothing,
            reason:
                '$scenario: the seat was taken back, a resume cannot '
                'succeed, so Retry must be absent; texts are '
                '${_errorTexts(tester)}',
          );
          _expectLeaveLabel(
            tester,
            _loc(tester).gameLeaveButton,
            scenario,
            notExpected: <String>[_enBackHome, _arBackHome],
          );

          await _finish(tester, rig);
        },
      );
    }

    testWidgets(
      'A1.4d (control): the same create lobby answered RATE_LIMITED keeps '
      'lobby-retry-button, and the button reads Leave',
      (tester) async {
        const String scenario =
            'A1.4d create lobby, socket drop, Reconnect answered RATE_LIMITED';
        final _Rig rig = _Rig();
        await _mount(tester, rig);
        await _hostLobbyAwaitingResume(tester, rig, scenario);

        _answerError(rig.last, _idOf(rig.last.sentRaw.single), 'RATE_LIMITED');
        await _pumpBounded(tester, frames: 3);

        expect(
          rig.controllers.last.errorCode,
          'RATE_LIMITED',
          reason: '$scenario: fixture: the resume must fail with RATE_LIMITED',
        );
        expect(
          find.byKey(_retryKey),
          findsOneWidget,
          reason:
              '$scenario: a rate limit passes, so Retry must stay; texts '
              'are ${_errorTexts(tester)}',
        );
        _expectLeaveLabel(
          tester,
          _loc(tester).gameLeaveButton,
          scenario,
          notExpected: <String>[_enBackHome],
        );

        await _finish(tester, rig);
      },
    );
  });
}

// Proof for contract C-529 (work/ludo/orders/C-529-dead-rooms-and-first-launch.md):
// dead rooms, first launch and the name field, decisions D1 to D6. D7 (the
// trailing slash on a room link) is in test/deep_link_trailing_slash_test.dart.
//
// Written from the contract and from the rigs the neighbouring suites use
// (test/relaunch_back_to_game_test.dart for the Home, link and lobby flow,
// test/game_screen_connection_lost_test.dart for driving GameScreen to a
// failed phase through a real request), never from the implementation.
//
// Every scenario runs the real HomeScreen, RoomRoute, LobbyScreen and
// GameScreen over a real RoomController on FakeTransport. The rig below
// opens a new transport on every connect, so a controller that reconnects
// (the lobby and game Reconnect buttons) gets a second one it can be
// answered on.
//
// Strings the contract quotes word for word are asserted as those words, in
// both locales, so the new ARB keys can be named by the implementation
// freely and this file still compiles against them. Strings that already
// have a getter are read through AppLocalizations.
//
// Case ids follow the decisions: D1a.., D2a.., D3a.., D4a.., D5a.., D6a..
// Each failure reason names the case, the scenario and what was seen, so a
// red case is rerun with
//   flutter test test/dead_rooms_first_launch_test.dart --plain-name '<id>'
// There is no random input anywhere: a scenario id reproduces it exactly.
//
// Not covered, because the contract leaves it open (reported, not guessed):
//   - D3 asks that the new room-closed notice share the slot, style and
//     live-region behaviour of home-game-gone-notice. The slot (above
//     Create, inside home-notice), the live region and the dismiss are
//     asserted (D3i); the style is private to the notice widget and is not
//     observable from outside.
//   - D3 and D4 together leave one thing open: for a lobby that holds a room
//     and fails with a code Retry stays for (RATE_LIMITED), the contract says
//     Retry stays, and also that it never calls createRoom. What it does
//     instead is the implementation's choice, so D3e taps it only when it is
//     there and asserts that no second create_room goes out.
//   - D6 says a PLAYING room keeps the empty roll line, but after D3 a
//     PLAYING room never reaches the end card, and the roll history is drawn
//     only there, so no screen draws that line for a PLAYING room. No case
//     is written for it; D6d (rolls seen keep the block) guards the other
//     side of the same rule.
//   - D2 does not say whether the 24 unit cut or the control character drop
//     runs first. D2d asserts only what the server needs: no control
//     character, at most 24 units, and nothing that was not typed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _nameKey = Key('home-name-field');
const Key _codeKey = Key('room-code-field');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _lobbyErrorKey = Key('lobby-error');
const Key _retryKey = Key('lobby-retry-button');
const Key _lobbyLeaveKey = Key('lobby-leave-button');
const Key _lobbyReconnectKey = Key('lobby-reconnect-button');
const Key _gameReconnectKey = Key('game-screen-reconnect-button');
const Key _goneNoticeKey = Key('home-game-gone-notice');
const Key _closedNoticeKey = Key('home-room-closed-notice');

/// A code lobbyErrorMessage maps to the generic line. D5 used BAD_SEAT_TOKEN
/// for this until C-540 D1: a game route whose controller fails with
/// BAD_SEAT_TOKEN now goes home instead of drawing the connection-lost card.
const String _genericCode = 'INTERNAL';
const Key _removedNoticeKey = Key('home-removed-notice');
const Key _noticeCardKey = Key('home-notice');
const Key _rematchGoneKey = Key('end-card-rematch-gone');
const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _errorMessageKey = Key('game-screen-error-message');

const String _testUrl = 'wss://dead-rooms-test.invalid/ws';
const String _code = 'K7M2QP';
const String _otherCode = 'ZY98XW';
const String _linkCode = 'AB23CD';
const String _token = 'tok-dead-rooms-001';
const String _verifyUrl = 'https://provefair.app/v/dead-rooms-529';
const String _gameId = '7f3a9c1e5b2d4068';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';

// The words the contract quotes. The new ARB getters are not on the base this
// file was written against, so these literals are what keeps it compiling.
const String _enHostClosed =
    'Your room closed while you were away. Create a new one and send the new '
    'link.';
const String _arHostClosed =
    'أُغلقت غرفتك أثناء غيابك. أنشئ غرفة جديدة وأرسل الرابط الجديد.';
const String _enGuestClosed =
    'That room closed while you were away. Ask your friend for a new link.';
const String _arGuestClosed =
    'أُغلقت الغرفة أثناء غيابك. اطلب من صديقك رابطاً جديداً.';
const String _enGameGone = 'That game has ended.';
const String _arGameGone = 'انتهت تلك اللعبة.';
const String _enRoomStarted = 'That room is no longer taking players.';
const String _arRoomStarted = 'هذه الغرفة لم تعد تستقبل لاعبين.';
const String _enBackHome = 'Back to home';
const String _arBackHome = 'العودة إلى الرئيسية';
const String _serverEnglish = 'seat token does not match a live seat';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'dead-rooms-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(
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

Map<String, Object?> _roomJson({
  required String state,
  String code = _code,
  int seq = 3,
  String? gameId,
  int? winner,
  Map<String, Object?>? turn,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? rematch,
  String? verifyUrl,
  int chainIndex = 0,
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
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': gameId == null ? null : '0:sam-seed|1:bob-seed',
  'seats':
      seats ??
      <Map<String, Object?>>[
        _seatJson(0, name: 'Host'),
        _seatJson(1, name: 'Guest'),
      ],
  'turn': turn,
  'winner': winner,
  'seq': seq,
  'verify_url': ?verifyUrl,
  'rematch': ?rematch,
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

Map<String, Object?> _finishedRoom({int seq = 9}) => _roomJson(
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
    _seatJson(0, name: 'Host', tokens: const <int>[57, 57, 57, 57]),
    _seatJson(1, name: 'Guest', tokens: const <int>[57, 57, 12, -1]),
  ],
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
      throw StateError('dead_rooms_first_launch_test: connect rejected');
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
  _LinkRig({this.cold});

  final Uri? cold;
  final StreamController<Uri> stream = StreamController<Uri>.broadcast();

  Future<Uri?> read() => Future<Uri?>.value(cold);
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
/// in (C-523 D3) so a tap lands on its final rect.
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

void _answerError(
  FakeTransport transport,
  String requestId,
  String code, {
  String message = '',
}) {
  transport.pushText(
    _frame(
      type: 'error',
      re: requestId,
      data: <String, Object?>{'code': code, 'message': message},
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

/// Pumps frame by frame and reports the frames at which each of [watched]
/// was in the tree, offstage included. A pop transition draws the route being
/// left for a few frames, so "never drawn" must be read over all of them.
Future<Map<String, List<int>>> _pumpWatching(
  WidgetTester tester,
  Map<String, Finder> watched,
) async {
  final Map<String, List<int>> seen = <String, List<int>>{
    for (final String name in watched.keys) name: <int>[],
  };
  void look(int frame) {
    watched.forEach((String name, Finder finder) {
      if (finder.evaluate().isNotEmpty) {
        seen[name]!.add(frame);
      }
    });
  }

  for (int i = 0; i < 20; i += 1) {
    await tester.pump(
      i == 0 ? Duration.zero : const Duration(milliseconds: 50),
    );
    look(i);
  }
  await tester.pump(const Duration(milliseconds: 400));
  look(20);
  return seen;
}

bool _homeIsCurrent(WidgetTester tester) {
  final Finder home = find.byType(HomeScreen, skipOffstage: false);
  if (home.evaluate().length != 1) {
    return false;
  }
  return ModalRoute.of(tester.element(home))?.isCurrent ?? false;
}

void _expectNotice(
  WidgetTester tester, {
  required Key key,
  required String expected,
  required String scenario,
}) {
  final Finder notice = find.byKey(key);
  expect(
    notice,
    findsOneWidget,
    reason:
        '$scenario: Home must show ${key.toString()} with "$expected"; '
        'notice keys on screen: gone=${find.byKey(_goneNoticeKey, skipOffstage: false).evaluate().length} '
        'closed=${find.byKey(_closedNoticeKey, skipOffstage: false).evaluate().length} '
        'removed=${find.byKey(_removedNoticeKey, skipOffstage: false).evaluate().length}',
  );
  expect(
    tester.widget<Text>(notice).data,
    expected,
    reason:
        '$scenario: the notice must read "$expected"; read '
        '"${tester.widget<Text>(notice).data}"',
  );
  expect(
    find.byKey(_noticeCardKey),
    findsOneWidget,
    reason: '$scenario: the notice must sit in the shared home-notice card',
  );
  final Finder create = find.byKey(_createKey);
  if (create.evaluate().length == 1) {
    expect(
      tester.getTopLeft(notice).dy,
      lessThan(tester.getTopLeft(create).dy),
      reason: '$scenario: the notice takes the slot above create-room-button',
    );
  }
  for (final Key other in <Key>[
    _goneNoticeKey,
    _closedNoticeKey,
    _removedNoticeKey,
  ]) {
    if (other == key) {
      continue;
    }
    expect(
      find.byKey(other, skipOffstage: false),
      findsNothing,
      reason: '$scenario: only one notice may show; also found $other',
    );
  }
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

/// Home, type [_otherCode], tap Join, answer with a two seat lobby for guest
/// seat 1, then drop the socket and tap Reconnect.
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

Future<void> _dropAndReconnect(
  WidgetTester tester,
  _Rig rig,
  String scenario,
  Finder reconnectButton,
) async {
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
  await tester.ensureVisible(reconnectButton);
  await tester.tap(reconnectButton);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  expect(
    rig.transports.length,
    before + 1,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ------------------------------------------------------------------ D1
  group('D1 Go on the name field follows the primary action', () {
    testWidgets('D1a: a code a link filled, the name edited, Go on the name field: '
        'join_room for that code with the edited name, never create_room, and '
        'a vanished room reads in the link\'s terms', (tester) async {
      const String scenario = 'D1a first-time link, edit name, Go';
      final _Rig rig = _Rig();
      await _mount(tester, rig, links: _LinkRig(cold: _linkTo(_linkCode)));

      expect(
        _fieldText(tester, _codeKey),
        _linkCode,
        reason: '$scenario: fixture: the link must fill the code field',
      );
      expect(
        rig.controllers,
        isEmpty,
        reason: '$scenario: fixture: a first-time player is not pushed',
      );

      await tester.enterText(find.byKey(_nameKey), 'Dee');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        rig.sent('create_room'),
        isEmpty,
        reason:
            '$scenario: Go must not open a new room while Join is primary; '
            'sent ${rig.allTypes}',
      );
      final List<String> joins = rig.sent('join_room');
      expect(
        joins,
        hasLength(1),
        reason: '$scenario: Go must send one join_room; sent ${rig.allTypes}',
      );
      expect(
        _dataOf(joins.single),
        <String, Object?>{'code': _linkCode, 'name': 'Dee'},
        reason:
            '$scenario: join_room must carry the link code and the edited '
            'name; sent ${_dataOf(joins.single)}',
      );

      _answerError(rig.last, _idOf(joins.single), 'NO_SUCH_ROOM');
      await _pumpBounded(tester, frames: 3);
      final Finder error = find.byKey(_lobbyErrorKey);
      expect(error, findsOneWidget, reason: '$scenario: lobby-error shows');
      expect(
        find.descendant(
          of: error,
          matching: find.text(_loc(tester).lobbyErrorLinkRoomGone),
        ),
        findsOneWidget,
        reason:
            '$scenario: Go carries the same fromLink value as Join, so the '
            'error reads lobbyErrorLinkRoomGone; texts are '
            '${tester.widgetList<Text>(find.descendant(of: error, matching: find.byType(Text))).map((Text t) => t.data).toList()}',
      );

      await _finish(tester, rig);
    });

    testWidgets(
      'D1b: a valid code the player typed, Go on the name field joins it '
      '(Join is primary) and the typed-code wording is kept',
      (tester) async {
        const String scenario = 'D1b typed code, Go on name';
        final _Rig rig = _Rig();
        await _mount(tester, rig);

        await _typeCode(tester, _otherCode);
        await tester.enterText(find.byKey(_nameKey), 'Eli');
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          rig.sent('create_room'),
          isEmpty,
          reason: '$scenario: no create_room; sent ${rig.allTypes}',
        );
        final List<String> joins = rig.sent('join_room');
        expect(
          joins,
          hasLength(1),
          reason: '$scenario: one join_room; sent ${rig.allTypes}',
        );
        expect(_dataOf(joins.single), <String, Object?>{
          'code': _otherCode,
          'name': 'Eli',
        }, reason: '$scenario: sent ${_dataOf(joins.single)}');

        await _finish(tester, rig);
      },
    );

    testWidgets(
      'D1c: no code in the field, Go on the name field creates; a code that '
      'is not six characters long does not make Join primary',
      (tester) async {
        const String scenario = 'D1c no code and partial code, Go on name';
        final _Rig rig = _Rig();
        await _mount(tester, rig);

        await tester.enterText(find.byKey(_nameKey), 'Dee');
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          rig.sent('join_room'),
          isEmpty,
          reason: '$scenario: no code, no join_room; sent ${rig.allTypes}',
        );
        final List<String> creates = rig.sent('create_room');
        expect(
          creates,
          hasLength(1),
          reason: '$scenario: one create_room; sent ${rig.allTypes}',
        );
        expect(
          _dataOf(creates.single)['name'],
          'Dee',
          reason: '$scenario: create_room carries the typed name',
        );

        await _finish(tester, rig);

        final _Rig partial = _Rig();
        await _mount(tester, partial);
        await tester.enterText(find.byKey(_codeKey), 'AB23C');
        await tester.pump();
        await tester.enterText(find.byKey(_nameKey), 'Dee');
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          partial.sent('join_room'),
          isEmpty,
          reason:
              '$scenario: five characters are not a code to join; sent '
              '${partial.allTypes}',
        );
        expect(
          partial.sent('create_room'),
          hasLength(1),
          reason:
              '$scenario: five characters, Go creates; sent '
              '${partial.allTypes}',
        );
        await _finish(tester, partial);
      },
    );
  });

  // ------------------------------------------------------------------ D2
  group('D2 the name field cannot hold a name the server refuses', () {
    testWidgets(
      'D2a: thirty characters typed or pasted leave 24 UTF-16 units, and a '
      'character typed at the limit changes nothing',
      (tester) async {
        final _Rig rig = _Rig();
        await _mount(tester, rig);
        final String thirty = 'abcdefghij' * 3;

        final String pasted = await _typeName(tester, thirty);
        expect(
          pasted,
          thirty.substring(0, 24),
          reason:
              'D2a paste of 30: the field must hold the first 24 units '
              '"${thirty.substring(0, 24)}"; holds "$pasted" '
              '(${pasted.length} units)',
        );

        final String atLimit = await _typeName(tester, 'x' * 24);
        expect(atLimit, 'x' * 24, reason: 'D2a: exactly 24 units are kept');
        final String typed = await _typeName(tester, '${'x' * 24}y');
        expect(
          typed,
          'x' * 24,
          reason:
              'D2a typing a 25th unit: the field must stay at 24 units; '
              'holds "$typed" (${typed.length} units)',
        );
        await _finish(tester, rig);
      },
    );

    testWidgets('D2b: a paste with a surrogate pair straddling unit 24 is cut before '
        'the pair; a pair that ends exactly at unit 24 is kept whole', (tester) async {
      final _Rig rig = _Rig();
      await _mount(tester, rig);
      const String face = '\u{1F600}';

      final String straddle = await _typeName(tester, '${'a' * 23}${face}bc');
      expect(
        straddle,
        'a' * 23,
        reason:
            'D2b: units 23 and 24 are the two halves of one pair; the cut '
            'must fall before it, leaving 23 units. Holds '
            '${straddle.codeUnits.map((int u) => u.toRadixString(16)).toList()}',
      );
      expect(
        _hasLoneSurrogate(straddle),
        isFalse,
        reason: 'D2b: the field must never hold half a surrogate pair',
      );

      final String whole = await _typeName(tester, '${'a' * 22}${face}bc');
      expect(
        whole,
        '${'a' * 22}$face',
        reason:
            'D2b: a pair ending exactly at unit 24 fits and must be kept '
            'whole; holds ${whole.codeUnits.map((int u) => u.toRadixString(16)).toList()}',
      );
      await _finish(tester, rig);
    });

    testWidgets(
      'D2c: control characters are dropped as they arrive, and the edges of '
      'the refused range are exact',
      (tester) async {
        final _Rig rig = _Rig();
        await _mount(tester, rig);

        expect(
          await _typeName(tester, 'ab\u0007c\u0085d'),
          'abcd',
          reason: 'D2c: BEL (U+0007) and NEL (U+0085) must be dropped',
        );
        expect(
          await _typeName(tester, 'a\u0000b\u001fc\u007fd\u009fe'),
          'abcde',
          reason:
              'D2c: U+0000, U+001F, U+007F and U+009F are all inside '
              '[\\x00-\\x1f\\x7f-\\x9f] and must be dropped',
        );
        expect(
          await _typeName(tester, 'a b~c\u00a0d'),
          'a b~c\u00a0d',
          reason:
              'D2c: U+0020, U+007E and U+00A0 sit just outside the refused '
              'range and must be kept',
        );
        await _finish(tester, rig);
      },
    );

    testWidgets(
      'D2d: whatever is pasted, Create sends a name the server accepts: 1 to '
      '24 units, no control character, nothing that was not pasted',
      (tester) async {
        final _Rig rig = _Rig();
        await _mount(tester, rig);
        final String pasted = 'n${'\u0007' * 3}${'m' * 40}\u0085z';

        await tester.enterText(find.byKey(_nameKey), pasted);
        await tester.pump();
        await _tap(tester, _createKey);

        final List<String> creates = rig.sent('create_room');
        expect(
          creates,
          hasLength(1),
          reason: 'D2d: one create_room; sent ${rig.allTypes}',
        );
        final String sentName = _dataOf(creates.single)['name']! as String;
        expect(
          sentName.length,
          inInclusiveRange(1, 24),
          reason:
              'D2d: the server refuses a name over 24 units with BAD_FIELD; '
              'sent ${sentName.length} units: "$sentName"',
        );
        expect(
          RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(sentName),
          isFalse,
          reason: 'D2d: sent a name with a control character: "$sentName"',
        );
        expect(
          sentName.startsWith('n'),
          isTrue,
          reason: 'D2d: the cut keeps the start of what was pasted',
        );
        expect(
          RegExp(r'^n(m+)(z?)$').hasMatch(sentName),
          isTrue,
          reason: 'D2d: sent text that was not pasted: "$sentName"',
        );
        await _finish(tester, rig);
      },
    );
  });

  // ------------------------------------------------------------------ D3
  group('D3 a room that closed while the player was away', () {
    for (final ({String id, bool host, Locale? locale, String expected}) variant
        in [
          (id: 'D3a', host: true, locale: null, expected: _enHostClosed),
          (
            id: 'D3b',
            host: true,
            locale: const Locale('ar'),
            expected: _arHostClosed,
          ),
          (id: 'D3c', host: false, locale: null, expected: _enGuestClosed),
          (
            id: 'D3d',
            host: false,
            locale: const Locale('ar'),
            expected: _arGuestClosed,
          ),
        ]) {
      testWidgets(
        '${variant.id}: a ${variant.host ? 'host' : 'guest'} lobby that held '
        'a room is answered NO_SUCH_ROOM on reconnect (${variant.locale ?? 'en'}): '
        'the route goes home with home-room-closed-notice, no error body, no '
        'Retry, no second create_room',
        (tester) async {
          final String scenario =
              '${variant.id} ${variant.host ? 'create' : 'join'} lobby, '
              'socket drop, Reconnect answered NO_SUCH_ROOM, locale '
              '${variant.locale ?? 'en'}';
          final _Rig rig = _Rig();
          await _mount(tester, rig, locale: variant.locale);
          if (variant.host) {
            await _hostLobbyAwaitingResume(tester, rig, scenario);
          } else {
            await _guestLobbyAwaitingResume(tester, rig, scenario);
          }
          final int createsBefore = rig.sent('create_room').length;

          _answerError(
            rig.last,
            _idOf(rig.last.sentRaw.single),
            'NO_SUCH_ROOM',
          );
          final Map<String, List<int>> seen = await _pumpWatching(
            tester,
            <String, Finder>{
              'lobby-error': find.byKey(_lobbyErrorKey, skipOffstage: false),
              'lobby-retry-button': find.byKey(_retryKey, skipOffstage: false),
            },
          );

          expect(
            seen['lobby-error'],
            isEmpty,
            reason:
                '$scenario: lobby-error must never be drawn; seen at frames '
                '${seen['lobby-error']}',
          );
          expect(
            seen['lobby-retry-button'],
            isEmpty,
            reason:
                '$scenario: lobby-retry-button must never be drawn; seen at '
                'frames ${seen['lobby-retry-button']}',
          );
          expect(
            _homeIsCurrent(tester),
            isTrue,
            reason: '$scenario: the route must have popped to Home',
          );
          _expectNotice(
            tester,
            key: _closedNoticeKey,
            expected: variant.expected,
            scenario: scenario,
          );
          expect(
            rig.sent('create_room'),
            hasLength(createsBefore),
            reason:
                '$scenario: no path may create a room the player did not ask '
                'for; create_room frames ${rig.sent('create_room').length}, '
                'sent ${rig.allTypes}',
          );

          await _finish(tester, rig);
        },
      );
    }

    testWidgets(
      'D3e: a held room, a failure that is not NO_SUCH_ROOM: Retry never '
      'calls createRoom a second time',
      (tester) async {
        const String scenario =
            'D3e create lobby, Reconnect answered RATE_LIMITED, tap Retry';
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

        final Finder retry = find.byKey(_retryKey);
        if (retry.evaluate().isNotEmpty) {
          await tester.ensureVisible(retry);
          await tester.tap(retry);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(
          rig.sent('create_room'),
          hasLength(1),
          reason:
              '$scenario: once a room code has been issued to this lobby, '
              'Retry must not send create_room again (a new room, a new '
              'code, friends left on the dead link); create_room frames '
              '${rig.sent('create_room').length}, sent ${rig.allTypes}',
        );

        await _finish(tester, rig);
      },
    );

    for (final ({String id, Locale? locale, String expected}) variant in [
      (id: 'D3f', locale: null, expected: _enGameGone),
      (id: 'D3g', locale: const Locale('ar'), expected: _arGameGone),
    ]) {
      testWidgets(
        '${variant.id}: a PLAYING room answered NO_SUCH_ROOM on reconnect '
        '(${variant.locale ?? 'en'}): home with home-game-gone-notice, no end '
        'card in any frame',
        (tester) async {
          final String scenario =
              '${variant.id} PLAYING room, socket drop, Reconnect answered '
              'NO_SUCH_ROOM, locale ${variant.locale ?? 'en'}';
          _seedFreshSeat();
          final _Rig rig = _Rig();
          await _mount(tester, rig, locale: variant.locale);
          expect(
            rig.sent('resume'),
            hasLength(1),
            reason: '$scenario: fixture: a fresh record resumes on its own',
          );
          _answerRoom(
            rig.last,
            rig.lastRequestId('resume'),
            _playingRoom(),
            seat: 0,
          );
          await _pumpBounded(tester, frames: 3);
          expect(
            find.byType(GameScreen),
            findsOneWidget,
            reason: '$scenario: fixture: a PLAYING resume shows GameScreen',
          );
          await _dropAndReconnect(
            tester,
            rig,
            scenario,
            find.byKey(_gameReconnectKey),
          );

          _answerError(
            rig.last,
            _idOf(rig.last.sentRaw.single),
            'NO_SUCH_ROOM',
          );
          final Map<String, List<int>> seen = await _pumpWatching(
            tester,
            <String, Finder>{
              'end-card-rematch-gone': find.byKey(
                _rematchGoneKey,
                skipOffstage: false,
              ),
              'EndCard': find.byType(EndCard, skipOffstage: false),
            },
          );

          expect(
            seen['end-card-rematch-gone'],
            isEmpty,
            reason:
                '$scenario: a PLAYING room is not a finished game; the gone '
                'end card (end-card-rematch-gone) was drawn at frames '
                '${seen['end-card-rematch-gone']}',
          );
          expect(
            seen['EndCard'],
            isEmpty,
            reason:
                '$scenario: no end card of any kind may be drawn; one was on '
                'the tree at frames ${seen['EndCard']}',
          );
          expect(
            _homeIsCurrent(tester),
            isTrue,
            reason: '$scenario: the route must have popped to Home',
          );
          _expectNotice(
            tester,
            key: _goneNoticeKey,
            expected: variant.expected,
            scenario: scenario,
          );

          await _finish(tester, rig);
        },
      );
    }

    testWidgets(
      'D3h: a FINISHED room answered NO_SUCH_ROOM on reconnect keeps today\'s '
      'gone end card and stays on the route (C-316 rule 4, unchanged)',
      (tester) async {
        const String scenario =
            'D3h FINISHED room, socket drop, reconnect answered NO_SUCH_ROOM';
        _seedFreshSeat();
        final _Rig rig = _Rig();
        await _mount(tester, rig);
        _answerRoom(
          rig.last,
          rig.lastRequestId('resume'),
          _finishedRoom(),
          seat: 0,
        );
        await _pumpBounded(tester, frames: 3);
        await _refuseGameLogs(tester, rig.last);
        expect(
          find.byType(EndCard),
          findsOneWidget,
          reason: '$scenario: fixture: a FINISHED resume shows the end card',
        );

        final RoomController controller = rig.controllers.last;
        rig.last.endFromFarSide();
        await tester.pump();
        await tester.pump();
        unawaited(controller.reconnect());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final List<String> resumes = rig.last.sentRaw
            .where((String s) => _typeOf(s) == 'resume')
            .toList();
        expect(
          resumes,
          hasLength(1),
          reason: '$scenario: fixture: reconnect must send one resume',
        );
        _answerError(rig.last, _idOf(resumes.single), 'NO_SUCH_ROOM');
        await _pumpBounded(tester, frames: 3);

        expect(
          find.byKey(_rematchGoneKey),
          findsOneWidget,
          reason:
              '$scenario: a FINISHED room keeps the gone end card; '
              'home is current=${_homeIsCurrent(tester)}',
        );
        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason: '$scenario: the route must stay on GameScreen',
        );
        expect(
          find.byKey(_goneNoticeKey, skipOffstage: false),
          findsNothing,
          reason: '$scenario: no home notice, the player never left',
        );

        await _finish(tester, rig);
      },
    );

    testWidgets(
      'D3i: home-room-closed-notice is a live region, is dismissed with '
      'home-notice-dismiss, and is gone when Create is tapped',
      (tester) async {
        const String scenario =
            'D3i host lobby, NO_SUCH_ROOM on reconnect, then dismiss and Create';
        final SemanticsHandle handle = tester.ensureSemantics();
        try {
          final _Rig rig = _Rig();
          await _mount(tester, rig);
          await _hostLobbyAwaitingResume(tester, rig, scenario);
          _answerError(
            rig.last,
            _idOf(rig.last.sentRaw.single),
            'NO_SUCH_ROOM',
          );
          await _pumpBounded(tester, frames: 6);
          _expectNotice(
            tester,
            key: _closedNoticeKey,
            expected: _enHostClosed,
            scenario: scenario,
          );
          final SemanticsNode node = tester.getSemantics(
            find.byKey(_closedNoticeKey),
          );
          expect(
            node.flagsCollection.isLiveRegion,
            isTrue,
            reason:
                '$scenario: the node holding the notice text (label '
                '"${node.label}") must be a live region, as '
                'home-game-gone-notice is',
          );

          await tester.ensureVisible(
            find.byKey(const Key('home-notice-dismiss')),
          );
          await tester.tap(find.byKey(const Key('home-notice-dismiss')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            find.byKey(_closedNoticeKey, skipOffstage: false),
            findsNothing,
            reason: '$scenario: dismiss must remove the notice',
          );

          await _finish(tester, rig);

          final _Rig again = _Rig();
          await _mount(tester, again);
          await _hostLobbyAwaitingResume(tester, again, scenario);
          _answerError(
            again.last,
            _idOf(again.last.sentRaw.single),
            'NO_SUCH_ROOM',
          );
          await _pumpBounded(tester, frames: 6);
          expect(
            find.byKey(_closedNoticeKey),
            findsOneWidget,
            reason: '$scenario: fixture: the notice shows a second time',
          );
          await _tap(tester, _createKey);
          expect(
            find.byKey(_closedNoticeKey, skipOffstage: false),
            findsNothing,
            reason: '$scenario: tapping Create must hide the notice',
          );
          await _finish(tester, again);
        } finally {
          handle.dispose();
        }
      },
    );
  });

  // ------------------------------------------------------------------ D4
  group('D4 a join that cannot succeed says so and leaves no dead end', () {
    testWidgets('D4a: a first-time friend, code filled by a link and untouched, Join '
        'answered NO_SUCH_ROOM: the link wording, no Retry', (tester) async {
      const String scenario = 'D4a first-time link, untouched, Join, gone';
      final _Rig rig = _Rig();
      await _mount(tester, rig, links: _LinkRig(cold: _linkTo(_linkCode)));
      expect(
        _fieldText(tester, _codeKey),
        _linkCode,
        reason: '$scenario: fixture: the link fills the code field',
      );
      await _tap(tester, _joinKey);
      final List<String> joins = rig.sent('join_room');
      expect(
        joins,
        hasLength(1),
        reason: '$scenario: one join_room; sent ${rig.allTypes}',
      );
      _answerError(rig.last, _idOf(joins.single), 'NO_SUCH_ROOM');
      await _pumpBounded(tester, frames: 3);

      final Finder error = find.byKey(_lobbyErrorKey);
      expect(error, findsOneWidget, reason: '$scenario: lobby-error shows');
      expect(
        find.descendant(
          of: error,
          matching: find.text(_loc(tester).lobbyErrorLinkRoomGone),
        ),
        findsOneWidget,
        reason:
            '$scenario: the Join tap must pass fromLink true, so the error '
            'reads lobbyErrorLinkRoomGone; texts are '
            '${tester.widgetList<Text>(find.descendant(of: error, matching: find.byType(Text))).map((Text t) => t.data).toList()}',
      );
      expect(
        find.byKey(_retryKey),
        findsNothing,
        reason: '$scenario: no Retry',
      );
      await _finish(tester, rig);
    });

    testWidgets('D4b: the link code edited and typed back is a typed code (any edit '
        'makes it typed): the typed-code wording, no Retry', (tester) async {
      const String scenario =
          'D4b first-time link, code edited then restored by typing, Join';
      final _Rig rig = _Rig();
      await _mount(tester, rig, links: _LinkRig(cold: _linkTo(_linkCode)));
      expect(_fieldText(tester, _codeKey), _linkCode);
      await tester.enterText(find.byKey(_codeKey), 'AB23C');
      await tester.pump();
      await _typeCode(tester, _linkCode);
      expect(
        _fieldText(tester, _codeKey),
        _linkCode,
        reason: '$scenario: fixture: the field is back at the link code',
      );
      await _tap(tester, _joinKey);
      final List<String> joins = rig.sent('join_room');
      expect(joins, hasLength(1), reason: '$scenario: one join_room');
      _answerError(rig.last, _idOf(joins.single), 'NO_SUCH_ROOM');
      await _pumpBounded(tester, frames: 3);

      final Finder error = find.byKey(_lobbyErrorKey);
      expect(error, findsOneWidget, reason: '$scenario: lobby-error shows');
      expect(
        find.descendant(
          of: error,
          matching: find.text(_loc(tester).lobbyErrorNoSuchRoom),
        ),
        findsOneWidget,
        reason:
            '$scenario: an edited code counts as typed, so the error reads '
            'lobbyErrorNoSuchRoom; texts are '
            '${tester.widgetList<Text>(find.descendant(of: error, matching: find.byType(Text))).map((Text t) => t.data).toList()}',
      );
      expect(
        find.byKey(_retryKey),
        findsNothing,
        reason: '$scenario: no Retry for NO_SUCH_ROOM on a typed code',
      );
      await _finish(tester, rig);
    });

    // The codes a retry cannot fix, and the ones it can. The first group is
    // red on the base; the second holds there and must keep holding.
    for (final ({String id, String code, bool retry}) row in [
      (id: 'D4c1', code: 'NO_SUCH_ROOM', retry: false),
      (id: 'D4c2', code: 'ROOM_STARTED', retry: false),
      (id: 'D4c3', code: 'BAD_FIELD', retry: false),
      (id: 'D4c4', code: 'ROOM_FULL', retry: true),
      (id: 'D4c5', code: 'RATE_LIMITED', retry: true),
      (id: 'D4c6', code: 'SOMETHING_UNMAPPED', retry: true),
    ]) {
      testWidgets(
        '${row.id}: a typed join answered ${row.code}: lobby-retry-button is '
        '${row.retry ? 'present' : 'absent'}',
        (tester) async {
          final String scenario = '${row.id} typed join answered ${row.code}';
          final _Rig rig = _Rig();
          await _mount(tester, rig);
          await _typeCode(tester, _otherCode);
          await _tap(tester, _joinKey);
          _answerError(rig.last, rig.lastRequestId('join_room'), row.code);
          await _pumpBounded(tester, frames: 3);

          expect(
            find.byKey(_lobbyErrorKey),
            findsOneWidget,
            reason: '$scenario: lobby-error must show',
          );
          expect(
            find.byKey(_retryKey),
            row.retry ? findsOneWidget : findsNothing,
            reason:
                '$scenario: lobby-retry-button must be '
                '${row.retry ? 'present' : 'absent'}',
          );
          expect(
            find.byKey(_lobbyLeaveKey),
            findsOneWidget,
            reason: '$scenario: the way out must stay',
          );
          await _finish(tester, rig);
        },
      );
    }

    testWidgets(
      'D4d: the same holds for a join that came from a link: absent for '
      'NO_SUCH_ROOM, ROOM_STARTED and BAD_FIELD',
      (tester) async {
        for (final String code in <String>[
          'NO_SUCH_ROOM',
          'ROOM_STARTED',
          'BAD_FIELD',
        ]) {
          final String scenario = 'D4d link join answered $code';
          final _Rig rig = _Rig();
          await _mount(tester, rig, links: _LinkRig(cold: _linkTo(_linkCode)));
          await _tap(tester, _joinKey);
          _answerError(rig.last, rig.lastRequestId('join_room'), code);
          await _pumpBounded(tester, frames: 3);
          expect(
            find.byKey(_lobbyErrorKey),
            findsOneWidget,
            reason: '$scenario: lobby-error must show',
          );
          expect(
            find.byKey(_retryKey),
            findsNothing,
            reason: '$scenario: lobby-retry-button must be absent',
          );
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D4e: transport, timeout and closed failures of a join keep Retry',
      (tester) async {
        // transport: the connect itself is refused.
        final _Rig refused = _Rig(rejectFirstConnects: 1);
        await _mount(tester, refused);
        await _typeCode(tester, _otherCode);
        await _tap(tester, _joinKey);
        expect(
          refused.controllers.last.errorCode,
          'transport',
          reason:
              'D4e fixture: a refused connect must land errorCode transport',
        );
        expect(
          find.byKey(_retryKey),
          findsOneWidget,
          reason: 'D4e transport: Retry must be present',
        );
        await _finish(tester, refused);

        // timeout: the server never answers join_room.
        final _Rig silent = _Rig();
        await _mount(tester, silent);
        await _typeCode(tester, _otherCode);
        await _tap(tester, _joinKey);
        await tester.pump(const Duration(seconds: 11));
        await tester.pump();
        expect(
          silent.controllers.last.errorCode,
          'timeout',
          reason:
              'D4e fixture: an unanswered join must time out; errorCode '
              '${silent.controllers.last.errorCode}',
        );
        expect(
          find.byKey(_retryKey),
          findsOneWidget,
          reason: 'D4e timeout: Retry must be present',
        );
        await _finish(tester, silent);

        // closed: the socket goes away while join_room is unanswered.
        final _Rig dropped = _Rig();
        await _mount(tester, dropped);
        await _typeCode(tester, _otherCode);
        await _tap(tester, _joinKey);
        dropped.last.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(
          dropped.controllers.last.errorCode,
          'closed',
          reason:
              'D4e fixture: a socket lost under a join must land errorCode '
              'closed; errorCode ${dropped.controllers.last.errorCode}',
        );
        expect(
          find.byKey(_retryKey),
          findsOneWidget,
          reason: 'D4e closed: Retry must be present',
        );
        await _finish(tester, dropped);
      },
    );

    for (final ({String id, Locale? locale, String expected}) variant in [
      (id: 'D4f', locale: null, expected: _enRoomStarted),
      (id: 'D4g', locale: const Locale('ar'), expected: _arRoomStarted),
    ]) {
      testWidgets('${variant.id}: ROOM_STARTED reads "${variant.expected}" '
          '(${variant.locale ?? 'en'})', (tester) async {
        final String scenario =
            '${variant.id} typed join answered ROOM_STARTED, locale '
            '${variant.locale ?? 'en'}';
        final _Rig rig = _Rig();
        await _mount(tester, rig, locale: variant.locale);
        await _typeCode(tester, _otherCode);
        await _tap(tester, _joinKey);
        _answerError(rig.last, rig.lastRequestId('join_room'), 'ROOM_STARTED');
        await _pumpBounded(tester, frames: 3);

        final Finder error = find.byKey(_lobbyErrorKey);
        expect(error, findsOneWidget, reason: '$scenario: lobby-error shows');
        expect(
          find.descendant(of: error, matching: find.text(variant.expected)),
          findsOneWidget,
          reason:
              '$scenario: lobby-error must read "${variant.expected}"; '
              'texts are '
              '${tester.widgetList<Text>(find.descendant(of: error, matching: find.byType(Text))).map((Text t) => t.data).toList()}',
        );
        await _finish(tester, rig);
      });
    }

    for (final ({String id, Locale? locale, String expected}) variant in [
      (id: 'D4h', locale: null, expected: _enBackHome),
      (id: 'D4i', locale: const Locale('ar'), expected: _arBackHome),
    ]) {
      testWidgets(
        '${variant.id}: the error body of a lobby that never held a seat says '
        '"${variant.expected}" on lobby-leave-button '
        '(${variant.locale ?? 'en'}), for a failed join and a failed create',
        (tester) async {
          final String scenario =
              '${variant.id} never-seated error body, locale '
              '${variant.locale ?? 'en'}';
          final _Rig join = _Rig();
          await _mount(tester, join, locale: variant.locale);
          await _typeCode(tester, _otherCode);
          await _tap(tester, _joinKey);
          _answerError(
            join.last,
            join.lastRequestId('join_room'),
            'NO_SUCH_ROOM',
          );
          await _pumpBounded(tester, frames: 3);
          _expectLeaveLabel(tester, variant.expected, '$scenario (join)');
          await _finish(tester, join);

          final _Rig create = _Rig(rejectFirstConnects: 1);
          await _mount(tester, create, locale: variant.locale);
          await _tap(tester, _createKey);
          expect(
            find.byKey(_lobbyErrorKey),
            findsOneWidget,
            reason: '$scenario (create): fixture: a refused connect fails',
          );
          _expectLeaveLabel(tester, variant.expected, '$scenario (create)');
          await _finish(tester, create);
        },
      );
    }

    testWidgets(
      'D4j: an error body reached with a seat in hand keeps the Leave label',
      (tester) async {
        const String scenario =
            'D4j create lobby, Reconnect answered RATE_LIMITED';
        final _Rig rig = _Rig();
        await _mount(tester, rig);
        await _hostLobbyAwaitingResume(tester, rig, scenario);
        _answerError(rig.last, _idOf(rig.last.sentRaw.single), 'RATE_LIMITED');
        await _pumpBounded(tester, frames: 3);
        expect(
          find.byKey(_lobbyErrorKey),
          findsOneWidget,
          reason: '$scenario: fixture: the error body shows',
        );
        _expectLeaveLabel(tester, _loc(tester).gameLeaveButton, scenario);
        await _finish(tester, rig);
      },
    );

    for (final String code in <String>['NO_SUCH_ROOM', 'ROOM_STARTED']) {
      for (final bool fromLink in <bool>[false, true]) {
        testWidgets('D4k: back home after a ${fromLink ? 'link' : 'typed'} join '
            'answered $code: code field empty, Join gone, Create primary, and '
            'the link state is gone with it', (tester) async {
          final String scenario =
              'D4k ${fromLink ? 'link' : 'typed'} join answered $code, Back '
              'to home';
          final _Rig rig = _Rig();
          await _mount(
            tester,
            rig,
            links: fromLink ? _LinkRig(cold: _linkTo(_linkCode)) : null,
          );
          if (!fromLink) {
            await _typeCode(tester, _linkCode);
          }
          await _tap(tester, _joinKey);
          _answerError(rig.last, rig.lastRequestId('join_room'), code);
          await _pumpBounded(tester, frames: 3);
          expect(
            find.byKey(_lobbyErrorKey),
            findsOneWidget,
            reason: '$scenario: fixture: lobby-error shows',
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
                '$scenario: the dead code must not stay in the field; '
                'holds "${_fieldText(tester, _codeKey)}"',
          );
          expect(
            find.byKey(_joinKey, skipOffstage: false),
            findsNothing,
            reason: '$scenario: Join must be gone with the code',
          );
          expect(
            tester.widget(find.byKey(_createKey)),
            isA<ElevatedButton>(),
            reason:
                '$scenario: Create must be primary again; it is a '
                '${tester.widget(find.byKey(_createKey)).runtimeType}',
          );

          // The link state went with the code: the same code typed again
          // is a typed code.
          await _typeCode(tester, _linkCode);
          await _tap(tester, _joinKey);
          _answerError(
            rig.last,
            rig.lastRequestId('join_room'),
            'NO_SUCH_ROOM',
          );
          await _pumpBounded(tester, frames: 3);
          final Finder error = find.byKey(_lobbyErrorKey);
          expect(
            find.descendant(
              of: error,
              matching: find.text(_loc(tester).lobbyErrorNoSuchRoom),
            ),
            findsOneWidget,
            reason:
                '$scenario: the code typed after going home is a typed '
                'code; texts are '
                '${tester.widgetList<Text>(find.descendant(of: error, matching: find.byType(Text))).map((Text t) => t.data).toList()}',
          );
          await _finish(tester, rig);
        });
      }
    }
  });

  // ------------------------------------------------------------------ D5
  group('D5 the connection-lost card never prints the server\'s own words', () {
    for (final ({String id, Locale locale}) variant in [
      (id: 'D5a', locale: const Locale('en')),
      (id: 'D5b', locale: const Locale('ar')),
    ]) {
      testWidgets(
        '${variant.id}: a generic-line code (INTERNAL) with the server\'s English message '
        '(${variant.locale}): the English text is nowhere in the tree and '
        'game-screen-error-message is absent',
        (tester) async {
          final String scenario =
              '${variant.id} roll answered $_genericCode '
              '"$_serverEnglish", locale ${variant.locale}';
          final controller = await _failedPlaying(
            tester,
            code: _genericCode,
            message: _serverEnglish,
            locale: variant.locale,
            scenario: scenario,
          );
          expect(
            controller.errorMessage,
            _serverEnglish,
            reason: '$scenario: fixture: the controller holds the message',
          );
          expect(
            find.byKey(_connectionLostKey),
            findsOneWidget,
            reason: '$scenario: fixture: the connection-lost card shows',
          );
          expect(
            find.textContaining(_serverEnglish, skipOffstage: false),
            findsNothing,
            reason: '$scenario: the server\'s message must be rendered nowhere',
          );
          expect(
            find.byKey(_errorMessageKey, skipOffstage: false),
            findsNothing,
            reason:
                '$scenario: $_genericCode maps to the generic line, so '
                'game-screen-error-message and its gap must be absent',
          );
        },
      );
    }

    testWidgets('D5c: an empty server message leaves no empty line under '
        '"Connection lost."', (tester) async {
      const String scenario = 'D5c roll answered $_genericCode, message ""';
      await _failedPlaying(
        tester,
        code: _genericCode,
        message: '',
        scenario: scenario,
      );
      expect(
        find.byKey(_errorMessageKey, skipOffstage: false),
        findsNothing,
        reason: '$scenario: an empty Text must not be drawn',
      );
    });

    for (final ({String id, Locale locale}) variant in [
      (id: 'D5d', locale: const Locale('en')),
      (id: 'D5e', locale: const Locale('ar')),
    ]) {
      testWidgets(
        '${variant.id}: code transport shows the localised transport line '
        '(${variant.locale}) in game-screen-error-message, never the '
        'server\'s message',
        (tester) async {
          final String scenario =
              '${variant.id} roll answered transport, locale ${variant.locale}';
          const String serverWords = 'socket reset by peer';
          await _failedPlaying(
            tester,
            code: 'transport',
            message: serverWords,
            locale: variant.locale,
            scenario: scenario,
          );
          final Finder line = find.byKey(_errorMessageKey);
          expect(
            line,
            findsOneWidget,
            reason: '$scenario: game-screen-error-message must show',
          );
          expect(
            tester.widget<Text>(line).data,
            _loc(tester).lobbyErrorTransport,
            reason:
                '$scenario: the line must be lobbyErrorTransport; reads '
                '"${tester.widget<Text>(line).data}"',
          );
          expect(
            find.textContaining(serverWords, skipOffstage: false),
            findsNothing,
            reason: '$scenario: the server\'s message must not be drawn',
          );
        },
      );
    }

    testWidgets(
      'D5f: a code that maps to the generic line shows no error line at all',
      (tester) async {
        const String scenario = 'D5f roll answered SERVER_GONE';
        await _failedPlaying(
          tester,
          code: 'SERVER_GONE',
          message: 'internal fault 7',
          scenario: scenario,
        );
        expect(
          find.byKey(_errorMessageKey, skipOffstage: false),
          findsNothing,
          reason: '$scenario: the generic line is never worth a second line',
        );
        expect(
          find.textContaining('internal fault 7', skipOffstage: false),
          findsNothing,
          reason: '$scenario: the server\'s message must not be drawn',
        );
      },
    );

    test('D5g: controller.errorMessage is read by no widget code, only by '
        'lib/src/net', () {
      final Directory src = Directory('lib/src');
      expect(
        src.existsSync(),
        isTrue,
        reason:
            'D5g fixture: run from the package root; cwd is '
            '${Directory.current.path}',
      );
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in src.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        if (entity.path.contains(
          '${Platform.pathSeparator}net${Platform.pathSeparator}',
        )) {
          continue;
        }
        final List<String> lines = entity.readAsLinesSync();
        for (int i = 0; i < lines.length; i += 1) {
          final String line = lines[i];
          if (line.trimLeft().startsWith('//')) {
            continue;
          }
          if (line.contains('errorMessage')) {
            offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'D5g: the server\'s English message must never be rendered; '
            'these lines outside lib/src/net still read errorMessage:\n'
            '${offenders.join('\n')}',
      );
    });
  });

  // ------------------------------------------------------------------ D6
  group('D6 a finished game reached by a resume does not say "No rolls"', () {
    for (final ({String id, Locale locale}) variant in [
      (id: 'D6a', locale: const Locale('en')),
      (id: 'D6b', locale: const Locale('ar')),
    ]) {
      testWidgets(
        '${variant.id}: an end card from a FINISHED snapshot with no rolls '
        '(${variant.locale}) carries neither the roll heading nor the empty '
        'line',
        (tester) async {
          final String scenario =
              '${variant.id} FINISHED resume, no rolls, locale '
              '${variant.locale}';
          final (RoomController controller, FakeTransport transport) =
              await _resumeInto(tester, _finishedRoom());
          await _mountGame(tester, controller, variant.locale);
          await _refuseGameLogs(tester, transport);

          final AppLocalizations loc = _loc(tester);
          expect(
            find.byType(EndCard),
            findsOneWidget,
            reason: '$scenario: fixture: the end card shows',
          );
          expect(
            find.text(loc.gameRollHistoryHeading, skipOffstage: false),
            findsNothing,
            reason:
                '$scenario: "${loc.gameRollHistoryHeading}" heads a block '
                'that has nothing to list',
          );
          expect(
            find.text(loc.gameRollHistoryEmpty, skipOffstage: false),
            findsNothing,
            reason:
                '$scenario: "${loc.gameRollHistoryEmpty}" is false of a '
                'game that was played',
          );
        },
      );
    }

    testWidgets(
      'D6c: a rematch lobby showing the last game, with no rolls, carries '
      'neither line either',
      (tester) async {
        const String scenario = 'D6c FINISHED resume then rematch LOBBY';
        final (RoomController controller, FakeTransport transport) =
            await _resumeInto(tester, _finishedRoom());
        await _mountGame(tester, controller, const Locale('en'));
        await _refuseGameLogs(tester, transport);
        transport.pushText(
          _frame(
            type: 'room',
            data: _roomJson(
              state: 'LOBBY',
              seq: 10,
              chainIndex: 1,
              rematch: const <String, Object?>{
                'by': 1,
                'ready': <int>[1],
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          controller.room!.state.name,
          'lobby',
          reason: '$scenario: fixture: the room is now a rematch LOBBY',
        );
        expect(
          controller.lastFinished,
          isNotNull,
          reason: '$scenario: fixture: the finished game is kept',
        );
        expect(
          find.byType(EndCard),
          findsOneWidget,
          reason: '$scenario: fixture: the end card still shows',
        );

        final AppLocalizations loc = _loc(tester);
        expect(
          find.text(loc.gameRollHistoryHeading, skipOffstage: false),
          findsNothing,
          reason: '$scenario: no roll heading',
        );
        expect(
          find.text(loc.gameRollHistoryEmpty, skipOffstage: false),
          findsNothing,
          reason: '$scenario: no empty roll line',
        );
      },
    );

    testWidgets(
      'D6d (control, holds on the base): a game played to the end with its '
      'rolls seen keeps the heading and lists them',
      (tester) async {
        const String scenario = 'D6d played game, rolls seen, FINISHED';
        final (RoomController controller, FakeTransport transport) =
            await _resumeInto(tester, _playingRoom());
        await _mountGame(tester, controller, const Locale('en'));
        int seq = 3;
        Future<void> push(String type, Map<String, Object?> data) async {
          seq += 1;
          transport.pushText(
            _frame(type: type, data: <String, Object?>{...data, 'seq': seq}),
          );
          await tester.pump();
          await tester.pump();
        }

        for (final (int k, int face) in <(int, int)>[(1, 4), (2, 6), (3, 2)]) {
          await push('rolled', <String, Object?>{
            'seat': 0,
            'value': face,
            'legal': const <int>[0],
            'deadline_ms': 45000,
            'k': k,
            'reveal': 'c' * 64,
          });
        }
        await push('game_over', <String, Object?>{
          'winner': 0,
          'verify_url': _verifyUrl,
        });
        await tester.pump(kEndCardHoldLimit);
        await tester.pump();
        await _refuseGameLogs(tester, transport);

        final AppLocalizations loc = _loc(tester);
        expect(
          controller.room!.state.name,
          'finished',
          reason: '$scenario: fixture: the game is over',
        );
        expect(
          find.text(loc.gameRollHistoryHeading, skipOffstage: false),
          findsOneWidget,
          reason: '$scenario: three rolls were seen, the heading must stay',
        );
        expect(
          find.text(loc.gameRollHistoryEntry(3, 2), skipOffstage: false),
          findsOneWidget,
          reason: '$scenario: the last roll (k 3, face 2) must be listed',
        );
        expect(
          find.text(loc.gameRollHistoryEmpty, skipOffstage: false),
          findsNothing,
          reason: '$scenario: rolls exist, so no empty line',
        );
      },
    );
  });
}

bool _hasLoneSurrogate(String text) {
  final List<int> units = text.codeUnits;
  for (int i = 0; i < units.length; i += 1) {
    final int u = units[i];
    final bool high = u >= 0xD800 && u <= 0xDBFF;
    final bool low = u >= 0xDC00 && u <= 0xDFFF;
    if (high &&
        (i + 1 >= units.length ||
            units[i + 1] < 0xDC00 ||
            units[i + 1] > 0xDFFF)) {
      return true;
    }
    if (low && (i == 0 || units[i - 1] < 0xD800 || units[i - 1] > 0xDBFF)) {
      return true;
    }
  }
  return false;
}

/// Enters [text] into the name field in one step, the way a paste lands, and
/// returns what the field holds.
Future<String> _typeName(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(_nameKey), text);
  await tester.pump();
  return _fieldText(tester, _nameKey);
}

void _expectLeaveLabel(WidgetTester tester, String expected, String scenario) {
  final Finder button = find.byKey(_lobbyLeaveKey);
  expect(
    button,
    findsOneWidget,
    reason: '$scenario: lobby-leave-button must be on screen',
  );
  final Finder label = find.descendant(
    of: find.byKey(_lobbyErrorKey),
    matching: find.text(expected),
  );
  expect(
    label,
    findsOneWidget,
    reason:
        '$scenario: lobby-leave-button must read "$expected"; the texts in '
        'lobby-error are '
        '${tester.widgetList<Text>(find.descendant(of: find.byKey(_lobbyErrorKey), matching: find.byType(Text))).map((Text t) => t.data).toList()}',
  );
}

/// Answers every game_log already sent on [transport], so the end card's own
/// stats fetch is not left waiting on the ten second timeout.
Future<void> _refuseGameLogs(
  WidgetTester tester,
  FakeTransport transport,
) async {
  final List<String> ids = <String>[
    for (final String raw in transport.sentRaw)
      if (_typeOf(raw) == 'game_log') _idOf(raw),
  ];
  for (final String id in ids) {
    if (transport.isClosed) {
      break;
    }
    _answerError(transport, id, 'RATE_LIMITED', message: 'game_log');
  }
  await tester.pump();
  await tester.pump();
}

// --- direct GameScreen rigs (D5, D6) --------------------------------------

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

/// A controller resumed into [room] as seat 0, through the real request path.
Future<(RoomController, FakeTransport)> _resumeInto(
  WidgetTester tester,
  Map<String, Object?> room,
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
    seat: 0,
    seatToken: _token,
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  _answerRoom(transport, _idOf(transport.sentRaw.last), room, seat: 0);
  await future;
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture is broken: the resume must land connected; phase '
        '${controller.phase}, error ${controller.errorCode}',
  );
  return (controller, transport);
}

Future<void> _mountGame(
  WidgetTester tester,
  RoomController controller,
  Locale locale,
) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: GameScreen(controller: controller),
    ),
  );
  await tester.pump();
}

/// A PLAYING room whose roll was answered with an error [code] and
/// [message]: the controller is failed with the room still in hand, and
/// GameScreen is mounted on it.
Future<RoomController> _failedPlaying(
  WidgetTester tester, {
  required String code,
  required String message,
  required String scenario,
  Locale locale = const Locale('en'),
}) async {
  final (RoomController controller, FakeTransport transport) =
      await _resumeInto(tester, _playingRoom());
  unawaited(controller.roll());
  await tester.pump();
  _answerError(
    transport,
    _idOf(transport.sentRaw.last),
    code,
    message: message,
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.failed,
    reason:
        '$scenario: fixture: the error reply must fail roll(); phase '
        '${controller.phase}, errorCode ${controller.errorCode}',
  );
  expect(controller.errorCode, code, reason: '$scenario: fixture: errorCode');
  await _mountGame(tester, controller, locale);
  return controller;
}

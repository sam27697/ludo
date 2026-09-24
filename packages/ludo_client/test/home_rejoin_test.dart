// Proof of order 175's contract H1..H6 (work/ludo/orders/175-home-rejoin-seat.md),
// pinned verbatim by order 176. Written against that frozen text and against
// the S1..S6 and R1..R5 contracts it is built on (orders 172 and 170), not
// against home_screen.dart's body.
//
// Home is mounted with a mock SharedPreferences store and a controller
// factory over FakeTransport, the same approach test/home_session_memory_test.dart
// uses; every helper below is this file's own copy, not an import from that
// file.
//
// Three things repeatedly cost this project a night and are guarded here:
//   - one pumpWidget per testWidgets body (a second mount reuses the element
//     and measures the first mount twice);
//   - pumpAndSettle is only ever called while HomeScreen is the only route on
//     screen. Once a tap can push LobbyScreen or GameScreen, every pump below
//     is bounded, because LobbyScreen's connecting state and GameScreen's
//     countdown both hold a ticker that reschedules a frame forever;
//   - a request left answered only by the widget tree's own teardown, not by
//     an explicit flush inside the test body, fails with "A Timer is still
//     pending" -- every outstanding request timer this file leaves armed on
//     purpose (W-7's leave_room, W-9's second resume) is flushed past its
//     10-second RoomConnection timeout before the test ends.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomState;
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _rejoinKey = Key('home-rejoin-button');
const Key _nameKey = Key('home-name-field');
const Key _codeKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');
const Key _retryKey = Key('lobby-retry-button');
const Key _lobbyRoomCodeKey = Key('lobby-room-code');

const String _testUrl = 'wss://home-rejoin-test.invalid/ws';
const String _seatPrefsKey = 'session.seat';

// The order's own fixture code for a stored record: "a stored record for
// code K7M2QP" (W-2), reused everywhere a stored record is needed so every
// case exercises the same shape.
const String _kCode = 'K7M2QP';
const int _kSeat = 2;
const String _kToken = 'tok-rejoin-seed-001';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'rejoin-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
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
  required String code,
  String state = 'LOBBY',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
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
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': state == 'LOBBY' ? null : 'g' * 16,
  'client_seeds': state == 'LOBBY' ? null : '0:seed',
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'verify_url': ?verifyUrl,
  'seq': seq,
};

/// Hands out a fresh [RoomController] wired to a fresh [FakeTransport] on
/// every call, remembering both in call order. The ordinary factory used by
/// every case except W-9, which needs its single controller's connector to
/// behave differently across its own two calls.
class _RecordingControllerFactory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }

  void disposeAll() {
    for (final RoomController controller in controllers) {
      controller.dispose();
    }
  }
}

/// W-9's connector: its first call rejects, the shape
/// RoomConnection.open's own connector-failure branch maps to errorCode
/// 'transport' (_openAndAttach, room_controller.dart); every call after
/// that succeeds and hands back a fresh, remembered [FakeTransport].
class _FlakyThenOkConnector {
  final List<FakeTransport> transports = <FakeTransport>[];
  int calls = 0;

  Future<FakeTransport> call(Uri url) async {
    calls += 1;
    if (calls == 1) {
      throw StateError(
        'home_rejoin_test.dart W-9 fixture: the first connect attempt must '
        'reject, standing in for a transport that would not open',
      );
    }
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    return transport;
  }
}

/// A [RoomControllerFactory] that builds exactly one controller, wired to
/// [connector], and remembers it.
class _SingleFlakyControllerFactory {
  final _FlakyThenOkConnector connector = _FlakyThenOkConnector();
  RoomController? controller;

  RoomController call() {
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
    );
    controller = created;
    return created;
  }
}

Widget _homeScreenApp(
  RoomControllerFactory controllerFactory, {
  Locale? locale,
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
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

AppLocalizations _loc(WidgetTester tester) {
  return AppLocalizations.of(tester.element(find.byType(Scaffold)));
}

/// Taps [buttonKey] and pumps just long enough for a pushed
/// MaterialPageRoute's transition to finish and the pushed route's first
/// screen to mount, without ever calling pumpAndSettle: LobbyScreen's
/// connecting state holds a ticking CircularProgressIndicator that
/// pumpAndSettle would chase forever (lesson 10).
Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.ensureVisible(find.byKey(buttonKey));
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pops the currently pushed route (whatever screen is on top) and pumps
/// just long enough for the pop transition to finish. Mirrors
/// test/home_screen_test.dart's own `_popPushedRoute`.
Future<void> _popPushedRoute(WidgetTester tester, Finder topRouteFinder) async {
  final BuildContext context = tester.element(topRouteFinder);
  Navigator.of(context).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Advances the clock eleven seconds past RoomConnection's ten-second
/// request timeout and pumps once more, so a request this test deliberately
/// never answers does not leave a Timer pending when the test ends.
Future<void> _flushAnyOutstandingRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

/// Lets an unawaited SessionMemory write finish before the caller reads the
/// store back. Neither `recordSeat` nor `clearSeat` schedules a real Timer,
/// so a couple of ordinary pumps -- not runAsync/pumpEventQueue -- are
/// enough, the same allowance test/home_session_memory_test.dart's own
/// `_hostThenRelaunchHome` makes for `recordSuccessfulCreate`.
Future<void> _letStoreWriteSettle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<List<String>?> _storedSeat() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(_seatPrefsKey);
}

/// Taps home-rejoin-button on an already-mounted Home with exactly one
/// stored record ([_kCode], [_kSeat], [_kToken]), then asserts H4/H5: one
/// controller built, and the first (and, at the point this returns, only)
/// frame on the wire is `resume` carrying that code and token. Returns the
/// id of that request so the caller can answer it.
Future<String> _tapRejoinAndCaptureResumeId(
  WidgetTester tester,
  _RecordingControllerFactory factory,
) async {
  await _tapAndAwaitPushedRoute(tester, _rejoinKey);

  expect(
    factory.controllers,
    hasLength(1),
    reason:
        'H4: tapping home-rejoin-button must build exactly one controller '
        'through widget.controllerFactory; built ${factory.controllers.length}',
  );
  final FakeTransport transport = factory.transports.single;

  expect(
    transport.sentRaw,
    hasLength(1),
    reason:
        'H4/H5: tapping home-rejoin-button must put exactly one frame on '
        'the wire before any reply; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );
  final String onlyFrame = transport.sentRaw.single;
  expect(
    _typeOf(onlyFrame),
    'resume',
    reason:
        'H5: LobbyAction.resume must send resume, not "${_typeOf(onlyFrame)}"',
  );
  expect(
    _dataOf(onlyFrame),
    <String, Object?>{'code': _kCode, 'seat_token': _kToken},
    reason:
        'H5: resume must carry the stored code ("$_kCode") and token '
        '("$_kToken") verbatim; sent ${_dataOf(onlyFrame)}',
  );
  expect(
    transport.sentRaw.any((String s) => _typeOf(s) == 'join_room'),
    isFalse,
    reason: 'H5: a resume tap must never send join_room',
  );
  expect(
    transport.sentRaw.any((String s) => _typeOf(s) == 'create_room'),
    isFalse,
    reason: 'H5: a resume tap must never send create_room',
  );

  return _idOf(onlyFrame);
}

/// Joins a room through the normal Join flow (W-5's own path): types [code]
/// in room-code-field, taps Join, and answers with `seat_assigned` naming
/// [seat]/[token] followed by the `room` reply, landing on a connected
/// LobbyScreen. Waits long enough for H1's unawaited SessionMemory.recordSeat
/// write to finish before returning.
Future<({RoomController controller, FakeTransport transport})>
_joinSuccessfully(
  WidgetTester tester,
  _RecordingControllerFactory factory, {
  required String code,
  required int seat,
  required String token,
}) async {
  await tester.enterText(find.byKey(_codeKey), code);
  await _tapAndAwaitPushedRoute(tester, _joinKey);

  final RoomController controller = factory.controllers.single;
  final FakeTransport transport = factory.transports.single;
  final List<String> joinMessages = transport.sentRaw
      .where((String s) => _typeOf(s) == 'join_room')
      .toList();
  expect(
    joinMessages,
    hasLength(1),
    reason:
        'fixture is broken: Join Room must have sent exactly one join_room '
        'request; sent ${transport.sentRaw.map(_typeOf).toList()}',
  );
  final String joinId = _idOf(joinMessages.single);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': seat, 'seat_token': token},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: joinId,
      data: _roomJson(
        code: code,
        state: 'LOBBY',
        hostSeat: 0,
        players: 4,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Host'),
          if (seat != 0) _seatJson(seat, name: 'Rejoiner'),
        ],
        seq: 1,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    find.byKey(_lobbyRoomCodeKey),
    findsOneWidget,
    reason:
        'fixture is broken: seat_assigned + room must land on a connected '
        'lobby before this helper returns',
  );

  await _letStoreWriteSettle(tester);

  return (controller: controller, transport: transport);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('W-1 (control): empty store shows no home-rejoin-button', (
    tester,
  ) async {
    final _RecordingControllerFactory factory = _RecordingControllerFactory();
    addTearDown(factory.disposeAll);

    await tester.pumpWidget(_homeScreenApp(factory.call));
    await tester.pumpAndSettle();

    expect(
      find.byKey(_rejoinKey),
      findsNothing,
      reason:
          'W-1: with nothing stored, home-rejoin-button must not be on '
          'screen; SessionMemory.load().seatRecord must be null on an '
          'empty store',
    );
  });

  testWidgets('W-2en: a stored record for code K7M2QP shows the rejoin button, '
      'labelled in English, above home-name-field', (tester) async {
    await SessionMemory.recordSeat(
      const SeatRecord(code: _kCode, seat: _kSeat, seatToken: _kToken),
    );
    final _RecordingControllerFactory factory = _RecordingControllerFactory();
    addTearDown(factory.disposeAll);

    await tester.pumpWidget(_homeScreenApp(factory.call));
    await tester.pumpAndSettle();

    expect(
      find.byKey(_rejoinKey),
      findsOneWidget,
      reason:
          'W-2en: a stored record for "$_kCode" must show '
          'home-rejoin-button',
    );

    final AppLocalizations loc = _loc(tester);
    expect(
      loc.localeName,
      'en',
      reason: 'fixture is broken: this case must be in English',
    );
    final String expectedLabel = loc.homeRejoinButton(_kCode);
    expect(
      find.descendant(
        of: find.byKey(_rejoinKey),
        matching: find.text(expectedLabel),
      ),
      findsOneWidget,
      reason:
          'W-2en: home-rejoin-button\'s label must read '
          'homeRejoinButton("$_kCode") in English ("$expectedLabel")',
    );

    final double buttonTop = tester.getTopLeft(find.byKey(_rejoinKey)).dy;
    final double nameFieldTop = tester.getTopLeft(find.byKey(_nameKey)).dy;
    expect(
      buttonTop,
      lessThan(nameFieldTop),
      reason:
          'H3: home-rejoin-button must be the first control of the form '
          'column, above home-name-field; button top $buttonTop, '
          'home-name-field top $nameFieldTop',
    );
  });

  testWidgets('W-2ar: a stored record for code K7M2QP shows the rejoin button, '
      'labelled in Arabic, above home-name-field', (tester) async {
    await SessionMemory.recordSeat(
      const SeatRecord(code: _kCode, seat: _kSeat, seatToken: _kToken),
    );
    final _RecordingControllerFactory factory = _RecordingControllerFactory();
    addTearDown(factory.disposeAll);

    await tester.pumpWidget(
      _homeScreenApp(factory.call, locale: const Locale('ar')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(_rejoinKey),
      findsOneWidget,
      reason:
          'W-2ar: a stored record for "$_kCode" must show '
          'home-rejoin-button',
    );

    final AppLocalizations loc = _loc(tester);
    expect(
      loc.localeName,
      'ar',
      reason: 'fixture is broken: this case must be in Arabic',
    );
    final String expectedLabel = loc.homeRejoinButton(_kCode);
    expect(
      find.descendant(
        of: find.byKey(_rejoinKey),
        matching: find.text(expectedLabel),
      ),
      findsOneWidget,
      reason:
          'W-2ar: home-rejoin-button\'s label must read '
          'homeRejoinButton("$_kCode") in Arabic ("$expectedLabel")',
    );

    final double buttonTop = tester.getTopLeft(find.byKey(_rejoinKey)).dy;
    final double nameFieldTop = tester.getTopLeft(find.byKey(_nameKey)).dy;
    expect(
      buttonTop,
      lessThan(nameFieldTop),
      reason:
          'H3: home-rejoin-button must be the first control of the form '
          'column, above home-name-field, in Arabic too; button top '
          '$buttonTop, home-name-field top $nameFieldTop',
    );
  });

  testWidgets(
    'W-3 tap (H4, H5): tapping home-rejoin-button sends resume once and a '
    'PLAYING reply shows GameScreen',
    (tester) async {
      await SessionMemory.recordSeat(
        const SeatRecord(code: _kCode, seat: _kSeat, seatToken: _kToken),
      );
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      addTearDown(factory.disposeAll);

      await tester.pumpWidget(_homeScreenApp(factory.call));
      await tester.pumpAndSettle();

      final String resumeId = await _tapRejoinAndCaptureResumeId(
        tester,
        factory,
      );
      final FakeTransport transport = factory.transports.single;

      transport.pushText(
        _frame(
          type: 'room',
          re: resumeId,
          data: _roomJson(
            code: _kCode,
            state: 'PLAYING',
            hostSeat: 0,
            players: 2,
            seats: <Map<String, Object?>>[
              _seatJson(0, name: 'Host'),
              _seatJson(_kSeat, name: 'Rejoiner'),
            ],
            turn: <String, Object?>{
              'seat': 0,
              'phase': 'await_roll',
              'deadline_ms': 45000,
              'k': 0,
            },
            seq: 5,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason:
            'H6: a PLAYING snapshot answering resume must show GameScreen; '
            'resume was for code "$_kCode" seat $_kSeat',
      );
      expect(
        transport.sentRaw.any((String s) => _typeOf(s) == 'join_room'),
        isFalse,
        reason: 'H5: still no join_room after the PLAYING reply',
      );
      expect(
        transport.sentRaw.any((String s) => _typeOf(s) == 'create_room'),
        isFalse,
        reason: 'H5: still no create_room after the PLAYING reply',
      );
    },
  );

  testWidgets(
    'W-4 lobby (H6): a LOBBY reply to resume shows the connected lobby with '
    'the stored room code',
    (tester) async {
      await SessionMemory.recordSeat(
        const SeatRecord(code: _kCode, seat: _kSeat, seatToken: _kToken),
      );
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      addTearDown(factory.disposeAll);

      await tester.pumpWidget(_homeScreenApp(factory.call));
      await tester.pumpAndSettle();

      final String resumeId = await _tapRejoinAndCaptureResumeId(
        tester,
        factory,
      );
      final FakeTransport transport = factory.transports.single;

      transport.pushText(
        _frame(
          type: 'room',
          re: resumeId,
          data: _roomJson(
            code: _kCode,
            state: 'LOBBY',
            hostSeat: 0,
            players: 4,
            seats: <Map<String, Object?>>[
              _seatJson(0, name: 'Host'),
              _seatJson(_kSeat, name: 'Rejoiner'),
            ],
            seq: 2,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byType(LobbyScreen),
        findsOneWidget,
        reason: 'H6: a LOBBY snapshot answering resume must show LobbyScreen',
      );
      expect(
        find.byType(GameScreen),
        findsNothing,
        reason: 'H6: a LOBBY reply must not show GameScreen',
      );
      final Text codeText = tester.widget<Text>(find.byKey(_lobbyRoomCodeKey));
      expect(
        codeText.data,
        _kCode,
        reason:
            'H6: the connected lobby must show the resumed room\'s own '
            'code "$_kCode"; showed "${codeText.data}"',
      );
    },
  );

  testWidgets("W-5 write (H1): a successful join stores session.seat with the "
      "server's own code, seat and token", (tester) async {
    final _RecordingControllerFactory factory = _RecordingControllerFactory();
    addTearDown(factory.disposeAll);

    await tester.pumpWidget(_homeScreenApp(factory.call));
    await tester.pumpAndSettle();

    await _joinSuccessfully(
      tester,
      factory,
      code: 'AB23CD',
      seat: 3,
      token: 'tok-w5-001',
    );

    final List<String>? stored = await _storedSeat();
    expect(
      stored,
      <String>['AB23CD', '3', 'tok-w5-001'],
      reason:
          'H1: after seat_assigned (seat 3, token "tok-w5-001") and the '
          'room reply for code "AB23CD" complete a join, session.seat '
          'must hold exactly [code, seat, token] with those values; got '
          '$stored',
    );
  });

  testWidgets(
    'W-6 clear on finish (H2a): a game_over push after a successful join '
    'clears session.seat',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      addTearDown(factory.disposeAll);

      await tester.pumpWidget(_homeScreenApp(factory.call));
      await tester.pumpAndSettle();

      final result = await _joinSuccessfully(
        tester,
        factory,
        code: 'AB23CD',
        seat: 1,
        token: 'tok-w6-001',
      );

      final List<String>? storedBefore = await _storedSeat();
      expect(
        storedBefore,
        isNotNull,
        reason:
            'fixture is broken: H1 must have written session.seat before '
            'this test pushes game_over',
      );

      result.transport.pushText(
        _frame(
          type: 'game_over',
          data: <String, Object?>{
            'winner': 0,
            'verify_url': 'https://verify.example.test/w6',
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      await _letStoreWriteSettle(tester);

      expect(
        result.controller.room?.state,
        RoomState.finished,
        reason:
            'fixture is broken: the game_over push must land room.state on '
            'finished before this test checks the store',
      );
      final List<String>? storedAfter = await _storedSeat();
      expect(
        storedAfter,
        isNull,
        reason:
            'H2a: once the owned controller\'s room.state is observed as '
            'finished, session.seat must be cleared; still holds '
            '$storedAfter',
      );
    },
  );

  testWidgets(
    'W-7 clear on leave (H2b): once leave() completes after the player '
    'pops the route, session.seat is gone and Home hides the button',
    (tester) async {
      // No addTearDown(factory.disposeAll) here (lesson 9): this case's own
      // assertion is that H2b's retire flow disposes the controller once
      // leave() completes, so by the time this test body ends the
      // controller is already disposed by home_screen.dart itself, and a
      // second dispose() from a blanket teardown throws "used after being
      // disposed".
      final _RecordingControllerFactory factory = _RecordingControllerFactory();

      await tester.pumpWidget(_homeScreenApp(factory.call));
      await tester.pumpAndSettle();

      await _joinSuccessfully(
        tester,
        factory,
        code: 'AB23CD',
        seat: 1,
        token: 'tok-w7-001',
      );

      final List<String>? storedBefore = await _storedSeat();
      expect(
        storedBefore,
        isNotNull,
        reason:
            'fixture is broken: H1 must have written session.seat before '
            'this test pops the route',
      );

      await _popPushedRoute(tester, find.byType(LobbyScreen));
      await _flushAnyOutstandingRequestTimeout(tester);
      await _letStoreWriteSettle(tester);

      final List<String>? storedAfter = await _storedSeat();
      expect(
        storedAfter,
        isNull,
        reason:
            'H2b: once leave() completes for a controller HomeScreen is '
            'retiring, session.seat must be cleared regardless of whether a '
            'record was ever written for the *next* controller; still '
            'holds $storedAfter',
      );
      expect(
        find.byKey(_rejoinKey),
        findsNothing,
        reason:
            'H2: once session.seat is cleared, Home must stop showing '
            'home-rejoin-button in the same frame it would otherwise next '
            'build',
      );
    },
  );

  group('W-8 clear on refusal (H2c)', () {
    for (final String errorCode in <String>['BAD_SEAT_TOKEN', 'NO_SUCH_ROOM']) {
      testWidgets('resume answered $errorCode clears session.seat', (
        tester,
      ) async {
        await SessionMemory.recordSeat(
          const SeatRecord(code: _kCode, seat: _kSeat, seatToken: _kToken),
        );
        final _RecordingControllerFactory factory =
            _RecordingControllerFactory();
        addTearDown(factory.disposeAll);

        await tester.pumpWidget(_homeScreenApp(factory.call));
        await tester.pumpAndSettle();

        final String resumeId = await _tapRejoinAndCaptureResumeId(
          tester,
          factory,
        );
        final FakeTransport transport = factory.transports.single;

        transport.pushText(
          _frame(
            type: 'error',
            re: resumeId,
            data: <String, Object?>{'code': errorCode, 'message': ''},
          ),
        );
        await tester.pump();
        await tester.pump();
        await _letStoreWriteSettle(tester);

        final List<String>? stored = await _storedSeat();
        expect(
          stored,
          isNull,
          reason:
              'H2c: a resume for code "$_kCode" refused with $errorCode '
              'must clear session.seat; still holds $stored',
        );
      });
    }
  });

  testWidgets('W-9 keep on a transport failure (control for H2c): the record '
      'survives, and the lobby retry button re-sends resume with the same '
      'code and token', (tester) async {
    await SessionMemory.recordSeat(
      const SeatRecord(code: _kCode, seat: _kSeat, seatToken: _kToken),
    );
    final _SingleFlakyControllerFactory factory =
        _SingleFlakyControllerFactory();
    addTearDown(() => factory.controller?.dispose());

    await tester.pumpWidget(_homeScreenApp(factory.call));
    await tester.pumpAndSettle();

    await _tapAndAwaitPushedRoute(tester, _rejoinKey);

    final RoomController? controller = factory.controller;
    expect(
      controller,
      isNotNull,
      reason:
          'fixture is broken: tapping home-rejoin-button must build a '
          'controller through widget.controllerFactory',
    );
    expect(
      controller!.phase,
      RoomPhase.failed,
      reason:
          'fixture is broken: the connector rejecting its first call '
          'must land the controller in RoomPhase.failed before this test '
          'checks the store; phase is ${controller.phase}',
    );
    expect(
      controller.errorCode,
      'transport',
      reason:
          'fixture is broken: a connector that rejects before opening '
          'must fail with errorCode "transport", not '
          '"${controller.errorCode}"',
    );

    await _letStoreWriteSettle(tester);
    final List<String>? storedAfterFailure = await _storedSeat();
    expect(
      storedAfterFailure,
      <String>[_kCode, _kSeat.toString(), _kToken],
      reason:
          'control for H2c: a plain transport failure (errorCode '
          '"transport", not BAD_SEAT_TOKEN or NO_SUCH_ROOM) must not '
          'clear session.seat; it holds $storedAfterFailure',
    );

    final Finder retryButton = find.byKey(_retryKey);
    expect(
      retryButton,
      findsOneWidget,
      reason:
          'fixture is broken: LobbyScreen must show lobby-retry-button '
          'once the resume attempt has failed',
    );
    await tester.tap(retryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      factory.connector.transports,
      hasLength(1),
      reason:
          'fixture is broken: the retry must be the connector\'s second '
          'call, the first one that actually returns a transport; the '
          'connector recorded ${factory.connector.transports.length} '
          'opened transports after ${factory.connector.calls} calls',
    );
    final FakeTransport retryTransport = factory.connector.transports.single;
    expect(
      retryTransport.sentRaw,
      hasLength(1),
      reason:
          'the retry must put exactly one frame on the wire; sent '
          '${retryTransport.sentRaw.map(_typeOf).toList()}',
    );
    final String retryFrame = retryTransport.sentRaw.single;
    expect(
      _typeOf(retryFrame),
      'resume',
      reason:
          'H5: lobby-retry-button must resend resume, not '
          '"${_typeOf(retryFrame)}"',
    );
    expect(
      _dataOf(retryFrame),
      <String, Object?>{'code': _kCode, 'seat_token': _kToken},
      reason:
          'the retry must resend the same stored code ("$_kCode") and '
          'token ("$_kToken") the first attempt used; sent '
          '${_dataOf(retryFrame)}',
    );

    // The retry's own request is deliberately never answered; flush its
    // 10-second timeout before the test ends so no Timer is left pending.
    await _flushAnyOutstandingRequestTimeout(tester);
  });
}

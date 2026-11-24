// Widget tests for the recent room-code memory behind Join.
//
// After a successful join, session memory keeps the joined code (max 3,
// newest first). Since C-678 Home no longer shows them as chips under the
// join field: the data stays, the keys home-recent-codes and
// home-recent-code-<CODE> are gone.
//
// Join Room builds a RoomController from widget.controllerFactory().
// These tests inject a factory wired to FakeTransport so the join can
// succeed on the wire. LobbyScreen's connecting state shows a
// CircularProgressIndicator, so these tests never call pumpAndSettle
// after a Join tap. A bounded 400ms pump covers MaterialPageRoute's
// default 300ms transition.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';
import 'support/home_flow.dart';

const Key _nameKey = Key('home-name-field');
const Key _joinKey = Key('join-room-button');
const Key _codeKey = Key('room-code-field');
const Key _recentListKey = Key('home-recent-codes');
const String _recentChipKeyPrefix = 'home-recent-code-';

const String _testUrl = 'wss://recent-codes-test.invalid/ws';

const String _codeOldest = 'AB23CD';
const String _codeMid = 'K7M2QP';
const String _codeNewer = 'ZQ2X59';
const String _codeNewest = 'H4N8W3';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'recent-codes-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  required String joinerName,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Host'),
    _seatJson(1, name: joinerName),
  ],
  'turn': null,
  'winner': null,
  'seq': 1,
};

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
}

Widget _homeScreenApp(
  RoomControllerFactory controllerFactory, {
  Key? key,
  NavigatorObserver? observer,
}) {
  return MaterialApp(
    key: key,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: observer == null
        ? const <NavigatorObserver>[]
        : <NavigatorObserver>[observer],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  // Join enters with a full code (C-523 D3), through a 200 ms AnimatedSize at
  // most: let it reach its final rect before the tap.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.ensureVisible(find.byKey(buttonKey));
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _popPushedRoute(WidgetTester tester) async {
  final BuildContext context = tester.element(find.byType(LobbyScreen));
  Navigator.of(context).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _flushAnyOutstandingRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

String _codeFieldText(WidgetTester tester) {
  expect(find.byKey(_codeKey), findsOneWidget);
  return tester.widget<TextField>(find.byKey(_codeKey)).controller!.text;
}

Key _recentChipKey(String code) => Key('$_recentChipKeyPrefix$code');

Future<List<String>> _storedCodes() async =>
    (await SessionMemory.load()).recentCodes;

void _expectNoChips(WidgetTester tester, List<String> codes) {
  expect(
    find.byKey(_recentListKey, skipOffstage: false),
    findsNothing,
    reason: 'C-678: Home must not show home-recent-codes',
  );
  for (final String code in codes) {
    expect(
      find.byKey(_recentChipKey(code), skipOffstage: false),
      findsNothing,
      reason: 'C-678: Home must not show home-recent-code-$code',
    );
  }
}

Future<void> _completeSuccessfulJoin(
  WidgetTester tester,
  FakeTransport transport, {
  required String code,
  required String name,
}) async {
  final List<String> joinMessages = transport.sentRaw
      .where((String sent) => _typeOf(sent) == 'join_room')
      .toList();
  expect(
    joinMessages,
    hasLength(1),
    reason:
        'Join Room must have sent one join_room request before this '
        'check treats the join as successful; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );
  final Map<String, Object?> joinBody = Map<String, Object?>.of(
    _dataOf(joinMessages.single),
  );
  expect(
    joinBody.remove('install'),
    isA<String>(),
    reason: 'join_room carries the install id; sent $joinBody',
  );
  expect(
    joinBody,
    <String, Object?>{'code': code, 'name': name},
    reason:
        'the typed code and name must reach the wire before the join '
        'is treated as successful',
  );
  final String joinId = _idOf(joinMessages.single);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 1, 'seat_token': 'tok-recent-$code'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: joinId,
      data: _roomJson(code: code, joinerName: name),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    find.byKey(const Key('lobby-room-code')),
    findsOneWidget,
    reason: 'a successful join must land on a lobby that shows lobby-room-code',
  );
}

Future<void> _joinThenReturnHome(
  WidgetTester tester,
  _RecordingControllerFactory factory, {
  required String code,
  required String name,
}) async {
  await tester.enterText(find.byKey(_nameKey), name);
  await tester.pump();
  // Order 701: the code field is behind the join sheet's code tile.
  await openCodeEntry(tester);
  await tester.enterText(find.byKey(_codeKey), code);
  await tester.pump();
  await _tapAndAwaitPushedRoute(tester, _joinKey);

  expect(
    factory.transports,
    isNotEmpty,
    reason: 'Join Room must build a controller through the injected factory',
  );
  await _completeSuccessfulJoin(
    tester,
    factory.transports.last,
    code: code,
    name: name,
  );

  await _popPushedRoute(tester);
  // C-669 R4: an unanswered leave keeps the seat record, and a kept record
  // resumes on relaunch. Backing out here is the ordinary delivered leave,
  // so the server answers it, in LOBBY with `player_left`.
  final FakeTransport transport = factory.transports.last;
  final List<String> leaves = transport.sentRaw
      .where((String s) => _typeOf(s) == 'leave_room')
      .toList();
  expect(
    leaves,
    hasLength(1),
    reason:
        'backing out of the lobby must send exactly one leave_room; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );
  transport.pushText(
    _frame(
      type: 'player_left',
      re: _idOf(leaves.single),
      data: <String, Object?>{'seat': 1, 'host_seat': 0, 'seq': 2},
    ),
  );
  await tester.pump();
  await _flushAnyOutstandingRequestTimeout(tester);
  // Order 701: home holds join-game-button; the code field is in its sheet.
  expect(
    find.byKey(joinGameButtonKey),
    findsOneWidget,
    reason:
        'backing out of the lobby must return to Home with join-game-button',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'successful join then return to Home keeps that code in session memory '
    'and shows no chip',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      await tester.pumpWidget(_homeScreenApp(factory.call));
      await tester.pumpAndSettle();

      await _joinThenReturnHome(
        tester,
        factory,
        code: _codeOldest,
        name: 'Riri',
      );

      expect(
        await _storedCodes(),
        <String>[_codeOldest],
        reason:
            'after a successful join, session memory must keep the joined '
            'code "$_codeOldest"',
      );
      _expectNoChips(tester, <String>[_codeOldest]);
    },
  );

  testWidgets('four successful joins keep at most three codes newest first', (
    tester,
  ) async {
    final _RecordingControllerFactory factory = _RecordingControllerFactory();
    await tester.pumpWidget(_homeScreenApp(factory.call));
    await tester.pumpAndSettle();

    const List<String> joined = <String>[
      _codeOldest,
      _codeMid,
      _codeNewer,
      _codeNewest,
    ];
    for (final String code in joined) {
      await _joinThenReturnHome(tester, factory, code: code, name: 'Riri');
    }

    expect(
      await _storedCodes(),
      <String>[_codeNewest, _codeNewer, _codeMid],
      reason:
          'session memory must keep at most three codes, newest first; '
          'after joining $joined it must be [$_codeNewest, $_codeNewer, '
          '$_codeMid]',
    );
    _expectNoChips(tester, joined);
  });

  testWidgets(
    'relaunch after successful join keeps the code in memory, shows no chip',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      await tester.pumpWidget(
        _homeScreenApp(
          factory.call,
          key: const ValueKey<String>('recent-visit'),
        ),
      );
      await tester.pumpAndSettle();

      await _joinThenReturnHome(tester, factory, code: _codeMid, name: 'Riri');

      await tester.pumpWidget(
        _homeScreenApp(
          factory.call,
          key: const ValueKey<String>('recent-relaunch'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(
        await _storedCodes(),
        <String>[_codeMid],
        reason:
            'after a successful join, a relaunch must still find "$_codeMid" '
            'in session memory',
      );
      _expectNoChips(tester, <String>[_codeMid]);
      // Order 701: open the code entry to read the field (a name first).
      await enterName(tester, 'Riri');
      await openCodeEntry(tester);
      expect(
        _codeFieldText(tester),
        isEmpty,
        reason: 'the relaunched code field starts empty; no chip fills it',
      );
    },
  );
}
